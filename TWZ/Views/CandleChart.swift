//
//  CandleChart.swift
//  TWZ
//
//  Lightweight candlestick + volume chart drawn with a single SwiftUI Canvas.
//  Trackpad: two-finger swipe left/right to pan (with momentum), up/down or pinch to zoom
//  around the cursor. Mouse: wheel zooms, shift-wheel pans. Drag pans, double-click resets.
//

import SwiftUI
import AppKit

struct PriceLine {
    var price: Double
    var color: Color
    var label: String
}

struct CandleChart: View {
    let chart: ChartModel
    var lastPrice: Double?
    var lines: [PriceLine] = []

    @AppStorage(CandleTheme.storageKey) private var candleTheme: CandleTheme = .teal
    @AppStorage(CandleTheme.customUpKey) private var customUp = CandleTheme.defaultUpHex
    @AppStorage(CandleTheme.customDownKey) private var customDown = CandleTheme.defaultDownHex
    @State private var hover: CGPoint?
    @State private var dragStartScroll: Double?

    private let axisWidth: CGFloat = 58
    private let timeAxisHeight: CGFloat = 16
    private let rightPaddingBars = 3.0

    var body: some View {
        GeometryReader { geo in
            let plotWidth = max(1, geo.size.width - axisWidth)
            Canvas(rendersAsynchronously: false) { ctx, size in
                draw(in: &ctx, size: size)
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                if case .active(let p) = phase { hover = p } else { hover = nil }
            }
            .gesture(panGesture(plotWidth: plotWidth))
            .onTapGesture(count: 2) {
                chart.scrollBack = 0
                chart.visibleBars = 120
            }
            .background(ScrollCatcher(
                onScroll: { dx, dy, location in
                    if dx != 0 { pan(byPoints: dx, plotWidth: plotWidth) }
                    if dy != 0 { zoom(by: exp(-dy * 0.01), at: location.x, plotWidth: plotWidth) }
                },
                onMagnify: { magnification, location in
                    zoom(by: 1 / (1 + magnification), at: location.x, plotWidth: plotWidth)
                }
            ))
        }
    }

    // MARK: Viewport

    private func barWidth(plotWidth: CGFloat) -> CGFloat {
        plotWidth / (chart.visibleBars + rightPaddingBars)
    }

    /// Clamped write: never past the oldest bars, and at most half a screen into the future.
    private func setScrollBack(_ value: Double) {
        let maxBack = max(0, Double(chart.bars.count) - 10)
        chart.scrollBack = min(maxBack, max(-chart.visibleBars / 2, value))
    }

    /// Positive points move the content right (revealing older bars).
    private func pan(byPoints points: CGFloat, plotWidth: CGFloat) {
        setScrollBack(chart.scrollBack + Double(points / barWidth(plotWidth: plotWidth)))
    }

    /// Scales the number of visible bars by `factor`, keeping the bar under `anchorX` in place.
    private func zoom(by factor: Double, at anchorX: CGFloat, plotWidth: CGFloat) {
        let x = min(plotWidth, max(0, anchorX))
        let oldWidth = barWidth(plotWidth: plotWidth)
        chart.visibleBars = min(600, max(15, chart.visibleBars * factor))
        let newWidth = barWidth(plotWidth: plotWidth)
        let fromRight = Double(plotWidth - x)
        setScrollBack(chart.scrollBack + fromRight / oldWidth - fromRight / newWidth)
    }

    // MARK: Gestures

