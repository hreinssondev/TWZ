//
//  ChartRenderer.swift
//  TWZ
//
//  How the charts are drawn, the way trading platforms draw theirs: nothing on screen waits for the main thread to
//  draw it. Once per screen refresh, each chart whose drawing changed is copied on the main thread into a
//  `ChartFrame` (its bars, zoom and place, prices, lines, hover, settings: plain values, quick to copy), and then all
//  of them are drawn at once, on every core, each into a buffer of its own (an IOSurface, which the window server
//  shows as it is, without copying it). Once they're all done they're shown together (see `ChartRenderLoop`). The main
//  thread only takes input and copies; a full grid of charts draws in about the time one did.
//

import AppKit
import CoreVideo
import IOSurface
import QuartzCore
import SwiftUI

/// Everything a chart's frame is drawn from, copied on the main thread (see `CandleChart.frame(size:)`), so it can be
/// drawn on any thread.
nonisolated struct ChartFrame {
    /// The chart's model, as it was.
    struct Chart {
        var bars: [Bar]
        var symbol: String
        var timeframe: Timeframe
        var visibleBars: Double
        var scrollBack: Double
        var priceShift: Double
        var priceScale: Double
        var isLoading: Bool
        var error: String?
    }

    var chart: Chart
    var restOfDay: CandleChart.RestOfDay?
    /// Empty slots right of the last bar (see `ChartModel.rightPadding`).
    var rightPadding: Double
    var lastPrice: Double?
    var settings: ChartSettings.Values
    var sideColors: SideColors
    var lines: [PriceLine]
    var pointers: [PricePointer]
    /// The fills drawn as arrows: the day's in the symbol with Trades on, else a round trip's shown from its tab.
    var fills: [Fill]
    var usdNok: Double?
    var hover: CGPoint?
    var optionHeld = false
    var controlHeld = false
    var commandHeld = false
    /// The price tag's (and with `tintsHoverLine` the hover line's) color while ⌥ / ⌘⇧ is held; nil without a handler.
    var altClickTint: Color?
    var commandClickTint: Color?
    var tintsHoverLine = false
    /// With ⌃ held: what a ⌃-click at the hovered price would place (see `CandleChart.controlClickColor`).
    var hoverControlColor: Color?
    /// The P/L at the hovered price (see `CandleChart.hoverPnL`).
    var hoverPnL: Double?
    /// Pixels per point of what it's drawn into (Snap puts candles on whole pixels, see `ChartSharpness`).
    var pixelScale: CGFloat = 1

    var candleTheme: CandleTheme { settings.candleTheme }
    var customUp: String { settings.customUp }
    var customDown: String { settings.customDown }
    var hoverHex: String { settings.hoverHex }
    var lastPriceHex: String { settings.lastPriceHex }
    var lastPriceDashed: Bool { settings.lastPriceDashed }
    var showLastPriceLine: Bool { settings.showLastPriceLine }
    var showGrid: Bool { settings.showGrid }
    var volumeOpacity: Double { settings.volumeOpacity }
    var hoverDashed: Bool { settings.hoverDashed }
    var lastPriceDots: Bool { settings.lastPriceDots }
    var hoverDots: Bool { settings.hoverDots }
    var showVWAP: Bool { settings.showVWAP }
    var showFastSMA: Bool { settings.showFastSMA }
    var showSlowSMA: Bool { settings.showSlowSMA }
    var indicatorWidth: Double { settings.indicatorWidth }
    var axisFontSize: Double { settings.axisFontSize }
    var labelSpacing: Double { settings.labelSpacing }
    var lastPriceOpacity: Double { settings.lastPriceOpacity }

    /// Widens with the axis text so larger prices still fit.
    var axisWidth: CGFloat { Self.axisWidth(fontSize: axisFontSize) }
    static func axisWidth(fontSize: Double) -> CGFloat { max(58, (fontSize * 5.8).rounded()) }
    /// Height of the price boxes on the axis.
    var tagHeight: CGFloat { axisFontSize + 6 }
    static let timeAxisHeight: CGFloat = 16
    var timeAxisHeight: CGFloat { Self.timeAxisHeight }
}

extension ChartFrame {

    /// Where bars and prices sit on screen; shared by drawing and alt-click pricing.
    struct Viewport {
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
        var rest: CandleChart.RestOfDay?

        func y(_ price: Double) -> CGFloat {
            priceRect.maxY - CGFloat((price - lo) / (hi - lo)) * priceRect.height
        }

        func price(at yPos: CGFloat) -> Double {
            lo + Double((priceRect.maxY - yPos) / priceRect.height) * (hi - lo)
        }
    }

    func plotRect(size: CGSize) -> CGRect {
        CGRect(x: 0, y: 4, width: size.width - axisWidth, height: size.height - timeAxisHeight - 4)
    }

