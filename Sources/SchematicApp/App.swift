import AppKit
import SwiftUI
import SchematicCore

@main
struct SchematicEditorApp: App {
    @StateObject private var controller = EditorController()

    init() {
        // Running as a bare SPM executable there is no app bundle, so the process
        // starts as a background-style app; promote it and bring the window forward.
        NSApplication.shared.setActivationPolicy(.regular)
        DispatchQueue.main.async {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    var body: some Scene {
        WindowGroup("Schematic Editor") {
            ContentView()
                .environmentObject(controller)
                .frame(minWidth: 1000, minHeight: 640)
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var controller: EditorController
    @State private var scopeWindow: Double = 0.2
    @State private var showErc = false
    @State private var ercText = ""
    @State private var editRefDes = ""
    @State private var editValue = ""

    private var scopeVisible: Bool { controller.isRunning || controller.probesExist }

    var body: some View {
        HSplitView {
            palette
                .frame(width: 150)
            VStack(spacing: 0) {
                CanvasView(controller: controller)
                if scopeVisible {
                    scopePanel
                        .frame(height: 210)
                }
                statusBar
            }
        }
        .toolbar { toolbarContent }
        .sheet(item: Binding(
            get: { controller.editingSymbol.map(EditingBox.init) },
            set: { controller.editingSymbol = $0?.symbol })) { box in
            propertiesSheet(box.symbol)
        }
        .alert("ERC", isPresented: $showErc) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(ercText)
        }
    }

    // MARK: - Palette

    private var palette: some View {
        List(SymbolLibrary.all, id: \.name) { def in
            Button {
                controller.placeSymbol?(def.name)
            } label: {
                HStack {
                    Text(def.refPrefix)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(width: 30, alignment: .leading)
                        .foregroundStyle(.secondary)
                    Text(def.name)
                }
            }
            .buttonStyle(.plain)
            .disabled(controller.isRunning)
        }
        .listStyle(.sidebar)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Button("New", systemImage: "doc") { controller.newDocument() }
            Button("Open", systemImage: "folder") { controller.openDocument() }
            Button("Save", systemImage: "square.and.arrow.down") { controller.saveDocument() }
        }
        ToolbarItemGroup {
            Button("Undo", systemImage: "arrow.uturn.backward") { controller.performUndo() }
                .disabled(!controller.canUndo || controller.isRunning)
            Button("Redo", systemImage: "arrow.uturn.forward") { controller.performRedo() }
                .disabled(!controller.canRedo || controller.isRunning)
        }
        ToolbarItemGroup {
            Button("Wire", systemImage: "point.topleft.down.to.point.bottomright.curvepath") {
                controller.tool = .wire
            }
            .disabled(controller.isRunning)
            Button("Rotate", systemImage: "rotate.right") { controller.rotateAction?() }
                .disabled(controller.isRunning)
            Button("Mirror", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right") { controller.mirrorAction?() }
                .disabled(controller.isRunning)
            Button("ERC", systemImage: "checkmark.shield") {
                ercText = controller.ercReport()
                showErc = true
            }
            Button("AC", systemImage: "waveform.path.ecg") { controller.runAcAnalysis() }
                .disabled(!controller.probesExist)
            Menu {
                Button("Export DXF\u{2026}") { controller.exportDxf() }
                Button("Export SVG\u{2026}") { controller.exportSvg() }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            Button("Fit", systemImage: "arrow.up.left.and.arrow.down.right") { controller.zoomToFitRequested?() }
        }
        ToolbarItemGroup {
            Button(controller.isRunning ? "Stop" : "Run", systemImage: controller.isRunning ? "stop.fill" : "play.fill") {
                if controller.isRunning {
                    controller.stopSimulation()
                } else {
                    controller.startSimulation()
                }
            }
            .tint(controller.isRunning ? .red : .green)
            Button("Reset", systemImage: "arrow.counterclockwise") { controller.resetSimulation() }
                .disabled(!controller.isRunning)
            Toggle(isOn: $controller.probeArmed) {
                Label("Probe", systemImage: "scope")
            }
            Button("Clear probes", systemImage: "xmark.circle") { controller.clearProbes() }
                .disabled(!controller.probesExist)
        }
    }

    // MARK: - Scope panel

    private var scopePanel: some View {
        VStack(spacing: 0) {
            HStack {
                Text("OSCILLOSCOPE")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $scopeWindow) {
                    Text("20 ms").tag(0.02)
                    Text("0.2 s").tag(0.2)
                    Text("2 s").tag(2.0)
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(red: 0.10, green: 0.125, blue: 0.16))
            ScopeView(controller: controller, windowSeconds: $scopeWindow)
        }
    }

    // MARK: - Status bar

    private var statusBar: some View {
        HStack {
            if controller.isRunning {
                Text("Running")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.green)
            }
            Text(controller.status)
                .font(.system(size: 11))
                .lineLimit(1)
            Spacer()
            Text(hint)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.bar)
    }

    private var hint: String {
        if controller.isRunning { return "Click a switch to toggle  •  Shift+scroll over R/C/L to tweak  •  Esc stop" }
        if controller.probeArmed { return "Click a wire/pin for voltage, a component for current  •  Esc exit" }
        switch controller.tool {
        case .wire: return "Click a pin or wire to start  •  click a target to finish  •  right-click cancel"
        case .place: return "Click to place  •  R rotate  •  M mirror  •  Esc back to Select"
        case .select: return "Drag to move  •  R rotate  •  M mirror  •  double-click to edit  •  ⌫ delete"
        }
    }

    // MARK: - Properties sheet

    private func propertiesSheet(_ symbol: SymbolInstance) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Properties — \(symbol.definition.name)")
                .font(.headline)
            TextField("Reference", text: $editRefDes)
            TextField("Value", text: $editValue)
            HStack {
                Spacer()
                Button("Cancel") { controller.editingSymbol = nil }
                Button("OK") {
                    controller.applyProperties(to: symbol, refDes: editRefDes, value: editValue)
                    controller.editingSymbol = nil
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 320)
        .onAppear {
            editRefDes = symbol.refDes
            editValue = symbol.value
        }
    }
}

private struct EditingBox: Identifiable {
    let symbol: SymbolInstance
    var id: Int { symbol.id }
}
