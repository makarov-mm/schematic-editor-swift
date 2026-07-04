import Foundation

/// Minimal complex number for the AC solve — keeps the package dependency-free.
public struct Complex: Equatable, Sendable {
    public var re: Double
    public var im: Double

    public init(_ re: Double, _ im: Double = 0) {
        self.re = re
        self.im = im
    }

    public static let zero = Complex(0)

    public var magnitude: Double { (re * re + im * im).squareRoot() }
    public var phase: Double { atan2(im, re) }

    public static func + (a: Complex, b: Complex) -> Complex { Complex(a.re + b.re, a.im + b.im) }
    public static func - (a: Complex, b: Complex) -> Complex { Complex(a.re - b.re, a.im - b.im) }
    public static func * (a: Complex, b: Complex) -> Complex { Complex(a.re * b.re - a.im * b.im, a.re * b.im + a.im * b.re) }

    public static func / (a: Complex, b: Complex) -> Complex {
        let d = b.re * b.re + b.im * b.im
        return Complex((a.re * b.re + a.im * b.im) / d, (a.im * b.re - a.re * b.im) / d)
    }

    public static func += (a: inout Complex, b: Complex) { a = a + b }
    public static func -= (a: inout Complex, b: Complex) { a = a - b }
}

public struct SimulationError: Error {
    public let message: String

    public init(message: String) { self.message = message }
}

/// Time-domain circuit simulator built on Modified Nodal Analysis, plus a SPICE-style
/// small-signal AC solve over the same topology. A line-by-line port of the verified C# core:
/// backward-Euler companion models, piecewise-linear diode with state iteration, live switch
/// state, instant fuses, dense Gaussian elimination (real for transient, complex for AC).
public final class CircuitSimulator {
    private enum Kind {
        case resistor, lamp, fuse, `switch`, capacitor, inductor, diode, sourceDc, sourceAc
    }

    private final class Element {
        let kind: Kind
        let symbol: SymbolInstance
        let nodeA: Int
        let nodeB: Int
        var value: Double = 0
        var frequency: Double = 0
        var ratedPower: Double = 0
        var ratedCurrent: Double = 0
        var branch = -1

        var prevVoltage: Double = 0
        var prevCurrent: Double = 0
        var diodeOn = false
        var fuseBlown = false
        var current: Double = 0

        init(kind: Kind, symbol: SymbolInstance, nodeA: Int, nodeB: Int) {
            self.kind = kind
            self.symbol = symbol
            self.nodeA = nodeA
            self.nodeB = nodeB
        }
    }

    private static let gmin = 1e-9
    private static let switchOnR = 1e-3
    private static let fuseR = 1e-2
    private static let diodeVon = 0.7
    private static let diodeRon = 0.05

    private let netlist: NetlistResult
    private let elements: [Element]
    private let netNode: [ObjectIdentifier: Int]
    private let netByNode: [Int: Net]
    private let nodeCount: Int
    private let branchCount: Int
    private var a: [Double]
    private var rhs: [Double]
    private var x: [Double]
    private var nodeVoltage: [Double]
    private let bySymbolId: [Int: Element]

    public private(set) var time: Double = 0
    public let warnings: [String]

    private init(netlist: NetlistResult, elements: [Element], netNode: [ObjectIdentifier: Int], netByNode: [Int: Net], nodeCount: Int, warnings: [String]) {
        self.netlist = netlist
        self.elements = elements
        self.netNode = netNode
        self.netByNode = netByNode
        self.nodeCount = nodeCount
        self.warnings = warnings

        var branch = 0
        for e in elements where e.kind == .sourceDc || e.kind == .sourceAc || e.kind == .inductor {
            e.branch = branch
            branch += 1
        }
        self.branchCount = branch

        let n = nodeCount + branchCount
        self.a = [Double](repeating: 0, count: n * n)
        self.rhs = [Double](repeating: 0, count: n)
        self.x = [Double](repeating: 0, count: n)
        self.nodeVoltage = [Double](repeating: 0, count: nodeCount + 1)
        self.bySymbolId = Dictionary(uniqueKeysWithValues: elements.map { ($0.symbol.id, $0) })
    }