    private func panGesture(plotWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                let start = dragStartScroll ?? chart.scrollBack
                dragStartScroll = start
                setScrollBack(start + Double(value.translation.width / barWidth(plotWidth: plotWidth)))
            }
            .onEnded { _ in dragStartScroll = nil }
    }

    // MARK: Drawing

    private func draw(in ctx: inout GraphicsContext, size: CGSize) {
        let bars = chart.bars
        let plot = CGRect(x: 0, y: 4, width: size.width - axisWidth, height: size.height - timeAxisHeight - 4)
        guard plot.width > 20, plot.height > 20 else { return }

        guard !bars.isEmpty else {
            let msg = chart.isLoading ? "Loading…" : (chart.error ?? (chart.symbol.isEmpty ? "Enter a symbol" : "No data"))
            ctx.draw(Text(msg).font(.system(size: 11)).foregroundStyle(.secondary),
                     at: CGPoint(x: size.width / 2, y: size.height / 2))
            return
        }

        // Visible window, anchored to the right edge. scrollBack is fractional so panning is smooth.
        let slots = chart.visibleBars + rightPaddingBars
        let barWidth = plot.width / slots
        let anchor = Double(bars.count) - chart.scrollBack   // index just past the bar at the anchor slot
        let anchorX = plot.maxX - CGFloat(rightPaddingBars) * barWidth
        let end = min(bars.count, max(1, Int((anchor + rightPaddingBars).rounded(.up))))
        let start = min(end - 1, max(0, Int((anchor - chart.visibleBars).rounded(.down))))
        let visible = bars[start..<end]
        func x(_ index: Int) -> CGFloat {
            anchorX - CGFloat(anchor - Double(index) - 0.5) * barWidth
        }
        // Bars partially scrolled past the edges are clipped; axis tags draw on the unclipped context.
        var plotCtx = ctx
        plotCtx.clip(to: Path(CGRect(x: 0, y: 0, width: plot.maxX, height: size.height)))

        // Price area takes the top 80%, volume the bottom 20%.
        let volumeHeight = plot.height * 0.18
        let priceRect = CGRect(x: plot.minX, y: plot.minY, width: plot.width, height: plot.height - volumeHeight - 4)

        var lo = visible.map(\.low).min() ?? 0
        var hi = visible.map(\.high).max() ?? 1
        if chart.scrollBack < 1, let lastPrice { lo = min(lo, lastPrice); hi = max(hi, lastPrice) }
        if hi - lo < 1e-9 { hi += 0.01; lo -= 0.01 }
        let pad = (hi - lo) * 0.06
        lo -= pad; hi += pad
        func y(_ price: Double) -> CGFloat {
            priceRect.maxY - CGFloat((price - lo) / (hi - lo)) * priceRect.height
        }
        func price(at yPos: CGFloat) -> Double {
            lo + Double((priceRect.maxY - yPos) / priceRect.height) * (hi - lo)
        }

        let gridColor = Color.primary.opacity(0.07)
        let labelColor = Color.secondary
        let (up, down) = candleTheme.colors(customUp: customUp, customDown: customDown)

        // Horizontal grid + price labels.
        for tick in Self.niceTicks(lo: lo, hi: hi, count: max(3, Int(priceRect.height / 45))) {
            let yy = y(tick)
            var path = Path()
            path.move(to: CGPoint(x: plot.minX, y: yy))
            path.addLine(to: CGPoint(x: plot.maxX, y: yy))
            ctx.stroke(path, with: .color(gridColor), lineWidth: 1)
            ctx.draw(Text(Fmt.price(tick)).font(.system(size: 10).monospacedDigit()).foregroundStyle(labelColor),
                     at: CGPoint(x: plot.maxX + 6, y: yy), anchor: .leading)
        }

        // Vertical grid + time labels, roughly every 90px.
        let labelEvery = max(1, Int((90 / barWidth).rounded(.up)))
        for i in start..<end where i % labelEvery == 0 {
            let xx = x(i)
            var path = Path()
            path.move(to: CGPoint(x: xx, y: plot.minY))
            path.addLine(to: CGPoint(x: xx, y: plot.maxY))
            plotCtx.stroke(path, with: .color(gridColor), lineWidth: 1)
            plotCtx.draw(Text(timeLabel(bars[i].time)).font(.system(size: 9).monospacedDigit()).foregroundStyle(labelColor),
                     at: CGPoint(x: xx, y: plot.maxY + timeAxisHeight / 2 + 1))
        }

        // Volume.
        let maxVolume = visible.map(\.volume).max() ?? 0
        if maxVolume > 0 {
            var upVol = Path(), downVol = Path()
            for i in start..<end {
                let b = bars[i]
                let h = CGFloat(b.volume / maxVolume) * volumeHeight
                let rect = CGRect(x: x(i) - barWidth * 0.35, y: plot.maxY - h, width: max(1, barWidth * 0.7), height: h)
                if b.close >= b.open { upVol.addRect(rect) } else { downVol.addRect(rect) }
            }
            plotCtx.fill(upVol, with: .color(up.opacity(0.35)))
            plotCtx.fill(downVol, with: .color(down.opacity(0.35)))
        }

        // Candles: batch into two paths per color for speed.
        var upWicks = Path(), downWicks = Path(), upBodies = Path(), downBodies = Path()
        let bodyWidth = max(1, barWidth * 0.7)
        for i in start..<end {
            let b = bars[i]
            let xx = x(i)
            let isUp = b.close >= b.open
            let top = y(max(b.open, b.close))
            let body = CGRect(x: xx - bodyWidth / 2, y: top, width: bodyWidth, height: max(1, y(min(b.open, b.close)) - top))
            if isUp {
                upWicks.move(to: CGPoint(x: xx, y: y(b.high))); upWicks.addLine(to: CGPoint(x: xx, y: y(b.low)))
                upBodies.addRect(body)
            } else {
                downWicks.move(to: CGPoint(x: xx, y: y(b.high))); downWicks.addLine(to: CGPoint(x: xx, y: y(b.low)))
                downBodies.addRect(body)
            }
        }
        plotCtx.stroke(upWicks, with: .color(up), lineWidth: 1)
        plotCtx.stroke(downWicks, with: .color(down), lineWidth: 1)
        plotCtx.fill(upBodies, with: .color(up))
        plotCtx.fill(downBodies, with: .color(down))

        // Position / order lines.
        for line in lines where line.price > lo && line.price < hi {
            drawLine(in: &ctx, y: y(line.price), plot: plot, color: line.color, dashed: true,
                     tag: line.label.isEmpty ? Fmt.price(line.price) : "\(line.label) \(Fmt.price(line.price))")
        }

        // Last price.
        if let last = lastPrice ?? bars.last?.close, last > lo, last < hi {
            let color = (bars.last.map { last >= $0.open } ?? true) ? up : down
            drawLine(in: &ctx, y: y(last), plot: plot, color: color, dashed: false, tag: Fmt.price(last))
        }

        // Crosshair + OHLCV readout.
        var readout = bars[min(end, max(start + 1, Int(anchor.rounded(.up)))) - 1]
        if let hover, plot.contains(hover) {
            let index = min(end - 1, max(start, Int((anchor - Double((anchorX - hover.x) / barWidth)).rounded(.down))))
            readout = bars[index]
            var cross = Path()
            cross.move(to: CGPoint(x: plot.minX, y: hover.y)); cross.addLine(to: CGPoint(x: plot.maxX, y: hover.y))
            cross.move(to: CGPoint(x: x(index), y: plot.minY)); cross.addLine(to: CGPoint(x: x(index), y: plot.maxY))
            ctx.stroke(cross, with: .color(.secondary.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            if priceRect.contains(hover) {
                drawTag(in: &ctx, text: Fmt.price(price(at: hover.y)), y: hover.y, plot: plot, color: .gray)
            }
        }
        let change = readout.open > 0 ? (readout.close - readout.open) / readout.open * 100 : 0
        let info = "O \(Fmt.price(readout.open))  H \(Fmt.price(readout.high))  L \(Fmt.price(readout.low))  C \(Fmt.price(readout.close))  \(Fmt.percent(change))  V \(Fmt.volume(readout.volume))"
        ctx.draw(Text(info).font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary),
                 at: CGPoint(x: plot.minX + 6, y: plot.minY + 2), anchor: .topLeading)
    }

    private func drawLine(in ctx: inout GraphicsContext, y: CGFloat, plot: CGRect, color: Color, dashed: Bool, tag: String) {
        var path = Path()
        path.move(to: CGPoint(x: plot.minX, y: y))
        path.addLine(to: CGPoint(x: plot.maxX, y: y))
        ctx.stroke(path, with: .color(color.opacity(0.8)), style: StrokeStyle(lineWidth: 1, dash: dashed ? [4, 3] : []))
        drawTag(in: &ctx, text: tag, y: y, plot: plot, color: color)
    }

    private func drawTag(in ctx: inout GraphicsContext, text: String, y: CGFloat, plot: CGRect, color: Color) {
        let resolved = ctx.resolve(Text(text).font(.system(size: 10, weight: .semibold).monospacedDigit()).foregroundStyle(.white))
        let textSize = resolved.measure(in: CGSize(width: 200, height: 20))
        let rect = CGRect(x: plot.maxX + 1, y: y - 8, width: max(axisWidth - 2, textSize.width + 8), height: 16)
        ctx.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(color))
        ctx.draw(resolved, at: CGPoint(x: rect.minX + 4, y: y), anchor: .leading)
    }

    private func timeLabel(_ date: Date) -> String {
        chart.timeframe.isIntraday
            ? Self.timeFormatter.string(from: date)
            : Self.dayFormatter.string(from: date)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM d"; return f
    }()

    static func niceTicks(lo: Double, hi: Double, count: Int) -> [Double] {
        let range = hi - lo
        guard range > 0, count > 0 else { return [] }
        let rough = range / Double(count)
        let magnitude = pow(10, floor(log10(rough)))
        let step = [1.0, 2.0, 2.5, 5.0, 10.0].map { $0 * magnitude }.first { $0 >= rough } ?? rough
        var ticks: [Double] = []
        var t = (lo / step).rounded(.up) * step
        while t <= hi {
            ticks.append(t)
            t += step
        }
        return ticks
    }
}

