import AppKit
import SwiftUI

/// AppKit spectrum layer driven by a timer — not SwiftUI `TimelineView`.
///
/// `TimelineView` inside `NSHostingView` forced a full hosting-view layout pass
/// (~23×/s) even after the EQ curve was split onto a separate Canvas. That layout
/// cost dominated the remaining CPU. This view only `setNeedsDisplay`s itself.
@available(macOS 14.2, *)
struct SpectrumOverlayView: NSViewRepresentable {
    var preEq: SpectrumData
    var postEq: SpectrumData
    var engineRunning: Bool
    var preEnabled: Bool
    var postEnabled: Bool
    var preLine: NSColor
    var postLine: NSColor
    var preFill: NSColor?
    var postFill: NSColor?
    var displayMax: Double
    var domain: ClosedRange<Double>

    func makeNSView(context: Context) -> SpectrumOverlayNSView {
        SpectrumOverlayNSView()
    }

    func updateNSView(_ view: SpectrumOverlayNSView, context: Context) {
        view.preEq = preEq
        view.postEq = postEq
        view.engineRunning = engineRunning
        view.preEnabled = preEnabled
        view.postEnabled = postEnabled
        view.preLine = preLine
        view.postLine = postLine
        view.preFill = preFill
        view.postFill = postFill
        view.displayMax = displayMax
        view.domain = domain
        view.setNeedsDisplay(view.bounds)
    }

    static func dismantleNSView(_ view: SpectrumOverlayNSView, coordinator: ()) {
        view.stop()
    }
}

@available(macOS 14.2, *)
final class SpectrumOverlayNSView: NSView {
    private static let leftPad: CGFloat = 14
    private static let rightPad: CGFloat = 14
    private static let topPad: CGFloat = 16
    private static let botPad: CGFloat = 20

    var preEq: SpectrumData?
    var postEq: SpectrumData?
    var engineRunning = false
    var preEnabled = false
    var postEnabled = false
    var preLine = NSColor.systemCyan
    var postLine = NSColor.systemOrange
    var preFill: NSColor?
    var postFill: NSColor?
    var displayMax: Double = 12
    var domain: ClosedRange<Double> = 20...20_000

    private var timer: Timer?
    private var preMags = [Float](repeating: -90, count: SpectrumData.binCount)
    private var postMags = [Float](repeating: -90, count: SpectrumData.binCount)
    private var peaksScratch = [Float](repeating: -90, count: SpectrumData.binCount)
    private var smoothScratch = [Float](repeating: -90, count: SpectrumData.binCount)

    override var isOpaque: Bool { false }
    override var wantsDefaultClipping: Bool { false }
    /// Match SwiftUI `Canvas` (y grows downward).
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = .clear
        start()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func start() {
        guard timer == nil else { return }
        let t = Timer(
            timeInterval: SpectrumAnalyzer.targetInterval,
            target: self,
            selector: #selector(tick),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    @objc private func tick() {
        setNeedsDisplay(bounds)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stop()
        } else {
            start()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let size = bounds.size
        guard size.width > 1, size.height > 1 else { return }

        refreshMags()
        if preEnabled {
            strokeSpectrum(ctx: ctx, size: size, mags: preMags, color: preLine, fill: preFill)
        }
        if postEnabled {
            strokeSpectrum(ctx: ctx, size: size, mags: postMags, color: postLine, fill: postFill)
        }
    }

    private func refreshMags() {
        guard engineRunning else {
            for i in preMags.indices { preMags[i] = -90; postMags[i] = -90 }
            return
        }
        if let preEq {
            preMags.withUnsafeMutableBufferPointer { mags in
                peaksScratch.withUnsafeMutableBufferPointer { peaks in
                    preEq.read(mags.baseAddress!, peaks: peaks.baseAddress!)
                }
            }
        }
        if let postEq {
            postMags.withUnsafeMutableBufferPointer { mags in
                peaksScratch.withUnsafeMutableBufferPointer { peaks in
                    postEq.read(mags.baseAddress!, peaks: peaks.baseAddress!)
                }
            }
        }
    }

    private func strokeSpectrum(
        ctx: CGContext, size: CGSize, mags: [Float], color: NSColor, fill: NSColor?
    ) {
        let count = mags.count
        guard count > 1 else { return }
        boxSmooth(mags, into: &smoothScratch)

        let W = size.width, H = size.height
        let maxDB = displayMax

        ctx.saveGState()
        ctx.setLineWidth(1.4)
        ctx.setLineJoin(.round)

        let path = CGMutablePath()
        var lastY: CGFloat = 0
        for i in 0..<count {
            let t = Float(i) / Float(count - 1)
            let f = 20.0 * powf(1000.0, t)
            let x = freqToX(Double(f), W: W)
            let db = max(-90.0, Double(smoothScratch[i]))
            let mapped = (db + 90.0) / 90.0 * (maxDB * 2) - maxDB
            let y = gainToY(mapped, H: H, maxDB: maxDB)
            if i == 0 {
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
            lastY = y
        }
        path.addLine(to: CGPoint(x: W, y: lastY))

            if let fill {
                let fillPath = path.mutableCopy() ?? CGMutablePath()
                fillPath.addLine(to: CGPoint(x: W, y: H))
                fillPath.addLine(to: CGPoint(x: 0, y: H))
                fillPath.closeSubpath()
                ctx.addPath(fillPath)
                ctx.clip()
                let colors = [fill.cgColor, CGColor(gray: 0, alpha: 0)] as CFArray
                let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
                if let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) {
                    ctx.drawLinearGradient(
                        gradient,
                        start: .zero,
                        end: CGPoint(x: 0, y: H),
                        options: []
                    )
                }
                ctx.resetClip()
            }

        ctx.addPath(path)
        ctx.setStrokeColor(color.withAlphaComponent(0.85).cgColor)
        ctx.strokePath()
        ctx.restoreGState()
    }

    private func boxSmooth(_ mags: [Float], into out: inout [Float]) {
        let window = 3
        let half = window / 2
        out = mags
        guard mags.count > window else { return }
        for i in half..<(mags.count - half) {
            var sum: Float = 0
            for k in (i - half)...(i + half) { sum += mags[k] }
            out[i] = sum / Float(window)
        }
    }

    private func freqToX(_ f: Double, W: CGFloat) -> CGFloat {
        let chartW = max(1, W - Self.leftPad - Self.rightPad)
        let lo = domain.lowerBound, hi = domain.upperBound
        let t = (log10(max(0.0001, f)) - log10(lo)) / (log10(hi) - log10(lo))
        return Self.leftPad + chartW * CGFloat(t)
    }

    private func gainToY(_ g: Double, H: CGFloat, maxDB: Double) -> CGFloat {
        let chartH = max(1, H - Self.topPad - Self.botPad)
        return Self.topPad + chartH * (1 - CGFloat((g + maxDB) / (maxDB * 2)))
    }
}