    /// Build a simulator from the document. Returns nil (with problems) when the circuit
    /// cannot be simulated at all; recoverable oddities are reported as warnings.
    public static func build(_ doc: SchematicDocument, _ netlist: NetlistResult, problems: inout [String]) -> CircuitSimulator? {
        problems = []
        var warnings: [String] = []

        var netNode: [ObjectIdentifier: Int] = [:]
        var netByNode: [Int: Net] = [:]
        var next = 1
        for net in netlist.nets {
            let grounded = net.pins.contains { $0.symbol.definition.name == "Ground" }
            let node = grounded ? 0 : next
            if !grounded { next += 1 }
            netNode[ObjectIdentifier(net)] = node
            netByNode[node] = net
        }

        if netlist.nets.allSatisfy({ netNode[ObjectIdentifier($0)] != 0 }) {
            problems.append("No ground: place a Ground symbol to define 0 V.")
            return nil
        }

        struct PinKey: Hashable {
            let id: Int
            let name: String
        }
        var pinNet: [PinKey: Net] = [:]
        for net in netlist.nets {
            for pin in net.pins { pinNet[PinKey(id: pin.symbol.id, name: pin.pin.name)] = net }
        }

        var elements: [Element] = []
        var anySource = false

        for sym in doc.symbols {
            let name = sym.definition.name
            if name == "Ground" { continue }

            if name == "NPN" {
                warnings.append("\(sym.refDes): transistors are not simulated (treated as open).")
                continue
            }

            let pins = sym.definition.pins
            if pins.count != 2 { continue }

            guard let netA = pinNet[PinKey(id: sym.id, name: pins[0].name)],
                  let netB = pinNet[PinKey(id: sym.id, name: pins[1].name)] else {
                warnings.append("\(sym.refDes): not fully connected, skipped.")
                continue
            }

            let nodeA = netNode[ObjectIdentifier(netA)]!
            let nodeB = netNode[ObjectIdentifier(netB)]!
            let kind: Kind

            switch name {
            case "Resistor": kind = .resistor
            case "Lamp": kind = .lamp
            case "Fuse": kind = .fuse
            case "Switch": kind = .switch
            case "Capacitor": kind = .capacitor
            case "Inductor": kind = .inductor
            case "Diode": kind = .diode
            case "VSource", "Battery": kind = .sourceDc
            case "ACSource": kind = .sourceAc
            default:
                warnings.append("\(sym.refDes): '\(name)' is not simulated.")
                continue
            }

            let e = Element(kind: kind, symbol: sym, nodeA: nodeA, nodeB: nodeB)

            switch kind {
            case .resistor:
                if let v = Units.parse(sym.value), v > 0 { e.value = v }
                else {
                    warnings.append("\(sym.refDes): cannot parse '\(sym.value)', using 1k.")
                    e.value = 1e3
                }
            case .lamp:
                if let rating = Units.parseLampRating(sym.value) {
                    e.value = rating.resistance
                    e.ratedPower = rating.ratedPower
                } else {
                    warnings.append("\(sym.refDes): cannot parse '\(sym.value)', using 12V 5W.")
                    e.value = 12 * 12 / 5.0
                    e.ratedPower = 5
                }
            case .fuse:
                e.value = fuseR
                if let v = Units.parse(sym.value), v > 0 { e.ratedCurrent = v }
                else {
                    warnings.append("\(sym.refDes): cannot parse '\(sym.value)', using 1A.")
                    e.ratedCurrent = 1
                }
            case .switch:
                break
            case .capacitor:
                if let v = Units.parse(sym.value), v > 0 { e.value = v }
                else {
                    warnings.append("\(sym.refDes): cannot parse '\(sym.value)', using 100n.")
                    e.value = 100e-9
                }
            case .inductor:
                if let v = Units.parse(sym.value), v > 0 { e.value = v }
                else {
                    warnings.append("\(sym.refDes): cannot parse '\(sym.value)', using 10m.")
                    e.value = 10e-3
                }
            case .diode:
                break
            case .sourceDc:
                anySource = true
                if let v = Units.parse(sym.value) { e.value = v }
                else {
                    warnings.append("\(sym.refDes): cannot parse '\(sym.value)', using 5V.")
                    e.value = 5
                }
            case .sourceAc:
                anySource = true
                if let spec = Units.parseAcSpec(sym.value) {
                    e.value = spec.amplitude
                    e.frequency = spec.frequency
                } else {
                    warnings.append("\(sym.refDes): cannot parse '\(sym.value)', using 5V 50Hz.")
                    e.value = 5
                    e.frequency = 50
                }
            }

            elements.append(e)
        }

        if !anySource {
            problems.append("No voltage source: add a Battery, VSource or ACSource.")
            return nil
        }

        let nodeCount = netNode.values.max() ?? 0
        return CircuitSimulator(netlist: netlist, elements: elements, netNode: netNode, netByNode: netByNode, nodeCount: nodeCount, warnings: warnings)
    }

