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
//  Indicators: SMA 9 and SMA 21 on every chart, plus VWAP (from 04:00 ET) on intraday charts;
//  each can be turned off, and their thickness set, in Settings › Appearance.
//  Holding ⌃ over the price area with a position open shows, left of the price tag, the P/L if the
//  position closed at that price.
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
    /// Drawn above the last price line, and its price box moves into the chart, just left of the axis,
    /// where the last price box would cover it.
    var movesAsideForLastPrice = false
}

struct CandleChart: View {
    @Environment(Broker.self) private var broker
    let chart: ChartModel
    var lines: [PriceLine] = []
    /// ⌥-click in the price area: called with the price under the cursor.
    var onAltClick: ((Double) -> Void)?
    /// ⌃-click in the price area: called with the price under the cursor.
    var onControlClick: ((Double) -> Void)?
    /// Price tag color while ⌃ is held: what a ⌃-click there would place (nil: nothing).
    var controlClickColor: ((Double) -> Color?)?
    /// While ⌃ is held: the open position's P/L if it closed at that price (nil: no position).
    var controlHoverPnL: ((Double) -> Double?)?
    /// Double-click on an order line: called with its order id.
    var onCancelOrder: ((Int) -> Void)?
    /// Any left click on the chart, modified or not (it still pans, zooms or places orders as usual).
    var onClick: (() -> Void)?

    @AppStorage(CandleTheme.storageKey) private var candleTheme: CandleTheme = .teal

    /// Read here rather than passed in, so each tick redraws only the chart, not the pane around it.
    private var lastPrice: Double? { broker.quote(chart.symbol)?.last }
    @AppStorage(CandleTheme.customUpKey) private var customUp = CandleTheme.defaultUpHex
    @AppStorage(CandleTheme.customDownKey) private var customDown = CandleTheme.defaultDownHex
    @AppStorage(LineColors.altClickKey) private var altClickHex = ""
    @AppStorage(LineColors.hoverKey) private var hoverHex = ""
    @AppStorage(LineColors.lastPriceKey) private var lastPriceHex = ""
    @AppStorage(LineDashes.lastPriceKey) private var lastPriceDashed = LineDashes.defaultLastPrice
    @AppStorage(LineColors.showLastPriceLineKey) private var showLastPriceLine = true
    @AppStorage(LineDashes.hoverKey) private var hoverDashed = LineDashes.defaultHover
    @AppStorage(Indicators.vwapKey) private var showVWAP = true
    @AppStorage(Indicators.fastSMAKey) private var showFastSMA = true
    @AppStorage(Indicators.slowSMAKey) private var showSlowSMA = true
    @AppStorage(Indicators.lineWidthKey) private var indicatorWidth = Indicators.defaultLineWidth
    @AppStorage(PriceAxis.fontSizeKey) private var axisFontSize = PriceAxis.defaultFontSize
    @AppStorage(PriceAxis.labelSpacingKey) private var labelSpacing = PriceAxis.defaultLabelSpacing
    @AppStorage(PriceAxis.lastPriceOpacityKey) private var lastPriceOpacity = PriceAxis.defaultLastPriceOpacity
    @State private var hover: CGPoint?
    @State private var dragStart: (scroll: Double, shift: Double)?
    @State private var optionHeld = false
    @State private var controlHeld = false

