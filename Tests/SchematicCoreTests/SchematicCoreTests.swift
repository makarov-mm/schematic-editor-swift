import XCTest
@testable import SchematicCore

/// The same analytic reference checks that the verified C# core passes: if these are green
/// on the Mac, the port's math is the math.
final class SchematicCoreTests: XCTestCase {

    // MARK: - Helpers

    private func makeDoc(_ build: (SchematicDocument, UndoStack) -> Void) -> SchematicDocument {
        let doc = SchematicDocument()
        let undo = UndoStack(doc)
        build(doc, undo)
        return doc
    }

    @discardableResult
    private func place(_ undo: UndoStack, _ name: String, _ x: Double, _ y: Double, _ rot: Rotation = .r0, value: String? = nil) -> SymbolInstance {
        let inst = SymbolInstance(definition: SymbolLibrary.get(name), position: Vec2(x, y))
        inst.rotation = rot
        if let value { inst.value = value }
        undo.push(AddElementCommand(inst))
        return inst
    }

    private func wire(_ undo: UndoStack, _ pts: [(Double, Double)]) {
        undo.push(AddElementCommand(Wire(pts.map { Vec2($0.0, $0.1) })))
    }

    private func mustBuild(_ doc: SchematicDocument) throws -> CircuitSimulator {
        var problems: [String] = []
        guard let sim = CircuitSimulator.build(doc, NetlistExtractor.extract(doc), problems: &problems) else {
            XCTFail("build failed: \(problems.joined(separator: "; "))")
            throw SimulationError(message: "build failed")
        }
        return sim
    }

    // MARK: - Units

    func testUnits() {
        XCTAssertEqual(Units.parse("10k")!, 10_000, accuracy: 1e-9)
        XCTAssertEqual(Units.parse("4.7k")!, 4700, accuracy: 1e-9)
        XCTAssertEqual(Units.parse("100n")!, 100e-9, accuracy: 1e-15)
        XCTAssertEqual(Units.parse("12V")!, 12, accuracy: 1e-9)
        XCTAssertEqual(Units.parse("2mV")!, 2e-3, accuracy: 1e-12, "m is milli")
        XCTAssertEqual(Units.parse("2MHz")!, 2e6, accuracy: 1e-3, "M is mega")
        XCTAssertNil(Units.parse("abc"))

        let lamp = Units.parseLampRating("12V 5W")!
        XCTAssertEqual(lamp.resistance, 28.8, accuracy: 1e-9)
        XCTAssertEqual(lamp.ratedPower, 5, accuracy: 1e-9)

        let ac = Units.parseAcSpec("5V 50Hz")!
        XCTAssertEqual(ac.amplitude, 5, accuracy: 1e-9)
        XCTAssertEqual(ac.frequency, 50, accuracy: 1e-9)
    }

    // MARK: - Transforms

    func testTransforms() {
        let s = SymbolInstance(definition: SymbolLibrary.get("Resistor"), position: Vec2(100, 50))
        s.rotation = .r90
        let pins = s.worldPins().map(\.world)
        XCTAssertEqual(pins[0].key(), Vec2(100, 30).key(), "R90 pin 1")
        XCTAssertEqual(pins[1].key(), Vec2(100, 70).key(), "R90 pin 2")
    }

    // MARK: - DC divider

    func testDcDivider() throws {
        var r1: SymbolInstance!
        let doc = makeDoc { _, u in
            let v = self.place(u, "VSource", 0, 0)
            v.value = "10V"
            r1 = self.place(u, "Resistor", 60, -20, .r90)
            let r2 = self.place(u, "Resistor", 60, 40, .r90)
            r2.value = "10k"
            self.place(u, "Ground", 0, 80)
            self.wire(u, [(0, -20), (0, -40), (60, -40)])
            self.wire(u, [(60, 0), (60, 20)])
            self.wire(u, [(60, 60), (60, 80), (0, 80)])
            self.wire(u, [(0, 20), (0, 80)])
        }
        let sim = try mustBuild(doc)
        try sim.step(1e-4)
        XCTAssertEqual(sim.voltage(at: Vec2(60, 10))!, 5.0, accuracy: 1e-3, "midpoint")
        XCTAssertEqual(abs(sim.current(of: r1)!), 0.5e-3, accuracy: 1e-6, "current")
    }

