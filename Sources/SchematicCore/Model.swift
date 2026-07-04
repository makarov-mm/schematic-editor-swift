import Foundation

public class SchematicElement {
    public internal(set) var id: Int = 0
    public init() {}
}

public final class SymbolInstance: SchematicElement {
    public let definition: SymbolDefinition
    public var position: Vec2
    public var rotation: Rotation = .r0
    public var mirror = false
    public var refDes: String = "?"
    public var value: String = ""
    /// Interactive state (closed for switches). Persisted; toggled at run time.
    public var stateOn = false

    public init(definition: SymbolDefinition, position: Vec2) {
        self.definition = definition
        self.position = position
        self.value = definition.defaultValue
        super.init()
    }

    public func toWorld(_ local: Vec2) -> Vec2 { Transform2.apply(local, rotation: rotation, mirror: mirror, translation: position) }

    public func worldPins() -> [(pin: PinDefinition, world: Vec2)] { definition.pins.map { ($0, toWorld($0.position)) } }

    public var activePrimitives: [DrawPrimitive] { stateOn ? (definition.onPrimitives ?? definition.primitives) : definition.primitives }

    public var bounds: Rect2 {
        let b = definition.localBounds
        var r = Rect2.empty
        for corner in [Vec2(b.minX, b.minY), Vec2(b.maxX, b.minY), Vec2(b.minX, b.maxY), Vec2(b.maxX, b.maxY)] {
            r.include(toWorld(corner))
        }
        return r
    }
}

public final class Wire: SchematicElement {
    public var points: [Vec2]

    public init(_ points: [Vec2]) {
        self.points = points
        super.init()
    }

    public func segments() -> [(a: Vec2, b: Vec2)] {
        guard points.count >= 2 else { return [] }
        return (0..<(points.count - 1)).map { (points[$0], points[$0 + 1]) }
    }

    public var bounds: Rect2 {
        var r = Rect2.empty
        for p in points { r.include(p) }
        return r
    }
}

public final class SchematicDocument {
    public static let grid: Double = 5

    public private(set) var elements: [SchematicElement] = []
    public var changed: (() -> Void)?
    private var nextId = 1

    public init() {}

    public var symbols: [SymbolInstance] { elements.compactMap { $0 as? SymbolInstance } }
    public var wires: [Wire] { elements.compactMap { $0 as? Wire } }

    public func add(_ element: SchematicElement) {
        if element.id == 0 {
            element.id = nextId
            nextId += 1
        } else {
            nextId = max(nextId, element.id + 1)
        }
        elements.append(element)
        changed?()
    }

    public func remove(_ element: SchematicElement) {
        elements.removeAll { $0 === element }
        changed?()
    }

    public func notifyChanged() { changed?() }

    public func find(byId id: Int) -> SchematicElement? { elements.first { $0.id == id } }

    /// Next free reference designator for a prefix: R1, R2, ...
    public func nextRefDes(prefix: String) -> String {
        var n = 1
        let used = Set(symbols.map(\.refDes))
        while used.contains("\(prefix)\(n)") { n += 1 }
        return "\(prefix)\(n)"
    }

    public func allPinPoints() -> [Vec2] { symbols.flatMap { $0.worldPins().map(\.world) } }

    public func findPinNear(_ point: Vec2, tolerance: Double) -> Vec2? {
        var best: Vec2?
        var bestDistance = tolerance
        for pin in allPinPoints() {
            let dist = pin.distance(to: point)
            if dist <= bestDistance {
                bestDistance = dist
                best = pin
            }
        }
        return best
    }

    /// A point is a valid wire endpoint when it hits a pin or lies on an existing wire.
    public func isConnectionPoint(_ point: Vec2) -> Bool {
        let key = point.key()
        for pin in allPinPoints() where pin.key() == key { return true }
        for wire in wires {
            if wire.points.contains(where: { $0.key() == key }) { return true }
            for seg in wire.segments() where point.isOnSegment(seg.a, seg.b) { return true }
        }
        return false
    }

    public var contentBounds: Rect2 {
        var r = Rect2.empty
        for s in symbols { r = r.union(s.bounds) }
        for w in wires { r = r.union(w.bounds) }
        return r
    }
}

// MARK: - Undo

public protocol EditCommand {
    var name: String { get }
    func apply(to doc: SchematicDocument)
    func revert(in doc: SchematicDocument)
}

