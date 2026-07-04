import Foundation

/// Drawing primitives in symbol-local coordinates. Swift enums with associated values
/// replace the C# record hierarchy one-to-one.
public enum DrawPrimitive: Sendable {
    case line(Vec2, Vec2)
    case poly([Vec2], closed: Bool, filled: Bool)
    case circle(center: Vec2, radius: Double, filled: Bool)
    case arc(center: Vec2, radius: Double, startDeg: Double, endDeg: Double)
    case text(String, at: Vec2, size: Double)

    /// Points that participate in the local bounding box.
    public func boundsPoints() -> [Vec2] {
        switch self {
        case .line(let a, let b):
            return [a, b]
        case .poly(let pts, _, _):
            return pts
        case .circle(let c, let r, _), .arc(let c, let r, _, _):
            return [Vec2(c.x - r, c.y - r), Vec2(c.x + r, c.y + r)]
        case .text(_, let p, _):
            return [p]
        }
    }

    /// Flatten an arc into a polyline (used by exporters).
    public static func flattenArc(center: Vec2, radius: Double, startDeg: Double, endDeg: Double, segments: Int = 16) -> [Vec2] {
        var pts: [Vec2] = []
        for i in 0...segments {
            let deg = startDeg + (endDeg - startDeg) * Double(i) / Double(segments)
            let rad = deg * .pi / 180
            pts.append(Vec2(center.x + radius * cos(rad), center.y + radius * sin(rad)))
        }
        return pts
    }
}

public struct PinDefinition: Sendable {
    public let name: String
    public let position: Vec2

    public init(_ name: String, _ position: Vec2) {
        self.name = name
        self.position = position
    }
}

public final class SymbolDefinition: Sendable {
    public let name: String
    public let refPrefix: String
    public let defaultValue: String
    public let pins: [PinDefinition]
    public let primitives: [DrawPrimitive]
    /// Alternate primitives when the instance is in the "on" state (closed switch).
    public let onPrimitives: [DrawPrimitive]?
    public let localBounds: Rect2

    public init(name: String, refPrefix: String, defaultValue: String, pins: [PinDefinition], primitives: [DrawPrimitive], onPrimitives: [DrawPrimitive]? = nil) {
        self.name = name
        self.refPrefix = refPrefix
        self.defaultValue = defaultValue
        self.pins = pins
        self.primitives = primitives
        self.onPrimitives = onPrimitives
        var b = Rect2.empty
        for pin in pins { b.include(pin.position) }
        for prim in primitives {
            for p in prim.boundsPoints() { b.include(p) }
        }
        self.localBounds = b
    }
}

