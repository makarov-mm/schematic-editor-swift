import Foundation

/// 2D point/vector in schematic units. Y grows downward, exactly like the WPF original,
/// so every coordinate in the shared .schem.json files means the same thing on both platforms.
public struct Vec2: Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = Vec2(0, 0)

    public static func + (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x + b.x, a.y + b.y) }
    public static func - (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x - b.x, a.y - b.y) }
    public static func * (a: Vec2, s: Double) -> Vec2 { Vec2(a.x * s, a.y * s) }

    public func distance(to other: Vec2) -> Double { ((x - other.x) * (x - other.x) + (y - other.y) * (y - other.y)).squareRoot() }

    /// Quantized key (0.1 units) for point-coincidence lookups. Two points connect electrically iff their keys match.
    public func key() -> Key { Key(kx: Int((x * 10).rounded()), ky: Int((y * 10).rounded())) }

    public struct Key: Hashable, Sendable {
        public let kx: Int
        public let ky: Int
    }

    public func snap(_ grid: Double) -> Vec2 { Vec2((x / grid).rounded() * grid, (y / grid).rounded() * grid) }

    public func distanceToSegment(_ a: Vec2, _ b: Vec2) -> Double {
        let ab = b - a
        let len2 = ab.x * ab.x + ab.y * ab.y
        if len2 < 1e-12 { return distance(to: a) }
        let t = max(0, min(1, ((x - a.x) * ab.x + (y - a.y) * ab.y) / len2))
        return distance(to: a + ab * t)
    }

    public func isOnSegment(_ a: Vec2, _ b: Vec2, tolerance: Double = 0.05) -> Bool { distanceToSegment(a, b) <= tolerance }
}

public struct Rect2: Sendable {
    public var minX: Double
    public var minY: Double
    public var maxX: Double
    public var maxY: Double

    public init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
        self.minX = minX
        self.minY = minY
        self.maxX = maxX
        self.maxY = maxY
    }

    public static let empty = Rect2(minX: .greatestFiniteMagnitude, minY: .greatestFiniteMagnitude, maxX: -.greatestFiniteMagnitude, maxY: -.greatestFiniteMagnitude)

    public var isEmpty: Bool { minX > maxX }
    public var width: Double { max(0, maxX - minX) }
    public var height: Double { max(0, maxY - minY) }

    public mutating func include(_ p: Vec2) {
        minX = min(minX, p.x)
        minY = min(minY, p.y)
        maxX = max(maxX, p.x)
        maxY = max(maxY, p.y)
    }

    public func union(_ other: Rect2) -> Rect2 {
        if isEmpty { return other }
        if other.isEmpty { return self }
        return Rect2(minX: min(minX, other.minX), minY: min(minY, other.minY), maxX: max(maxX, other.maxX), maxY: max(maxY, other.maxY))
    }

    public func inflated(_ d: Double) -> Rect2 { Rect2(minX: minX - d, minY: minY - d, maxX: maxX + d, maxY: maxY + d) }

    public func contains(_ p: Vec2) -> Bool { p.x >= minX && p.x <= maxX && p.y >= minY && p.y <= maxY }

    public func intersects(_ other: Rect2) -> Bool { !(other.minX > maxX || other.maxX < minX || other.minY > maxY || other.maxY < minY) }
}

/// Clockwise rotation in 90-degree steps (screen coordinates, Y down).
public enum Rotation: Int, Codable, Sendable, CaseIterable {
    case r0 = 0
    case r90 = 90
    case r180 = 180
    case r270 = 270

    public var next: Rotation {
        switch self {
        case .r0: return .r90
        case .r90: return .r180
        case .r180: return .r270
        case .r270: return .r0
        }
    }
}

public enum Transform2 {
    /// Mirror (X axis) first, then rotate clockwise, then translate — identical order to the C# core.
    public static func apply(_ p: Vec2, rotation: Rotation, mirror: Bool, translation: Vec2) -> Vec2 {
        var v = mirror ? Vec2(-p.x, p.y) : p
        switch rotation {
        case .r0: break
        case .r90: v = Vec2(-v.y, v.x)
        case .r180: v = Vec2(-v.x, -v.y)
        case .r270: v = Vec2(v.y, -v.x)
        }
        return v + translation
    }
}