    /// Reset time, reactive state, blown fuses and diode states.
    public func reset() {
        time = 0
        for e in elements {
            e.prevVoltage = 0
            e.prevCurrent = 0
            e.diodeOn = false
            e.fuseBlown = false
            e.current = 0
        }
        for i in 0..<nodeVoltage.count { nodeVoltage[i] = 0 }
    }

    /// Advance the simulation by one time step.
    public func step(_ dt: Double) throws {
        time += dt

        // Diode PWL state iteration: assume states, solve, verify, flip, repeat.
        var iter = 0
        while true {
            assemble(dt)
            try solve()

            var consistent = true
            for e in elements where e.kind == .diode {
                let vd = v(e.nodeA) - v(e.nodeB)
                if e.diodeOn {
                    let i = (vd - Self.diodeVon) / Self.diodeRon
                    if i < 0 {
                        e.diodeOn = false
                        consistent = false
                    }
                } else if vd > Self.diodeVon {
                    e.diodeOn = true
                    consistent = false
                }
            }

            if consistent || iter >= 12 { break }
            iter += 1
        }

        if nodeCount > 0 {
            for i in 1...nodeCount { nodeVoltage[i] = x[i - 1] }
        }

        for e in elements {
            let va = v(e.nodeA), vb = v(e.nodeB), vd = va - vb
            switch e.kind {
            case .resistor, .lamp:
                e.current = vd / e.value
            case .fuse:
                e.current = e.fuseBlown ? vd * Self.gmin : vd / e.value
                if !e.fuseBlown && abs(e.current) > e.ratedCurrent {
                    e.fuseBlown = true
                    e.current = 0
                }
            case .switch:
                e.current = e.symbol.stateOn ? vd / Self.switchOnR : vd * Self.gmin
            case .capacitor:
                let g = e.value / dt
                e.current = g * (vd - e.prevVoltage)
                e.prevVoltage = vd
            case .inductor:
                e.current = x[nodeCount + e.branch]
                e.prevCurrent = e.current
            case .diode:
                e.current = e.diodeOn ? (vd - Self.diodeVon) / Self.diodeRon : vd * Self.gmin
            case .sourceDc, .sourceAc:
                // Branch current flows out of the + terminal through the circuit.
                e.current = -x[nodeCount + e.branch]
            }
        }
    }

    private func v(_ node: Int) -> Double { node == 0 ? 0 : x[node - 1] }