    // MARK: - RC transient

    func testRcCharging() throws {
        let doc = makeDoc { _, u in
            let v = self.place(u, "VSource", 0, 0)
            v.value = "10V"
            let r = self.place(u, "Resistor", 60, -40)
            r.value = "1k"
            let c = self.place(u, "Capacitor", 120, 0, .r90)
            c.value = "1u"
            self.place(u, "Ground", 0, 60)
            self.wire(u, [(0, -20), (0, -40), (40, -40)])
            self.wire(u, [(80, -40), (120, -40), (120, -20)])
            self.wire(u, [(120, 20), (120, 60), (0, 60)])
            self.wire(u, [(0, 20), (0, 60)])
        }
        let sim = try mustBuild(doc)
        for _ in 0..<1000 { try sim.step(1e-6) } // t = tau = 1 ms
        let expected = 10.0 * (1 - exp(-1))
        XCTAssertEqual(sim.voltage(at: Vec2(120, -20))!, expected, accuracy: 0.05, "RC at t=tau")
    }

    // MARK: - Switch and lamp

    func testSwitchAndLamp() throws {
        var sw: SymbolInstance!
        var lamp: SymbolInstance!
        let doc = makeDoc { _, u in
            let v = self.place(u, "Battery", 0, 0)
            v.value = "12V"
            sw = self.place(u, "Switch", 60, -40)
            lamp = self.place(u, "Lamp", 120, 0, .r90)
            lamp.value = "12V 5W"
            self.place(u, "Ground", 0, 60)
            self.wire(u, [(0, -20), (0, -40), (40, -40)])
            self.wire(u, [(80, -40), (120, -40), (120, -20)])
            self.wire(u, [(120, 20), (120, 60), (0, 60)])
            self.wire(u, [(0, 20), (0, 60)])
        }
        let sim = try mustBuild(doc)
        try sim.step(1e-4)
        XCTAssertLessThan(sim.lampBrightness(lamp), 0.01, "open switch: dark")

        sw.stateOn = true
        try sim.step(1e-4)
        XCTAssertGreaterThan(sim.lampBrightness(lamp), 0.95, "closed switch: bright")
        XCTAssertEqual(abs(sim.current(of: lamp)!), 12.0 / 28.8, accuracy: 0.01, "lamp current")
    }

    // MARK: - Fuse

    func testFuseBlows() throws {
        var fuse: SymbolInstance!
        let doc = makeDoc { _, u in
            let v = self.place(u, "Battery", 0, 0)
            v.value = "9V"
            fuse = self.place(u, "Fuse", 60, -40)
            fuse.value = "1A"
            let r = self.place(u, "Resistor", 120, 0, .r90)
            r.value = "1"
            self.place(u, "Ground", 0, 60)
            self.wire(u, [(0, -20), (0, -40), (40, -40)])
            self.wire(u, [(80, -40), (120, -40), (120, -20)])
            self.wire(u, [(120, 20), (120, 60), (0, 60)])
            self.wire(u, [(0, 20), (0, 60)])
        }
        let sim = try mustBuild(doc)
        try sim.step(1e-4)
        XCTAssertTrue(sim.isFuseBlown(fuse), "overcurrent blew the fuse")
        sim.reset()
        XCTAssertFalse(sim.isFuseBlown(fuse), "reset un-blows")
    }

    // MARK: - Diode rectifier

