import AppKit
import SwiftUI
import SchematicCore

/// Rolling oscilloscope for the controller's probes. The vertical scale follows the actual
/// [min..max] of the visible window (not a symmetric ±peak), so DC-offset signals fill the
/// screen and their ripple stays visible. Gridlines land on a 1-2-5 ladder; the zero axis is
/// drawn whenever it falls inside the window. Traces decimate to roughly one point per pixel.
final class ScopeNSView: NSView {
    unowned let controller: EditorController

    var windowSeconds: Double = 0.2 {
        didSet { needsDisplay = true }
    }

    init(controller: EditorController) {
        self.controller = controller
        super.init(frame: .zero)
        wantsLayer = true
        controller.scopeNeedsDisplay = { [weak self] in self?.needsDisplay = true }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let w = bounds.width, h = bounds.height
        guard w > 10, h > 10 else { return }

        NSColor(calibratedRed: 0.07, green: 0.086, blue: 0.11, alpha: 1).setFill()
        ctx.fill(bounds)

        let gridColor = NSColor(calibratedRed: 0.15, green: 0.18, blue: 0.22, alpha: 1)
        let axisColor = NSColor(calibratedRed: 0.29, green: 0.34, blue: 0.40, alpha: 1)
        let textColor = NSColor(calibratedRed: 0.60, green: 0.65, blue: 0.71, alpha: 1)

        // Time graticule: 10 divisions.
        ctx.setStrokeColor(gridColor.cgColor)
        ctx.setLineWidth(1)
        for i in 1..<10 {
            let x = w * CGFloat(i) / 10
            ctx.move(to: CGPoint(x: x, y: 0))
            ctx.addLine(to: CGPoint(x: x, y: h))
        }
        ctx.strokePath()

        let probes = controller.probes
        if probes.isEmpty {
            for i in 1..<6 {
                let y = h * CGFloat(i) / 6
                ctx.move(to: CGPoint(x: 0, y: y))
                ctx.addLine(to: CGPoint(x: w, y: y))
            }
            ctx.strokePath()
            drawString("Arm the probe tool and click a wire (voltage) or a component (current).", at: CGPoint(x: w / 2, y: h / 2 - 7), size: 12, color: textColor, centered: true)
            return
        }

        var tNow = controller.simTime
        if !controller.isRunning {
            for p in probes where !p.times.isEmpty { tNow = max(tNow, Double(p.times[p.times.count - 1])) }
        }
        let t0 = tNow - windowSeconds

        // Range of the visible window across all traces.
        var vmin = Double.greatestFiniteMagnitude
        var vmax = -Double.greatestFiniteMagnitude
        for p in probes {
            var i = p.values.count - 1
            while i >= 0, Double(p.times[i]) >= t0 {
                let v = Double(p.values[i])
                vmin = min(vmin, v)
                vmax = max(vmax, v)
                i -= 1
            }
        }
        if vmin > vmax {
            vmin = -1
            vmax = 1
        }

        var span = vmax - vmin
        let minSpan = max(1e-6, max(abs(vmax), abs(vmin)) * 0.02)
        if span < minSpan {
            let mid = (vmin + vmax) / 2
            vmin = mid - minSpan / 2
            vmax = mid + minSpan / 2
            span = minSpan
        }
        let lo = vmin - span * 0.07
        let hi = vmax + span * 0.07

        let marginY: CGFloat = 8
        func yFor(_ v: Double) -> CGFloat { h - marginY - CGFloat((v - lo) / (hi - lo)) * (h - 2 * marginY) }
        func xFor(_ t: Double) -> CGFloat { CGFloat((t - t0) / windowSeconds) * w }

        // Value gridlines on a 1-2-5 ladder, labelled at the right edge.
        let step = niceCeil((hi - lo) / 6)
        var v = (lo / step).rounded(.up) * step
        while v <= hi + step * 1e-9 {
            let y = yFor(v)
            let isZero = abs(v) < step * 1e-6
            ctx.setStrokeColor((isZero ? axisColor : gridColor).cgColor)
            ctx.move(to: CGPoint(x: 0, y: y))
            ctx.addLine(to: CGPoint(x: w, y: y))
            ctx.strokePath()
            drawString(formatValue(v), at: CGPoint(x: w - 6, y: y - 13), size: 10, color: textColor, rightAligned: true)
            v += step
        }

        // Traces.
        for p in probes {
            let count = p.values.count
            guard count >= 2 else { continue }
            var first = count - 1
            while first > 0, Double(p.times[first - 1]) >= t0 { first -= 1 }
            let visible = count - first
            guard visible >= 2 else { continue }
            let stride = max(1, visible / max(64, Int(w)))

            ctx.setStrokeColor(p.color.cgColor)
            ctx.setLineWidth(1.6)
            ctx.setLineJoin(.round)
            ctx.move(to: CGPoint(x: xFor(Double(p.times[first])), y: yFor(Double(p.values[first]))))
            var i = first + stride
            while i < count {
                ctx.addLine(to: CGPoint(x: xFor(Double(p.times[i])), y: yFor(Double(p.values[i]))))
                i += stride
            }
            ctx.addLine(to: CGPoint(x: xFor(Double(p.times[count - 1])), y: yFor(Double(p.values[count - 1]))))
            ctx.strokePath()
        }

        // Legend with live values.
        var ly: CGFloat = 6
        for p in probes {
            let unit = p.isCurrent ? "A" : "V"
            drawString("\(p.label)  \(SchematicNSView.formatSi(p.lastValue, unit))", at: CGPoint(x: 8, y: ly), size: 12, color: p.color)
            ly += 16
        }

        let caption = windowSeconds >= 1 ? String(format: "%.1f s", windowSeconds) : String(format: "%.0f ms", windowSeconds * 1000)
        drawString(caption, at: CGPoint(x: w - 6, y: h - 18), size: 11, color: textColor, rightAligned: true)
    }

    private func niceCeil(_ value: Double) -> Double {
        let p = pow(10, floor(log10(value)))
        let m = value / p
        return (m <= 1 ? 1 : m <= 2 ? 2 : m <= 5 ? 5 : 10) * p
    }

    private func formatValue(_ v: Double) -> String {
        let a = abs(v)
        if a < 1e-12 { return "0" }
        let (m, suffix): (Double, String)
        switch a {
        case 1e6...: (m, suffix) = (1e-6, "M")
        case 1e3...: (m, suffix) = (1e-3, "k")
        case 1...: (m, suffix) = (1, "")
        case 1e-3...: (m, suffix) = (1e3, "m")
        case 1e-6...: (m, suffix) = (1e6, "\u{00b5}")
        default: (m, suffix) = (1e9, "n")
        }
        return String(format: "%.3g%@", v * m, suffix)
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

struct ScopeView: NSViewRepresentable {
    let controller: EditorController
    @Binding var windowSeconds: Double

    func makeNSView(context: Context) -> ScopeNSView { ScopeNSView(controller: controller) }

    func updateNSView(_ view: ScopeNSView, context: Context) {
        view.windowSeconds = windowSeconds
        view.needsDisplay = true
    }
}
