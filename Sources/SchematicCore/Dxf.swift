import Foundation

/// Minimal hand-written DXF R12 (AC1009) ASCII exporter — no external libraries.
/// R12 was chosen because virtually every CAD package can import it.
/// Editor Y axis points down; DXF Y points up, so Y is negated on export.
/// All numbers use POSIX formatting (DXF requires '.' as the decimal separator).
public enum DxfExporter {
    private static let layerSymbols = "SYMBOLS"
    private static let layerWires = "WIRES"
    private static let layerText = "TEXT"

    public static func export(_ doc: SchematicDocument) -> String {
        var sb = ""

        // HEADER
        pair(&sb, 0, "SECTION"); pair(&sb, 2, "HEADER")
        pair(&sb, 9, "$ACADVER"); pair(&sb, 1, "AC1009")
        pair(&sb, 0, "ENDSEC")

        // TABLES (layers)
        pair(&sb, 0, "SECTION"); pair(&sb, 2, "TABLES")
        pair(&sb, 0, "TABLE"); pair(&sb, 2, "LAYER"); pair(&sb, 70, "3")
        layer(&sb, layerSymbols, 7)
        layer(&sb, layerWires, 5)
        layer(&sb, layerText, 3)
        pair(&sb, 0, "ENDTAB")
        pair(&sb, 0, "ENDSEC")

        // ENTITIES
        pair(&sb, 0, "SECTION"); pair(&sb, 2, "ENTITIES")

        for wire in doc.wires {
            for seg in wire.segments() { line(&sb, layerWires, seg.a, seg.b) }
        }

        let netlist = NetlistExtractor.extract(doc)
        for j in netlist.junctions { circle(&sb, layerWires, j, 1.2) }

        for sym in doc.symbols {
            exportSymbol(&sb, sym)

            let bounds = sym.bounds
            let center = Vec2((bounds.minX + bounds.maxX) / 2, 0)
            let refPos = Vec2(center.x, bounds.minY - 4)
            let valPos = Vec2(center.x, bounds.maxY + 4)

            if !sym.refDes.isEmpty && sym.definition.name != "Ground" {
                text(&sb, layerText, refPos, sym.refDes, 5)
            }
            if !sym.value.isEmpty {
                text(&sb, layerText, valPos, sym.value, 5)
            }
        }

        pair(&sb, 0, "ENDSEC")
        pair(&sb, 0, "EOF")
        return sb
    }

    public static func export(_ doc: SchematicDocument, to url: URL) throws {
        try export(doc).data(using: .utf8)!.write(to: url)
    }

    private static func exportSymbol(_ sb: inout String, _ sym: SymbolInstance) {
        for prim in sym.activePrimitives {
            switch prim {
            case .line(let a, let b):
                line(&sb, layerSymbols, sym.toWorld(a), sym.toWorld(b))
            case .poly(let localPts, let closed, let filled):
                let pts = localPts.map(sym.toWorld)
                if filled && pts.count == 3 {
                    solid(&sb, layerSymbols, pts[0], pts[1], pts[2])
                } else {
                    let count = closed ? pts.count : pts.count - 1
                    for i in 0..<max(0, count) { line(&sb, layerSymbols, pts[i], pts[(i + 1) % pts.count]) }
                }
            case .circle(let c, let r, _):
                circle(&sb, layerSymbols, sym.toWorld(c), r)
            case .arc(let c, let r, let start, let end):
                // Flattened: rotation/mirror of true ARC entities is error-prone,
                // short polylines import identically everywhere.
                let pts = DrawPrimitive.flattenArc(center: c, radius: r, startDeg: start, endDeg: end).map(sym.toWorld)
                for i in 0..<(pts.count - 1) { line(&sb, layerSymbols, pts[i], pts[i + 1]) }
            case .text(let string, let at, let size):
                text(&sb, layerSymbols, sym.toWorld(at), string, size)
            }
        }
    }

    private static func f(_ v: Double) -> String { String(format: "%.4g", locale: Locale(identifier: "en_US_POSIX"), v) }

    private static func pair(_ sb: inout String, _ code: Int, _ value: String) {
        sb += "\(code)\n\(value)\n"
    }

    private static func layer(_ sb: inout String, _ name: String, _ color: Int) {
        pair(&sb, 0, "LAYER")
        pair(&sb, 2, name)
        pair(&sb, 70, "0")
        pair(&sb, 62, "\(color)")
        pair(&sb, 6, "CONTINUOUS")
    }

    private static func line(_ sb: inout String, _ layer: String, _ a: Vec2, _ b: Vec2) {
        pair(&sb, 0, "LINE"); pair(&sb, 8, layer)
        pair(&sb, 10, f(a.x)); pair(&sb, 20, f(-a.y)); pair(&sb, 30, "0")
        pair(&sb, 11, f(b.x)); pair(&sb, 21, f(-b.y)); pair(&sb, 31, "0")
    }

    private static func circle(_ sb: inout String, _ layer: String, _ c: Vec2, _ r: Double) {
        pair(&sb, 0, "CIRCLE"); pair(&sb, 8, layer)
        pair(&sb, 10, f(c.x)); pair(&sb, 20, f(-c.y)); pair(&sb, 30, "0")
        pair(&sb, 40, f(r))
    }

    private static func solid(_ sb: inout String, _ layer: String, _ a: Vec2, _ b: Vec2, _ c: Vec2) {
        pair(&sb, 0, "SOLID"); pair(&sb, 8, layer)
        pair(&sb, 10, f(a.x)); pair(&sb, 20, f(-a.y)); pair(&sb, 30, "0")
        pair(&sb, 11, f(b.x)); pair(&sb, 21, f(-b.y)); pair(&sb, 31, "0")
        pair(&sb, 12, f(c.x)); pair(&sb, 22, f(-c.y)); pair(&sb, 32, "0")
        pair(&sb, 13, f(c.x)); pair(&sb, 23, f(-c.y)); pair(&sb, 33, "0")
    }

    private static func text(_ sb: inout String, _ layer: String, _ center: Vec2, _ string: String, _ height: Double) {
        // DXF TEXT default anchor is left baseline; approximate centering.
        let x = center.x - Double(string.count) * height * 0.4
        let y = -center.y - height * 0.5
        pair(&sb, 0, "TEXT"); pair(&sb, 8, layer)
        pair(&sb, 10, f(x)); pair(&sb, 20, f(y)); pair(&sb, 30, "0")
        pair(&sb, 40, f(height))
        pair(&sb, 1, string)
    }
}