    func testDiodeRectifier() throws {
        let doc = makeDoc { _, u in
            let v = self.place(u, "ACSource", 0, 0)
            v.value = "5V 50Hz"
            self.place(u, "Diode", 60, -40)
            let r = self.place(u, "Resistor", 120, 0, .r90)
            r.value = "1k"
            self.place(u, "Ground", 0, 60)
            self.wire(u, [(0, -20), (0, -40), (40, -40)])
            self.wire(u, [(80, -40), (120, -40), (120, -20)])
            self.wire(u, [(120, 20), (120, 60), (0, 60)])
            self.wire(u, [(0, 20), (0, 60)])
        }
        let sim = try mustBuild(doc)
        var vmax = 0.0, vmin = 0.0
        for _ in 0..<800 {
            try sim.step(5e-5)
            let v = sim.voltage(at: Vec2(120, -40)) ?? 0
            vmax = max(vmax, v)
            vmin = min(vmin, v)
        }
        XCTAssertEqual(vmax, 4.3, accuracy: 0.15, "rectified peak = 5 - 0.7")
        XCTAssertGreaterThan(vmin, -0.2, "negative half suppressed")
    }

    // MARK: - Ground merging

    func testSeparateGroundsMerge() throws {
        let doc = makeDoc { _, u in
            let v = self.place(u, "VSource", 0, 0)
            v.value = "10V"
            self.place(u, "Resistor", 60, -40)
            self.place(u, "Ground", 120, 0)
            self.place(u, "Ground", 0, 60)
            self.wire(u, [(0, -20), (0, -40), (40, -40)])
            self.wire(u, [(80, -40), (120, -40), (120, 0)])
            self.wire(u, [(0, 20), (0, 60)])
        }
        let sim = try mustBuild(doc)
        try sim.step(1e-4)
        XCTAssertEqual(sim.voltage(at: Vec2(0, -40))!, 10.0, accuracy: 1e-3, "one reference")
    }

    // MARK: - AC analysis

    func testAcRcLowPass() throws {
        let doc = makeDoc { _, u in
            let v = self.place(u, "ACSource", 0, 0)
            v.value = "1V 50Hz"
            let r = self.place(u, "Resistor", 60, -40)
            r.value = "1k"
            let c = self.place(u, "Capacitor", 120, 0, .r90)
            c.value = "1u"
            self.place(u, "Ground", 0, 60)
            self.wire(u, [(0, -20), (0, -40), (40, -40)])
            self.wire(u, [(80, -40), (120, -40), (120, -20)])
            self.wire(u, [(120, 20), (120, 60), (0, 60)])
            self.wire(u, [(0, 20), (0, 60)])
        }
        let sim = try mustBuild(doc)
        let fc = 1.0 / (2.0 * .pi * 1e3 * 1e-6)
        let atCorner = try sim.acVoltage(at: Vec2(120, -40), frequency: fc)!
        XCTAssertEqual(atCorner.magnitude, 1.0 / 2.0.squareRoot(), accuracy: 1e-3, "-3 dB at fc")
        XCTAssertEqual(atCorner.phase * 180 / .pi, -45, accuracy: 0.5, "-45 deg at fc")
    }

    func testAcRlcResonance() throws {
        let doc = makeDoc { _, u in
            let v = self.place(u, "ACSource", 0, 0)
            v.value = "5V 50Hz"
            let r = self.place(u, "Resistor", 60, -40)
            r.value = "3.3"
            let l = self.place(u, "Inductor", 120, -40)
            l.value = "100m"
            let c = self.place(u, "Capacitor", 180, 0, .r90)
            c.value = "100u"
            self.place(u, "Ground", 0, 60)
            self.wire(u, [(0, -20), (0, -40), (40, -40)])
            self.wire(u, [(80, -40), (100, -40)])
            self.wire(u, [(140, -40), (180, -40), (180, -20)])
            self.wire(u, [(180, 20), (180, 60), (0, 60)])
            self.wire(u, [(0, 20), (0, 60)])
        }
        let sim = try mustBuild(doc)
        let f0 = 1.0 / (2.0 * .pi * (0.1 * 100e-6).squareRoot())
        let q = (0.1 / 100e-6).squareRoot() / 3.3
        let peak = try sim.acVoltage(at: Vec2(180, -40), frequency: f0)!.magnitude
        XCTAssertEqual(peak, 5.0 * q, accuracy: 0.2, "|Vc(f0)| = Q*A")
    }

