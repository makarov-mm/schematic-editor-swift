import AppKit
import SwiftUI
import SchematicCore

/// The schematic canvas: a plain NSView with custom drawing and mouse handling — the
/// closest macOS analogue of the WPF OnRender approach used by the original editor.
final class SchematicNSView: NSView {
    unowned let controller: EditorController

    private var zoom: CGFloat = 3
    private var pan = CGPoint(x: 120, y: 300)
    private var cursorWorld = Vec2.zero
    private var selection: [SchematicElement] = []
    private var ghost: SymbolInstance?
    private var wirePoints: [Vec2] = []
    private var dragStart: Vec2?
    private var dragDelta = Vec2.zero
    private var rubberStart: Vec2?
    private var panning = false
    private var trackingArea: NSTrackingArea?

    private let hitTolerance: Double = 4

    init(controller: EditorController) {
        self.controller = controller
        super.init(frame: .zero)
        wantsLayer = true
        controller.canvasNeedsDisplay = { [weak self] in self?.needsDisplay = true }
        controller.zoomToFitRequested = { [weak self] in self?.zoomToFit() }
        controller.placeSymbol = { [weak self] name in self?.beginPlacing(name) }
        controller.rotateAction = { [weak self] in self?.rotateSelectionOrGhost() }
        controller.mirrorAction = { [weak self] in self?.mirrorSelectionOrGhost() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }   // Y down, like the schematic coordinate system

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    // MARK: - Coordinates

    private func toWorld(_ p: CGPoint) -> Vec2 { Vec2(Double((p.x - pan.x) / zoom), Double((p.y - pan.y) / zoom)) }
    private func toScreen(_ w: Vec2) -> CGPoint { CGPoint(x: CGFloat(w.x) * zoom + pan.x, y: CGFloat(w.y) * zoom + pan.y) }

    func zoomToFit() {
        let content = controller.document.contentBounds
        guard !content.isEmpty, bounds.width > 10 else {
            zoom = 3
            pan = CGPoint(x: bounds.midX, y: bounds.midY)
            needsDisplay = true
            return
        }
        let padded = content.inflated(25)
        let scaleX = bounds.width / CGFloat(padded.width)
        let scaleY = bounds.height / CGFloat(padded.height)
        zoom = min(max(min(scaleX, scaleY), 0.05), 100)
        pan = CGPoint(
            x: bounds.midX - CGFloat(padded.minX + padded.width / 2) * zoom,
            y: bounds.midY - CGFloat(padded.minY + padded.height / 2) * zoom)
        needsDisplay = true
    }

    // MARK: - Hit testing

    private func hitElement(at world: Vec2) -> SchematicElement? {
        for sym in controller.document.symbols.reversed() where sym.bounds.inflated(2).contains(world) {
            return sym
        }
        for wire in controller.document.wires.reversed() {
            for seg in wire.segments() where world.distanceToSegment(seg.a, seg.b) <= hitTolerance {
                return wire
            }
        }
        return nil
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let world = toWorld(convert(event.locationInWindow, from: nil))
        cursorWorld = world

        if event.modifierFlags.contains(.option) || panning {
            return // option-drag pans in mouseDragged
        }

        if controller.probeArmed {
            controller.probeClick(at: world, hitSymbol: hitElement(at: world) as? SymbolInstance)
            return
        }

        if controller.isRunning {
            if let sym = hitElement(at: world) as? SymbolInstance, sym.definition.name == "Switch" {
                sym.stateOn.toggle()   // live toggle: no undo entry, no rebuild
                needsDisplay = true
            }
            return
        }

        switch controller.tool {
        case .place:
            commitPlacement(at: world)
        case .wire:
            wireClick(at: world)
        case .select:
            if event.clickCount == 2, let sym = hitElement(at: world) as? SymbolInstance {
                controller.editingSymbol = sym
                return
            }
            selectClick(at: world, extend: event.modifierFlags.contains(.shift))
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        if controller.isRunning { return }
        if case .wire = controller.tool, !wirePoints.isEmpty {
            wirePoints.removeAll()
        } else {
            controller.tool = .select
            ghost = nil
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if event.modifierFlags.contains(.option) || panning {
            pan.x += event.deltaX
            pan.y += event.deltaY
            needsDisplay = true
            return
        }
        let world = toWorld(point)
        cursorWorld = world

        if controller.isRunning || controller.probeArmed { return }

        if case .select = controller.tool {
            if let start = dragStart, !selection.isEmpty {
                dragDelta = (world - start).snap(SchematicDocument.grid)
            }
            needsDisplay = true
        }
    }

    override func otherMouseDragged(with event: NSEvent) {
        pan.x += event.deltaX
        pan.y += event.deltaY
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let world = toWorld(convert(event.locationInWindow, from: nil))

        if let start = rubberStart {
            var rect = Rect2.empty
            rect.include(start)
            rect.include(world)
            selection = controller.document.symbols.filter { rect.intersects($0.bounds) }
            selection += controller.document.wires.filter { rect.intersects($0.bounds) } as [SchematicElement]
            rubberStart = nil
            needsDisplay = true
        }

        if dragStart != nil, dragDelta.x != 0 || dragDelta.y != 0 {
            controller.undo.push(MoveElementsCommand(selection, delta: dragDelta))
        }
        dragStart = nil
        dragDelta = .zero
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        let world = toWorld(convert(event.locationInWindow, from: nil))
        cursorWorld = world

        if let sim = controller.simulator {
            var extra = ""
            if let sym = hitElement(at: world) as? SymbolInstance, let current = sim.current(of: sym) {
                extra = "   \(sym.refDes): \(Self.formatSi(current, "A"))"
            } else if let volts = sim.voltage(at: controller.document.findPinNear(world, tolerance: hitTolerance * 2) ?? world.snap(SchematicDocument.grid)) {
                extra = "   \(Self.formatSi(volts, "V"))"
            }
            controller.status = String(format: "t %.3f s%@", sim.time, extra)
        }

        if ghost != nil {
            ghost?.position = world.snap(SchematicDocument.grid)
            needsDisplay = true
        }
        if case .wire = controller.tool { needsDisplay = true }
    }

    override func scrollWheel(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let world = toWorld(point)

        if controller.isRunning && event.modifierFlags.contains(.shift) {
            if let sym = hitElement(at: world) as? SymbolInstance,
               sym.definition.name == "Resistor" || sym.definition.name == "Capacitor" || sym.definition.name == "Inductor" {
                tweakValue(sym, up: event.scrollingDeltaY > 0 || event.deltaY > 0)
                return
            }
        }

        let delta = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : event.deltaY
        let factor: CGFloat = delta > 0 ? 1.15 : 1 / 1.15
        let newZoom = min(max(zoom * factor, 0.05), 100)
        pan.x = point.x - CGFloat(world.x) * newZoom
        pan.y = point.y - CGFloat(world.y) * newZoom
        zoom = newZoom
        needsDisplay = true
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        if controller.isRunning {
            switch event.keyCode {
            case 53: controller.stopSimulation()          // Esc
            case 3: zoomToFit()                            // F
            default: break
            }
            return
        }

        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "z" where event.modifierFlags.contains(.shift): controller.performRedo()
            case "z": controller.performUndo()
            case "a":
                selection = controller.document.symbols + (controller.document.wires as [SchematicElement])
                needsDisplay = true
            default: super.keyDown(with: event)
            }
            return
        }

        switch event.keyCode {
        case 53: // Esc
            if controller.probeArmed { controller.probeArmed = false }
            else if case .wire = controller.tool, !wirePoints.isEmpty { wirePoints.removeAll() }
            else {
                controller.tool = .select
                ghost = nil
                selection.removeAll()
            }
            needsDisplay = true
        case 51, 117: // Delete / Forward delete
            if !selection.isEmpty {
                controller.undo.push(DeleteElementsCommand(selection))
                selection.removeAll()
            }
        case 15: rotateSelectionOrGhost()  // R
        case 46: mirrorSelectionOrGhost()  // M
        case 3: zoomToFit()                // F
        case 13: controller.tool = .wire   // W
        default: super.keyDown(with: event)
        }
    }

    func rotateSelectionOrGhost() {
        if let ghost {
            ghost.rotation = ghost.rotation.next
            needsDisplay = true
            return
        }
        let symbols = selection.compactMap { $0 as? SymbolInstance }
        guard !symbols.isEmpty else { return }
        controller.undo.push(CompositeCommand("Rotate", symbols.map(RotateSymbolCommand.init)))
    }

    func mirrorSelectionOrGhost() {
        if let ghost {
            ghost.mirror.toggle()
            needsDisplay = true
            return
        }
        let symbols = selection.compactMap { $0 as? SymbolInstance }
        guard !symbols.isEmpty else { return }
        controller.undo.push(CompositeCommand("Mirror", symbols.map(MirrorSymbolCommand.init)))
    }

    func beginPlacing(_ symbolName: String) {
        controller.tool = .place(symbolName)
        selection.removeAll()
        wirePoints.removeAll()
        ghost = SymbolInstance(definition: SymbolLibrary.get(symbolName), position: cursorWorld.snap(SchematicDocument.grid))
        needsDisplay = true
    }

    // MARK: - Tool actions

    private func commitPlacement(at world: Vec2) {
        guard case .place(let name) = controller.tool, let ghost else { return }
        let inst = SymbolInstance(definition: ghost.definition, position: world.snap(SchematicDocument.grid))
        inst.rotation = ghost.rotation
        inst.mirror = ghost.mirror
        inst.refDes = controller.document.nextRefDes(prefix: ghost.definition.refPrefix)
        controller.undo.push(AddElementCommand(inst))
        self.ghost = SymbolInstance(definition: SymbolLibrary.get(name), position: inst.position)
        self.ghost?.rotation = inst.rotation
        self.ghost?.mirror = inst.mirror
    }

    private func wireClick(at world: Vec2) {
        let snapped = controller.document.findPinNear(world, tolerance: hitTolerance * 2) ?? world.snap(SchematicDocument.grid)

        if wirePoints.isEmpty {
            guard controller.document.isConnectionPoint(snapped) else {
                controller.status = "A wire must start on a pin or an existing wire."
                return
            }
            wirePoints.append(snapped)
            return
        }

        // Orthogonal L-shaped extension via the corner.
        let last = wirePoints[wirePoints.count - 1]
        var pts = wirePoints
        if snapped.x != last.x && snapped.y != last.y {
            pts.append(Vec2(snapped.x, last.y))
        }
        pts.append(snapped)

        if controller.document.isConnectionPoint(snapped) {
            controller.undo.push(AddElementCommand(Wire(pts)))
            wirePoints.removeAll()
        } else {
            wirePoints = pts
        }
        needsDisplay = true
    }

    private func selectClick(at world: Vec2, extend: Bool) {
        if let hit = hitElement(at: world) {
            if extend {
                if selection.contains(where: { $0 === hit }) { selection.removeAll { $0 === hit } }
                else { selection.append(hit) }
            } else if !selection.contains(where: { $0 === hit }) {
                selection = [hit]
            }
            dragStart = world
            if let wire = hit as? Wire, selection.count == 1, let net = controller.netlist.findNet(at: wire.points[0]) {
                controller.status = "Net \(net.name): \(net.pins.count) pin(s), \(net.wires.count) wire(s)"
            }
        } else {
            if !extend { selection.removeAll() }
            rubberStart = world
        }
        needsDisplay = true
    }

    private func tweakValue(_ sym: SymbolInstance, up: Bool) {
        guard let sim = controller.simulator, let v = Units.parse(sym.value), v > 0 else { return }
        let ladder: [Double] = [1.0, 2.2, 4.7]
        var p = pow(10, (log10(v)).rounded(.down))
        let m = v / p
        var idx = 0
        for i in 1..<ladder.count where abs(log(m / ladder[i])) < abs(log(m / ladder[idx])) { idx = i }
        idx += up ? 1 : -1
        if idx >= ladder.count { idx = 0; p *= 10 }
        if idx < 0 { idx = ladder.count - 1; p /= 10 }
        sym.value = Self.formatValueShort(min(max(ladder[idx] * p, 1e-12), 1e12))
        if sim.updateComponentValue(sym) {
            controller.status = "\(sym.refDes) = \(sym.value)"
            needsDisplay = true
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        NSColor(calibratedWhite: 0.985, alpha: 1).setFill()
        ctx.fill(bounds)

        ctx.saveGState()
        ctx.translateBy(x: pan.x, y: pan.y)
        ctx.scaleBy(x: zoom, y: zoom)

        drawGrid(ctx)

        // Cross-probing: highlight the whole net of the single selected wire.
        if selection.count == 1, let wire = selection.first as? Wire, let net = controller.netlist.findNet(at: wire.points[0]) {
            ctx.setStrokeColor(NSColor(calibratedRed: 1, green: 0.62, blue: 0.11, alpha: 0.55).cgColor)
            ctx.setLineWidth(3.2)
            for w in net.wires { strokePolyline(ctx, w.points, offset: .zero) }
        }

        // Wires.
        for wire in controller.document.wires {
            let selected = selection.contains { $0 === wire }
            ctx.setStrokeColor(selected ? NSColor.systemOrange.cgColor : NSColor(calibratedRed: 0.10, green: 0.34, blue: 0.77, alpha: 1).cgColor)
            ctx.setLineWidth(0.9)
            strokePolyline(ctx, wire.points, offset: selected ? dragDelta : .zero)
        }

        // Junction dots and dangling ends.
        ctx.setFillColor(NSColor(calibratedRed: 0.10, green: 0.34, blue: 0.77, alpha: 1).cgColor)
        for j in controller.netlist.junctions {
            ctx.fillEllipse(in: CGRect(x: j.x - 1.4, y: j.y - 1.4, width: 2.8, height: 2.8))
        }
        ctx.setStrokeColor(NSColor.systemRed.cgColor)
        ctx.setLineWidth(0.8)
        for d in controller.netlist.danglingWireEnds {
            ctx.strokeEllipse(in: CGRect(x: d.x - 2.2, y: d.y - 2.2, width: 4.4, height: 4.4))
        }

        // Symbols.
        for sym in controller.document.symbols {
            let selected = selection.contains { $0 === sym }
            let offset = selected ? dragDelta : Vec2.zero

            if controller.simulator != nil, sym.definition.name == "Lamp" {
                drawLampGlow(ctx, sym)
            }

            drawSymbol(ctx, sym, color: selected ? NSColor.systemOrange : NSColor(calibratedWhite: 0.13, alpha: 1), offset: offset)
            drawLabels(sym, offset: offset)

            if let sim = controller.simulator, sym.definition.name == "Fuse", sim.isFuseBlown(sym) {
                ctx.setStrokeColor(NSColor.systemRed.cgColor)
                ctx.setLineWidth(1.6)
                ctx.move(to: CGPoint(x: sym.position.x - 5, y: sym.position.y - 5))
                ctx.addLine(to: CGPoint(x: sym.position.x + 5, y: sym.position.y + 5))
                ctx.move(to: CGPoint(x: sym.position.x - 5, y: sym.position.y + 5))
                ctx.addLine(to: CGPoint(x: sym.position.x + 5, y: sym.position.y - 5))
                ctx.strokePath()
            }
        }

        // Probe markers.
        for probe in controller.probes {
            let pos = probe.isCurrent ? probe.symbol!.position : probe.anchor
            ctx.setFillColor(probe.color.cgColor)
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(0.7)
            let rect = CGRect(x: pos.x - 2.4, y: pos.y - 2.4, width: 4.8, height: 4.8)
            ctx.fillEllipse(in: rect)
            ctx.strokeEllipse(in: rect)
            drawText(probe.label, at: Vec2(pos.x + 3.5, pos.y - 6), size: 4, color: probe.color)
        }

        // Placement ghost.
        if let ghost {
            drawSymbol(ctx, ghost, color: NSColor.systemGray.withAlphaComponent(0.6), offset: .zero)
        }

        // Wire preview.
        if case .wire = controller.tool, !wirePoints.isEmpty {
            let snapped = controller.document.findPinNear(cursorWorld, tolerance: hitTolerance * 2) ?? cursorWorld.snap(SchematicDocument.grid)
            let last = wirePoints[wirePoints.count - 1]
            var preview = wirePoints
            if snapped.x != last.x && snapped.y != last.y { preview.append(Vec2(snapped.x, last.y)) }
            preview.append(snapped)
            let valid = controller.document.isConnectionPoint(snapped)
            ctx.setStrokeColor((valid ? NSColor.systemGreen : NSColor.systemRed).withAlphaComponent(0.8).cgColor)
            ctx.setLineWidth(0.9)
            strokePolyline(ctx, preview, offset: .zero)
        }

        // Rubber band.
        if let start = rubberStart {
            ctx.setStrokeColor(NSColor.systemBlue.withAlphaComponent(0.7).cgColor)
            ctx.setFillColor(NSColor.systemBlue.withAlphaComponent(0.08).cgColor)
            ctx.setLineWidth(0.6)
            let rect = CGRect(x: min(start.x, cursorWorld.x), y: min(start.y, cursorWorld.y), width: abs(cursorWorld.x - start.x), height: abs(cursorWorld.y - start.y))
            ctx.fill(rect)
            ctx.stroke(rect)
        }

        ctx.restoreGState()
    }

    private func drawGrid(_ ctx: CGContext) {
        guard zoom > 0.8 else { return }
        let grid = SchematicDocument.grid
        let topLeft = toWorld(.zero)
        let bottomRight = toWorld(CGPoint(x: bounds.width, y: bounds.height))
        ctx.setFillColor(NSColor(calibratedWhite: 0.82, alpha: 1).cgColor)
        var x = (topLeft.x / grid).rounded(.down) * grid
        while x <= bottomRight.x {
            var y = (topLeft.y / grid).rounded(.down) * grid
            while y <= bottomRight.y {
                ctx.fill(CGRect(x: x - 0.25, y: y - 0.25, width: 0.5, height: 0.5))
                y += grid
            }
            x += grid
        }
    }

    private func strokePolyline(_ ctx: CGContext, _ points: [Vec2], offset: Vec2) {
        guard points.count >= 2 else { return }
        ctx.move(to: CGPoint(x: points[0].x + offset.x, y: points[0].y + offset.y))
        for p in points.dropFirst() { ctx.addLine(to: CGPoint(x: p.x + offset.x, y: p.y + offset.y)) }
        ctx.strokePath()
    }

    private func drawSymbol(_ ctx: CGContext, _ sym: SymbolInstance, color: NSColor, offset: Vec2) {
        ctx.setStrokeColor(color.cgColor)
        ctx.setFillColor(color.cgColor)
        ctx.setLineWidth(0.9)
        ctx.setLineCap(.round)

        func world(_ p: Vec2) -> CGPoint {
            let w = sym.toWorld(p) + offset
            return CGPoint(x: w.x, y: w.y)
        }

        for prim in sym.activePrimitives {
            switch prim {
            case .line(let a, let b):
                ctx.move(to: world(a))
                ctx.addLine(to: world(b))
                ctx.strokePath()
            case .poly(let pts, let closed, let filled):
                guard let first = pts.first else { break }
                ctx.move(to: world(first))
                for p in pts.dropFirst() { ctx.addLine(to: world(p)) }
                if closed { ctx.closePath() }
                filled ? ctx.fillPath() : ctx.strokePath()
            case .circle(let c, let r, let filled):
                let wc = sym.toWorld(c) + offset
                let rect = CGRect(x: wc.x - r, y: wc.y - r, width: 2 * r, height: 2 * r)
                filled ? ctx.fillEllipse(in: rect) : ctx.strokeEllipse(in: rect)
            case .arc(let c, let r, let start, let end):
                let flat = DrawPrimitive.flattenArc(center: c, radius: r, startDeg: start, endDeg: end)
                ctx.move(to: world(flat[0]))
                for p in flat.dropFirst() { ctx.addLine(to: world(p)) }
                ctx.strokePath()
            case .text(let text, let at, let size):
                drawText(text, at: sym.toWorld(at) + offset - Vec2(0, size / 2), size: size, color: color, centered: true)
            }
        }
    }

    private func drawLabels(_ sym: SymbolInstance, offset: Vec2) {
        guard sym.definition.name != "Ground" else { return }
        let bounds = sym.bounds
        drawText(sym.refDes, at: Vec2(bounds.minX + offset.x, bounds.minY - 8 + offset.y), size: 5, color: NSColor(calibratedWhite: 0.35, alpha: 1))
        if !sym.value.isEmpty {
            drawText(sym.value, at: Vec2(bounds.minX + offset.x, bounds.maxY + 2 + offset.y), size: 5, color: NSColor(calibratedWhite: 0.45, alpha: 1))
        }
    }

    private func drawText(_ text: String, at world: Vec2, size: Double, color: NSColor, centered: Bool = false) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size),
            .foregroundColor: color,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        var point = CGPoint(x: world.x, y: world.y)
        if centered { point.x -= string.size().width / 2 }
        string.draw(at: point)
    }

