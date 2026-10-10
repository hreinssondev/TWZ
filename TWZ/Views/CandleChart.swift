//
//  CandleChart.swift
//  TWZ
//
//  Lightweight candlestick + volume chart drawn with a single SwiftUI Canvas.
//  Trackpad: two-finger swipe left/right to pan (with momentum), up/down or pinch to zoom
//  around the cursor; a diagonal swipe does both. Mouse: wheel zooms, shift-wheel pans.
//  Drag pans freely, in time and price. Right-click resets the view, as does double-clicking
//  anywhere but an order line; double-clicking an order line cancels that order.
//  Intraday charts shade the sessions outside regular hours: pre-market and after hours in grey,
//  overnight in indigo.
//

import SwiftUI
import AppKit

struct PriceLine {
    var price: Double
    var color: Color
    var label: String
    var dashed = true
    /// The order the line belongs to; double-clicking the line cancels it.
    var orderId: Int?
}

struct CandleChart: View {
    let chart: ChartModel
    var lastPrice: Double?
    var lines: [PriceLine] = []
    /// ⌥-click in the price area: called with the price under the cursor.
    var onAltClick: ((Double) -> Void)?
    /// ⌃-click in the price area: called with the price under the cursor.
    var onControlClick: ((Double) -> Void)?
    /// Price tag color while ⌃ is held: what a ⌃-click there would place (nil: nothing).
    var controlClickColor: ((Double) -> Color?)?
    /// Double-click on an order line: called with its order id.
    var onCancelOrder: ((Int) -> Void)?