    /// nil while the chart is too small to draw or has no bars.
    func viewport(size: CGSize) -> Viewport? {
        let bars = chart.bars
        let plot = plotRect(size: size)
        guard plot.width > 20, plot.height > 20, !bars.isEmpty else { return nil }

        // Visible window, anchored to the right edge. scrollBack is fractional so panning is smooth.
        let rest = restOfDay
        let padding = rightPadding
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

    /// `lines`, those following the last price moved to it.
    var placedLines: [PriceLine] {
        guard lines.contains(where: \.followsLastPrice), let last = lastPrice ?? chart.bars.last?.close else { return lines }
        return lines.map { line in
            var line = line
            if line.followsLastPrice { line.price = last }
            return line
        }
    }

    func draw(in ctx: inout ChartPainter, size: CGSize) {
        let bars = chart.bars
        // A chart theme: its own background behind everything, axes included.
        let scene = candleTheme.scene
        if let scene {
            ctx.fill(Path(CGRect(origin: .zero, size: size)),
                     with: .linearGradient(scene.background, startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
        }
        guard let v = viewport(size: size) else {
            let plot = plotRect(size: size)
            guard plot.width > 20, plot.height > 20 else { return }
            let msg = chart.isLoading ? "Loading…" : (chart.error ?? (chart.symbol.isEmpty ? "Enter a symbol" : "No data"))
            AxisLabels.draw([.init(text: msg, point: CGPoint(x: size.width / 2, y: size.height / 2), anchor: .center)],
                            size: 11, color: scene.map { NSColor($0.label) } ?? AxisLabels.secondary, in: ctx)
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

        // Grid lines switched off in Settings: drawn clear, the labels stay.
        let gridColor = scene.map { $0.grid.opacity(showGrid ? 0.14 : 0) } ?? Color.primary.opacity(showGrid ? 0.07 : 0)
        // The axis labels' color, for Core Text (see `AxisLabels`).
        let labelNSColor = scene.map { NSColor($0.label) } ?? AxisLabels.secondary
        let (up, down) = candleTheme.colors(customUp: customUp, customDown: customDown)

        // Session shading, one band per run of bars from the same session.
        let forex = ForexPair(chart.symbol)
        if chart.timeframe.isIntraday, forex == nil {
            var i = start
            while i < end {
                let phase = bars[i].phase
                var j = i
                while j + 1 < end, bars[j + 1].phase == phase { j += 1 }
                if let tint = Self.sessionTint(phase, scene: scene) {
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
                    guard let tint = Self.sessionTint(session.phase, scene: scene) else { continue }
                    let left = edge(session.start)
                    plotCtx.fill(Path(CGRect(x: left, y: plot.minY, width: edge(session.end) - left, height: plot.height)),
                                 with: .color(tint))
                }
            }
        }

        // Forex: a thin line where each trading day starts (17:00 New York, the FX rollover).
        if chart.timeframe.isIntraday, forex != nil {
            var separators = Path()
            for i in max(start, 1)..<end where Self.forexDay(bars[i].time) != Self.forexDay(bars[i - 1].time) {
                let xx = x(i) - barWidth / 2
                separators.move(to: CGPoint(x: xx, y: plot.minY))
                separators.addLine(to: CGPoint(x: xx, y: plot.maxY))
            }
            plotCtx.stroke(separators, with: .color(scene?.label.opacity(0.3) ?? Color.primary.opacity(0.25)), lineWidth: 0.5)
        }

        // Horizontal grid + price labels.
        // Never finer than a cent (a hundredth of a cent under $1), the smallest step prices show; for a
        // forex pair, a tenth of a pip.
        let minStep = forex.map { $0.pip / 10 } ?? (hi < 1 ? 0.0001 : 0.01)
        let minDecimals = forex.map { $0.decimals - 1 } ?? (hi < 1 ? 4 : 2)
        let ticks = Self.niceTicks(lo: lo, hi: hi, count: max(2, Int(priceRect.height / labelSpacing)), minStep: minStep)
        let decimals = ticks.count > 1 ? Self.decimals(forStep: ticks[1] - ticks[0], atLeast: minDecimals) : minDecimals
        var priceLabels: [AxisLabels.Item] = []
        for tick in ticks {
            let yy = y(tick)
            var path = Path()
            path.move(to: CGPoint(x: plot.minX, y: yy))
            path.addLine(to: CGPoint(x: plot.maxX, y: yy))
            ctx.stroke(path, with: .color(gridColor), lineWidth: 1)
            priceLabels.append(.init(text: tick.formatted(.number.precision(.fractionLength(decimals))),
                                     point: CGPoint(x: plot.maxX + 6, y: yy), anchor: .leading))
        }
        AxisLabels.draw(priceLabels, size: axisFontSize, color: labelNSColor, in: ctx)

        // Vertical grid + time labels, roughly every 90px.
        let labelEvery = max(1, Int((90 / barWidth).rounded(.up)))
        let timeLabelSpan = Double(labelEvery) * (chart.timeframe.barSeconds ?? 86_400)
        var timeLabels: [AxisLabels.Item] = []
        for i in start..<end where i % labelEvery == 0 {
            let xx = x(i)
            var path = Path()
            path.move(to: CGPoint(x: xx, y: plot.minY))
            path.addLine(to: CGPoint(x: xx, y: plot.maxY))
            plotCtx.stroke(path, with: .color(gridColor), lineWidth: 1)
            let previous = i >= labelEvery ? bars[i - labelEvery].time : nil
            timeLabels.append(.init(text: timeLabel(bars[i].time, previous: previous, spacing: timeLabelSpan),
                                    point: CGPoint(x: xx, y: plot.maxY + timeAxisHeight / 2 + 1), anchor: .center))
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
                timeLabels.append(.init(text: timeLabel(time, previous: time.addingTimeInterval(-timeLabelSpan), spacing: timeLabelSpan),
                                        point: CGPoint(x: xx, y: plot.maxY + timeAxisHeight / 2 + 1), anchor: .center))
            }
        }
        AxisLabels.draw(timeLabels, size: 9, color: labelNSColor, in: plotCtx)

        // Volume, at Settings' opacity.
        let maxVolume = visible.map(\.volume).max() ?? 0
        if maxVolume > 0, volumeOpacity > 0 {
            var upVol = Path(), downVol = Path()
            let snap = PixelSnap(scale: pixelScale, bodyWidth: max(1, barWidth * 0.7))
            for i in start..<end {
                let b = bars[i]
                let h = CGFloat(b.volume / maxVolume) * volumeHeight
                let rect = settings.pixelSnap
                    ? snap.column(centeredAt: x(i), top: plot.maxY - h, bottom: plot.maxY, minHeight: 0)
                    : CGRect(x: x(i) - barWidth * 0.35, y: plot.maxY - h, width: max(1, barWidth * 0.7), height: h)
                if b.close >= b.open { upVol.addRect(rect) } else { downVol.addRect(rect) }
            }
            plotCtx.fill(upVol, with: .color(up.opacity(volumeOpacity)))
            plotCtx.fill(downVol, with: .color(down.opacity(volumeOpacity)))
        }

        // Candles: batch into two paths per color for speed.
        var upWicks = Path(), downWicks = Path(), upBodies = Path(), downBodies = Path()
        let bodyWidth = max(1, barWidth * 0.7)
        if settings.pixelSnap {
            // Snap: bodies and wicks filled on whole pixels, every body as wide as the next, its wick in the middle.
            let snap = PixelSnap(scale: pixelScale, bodyWidth: bodyWidth)
            for i in start..<end {
                let b = bars[i]
                let xx = x(i)
                let body = snap.column(centeredAt: xx, top: y(max(b.open, b.close)), bottom: y(min(b.open, b.close)), minHeight: 1)
                let wick = snap.wick(centeredAt: xx, top: y(b.high), bottom: y(b.low))
                if b.close >= b.open { upWicks.addRect(wick); upBodies.addRect(body) } else { downWicks.addRect(wick); downBodies.addRect(body) }
            }
            plotCtx.fill(upWicks, with: .color(up))
            plotCtx.fill(downWicks, with: .color(down))
        } else {
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
        }
        plotCtx.fill(upBodies, with: .color(up))
        plotCtx.fill(downBodies, with: .color(down))

        drawIndicators(in: &plotCtx, bars: bars, start: start, end: end, x: x, y: y)
        if !fills.isEmpty {
            drawTrades(in: &plotCtx, bars: bars, start: start, end: end, bodyWidth: bodyWidth, x: x, y: y)
        }
        if !pointers.isEmpty {
            drawPointers(in: &plotCtx, bars: bars, start: start, end: end, bodyWidth: bodyWidth, x: x, y: y)
        }

        // Position / order lines; orders and the ones that move aside for the last price (avg cost) go
        // on top of it.
        let last = (lastPrice ?? bars.last?.close).flatMap { $0 > lo && $0 < hi ? $0 : nil }
        func isOrder(_ line: PriceLine) -> Bool {
            !line.drawnAcross && (line.drawnLikeOrder || (line.orderId != nil && !line.movesAsideForLastPrice))
        }
        // Order lines run from the latest candle to the axis, not across the whole chart.
        let orderLineStart = min(max(x(bars.count - 1), plot.minX), plot.maxX)
        // Trend lines on intraday charts: from where today starts (the previous day's end) to the axis.
        lazy var dayStart: CGFloat? = {
            guard chart.timeframe.isIntraday, let lastBar = bars.last else { return nil }
            var i = bars.count - 1
            if forex != nil {
                let day = Self.forexDay(lastBar.time)
                while i > 0, Self.forexDay(bars[i - 1].time) == day { i -= 1 }
            } else {
                while i > 0, bars[i - 1].vwapDay == lastBar.vwapDay { i -= 1 }
            }
            return min(max(x(i) - barWidth / 2, plot.minX), plot.maxX)
        }()
        func draw(_ line: PriceLine) {
            let lineY = y(line.price)
            let covered = line.movesAsideForLastPrice && last.map { abs(y($0) - lineY) < tagHeight } == true
            drawLine(in: &ctx, y: lineY, plot: plot, color: line.color, dashed: line.dashed, dotted: line.dotted,
                     tag: line.label.isEmpty ? Fmt.price(line.price, for: chart.symbol) : "\(line.label) \(Fmt.price(line.price, for: chart.symbol))",
                     tagInside: covered || isOrder(line), chartTag: line.chartText, showsTag: line.showsTag,
                     lineStart: isOrder(line) ? orderLineStart : line.fromDayStart ? dayStart : nil,
                     progress: line.fillProgress, lineWidth: line.lineWidth)
        }
        let visibleLines = placedLines.filter { $0.price > lo && $0.price < hi }
        visibleLines.filter { !$0.movesAsideForLastPrice && !isOrder($0) }.forEach(draw)

        // Last price: color, dashes and whether the line shows (the box always does) from Settings.
        if let last {
            drawLine(in: &ctx, y: y(last), plot: plot,
                     color: LineColors.resolve(lastPriceHex, default: LineColors.defaultLastPrice), dashed: lastPriceDashed,
                     dotted: lastPriceDashed && lastPriceDots,
                     tag: Fmt.price(last, for: chart.symbol), tagOpacity: lastPriceOpacity, showsLine: showLastPriceLine)
        }
        visibleLines.filter { $0.movesAsideForLastPrice || isOrder($0) }.forEach(draw)

        // Crosshair: the price line across, and a line down through the hovered bar with its time in a box
        // on the time axis.
        if let hover, plot.contains(hover) {
            var cross = Path()
            cross.move(to: CGPoint(x: plot.minX, y: hover.y)); cross.addLine(to: CGPoint(x: plot.maxX, y: hover.y))
            let hoverIndex = Int((anchor - 0.5 - Double((anchorX - hover.x) / barWidth)).rounded())
            let hoverTime = time(atIndex: hoverIndex, bars: bars, rest: v.rest)
            let hoverX = x(hoverIndex)
            if hoverTime != nil, hoverX >= plot.minX, hoverX <= plot.maxX {
                cross.move(to: CGPoint(x: hoverX, y: plot.minY)); cross.addLine(to: CGPoint(x: hoverX, y: plot.maxY))
            }
            let hoverColor = LineColors.resolve(hoverHex, default: LineColors.defaultHover)
            // Holding ⌥ / ⌘⇧ tints the price tag (and with `tintsHoverLine` the line): a click places there.
            let modifierTint: Color? = (optionHeld ? altClickTint : nil) ?? (commandHeld ? commandClickTint : nil)
            let lineTint = tintsHoverLine ? modifierTint : nil
            ctx.stroke(cross, with: .color(lineTint ?? hoverColor.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: hoverDashed ? (hoverDots ? [1, 2] : [3, 3]) : []))
            if priceRect.contains(hover) {
                let hoverPrice = v.price(at: hover.y)
                // Holding ⌃ turns it red or green: a ⌃-click places a stop loss or take profit there.
                var tagColor = hoverColor
                if controlHeld, let color = hoverControlColor {
                    tagColor = color
                } else if let modifierTint {
                    tagColor = modifierTint
                }
                drawTag(in: &ctx, text: Fmt.price(hoverPrice, for: chart.symbol), y: hover.y, plot: plot, color: tagColor)
                if let pnl = hoverPnL {
                    drawPnLTag(in: &ctx, pnl: pnl, y: hover.y, plot: plot)
                }
            }
            if let hoverTime, hoverX >= plot.minX, hoverX <= plot.maxX {
                drawTimeTag(in: &ctx, text: hoverTimeLabel(hoverTime), x: hoverX, plot: plot, color: hoverColor)
            }
        }
    }

    /// The time of the bar at `index`: a bar's own, or past the last one, the empty slot's (the rest of the
    /// day's, or one bar's length on from the last bar); nil before the first bar.
    private func time(atIndex index: Int, bars: [Bar], rest: CandleChart.RestOfDay?) -> Date? {
        guard index >= 0 else { return nil }
        if index < bars.count { return bars[index].time }
        guard let last = bars.last else { return nil }
        if let rest { return rest.from.addingTimeInterval(Double(index - bars.count) * rest.barSeconds) }
        let seconds = chart.timeframe.barSeconds ?? 86_400
        return last.time.addingTimeInterval(Double(index - bars.count + 1) * seconds)
    }

    /// The hovered time: HH:mm (with seconds under a minute's bars), the date in front if not today; the
    /// date for daily bars and longer.
    private func hoverTimeLabel(_ date: Date) -> String {
        guard chart.timeframe.isIntraday else { return Self.hoverDayFormatter.string(from: date) }
        let time = ((chart.timeframe.barSeconds ?? 60) < 60 ? Self.secondsFormatter : Self.timeFormatter).string(from: date)
        return Calendar.current.isDateInToday(date) ? time : "\(Self.dayFormatter.string(from: date)) \(time)"
    }

    /// A box on the time axis, centered on `x` (kept inside the plot's width), in the hover color.
    private func drawTimeTag(in ctx: inout ChartPainter, text: String, x: CGFloat, plot: CGRect, color: Color) {
        let width = AxisLabels.width(text, size: 9, weight: .semibold) + 8
        let minX = min(max(plot.minX, x - width / 2), plot.maxX - width)
        let rect = CGRect(x: minX, y: plot.maxY + 1, width: width, height: timeAxisHeight - 1)
        ctx.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(color))
        AxisLabels.draw([.init(text: text, point: CGPoint(x: rect.midX, y: rect.midY), anchor: .center)],
                        size: 9, weight: .semibold, color: color.isLight ? .black : .white, in: ctx)
    }

    // MARK: Indicators

    private static let vwapColor = Color.orange
    private static let fastSMAColor = Color(red: 0.3, green: 0.65, blue: 1)
    private static let slowSMAColor = Color(red: 0.75, green: 0.4, blue: 1)

    /// VWAP (intraday only, from 04:00 ET), SMA 9 and SMA 21 over the visible bars, each if turned on
    /// in Settings.
    private func drawIndicators(in ctx: inout ChartPainter, bars: [Bar], start: Int, end: Int,
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

    // MARK: Trades

    /// One arrow: an order's fills on one bar, at their volume-weighted average price.
    private struct TradeMarker {
        var bar: Int
        var isBuy: Bool
        var price: Double
    }

    /// The day's fills in this chart's symbol, on the visible bars.
    private func drawTrades(in ctx: inout ChartPainter, bars: [Bar], start: Int, end: Int, bodyWidth: CGFloat,
                            x: (Int) -> CGFloat, y: (Double) -> CGFloat) {
        guard !fills.isEmpty else { return }
        var groups: [String: (bar: Int, isBuy: Bool, shares: Double, cost: Double)] = [:]
        for fill in fills {
            guard let bar = Self.barIndex(of: fill.time, in: bars, barSeconds: chart.timeframe.barSeconds),
                  bar >= start, bar < end else { continue }
            let key = "\(fill.orderId)|\(fill.side)|\(bar)"
            var group = groups[key] ?? (bar, fill.side == "BOT", 0, 0)
            group.shares += fill.shares
            group.cost += fill.shares * fill.price
            groups[key] = group
        }
        let markers = groups.values.compactMap { g in
            g.shares > 0 ? TradeMarker(bar: g.bar, isBuy: g.isBuy, price: g.cost / g.shares) : nil
        }

        for m in markers {
            Self.drawPointer(at: CGPoint(x: x(m.bar) - bodyWidth / 2 - 1, y: y(m.price)), color: sideColors.of(m.isBuy), in: &ctx)
        }
    }

    /// An arrow pointing right, its tip at `tip`: a fill's (see `drawTrades`, `drawPointers`). Thinly
    /// outlined dark, or with `outline`, ringed in that color: a rim with sharp corners, so the arrow keeps
    /// its shape, set off from the chart by a thin dark line.
    private static func drawPointer(at tip: CGPoint, color: Color, outline: Color? = nil, in ctx: inout ChartPainter) {
        let head: CGFloat = 5, halfWidth: CGFloat = 3.5, stem: CGFloat = 5, stemHalf: CGFloat = 1
        var arrow = Path()
        arrow.move(to: tip)
        arrow.addLine(to: CGPoint(x: tip.x - head, y: tip.y - halfWidth))
        arrow.addLine(to: CGPoint(x: tip.x - head, y: tip.y - stemHalf))
        arrow.addLine(to: CGPoint(x: tip.x - head - stem, y: tip.y - stemHalf))
        arrow.addLine(to: CGPoint(x: tip.x - head - stem, y: tip.y + stemHalf))
        arrow.addLine(to: CGPoint(x: tip.x - head, y: tip.y + stemHalf))
        arrow.addLine(to: CGPoint(x: tip.x - head, y: tip.y + halfWidth))
        arrow.closeSubpath()
        // Half of each stroke shows: the fill covers its inner half.
        if let outline {
            let rim: CGFloat = 1.25, line: CGFloat = 0.75
            ctx.stroke(arrow, with: .color(.black.opacity(0.7)), style: StrokeStyle(lineWidth: (rim + line) * 2, lineJoin: .miter))
            ctx.stroke(arrow, with: .color(outline), style: StrokeStyle(lineWidth: rim * 2, lineJoin: .miter))
        } else {
            ctx.stroke(arrow, with: .color(.black.opacity(0.6)), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
        }
        ctx.fill(arrow, with: .color(color))
    }

    /// `pointers` on the visible bars, like the trade arrows, their tips just left of the candle. One after the
    /// last bar points at the last bar: its own bar isn't in yet, or never comes (a what-if trade with the
    /// market closed, on a weekend, say).
    private func drawPointers(in ctx: inout ChartPainter, bars: [Bar], start: Int, end: Int, bodyWidth: CGFloat,
                              x: (Int) -> CGFloat, y: (Double) -> CGFloat) {
        for p in pointers {
            let latest = bars.last.flatMap { p.time >= $0.time ? bars.count - 1 : nil }
            guard let bar = Self.barIndex(of: p.time, in: bars, barSeconds: chart.timeframe.barSeconds) ?? latest,
                  bar >= start, bar < end else { continue }
            Self.drawPointer(at: CGPoint(x: x(bar) - bodyWidth / 2 - 1, y: y(p.price)), color: p.color, outline: p.outline, in: &ctx)
        }
    }

    /// The bar a time falls in: the last bar starting at or before it; nil before the first bar, or
    /// after the last intraday bar ends (the fill's bar hasn't come in yet).
    static func barIndex(of time: Date, in bars: [Bar], barSeconds: Double?) -> Int? {
        var lo = 0, hi = bars.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if bars[mid].time <= time { lo = mid + 1 } else { hi = mid }
        }
        let i = lo - 1
        guard i >= 0 else { return nil }
        if let barSeconds, time.timeIntervalSince(bars[i].time) >= barSeconds, i == bars.count - 1 { return nil }
        return i
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

    /// `chartTag` is a second box in the chart, just left of the axis or of the tag when it's inside.
    private func drawLine(in ctx: inout ChartPainter, y: CGFloat, plot: CGRect, color: Color, dashed: Bool, dotted: Bool = false, tag: String,
                          tagOpacity: Double = 1, tagInside: Bool = false, chartTag: String? = nil, showsLine: Bool = true,
                          showsTag: Bool = true, lineStart: CGFloat? = nil, progress: Double? = nil, lineWidth: CGFloat = 1) {
        if showsLine {
            var path = Path()
            path.move(to: CGPoint(x: lineStart ?? plot.minX, y: y))
            path.addLine(to: CGPoint(x: plot.maxX, y: y))
            ctx.stroke(path, with: .color(color.opacity(0.8)),
                       style: StrokeStyle(lineWidth: lineWidth, dash: dotted ? [1, 2] : dashed ? [4, 3] : []))
        }
        guard showsTag else { return }
        let box = drawTag(in: &ctx, text: tag, y: y, plot: plot, color: color, opacity: tagOpacity, inside: tagInside, progress: progress)
        if let chartTag {
            drawTag(in: &ctx, text: chartTag, y: y, plot: plot, color: color, inside: true, insideRight: tagInside ? box.minX - 2 : nil)
        }
    }

    /// `opacity` fades only the box, not its text; at the opacity slider's minimum there's no box.
    /// The text is white, or black on a light box (white ⌥-click lines, say).
    /// `inside` puts the box in the chart, just left of the price axis (or of `insideRight`), instead of on it.
    /// `progress` (0–1, an order's fill): the box starts black, outlined in its color, and fills with it
    /// from the left that far, its text white on the black part.
    @discardableResult
    private func drawTag(in ctx: inout ChartPainter, text: String, y: CGFloat, plot: CGRect, color: Color,
                         opacity: Double = 1, inside: Bool = false, insideRight: CGFloat? = nil, progress: Double? = nil) -> CGRect {
        let boxed = !PriceAxis.hidesLastPriceBox(opacity)
        let textColor: NSColor = boxed && opacity >= 0.5 && color.isLight ? .black : .white
        // Core Text from lines kept between frames (see `AxisLabels`).
        let fontSize = axisFontSize
        let textSize = CGSize(width: AxisLabels.width(text, size: fontSize, weight: .semibold), height: 0)
        func drawText(_ color: NSColor, in ctx: ChartPainter) {
            AxisLabels.draw([.init(text: text, point: textAt, anchor: .leading)], size: fontSize, weight: .semibold, color: color, in: ctx)
        }
        let rect = inside
            ? CGRect(x: (insideRight ?? plot.maxX - 2) - textSize.width - 8, y: y - tagHeight / 2, width: textSize.width + 8, height: tagHeight)
            : CGRect(x: plot.maxX + 1, y: y - tagHeight / 2, width: max(axisWidth - 2, textSize.width + 8), height: tagHeight)
        let textAt = CGPoint(x: rect.minX + 4, y: y)
        if boxed, let progress {
            let box = Path(roundedRect: rect, cornerRadius: 3)
            let split = rect.minX + rect.width * min(1, max(0, progress))
            let filled = CGRect(x: rect.minX, y: rect.minY, width: split - rect.minX, height: rect.height)
            let unfilled = CGRect(x: split, y: rect.minY, width: rect.maxX - split, height: rect.height)
            ctx.fill(box, with: .color(Color.black.opacity(opacity)))
            var lit = ctx
            lit.clip(to: Path(filled))
            lit.fill(box, with: .color(color.opacity(opacity)))
            drawText(textColor, in: lit)
            var dark = ctx
            dark.clip(to: Path(unfilled))
            drawText(.white, in: dark)
            ctx.stroke(Path(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 3), with: .color(color.opacity(opacity)), lineWidth: 1)
        } else {
            if boxed { ctx.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(color.opacity(opacity))) }
            drawText(textColor, in: ctx)
        }
        return rect
    }

    /// The P/L at the hovered price, in a green (gain) or red (loss) tag just left of the price axis:
    /// whole NOK at USD.NOK (dollars and cents without a rate).
    private func drawPnLTag(in ctx: inout ChartPainter, pnl: Double, y: CGFloat, plot: CGRect) {
        let text = usdNok.map { Fmt.nok(pnl * $0, signed: true, groupedFrom: 0) } ?? Fmt.amount(pnl, signed: true)
        let width = AxisLabels.width(text, size: axisFontSize, weight: .semibold) + 8
        let rect = CGRect(x: plot.maxX - width - 2, y: y - tagHeight / 2, width: width, height: tagHeight)
        ctx.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(sideColors.of(pnl >= 0)))
        AxisLabels.draw([.init(text: text, point: CGPoint(x: rect.midX, y: y), anchor: .center)],
                        size: axisFontSize, weight: .semibold, color: .white, in: ctx)
    }

    private static func sessionTint(_ phase: MarketSession.Phase, scene: ChartScene?) -> Color? {
        switch phase {
        case .regular: nil
        case .preMarket, .afterHours: scene?.label.opacity(0.06) ?? Color.primary.opacity(0.045)
        case .overnight, .closed: scene?.grid.opacity(0.08) ?? Color.indigo.opacity(0.08)
        }
    }

    /// A time axis label: the time, but the date for daily bars, for labels 12 hours or more apart,
    /// and where a new day starts since the label before (`previous`, `spacing` seconds of bars back).
    private func timeLabel(_ date: Date, previous: Date?, spacing: Double) -> String {
        let showsDay = !(chart.timeframe.isIntraday && spacing < 12 * 3600
                         && previous.map({ Self.localDay($0) == Self.localDay(date) }) ?? true)
        // The same times come back frame after frame while zooming or panning: formatted once each.
        let key = Int64(date.timeIntervalSince1970) << 1 | (showsDay ? 1 : 0)
        if let cached = Self.cacheLock.withLock({ Self.timeLabels[key] }) { return cached }
        let label = (showsDay ? Self.dayFormatter : Self.timeFormatter).string(from: date)
        Self.cacheLock.withLock {
            if Self.timeLabels.count > 20_000 { Self.timeLabels.removeAll(keepingCapacity: true) }
            Self.timeLabels[key] = label
        }
        return label
    }

    nonisolated(unsafe) private static var timeLabels: [Int64: String] = [:]
    /// Shared by the charts rendering at once on several threads.
    private static let cacheLock = NSLock()

    /// The local calendar day a time falls in, as a day count.
    private static func localDay(_ time: Date) -> Int {
        Int(((time.timeIntervalSince1970 + Double(localOffsets.offset(at: time))) / 86_400).rounded(.down))
    }

    private static let localOffsets = ZoneOffsets(.current)
    private static let newYorkOffsets = ZoneOffsets(TimeZone(identifier: "America/New_York")!)

    /// The forex trading day a time falls in, counted in days: each starts at 17:00 New York.
    private static func forexDay(_ time: Date) -> Int {
        let local = time.timeIntervalSince1970 + Double(newYorkOffsets.offset(at: time))
        return Int(((local + 7 * 3600) / 86_400).rounded(.down))
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM d"; return f
    }()

    private static let secondsFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    private static let hoverDayFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM d, yyyy"; return f
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

// MARK: - Rendering

/// Snap (see `ChartSharpness`): candle bodies, volume bars and wicks on whole pixels. Every body is the same number
/// of pixels wide, with the same parity as the wick's, so the wick sits exactly in its middle.
nonisolated struct PixelSnap {
    let scale: CGFloat
    let bodyPixels: CGFloat
    let wickPixels: CGFloat

    init(scale: CGFloat, bodyWidth: CGFloat) {
        self.scale = max(1, scale)
        let wick = max(1, self.scale.rounded())
        var body = max(1, (bodyWidth * self.scale).rounded())
        if body > wick, Int(body - wick) % 2 != 0 { body -= 1 }
        bodyPixels = max(wick, body)
        wickPixels = wick
    }

    private func pixel(_ v: CGFloat) -> CGFloat { (v * scale).rounded() / scale }

    private func left(centeredAt x: CGFloat) -> CGFloat { ((x * scale) - bodyPixels / 2).rounded() / scale }

    /// A body (or volume bar) from `top` to `bottom`, at least `minHeight` points tall.
    func column(centeredAt x: CGFloat, top: CGFloat, bottom: CGFloat, minHeight: CGFloat) -> CGRect {
        let t = pixel(top), b = max(t + minHeight, pixel(bottom))
        return CGRect(x: left(centeredAt: x), y: t, width: bodyPixels / scale, height: b - t)
    }

    /// The wick: a column one point wide, in the middle of the body's.
    func wick(centeredAt x: CGFloat, top: CGFloat, bottom: CGFloat) -> CGRect {
        let t = pixel(top), b = max(t + wickPixels / scale, pixel(bottom))
        return CGRect(x: left(centeredAt: x) + (bodyPixels - wickPixels) / 2 / scale, y: t, width: wickPixels / scale, height: b - t)
    }
}

/// A time zone's offsets from GMT, one per stretch between its daylight saving changes (2000–2050), looked up without a
/// lock: the charts render on several threads at once, and a zone's own lookup is slow.
nonisolated final class ZoneOffsets: Sendable {
    private let starts: [Double]
    private let offsets: [Int]

    init(_ zone: TimeZone) {
        var t = Date(timeIntervalSince1970: 946_684_800)
        let end = Date(timeIntervalSince1970: 2_524_608_000)
        var starts = [-Double.infinity], offsets = [zone.secondsFromGMT(for: t)]
        while let next = zone.nextDaylightSavingTimeTransition(after: t), next < end {
            starts.append(next.timeIntervalSince1970)
            offsets.append(zone.secondsFromGMT(for: next))
            t = next
        }
        self.starts = starts
        self.offsets = offsets
    }

    func offset(at time: Date) -> Int {
        let s = time.timeIntervalSince1970
        var lo = 0, hi = starts.count
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if starts[mid] <= s { lo = mid } else { hi = mid }
        }
        return offsets[lo]
    }
}

/// A buffer a chart is drawn into and shown from: an IOSurface, which the window server composites as it is.
nonisolated final class ChartSurface: @unchecked Sendable {
    let surface: IOSurface
    let context: CGContext
    let pixelWidth: Int
    let pixelHeight: Int
    /// Being drawn into, or waiting to be shown.
    var busy = false

    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    init?(pixelWidth: Int, pixelHeight: Int) {
        let bytesPerRow = (pixelWidth * 4 + 63) & ~63
        guard pixelWidth > 0, pixelHeight > 0,
              let surface = IOSurface(properties: [
                .width: pixelWidth, .height: pixelHeight, .bytesPerElement: 4, .bytesPerRow: bytesPerRow,
                .allocSize: bytesPerRow * pixelHeight, .pixelFormat: 0x4247_5241, // 'BGRA'
              ]),
              let context = CGContext(data: surface.baseAddress, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8,
                                      bytesPerRow: surface.bytesPerRow, space: Self.sRGB,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        // Tagged sRGB, so the window server shows its colors as drawn.
        if let space = Self.sRGB.copyPropertyList() {
            IOSurfaceSetValue(unsafeBitCast(surface, to: IOSurfaceRef.self), kIOSurfaceColorSpace, space)
        }
        self.surface = surface
        self.context = context
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

/// One chart's frame to draw: on any thread, into its own surface.
nonisolated final class ChartRenderJob: @unchecked Sendable {
    let frame: ChartFrame
    let size: CGSize
    let scale: CGFloat
    let target: ChartSurface
    /// The chart view's layer, shown into from the render thread.
    let layer: CALayer

    private static let dark = NSAppearance(named: .darkAqua)

    init(frame: ChartFrame, size: CGSize, scale: CGFloat, target: ChartSurface, layer: CALayer) {
        self.frame = frame
        self.size = size
        self.scale = scale
        self.target = target
        self.layer = layer
    }

    func render() {
        let surface = target.surface
        surface.lock(options: [], seed: nil)
        defer { surface.unlock(options: [], seed: nil) }
        let cg = target.context
        cg.saveGState()
        defer { cg.restoreGState() }
        cg.clear(CGRect(x: 0, y: 0, width: target.pixelWidth, height: target.pixelHeight))
        // The chart draws top-down, in points; a surface's first row is its top.
        cg.translateBy(x: 0, y: CGFloat(target.pixelHeight))
        cg.scaleBy(x: scale, y: -scale)
        let draw = {
            var painter = ChartPainter(cg)
            self.frame.draw(in: &painter, size: self.size)
        }
        if let dark = Self.dark { dark.performAsCurrentDrawingAppearance(draw) } else { draw() }
    }
}

/// Draws a window's charts: at each refresh of its screen, first the input waiting to be applied (scrolls, swipes and
/// pinches spread over the frames, see `addFrameHandler`), then every chart whose drawing changed since (see
/// `ChartCanvasView.setNeedsRender`) is copied, all of them are drawn at once on every core, and once all are drawn
/// they're shown together, from the drawing thread. Input and drawing in the same refresh: a zoom step is on screen
/// at the next one. While a frame is still drawing, changes wait for the next refresh after it.
final class ChartRenderLoop: NSObject {
    private static var loops: [ObjectIdentifier: ChartRenderLoop] = [:]

    static func of(_ window: NSWindow) -> ChartRenderLoop {
        let id = ObjectIdentifier(window)
        if let loop = loops[id] { return loop }
        let loop = ChartRenderLoop(window: window)
        loops[id] = loop
        return loop
    }

    private weak var window: NSWindow?
    private var clock: ScreenClock?
    private var dirty: [ObjectIdentifier: ChartCanvasView] = [:]
    private struct FrameHandler {
        weak var owner: AnyObject?
        let run: (CFTimeInterval) -> Bool
    }
    private var handlers: [ObjectIdentifier: FrameHandler] = [:]
    /// Set on the main thread as a frame starts drawing, cleared on the drawing thread once it's shown.
    private let inFlight = InFlight()
    /// Refreshes in a row with nothing to do: the display link stops after a few.
    private var idleTicks = 0
    private var closeObserver: (any NSObjectProtocol)?
    private var screenObserver: (any NSObjectProtocol)?

    private init(window: NSWindow) {
        self.window = window
        super.init()
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
        screenObserver = NotificationCenter.default.addObserver(forName: NSWindow.didChangeScreenNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                // On another screen: its refreshes from now on.
                self?.clock?.stop()
                self?.clock = nil
                self?.wake()
            }
        }
    }

    private func close() {
        clock?.stop()
        clock = nil
        dirty = [:]
        handlers = [:]
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let window { Self.loops[ObjectIdentifier(window)] = nil }
    }

    func setNeedsRender(_ view: ChartCanvasView) {
        dirty[ObjectIdentifier(view)] = view
        wake()
    }

    /// `run` is called first at each refresh, with the refresh's length in seconds, for as long as it returns true
    /// (and `owner` lives): input spread over the frames, applied right before the charts are copied.
    func addFrameHandler(_ owner: AnyObject, _ run: @escaping (CFTimeInterval) -> Bool) {
        handlers[ObjectIdentifier(owner)] = FrameHandler(owner: owner, run: run)
        wake()
    }

    private func wake() {
        idleTicks = 0
        if clock == nil, let window, let screen = window.screen ?? NSScreen.main {
            clock = ScreenClock(screen: screen) { [weak self] frame in self?.tick(frame: frame) }
        }
        clock?.start()
    }

    private func tick(frame: CFTimeInterval) {
        for (id, handler) in handlers where handler.owner == nil || !handler.run(frame) {
            handlers[id] = nil
        }
        guard !dirty.isEmpty, !inFlight.isSet else {
            if dirty.isEmpty, handlers.isEmpty {
                idleTicks += 1
                if idleTicks > 30 { clock?.stop() }
            }
            return
        }
        idleTicks = 0
        let views = Array(dirty.values)
        dirty.removeAll(keepingCapacity: true)
        var shown: [(ChartCanvasView, ChartRenderJob)] = []
        for view in views {
            if let job = view.prepareRender() { shown.append((view, job)) }
        }
        guard !shown.isEmpty else { return }
        inFlight.set(true)
        let jobs = shown.map(\.1)
        let started = CACurrentMediaTime()
        let inFlight = inFlight
        DispatchQueue.global(qos: .userInteractive).async {
            DispatchQueue.concurrentPerform(iterations: jobs.count) { jobs[$0].render() }
            // Shown from here, all together, without waiting for the main thread (busy with SwiftUI's updates
            // some of the time).
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for job in jobs {
                job.layer.contentsScale = job.scale
                job.layer.contents = job.target.surface
            }
            CATransaction.commit()
            inFlight.set(false)
            let span = CACurrentMediaTime() - started
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    for (view, job) in shown { view.presented(job) }
                    FrameMeter.shared.record(span: span, charts: jobs.count)
                }
            }
        }
    }
}

/// Calls `tick` on the main thread at every refresh of a screen, with the refresh's length. A Core Video display
/// link: AppKit's (`NSScreen.displayLink`, a `CADisplayLink`) calls back at most 120 times a second, even on a
/// 240 Hz screen asking for more. A refresh whose call the main thread hasn't taken yet isn't queued again.
final class ScreenClock {
    private var link: CVDisplayLink?
    private let tick: (CFTimeInterval) -> Void
    private let pending = InFlight()
    private var running = false

    init?(screen: NSScreen, tick: @escaping (CFTimeInterval) -> Void) {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        self.tick = tick
        var made: CVDisplayLink?
        guard CVDisplayLinkCreateWithCGDisplay(CGDirectDisplayID(number.uint32Value), &made) == kCVReturnSuccess, let made else { return nil }
        link = made
        let pending = pending
        CVDisplayLinkSetOutputHandler(made) { [weak self] _, _, out, _, _ in
            guard !pending.isSet else { return kCVReturnSuccess }
            pending.set(true)
            let scale = Double(out.pointee.videoTimeScale)
            let frame = scale > 0 ? Double(out.pointee.videoRefreshPeriod) / scale : 1.0 / 60
            DispatchQueue.main.async {
                pending.set(false)
                MainActor.assumeIsolated { self?.fire(frame) }
            }
            return kCVReturnSuccess
        }
    }

    private func fire(_ frame: CFTimeInterval) {
        if running { tick(max(0.001, frame)) }
    }

    func start() {
        guard !running, let link else { return }
        running = true
        CVDisplayLinkStart(link)
    }

    func stop() {
        guard running, let link else { return }
        running = false
        CVDisplayLinkStop(link)
    }

    deinit {
        if let link { CVDisplayLinkStop(link) }
    }
}

/// A flag set on one thread and read on another.
nonisolated final class InFlight: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set(_ new: Bool) { lock.withLock { value = new } }
}
