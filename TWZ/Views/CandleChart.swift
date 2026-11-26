//
//  CandleChart.swift
//  TWZ
//
//  Lightweight candlestick + volume chart drawn with a single SwiftUI Canvas.
//  Trackpad: two-finger swipe left/right to pan (with momentum), up/down or pinch to zoom
//  around the cursor; a diagonal swipe does both; with ⇧, ⌘ or ⌥ held (any of them, together too), a
//  swipe moves the grid's Zoom slider instead (see `onZoomAll`), and with ⌃ (others too) it squeezes or
//  stretches the price axis; with ⌃⇧ (no ⌘ or ⌥) the space between the latest candle and the price axis, as
//  the Space slider (up or right: more), on every chart. With Settings › Appearance's view sync on, any view moved by hand (dragged, swiped,
//  pinched, ⌃-scaled, reset) moves every other chart in the same window alike (see `ViewSync`); with ⇧, ⌘ or ⌥ held
//  (a swipe: begun with them, under Swiping on) only this chart moves.
//  Settings › Appearance › Swiping swaps the two: a swipe the grid's zoom, a
//  ⇧-, ⌘- or ⌥-swipe this chart.
//  Mouse: wheel zooms, shift-wheel pans, ⌘- or ⌥-wheel the grid's zoom, ⌃-wheel the price axis, ⌃⇧-wheel the space.
//  Drag pans freely, in time and price. Right-click resets the view, as does double-clicking
//  anywhere but an order line (unless `onDoubleClick` takes it: with a ⌃-click what-if on the chart,
//  that comes off instead); double-clicking an order line cancels that order, and a single click
//  does for the lines placed by ⌃-click (stop loss, take profit, what-if).
//  Intraday charts shade the sessions outside regular hours: pre-market and after hours in grey,
//  overnight in indigo (not forex charts: forex trades round the clock).
//  Indicators: SMA 9 and SMA 21 on every chart, plus VWAP (from 04:00 ET) on intraday charts;
//  each can be turned off, and their thickness set, in Settings › Appearance.
//  Trades (off by default): the day's fills in the symbol, an arrow pointing right at each, green for a
//  buy and red for a sell, its tip at the fill price just left of the bar the fill came in (as a
//  what-if trade's fills always show, green for a long, red for a short, ringed in the what-if pink); a round trip double-clicked in the Round trips tab
//  shows its fills' arrows either way.
//  With Settings › Trading's dollar ⌥ / ⌘-click on, ⌥-click buys and ⌘-click sells a fixed dollar
//  amount at the clicked price, the hover line and price tag green / red while the key is held.
//  Hovering the price area shows, left of the price tag, the P/L at the hovered price (see `hoverPnL`).
//  ⌃-clicking with no position open places a what-if buy at that price (see `WhatIf`); ⌃-clicking its
//  line, or double-clicking anywhere on the chart, removes it.
//  Triple-clicking the price area puts an option at that price in the Options window (see `onTripleClick`).
//

import SwiftUI
import AppKit

struct PriceLine {
    var price: Double
    var color: Color
    var label: String
    var dashed = true
    /// Small dots, finer than the dashes (a round trip shown from the Round trips tab, or Settings' Dots).
    var dotted = false
    /// The order the line belongs to; double-clicking the line cancels it. An order's price box sits in
    /// the chart, just left of the axis, above the last price line, so the axis boxes never cover it.
    var orderId: Int?
    /// Drawn above the last price line, and its price box moves into the chart, just left of the axis,
    /// where the last price box would cover it.
    var movesAsideForLastPrice = false
    /// Drawn as an order line is (from the latest candle to the axis, the price box in the chart
    /// beside the axis, above the last price line) without being one: the last trade's exit.
    var drawnLikeOrder = false
    /// A second box beside the price one, in the chart just left of the axis (or left of the price box
    /// when that has moved into the chart): the what-if line's NOK value.
    var chartText: String?
    /// A single click on the line cancels it too (the ⌃-click lines: stop loss, take profit, what-if).
    var cancelsOnClick = false
    /// How much of the order has filled (0–1): its price box fills with the line's color that far.
    var fillProgress: Double?
    /// A market order's line: it has no price of its own, so it sits at the last price, moving with
    /// it until the order fills (`price` is only used before the chart has a price).
    var followsLastPrice = false
    /// Across the whole chart even with an `orderId`, its price box on the axis (a trend line).
    var drawnAcross = false
    var lineWidth: CGFloat = 1
    /// Off: just the line, no price box.
    var showsTag = true
}

/// A sideways arrow pointing right at a price at a time, its tip just left of that time's candle
/// (a what-if trade's fills).
struct PricePointer {
    var time: Date
    var price: Double
    var color: Color
    /// A thick outline in this color instead of the trade arrows' thin dark one.
    var outline: Color?
}