    /// Widens with the axis text so larger prices still fit.
    private var axisWidth: CGFloat { max(58, (axisFontSize * 5.8).rounded()) }
    /// Height of the price boxes on the axis.
    private var tagHeight: CGFloat { axisFontSize + 6 }
    private let timeAxisHeight: CGFloat = 16
    private let rightPaddingBars = 3.0
    private let defaultVisibleBars = 120.0

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
                onPriceScale: { dy in scalePrices(by: exp(dy * 0.01)) },
                onMagnify: { magnification, location in
                    zoom(by: 1 / (1 + magnification), at: location.x, plotWidth: plotWidth)
                },
                onClick: { onClick?() },
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
        plotWidth / (chart.visibleBars + rightPadding(restOfDay))
    }

    /// The rest of today's extended session after the last intraday bar, as empty slots to its right.
    private struct RestOfDay {
        var from: Date                // where the first empty slot starts
        var barSeconds: Double
        var sessions: [(start: Date, end: Date, phase: MarketSession.Phase)]
        var slots: Int                // empty slots up to 20:00 ET
        var todayBars: Int            // bars since 04:00 ET

        /// Fractional bar index of a time in the empty slots.
        func index(_ time: Date, barCount: Int) -> Double {
            Double(barCount) + time.timeIntervalSince(from) / barSeconds
        }
    }

    private var restOfDay: RestOfDay? {
        let bars = chart.bars
        guard let seconds = chart.timeframe.barSeconds, let last = bars.last else { return nil }
        let from = last.time.addingTimeInterval(seconds)
        let sessions = MarketSession.restOfDay(from: from)
        guard let end = sessions.last?.end else { return nil }
        let todayBars = bars.reversed().prefix { $0.vwapDay == last.vwapDay }.count
        return RestOfDay(from: from, barSeconds: seconds, sessions: sessions,
                         slots: Int((end.timeIntervalSince(from) / seconds).rounded(.up)), todayBars: todayBars)
    }

    /// Empty slots right of the last bar: a few normally; zooming out past today's bars (and the default
    /// zoom) uses the room for the rest of the day, until all of it through after hours (20:00 ET) is on screen.
    private func rightPadding(_ rest: RestOfDay?) -> Double {
        guard let rest else { return rightPaddingBars }
        return min(max(rightPaddingBars, Double(rest.slots)),
                   max(rightPaddingBars, chart.visibleBars - max(Double(rest.todayBars), defaultVisibleBars)))
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
        let rest = restOfDay
        let oldWidth = barWidth(plotWidth: plotWidth), oldPadding = rightPadding(rest)
        // Zooms out as far as all the loaded bars (at least 600).
        chart.visibleBars = min(max(600, Double(chart.bars.count)), max(15, chart.visibleBars * factor))
        let newWidth = barWidth(plotWidth: plotWidth), newPadding = rightPadding(rest)
        let fromRight = Double(plotWidth - x)
        setScrollBack(chart.scrollBack + (newPadding - oldPadding) + fromRight / oldWidth - fromRight / newWidth)
    }

    /// Stretches (factor < 1) or squeezes (> 1) the price axis around the middle of the view.
    private func scalePrices(by factor: Double) {
        chart.priceScale = min(20, max(0.05, chart.priceScale * factor))
    }

    /// Latest bars at the right edge, default zoom, price range fitted to the bars again.
    private func resetView() {
        chart.scrollBack = 0
        chart.visibleBars = defaultVisibleBars
        chart.priceShift = 0
        chart.priceScale = 1
    }

    // MARK: Gestures

    /// The content follows the pointer both ways: sideways through time, up and down in price.
    private func panGesture(plotWidth: CGFloat, plotHeight: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                let start = dragStart ?? (chart.scrollBack, chart.priceShift)
                dragStart = start
                setScrollBack(start.scroll + Double(value.translation.width / barWidth(plotWidth: plotWidth)))
                // The shift is a fraction of the unscaled range; scaled, the content still follows the pointer.
                chart.priceShift = start.shift + Double(value.translation.height / max(1, plotHeight)) * chart.priceScale
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
        var rest: RestOfDay?

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
        let rest = restOfDay
        let padding = rightPadding(rest)
        let slots = chart.visibleBars + padding
        let barWidth = plot.width / slots
        let anchor = Double(bars.count) - chart.scrollBack
        let anchorX = plot.maxX - CGFloat(padding) * barWidth
        let end = min(bars.count, max(1, Int((anchor + padding).rounded(.up))))
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
        let mid = (lo + hi) / 2, half = (hi - lo) / 2 * chart.priceScale
        lo = mid - half; hi = mid + half
        return Viewport(plot: plot, priceRect: priceRect, volumeHeight: volumeHeight, barWidth: barWidth,
                        anchor: anchor, anchorX: anchorX, start: start, end: end, lo: lo, hi: hi, rest: rest)
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
            // The rest of today, still to come.
            if let rest = v.rest {
                func edge(_ t: Date) -> CGFloat {
                    anchorX - CGFloat(anchor - rest.index(t, barCount: bars.count)) * barWidth
                }
                for session in rest.sessions {
                    guard let tint = Self.sessionTint(session.phase) else { continue }
                    let left = edge(session.start)
                    plotCtx.fill(Path(CGRect(x: left, y: plot.minY, width: edge(session.end) - left, height: plot.height)),
                                 with: .color(tint))
                }
            }
        }

        // Horizontal grid + price labels.
        // Never finer than a cent (a hundredth of a cent under $1), the smallest step prices show.
        let ticks = Self.niceTicks(lo: lo, hi: hi, count: max(2, Int(priceRect.height / labelSpacing)),
                                   minStep: hi < 1 ? 0.0001 : 0.01)
        let decimals = ticks.count > 1 ? Self.decimals(forStep: ticks[1] - ticks[0], atLeast: hi < 1 ? 4 : 2) : 2
        for tick in ticks {
            let yy = y(tick)
            var path = Path()
            path.move(to: CGPoint(x: plot.minX, y: yy))
            path.addLine(to: CGPoint(x: plot.maxX, y: yy))
            ctx.stroke(path, with: .color(gridColor), lineWidth: 1)
            ctx.draw(Text(tick.formatted(.number.precision(.fractionLength(decimals))))
                        .font(.system(size: axisFontSize).monospacedDigit()).foregroundStyle(labelColor),
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
        if let rest = v.rest {
            for k in 0..<rest.slots where (bars.count + k) % labelEvery == 0 {
                let xx = x(bars.count + k)
                guard xx > plot.minX, xx < plot.maxX else { continue }
                var path = Path()
                path.move(to: CGPoint(x: xx, y: plot.minY))
                path.addLine(to: CGPoint(x: xx, y: plot.maxY))
                plotCtx.stroke(path, with: .color(gridColor), lineWidth: 1)
                let time = rest.from.addingTimeInterval(Double(k) * rest.barSeconds)
                plotCtx.draw(Text(timeLabel(time)).font(.system(size: 9).monospacedDigit()).foregroundStyle(labelColor),
                             at: CGPoint(x: xx, y: plot.maxY + timeAxisHeight / 2 + 1))
            }
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

        drawIndicators(in: &plotCtx, bars: bars, start: start, end: end, x: x, y: y)

        // Position / order lines; the ones that move aside for the last price (avg cost) go on top of it.
        let last = (lastPrice ?? bars.last?.close).flatMap { $0 > lo && $0 < hi ? $0 : nil }
        func draw(_ line: PriceLine) {
            let lineY = y(line.price)
            let covered = line.movesAsideForLastPrice && last.map { abs(y($0) - lineY) < tagHeight } == true
            drawLine(in: &ctx, y: lineY, plot: plot, color: line.color, dashed: line.dashed,
                     tag: line.label.isEmpty ? Fmt.price(line.price) : "\(line.label) \(Fmt.price(line.price))",
                     tagInside: covered)
        }
        let visibleLines = lines.filter { $0.price > lo && $0.price < hi }
        visibleLines.filter { !$0.movesAsideForLastPrice }.forEach(draw)

        // Last price: color, dashes and whether the line shows (the box always does) from Settings.
        if let last {
            drawLine(in: &ctx, y: y(last), plot: plot,
                     color: LineColors.resolve(lastPriceHex, default: LineColors.defaultLastPrice), dashed: lastPriceDashed,
                     tag: Fmt.price(last), tagOpacity: lastPriceOpacity, showsLine: showLastPriceLine)
        }
        visibleLines.filter(\.movesAsideForLastPrice).forEach(draw)

        // Crosshair (horizontal only).
        if let hover, plot.contains(hover) {
            var cross = Path()
            cross.move(to: CGPoint(x: plot.minX, y: hover.y)); cross.addLine(to: CGPoint(x: plot.maxX, y: hover.y))
            let hoverColor = LineColors.resolve(hoverHex, default: LineColors.defaultHover)
            ctx.stroke(cross, with: .color(hoverColor.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: hoverDashed ? [3, 3] : []))
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
                if controlHeld, let pnl = controlHoverPnL?(hoverPrice) {
                    drawPnLTag(in: &ctx, pnl: pnl, y: hover.y, plot: plot)
                }
            }
        }
    }

    // MARK: Indicators

    private static let vwapColor = Color.orange
    private static let fastSMAColor = Color(red: 0.3, green: 0.65, blue: 1)
    private static let slowSMAColor = Color(red: 0.75, green: 0.4, blue: 1)

    /// VWAP (intraday only, from 04:00 ET), SMA 9 and SMA 21 over the visible bars, each if turned on
    /// in Settings.
    private func drawIndicators(in ctx: inout GraphicsContext, bars: [Bar], start: Int, end: Int,
                                x: (Int) -> CGFloat, y: (Double) -> CGFloat) {
        func stroke(_ values: [Double?], color: Color, breakBefore: (Int) -> Bool = { _ in false }) {
            var path = Path()
            var drawing = false
            for (offset, value) in values.enumerated() {
                guard let value else { drawing = false; continue }
                if breakBefore(start + offset) { drawing = false }
                let point = CGPoint(x: x(start + offset), y: y(value))
                if drawing { path.addLine(to: point) } else { path.move(to: point); drawing = true }
            }
            ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: indicatorWidth, lineJoin: .round))
        }

        if showVWAP, chart.timeframe.isIntraday {
            stroke(Self.vwap(bars, start: start, end: end), color: Self.vwapColor) { i in
                i > 0 && bars[i].vwapDay != bars[i - 1].vwapDay
            }
        }
        if showSlowSMA { stroke(Self.sma(bars, period: 21, start: start, end: end), color: Self.slowSMAColor) }
        if showFastSMA { stroke(Self.sma(bars, period: 9, start: start, end: end), color: Self.fastSMAColor) }
    }

    /// Simple moving average of closes for bars start..<end; nil until `period` bars exist.
    static func sma(_ bars: [Bar], period: Int, start: Int, end: Int) -> [Double?] {
        var sum = 0.0
        let from = max(0, start - period + 1)
        var values: [Double?] = []
        values.reserveCapacity(end - start)
        for i in from..<end {
            sum += bars[i].close
            if i - from >= period { sum -= bars[i - period].close }
            if i >= start { values.append(i + 1 >= period ? sum / Double(period) : nil) }
        }
        return values
    }

    /// Volume-weighted average of typical price ((H+L+C)/3), restarting each VWAP day, for bars start..<end.
    static func vwap(_ bars: [Bar], start: Int, end: Int) -> [Double?] {
        guard start < end else { return [] }
        var from = start
        while from > 0, bars[from - 1].vwapDay == bars[start].vwapDay { from -= 1 }
        var pv = 0.0, volume = 0.0
        var values: [Double?] = []
        values.reserveCapacity(end - start)
        for i in from..<end {
            let b = bars[i]
            if i > from, b.vwapDay != bars[i - 1].vwapDay { pv = 0; volume = 0 }
            pv += (b.high + b.low + b.close) / 3 * b.volume
            volume += b.volume
            if i >= start { values.append(volume > 0 ? pv / volume : nil) }
        }
        return values
    }

    private func drawLine(in ctx: inout GraphicsContext, y: CGFloat, plot: CGRect, color: Color, dashed: Bool, tag: String,
                          tagOpacity: Double = 1, tagInside: Bool = false, showsLine: Bool = true) {
        if showsLine {
            var path = Path()
            path.move(to: CGPoint(x: plot.minX, y: y))
            path.addLine(to: CGPoint(x: plot.maxX, y: y))
            ctx.stroke(path, with: .color(color.opacity(0.8)), style: StrokeStyle(lineWidth: 1, dash: dashed ? [4, 3] : []))
        }
        drawTag(in: &ctx, text: tag, y: y, plot: plot, color: color, opacity: tagOpacity, inside: tagInside)
    }

    /// `opacity` fades only the box, not its white text; at the opacity slider's minimum there's no box.
    /// `inside` puts the box in the chart, just left of the price axis, instead of on it.
    private func drawTag(in ctx: inout GraphicsContext, text: String, y: CGFloat, plot: CGRect, color: Color,
                         opacity: Double = 1, inside: Bool = false) {
        let boxed = !PriceAxis.hidesLastPriceBox(opacity)
        let resolved = ctx.resolve(Text(text).font(.system(size: axisFontSize, weight: .semibold).monospacedDigit()).foregroundStyle(.white))
        let textSize = resolved.measure(in: CGSize(width: 300, height: 40))
        let rect = inside
            ? CGRect(x: plot.maxX - textSize.width - 10, y: y - tagHeight / 2, width: textSize.width + 8, height: tagHeight)
            : CGRect(x: plot.maxX + 1, y: y - tagHeight / 2, width: max(axisWidth - 2, textSize.width + 8), height: tagHeight)
        if boxed { ctx.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(color.opacity(opacity))) }
        ctx.draw(resolved, at: CGPoint(x: rect.minX + 4, y: y), anchor: .leading)
    }

    /// The P/L at the hovered price, in a green (gain) or red (loss) tag just left of the price axis.
    private func drawPnLTag(in ctx: inout GraphicsContext, pnl: Double, y: CGFloat, plot: CGRect) {
        let resolved = ctx.resolve(Text(Fmt.money(pnl, signed: true))
            .font(.system(size: axisFontSize, weight: .semibold).monospacedDigit()).foregroundStyle(.white))
        let width = resolved.measure(in: CGSize(width: 300, height: 40)).width + 8
        let rect = CGRect(x: plot.maxX - width - 2, y: y - tagHeight / 2, width: width, height: tagHeight)
        ctx.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(pnl >= 0 ? .green : .red))
        ctx.draw(resolved, at: CGPoint(x: rect.midX, y: y))
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

    static func niceTicks(lo: Double, hi: Double, count: Int, minStep: Double = 0) -> [Double] {
        let range = hi - lo
        guard range > 0, count > 0 else { return [] }
        let rough = max(range / Double(count), minStep)
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

    /// Decimals needed to show every tick `step` apart exactly (e.g. 3 for a 0.025 step), at least `atLeast`.
    static func decimals(forStep step: Double, atLeast: Int) -> Int {
        var d = atLeast
        while d < 6, abs(step * pow(10, Double(d)) - (step * pow(10, Double(d))).rounded()) > 1e-6 { d += 1 }
        return d
    }
}