public final class UndoStack {
    private let doc: SchematicDocument
    private var undoList: [EditCommand] = []
    private var redoList: [EditCommand] = []

    public init(_ doc: SchematicDocument) { self.doc = doc }

    public var canUndo: Bool { !undoList.isEmpty }
    public var canRedo: Bool { !redoList.isEmpty }

    public func push(_ command: EditCommand) {
        command.apply(to: doc)
        undoList.append(command)
        redoList.removeAll()
    }

    public func undo() {
        guard let command = undoList.popLast() else { return }
        command.revert(in: doc)
        redoList.append(command)
    }

    public func redo() {
        guard let command = redoList.popLast() else { return }
        command.apply(to: doc)
        undoList.append(command)
    }
}

public final class AddElementCommand: EditCommand {
    public let name = "Add"
    private let element: SchematicElement

    public init(_ element: SchematicElement) { self.element = element }

    public func apply(to doc: SchematicDocument) { doc.add(element) }
    public func revert(in doc: SchematicDocument) { doc.remove(element) }
}

public final class DeleteElementsCommand: EditCommand {
    public let name = "Delete"
    private let victims: [SchematicElement]

    public init(_ victims: [SchematicElement]) { self.victims = victims }

    public func apply(to doc: SchematicDocument) { for v in victims { doc.remove(v) } }
    public func revert(in doc: SchematicDocument) { for v in victims { doc.add(v) } }
}

public final class MoveElementsCommand: EditCommand {
    public let name = "Move"
    private let elements: [SchematicElement]
    private let delta: Vec2

    public init(_ elements: [SchematicElement], delta: Vec2) {
        self.elements = elements
        self.delta = delta
    }

    private func shift(_ d: Vec2, in doc: SchematicDocument) {
        for e in elements {
            if let s = e as? SymbolInstance { s.position = s.position + d }
            if let w = e as? Wire { w.points = w.points.map { $0 + d } }
        }
        doc.notifyChanged()
    }

    public func apply(to doc: SchematicDocument) { shift(delta, in: doc) }
    public func revert(in doc: SchematicDocument) { shift(Vec2(-delta.x, -delta.y), in: doc) }
}

public final class RotateSymbolCommand: EditCommand {
    public let name = "Rotate"
    private let symbol: SymbolInstance

    public init(_ symbol: SymbolInstance) { self.symbol = symbol }

    public func apply(to doc: SchematicDocument) {
        symbol.rotation = symbol.rotation.next
        doc.notifyChanged()
    }

    public func revert(in doc: SchematicDocument) {
        symbol.rotation = symbol.rotation.next.next.next
        doc.notifyChanged()
    }
}

public final class MirrorSymbolCommand: EditCommand {
    public let name = "Mirror"
    private let symbol: SymbolInstance

    public init(_ symbol: SymbolInstance) { self.symbol = symbol }

    public func apply(to doc: SchematicDocument) {
        symbol.mirror.toggle()
        doc.notifyChanged()
    }

    public func revert(in doc: SchematicDocument) {
        symbol.mirror.toggle()
        doc.notifyChanged()
    }
}

public final class SetPropertiesCommand: EditCommand {
    public let name = "Properties"
    private let symbol: SymbolInstance
    private let newRefDes: String
    private let newValue: String
    private var oldRefDes = ""
    private var oldValue = ""

    public init(_ symbol: SymbolInstance, refDes: String, value: String) {
        self.symbol = symbol
        self.newRefDes = refDes
        self.newValue = value
    }

    public func apply(to doc: SchematicDocument) {
        oldRefDes = symbol.refDes
        oldValue = symbol.value
        symbol.refDes = newRefDes
        symbol.value = newValue
        doc.notifyChanged()
    }

    public func revert(in doc: SchematicDocument) {
        symbol.refDes = oldRefDes
        symbol.value = oldValue
        doc.notifyChanged()
    }
}

public final class CompositeCommand: EditCommand {
    public let name: String
    private let commands: [EditCommand]

    public init(_ name: String, _ commands: [EditCommand]) {
        self.name = name
        self.commands = commands
    }

    public func apply(to doc: SchematicDocument) { for c in commands { c.apply(to: doc) } }
    public func revert(in doc: SchematicDocument) { for c in commands.reversed() { c.revert(in: doc) } }
}