extension ChartModel {
    /// The rest of today's extended session after the last intraday bar (see `CandleChart.RestOfDay`); nil for
    /// daily and forex charts.
    var restOfDay: CandleChart.RestOfDay? {
        guard let seconds = timeframe.barSeconds, let last = bars.last, !ForexPair.isForex(symbol) else { return nil }
        let from = last.time.addingTimeInterval(seconds)
        let sessions = MarketSession.restOfDay(from: from)
        guard let end = sessions.last?.end else { return nil }
        let todayBars = bars.reversed().prefix { $0.vwapDay == last.vwapDay }.count
        return CandleChart.RestOfDay(from: from, barSeconds: seconds, sessions: sessions,
                                     slots: Int((end.timeIntervalSince(from) / seconds).rounded(.up)), todayBars: todayBars)
    }

    /// Empty slots right of the last bar: the Space slider's count (`space`) normally; zooming out past today's bars (and the
    /// default zoom) uses the room for the rest of the day, until all of it through after hours (20:00 ET) is on screen.
    func rightPadding(_ rest: CandleChart.RestOfDay?, space: Double) -> Double {
        guard let rest else { return space }
        return min(max(space, Double(rest.slots)), max(space, visibleBars - max(Double(rest.todayBars), defaultVisibleBars)))
    }

    /// How far left of the price axis the latest candle's right edge is, as a share of the chart's width: 0 while it's
    /// off the right (scrolled back), at most 1.
    func latestBarShare(_ rest: CandleChart.RestOfDay?, space: Double) -> Double {
        let padding = rightPadding(rest, space: space)
        return min(1, max(0, (padding - scrollBack) / (visibleBars + padding)))
    }

    /// Zooms to `visible` bars, the latest candle staying where it is on screen (the chart's right edge while it's
    /// off the right): Settings › Appearance › Zoom keeps the latest candle in place.
    func zoomKeepingLatestBar(to visible: Double) {
        let space = UserDefaults.standard.object(forKey: RightSpace.key) as? Double ?? RightSpace.defaultBars
        let rest = restOfDay
        let oldPadding = rightPadding(rest, space: space), oldSlots = visibleBars + oldPadding
        let share = latestBarShare(rest, space: space)
        visibleBars = visible
        let newPadding = rightPadding(rest, space: space)
        let back = scrollBack + (newPadding - oldPadding) - share * (visibleBars + newPadding - oldSlots)
        scrollBack = min(max(0, Double(bars.count) - 10), max(-visibleBars / 2, back))
    }
}

/// Settings › Appearance › Zoom keeps the latest candle in place: on (the default), zooming (a swipe, pinch or wheel on a
/// chart, the grid's zoom, the Zoom slider) keeps the latest candle where it is on screen, the bars before it spreading
/// or closing up to its left; off, a chart zooms around the pointer and the grid's zoom keeps the Space slider's bars
/// right of the latest candle, so it moves as the bars widen or narrow.
enum ZoomAnchor {
    static let keepsLatestKey = "zoomKeepsLatestCandle"
    static let defaultKeepsLatest = true

    static var keepsLatest: Bool { UserDefaults.standard.object(forKey: keepsLatestKey) as? Bool ?? defaultKeepsLatest }
}

/// Loads older bars once a chart's view reaches the oldest bar loaded: zoomed or scrolled out that far, or too little
/// history to fill it (see `Broker.loadOlderBars`). Zoomed out as wide as the bars loaded counts too: zooming around the
/// pointer leaves room for the future on the right, so the oldest bar can stay just off screen when the zoom stops at
/// every bar loaded (a forex pair's day of minutes is more than `maxVisibleBars`). Checked as the chart draws, so
/// nothing in SwiftUI follows the zoom and place on every frame.
enum OlderBars {
    /// Each chart's bar count while its view reaches the oldest bar, -1 while it doesn't.
    private static var shown: [ObjectIdentifier: Int] = [:]

    static func check(_ chart: ChartModel, broker: Broker) {
        let count = Double(chart.bars.count)
        let reaches = count > 0 && (chart.scrollBack + chart.visibleBars >= count || chart.visibleBars >= count)
        // Older bars that still leave it on screen ask for the page before them.
        let now = reaches ? chart.bars.count : -1
        let id = ObjectIdentifier(chart)
        guard shown[id] != now else { return }
        shown[id] = now
        if reaches { DispatchQueue.main.async { broker.loadOlderBars(chart) } }
    }
}

/// Empty bar slots between the last candle and the price axis, set by the Space slider beside Zoom.
enum RightSpace {
    static let key = "chartRightSpaceBars"
    static let defaultBars = 3.0
    static let range = 0.0...40.0
}

