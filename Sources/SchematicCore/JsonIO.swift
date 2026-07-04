import Foundation

/// A saved scope probe: type "V" (anchor point) or "I" (symbol id).
public struct ProbeInfo: Codable {
    public let type: String
    public let x: Double
    public let y: Double
    public let symbolId: Int

    public init(type: String, x: Double = 0, y: Double = 0, symbolId: Int = 0) {
        self.type = type
        self.x = x
        self.y = y
        self.symbolId = symbolId
    }

    enum CodingKeys: String, CodingKey {
        case type = "Type"
        case x = "X"
        case y = "Y"
        case symbolId = "SymbolId"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? "V"
        x = try c.decodeIfPresent(Double.self, forKey: .x) ?? 0
        y = try c.decodeIfPresent(Double.self, forKey: .y) ?? 0
        symbolId = try c.decodeIfPresent(Int.self, forKey: .symbolId) ?? 0
    }
}

/// Native document format (.schem.json) — byte-compatible with the C#/WPF editor,
/// so schematics (probes included) move freely between Windows and macOS.
public enum JsonIO {
    private struct SymbolDto: Codable {
        var Id: Int
        var Symbol: String
        var X: Double?
        var Y: Double?
        var Rotation: Int?
        var Mirror: Bool?
        var RefDes: String?
        var Value: String?
        var On: Bool?
    }

    private struct WireDto: Codable {
        var Id: Int
        var Points: [Double]
    }

    private struct DocumentDto: Codable {
        var Format: String
        var Version: Int
        var Symbols: [SymbolDto]
        var Wires: [WireDto]
        var Probes: [ProbeInfo]?
    }

    public struct LoadedDocument {
        public let document: SchematicDocument
        public let probes: [ProbeInfo]
    }

    public static func save(_ doc: SchematicDocument, probes: [ProbeInfo] = []) throws -> Data {
        let dto = DocumentDto(
            Format: "schematic-editor",
            Version: 1,
            Symbols: doc.symbols.map { s in
                SymbolDto(
                    Id: s.id,
                    Symbol: s.definition.name,
                    X: s.position.x == 0 ? nil : s.position.x,
                    Y: s.position.y == 0 ? nil : s.position.y,
                    Rotation: s.rotation == .r0 ? nil : fileValue(for: s.rotation),
                    Mirror: s.mirror ? true : nil,
                    RefDes: s.refDes,
                    Value: s.value,
                    On: s.stateOn ? true : nil)
            },
            Wires: doc.wires.map { w in
                WireDto(Id: w.id, Points: w.points.flatMap { [$0.x, $0.y] })
            },
            Probes: probes.isEmpty ? nil : probes)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(dto)
    }

    public static func load(_ data: Data) throws -> LoadedDocument {
        let dto = try JSONDecoder().decode(DocumentDto.self, from: data)
        let doc = SchematicDocument()

        for s in dto.Symbols {
            guard let def = SymbolLibrary.find(s.Symbol) else { continue }
            let inst = SymbolInstance(definition: def, position: Vec2(s.X ?? 0, s.Y ?? 0))
            inst.rotation = rotation(fromFileValue: s.Rotation ?? 0)
            inst.mirror = s.Mirror ?? false
            inst.refDes = s.RefDes ?? "?"
            inst.value = s.Value ?? ""
            inst.stateOn = s.On ?? false
            inst.id = s.Id
            doc.add(inst)
        }

        for w in dto.Wires {
            var points: [Vec2] = []
            var i = 0
            while i + 1 < w.Points.count {
                points.append(Vec2(w.Points[i], w.Points[i + 1]))
                i += 2
            }
            let wire = Wire(points)
            wire.id = w.Id
            doc.add(wire)
        }

        return LoadedDocument(document: doc, probes: dto.Probes ?? [])
    }

