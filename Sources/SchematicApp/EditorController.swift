import AppKit
import SwiftUI
import SchematicCore

enum EditorTool {
    case select
    case wire
    case place(String)
}

final class ScopeProbe {
    let label: String
    let color: NSColor
    let anchor: Vec2
    let symbol: SymbolInstance?
    var node = -1
    var times: [Float] = []
    var values: [Float] = []
    var lastValue: Double = 0

    var isCurrent: Bool { symbol != nil }

    init(label: String, color: NSColor, anchor: Vec2 = .zero, symbol: SymbolInstance? = nil) {
        self.label = label
        self.color = color
        self.anchor = anchor
        self.symbol = symbol
    }

    func append(_ t: Double, _ v: Double) {
        times.append(Float(t))
        values.append(Float(v))
        lastValue = v
        if times.count > 130_000 {
            times.removeFirst(30_000)
            values.removeFirst(30_000)
        }
    }

    func clear() {
        times.removeAll()
        values.removeAll()
    }
}

/// Owns the document, undo stack, netlist, probes and the real-time simulation loop.
/// SwiftUI observes the published state; the AppKit canvas talks to it directly.
final class EditorController: ObservableObject {
    static let simDt = 5e-5
    static let probePalette: [NSColor] = [
        NSColor(red: 0.90, green: 0.10, blue: 0.29, alpha: 1),
        NSColor(red: 0.24, green: 0.71, blue: 0.29, alpha: 1),
        NSColor(red: 0.26, green: 0.39, blue: 0.85, alpha: 1),
        NSColor(red: 0.96, green: 0.51, blue: 0.19, alpha: 1),
        NSColor(red: 0.57, green: 0.12, blue: 0.71, alpha: 1),
        NSColor(red: 0.00, green: 0.66, blue: 0.71, alpha: 1),
        NSColor(red: 0.94, green: 0.20, blue: 0.90, alpha: 1),
        NSColor(red: 0.60, green: 0.39, blue: 0.14, alpha: 1),
    ]

    private(set) var document = SchematicDocument()
    private(set) var undo: UndoStack
    private(set) var netlist = NetlistResult()
    private(set) var simulator: CircuitSimulator?
    private(set) var probes: [ScopeProbe] = []

    @Published var tool: EditorTool = .select
    @Published var isRunning = false
    @Published var probeArmed = false
    @Published var status = "Ready."
    @Published var canUndo = false
    @Published var canRedo = false
    @Published var probesExist = false
    @Published var editingSymbol: SymbolInstance?

    var canvasNeedsDisplay: (() -> Void)?
    var scopeNeedsDisplay: (() -> Void)?
    var zoomToFitRequested: (() -> Void)?
    var placeSymbol: ((String) -> Void)?
    var rotateAction: (() -> Void)?
    var mirrorAction: (() -> Void)?

    private var timer: Timer?
    private var lastTick = Date()

    init() {
        undo = UndoStack(document)
        hookDocument()
    }

    private func hookDocument() {
        document.changed = { [weak self] in self?.onDocumentChanged() }
        onDocumentChanged()
    }

    private func onDocumentChanged() {
        if isRunning { stopSimulation() }
        netlist = NetlistExtractor.extract(document)
        canUndo = undo.canUndo
        canRedo = undo.canRedo
        revalidateProbes()
        canvasNeedsDisplay?()
    }

    // MARK: - Files

    func newDocument() {
        setDocument(SchematicDocument(), probes: [])
        status = "New schematic."
    }

