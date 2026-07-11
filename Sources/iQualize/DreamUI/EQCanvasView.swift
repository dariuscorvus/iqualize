import AppKit
import SwiftUI

@available(macOS 14.2, *)
struct EQCanvasView: View {
    let vm: DreamViewModel

    @Environment(\.dreamTheme) private var theme

    /// Class-based scratchpad held by reference so we don't mutate @State inside Canvas's body.
    @State private var scratch = CanvasScratch()
    @State private var dragState: DragState?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { context in
                    Canvas(rendersAsynchronously: false) { ctx, size in
                        let phase = context.date.timeIntervalSinceReferenceDate
                        // Pull fresh spectrum into the scratchpad each frame.
                        scratch.refreshSpectra(
                            preEq: vm.audioEngine.preEqAnalyzer.spectrumData,
                            postEq: vm.audioEngine.postEqAnalyzer.spectrumData,
                            engineRunning: vm.audioEngine.isRunning
                        )
                        draw(into: &ctx, size: size, phase: phase)
                    }
                }
                .allowsHitTesting(false)

                pointerOverlay(proxy: proxy)

                addButton(.left)
                addButton(.right)
            }
            .background(theme.bgCanvas)
            .clipped()
        }
        .frame(maxWidth: .infinity, minHeight: 380, idealHeight: 380, maxHeight: .infinity)
    }

    // MARK: - +Add buttons

    @ViewBuilder
    private func addButton(_ side: AddSide) -> some View {
        AddBandButton(side: side) { vm.addBand(side == .left ? .left : .right) }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: side == .left ? .leading : .trailing)
            .padding(.horizontal, 8)
    }

    // MARK: - Pointer overlay

    @ViewBuilder
    private func pointerOverlay(proxy: GeometryProxy) -> some View {
        let size = proxy.size
        Rectangle().fill(Color.clear)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in handleDrag(value, in: size) }
                    .onEnded { value in handleDragEnd(value, in: size) }
            )
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): updateHover(at: p, in: size)
                case .ended:         vm.hoverBandID = nil
                }
            }
            .overlay(
                ScrollWheelOverlay(onScroll: { p, dy, shift in
                    handleScroll(at: p, in: size, dy: dy, shift: shift)
                })
            )
            .overlay(
                RightClickOverlay(buildMenu: { event, view in
                    let p = view.convert(event.locationInWindow, from: nil)
                    return contextMenu(for: p, in: size)
                })
            )
            .overlay(
                ModifierOverlay(altPressed: { vm.altPressed = $0 })
            )
    }

    // MARK: - Drawing

    private func draw(into ctx: inout GraphicsContext, size: CGSize, phase: Double) {
        let W = size.width, H = size.height
        let isLight = theme.scheme == .light
        let (ir, ig, ib) = theme.inkRGB

        func ink(_ a: Double) -> Color {
            Color(.sRGB, red: ir, green: ig, blue: ib, opacity: a)
        }

        // Compute display range. Auto-scale grows the y-axis to fit the composite curve peak;
        // otherwise the axis is the user's chosen ±maxGainDB.
        let displayMax = computeDisplayMax(bands: vm.displayBands, W: W)

        // dB grid — generated from the actual range (so ±24 doesn't squish ±12-only bands).
        // Lines are drawn here; the labels are drawn near the end (on top of spectrum) so
        // the spectrum baseline doesn't strike through the bottom dB label.
        let majorStep: Double = displayMax <= 12 ? 6 : displayMax <= 18 ? 6 : 12
        let lines = gridLines(maxDB: displayMax, step: majorStep)
        let extremeMagnitude = lines.map(abs).max() ?? 0
        for db in lines {
            let y = gainToY(db, H: H, maxDB: displayMax)
            let isZero = db == 0
            var path = Path()
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: W, y: y))
            ctx.stroke(
                path,
                with: .color(ink(isZero ? 0.20 : 0.05)),
                style: StrokeStyle(lineWidth: isZero ? 1 : 0.5, dash: isZero ? [] : [2, 4])
            )
        }

        // Frequency grid
        let decades: [Double] = [10, 100, 1000, 10000]
        let minors: [Double] = [
            20,30,40,50,60,70,80,90,
            200,300,400,500,600,700,800,900,
            2000,3000,4000,5000,6000,7000,8000,9000,
            11000,12000,13000,14000,15000,16000,17000,18000,19000
        ]
        for f in minors where f >= 20 && f <= 20000 {
            let x = freqToX(f, W: W)
            var p = Path(); p.move(to: .init(x: x, y: 0)); p.addLine(to: .init(x: x, y: H))
            ctx.stroke(p, with: .color(ink(0.035)), lineWidth: 0.5)
            var t = Path(); t.move(to: .init(x: x, y: H - 1)); t.addLine(to: .init(x: x, y: H - 4))
            ctx.stroke(t, with: .color(ink(0.12)), lineWidth: 1)
        }
        for f in decades where f >= 20 && f <= 20000 {
            let x = freqToX(f, W: W)
            var p = Path(); p.move(to: .init(x: x, y: 0)); p.addLine(to: .init(x: x, y: H))
            ctx.stroke(p, with: .color(ink(0.10)), lineWidth: 1)
            var t = Path(); t.move(to: .init(x: x, y: H - 1)); t.addLine(to: .init(x: x, y: H - 7))
            ctx.stroke(t, with: .color(ink(0.28)), lineWidth: 1)
        }
        // Frequency labels — unit suffixed only on the extremes (20 Hz, 20 kHz). Middle labels stay
        // numeric to avoid a row of repetitive "Hz"/"kHz" tokens.
        let labeled: [Double] = [20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000]
        for f in labeled where f >= 20 && f <= 20000 {
            let x = freqToX(f, W: W)
            let base = f >= 1000 ? "\(Int(f/1000))k" : "\(Int(f))"
            let label: String
            if f == 20 { label = "20 Hz" }
            else if f == 20000 { label = "20 kHz" }
            else { label = base }
            let txt = Text(label).font(.system(size: 10)).foregroundStyle(ink(0.42))
            let anchor: UnitPoint = (f == 20) ? .leading : (f == 20000) ? .trailing : .center
            let px = (f == 20) ? x + 4 : (f == 20000) ? x - 4 : x
            ctx.draw(txt, at: CGPoint(x: px, y: H - 10), anchor: anchor)
        }

        // Semitone snap markers
        if vm.snapToSemitone || vm.altPressed {
            for n in -60...72 {
                let f = 440.0 * pow(2.0, Double(n) / 12.0)
                if f < 20 || f > 20000 { continue }
                let x = freqToX(f, W: W)
                var p = Path(); p.addRect(.init(x: x, y: H - 14, width: 1, height: 8))
                ctx.fill(p, with: .color(Color(rgba: 0x60a5fa, a: 0.18)))
            }
        }

        let dispBands = vm.displayBands

        // Hover-band column glow (when not selected)
        if let hov = vm.hoverBandID, hov != vm.selectedBandID,
           let hb = dispBands.first(where: { $0.id == hov }) {
            let sx = freqToX(Double(hb.frequency), W: W)
            let colW: CGFloat = 48
            let g = Gradient(stops: [
                .init(color: ink(0), location: 0),
                .init(color: ink(0.05), location: 0.5),
                .init(color: ink(0), location: 1)
            ])
            let rect = CGRect(x: sx - colW, y: 0, width: colW * 2, height: H)
            ctx.fill(Path(rect), with: .linearGradient(g, startPoint: CGPoint(x: rect.minX, y: 0), endPoint: CGPoint(x: rect.maxX, y: 0)))
        }

        // Selected-band column glow
        if let sel = vm.selectedBandID, let sb = dispBands.first(where: { $0.id == sel }) {
            let sx = freqToX(Double(sb.frequency), W: W)
            let colW: CGFloat = 56
            let g = Gradient(stops: [
                .init(color: Color(rgba: 0x60a5fa, a: 0), location: 0),
                .init(color: Color(rgba: 0x60a5fa, a: 0.13), location: 0.5),
                .init(color: Color(rgba: 0x60a5fa, a: 0), location: 1)
            ])
            let rect = CGRect(x: sx - colW, y: 0, width: colW * 2, height: H)
            ctx.fill(Path(rect), with: .linearGradient(g, startPoint: CGPoint(x: rect.minX, y: 0), endPoint: CGPoint(x: rect.maxX, y: 0)))
        }

        // Real pre/post-EQ spectrum (only if engine is running and toggle is on)
        if vm.audioEngine.isRunning && vm.preEqEnabled {
            drawRealSpectrum(into: &ctx, size: size, mags: scratch.preEqMags, color: vm.preEqLineColor, fillColor: vm.preEqFillEnabled ? vm.preEqFillColor.opacity(0.18) : nil, displayMax: displayMax)
        }
        if vm.audioEngine.isRunning && vm.postEqEnabled && !vm.bypass {
            drawRealSpectrum(into: &ctx, size: size, mags: scratch.postEqMags, color: vm.postEqLineColor, fillColor: vm.postEqFillEnabled ? vm.postEqFillColor.opacity(0.18) : nil, displayMax: displayMax)
        }

        // Per-band ghost responses
        for b in dispBands {
            let isSel = b.id == vm.selectedBandID
            let isHov = b.id == vm.hoverBandID
            let fillAlpha = isSel ? 0.22 : isHov ? 0.13 : 0.06
            let strokeAlpha = isSel ? 0.55 : isHov ? 0.30 : 0.12

            let zero = gainToY(0, H: H, maxDB: displayMax)
            var pts: [CGPoint] = []
            let N = 120
            for i in 0...N {
                let x = CGFloat(i) / CGFloat(N) * W
                let f = xToFreq(x, W: W)
                let g = bandResponseDB(f: f, band: b)
                pts.append(CGPoint(x: x, y: gainToY(g, H: H, maxDB: displayMax)))
            }
            var fillPath = smoothClosedPath(pts: pts, baselineY: zero)
            ctx.fill(fillPath, with: .color(Color(rgba: 0x60a5fa, a: fillAlpha)))
            var line = smoothPath(pts: pts)
            ctx.stroke(line, with: .color(Color(rgba: 0x60a5fa, a: strokeAlpha)), lineWidth: isSel ? 1.2 : 0.7)
            _ = fillPath; _ = line // silence "unused" if elided
        }

        // Composite EQ curve
        let sampleN = 280
        var samples: [CGPoint] = []
        for i in 0...sampleN {
            let x = CGFloat(i) / CGFloat(sampleN) * W
            let f = xToFreq(x, W: W)
            let total = dispBands.reduce(0.0) { $0 + bandResponseDB(f: f, band: $1) }
            samples.append(CGPoint(x: x, y: gainToY(total, H: H, maxDB: displayMax)))
        }
        let zero = gainToY(0, H: H, maxDB: displayMax)
        var compositeFill = smoothClosedPath(pts: samples, baselineY: zero)
        let grd = Gradient(stops: [
            .init(color: Color(rgba: 0x3b82f6, a: 0.32), location: 0),
            .init(color: Color(rgba: 0x3b82f6, a: 0.05), location: 0.5),
            .init(color: Color(rgba: 0x3b82f6, a: 0.32), location: 1),
        ])
        ctx.fill(compositeFill, with: .linearGradient(grd, startPoint: .zero, endPoint: CGPoint(x: 0, y: H)))
        let compositeLine = smoothPath(pts: samples)
        ctx.stroke(compositeLine, with: .color(theme.accent2), style: StrokeStyle(lineWidth: 2, lineJoin: .round))
        _ = compositeFill; _ = compositeLine

        // dB axis labels — drawn after the spectrum and offset so the text bottom sits 2 pt
        // above the grid line. The previous y-8 offset put the line through the middle of the
        // text, so the bottom-most label looked underlined by the spectrum's silence baseline.
        for db in lines where db != 0 {
            let y = gainToY(db, H: H, maxDB: displayMax)
            let intDb = Int(db.rounded())
            let isExtreme = abs(db) == extremeMagnitude
            let label = (intDb > 0 ? "+\(intDb)" : "\(intDb)") + (isExtreme ? " dB" : "")
            let text = Text(label).font(.system(size: 10, design: .monospaced)).foregroundStyle(ink(0.36))
            ctx.draw(text, at: CGPoint(x: 8, y: y - 2), anchor: .bottomLeading)
            ctx.draw(text, at: CGPoint(x: W - 8, y: y - 2), anchor: .bottomTrailing)
        }

        // Knobs + bandwidth handles + labels
        for b in dispBands {
            let x = freqToX(Double(b.frequency), W: W)
            let y = gainToY(Double(b.gain), H: H, maxDB: displayMax)
            let zero = gainToY(0, H: H, maxDB: displayMax)
            let isSel = b.id == vm.selectedBandID
            let isHov = b.id == vm.hoverBandID || (dragState?.bandID == b.id)
            let opacity: Double = b.muted ? 0.45 : 1.0

            // Q ring on hover/select
            if isSel || isHov {
                let rx = max(14, 50.0 / max(Double(b.bandwidth), 0.3))
                let ry = min(120, abs(Double(b.gain)) * 7 + 18)
                let rect = CGRect(x: x - rx, y: y - ry, width: rx * 2, height: ry * 2)
                ctx.stroke(
                    Path(ellipseIn: rect),
                    with: .color(Color(rgba: 0x60a5fa, a: 0.5 * opacity)),
                    style: StrokeStyle(lineWidth: 0.7, dash: [2, 3])
                )
            }

            // Vertical line zero -> knob
            var v = Path()
            v.move(to: CGPoint(x: x, y: zero))
            v.addLine(to: CGPoint(x: x, y: y))
            ctx.stroke(v, with: .color(theme.accent.opacity((isSel || isHov ? 1.0 : 0.85) * opacity)), style: StrokeStyle(lineWidth: isSel ? 4 : isHov ? 3.5 : 3, lineCap: .round))

            // Bandwidth handles
            if isSel || isHov {
                let rx = max(14.0, 50.0 / max(Double(b.bandwidth), 0.3))
                let lh = CGRect(x: x - rx - 3.5, y: y - 3.5, width: 7, height: 7)
                let rh = CGRect(x: x + rx - 3.5, y: y - 3.5, width: 7, height: 7)
                ctx.fill(Path(ellipseIn: lh), with: .color(theme.accent.opacity(opacity)))
                ctx.fill(Path(ellipseIn: rh), with: .color(theme.accent.opacity(opacity)))
            }

            // Knob
            let knobR: CGFloat = isSel ? 9 : isHov ? 8 : 7
            let knobRect = CGRect(x: x - knobR, y: y - knobR, width: knobR * 2, height: knobR * 2)
            ctx.fill(Path(ellipseIn: knobRect), with: .color((b.muted ? theme.knobFillMuted : theme.knobFillBase).opacity(opacity)))
            ctx.stroke(Path(ellipseIn: knobRect), with: .color(theme.accent.opacity(opacity)), lineWidth: isSel ? 2 : 1.5)

            // Mute slash
            if b.muted {
                let sl = knobR * 0.78
                var s = Path()
                s.move(to: CGPoint(x: x - sl, y: y + sl))
                s.addLine(to: CGPoint(x: x + sl, y: y - sl))
                ctx.stroke(s, with: .color(Color(rgba: 0x141820, a: 0.85 * opacity)), lineWidth: 1.6)
            }

            // dB / Hz labels — only for the selected/hovered band; the readout grid below
            // already surfaces this per-band, so showing it for every knob at once just
            // clutters and overlaps when bands sit close together in frequency.
            if isSel || isHov {
                let dbText = formatDB(b.gain)
                let hzText = formatHz(b.frequency)
                let weightSel: Font.Weight = isSel ? .semibold : .medium
                let dbAlpha: Double = isSel ? (isLight ? 0.78 : 0.98) : (isLight ? 0.62 : 0.86)
                let hzAlpha: Double = isSel ? (isLight ? 0.55 : 0.70) : (isLight ? 0.40 : 0.55)
                let labelW: CGFloat = 60
                let flip = x + knobR + 6 + labelW + 6 > W
                let lx = flip ? x - knobR - 6 : x + knobR + 6
                let dbView = Text(dbText).font(.system(size: isSel ? 12 : 11, weight: weightSel)).foregroundStyle(ink(dbAlpha))
                let hzView = Text(hzText).font(.system(size: isSel ? 11 : 10, weight: isSel ? .medium : .regular)).foregroundStyle(ink(hzAlpha))
                let anchor: UnitPoint = flip ? .trailing : .leading
                ctx.draw(dbView, at: CGPoint(x: lx, y: y - 7), anchor: anchor)
                ctx.draw(hzView, at: CGPoint(x: lx, y: y + 7), anchor: anchor)
            }

            // Bandwidth readout while dragging Q
            if isSel, let drag = dragState, drag.bandID == b.id, drag.mode == .bandwidth {
                let bwText = vm.bandwidthDisplay == .oct
                    ? String(format: "%.2f oct", b.bandwidth)
                    : String(format: "Q %.2f", octavesToQ(Double(b.bandwidth)))
                let bwView = Text(bwText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.bandwidthAccent.opacity(opacity))
                ctx.draw(bwView, at: CGPoint(x: x, y: y - knobR - 8), anchor: .center)
            }
        }
    }

    /// Draw a spectrum trace from real magnitude data (in dB, log-spaced bins 20Hz-20kHz).
    private func drawRealSpectrum(into ctx: inout GraphicsContext, size: CGSize, mags: [Float], color: Color, fillColor: Color?, displayMax: Double) {
        let W = size.width, H = size.height
        let count = mags.count
        guard count > 1 else { return }

        // Light moving-average smoothing in dB to soften the bin-to-bin jitter before splining.
        let smoothed = smoothMagnitudes(mags, window: 3)

        var pts: [CGPoint] = []
        for i in 0..<count {
            let t = Float(i) / Float(count - 1)
            let f = 20.0 * powf(1000.0, t)
            let x = freqToX(Double(f), W: W)
            // Map dBFS (-90..0) onto the visible y-range so silence sits at the bottom and 0 dBFS
            // reaches the top of the chart.
            let db = max(-90.0, Double(smoothed[i]))
            let mapped = (db + 90.0) / 90.0 * (displayMax * 2) - displayMax
            pts.append(CGPoint(x: x, y: gainToY(mapped, H: H, maxDB: displayMax)))
        }

        if let fc = fillColor {
            var p = smoothPath(pts: pts)
            p.addLine(to: CGPoint(x: pts.last!.x, y: H))
            p.addLine(to: CGPoint(x: pts.first!.x, y: H))
            p.closeSubpath()
            ctx.fill(p, with: .linearGradient(
                Gradient(colors: [fc, Color.black.opacity(0)]),
                startPoint: .zero,
                endPoint: CGPoint(x: 0, y: H)
            ))
        }
        let line = smoothPath(pts: pts)
        ctx.stroke(line, with: .color(color.opacity(0.85)), lineWidth: 1.4)
    }

    /// Box-window smoothing on the dB magnitude array (keeps endpoints intact).
    private func smoothMagnitudes(_ mags: [Float], window: Int) -> [Float] {
        guard window > 1, mags.count > window else { return mags }
        let half = window / 2
        var out = mags
        for i in half..<(mags.count - half) {
            var sum: Float = 0
            for k in (i - half)...(i + half) { sum += mags[k] }
            out[i] = sum / Float(window)
        }
        return out
    }

    /// Catmull-Rom spline through `pts`, rendered as cubic Beziers. Open path (line, no fill).
    private func smoothPath(pts: [CGPoint]) -> Path {
        var path = Path()
        guard let first = pts.first else { return path }
        path.move(to: first)
        guard pts.count > 1 else { return path }
        for i in 0..<(pts.count - 1) {
            let p0 = pts[max(0, i - 1)]
            let p1 = pts[i]
            let p2 = pts[i + 1]
            let p3 = pts[min(pts.count - 1, i + 2)]
            let cp1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let cp2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: cp1, control2: cp2)
        }
        return path
    }

    /// Smooth path closed to a baseline (for filled regions like the composite EQ fill).
    private func smoothClosedPath(pts: [CGPoint], baselineY: CGFloat) -> Path {
        guard let first = pts.first, let last = pts.last else { return Path() }
        var path = Path()
        path.move(to: CGPoint(x: first.x, y: baselineY))
        path.addLine(to: first)
        for i in 0..<(pts.count - 1) {
            let p0 = pts[max(0, i - 1)]
            let p1 = pts[i]
            let p2 = pts[i + 1]
            let p3 = pts[min(pts.count - 1, i + 2)]
            let cp1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let cp2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: cp1, control2: cp2)
        }
        path.addLine(to: CGPoint(x: last.x, y: baselineY))
        path.closeSubpath()
        return path
    }

    // MARK: - Pointer helpers

    private func updateHover(at p: CGPoint, in size: CGSize) {
        if dragState != nil { return }
        if let hit = hitTest(p, in: size) {
            vm.hoverBandID = hit.bandID
            return
        }
        let W = size.width
        var best: UUID? = nil
        var bestDx: CGFloat = .infinity
        for b in vm.displayBands {
            let bx = freqToX(Double(b.frequency), W: W)
            let dx = abs(bx - p.x)
            if dx < bestDx { bestDx = dx; best = b.id }
        }
        vm.hoverBandID = (bestDx < 32) ? best : nil
    }

    private func handleDrag(_ value: DragGesture.Value, in size: CGSize) {
        if dragState == nil {
            let p = value.startLocation
            if let hit = hitTest(p, in: size) {
                vm.selectedBandID = hit.bandID
                vm.beginDrag()
                if let band = vm.band(id: hit.bandID) {
                    dragState = DragState(bandID: hit.bandID, mode: hit.mode, side: hit.side, startQ: band.bandwidth, startF: band.frequency, startG: band.gain, startX: p.x)
                }
            } else {
                vm.selectedBandID = nil
            }
        }
        guard let drag = dragState else { return }
        let W = size.width, H = size.height
        let p = value.location
        let displayMax = computeDisplayMax(bands: vm.displayBands, W: W)
        switch drag.mode {
        case .knob:
            let x = max(0, min(W, p.x))
            let y = max(0, min(H, p.y))
            var f = xToFreq(x, W: W)
            let g = max(-Double(vm.gainClamp), min(Double(vm.gainClamp), yToGain(y, H: H, maxDB: displayMax)))
            if vm.snapToSemitone || vm.altPressed {
                f = snapToNearest(f)
            }
            f = max(20, min(20000, f))
            vm.updateBand(id: drag.bandID, frequency: Float(f), gain: Float(g))
        case .bandwidth:
            let dxFrac = (p.x - drag.startX) / W
            let dir: Double = (drag.side == .right) ? 1 : -1
            let newQ = max(0.05, min(8.0, Double(drag.startQ) - dir * Double(dxFrac) * 4))
            vm.updateBand(id: drag.bandID, bandwidth: Float(newQ))
        }
    }

    private func handleDragEnd(_ value: DragGesture.Value, in size: CGSize) {
        if dragState == nil {
            if hitTest(value.location, in: size) == nil {
                vm.selectedBandID = nil
            }
        } else {
            vm.commitDrag(dragState?.mode == .bandwidth ? "Adjust Bandwidth" : "Adjust Band")
        }
        dragState = nil
    }

    private func handleScroll(at p: CGPoint, in size: CGSize, dy: CGFloat, shift: Bool) {
        let W = size.width
        var best: UUID? = nil
        var bestDx: CGFloat = .infinity
        for b in vm.displayBands {
            let bx = freqToX(Double(b.frequency), W: W)
            let dx = abs(bx - p.x)
            if dx < bestDx { bestDx = dx; best = b.id }
        }
        guard bestDx < 32, let id = best, let band = vm.band(id: id) else { return }
        let step: Float = shift ? 0.1 : 0.5
        let dir: Float = dy > 0 ? 1 : -1
        let newG = max(-vm.gainClamp, min(vm.gainClamp, band.gain + dir * step))
        vm.beginDrag()
        vm.updateBand(id: id, gain: newG)
        vm.selectedBandID = id
        scratch.scheduleScrollCommit { vm.commitDrag("Adjust Gain") }
    }

    /// Build a native NSMenu for the canvas context menu. Returns nil if there's nothing to show.
    private func contextMenu(for p: CGPoint, in size: CGSize) -> NSMenu? {
        let hit = hitTest(p, in: size)
        if let hit { vm.selectedBandID = hit.bandID }

        let menu = NSMenu()

        if let bandID = hit?.bandID {
            menu.addItem(MenuAction(title: "Reset Gain") { [vm = self.vm] in
                vm.updateBand(id: bandID, gain: 0, registerUndo: true)
            })

            let muteTitle = (vm.band(id: bandID)?.muted == true) ? "Unmute Band" : "Mute Band"
            let muteItem = MenuAction(title: muteTitle) { [vm = self.vm] in
                vm.toggleMute(id: bandID)
            }
            muteItem.keyEquivalent = "m"
            muteItem.keyEquivalentModifierMask = []
            menu.addItem(muteItem)

            let leftItem = MenuAction(title: "Move Left") { [vm = self.vm] in
                vm.moveBandHorizontally(id: bandID, dir: -1)
            }
            leftItem.keyEquivalent = String(UnicodeScalar(NSLeftArrowFunctionKey)!)
            leftItem.keyEquivalentModifierMask = [.shift, .option]
            menu.addItem(leftItem)

            let rightItem = MenuAction(title: "Move Right") { [vm = self.vm] in
                vm.moveBandHorizontally(id: bandID, dir: 1)
            }
            rightItem.keyEquivalent = String(UnicodeScalar(NSRightArrowFunctionKey)!)
            rightItem.keyEquivalentModifierMask = [.shift, .option]
            menu.addItem(rightItem)

            menu.addItem(.separator())
            menu.addItem(MenuAction(title: "Add Suggested Band") { [vm = self.vm] in
                vm.addBand(.suggest)
            })
            menu.addItem(.separator())

            let delete = MenuAction(title: "Delete Band") { [vm = self.vm] in
                vm.deleteBand(id: bandID)
            }
            delete.keyEquivalent = "\u{8}" // backspace
            delete.keyEquivalentModifierMask = []
            menu.addItem(delete)
        } else {
            menu.addItem(MenuAction(title: "Add Suggested Band") { [vm = self.vm] in
                vm.addBand(.suggest)
            })
            menu.addItem(MenuAction(title: "Add at end") { [vm = self.vm] in
                vm.addBand(.right)
            })
        }

        return menu.items.isEmpty ? nil : menu
    }

    private func hitTest(_ p: CGPoint, in size: CGSize) -> HitResult? {
        let W = size.width, H = size.height
        let displayMax = computeDisplayMax(bands: vm.displayBands, W: W)
        for b in vm.displayBands {
            let x = freqToX(Double(b.frequency), W: W)
            let y = gainToY(Double(b.gain), H: H, maxDB: displayMax)
            if hypot(p.x - x, p.y - y) < 12 { return HitResult(bandID: b.id, mode: .knob, side: .none) }
            let rx = max(14.0, 50.0 / max(Double(b.bandwidth), 0.3))
            if hypot(p.x - (x - rx), p.y - y) < 8 { return HitResult(bandID: b.id, mode: .bandwidth, side: .left) }
            if hypot(p.x - (x + rx), p.y - y) < 8 { return HitResult(bandID: b.id, mode: .bandwidth, side: .right) }
        }
        return nil
    }

    // MARK: - Math (mirrors iqualize-engine.js)

    private func freqToX(_ f: Double, W: CGFloat) -> CGFloat {
        let t = (log10(max(20.0, f)) - log10(20.0)) / (log10(20000.0) - log10(20.0))
        return W * t
    }

    private func xToFreq(_ x: CGFloat, W: CGFloat) -> Double {
        let t = max(0, min(1, x / W))
        return pow(10.0, log10(20.0) + Double(t) * (log10(20000.0) - log10(20.0)))
    }

    /// Pixels of margin above the +max grid line — the dB label sits with its bottom 2 pt above
    /// the line, so we need ~16 pt of clear space (text height ~14 + 2 gap).
    private static let chartTopPad: CGFloat = 16
    /// Pixels of margin below the -max grid line (room for the frequency-axis labels at H − 10).
    private static let chartBotPad: CGFloat = 20

    private func gainToY(_ g: Double, H: CGFloat, maxDB: Double = 15) -> CGFloat {
        let chartH = max(1, H - Self.chartTopPad - Self.chartBotPad)
        return Self.chartTopPad + chartH * (1 - CGFloat((g + maxDB) / (maxDB * 2)))
    }

    private func yToGain(_ y: CGFloat, H: CGFloat, maxDB: Double = 15) -> Double {
        let chartH = max(1, H - Self.chartTopPad - Self.chartBotPad)
        let t = (y - Self.chartTopPad) / chartH
        return (1 - Double(t)) * maxDB * 2 - maxDB
    }

    /// Display y-axis range. Auto-scale grows to fit the composite curve peak; otherwise honors maxGainDB.
    private func computeDisplayMax(bands: [EQBand], W: CGFloat) -> Double {
        if vm.autoScale {
            // Sample the composite curve at a coarse resolution and find its peak magnitude.
            let N = 64
            var peak: Double = 12
            for i in 0...N {
                let x = CGFloat(i) / CGFloat(N) * W
                let f = xToFreq(x, W: W)
                let total = abs(bands.reduce(0.0) { $0 + bandResponseDB(f: f, band: $1) })
                if total > peak { peak = total }
            }
            // Add 20% headroom, clamp to a sensible upper bound, then round to a clean number.
            let target = min(30.0, ceil(peak * 1.2))
            // Snap to nearest 6 dB step so the grid stays tidy.
            let stepped = (target / 6.0).rounded(.up) * 6.0
            return max(12, stepped)
        }
        return Double(vm.maxGainDB)
    }

    /// Returns dB grid line positions for the given range, including 0.
    private func gridLines(maxDB: Double, step: Double) -> [Double] {
        var v = step
        var lines: [Double] = [0]
        while v <= maxDB + 0.01 {
            lines.append(v)
            lines.append(-v)
            v += step
        }
        return lines.sorted()
    }

    /// Bell-style approximation matching iqualize-engine.js bandResponse for visual parity.
    private func bandResponseDB(f: Double, band: EQBand) -> Double {
        if band.muted { return 0 }
        let r = f / Double(band.frequency)
        let log2r = log2(r)
        let oct = max(0.05, Double(band.bandwidth))
        let g = Double(band.gain)
        switch band.filterType {
        case .parametric:
            return g / (1 + pow(log2r / oct, 2))
        case .lowShelf:
            let k = 4 / oct
            return g * (1 / (1 + exp(k * log2r)))
        case .highShelf:
            let k = 4 / oct
            return g * (1 / (1 + exp(-k * log2r)))
        case .lowPass:
            if log2r <= 0 { return 0 }
            return -12 * log2r
        case .highPass:
            if log2r >= 0 { return 0 }
            return 12 * log2r
        case .bandPass:
            return -12 + 12 / (1 + pow(log2r / oct, 2))
        case .notch:
            return -24 / (1 + pow(log2r / (oct * 0.3), 2))
        }
    }

    /// Round-frequency anchors used by `snapToNearest` — multiples of 10/100/1k/10k from 20 Hz to 20 kHz.
    /// Mirrors the prototype's `IQ.ROUND_FREQS` list (~36 entries, not the dense per-10 grid the
    /// previous Swift port accidentally generated).
    private static let roundAnchors: [Double] = {
        var out: [Double] = []
        var dec = 10.0
        while dec <= 10000 {
            for m in 1...9 {
                let f = dec * Double(m)
                if f >= 20 && f <= 20000 { out.append(f) }
            }
            dec *= 10
        }
        if !out.contains(20000) { out.append(20000) }
        return out
    }()

    private func snapToNearest(_ f: Double) -> Double {
        // Nearest semitone of A4 = 440 chromatic ladder.
        let semis = 12 * log2(f / 440)
        let semitone = 440 * pow(2.0, round(semis) / 12)

        // Nearest "round" anchor from the sparse list.
        var bestRound = Self.roundAnchors[0]
        var bestD = abs(log2(f / bestRound))
        for r in Self.roundAnchors {
            let d = abs(log2(f / r))
            if d < bestD { bestD = d; bestRound = r }
        }

        // Pick whichever target is closer in log space.
        return abs(log2(f / semitone)) < abs(log2(f / bestRound)) ? semitone : bestRound
    }

    private func octavesToQ(_ oct: Double) -> Double {
        1 / (2 * sinh(Foundation.log(2.0) * 0.5 * oct))
    }
}