struct CandleChart: View {
    @Environment(Broker.self) private var broker
    @Environment(Workspace.self) private var workspace
    @AppStorage(ViewSync.key) private var viewSync = ViewSync.defaultOn
    @Environment(\.sideColors) private var sideColors
    let chart: ChartModel
    var lines: [PriceLine] = []
    var pointers: [PricePointer] = []
    /// ⌥-click in the price area: called with the price under the cursor.
    var onAltClick: ((Double) -> Void)?
    /// ⌘⇧-click in the price area: called with the price under the cursor.
    var onCommandClick: ((Double) -> Void)?
    /// Price tag color while ⌥ / ⌘⇧ is held (with a handler for that click).
    var altClickTint: Color = .white
    var commandClickTint: Color = .red
    /// The hover line takes the ⌥ / ⌘ tint too, not just its price tag.
    var tintsHoverLine = false
    /// ⌃-click in the price area: called with the price under the cursor.
    var onControlClick: ((Double) -> Void)?
    /// ⌃-click on an order line: called with its order id first; returning true skips `onControlClick`.
    var onControlClickLine: ((Int) -> Bool)?
    /// Price tag color while ⌃ is held: what a ⌃-click there would place (nil: nothing).
    var controlClickColor: ((Double) -> Color?)?
    /// While hovering the price area: the P/L if sold at that price (nil: none to show).
    var hoverPnL: ((Double) -> Double?)?
    /// While the pointer is over the chart, on every move.
    var onHover: (() -> Void)?
    /// Double-click on an order line: called with its order id.
    var onCancelOrder: ((Int) -> Void)?
    /// Any left click on the chart, modified or not (it still pans, zooms or places orders as usual).
    var onClick: (() -> Void)?
    /// Double-click anywhere but an order line; true when it took the double-click, so the view stays
    /// as it is (otherwise it resets).
    var onDoubleClick: (() -> Bool)?
    /// Fills drawn as arrows even with Trades off (a round trip shown from the Round trips tab).
    var shownFillIds: Set<String> = []
    /// ⇧-, ⌘- or ⌥-swipe on the trackpad: the grid's zoom times this (above 1: zoomed out), as its Zoom slider.
    var onZoomAll: ((Double) -> Void)?
    /// Triple-click in the price area: called with the price under the cursor. With it, a double-click's view reset
    /// (not an order line's cancel) waits a double-click's time, so a third click can take it instead.
    var onTripleClick: ((Double) -> Void)?

    private var candleTheme: CandleTheme { ChartSettings.shared.values.candleTheme }

    /// Read here rather than passed in, so each tick redraws only the chart, not the pane around it.
    private var lastPrice: Double? { broker.quote(chart.symbol)?.last }
    private var customUp: String { ChartSettings.shared.values.customUp }
    private var customDown: String { ChartSettings.shared.values.customDown }
    private var hoverHex: String { ChartSettings.shared.values.hoverHex }
    private var lastPriceHex: String { ChartSettings.shared.values.lastPriceHex }
    private var lastPriceDashed: Bool { ChartSettings.shared.values.lastPriceDashed }
    private var showLastPriceLine: Bool { ChartSettings.shared.values.showLastPriceLine }
    private var showGrid: Bool { ChartSettings.shared.values.showGrid }
    private var volumeOpacity: Double { ChartSettings.shared.values.volumeOpacity }
    private var hoverDashed: Bool { ChartSettings.shared.values.hoverDashed }
    private var lastPriceDots: Bool { ChartSettings.shared.values.lastPriceDots }
    private var hoverDots: Bool { ChartSettings.shared.values.hoverDots }
    private var showVWAP: Bool { ChartSettings.shared.values.showVWAP }
    private var showFastSMA: Bool { ChartSettings.shared.values.showFastSMA }
    private var showSlowSMA: Bool { ChartSettings.shared.values.showSlowSMA }
    private var showTrades: Bool { ChartSettings.shared.values.showTrades }
    private var indicatorWidth: Double { ChartSettings.shared.values.indicatorWidth }
    private var axisFontSize: Double { ChartSettings.shared.values.axisFontSize }
    private var labelSpacing: Double { ChartSettings.shared.values.labelSpacing }
    private var lastPriceOpacity: Double { ChartSettings.shared.values.lastPriceOpacity }
    /// The settings above are read once for every chart (see `ChartSettings`).
    private var rightPaddingBars: Double {
        get { ChartSettings.shared.values.rightPaddingBars }
        nonmutating set { UserDefaults.standard.set(newValue, forKey: RightSpace.key) }
    }
    @State private var hover: CGPoint?
    @State private var dragStart: (scroll: Double, shift: Double)?
    @State private var optionHeld = false
    @State private var controlHeld = false
    @State private var commandHeld = false
    /// A double-click's reset, waiting to see if a third click comes (see `onTripleClick`).
    @State private var pendingReset: Task<Void, Never>?
    @State private var tripleClickAt = Date.distantPast

    /// Widens with the axis text so larger prices still fit.
    private var axisWidth: CGFloat { max(58, (axisFontSize * 5.8).rounded()) }
    /// Height of the price boxes on the axis.
    private var tagHeight: CGFloat { axisFontSize + 6 }
    private let timeAxisHeight: CGFloat = 16

