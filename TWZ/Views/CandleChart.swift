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
    /// With `drawnAcross`, on intraday charts only from where today starts (the line where the previous day ends)
    /// to the axis (a trend line).
    var fromDayStart = false
    /// With `fromDayStart`: from the start of this time's day instead of today's (when a trend line was placed).
    var since: Date?
    /// Off the prices on screen: drawn at the top or bottom edge, thicker, instead of not at all (a trend line).
    var pinsToEdge = false
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

/// No trade today (a US market holiday, or before the first one): the price is yesterday's close. A view of its own, so
/// the chart's view isn't rebuilt on every price tick (only this reads the quote).
private struct YesterdayCloseBadge: View {
    @Environment(Broker.self) private var broker
    let symbol: String

    var body: some View {
        if broker.quote(symbol)?.lastIsClose == true {
            Text("Yesterday's close · no trades today")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.black)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(Color.orange))
                .allowsHitTesting(false)
        }
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
    private var lastPrice: Double? { broker.liveQuote(chart.symbol)?.last }
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

    private var axisWidth: CGFloat { ChartFrame.axisWidth(fontSize: axisFontSize) }
    private var timeAxisHeight: CGFloat { ChartFrame.timeAxisHeight }

    var body: some View {
        GeometryReader { geo in
            let plotWidth = max(1, geo.size.width - axisWidth)
            // Read here, so a change in them redraws the chart; the rest it draws from (the chart's zoom and place,
            // bars, prices) redraws it on its own, without SwiftUI (see `ChartCanvas`).
            let _ = (hover, optionHeld, controlHeld, commandHeld)
            Color.clear
            .background(ChartCanvas { size in frame(size: size) })
            .overlay(alignment: .topTrailing) {
                YesterdayCloseBadge(symbol: chart.symbol)
                    .padding(.top, 4).padding(.trailing, axisWidth + 4)
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                if case .active(let p) = phase {
                    hover = p
                    if workspace.hoveredChartID != chart.id { workspace.hoveredChartID = chart.id }
                    onHover?()
                    optionHeld = NSEvent.modifierFlags.contains(.option)
                    controlHeld = NSEvent.modifierFlags.contains(.control)
                    commandHeld = NSEvent.modifierFlags.isSuperset(of: [.command, .shift])
                } else {
                    hover = nil
                    if workspace.hoveredChartID == chart.id { workspace.hoveredChartID = nil }
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
    nonisolated struct RestOfDay {
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


    // MARK: Frame

    /// What the chart's drawn from, copied for its renderer (see `ChartFrame`): read here on the main thread, so a
    /// change in any of it draws the chart again.
    private func baseFrame() -> ChartFrame {
        let settings = ChartSettings.shared.values
        let rest = restOfDay
        let fills = settings.showTrades || !shownFillIds.isEmpty
            ? broker.fills.values.filter { $0.symbol == chart.symbol && (settings.showTrades || shownFillIds.contains($0.id)) }
            : []
        return ChartFrame(
            chart: .init(bars: chart.bars, symbol: chart.symbol, timeframe: chart.timeframe, visibleBars: chart.visibleBars,
                         scrollBack: chart.scrollBack, priceShift: chart.priceShift, priceScale: chart.priceScale,
                         isLoading: chart.isLoading, error: chart.error),
            restOfDay: rest, rightPadding: rightPadding(rest), lastPrice: lastPrice, settings: settings,
            sideColors: sideColors, lines: lines, pointers: pointers, fills: fills,
            usdNok: hover != nil && hoverPnL != nil ? broker.usdNok : nil,
            hover: hover, optionHeld: optionHeld, controlHeld: controlHeld, commandHeld: commandHeld,
            altClickTint: onAltClick != nil ? altClickTint : nil, commandClickTint: onCommandClick != nil ? commandClickTint : nil,
            tintsHoverLine: tintsHoverLine)
    }

    /// The frame to draw at `size`, with what the hovered price would do worked out here (see `ChartFrame`).
    private func frame(size: CGSize) -> ChartFrame {
        OlderBars.check(chart, broker: broker)
        var frame = baseFrame()
        if let hover, let v = frame.viewport(size: size), v.priceRect.contains(hover) {
            let price = v.price(at: hover.y)
            if controlHeld { frame.hoverControlColor = controlClickColor?(price) }
            frame.hoverPnL = hoverPnL?(price)
        }
        return frame
    }

    // MARK: Hit testing

    /// The order line closest to `point` vertically, if one is within a few points of it; for a
    /// `singleClick`, only if that closest line cancels on a single click.
    private func orderLine(near point: CGPoint, size: CGSize, singleClick: Bool = false) -> Int? {
        let frame = baseFrame()
        guard onCancelOrder != nil, let v = frame.viewport(size: size),
              point.y >= v.plot.minY, point.y <= v.plot.maxY else { return nil }
        let closest = frame.placedLines
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
        guard let v = baseFrame().viewport(size: size), v.priceRect.contains(point) else { return nil }
        return v.price(at: point.y)
    }

    private func plotRect(size: CGSize) -> CGRect {
        CGRect(x: 0, y: 4, width: size.width - axisWidth, height: size.height - timeAxisHeight - 4)
    }

    /// See `ChartFrame.barIndex`.
    static func barIndex(of time: Date, in bars: [Bar], barSeconds: Double?) -> Int? {
        ChartFrame.barIndex(of: time, in: bars, barSeconds: barSeconds)
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
        private var ticking = false
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

        /// Applied at each refresh by the window's render loop, right before it draws the charts (see
        /// `ChartRenderLoop.addFrameHandler`), so each step is on screen at the next refresh.
        private func startTicking() {
            guard !ticking, let window else { return }
            ticking = true
            ChartRenderLoop.of(window).addFrameHandler(self) { [weak self] frame in
                guard let self else { return false }
                self.tick(frame: frame)
                if !self.hasPending { self.ticking = false }
                return self.ticking
            }
        }

        private func stopTicking() {
            ticking = false
        }

        private var hasPending: Bool {
            pendingPan != 0 || pendingZoom != 0 || pendingGrid != 0 || pendingPrice != 0 || pendingPinch != 0
        }

        private func tick(frame: CFTimeInterval) {
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
            // Settings' Reverse swiping: a trackpad swipe moves everything the other way.
            let sign: CGFloat = event.hasPreciseScrollingDeltas && Swiping.reversed ? -1 : 1
            dx *= sign
            dy *= sign
            let sidewaysX = event.scrollingDeltaX * sign
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
                if panLocked { queueScroll(sidewaysX, 0, at: location, solo: false) } else if d != 0 { queueGrid(d) }
            case .gridZoom, .chart:
                // Locked to panning: every bit sideways pans, none zooms.
                if panLocked { queueScroll(sidewaysX, 0, at: location, solo: solo) } else { queueScroll(dx, dy, at: location, solo: solo) }
            }
        }
    }
}