// MARK: - Helpers

private enum AddSide { case left, right }

@available(macOS 14.2, *)
private struct AddBandButton: View {
    let side: AddSide
    let action: () -> Void

    @Environment(\.dreamTheme) private var theme
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text("+")
                .font(.system(size: 16, weight: .light))
                .foregroundStyle(hover ? theme.accent2 : theme.textDim)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(hover ? theme.accent.opacity(0.12) : theme.bgControl)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(hover ? theme.accent : theme.line, lineWidth: 1)
                )
                .animation(.easeOut(duration: 0.12), value: hover)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
private enum DragMode { case knob, bandwidth }
private enum DragSide { case left, right, none }

private struct DragState {
    let bandID: UUID
    let mode: DragMode
    let side: DragSide
    let startQ: Float
    let startF: Float
    let startG: Float
    let startX: CGFloat
}

private struct HitResult {
    let bandID: UUID
    let mode: DragMode
    let side: DragSide
}

/// Reference-typed scratchpad. Held inside @State for stability across redraws,
/// but mutated *outside* SwiftUI's body invariants (no @State setters fired).
final class CanvasScratch {
    var preEqMags: [Float] = Array(repeating: -90, count: SpectrumData.binCount)
    var postEqMags: [Float] = Array(repeating: -90, count: SpectrumData.binCount)
    private var peaksScratch: [Float] = Array(repeating: -90, count: SpectrumData.binCount)
    private var scrollCommitTask: Task<Void, Never>?

