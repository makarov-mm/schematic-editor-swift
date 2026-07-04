import AppKit
import SchematicCore

/// AC analysis result window: log-log magnitude on top, phase below, one curve per voltage
/// probe. A plain NSWindow with a custom NSView — same hand-drawn approach as the scope.
enum BodeWindowPresenter {
    private static var windows: [NSWindow] = []

    static func present(traces: [(label: String, color: NSColor, freq: [Double], response: [Complex])]) {
        let plot = BodePlotView(traces: traces)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 940, height: 640),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "AC Analysis (1 Hz – 100 kHz)"
        window.contentView = plot
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        windows.append(window)
        windows.removeAll { !$0.isVisible && $0 !== window }
    }
}

final class BodePlotView: NSView {
    private let traces: [(label: String, color: NSColor, freq: [Double], response: [Complex])]

    private let marginLeft: CGFloat = 64
    private let marginRight: CGFloat = 16
    private let marginTop: CGFloat = 28
    private let marginBottom: CGFloat = 30
    private let panelGap: CGFloat = 26

    init(traces: [(label: String, color: NSColor, freq: [Double], response: [Complex])]) {
        self.traces = traces
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let w = bounds.width, h = bounds.height

        NSColor(calibratedRed: 0.07, green: 0.086, blue: 0.11, alpha: 1).setFill()
        ctx.fill(bounds)

        guard let first = traces.first, first.freq.count >= 2, w > 200, h > 200 else { return }

        let gridColor = NSColor(calibratedRed: 0.15, green: 0.18, blue: 0.22, alpha: 1)
        let axisColor = NSColor(calibratedRed: 0.29, green: 0.34, blue: 0.40, alpha: 1)
        let textColor = NSColor(calibratedRed: 0.60, green: 0.65, blue: 0.71, alpha: 1)

        let fMin = first.freq[0]
        let fMax = first.freq[first.freq.count - 1]
        let plotW = w - marginLeft - marginRight
        let magH = (h - marginTop - marginBottom - panelGap) * 0.62
        let phH = (h - marginTop - marginBottom - panelGap) * 0.38
        let magTop = marginTop
        let phTop = marginTop + magH + panelGap

        // Magnitude range across all traces, clamped to sane decades.
        var magMin = Double.greatestFiniteMagnitude
        var magMax = -Double.greatestFiniteMagnitude
        for t in traces {
            for v in t.response {
                let m = max(v.magnitude, 1e-9)
                magMin = min(magMin, m)
                magMax = max(magMax, m)
            }
        }
        var logLo = floor(log10(magMin))
        let logHi = ceil(log10(magMax))
        if logHi - logLo < 2 { logLo = logHi - 2 }
        if logHi - logLo > 8 { logLo = logHi - 8 }

        func xFor(_ f: Double) -> CGFloat { marginLeft + CGFloat((log10(f) - log10(fMin)) / (log10(fMax) - log10(fMin))) * plotW }
        func yMag(_ m: Double) -> CGFloat {
            let clamped = min(max(m, pow(10, logLo)), pow(10, logHi))
            return magTop + magH - CGFloat((log10(clamped) - logLo) / (logHi - logLo)) * magH
        }
        func yPh(_ deg: Double) -> CGFloat { phTop + phH - CGFloat((deg + 180.0) / 360.0) * phH }

        // Frequency decades: vertical grid shared by both panels.
        var d = ceil(log10(fMin))
        while d <= floor(log10(fMax)) {
            let f = pow(10, d)
            let x = xFor(f)
            ctx.setStrokeColor(gridColor.cgColor)
            ctx.setLineWidth(1)
            ctx.move(to: CGPoint(x: x, y: magTop))
            ctx.addLine(to: CGPoint(x: x, y: magTop + magH))
            ctx.move(to: CGPoint(x: x, y: phTop))
            ctx.addLine(to: CGPoint(x: x, y: phTop + phH))
            ctx.strokePath()
            drawString(formatFreq(f), at: CGPoint(x: x, y: h - marginBottom + 6), size: 11, color: textColor, centered: true)
            d += 1
        }

        // Magnitude decades.
        var m = logLo
        while m <= logHi {
            let y = yMag(pow(10, m))
            ctx.setStrokeColor(gridColor.cgColor)
            ctx.move(to: CGPoint(x: marginLeft, y: y))
            ctx.addLine(to: CGPoint(x: marginLeft + plotW, y: y))
            ctx.strokePath()
            drawString(formatMag(pow(10, m)), at: CGPoint(x: marginLeft - 6, y: y - 7), size: 11, color: textColor, rightAligned: true)
            m += 1
        }

        // Phase grid: every 90 degrees, zero line brighter.
        for deg in stride(from: -180, through: 180, by: 90) {
            let y = yPh(Double(deg))
            ctx.setStrokeColor((deg == 0 ? axisColor : gridColor).cgColor)
            ctx.move(to: CGPoint(x: marginLeft, y: y))
            ctx.addLine(to: CGPoint(x: marginLeft + plotW, y: y))
            ctx.strokePath()
            drawString("\(deg)\u{00b0}", at: CGPoint(x: marginLeft - 6, y: y - 7), size: 11, color: textColor, rightAligned: true)
        }

        // Traces.
        for t in traces {
            ctx.setStrokeColor(t.color.cgColor)
            ctx.setLineWidth(1.7)
            ctx.setLineJoin(.round)

            ctx.move(to: CGPoint(x: xFor(t.freq[0]), y: yMag(t.response[0].magnitude)))
            for i in 1..<t.freq.count { ctx.addLine(to: CGPoint(x: xFor(t.freq[i]), y: yMag(t.response[i].magnitude))) }
            ctx.strokePath()

            ctx.move(to: CGPoint(x: xFor(t.freq[0]), y: yPh(t.response[0].phase * 180 / .pi)))
            for i in 1..<t.freq.count { ctx.addLine(to: CGPoint(x: xFor(t.freq[i]), y: yPh(t.response[i].phase * 180 / .pi))) }
            ctx.strokePath()
        }

        // Titles and legend.
        drawString("MAGNITUDE", at: CGPoint(x: marginLeft, y: magTop - 18), size: 10, color: textColor)
        drawString("PHASE", at: CGPoint(x: marginLeft, y: phTop - 18), size: 10, color: textColor)
        var ly = magTop + 4
        for t in traces {
            drawString(t.label, at: CGPoint(x: marginLeft + plotW - 8, y: ly), size: 12, color: t.color, rightAligned: true)
            ly += 16
        }
    }

    private func formatFreq(_ f: Double) -> String {
        if f >= 1e6 { return String(format: "%.4g MHz", f / 1e6) }
        if f >= 1e3 { return String(format: "%.4g kHz", f / 1e3) }
        return String(format: "%.4g Hz", f)
    }

    private func formatMag(_ m: Double) -> String {
        if m >= 1 { return String(format: "%.4g V", m) }
        if m >= 1e-3 { return String(format: "%.4g mV", m * 1e3) }
        return String(format: "%.4g \u{00b5}V", m * 1e6)
    }

    private func drawString(_ text: String, at point: CGPoint, size: CGFloat, color: NSColor, centered: Bool = false, rightAligned: Bool = false) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: size, weight: .regular),
            .foregroundColor: color,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        var p = point
        if centered { p.x -= string.size().width / 2 }
        if rightAligned { p.x -= string.size().width }
        string.draw(at: p)
    }
}