    var body: some View {
        GeometryReader { geo in
            let plotWidth = max(1, geo.size.width - axisWidth)
            // Read here, so a change in them redraws the chart; the rest it draws from (the chart's zoom and place,
            // bars, prices) redraws it on its own, without SwiftUI (see `ChartCanvas`).
            let _ = (hover, optionHeld, controlHeld, commandHeld)
            Color.clear
            .background(ChartCanvas { painter, size in draw(in: &painter, size: size) })
            .overlay(alignment: .topTrailing) {
                // No trade today (a US market holiday, or before the first one): the price is yesterday's close.
                if broker.quote(chart.symbol)?.lastIsClose == true {
                    Text("Yesterday's close · no trades today")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.orange))
                        .padding(.top, 4).padding(.trailing, axisWidth + 4)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                if case .active(let p) = phase {
                    hover = p
                    onHover?()
                    optionHeld = NSEvent.modifierFlags.contains(.option)
                    controlHeld = NSEvent.modifierFlags.contains(.control)
                    commandHeld = NSEvent.modifierFlags.isSuperset(of: [.command, .shift])
                } else {
                    hover = nil
                }
            }
            .gesture(panGesture(plotWidth: plotWidth, plotHeight: plotRect(size: geo.size).height))
            .onTapGesture(count: 2) { location in
                if let id = orderLine(near: location, size: geo.size) {
                    onCancelOrder?(id)
                } else if onTripleClick == nil {
                    if onDoubleClick?() != true { resetView() }
                } else if Date().timeIntervalSince(tripleClickAt) > NSEvent.doubleClickInterval {
                    pendingReset?.cancel()
                    pendingReset = Task { @MainActor in
                        try? await Task.sleep(for: .seconds(NSEvent.doubleClickInterval))
                        guard !Task.isCancelled else { return }
                        if onDoubleClick?() != true { resetView() }
                    }
                }
            }
            .onTapGesture { location in
                if let id = orderLine(near: location, size: geo.size, singleClick: true) { onCancelOrder?(id) }
            }
            .background(ScrollCatcher(
                onScroll: { dx, dy, location, solo in
                    if dx != 0 { pan(byPoints: dx, plotWidth: plotWidth, solo: solo) }
                    if dy != 0 { zoom(by: exp(dy * 0.01), at: location.x, plotWidth: plotWidth, solo: solo) }
                },
                onPriceScale: { dy in scalePrices(by: exp(dy * 0.01)) },
                onShiftScroll: onZoomAll.map { zoomAll in { d in zoomAll(exp(d * 0.01)) } },
                onRightSpace: { bars in
                    rightPaddingBars = min(RightSpace.range.upperBound, max(RightSpace.range.lowerBound, rightPaddingBars + bars))
                },
                onMagnify: { magnification, location in
                    zoom(by: 1 / (1 + magnification), at: location.x, plotWidth: plotWidth)
                },
                onClick: { onClick?() },
                onModifiedClick: { location, flags in
                    if flags == .control, let onControlClickLine,
                       let id = orderLine(near: location, size: geo.size), onControlClickLine(id) {
                        return true
                    }
                    guard let handler = flags == .control ? onControlClick : flags == [.command, .shift] ? onCommandClick : onAltClick,
                          let price = price(at: location, size: geo.size) else { return false }
                    handler(price)
                    return true
                },
                onModifierKeys: { flags in
                    optionHeld = flags.contains(.option)
                    controlHeld = flags.contains(.control)
                    commandHeld = flags.isSuperset(of: [.command, .shift])
                },
                onRightClick: resetView,
                onTripleClick: onTripleClick.map { handler in
                    { location in
                        tripleClickAt = Date()
                        pendingReset?.cancel()
                        pendingReset = nil
                        if let price = price(at: location, size: geo.size) { handler(price) }
                    }
                }
            ))
        }
    }

    // MARK: Viewport

    private func barWidth(plotWidth: CGFloat) -> CGFloat {
        plotWidth / (chart.visibleBars + rightPadding(restOfDay))
    }

    /// The rest of today's extended session after the last intraday bar, as empty slots to its right.
    struct RestOfDay {
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

    private var restOfDay: RestOfDay? { chart.restOfDay }

    private func rightPadding(_ rest: RestOfDay?) -> Double { chart.rightPadding(rest, space: rightPaddingBars) }

    /// Clamped write: never past the oldest bars, and at most half a screen into the future.
    private func setScrollBack(_ value: Double, solo: Bool? = nil) {
        let maxBack = max(0, Double(chart.bars.count) - 10)
        chart.scrollBack = min(maxBack, max(-chart.visibleBars / 2, value))
        chart.adjustedByHand = true
        chart.pendingEdge = nil
        viewChanged(solo: solo)
    }

    /// The view was moved by hand: with Settings › Appearance's view sync on, every other chart in this
    /// window takes it (see `ViewSync`), unless `solo` (by default: ⇧, ⌘ or ⌥ held now).
    private func viewChanged(solo: Bool? = nil) {
        let solo = solo ?? !NSEvent.modifierFlags.intersection([.shift, .command, .option]).isEmpty
        if viewSync, !solo { workspace.matchViews(to: chart, sameWindow: true) }
    }

    /// Positive points move the content right (revealing older bars).
    private func pan(byPoints points: CGFloat, plotWidth: CGFloat, solo: Bool? = nil) {
        setScrollBack(chart.scrollBack + Double(points / barWidth(plotWidth: plotWidth)), solo: solo)
    }

    /// Scales the number of visible bars by `factor`, keeping the bar under `anchorX` in place.
    /// With Settings › Appearance › Zoom keeps the latest candle in place, the latest candle stays where it is
    /// instead (the chart's right edge while it's off the right), whatever the pointer's place.
    private func zoom(by factor: Double, at anchorX: CGFloat, plotWidth: CGFloat, solo: Bool? = nil) {
        let rest = restOfDay
        let x = ZoomAnchor.keepsLatest
            ? plotWidth * CGFloat(1 - chart.latestBarShare(rest, space: rightPaddingBars))
            : min(plotWidth, max(0, anchorX))
        let oldWidth = barWidth(plotWidth: plotWidth), oldPadding = rightPadding(rest)
        // Zooms out as far as all the loaded bars (at least `maxVisibleBars`).
        chart.visibleBars = min(max(ChartModel.maxVisibleBars, Double(chart.bars.count)), max(15, chart.visibleBars * factor))
        let newWidth = barWidth(plotWidth: plotWidth), newPadding = rightPadding(rest)
        let fromRight = Double(plotWidth - x)
        setScrollBack(chart.scrollBack + (newPadding - oldPadding) + fromRight / oldWidth - fromRight / newWidth, solo: solo)
    }

    /// Stretches (factor < 1) or squeezes (> 1) the price axis around the middle of the view.
    private func scalePrices(by factor: Double) {
        chart.priceScale = min(20, max(0.05, chart.priceScale * factor))
        chart.adjustedByHand = true
        viewChanged()
    }

    /// Latest bars at the right edge, default zoom, price range fitted to the bars again; no longer
    /// adjusted by hand, so scales apply to it again.
    private func resetView() {
        chart.adjustedByHand = false
        chart.scrollBack = 0
        chart.visibleBars = chart.defaultVisibleBars
        chart.priceShift = 0
        chart.priceScale = 1
        viewChanged()
    }

    // MARK: Gestures

    /// The content follows the pointer both ways: sideways through time, up and down in price.
    private func panGesture(plotWidth: CGFloat, plotHeight: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                FrameMeter.shared.input()
                let start = dragStart ?? (chart.scrollBack, chart.priceShift)
                dragStart = start
                // The shift is a fraction of the unscaled range; scaled, the content still follows the pointer.
                chart.priceShift = start.shift + Double(value.translation.height / max(1, plotHeight)) * chart.priceScale
                setScrollBack(start.scroll + Double(value.translation.width / barWidth(plotWidth: plotWidth)))
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

    /// `lines`, those following the last price moved to it.
    private var placedLines: [PriceLine] {
        guard lines.contains(where: \.followsLastPrice), let last = lastPrice ?? chart.bars.last?.close else { return lines }
        return lines.map { line in
            var line = line
            if line.followsLastPrice { line.price = last }
            return line
        }
    }

    /// The order line closest to `point` vertically, if one is within a few points of it; for a
    /// `singleClick`, only if that closest line cancels on a single click.
    private func orderLine(near point: CGPoint, size: CGSize, singleClick: Bool = false) -> Int? {
        guard onCancelOrder != nil, let v = viewport(size: size),
              point.y >= v.plot.minY, point.y <= v.plot.maxY else { return nil }
        let closest = placedLines
            .compactMap { line in
                line.orderId.flatMap { id in
                    line.price > v.lo && line.price < v.hi ? (id, abs(v.y(line.price) - point.y), line.cancelsOnClick) : nil
                }
            }
            .filter { $0.1 <= 8 }
            .min { $0.1 < $1.1 }
        guard let closest, !singleClick || closest.2 else { return nil }
        return closest.0
    }

    /// The price under a point in the price area, or nil outside it.
    private func price(at point: CGPoint, size: CGSize) -> Double? {
        guard let v = viewport(size: size), v.priceRect.contains(point) else { return nil }
        return v.price(at: point.y)
    }

    private func draw(in ctx: inout ChartPainter, size: CGSize) {
        let bars = chart.bars
        OlderBars.check(chart, broker: broker)
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
            for i in start..<end {
                let b = bars[i]
                let h = CGFloat(b.volume / maxVolume) * volumeHeight
                let rect = CGRect(x: x(i) - barWidth * 0.35, y: plot.maxY - h, width: max(1, barWidth * 0.7), height: h)
                if b.close >= b.open { upVol.addRect(rect) } else { downVol.addRect(rect) }
            }
            plotCtx.fill(upVol, with: .color(up.opacity(volumeOpacity)))
            plotCtx.fill(downVol, with: .color(down.opacity(volumeOpacity)))
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
        if showTrades || !shownFillIds.isEmpty {
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
        func draw(_ line: PriceLine) {
            let lineY = y(line.price)
            let covered = line.movesAsideForLastPrice && last.map { abs(y($0) - lineY) < tagHeight } == true
            drawLine(in: &ctx, y: lineY, plot: plot, color: line.color, dashed: line.dashed, dotted: line.dotted,
                     tag: line.label.isEmpty ? Fmt.price(line.price, for: chart.symbol) : "\(line.label) \(Fmt.price(line.price, for: chart.symbol))",
                     tagInside: covered || isOrder(line), chartTag: line.chartText, showsTag: line.showsTag,
                     lineStart: isOrder(line) ? orderLineStart : nil, progress: line.fillProgress, lineWidth: line.lineWidth)
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
            let modifierTint: Color? = optionHeld && onAltClick != nil ? altClickTint
                : commandHeld && onCommandClick != nil ? commandClickTint : nil
            let lineTint = tintsHoverLine ? modifierTint : nil
            ctx.stroke(cross, with: .color(lineTint ?? hoverColor.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: hoverDashed ? (hoverDots ? [1, 2] : [3, 3]) : []))
            if priceRect.contains(hover) {
                let hoverPrice = v.price(at: hover.y)
                // Holding ⌃ turns it red or green: a ⌃-click places a stop loss or take profit there.
                var tagColor = hoverColor
                if controlHeld, let color = controlClickColor?(hoverPrice) {
                    tagColor = color
                } else if let modifierTint {
                    tagColor = modifierTint
                }
                drawTag(in: &ctx, text: Fmt.price(hoverPrice, for: chart.symbol), y: hover.y, plot: plot, color: tagColor)
                if let pnl = hoverPnL?(hoverPrice) {
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
    private func time(atIndex index: Int, bars: [Bar], rest: RestOfDay?) -> Date? {
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
        let fills = broker.fills.values.filter { $0.symbol == chart.symbol && (showTrades || shownFillIds.contains($0.id)) }
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
        let text = broker.usdNok.map { Fmt.nok(pnl * $0, signed: true, groupedFrom: 0) } ?? Fmt.amount(pnl, signed: true)
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
        if let cached = Self.timeLabels[key] { return cached }
        if Self.timeLabels.count > 20_000 { Self.timeLabels.removeAll(keepingCapacity: true) }
        let label = (showsDay ? Self.dayFormatter : Self.timeFormatter).string(from: date)
        Self.timeLabels[key] = label
        return label
    }

    private static var timeLabels: [Int64: String] = [:]

    /// A zone's offset from GMT, looked up once per hour of time (it only changes on the hour, at DST).
    private static func offset(of zone: TimeZone, at time: Date, cache: inout [Int: Int]) -> Int {
        let hour = Int((time.timeIntervalSince1970 / 3600).rounded(.down))
        if let cached = cache[hour] { return cached }
        if cache.count > 50_000 { cache.removeAll(keepingCapacity: true) }
        let offset = zone.secondsFromGMT(for: time)
        cache[hour] = offset
        return offset
    }

    private static var localOffsets: [Int: Int] = [:]
    private static var newYorkOffsets: [Int: Int] = [:]

    /// The local calendar day a time falls in, as a day count.
    private static func localDay(_ time: Date) -> Int {
        Int(((time.timeIntervalSince1970 + Double(offset(of: .current, at: time, cache: &localOffsets))) / 86_400).rounded(.down))
    }

    private static let newYork = TimeZone(identifier: "America/New_York")!

    /// The forex trading day a time falls in, counted in days: each starts at 17:00 New York.
    private static func forexDay(_ time: Date) -> Int {
        let local = time.timeIntervalSince1970 + Double(offset(of: newYork, at: time, cache: &newYorkOffsets))
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

// MARK: - Trackpad / scroll-wheel input

/// SwiftUI on macOS has no scroll-wheel or precise trackpad scroll gesture, so this background
/// view watches the app's scroll and magnify events and forwards the ones over its own frame.
/// ⌃ + scroll scales the price axis instead of zooming in time; ⌘, ⌥ or ⇧ (or several) + a swipe moves the
/// grid's zoom (on a trackpad, the other way round with Settings › Appearance › Swiping on, see `Swiping`).
/// It also reports every left click, takes ⌥-clicks (before SwiftUI's tap and drag gestures see them)
/// and ⌥ key changes.
private struct ScrollCatcher: NSViewRepresentable {
    /// (dx, dy, location, solo): dx in points (positive = content moves right), dy in points
    /// (positive = zoom out), location in view coordinates with a top-left origin; solo: a swipe begun with ⇧, ⌘
    /// or ⌥ held under Settings › Appearance › Swiping on, so it moves this chart alone (see `ViewSync`).
    var onScroll: (CGFloat, CGFloat, CGPoint, Bool) -> Void
    /// ⌃ + scroll, in points (positive = squeeze the prices, like zooming out).
    var onPriceScale: (CGFloat) -> Void
    /// ⌘, ⌥ or ⇧ + a trackpad swipe (⌘ or ⌥ + a mouse wheel), either way, in points (positive = zoom out); nil: it
    /// pans and zooms as usual.
    var onShiftScroll: ((CGFloat) -> Void)?
    /// ⌃⇧ + scroll: whole bars of space to add between the latest candle and the price axis (below 0 takes some
    /// off), as the Space slider (see `RightSpace`).
    var onRightSpace: (Double) -> Void
    var onMagnify: (CGFloat, CGPoint) -> Void
    var onClick: () -> Void
    /// ⌥- or ⌃-click location and which of the two; return true to consume the click.
    var onModifiedClick: ((CGPoint, NSEvent.ModifierFlags) -> Bool)?
    var onModifierKeys: (NSEvent.ModifierFlags) -> Void
    var onRightClick: () -> Void
    /// A plain triple-click's location.
    var onTripleClick: ((CGPoint) -> Void)? = nil

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.onScroll = onScroll
        view.onPriceScale = onPriceScale
        view.onShiftScroll = onShiftScroll
        view.onRightSpace = onRightSpace
        view.onMagnify = onMagnify
        view.onClick = onClick
        view.onModifiedClick = onModifiedClick
        view.onModifierKeys = onModifierKeys
        view.onRightClick = onRightClick
        view.onTripleClick = onTripleClick
    }

    static func dismantleNSView(_ view: CatcherView, coordinator: ()) {
        view.removeMonitor()
    }

    final class CatcherView: NSView {
        var onScroll: ((CGFloat, CGFloat, CGPoint, Bool) -> Void)?
        var onPriceScale: ((CGFloat) -> Void)?
        var onShiftScroll: ((CGFloat) -> Void)?
        var onRightSpace: ((Double) -> Void)?
        /// The ⌃⇧ scroll not yet a whole bar of space.
        private var rightSpaceRest: CGFloat = 0
        /// Points of ⌃⇧ scroll per bar of space: a mouse wheel's notch (12) is one.
        private static let pointsPerSpaceBar: CGFloat = 10
        var onMagnify: ((CGFloat, CGPoint) -> Void)?
        var onClick: (() -> Void)?
        /// What the scroll going on does: ⌃⇧ (without ⌘ or ⌥) the space right of the latest candle, as the Space
        /// slider; ⌃ (with or without others) the price axis; ⌘, ⌥ or ⇧ (a trackpad's),
        /// alone or together, the grid's zoom; else
        /// pan and zoom this chart. It follows the keys mid-swipe and keeps it through its momentum (see `handleScroll`).
        enum Gesture { case chart, gridZoom, priceScale, rightSpace }
        private var gesture = Gesture.chart
        /// The chart gesture going on was begun (or taken over) with ⇧, ⌘ or ⌥ on a trackpad: Swiping on, this chart only.
        private var solo = false
        /// Settings › Appearance › Pan locks once swiped sideways: this swipe went sideways, so it only pans until
        /// the fingers lift (and through its momentum).
        private var panLocked = false

        // Scrolls, swipes and pinches not yet applied. A trackpad or mouse reports about 100 times a second, so
        // applied as they come, the charts would move only that often; instead each is spread over the screen's
        // refreshes (up to 240 a second), a share every frame until it's all applied (see `tick`): the same
        // movement in all, done within about 10 ms, with a frame drawn at every refresh.
        private var pendingPan: CGFloat = 0
        private var pendingZoom: CGFloat = 0
        private var pendingLocation = CGPoint.zero
        private var pendingSolo = false
        private var pendingGrid: CGFloat = 0
        private var pendingPrice: CGFloat = 0
        /// The pinch's zoom factor not yet applied, as its logarithm.
        private var pendingPinch: Double = 0
        private var pinchLocation = CGPoint.zero
        private var link: CADisplayLink?
        /// How quickly what's pending is applied: about two-thirds within this many seconds.
        private static let smoothing: Double = 0.005

        private func queueScroll(_ dx: CGFloat, _ dy: CGFloat, at location: CGPoint, solo: Bool) {
            if solo != pendingSolo, pendingPan != 0 || pendingZoom != 0 { onScroll?(pendingPan, pendingZoom, pendingLocation, pendingSolo); pendingPan = 0; pendingZoom = 0 }
            pendingPan += dx
            pendingZoom += dy
            pendingLocation = location
            pendingSolo = solo
            startTicking()
        }

        private func queueGrid(_ d: CGFloat) { pendingGrid += d; startTicking() }
        private func queuePrice(_ d: CGFloat) { pendingPrice += d; startTicking() }

        private func queuePinch(_ magnification: CGFloat, at location: CGPoint) {
            // The chart zooms by 1 / (1 + magnification); kept as a logarithm, so the shares multiply back up to it.
            pendingPinch += -log1p(Double(max(-0.9, magnification)))
            pinchLocation = location
            startTicking()
        }

        private func startTicking() {
            if link == nil {
                let made = displayLink(target: self, selector: #selector(tick(_:)))
                made.add(to: .main, forMode: .common)
                link = made
            }
            link?.isPaused = false
        }

        private func stopTicking() {
            link?.invalidate()
            link = nil
        }

        @objc private func tick(_ link: CADisplayLink) {
            let frame = max(0.001, link.targetTimestamp - link.timestamp)
            let share = CGFloat(1 - exp(-frame / Self.smoothing))
            func take(_ pending: inout CGFloat, below: CGFloat) -> CGFloat {
                let part = abs(pending) < below ? pending : pending * share
                pending -= part
                return part
            }
            if pendingPan != 0 || pendingZoom != 0 {
                let dx = take(&pendingPan, below: 0.5), dy = take(&pendingZoom, below: 0.5)
                onScroll?(dx, dy, pendingLocation, pendingSolo)
            }
            if pendingGrid != 0 { onShiftScroll?(take(&pendingGrid, below: 0.5)) }
            if pendingPrice != 0 { onPriceScale?(take(&pendingPrice, below: 0.5)) }
            if pendingPinch != 0 {
                let part = abs(pendingPinch) < 0.002 ? pendingPinch : pendingPinch * Double(share)
                pendingPinch -= part
                onMagnify?(CGFloat(exp(-part) - 1), pinchLocation)
            }
            if pendingPan == 0, pendingZoom == 0, pendingGrid == 0, pendingPrice == 0, pendingPinch == 0 {
                link.isPaused = true
            }
        }

        static func gesture(for flags: NSEvent.ModifierFlags, precise: Bool) -> Gesture {
            let command = flags.contains(.command), option = flags.contains(.option)
            let control = flags.contains(.control), shift = flags.contains(.shift)
            if control, shift, !command, !option { return .rightSpace }
            if control { return .priceScale }
            // A mouse's shift-wheel alone pans (it arrives sideways).
            let zoomKeys = command || option || (shift && precise)
            // Settings › Appearance › Swiping on: a trackpad swipe zooms the grid, with the keys this chart.
            if precise && Swiping.zoomsAll { return zoomKeys ? .chart : .gridZoom }
            return zoomKeys ? .gridZoom : .chart
        }
        var onModifiedClick: ((CGPoint, NSEvent.ModifierFlags) -> Bool)?
        var onModifierKeys: ((NSEvent.ModifierFlags) -> Void)?
        var onRightClick: (() -> Void)?
        var onTripleClick: ((CGPoint) -> Void)?
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
                if event.type == .scrollWheel || event.type == .magnify { FrameMeter.shared.input() }
                switch event.type {
                case .magnify:
                    self.queuePinch(event.magnification, at: location)
                case .rightMouseDown:
                    self.onRightClick?()
                case .leftMouseDown:
                    self.onClick?()
                    let flags = event.modifierFlags.intersection([.option, .command, .control, .shift])
                    if event.clickCount == 3, flags.isEmpty { self.onTripleClick?(location) }
                    guard flags == .option || flags == .control || flags == [.command, .shift], let onModifiedClick = self.onModifiedClick,
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
            stopTicking()
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
            if event.hasPreciseScrollingDeltas, Swiping.locksPan {
                if event.phase.contains(.began) || event.phase.contains(.mayBegin) { panLocked = false }
                if !panLocked, event.momentumPhase.isEmpty, abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
                    panLocked = true
                }
            } else {
                panLocked = false
            }
            // What the gesture does follows the keys held while the fingers are on the trackpad: pressing or
            // letting go of one mid-swipe switches it at once (⌃ let go, back to plain swiping). Its momentum
            // keeps doing what it did as the fingers lifted, keys let go or not.
            let keys = Self.gesture(for: event.modifierFlags, precise: event.hasPreciseScrollingDeltas)
            if !event.hasPreciseScrollingDeltas || event.momentumPhase.isEmpty {
                if keys != gesture { rightSpaceRest = 0 }
                gesture = keys
                solo = keys == .chart && event.hasPreciseScrollingDeltas
                    && !event.modifierFlags.intersection([.option, .command, .shift]).isEmpty
            }
            // Whichever way it goes most (the system may turn a ⇧-swipe sideways).
            let d = abs(dy) >= abs(dx) ? dy : dx
            switch gesture {
            case .rightSpace:
                // Up or right adds space, as the slider going right; whole bars at a time.
                rightSpaceRest += d
                let bars = (rightSpaceRest / Self.pointsPerSpaceBar).rounded(.towardZero)
                if bars != 0 {
                    rightSpaceRest -= bars * Self.pointsPerSpaceBar
                    onRightSpace?(Double(bars))
                }
            case .priceScale:
                // A ⌃-swipe on the trackpad scales the opposite way to the ⌃-wheel.
                if d != 0 { queuePrice(event.hasPreciseScrollingDeltas ? -d : d) }
            case .gridZoom where onShiftScroll != nil:
                // Locked to panning (Swipe zooms every chart on): the chart under the pointer pans, nothing zooms.
                if panLocked { queueScroll(event.scrollingDeltaX, 0, at: location, solo: false) } else if d != 0 { queueGrid(d) }
            case .gridZoom, .chart:
                // Locked to panning: every bit sideways pans, none zooms.
                if panLocked { queueScroll(event.scrollingDeltaX, 0, at: location, solo: solo) } else { queueScroll(dx, dy, at: location, solo: solo) }
            }
        }
    }
}
