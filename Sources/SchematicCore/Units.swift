import Foundation

/// Parses component values like "10k", "4.7k", "100n", "12V", "50Hz", "12V 5W".
/// Multiplier prefixes are case-sensitive where it matters (m = milli, M = mega).
public enum Units {
    public static func parse(_ text: String?) -> Double? {
        guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }

        var index = text.startIndex
        while index < text.endIndex, text[index].isNumber || text[index] == "." || text[index] == "-" || text[index] == "+" {
            index = text.index(after: index)
        }
        guard index > text.startIndex, let number = Double(text[text.startIndex..<index]) else { return nil }

        var rest = String(text[index...]).trimmingCharacters(in: .whitespaces)
        var multiplier = 1.0

        if !rest.isEmpty {
            if rest.lowercased().hasPrefix("meg") {
                multiplier = 1e6
                rest = String(rest.dropFirst(3))
            } else if !isUnitWord(rest) {
                switch rest.first! {
                case "p": multiplier = 1e-12
                case "n": multiplier = 1e-9
                case "u", "\u{00b5}": multiplier = 1e-6
                case "m": multiplier = 1e-3
                case "k", "K": multiplier = 1e3
                case "M": multiplier = 1e6
                case "G": multiplier = 1e9
                default: return nil
                }
                rest = String(rest.dropFirst())
            }
        }

        if !rest.isEmpty && !isUnitWord(rest) { return nil }
        return number * multiplier
    }

    private static func isUnitWord(_ s: String) -> Bool {
        let lower = s.lowercased()
        return lower == "v" || lower == "a" || lower == "w" || lower == "hz" || lower == "f" || lower == "h" || lower == "ohm" || lower == "r" || lower == "\u{03c9}"
    }

    /// Parse "12V 5W" style lamp ratings into (resistance, ratedPower).
    public static func parseLampRating(_ text: String?) -> (resistance: Double, ratedPower: Double)? {
        guard let text, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }

        var volts: Double?
        var watts: Double?
        var ohms: Double?
        for part in text.split(separator: " ") {
            let piece = String(part)
            if piece.hasSuffix("W"), let w = parse(piece) { watts = w }
            else if piece.hasSuffix("V"), let v = parse(piece) { volts = v }
            else if let r = parse(piece) { ohms = r }
        }

        if let v = volts, let w = watts, w > 0 { return (v * v / w, w) }
        if let r = ohms, r > 0 { return (r, watts ?? 1) }
        return nil
    }

    /// Parse "5V 50Hz" style AC source specs into (amplitude, frequency).
    public static func parseAcSpec(_ text: String?) -> (amplitude: Double, frequency: Double)? {
        guard let text, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }

        var amplitude = 5.0
        var frequency = 50.0
        var any = false
        for part in text.split(separator: " ") {
            let piece = String(part)
            if piece.lowercased().hasSuffix("hz"), let f = parse(piece) {
                frequency = f
                any = true
            } else if let a = parse(piece) {
                amplitude = a
                any = true
            }
        }
        return any ? (amplitude, frequency) : nil
    }
}