    private func assemble(_ dt: Double) {
        let n = nodeCount + branchCount
        for i in 0..<(n * n) { a[i] = 0 }
        for i in 0..<n { rhs[i] = 0 }

        for i in 0..<nodeCount { a[i * n + i] += Self.gmin }

        func stampG(_ na: Int, _ nb: Int, _ g: Double) {
            if na != 0 { a[(na - 1) * n + (na - 1)] += g }
            if nb != 0 { a[(nb - 1) * n + (nb - 1)] += g }
            if na != 0 && nb != 0 {
                a[(na - 1) * n + (nb - 1)] -= g
                a[(nb - 1) * n + (na - 1)] -= g
            }
        }

        // Current source injecting into node A and out of node B.
        func stampCurrent(_ na: Int, _ nb: Int, _ i: Double) {
            if na != 0 { rhs[na - 1] += i }
            if nb != 0 { rhs[nb - 1] -= i }
        }

        func stampBranch(_ na: Int, _ nb: Int, _ k: Int) {
            if na != 0 { a[(na - 1) * n + k] += 1; a[k * n + (na - 1)] += 1 }
            if nb != 0 { a[(nb - 1) * n + k] -= 1; a[k * n + (nb - 1)] -= 1 }
        }

        for e in elements {
            switch e.kind {
            case .resistor, .lamp:
                stampG(e.nodeA, e.nodeB, 1.0 / e.value)
            case .fuse:
                stampG(e.nodeA, e.nodeB, e.fuseBlown ? Self.gmin : 1.0 / e.value)
            case .switch:
                stampG(e.nodeA, e.nodeB, e.symbol.stateOn ? 1.0 / Self.switchOnR : Self.gmin)
            case .capacitor:
                let g = e.value / dt
                stampG(e.nodeA, e.nodeB, g)
                stampCurrent(e.nodeA, e.nodeB, g * e.prevVoltage)
            case .diode:
                if e.diodeOn {
                    stampG(e.nodeA, e.nodeB, 1.0 / Self.diodeRon)
                    stampCurrent(e.nodeA, e.nodeB, Self.diodeVon / Self.diodeRon)
                } else {
                    stampG(e.nodeA, e.nodeB, Self.gmin)
                }
            case .inductor:
                let k = nodeCount + e.branch
                stampBranch(e.nodeA, e.nodeB, k)
                a[k * n + k] -= e.value / dt
                rhs[k] -= e.value / dt * e.prevCurrent
            case .sourceDc, .sourceAc:
                let k = nodeCount + e.branch
                stampBranch(e.nodeA, e.nodeB, k)
                rhs[k] = e.kind == .sourceDc ? e.value : e.value * sin(2.0 * .pi * e.frequency * time)
            }
        }
    }

    /// Dense Gaussian elimination with partial pivoting, on copies so assemble can rebuild.
    private func solve() throws {
        let n = nodeCount + branchCount
        var m = a
        var b = rhs

        for col in 0..<n {
            var pivot = col
            var best = abs(m[col * n + col])
            for r in (col + 1)..<n {
                let value = abs(m[r * n + col])
                if value > best {
                    best = value
                    pivot = r
                }
            }
            if best < 1e-14 { throw SimulationError(message: "Singular matrix: circuit has no unique solution.") }

            if pivot != col {
                for c in col..<n { m.swapAt(col * n + c, pivot * n + c) }
                b.swapAt(col, pivot)
            }

            for r in (col + 1)..<n {
                let f = m[r * n + col] / m[col * n + col]
                if f == 0 { continue }
                for c in col..<n { m[r * n + c] -= f * m[col * n + c] }
                b[r] -= f * b[col]
            }
        }

        for r in stride(from: n - 1, through: 0, by: -1) {
            var sum = b[r]
            for c in (r + 1)..<n { sum -= m[r * n + c] * x[c] }
            x[r] = sum / m[r * n + r]
        }
    }

    // MARK: - Probes

    /// Resolve the MNA node index that owns the given point (0 = ground), or nil.
    public func resolveNode(_ point: Vec2) -> Int? {
        guard let net = netlist.findNet(at: point) else { return nil }
        return netNode[ObjectIdentifier(net)]
    }

    public func resolveNetName(_ point: Vec2) -> String? { netlist.findNet(at: point)?.name }

    public func nodeVoltage(_ node: Int) -> Double { node == 0 ? 0 : nodeVoltage[node] }

    public func voltage(at point: Vec2) -> Double? {
        guard let node = resolveNode(point) else { return nil }
        return nodeVoltage(node)
    }

    /// Current through a two-terminal symbol (pin 1 -> pin 2 positive), or nil.
    public func current(of sym: SymbolInstance) -> Double? { bySymbolId[sym.id]?.current }

    /// Lamp brightness 0..1 (rated power -> 1).
    public func lampBrightness(_ lamp: SymbolInstance) -> Double {
        guard let e = bySymbolId[lamp.id], e.kind == .lamp else { return 0 }
        let vd = v(e.nodeA) - v(e.nodeB)
        let power = vd * vd / e.value
        return min(max(power / e.ratedPower, 0), 1)
    }

    public func isFuseBlown(_ fuse: SymbolInstance) -> Bool { bySymbolId[fuse.id]?.fuseBlown ?? false }

    /// Re-parse the value of a live component (R, C, L) while the simulation runs, without a
    /// rebuild — reactive state and time carry straight through the change.
    public func updateComponentValue(_ sym: SymbolInstance) -> Bool {
        guard let e = bySymbolId[sym.id] else { return false }
        guard e.kind == .resistor || e.kind == .capacitor || e.kind == .inductor else { return false }
        guard let parsed = Units.parse(sym.value), parsed > 0 else { return false }
        e.value = parsed
        return true
    }

