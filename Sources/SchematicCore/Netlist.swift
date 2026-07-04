import Foundation

public struct NetPin {
    public let symbol: SymbolInstance
    public let pin: PinDefinition
    public let world: Vec2

    public var description: String { "\(symbol.refDes).\(pin.name)" }
}

/// An electrical net: a set of pins connected by wires or direct contact.
public final class Net {
    public internal(set) var name = ""
    public internal(set) var pins: [NetPin] = []
    public internal(set) var wires: [Wire] = []
}

public final class NetlistResult {
    public init() {}

    public internal(set) var nets: [Net] = []
    /// Wire endpoints that connect to nothing (for ERC and dangling markers).
    public internal(set) var danglingWireEnds: [Vec2] = []
    /// Points where three or more connections meet (rendered as junction dots).
    public internal(set) var junctions: [Vec2] = []

    /// Find the net that owns the given point (a pin, a wire vertex, or a segment interior).
    public func findNet(at point: Vec2) -> Net? {
        let key = point.key()
        for net in nets {
            if net.pins.contains(where: { $0.world.key() == key }) { return net }
            for wire in net.wires {
                if wire.points.contains(where: { $0.key() == key }) { return net }
                for seg in wire.segments() where point.isOnSegment(seg.a, seg.b) { return net }
            }
        }
        return nil
    }

    public func toText() -> String {
        if nets.isEmpty { return "(no nets)\n" }
        return nets.map { net in "\(net.name): " + net.pins.map(\.description).joined(separator: ", ") }.joined(separator: "\n") + "\n"
    }
}

/// Extracts nets from the document. Connectivity rules (identical to the C# core):
///  - coincident connection points (pins, wire vertices) are connected;
///  - consecutive vertices of a wire are connected;
///  - a connection point lying on the interior of a wire segment forms a T-connection.
public enum NetlistExtractor {
    private struct UnionFind {
        var parent: [Int]

        init(_ n: Int) { parent = Array(0..<n) }

        mutating func find(_ x: Int) -> Int {
            var x = x
            while parent[x] != x {
                parent[x] = parent[parent[x]]
                x = parent[x]
            }
            return x
        }

        mutating func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[ra] = rb }
        }
    }

    public static func extract(_ doc: SchematicDocument) -> NetlistResult {
        let result = NetlistResult()

        // 1. Collect all connection points, merging coincident ones by quantized key.
        var nodeIndex: [Vec2.Key: Int] = [:]
        var nodePoints: [Vec2] = []

        func nodeOf(_ p: Vec2) -> Int {
            let key = p.key()
            if let idx = nodeIndex[key] { return idx }
            let idx = nodePoints.count
            nodeIndex[key] = idx
            nodePoints.append(p)
            return idx
        }

        let wires = doc.wires
        let wireNodeLists = wires.map { $0.points.map(nodeOf) }

        var pinAtNode: [[NetPin]] = []
        for sym in doc.symbols {
            for (pin, world) in sym.worldPins() {
                let n = nodeOf(world)
                while pinAtNode.count < nodePoints.count { pinAtNode.append([]) }
                pinAtNode[n].append(NetPin(symbol: sym, pin: pin, world: world))
            }
        }
        while pinAtNode.count < nodePoints.count { pinAtNode.append([]) }

        var uf = UnionFind(nodePoints.count)

        // 2. Wire segments connect their endpoints.
        for nodes in wireNodeLists {
            for i in 0..<max(0, nodes.count - 1) { uf.union(nodes[i], nodes[i + 1]) }
        }

        // 3. T-connections: node lying on the interior of another wire's segment.
        var tConnections: [Int] = []
        for (w, wire) in wires.enumerated() {
            let nodes = wireNodeLists[w]
            for s in 0..<max(0, wire.points.count - 1) {
                let a = wire.points[s], b = wire.points[s + 1]
                var segBounds = Rect2.empty
                segBounds.include(a)
                segBounds.include(b)
                segBounds = segBounds.inflated(0.1)
                for n in 0..<nodePoints.count {
                    let p = nodePoints[n]
                    if !segBounds.contains(p) { continue }
                    if p.key() == a.key() || p.key() == b.key() { continue }
                    if p.isOnSegment(a, b) {
                        uf.union(n, nodes[s])
                        tConnections.append(n)
                    }
                }
            }
        }

        // 4. Connection degree per node.
        var degree = [Int](repeating: 0, count: nodePoints.count)
        for n in tConnections { degree[n] += 2 }
        for nodes in wireNodeLists {
            for i in 0..<nodes.count {
                let isEndpoint = i == 0 || i == nodes.count - 1
                degree[nodes[i]] += isEndpoint ? 1 : 2
            }
        }
        for n in 0..<nodePoints.count { degree[n] += pinAtNode[n].count }

        var netByRoot: [Int: Net] = [:]
        func netOf(_ node: Int) -> Net {
            let root = uf.find(node)
            if let net = netByRoot[root] { return net }
            let net = Net()
            netByRoot[root] = net
            return net
        }

        for n in 0..<nodePoints.count where !pinAtNode[n].isEmpty {
            netOf(n).pins.append(contentsOf: pinAtNode[n])
        }

        for (w, nodes) in wireNodeLists.enumerated() where !nodes.isEmpty {
            netOf(nodes[0]).wires.append(wires[w])
        }

        // 5. Junction dots and dangling wire ends.
        for nodes in wireNodeLists where !nodes.isEmpty {
            for end in [nodes[0], nodes[nodes.count - 1]] where degree[end] <= 1 {
                result.danglingWireEnds.append(nodePoints[end])
            }
        }
        for n in 0..<nodePoints.count where degree[n] >= 3 {
            result.junctions.append(nodePoints[n])
        }

        // 6. Name nets: GND when a ground symbol is attached, otherwise N001, N002...
        var counter = 1
        for net in netByRoot.values where !net.pins.isEmpty || !net.wires.isEmpty {
            if net.pins.contains(where: { $0.symbol.definition.name == "Ground" }) {
                net.name = "GND"
            } else {
                net.name = String(format: "N%03d", counter)
                counter += 1
            }
            result.nets.append(net)
        }

        result.nets.sort { $0.name < $1.name }
        return result
    }
}