// MARK: - Trackpad / scroll-wheel input

/// SwiftUI on macOS has no scroll-wheel or precise trackpad scroll gesture, so this background
/// view watches the app's scroll and magnify events and forwards the ones over its own frame.
/// ⌘ + vertical scroll scales the price axis instead of zooming in time.
/// It also reports every left click, takes ⌥-clicks (before SwiftUI's tap and drag gestures see them)
/// and ⌥ key changes.
private struct ScrollCatcher: NSViewRepresentable {
    /// (dx, dy, location): dx in points (positive = content moves right), dy in points
    /// (positive = zoom out), location in view coordinates with a top-left origin.
    var onScroll: (CGFloat, CGFloat, CGPoint) -> Void
    /// ⌘ + vertical scroll, in points (positive = squeeze the prices, like zooming out).
    var onPriceScale: (CGFloat) -> Void
    var onMagnify: (CGFloat, CGPoint) -> Void
    var onClick: () -> Void
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
        view.onPriceScale = onPriceScale
        view.onMagnify = onMagnify
        view.onClick = onClick
        view.onModifiedClick = onModifiedClick
        view.onModifierKeys = onModifierKeys
        view.onRightClick = onRightClick
    }

    static func dismantleNSView(_ view: CatcherView, coordinator: ()) {
        view.removeMonitor()
    }

    final class CatcherView: NSView {
        var onScroll: ((CGFloat, CGFloat, CGPoint) -> Void)?
        var onPriceScale: ((CGFloat) -> Void)?
        var onMagnify: ((CGFloat, CGPoint) -> Void)?
        var onClick: (() -> Void)?
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
                    self.onClick?()
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
            if event.modifierFlags.contains(.command) {
                if dy != 0 { onPriceScale?(dy) }
                return
            }
            onScroll?(dx, dy, location)
        }
    }
}