    // MARK: - AC analysis

    /// Small-signal frequency-domain solve at a single frequency. Same topology, complex
    /// immittances; nonlinear elements linearized around their present state; AC sources
    /// drive with their amplitude, DC sources become shorts. Returns node voltages followed
    /// by branch currents.
    public func solveAc(frequency: Double) throws -> [Complex] {
        let n = nodeCount + branchCount
        var m = [Complex](repeating: .zero, count: n * n)
        var b = [Complex](repeating: .zero, count: n)
        let w = 2.0 * Double.pi * frequency

        for i in 0..<nodeCount { m[i * n + i] += Complex(Self.gmin) }

        func stampG(_ na: Int, _ nb: Int, _ g: Complex) {
            if na != 0 { m[(na - 1) * n + (na - 1)] += g }
            if nb != 0 { m[(nb - 1) * n + (nb - 1)] += g }
            if na != 0 && nb != 0 {
                m[(na - 1) * n + (nb - 1)] -= g
                m[(nb - 1) * n + (na - 1)] -= g
            }
        }

        func stampBranch(_ na: Int, _ nb: Int, _ k: Int) {
            if na != 0 { m[(na - 1) * n + k] += Complex(1); m[k * n + (na - 1)] += Complex(1) }
            if nb != 0 { m[(nb - 1) * n + k] -= Complex(1); m[k * n + (nb - 1)] -= Complex(1) }
        }

        for e in elements {
            switch e.kind {
            case .resistor, .lamp:
                stampG(e.nodeA, e.nodeB, Complex(1.0 / e.value))
            case .fuse:
                stampG(e.nodeA, e.nodeB, Complex(e.fuseBlown ? Self.gmin : 1.0 / e.value))
            case .switch:
                stampG(e.nodeA, e.nodeB, Complex(e.symbol.stateOn ? 1.0 / Self.switchOnR : Self.gmin))
            case .capacitor:
                stampG(e.nodeA, e.nodeB, Complex(0, w * e.value))
            case .diode:
                stampG(e.nodeA, e.nodeB, Complex(e.diodeOn ? 1.0 / Self.diodeRon : Self.gmin))
            case .inductor:
                let k = nodeCount + e.branch
                stampBranch(e.nodeA, e.nodeB, k)
                m[k * n + k] -= Complex(0, w * e.value)
            case .sourceDc, .sourceAc:
                let k = nodeCount + e.branch
                stampBranch(e.nodeA, e.nodeB, k)
                b[k] = e.kind == .sourceAc ? Complex(e.value) : .zero
            }
        }

        // Complex Gaussian elimination with partial pivoting by magnitude.
        var solution = [Complex](repeating: .zero, count: n)
        for col in 0..<n {
            var pivot = col
            var best = m[col * n + col].magnitude
            for r in (col + 1)..<n {
                let value = m[r * n + col].magnitude
                if value > best {
                    best = value
                    pivot = r
                }
            }
            if best < 1e-14 { throw SimulationError(message: "Singular matrix: AC analysis has no unique solution.") }

            if pivot != col {
                for c in col..<n { m.swapAt(col * n + c, pivot * n + c) }
                b.swapAt(col, pivot)
            }

            for r in (col + 1)..<n {
                let f = m[r * n + col] / m[col * n + col]
                if f == .zero { continue }
                for c in col..<n { m[r * n + c] -= f * m[col * n + c] }
                b[r] -= f * b[col]
            }
        }

        for r in stride(from: n - 1, through: 0, by: -1) {
            var sum = b[r]
            for c in (r + 1)..<n { sum -= m[r * n + c] * solution[c] }
            solution[r] = sum / m[r * n + r]
        }

        return solution
    }

    public func acNodeVoltage(_ solution: [Complex], _ node: Int) -> Complex { node == 0 ? .zero : solution[node - 1] }

    public func acVoltage(at point: Vec2, frequency: Double) throws -> Complex? {
        guard let node = resolveNode(point) else { return nil }
        return acNodeVoltage(try solveAc(frequency: frequency), node)
    }
}