    // MARK: - JSON round trip and C# compatibility

    func testJsonRoundTripWithProbes() throws {
        var rsym: SymbolInstance!
        let doc = makeDoc { _, u in
            let v = self.place(u, "VSource", 0, 0)
            v.value = "10V"
            rsym = self.place(u, "Resistor", 60, 0, .r90)
            self.place(u, "Ground", 0, 60)
            self.wire(u, [(0, -20), (0, -40), (60, -40), (60, -20)])
            self.wire(u, [(60, 20), (60, 60), (0, 60)])
            self.wire(u, [(0, 20), (0, 60)])
        }
        let data = try JsonIO.save(doc, probes: [ProbeInfo(type: "V", x: 60, y: -40), ProbeInfo(type: "I", symbolId: rsym.id)])
        let loaded = try JsonIO.load(data)
        XCTAssertEqual(loaded.document.symbols.count, 3)
        XCTAssertEqual(loaded.probes.count, 2)
        XCTAssertEqual(loaded.probes[0].type, "V")
        XCTAssertEqual(loaded.probes[0].x, 60, accuracy: 1e-9)
        XCTAssertEqual(loaded.probes[1].symbolId, rsym.id)
    }

    func testLoadsCSharpProducedFile() throws {
        // A minimal file exactly as the WPF editor writes it (defaults omitted).
        let json = """
        {
          "Format": "schematic-editor",
          "Version": 1,
          "Symbols": [
            { "Id": 1, "Symbol": "Battery", "RefDes": "BT1", "Value": "12V" },
            { "Id": 2, "Symbol": "Resistor", "X": 60, "Y": -40, "Rotation": 1, "RefDes": "R1", "Value": "1k" },
            { "Id": 3, "Symbol": "Switch", "X": 120, "Y": -40, "RefDes": "S1", "Value": "", "On": true }
          ],
          "Wires": [ { "Id": 4, "Points": [0, -20, 0, -40, 40, -40] } ],
          "Probes": [ { "Type": "I", "SymbolId": 2 } ]
        }
        """
        let loaded = try JsonIO.load(Data(json.utf8))
        XCTAssertEqual(loaded.document.symbols.count, 3)
        XCTAssertTrue(loaded.document.symbols.first { $0.refDes == "S1" }!.stateOn, "On flag read")
        XCTAssertEqual(loaded.document.symbols.first { $0.refDes == "R1" }!.rotation, .r90, "C# rotation index 1 means R90")

        // Round-trip must keep the C# index convention on disk.
        let rewritten = try JsonIO.save(loaded.document)
        let reloaded = try JsonIO.load(rewritten)
        XCTAssertEqual(reloaded.document.symbols.first { $0.refDes == "R1" }!.rotation, .r90, "index convention survives a save")
        XCTAssertEqual(loaded.document.wires.first!.points.count, 3)
        XCTAssertEqual(loaded.probes.first!.type, "I")
    }

    // MARK: - Netlist

    func testNetlistTJunction() {
        let doc = makeDoc { _, u in
            self.wire(u, [(0, 0), (100, 0)])
            self.wire(u, [(50, 0), (50, 40)])   // endpoint on segment interior
        }
        let netlist = NetlistExtractor.extract(doc)
        XCTAssertEqual(netlist.nets.count, 1, "T-junction merges wires")
        XCTAssertEqual(netlist.junctions.count, 1, "junction dot at the T")
    }
}