// MARK: - Trackpad / scroll-wheel input

/// SwiftUI on macOS has no scroll-wheel or precise trackpad scroll gesture, so this background
/// view watches the app's scroll and magnify events and forwards the ones over its own frame.
private struct ScrollCatcher: NSViewRepresentable {
    /// (dx, dy, location): dx in points (positive = content moves right), dy in points
    /// (positive = zoom in), location in view coordinates with a top-left origin.
    var onScroll: (CGFloat, CGFloat, CGPoint) -> Void
    var onMagnify: (CGFloat, CGPoint) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onScroll = onScroll
        view.onMagnify = onMagnify
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.onScroll = onScroll
        view.onMagnify = onMagnify
    }

    static func dismantleNSView(_ view: CatcherView, coordinator: ()) {
        view.removeMonitor()
    }

    final class CatcherView: NSView {
        var onScroll: ((CGFloat, CGFloat, CGPoint) -> Void)?
        var onMagnify: ((CGFloat, CGPoint) -> Void)?
        private var monitor: Any?
        private enum Axis { case horizontal, vertical }
        private var lockedAxis: Axis?

        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] event in
                guard let self, let location = self.location(of: event) else { return event }
                if event.type == .magnify {
                    self.onMagnify?(event.magnification, location)
                } else {
                    self.handleScroll(event, at: location)
                }
                return nil
            }
        }

        func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private func location(of event: NSEvent) -> CGPoint? {
            guard let window, event.window === window, !isHiddenOrHasHiddenAncestor else { return nil }
            let point = convert(event.locationInWindow, from: nil)
            return bounds.contains(point) ? point : nil
        }

        private func handleScroll(_ event: NSEvent, at location: CGPoint) {
            var dx = event.scrollingDeltaX
            var dy = event.scrollingDeltaY
            if !event.hasPreciseScrollingDeltas {
                // Mouse wheel: line-based deltas. Shift-wheel arrives as dx and pans.
                dx *= 12
                dy *= 12
            } else {
                // Trackpad: lock each gesture (and its momentum) to its dominant axis so a
                // slightly diagonal swipe doesn't pan and zoom at once.
                if event.phase == .began || event.phase == .mayBegin { lockedAxis = nil }
                if lockedAxis == nil, dx != 0 || dy != 0 {
                    lockedAxis = abs(dx) >= abs(dy) ? .horizontal : .vertical
                }
                switch lockedAxis {
                case .horizontal: dy = 0
                case .vertical: dx = 0
                case nil: break
                }
            }
            if event.isDirectionInvertedFromDevice { dy = -dy }
            onScroll?(dx, dy, location)
        }
    }
}