    func openDocument() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let loaded = try JsonIO.load(from: url)
            setDocument(loaded.document, probes: loaded.probes)
            status = "Opened \(url.lastPathComponent)."
        } catch {
            status = "Open failed: \(error.localizedDescription)"
        }
    }

    func saveDocument() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "schematic.schem.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try JsonIO.save(document, to: url, probes: exportProbes())
            status = "Saved \(url.lastPathComponent)."
        } catch {
            status = "Save failed: \(error.localizedDescription)"
        }
    }

    private func setDocument(_ doc: SchematicDocument, probes saved: [ProbeInfo]) {
        stopSimulation()
        document = doc
        undo = UndoStack(doc)
        probes.removeAll()
        hookDocument()
        loadProbes(saved)
        zoomToFitRequested?()
    }

    // MARK: - Probes

    func loadProbes(_ saved: [ProbeInfo]) {
        probes.removeAll()
        for info in saved {
            let color = Self.probePalette[probes.count % Self.probePalette.count]
            if info.type == "I" {
                if let s = document.find(byId: info.symbolId) as? SymbolInstance, s.definition.pins.count == 2 {
                    probes.append(ScopeProbe(label: "I(\(s.refDes))", color: color, symbol: s))
                }
            } else {
                let anchor = Vec2(info.x, info.y)
                if let net = netlist.findNet(at: anchor) {
                    probes.append(ScopeProbe(label: "V(\(net.name))", color: color, anchor: anchor))
                }
            }
        }
        probesExist = !probes.isEmpty
        scopeNeedsDisplay?()
    }

    func exportProbes() -> [ProbeInfo] {
        probes.map { p in
            p.isCurrent ? ProbeInfo(type: "I", symbolId: p.symbol!.id) : ProbeInfo(type: "V", x: p.anchor.x, y: p.anchor.y)
        }
    }

    /// Place or remove a probe at a world point. Works in edit mode and in run mode.
    func probeClick(at world: Vec2, hitSymbol: SymbolInstance?) {
        if let near = probes.first(where: { p in
            p.isCurrent ? p.symbol!.position.distance(to: world) <= 8 : p.anchor.distance(to: world) <= 8
        }) {
            probes.removeAll { $0 === near }
            status = "Removed probe \(near.label)."
            probesExist = !probes.isEmpty
            canvasNeedsDisplay?()
            scopeNeedsDisplay?()
            return
        }

        let color = Self.probePalette[probes.count % Self.probePalette.count]
        if let sym = hitSymbol, sym.definition.pins.count == 2, sym.definition.name != "Ground" {
            probes.append(ScopeProbe(label: "I(\(sym.refDes))", color: color, symbol: sym))
            status = "Current probe on \(sym.refDes)."
        } else {
            let anchor = document.findPinNear(world, tolerance: 8) ?? world.snap(SchematicDocument.grid)
            guard let net = netlist.findNet(at: anchor) else {
                status = "No net here — click a wire or a pin."
                return
            }
            let probe = ScopeProbe(label: "V(\(net.name))", color: color, anchor: anchor)
            probe.node = simulator?.resolveNode(anchor) ?? -1
            probes.append(probe)
            status = "Voltage probe on \(net.name)."
        }
        probesExist = true
        canvasNeedsDisplay?()
        scopeNeedsDisplay?()
    }

    func clearProbes() {
        probes.removeAll()
        probesExist = false
        canvasNeedsDisplay?()
        scopeNeedsDisplay?()
    }

    private func revalidateProbes() {
        var changed = false
        probes.removeAll { p in
            if p.isCurrent {
                let dead = !document.symbols.contains { $0 === p.symbol }
                changed = changed || dead
                return dead
            }
            let dead = netlist.findNet(at: p.anchor) == nil
            changed = changed || dead
            return dead
        }
        if changed {
            probesExist = !probes.isEmpty
            scopeNeedsDisplay?()
        }
    }

    // MARK: - Simulation

    var simTime: Double { simulator?.time ?? 0 }

    @discardableResult
    func startSimulation() -> Bool {
        if isRunning { return true }
        var problems: [String] = []
        guard let sim = CircuitSimulator.build(document, netlist, problems: &problems) else {
            status = problems.joined(separator: " ")
            return false
        }
        for warning in sim.warnings { status = warning }

        simulator = sim
        sim.reset()
        for p in probes {
            if !p.isCurrent { p.node = sim.resolveNode(p.anchor) ?? -1 }
            p.clear()
        }
        tool = .select
        isRunning = true
        lastTick = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.tick() }
        status = "Simulation running."
        canvasNeedsDisplay?()
        return true
    }

    func stopSimulation() {
        guard isRunning else { return }
        timer?.invalidate()
        timer = nil
        simulator = nil
        isRunning = false
        status = "Simulation stopped."
        canvasNeedsDisplay?()
        scopeNeedsDisplay?()
    }

    func resetSimulation() {
        simulator?.reset()
        for p in probes { p.clear() }
        canvasNeedsDisplay?()
        scopeNeedsDisplay?()
    }

    private func tick() {
        guard let sim = simulator else { return }
        let elapsed = min(Date().timeIntervalSince(lastTick), 0.08)
        lastTick = Date()
        let steps = Int((elapsed / Self.simDt).rounded())

        do {
            for _ in 0..<steps {
                try sim.step(Self.simDt)
                for p in probes {
                    let v: Double
                    if p.isCurrent { v = sim.current(of: p.symbol!) ?? 0 }
                    else { v = p.node >= 0 ? sim.nodeVoltage(p.node) : 0 }
                    p.append(sim.time, v)
                }
            }
        } catch let error as SimulationError {
            status = "Simulation stopped: \(error.message)"
            stopSimulation()
            return
        } catch {
            stopSimulation()
            return
        }

        canvasNeedsDisplay?()
        scopeNeedsDisplay?()
    }

    // MARK: - Edit actions used by toolbar

    func performUndo() {
        undo.undo()
        document.notifyChanged()
    }

    func performRedo() {
        undo.redo()
        document.notifyChanged()
    }

    func applyProperties(to sym: SymbolInstance, refDes: String, value: String) {
        undo.push(SetPropertiesCommand(sym, refDes: refDes, value: value))
    }

    func ercReport() -> String {
        let issues = ErcChecker.check(document, netlist)
        if issues.isEmpty { return "ERC: no issues." }
        return issues.map { "\($0.severity == .error ? "E" : "W"): \($0.message)" }.joined(separator: "\n")
    }
}