    func refreshSpectra(preEq: SpectrumData, postEq: SpectrumData, engineRunning: Bool) {
        guard engineRunning else {
            for i in preEqMags.indices { preEqMags[i] = -90 }
            for i in postEqMags.indices { postEqMags[i] = -90 }
            return
        }
        preEqMags.withUnsafeMutableBufferPointer { mags in
            peaksScratch.withUnsafeMutableBufferPointer { peaks in
                preEq.read(mags.baseAddress!, peaks: peaks.baseAddress!)
            }
        }
        postEqMags.withUnsafeMutableBufferPointer { mags in
            peaksScratch.withUnsafeMutableBufferPointer { peaks in
                postEq.read(mags.baseAddress!, peaks: peaks.baseAddress!)
            }
        }
    }

    @MainActor
    func scheduleScrollCommit(_ commit: @escaping @MainActor () -> Void) {
        scrollCommitTask?.cancel()
        scrollCommitTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            if !Task.isCancelled { commit() }
        }
    }
}

// MARK: - AppKit overlays for scroll wheel, right click, and modifier keys

@available(macOS 14.2, *)
struct ScrollWheelOverlay: NSViewRepresentable {
    var onScroll: (CGPoint, CGFloat, Bool) -> Void

    func makeNSView(context: Context) -> ScrollHandlerView {
        let v = ScrollHandlerView()
        v.onScroll = onScroll
        return v
    }
    func updateNSView(_ nsView: ScrollHandlerView, context: Context) {
        nsView.onScroll = onScroll
    }
}