    private func drawLampGlow(_ ctx: CGContext, _ sym: SymbolInstance) {
        guard let sim = controller.simulator else { return }
        let brightness = sim.lampBrightness(sym)
        guard brightness >= 0.02 else { return }
        let radius = 10 + 14 * brightness
        let colors = [
            NSColor(calibratedRed: 1, green: 0.85, blue: 0.25, alpha: 0.6 * brightness).cgColor,
            NSColor(calibratedRed: 1, green: 0.85, blue: 0.25, alpha: 0).cgColor,
        ]
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1]) else { return }
        let center = CGPoint(x: sym.position.x, y: sym.position.y)
        ctx.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
    }

    // MARK: - Formatting

    static func formatSi(_ v: Double, _ unit: String) -> String {
        let a = abs(v)
        let (m, prefix): (Double, String)
        switch a {
        case 1e6...: (m, prefix) = (1e-6, "M")
        case 1e3...: (m, prefix) = (1e-3, "k")
        case 1...: (m, prefix) = (1, "")
        case 1e-3...: (m, prefix) = (1e3, "m")
        case 1e-6...: (m, prefix) = (1e6, "\u{00b5}")
        case 1e-9...: (m, prefix) = (1e9, "n")
        default: (m, prefix) = (1, "")
        }
        return String(format: "%.3g %@%@", v * m, prefix, unit)
    }

    static func formatValueShort(_ v: Double) -> String {
        let a = abs(v)
        let (m, suffix): (Double, String)
        switch a {
        case 1e9...: (m, suffix) = (1e-9, "G")
        case 1e6...: (m, suffix) = (1e-6, "Meg")
        case 1e3...: (m, suffix) = (1e-3, "k")
        case 1...: (m, suffix) = (1, "")
        case 1e-3...: (m, suffix) = (1e3, "m")
        case 1e-6...: (m, suffix) = (1e6, "u")
        case 1e-9...: (m, suffix) = (1e9, "n")
        default: (m, suffix) = (1e12, "p")
        }
        return String(format: "%.4g%@", v * m, suffix)
    }
}

struct CanvasView: NSViewRepresentable {
    let controller: EditorController

    func makeNSView(context: Context) -> SchematicNSView { SchematicNSView(controller: controller) }
    func updateNSView(_ view: SchematicNSView, context: Context) { view.needsDisplay = true }
}