/// IEC 60617-style symbol library. Every coordinate is copied verbatim from the C# library,
/// so shared files render pixel-identically. Grid is 5; all pins sit on the grid.
public enum SymbolLibrary {
    private static func L(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> DrawPrimitive { .line(Vec2(x1, y1), Vec2(x2, y2)) }
    private static func V(_ x: Double, _ y: Double) -> Vec2 { Vec2(x, y) }

    public static let all: [SymbolDefinition] = build()
    private static let byName: [String: SymbolDefinition] = Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0) })

    public static func get(_ name: String) -> SymbolDefinition {
        guard let def = byName[name] else { fatalError("Unknown symbol: \(name)") }
        return def
    }

    public static func find(_ name: String) -> SymbolDefinition? { byName[name] }

    private static func build() -> [SymbolDefinition] {
        var list: [SymbolDefinition] = []
        let d = 8.0 / 2.0.squareRoot()

        list.append(SymbolDefinition(name: "Resistor", refPrefix: "R", defaultValue: "10k",
            pins: [PinDefinition("1", V(-20, 0)), PinDefinition("2", V(20, 0))],
            primitives: [
                L(-20, 0, -10, 0), L(10, 0, 20, 0),
                .poly([V(-10, -4), V(10, -4), V(10, 4), V(-10, 4)], closed: true, filled: false),
            ]))

        list.append(SymbolDefinition(name: "Capacitor", refPrefix: "C", defaultValue: "100n",
            pins: [PinDefinition("1", V(-20, 0)), PinDefinition("2", V(20, 0))],
            primitives: [
                L(-20, 0, -2, 0), L(2, 0, 20, 0),
                L(-2, -7, -2, 7), L(2, -7, 2, 7),
            ]))

        list.append(SymbolDefinition(name: "Inductor", refPrefix: "L", defaultValue: "10m",
            pins: [PinDefinition("1", V(-20, 0)), PinDefinition("2", V(20, 0))],
            primitives: [
                .arc(center: V(-15, 0), radius: 5, startDeg: 180, endDeg: 360),
                .arc(center: V(-5, 0), radius: 5, startDeg: 180, endDeg: 360),
                .arc(center: V(5, 0), radius: 5, startDeg: 180, endDeg: 360),
                .arc(center: V(15, 0), radius: 5, startDeg: 180, endDeg: 360),
            ]))

        list.append(SymbolDefinition(name: "Diode", refPrefix: "D", defaultValue: "1N4148",
            pins: [PinDefinition("A", V(-20, 0)), PinDefinition("K", V(20, 0))],
            primitives: [
                L(-20, 0, -6, 0), L(6, 0, 20, 0),
                .poly([V(-6, -6), V(-6, 6), V(6, 0)], closed: true, filled: true),
                L(6, -6, 6, 6),
            ]))

        list.append(SymbolDefinition(name: "Ground", refPrefix: "GND", defaultValue: "",
            pins: [PinDefinition("1", V(0, 0))],
            primitives: [
                L(0, 0, 0, 6),
                L(-8, 6, 8, 6), L(-5, 9, 5, 9), L(-2, 12, 2, 12),
            ]))

        list.append(SymbolDefinition(name: "VSource", refPrefix: "V", defaultValue: "5V",
            pins: [PinDefinition("+", V(0, -20)), PinDefinition("-", V(0, 20))],
            primitives: [
                L(0, -20, 0, -10), L(0, 10, 0, 20),
                .circle(center: V(0, 0), radius: 10, filled: false),
                .text("+", at: V(0, -4), size: 6),
                .text("\u{2212}", at: V(0, 5), size: 6),
            ]))

        list.append(SymbolDefinition(name: "ACSource", refPrefix: "V", defaultValue: "5V 50Hz",
            pins: [PinDefinition("+", V(0, -20)), PinDefinition("-", V(0, 20))],
            primitives: [
                L(0, -20, 0, -10), L(0, 10, 0, 20),
                .circle(center: V(0, 0), radius: 10, filled: false),
                .arc(center: V(-2.5, 0), radius: 2.5, startDeg: 180, endDeg: 360),
                .arc(center: V(2.5, 0), radius: 2.5, startDeg: 0, endDeg: 180),
            ]))

        list.append(SymbolDefinition(name: "Battery", refPrefix: "BT", defaultValue: "9V",
            pins: [PinDefinition("+", V(0, -20)), PinDefinition("-", V(0, 20))],
            primitives: [
                L(0, -20, 0, -2), L(0, 2, 0, 20),
                L(-8, -2, 8, -2), L(-4, 2, 4, 2),
                .text("+", at: V(7, -7), size: 5),
            ]))

        list.append(SymbolDefinition(name: "Lamp", refPrefix: "E", defaultValue: "12V 5W",
            pins: [PinDefinition("1", V(-20, 0)), PinDefinition("2", V(20, 0))],
            primitives: [
                L(-20, 0, -8, 0), L(8, 0, 20, 0),
                .circle(center: V(0, 0), radius: 8, filled: false),
                L(-d, -d, d, d), L(-d, d, d, -d),
            ]))

        list.append(SymbolDefinition(name: "Switch", refPrefix: "S", defaultValue: "",
            pins: [PinDefinition("1", V(-20, 0)), PinDefinition("2", V(20, 0))],
            primitives: [
                L(-20, 0, -10, 0), L(10, 0, 20, 0),
                .circle(center: V(-10, 0), radius: 1.5, filled: false),
                .circle(center: V(10, 0), radius: 1.5, filled: false),
                L(-8.7, -0.8, 8, -8),
            ],
            onPrimitives: [
                L(-20, 0, -10, 0), L(10, 0, 20, 0),
                .circle(center: V(-10, 0), radius: 1.5, filled: false),
                .circle(center: V(10, 0), radius: 1.5, filled: false),
                L(-8.6, -0.7, 8.6, -0.7),
            ]))

        list.append(SymbolDefinition(name: "Fuse", refPrefix: "F", defaultValue: "1A",
            pins: [PinDefinition("1", V(-20, 0)), PinDefinition("2", V(20, 0))],
            primitives: [
                L(-20, 0, 20, 0),
                .poly([V(-10, -4), V(10, -4), V(10, 4), V(-10, 4)], closed: true, filled: false),
            ]))

        list.append(SymbolDefinition(name: "NPN", refPrefix: "Q", defaultValue: "BC547",
            pins: [PinDefinition("B", V(-20, 0)), PinDefinition("C", V(10, -20)), PinDefinition("E", V(10, 20))],
            primitives: [
                L(-20, 0, -4, 0),
                L(-4, -10, -4, 10),
                L(-4, -4, 10, -14), L(10, -14, 10, -20),
                L(-4, 4, 10, 14), L(10, 14, 10, 20),
                .poly([V(10, 14), V(4.8, 12.7), V(7.1, 9.4)], closed: true, filled: true),
            ]))

        return list
    }
}