    @AppStorage(CandleTheme.storageKey) private var candleTheme: CandleTheme = .teal
    @AppStorage(CandleTheme.customUpKey) private var customUp = CandleTheme.defaultUpHex
    @AppStorage(CandleTheme.customDownKey) private var customDown = CandleTheme.defaultDownHex
    @AppStorage(LineColors.altClickKey) private var altClickHex = ""
    @AppStorage(LineColors.hoverKey) private var hoverHex = ""
    @AppStorage(LineColors.lastPriceKey) private var lastPriceHex = ""
    @State private var hover: CGPoint?
    @State private var dragStart: (scroll: Double, shift: Double)?
    @State private var optionHeld = false
    @State private var controlHeld = false

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
                if case .active(let p) = phase {
                    hover = p
                    optionHeld = NSEvent.modifierFlags.contains(.option)
                    controlHeld = NSEvent.modifierFlags.contains(.control)
                } else {
                    hover = nil
                }
            }
            .gesture(panGesture(plotWidth: plotWidth, plotHeight: plotRect(size: geo.size).height))
            .onTapGesture(count: 2) { location in
                if let id = orderLine(near: location, size: geo.size) {
                    onCancelOrder?(id)
                } else {
                    resetView()
                }
            }
            .background(ScrollCatcher(
                onScroll: { dx, dy, location in
                    if dx != 0 { pan(byPoints: dx, plotWidth: plotWidth) }
                    if dy != 0 { zoom(by: exp(dy * 0.01), at: location.x, plotWidth: plotWidth) }
                },
                onMagnify: { magnification, location in
                    zoom(by: 1 / (1 + magnification), at: location.x, plotWidth: plotWidth)
                },
                onModifiedClick: { location, flags in
                    guard let handler = flags == .control ? onControlClick : onAltClick,
                          let price = price(at: location, size: geo.size) else { return false }
                    handler(price)
                    return true
                },
                onModifierKeys: { flags in
                    optionHeld = flags.contains(.option)
                    controlHeld = flags.contains(.control)
                },
                onRightClick: resetView
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
        // Zooms out as far as all the loaded bars (at least 600).
        chart.visibleBars = min(max(600, Double(chart.bars.count)), max(15, chart.visibleBars * factor))
        let newWidth = barWidth(plotWidth: plotWidth)
        let fromRight = Double(plotWidth - x)
        setScrollBack(chart.scrollBack + fromRight / oldWidth - fromRight / newWidth)
    }

    /// Latest bars at the right edge, default zoom, price range fitted to the bars again.
    private func resetView() {
        chart.scrollBack = 0
        chart.visibleBars = 120
        chart.priceShift = 0
    }

    // MARK: Gestures

    /// The content follows the pointer both ways: sideways through time, up and down in price.
    private func panGesture(plotWidth: CGFloat, plotHeight: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                let start = dragStart ?? (chart.scrollBack, chart.priceShift)
                dragStart = start
                setScrollBack(start.scroll + Double(value.translation.width / barWidth(plotWidth: plotWidth)))
                chart.priceShift = start.shift + Double(value.translation.height / max(1, plotHeight))
            }
            .onEnded { _ in dragStart = nil }
    }

    // MARK: Drawing

    /// Where bars and prices sit on screen; shared by drawing and alt-click pricing.
    private struct Viewport {
        var plot: CGRect
        var priceRect: CGRect
        var volumeHeight: CGFloat
        var barWidth: CGFloat
        var anchor: Double        // index just past the bar at the anchor slot
        var anchorX: CGFloat
        var start: Int
        var end: Int
        var lo: Double
        var hi: Double

        func y(_ price: Double) -> CGFloat {
            priceRect.maxY - CGFloat((price - lo) / (hi - lo)) * priceRect.height
        }

        func price(at yPos: CGFloat) -> Double {
            lo + Double((priceRect.maxY - yPos) / priceRect.height) * (hi - lo)
        }
    }

    private func plotRect(size: CGSize) -> CGRect {
        CGRect(x: 0, y: 4, width: size.width - axisWidth, height: size.height - timeAxisHeight - 4)
    }

    /// nil while the chart is too small to draw or has no bars.
    private func viewport(size: CGSize) -> Viewport? {
        let bars = chart.bars
        let plot = plotRect(size: size)
        guard plot.width > 20, plot.height > 20, !bars.isEmpty else { return nil }

        // Visible window, anchored to the right edge. scrollBack is fractional so panning is smooth.
        let slots = chart.visibleBars + rightPaddingBars
        let barWidth = plot.width / slots
        let anchor = Double(bars.count) - chart.scrollBack
        let anchorX = plot.maxX - CGFloat(rightPaddingBars) * barWidth
        let end = min(bars.count, max(1, Int((anchor + rightPaddingBars).rounded(.up))))
        let start = min(end - 1, max(0, Int((anchor - chart.visibleBars).rounded(.down))))
        let visible = bars[start..<end]

        // Candles use the full height; volume fills the bottom 18% behind them and doesn't squeeze them.
        let volumeHeight = plot.height * 0.18
        let priceRect = plot

        var lo = visible.map(\.low).min() ?? 0
        var hi = visible.map(\.high).max() ?? 1
        if chart.scrollBack < 1, let lastPrice { lo = min(lo, lastPrice); hi = max(hi, lastPrice) }
        if hi - lo < 1e-9 { hi += 0.01; lo -= 0.01 }
        let pad = (hi - lo) * 0.06
        lo -= pad; hi += pad
        let shift = (hi - lo) * chart.priceShift
        lo += shift; hi += shift
        return Viewport(plot: plot, priceRect: priceRect, volumeHeight: volumeHeight, barWidth: barWidth,
                        anchor: anchor, anchorX: anchorX, start: start, end: end, lo: lo, hi: hi)
    }

    /// The order line closest to `point` vertically, if one is within a few points of it.
    private func orderLine(near point: CGPoint, size: CGSize) -> Int? {
        guard onCancelOrder != nil, let v = viewport(size: size),
              point.y >= v.plot.minY, point.y <= v.plot.maxY else { return nil }
        return lines
            .compactMap { line in
                line.orderId.flatMap { id in
                    line.price > v.lo && line.price < v.hi ? (id, abs(v.y(line.price) - point.y)) : nil
                }
            }
            .filter { $0.1 <= 8 }
            .min { $0.1 < $1.1 }?.0
    }

    /// The price under a point in the price area, or nil outside it.
    private func price(at point: CGPoint, size: CGSize) -> Double? {
        guard let v = viewport(size: size), v.priceRect.contains(point) else { return nil }
        return v.price(at: point.y)
    }

    private func draw(in ctx: inout GraphicsContext, size: CGSize) {
        let bars = chart.bars
        guard let v = viewport(size: size) else {
            let plot = plotRect(size: size)
            guard plot.width > 20, plot.height > 20 else { return }
            let msg = chart.isLoading ? "Loading…" : (chart.error ?? (chart.symbol.isEmpty ? "Enter a symbol" : "No data"))
            ctx.draw(Text(msg).font(.system(size: 11)).foregroundStyle(.secondary),
                     at: CGPoint(x: size.width / 2, y: size.height / 2))
            return
        }
        let plot = v.plot, priceRect = v.priceRect, volumeHeight = v.volumeHeight
        let barWidth = v.barWidth, anchor = v.anchor, anchorX = v.anchorX
        let start = v.start, end = v.end, lo = v.lo, hi = v.hi
        let visible = bars[start..<end]
        func x(_ index: Int) -> CGFloat {
            anchorX - CGFloat(anchor - Double(index) - 0.5) * barWidth
        }
        func y(_ price: Double) -> CGFloat { v.y(price) }
        // Bars partially scrolled past the edges are clipped; axis tags draw on the unclipped context.
        var plotCtx = ctx
        plotCtx.clip(to: Path(CGRect(x: 0, y: 0, width: plot.maxX, height: size.height)))

        let gridColor = Color.primary.opacity(0.07)
        let labelColor = Color.secondary
        let (up, down) = candleTheme.colors(customUp: customUp, customDown: customDown)

        // Session shading, one band per run of bars from the same session.
        if chart.timeframe.isIntraday {
            var i = start
            while i < end {
                let phase = bars[i].phase
                var j = i
                while j + 1 < end, bars[j + 1].phase == phase { j += 1 }
                if let tint = Self.sessionTint(phase) {
                    let band = CGRect(x: x(i) - barWidth / 2, y: plot.minY,
                                      width: CGFloat(j - i + 1) * barWidth, height: plot.height)
                    plotCtx.fill(Path(band), with: .color(tint))
                }
                i = j + 1
            }
        }

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
            drawLine(in: &ctx, y: y(line.price), plot: plot, color: line.color, dashed: line.dashed,
                     tag: line.label.isEmpty ? Fmt.price(line.price) : "\(line.label) \(Fmt.price(line.price))")
        }

        // Last price: dotted, color from Settings.
        if let last = lastPrice ?? bars.last?.close, last > lo, last < hi {
            drawLine(in: &ctx, y: y(last), plot: plot,
                     color: LineColors.resolve(lastPriceHex, default: LineColors.defaultLastPrice), dashed: true,
                     tag: Fmt.price(last))
        }

        // Crosshair (horizontal only).
        if let hover, plot.contains(hover) {
            var cross = Path()
            cross.move(to: CGPoint(x: plot.minX, y: hover.y)); cross.addLine(to: CGPoint(x: plot.maxX, y: hover.y))
            let hoverColor = LineColors.resolve(hoverHex, default: LineColors.defaultHover)
            ctx.stroke(cross, with: .color(hoverColor.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            if priceRect.contains(hover) {
                let hoverPrice = v.price(at: hover.y)
                // Holding ⌥ turns the price tag the ⌥-click order color: an alt-click buys there.
                // Holding ⌃ turns it red or green: a ⌃-click places a stop loss or take profit there.
                var tagColor = hoverColor
                if controlHeld, let color = controlClickColor?(hoverPrice) {
                    tagColor = color
                } else if optionHeld, onAltClick != nil {
                    tagColor = LineColors.resolve(altClickHex, default: LineColors.defaultAltClick)
                }
                drawTag(in: &ctx, text: Fmt.price(hoverPrice), y: hover.y, plot: plot, color: tagColor)
            }
        }
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

    private static func sessionTint(_ phase: MarketSession.Phase) -> Color? {
        switch phase {
        case .regular: nil
        case .preMarket, .afterHours: Color.primary.opacity(0.045)
        case .overnight, .closed: Color.indigo.opacity(0.08)
        }
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
/// It also takes ⌥-clicks (before SwiftUI's tap and drag gestures see them) and ⌥ key changes.
private struct ScrollCatcher: NSViewRepresentable {
    /// (dx, dy, location): dx in points (positive = content moves right), dy in points
    /// (positive = zoom out), location in view coordinates with a top-left origin.
    var onScroll: (CGFloat, CGFloat, CGPoint) -> Void
    var onMagnify: (CGFloat, CGPoint) -> Void
    /// ⌥- or ⌃-click location and which of the two; return true to consume the click.
    var onModifiedClick: ((CGPoint, NSEvent.ModifierFlags) -> Bool)?
    var onModifierKeys: (NSEvent.ModifierFlags) -> Void
    var onRightClick: () -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.onScroll = onScroll
        view.onMagnify = onMagnify
        view.onModifiedClick = onModifiedClick
        view.onModifierKeys = onModifierKeys
        view.onRightClick = onRightClick
    }

    static func dismantleNSView(_ view: CatcherView, coordinator: ()) {
        view.removeMonitor()
    }

    final class CatcherView: NSView {
        var onScroll: ((CGFloat, CGFloat, CGPoint) -> Void)?
        var onMagnify: ((CGFloat, CGPoint) -> Void)?
        var onModifiedClick: ((CGPoint, NSEvent.ModifierFlags) -> Bool)?
        var onModifierKeys: ((NSEvent.ModifierFlags) -> Void)?
        var onRightClick: (() -> Void)?
        private var monitor: Any?

        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(
                matching: [.scrollWheel, .magnify, .leftMouseDown, .rightMouseDown, .flagsChanged]
            ) { [weak self] event in
                guard let self else { return event }
                if event.type == .flagsChanged {
                    self.onModifierKeys?(event.modifierFlags)
                    return event
                }
                guard let location = self.location(of: event) else { return event }
                switch event.type {
                case .magnify:
                    self.onMagnify?(event.magnification, location)
                case .rightMouseDown:
                    self.onRightClick?()
                case .leftMouseDown:
                    let flags = event.modifierFlags.intersection([.option, .command, .control, .shift])
                    guard flags == .option || flags == .control, let onModifiedClick = self.onModifiedClick,
                          onModifiedClick(location, flags) else { return event }
                default:
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
                // Trackpad: a nearly straight swipe only pans or only zooms, but a clearly
                // diagonal one does both, so you can zoom while panning without lifting.
                if abs(dy) < abs(dx) * 0.35 { dy = 0 } else if abs(dx) < abs(dy) * 0.35 { dx = 0 }
            }
            if event.isDirectionInvertedFromDevice { dy = -dy }
            onScroll?(dx, dy, location)
        }
    }
}