    /// The C# core serializes Rotation as the enum INDEX (R0=0, R90=1, R180=2, R270=3),
    /// not as degrees. Accept degrees too, for hand-written files.
    private static func rotation(fromFileValue v: Int) -> Rotation {
        switch v {
        case 1, 90: return .r90
        case 2, 180: return .r180
        case 3, 270: return .r270
        default: return .r0
        }
    }

    private static func fileValue(for r: Rotation) -> Int {
        switch r {
        case .r0: return 0
        case .r90: return 1
        case .r180: return 2
        case .r270: return 3
        }
    }

    public static func save(_ doc: SchematicDocument, to url: URL, probes: [ProbeInfo] = []) throws {
        try save(doc, probes: probes).write(to: url)
    }

    public static func load(from url: URL) throws -> LoadedDocument {
        try load(Data(contentsOf: url))
    }
}

/// Handwritten SVG exporter — same visual conventions as the C# one.
public enum SvgExporter {
    public static func export(_ doc: SchematicDocument) -> String {
        let bounds = doc.contentBounds.isEmpty ? Rect2(minX: 0, minY: 0, maxX: 100, maxY: 100) : doc.contentBounds.inflated(20)
        var out = ""
        out += "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"\(f(bounds.minX)) \(f(bounds.minY)) \(f(bounds.width)) \(f(bounds.height))\">\n"
        out += "<g fill=\"none\" stroke=\"#1a56c4\" stroke-width=\"0.9\" stroke-linecap=\"round\">\n"
        for wire in doc.wires {
            let pts = wire.points.map { "\(f($0.x)),\(f($0.y))" }.joined(separator: " ")
            out += "<polyline points=\"\(pts)\"/>\n"
        }
        out += "</g>\n<g fill=\"none\" stroke=\"#222222\" stroke-width=\"0.9\" stroke-linecap=\"round\">\n"
        for sym in doc.symbols {
            for prim in sym.activePrimitives { out += primitive(prim, sym) }
        }
        out += "</g>\n"
        let netlist = NetlistExtractor.extract(doc)
        for j in netlist.junctions {
            out += "<circle cx=\"\(f(j.x))\" cy=\"\(f(j.y))\" r=\"1.4\" fill=\"#1a56c4\"/>\n"
        }
        out += "</svg>\n"
        return out
    }

    private static func primitive(_ prim: DrawPrimitive, _ sym: SymbolInstance) -> String {
        switch prim {
        case .line(let a, let b):
            let wa = sym.toWorld(a), wb = sym.toWorld(b)
            return "<line x1=\"\(f(wa.x))\" y1=\"\(f(wa.y))\" x2=\"\(f(wb.x))\" y2=\"\(f(wb.y))\"/>\n"
        case .poly(let pts, let closed, let filled):
            let world = pts.map(sym.toWorld).map { "\(f($0.x)),\(f($0.y))" }.joined(separator: " ")
            let tag = closed ? "polygon" : "polyline"
            let fill = filled ? " fill=\"#222222\"" : ""
            return "<\(tag) points=\"\(world)\"\(fill)/>\n"
        case .circle(let c, let r, let filled):
            let wc = sym.toWorld(c)
            let fill = filled ? " fill=\"#222222\"" : ""
            return "<circle cx=\"\(f(wc.x))\" cy=\"\(f(wc.y))\" r=\"\(f(r))\"\(fill)/>\n"
        case .arc(let c, let r, let start, let end):
            let world = DrawPrimitive.flattenArc(center: c, radius: r, startDeg: start, endDeg: end).map(sym.toWorld).map { "\(f($0.x)),\(f($0.y))" }.joined(separator: " ")
            return "<polyline points=\"\(world)\"/>\n"
        case .text(let text, let at, let size):
            let wp = sym.toWorld(at)
            return "<text x=\"\(f(wp.x))\" y=\"\(f(wp.y))\" font-size=\"\(f(size))\" text-anchor=\"middle\" fill=\"#222222\" stroke=\"none\">\(text)</text>\n"
        }
    }

    private static func f(_ v: Double) -> String { String(format: "%.3g", locale: Locale(identifier: "en_US_POSIX"), v) }
}