// MARK: - ERC

public enum ErcSeverity {
    case warning
    case error
}

public struct ErcIssue {
    public let severity: ErcSeverity
    public let message: String
    public let location: Vec2
}

/// Electrical rule check, same rule set as the C# core: unconnected pins, dangling wire
/// ends, single-pin nets, short-circuited sources, missing reference designators.
public enum ErcChecker {
    public static func check(_ doc: SchematicDocument, _ netlist: NetlistResult) -> [ErcIssue] {
        var issues: [ErcIssue] = []

        struct PinKey: Hashable {
            let id: Int
            let name: String
        }
        var connectedPins = Set<PinKey>()

        for net in netlist.nets {
            let hasWires = !net.wires.isEmpty
            for pin in net.pins where hasWires || net.pins.count > 1 {
                connectedPins.insert(PinKey(id: pin.symbol.id, name: pin.pin.name))
            }
        }

        for sym in doc.symbols {
            for (pin, world) in sym.worldPins() where !connectedPins.contains(PinKey(id: sym.id, name: pin.name)) {
                issues.append(ErcIssue(severity: .error, message: "Unconnected pin \(sym.refDes).\(pin.name)", location: world))
            }
            if sym.refDes.hasSuffix("?") {
                issues.append(ErcIssue(severity: .warning, message: "Symbol has no reference designator: \(sym.refDes)", location: sym.position))
            }
        }

        for p in netlist.danglingWireEnds {
            issues.append(ErcIssue(severity: .error, message: String(format: "Dangling wire end at (%.1f, %.1f)", p.x, p.y), location: p))
        }

        for net in netlist.nets where net.pins.count == 1 && !net.wires.isEmpty {
            issues.append(ErcIssue(severity: .warning, message: "Net \(net.name) connects only one pin (\(net.pins[0].description))", location: net.pins[0].world))
        }

        for net in netlist.nets {
            let sources = net.pins.filter { $0.symbol.definition.name == "VSource" || $0.symbol.definition.name == "Battery" }
            let grouped = Dictionary(grouping: sources) { $0.symbol.id }
            for (_, pins) in grouped where pins.count >= 2 {
                issues.append(ErcIssue(severity: .error, message: "Source \(pins[0].symbol.refDes) is short-circuited (both terminals on net \(net.name))", location: pins[0].symbol.position))
            }
        }

        return issues
    }
}