final class ScrollHandlerView: NSView {
    var onScroll: ((CGPoint, CGFloat, Bool) -> Void)?
    override var isFlipped: Bool { true }
    /// Only claim hit-tests for scroll events — every other input falls through to the views below.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = NSApp.currentEvent, event.type == .scrollWheel else { return nil }
        return self
    }
    override func scrollWheel(with event: NSEvent) {
        let dy = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : -event.scrollingDeltaX
        guard dy != 0 else { return }
        let p = convert(event.locationInWindow, from: nil)
        onScroll?(p, dy, event.modifierFlags.contains(.shift))
    }
}

@available(macOS 14.2, *)
struct RightClickOverlay: NSViewRepresentable {
    /// Called when right-click happens. Should return an NSMenu to pop up at the click,
    /// or nil to do nothing.
    var buildMenu: (NSEvent, NSView) -> NSMenu?

    func makeNSView(context: Context) -> RightClickHandlerView {
        let v = RightClickHandlerView()
        v.buildMenu = buildMenu
        return v
    }
    func updateNSView(_ nsView: RightClickHandlerView, context: Context) {
        nsView.buildMenu = buildMenu
    }
}

final class RightClickHandlerView: NSView {
    var buildMenu: ((NSEvent, NSView) -> NSMenu?)?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        if let event = NSApp.currentEvent, event.type == .rightMouseDown { return self }
        return nil
    }
    override func rightMouseDown(with event: NSEvent) {
        if let menu = buildMenu?(event, self) {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }
    }
}

/// NSMenuItem subclass that runs a closure when activated. Used so we can build the canvas
/// context menu inline without scattering @objc selectors across the file.
final class MenuAction: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        self.target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    @objc private func invoke() { handler() }
}

@available(macOS 14.2, *)
struct ModifierOverlay: NSViewRepresentable {
    var altPressed: (Bool) -> Void

    func makeNSView(context: Context) -> ModifierHandlerView {
        let v = ModifierHandlerView()
        v.altPressed = altPressed
        return v
    }
    func updateNSView(_ nsView: ModifierHandlerView, context: Context) {
        nsView.altPressed = altPressed
    }
}

final class ModifierHandlerView: NSView {
    var altPressed: ((Bool) -> Void)?
    nonisolated(unsafe) private var monitor: Any?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                self?.altPressed?(event.modifierFlags.contains(.option))
                return event
            }
        }
    }
    deinit {
        if let m = monitor { NSEvent.removeMonitor(m) }
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
