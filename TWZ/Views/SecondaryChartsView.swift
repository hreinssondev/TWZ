//
//  SecondaryChartsView.swift
//  TWZ
//
//  A grid of charts that follow a list, the top gainers unless picked otherwise (their own scanner, 50 rows; the
//  header's menu, or ⌘⇧ and a list's letter with this window in front, as in the main window, switches it
//  here only), laid out in rank order:
//  6×3 for the top 18, or a custom grid set by the Cols / Rows sliders (the "All Charts" / "Top N"
//  title toggles them). A slider change applies once the sliders have been left alone for a moment.
//  Each view also has its own Zoom slider: its charts' default zoom, applied as it moves; a ⇧-, ⌘- or ⌥-swipe
//  on a chart moves it too, as in the main window (⌃-swipe: the price axis).
//  A symbol keeps its chart while it stays in the top N (a reshuffle only moves the charts); only
//  charts whose symbol dropped out load a new one.
//  A symbol typed into a chart's field stays in that chart and cell, the stock it replaced leaving
//  the charts meanwhile (so nothing else moves) and the gainers filling the other cells around it, until the top bar's Reset, the field emptied, or a smaller grid without that cell.
//  ⌘R (or another of the main window's Reset keys) with this window in front resets it alone, on its list: every
//  chart's view back to the Zoom slider's, those set by hand keeping their stock; the Reset button beside the
//  timeframe picker lets those go too.
//  Clicking a chart selects it, as in the main window: hotkeys, order keys and the other trading shortcuts go to
//  its stock, it streams tick by tick (⌘↩ keeps it fast), and its header shows the position, ⚡, S, SSR, buying
//  power and its own timeframe switch. ⌥1–6 (⌃ too) with this window in front sets every chart's timeframe here, and ⇧1–5 (or a click on the header's layout numbers) loads one of its own saved chart layouts (see `GridLayout`).
//  The header's 1–5 before them are this window's own view sets or scales, as the main window's top bar has (see
//  `ScaleButtons`; ⌥⇧1–5 with this window in front). On the Forex list, 1/2 after them shows the pairs past those
//  the grid has room for (2/2), and back, and 5D orders the pairs by their range over the last 5 finished days. With P on, or the
//  window closed, the scanner stops and every chart is emptied: no history, bar updates or quotes.
//  Hidden by its shortcut (see `ChartsWindowShortcut`), the window isn't closed: the charts stay live.
//  There are two of these windows, Charts and Charts 2 (the Window menu, or each one's own shortcut), each with all of
//  the above of its own (see `ChartsWin`, `ChartsWindowState`); Charts 2 is laid out for a portrait screen.
//

import SwiftUI

enum SecondaryCharts {
    static let maxColumns = 8
    static let maxRows = 4
    static let count = maxColumns * maxRows
    static let timeframeKey = "secondaryChartsTimeframe"
    static let pausedKey = "secondaryChartsPaused"
    static let layoutKey = "secondaryChartsLayout"
    static let columnsKey = "secondaryChartsColumns"
    static let rowsKey = "secondaryChartsRows"
    static let allZoomKey = "secondaryChartsAllZoom"
    static let customZoomKey = "secondaryChartsCustomZoom"
    static let scannerOwner = "secondary-charts"
    static let listKey = "secondaryChartsList"
    static let windowID = "secondary-charts"
    static let windowTitle = "Charts"
    /// The scanner gainer charts follow, here and in the main window's grid: enough rows for 8×4.
    static let gainersScan = ScanSpec(kind: .gainers, filter: ScannerFilter(minPrice: 0.1), rows: ScannerKind.maxRowCount)

    /// The Charts window's scan of `kind`: as many rows as the gainers'.
    static func scan(_ kind: ScannerKind) -> ScanSpec {
        kind == .gainers ? gainersScan : ScanSpec(kind: kind, filter: kind.defaultFilter, rows: ScannerKind.maxRowCount)
    }

    /// Either Charts window.
    static func isWindow(_ window: NSWindow?) -> Bool { ChartsWin.of(window) != nil }

    enum Layout: String {
        case all, custom
    }
}

/// Which Charts window: there are two, each with its own charts, list, grid, Zoom slider, numbers, layouts and
/// shortcut. The first keeps the settings it always had; the second's are the same keys with "2" on the end, and
/// it's laid out for a portrait screen (All Charts 3×6, Cols / Rows up to 4 × 8).
enum ChartsWin: Int, CaseIterable, Codable, Hashable {
    case first = 1, second = 2

    /// Its charts' ids: 100… in the first, 200… in the second (see `ChartModel.windowIndex`).
    var firstChartID: Int { rawValue * 100 }
    /// A stored setting's key for this window.
    func key(_ base: String) -> String { self == .first ? base : base + "2" }
    var scannerOwner: String { key(SecondaryCharts.scannerOwner) }
    var windowID: String { self == .first ? SecondaryCharts.windowID : "charts-window-2" }
    var title: String { self == .first ? SecondaryCharts.windowTitle : "Charts 2" }
    /// In messages: "Charts window", "Charts window 2".
    var name: String { self == .first ? "Charts window" : "Charts window 2" }
    var layoutWindow: GridLayout.Window { self == .first ? .chartsWindow : .chartsWindow2 }
    /// All Charts' grid, and the Cols / Rows sliders' most (as many charts either way, `SecondaryCharts.count`).
    var allColumns: Int { self == .first ? 6 : 3 }
    var allRows: Int { self == .first ? 3 : 6 }
    var maxColumns: Int { self == .first ? SecondaryCharts.maxColumns : SecondaryCharts.maxRows }
    var maxRows: Int { self == .first ? SecondaryCharts.maxRows : SecondaryCharts.maxColumns }
    var defaultColumns: Int { self == .first ? 5 : 2 }
    var defaultRows: Int { self == .first ? 2 : 4 }
    var allLabel: String { "All Charts (\(allColumns)×\(allRows))" }

    static func of(chartID: Int) -> ChartsWin? { ChartsWin(rawValue: chartID / 100) }
    static func of(_ window: NSWindow?) -> ChartsWin? {
        guard let window else { return nil }
        let id = window.identifier?.rawValue ?? ""
        return allCases.first { id.hasPrefix($0.windowID) || window.title == $0.title }
    }
}

/// One Charts window's own state (see `ChartsWin`), saved where it says so.
@Observable
final class ChartsWindowState {
    let win: ChartsWin
    /// One chart for each cell of its largest grid, empty until the window's open and not paused.
    let charts: [ChartModel]
    /// Charts given a stock by hand (their symbol field), by chart id, with the cell each keeps: the gainers fill
    /// the other cells around them, until the Reset button, an emptied field, or a smaller grid without that cell.
    var pins: [Int: Int] = [:]
    /// The stock a chart set by hand showed while following the list, which leaves the charts meanwhile.
    var displaced: [Int: String] = [:]
    /// Counts its Resets (⌘R there, see `Workspace.resetChartsWindow`).
    var resets = 0
    /// Its own numbers (its header, see `ScaleButtons`): its view sets and scales by number, and the one lit. Saved.
    var viewSets: [Int: ViewSet] {
        didSet { defaults.set(try? JSONEncoder().encode(viewSets), forKey: win.key("chartsWindowViewSets")) }
    }
    var activeViewSet: Int? {
        didSet { defaults.set(activeViewSet, forKey: win.key("chartsWindowActiveViewSet")) }
    }
    var scales: [Int: ChartScale] {
        didSet { defaults.set(try? JSONEncoder().encode(scales), forKey: win.key("chartsWindowScales")) }
    }
    /// While lit, every chart here loading another stock takes it too (see `Broker.chartsWindowScales`).
    var activeScale: Int? {
        didSet { defaults.set(activeScale, forKey: win.key("chartsWindowActiveScale")) }
    }
    /// The zoom a swipe has just put its charts at (see `Workspace.zoomChartsWindow`), so its Zoom slider following
    /// it doesn't zoom them again.
    @ObservationIgnored var swipedZoom: Double?
    /// The list its charts follow (⌘⇧ and a list's letter there, or its header's menu). Saved.
    var list: ScannerKind {
        didSet { defaults.set(list.rawValue, forKey: win.key(SecondaryCharts.listKey)) }
    }
    /// System-wide shortcut that shows and hides it (see `ChartsWindowShortcut`). Saved.
    var shortcut: KeyShortcut? {
        didSet { defaults.set(shortcut.flatMap { try? JSONEncoder().encode($0) }, forKey: win.key("chartsWindowShortcut")) }
    }
    @ObservationIgnored private let defaults = UserDefaults.standard

    init(_ win: ChartsWin) {
        self.win = win
        let d = UserDefaults.standard
        let timeframe = d.string(forKey: win.key(SecondaryCharts.timeframeKey)).flatMap(Timeframe.init(rawValue:)) ?? .m1
        charts = (0..<SecondaryCharts.count).map { ChartModel(id: win.firstChartID + $0, symbol: "", timeframe: timeframe) }
        let viewSets = d.data(forKey: win.key("chartsWindowViewSets"))
            .flatMap { try? JSONDecoder().decode([Int: ViewSet].self, from: $0) } ?? [:]
        self.viewSets = viewSets
        activeViewSet = (d.object(forKey: win.key("chartsWindowActiveViewSet")) as? Int).flatMap { viewSets[$0] != nil ? $0 : nil }
        let scales = d.data(forKey: win.key("chartsWindowScales"))
            .flatMap { try? JSONDecoder().decode([Int: ChartScale].self, from: $0) } ?? [:]
        self.scales = scales
        activeScale = (d.object(forKey: win.key("chartsWindowActiveScale")) as? Int).flatMap { scales[$0] != nil ? $0 : nil }
        list = d.string(forKey: win.key(SecondaryCharts.listKey)).flatMap(ScannerKind.init(rawValue:)) ?? .gainers
        shortcut = d.data(forKey: win.key("chartsWindowShortcut")).flatMap { try? JSONDecoder().decode(KeyShortcut.self, from: $0) }
    }
}

/// Gainer charts: the Charts window's and the main window's.
extension Workspace {
    /// `charts` in gainer rank order, empty ones last. Only their place in a grid follows the ranking:
    /// a chart keeps its symbol and data, so a reshuffle reloads nothing.
    func ranked(_ charts: [ChartModel], by gainers: [String]) -> [ChartModel] {
        let rank = Dictionary(gainers.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return charts.enumerated().sorted { a, b in
            let ra = rank[a.element.symbol] ?? .max, rb = rank[b.element.symbol] ?? .max
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element)
    }

    /// Fills `charts` with the top `count` gainers; the other charts are emptied. A symbol still in
    /// the top `count` keeps its chart, so a reshuffle in the ranking reloads nothing (`ranked` moves
    /// them); new symbols take the charts that dropped out.
    func fill(_ charts: [ChartModel], withTop count: Int, of gainers: [String], broker: Broker) {
        var top: [String] = []
        for symbol in gainers where !symbol.isEmpty && !top.contains(symbol) {
            guard top.count < min(count, charts.count) else { break }
            top.append(symbol)
        }
        let shown = Set(charts.map(\.symbol))
        var incoming = top.filter { !shown.contains($0) }[...]
        for chart in charts where !top.contains(chart.symbol) {
            if let symbol = incoming.popFirst() {
                load(symbol, into: chart, broker: broker)
            } else {
                clear(chart, broker: broker)
            }
        }
    }

    /// ⇧-, ⌘- or ⌥-swipe on Charts window chart `chart`: every chart there zooms by `factor` from the zoom on
    /// screen, as `zoomGrid` does for the main charts. The new zoom, for the window's Zoom slider.
    func zoomChartsWindow(by factor: Double, from chart: ChartModel, sliderZoom: Double, broker: Broker) -> Double {
        guard let win = ChartsWin.of(chartID: chart.id) else { return sliderZoom }
        let window = chartsWindow(win)
        let shown = window.charts.filter { !$0.symbol.isEmpty }
        let base = !GridZoom.resetsAdjusted && chart.adjustedByHand
            ? shown.first { !$0.adjustedByHand }?.visibleBars ?? sliderZoom
            : chart.visibleBars
        guard base > 0 else { return sliderZoom }
        let most = shown.map { Double($0.bars.count) }.max() ?? 0
        let zoom = min(max(ChartModel.maxVisibleBars, most, base), max(15, base * factor))
        setZoom(zoom, of: window.charts, broker: broker, by: zoom / base)
        if zoom != sliderZoom { window.swipedZoom = zoom }
        return zoom
    }

    // MARK: - The Charts window's numbers (see `ScaleButtons`)

    /// Tells the broker each Charts window's lit scale, which its charts loading a stock take (scales only as scales).
    func syncChartsWindowScale(to broker: Broker) {
        for window in chartsWindows {
            broker.chartsWindowScales[window.win] = NumberButtons.areScales ? window.activeScale.flatMap { window.scales[$0] } : nil
        }
    }

    /// ⇧-click on a Charts window number, as view sets: every chart's zoom and place there on every timeframe, saved.
    func saveChartsWindowViewSet(_ slot: Int, in win: ChartsWin, broker: Broker) {
        let window = chartsWindow(win)
        broker.keepChartViews(of: window.charts)
        window.viewSets[slot] = ViewSet(views: broker.chartsWindowViews(win),
                                        zooms: Dictionary(uniqueKeysWithValues: window.charts.map { ($0.id, $0.zooms) }))
        window.activeViewSet = slot
        broker.say("\(win.name) view set \(slot) saved: every chart's zoom and place there on every timeframe")
    }

    /// A click on a Charts window number, as view sets: every chart there back to it; lit, it goes off.
    func pickChartsWindowViewSet(_ slot: Int, in win: ChartsWin, broker: Broker) {
        let window = chartsWindow(win)
        if window.activeViewSet == slot {
            window.activeViewSet = nil
            return broker.say("\(win.name) view set \(slot) off: charts keep their views as they are")
        }
        guard let set = window.viewSets[slot] else {
            NSSound.beep()
            return broker.say("Nothing saved as \(win.name) view set \(slot) yet: ⇧-click its number to save every chart's zoom and place there")
        }
        broker.replaceChartsWindowViews(win, with: set.views)
        for chart in window.charts {
            chart.zooms = set.zooms[chart.id] ?? [:]
            broker.restoreView(of: chart)
        }
        window.activeViewSet = slot
        broker.say("\(win.name) view set \(slot): every chart's zoom and place there as saved")
    }

    /// ⇧-click on a Charts window number, as scales: the selected chart's view, if it's one of that window's; false otherwise.
    func saveChartsWindowScale(_ slot: Int, in win: ChartsWin) -> Bool {
        guard isChartSelected, ChartsWin.of(chartID: selectedChartID) == win, let chart = chart(id: selectedChartID),
              !chart.symbol.isEmpty else { return false }
        let window = chartsWindow(win)
        window.scales[slot] = ChartScale(of: chart)
        window.activeScale = slot
        return true
    }

    /// A click on a Charts window number, as scales: every chart there takes it (those adjusted by hand too) and so do
    /// those loading a stock while it's lit; lit, it goes off.
    func pickChartsWindowScale(_ slot: Int, in win: ChartsWin, broker: Broker) {
        let window = chartsWindow(win)
        if window.activeScale == slot {
            window.activeScale = nil
            syncChartsWindowScale(to: broker)
            return broker.say("\(win.name) scale \(slot) off: charts keep their own views")
        }
        guard let scale = window.scales[slot] else {
            NSSound.beep()
            return broker.say("Nothing saved as \(win.name) scale \(slot) yet: ⇧-click its number to save the selected chart's view")
        }
        broker.forgetChartAdjustments(of: window.charts)
        for chart in window.charts where !chart.symbol.isEmpty { scale.apply(to: chart) }
        window.activeScale = slot
        syncChartsWindowScale(to: broker)
        broker.say("\(win.name) scale \(slot) on every chart there, also as its list changes (pick it again to turn it off)")
    }

    /// Sets the charts' default zoom and zooms them to it. The zooms they were left at on other stocks
    /// and timeframes stay (see `ChartViews`); Reset forgets those.
    /// From `oldZoom` (the grid's zoom moved: ⇧-swipe, the Zoom slider) with Settings' "⇧-swipe zooms
    /// charts adjusted by hand to the same zoom" off, charts adjusted by hand keep their own zoom and
    /// change it by as much (see `GridZoom`), or by `factor` when given (a swipe, see `zoomGrid`).
    func setZoom(_ zoom: Double, of charts: [ChartModel], broker: Broker, from oldZoom: Double? = nil, by factor: Double? = nil) {
        let relative = GridZoom.resetsAdjusted ? nil : factor ?? oldZoom.flatMap { old in old > 0 ? zoom / old : nil }
        // With Settings › Appearance › Zoom keeps the latest candle in place, each chart's latest candle stays put.
        let keepsLatest = ZoomAnchor.keepsLatest
        func show(_ visible: Double, on chart: ChartModel) {
            if keepsLatest, !chart.bars.isEmpty { chart.zoomKeepingLatestBar(to: visible) } else { chart.visibleBars = visible }
        }
        for chart in charts {
            if let relative, chart.adjustedByHand {
                chart.defaultVisibleBars = zoom
                show(min(max(ChartModel.maxVisibleBars, Double(chart.bars.count)), max(15, chart.visibleBars * relative)), on: chart)
                continue
            }
            if chart.defaultVisibleBars != zoom || chart.visibleBars != zoom {
                chart.defaultVisibleBars = zoom
                show(zoom, on: chart)
            }
        }
    }

    /// Puts the charts' view back to `zoom`, as double-clicking one does: latest bars at the right
    /// edge, price range fitted to the bars again. Given a `timeframe` (the top bar's Reset), only on it:
    /// charts on another one, and the views kept on others, stay as they are.
    func resetViews(of charts: [ChartModel], zoom: Double, broker: Broker, timeframe: Timeframe? = nil) {
        let charts = charts.filter { chart in timeframe.map { chart.timeframe == $0 } ?? true }
        setZoom(zoom, of: charts, broker: broker)
        broker.forgetChartViews(of: charts, timeframe: timeframe)
        for chart in charts {
            chart.adjustedByHand = false
            if let timeframe { chart.zooms[timeframe] = nil } else { chart.zooms = [:] }
        }
        for chart in charts where chart.scrollBack != 0 || chart.priceShift != 0 || chart.priceScale != 1 {
            chart.scrollBack = 0
            chart.priceShift = 0
            chart.priceScale = 1
        }
    }

    func setTimeframe(_ timeframe: Timeframe, of charts: [ChartModel], broker: Broker) {
        for chart in charts where chart.timeframe != timeframe {
            chart.timeframe = timeframe
            if !chart.symbol.isEmpty { broker.loadChart(chart) }
        }
    }
}

struct SecondaryChartsView: View {
    @Environment(Broker.self) private var broker
    @Environment(Workspace.self) private var workspace
    /// Which Charts window this is.
    let win: ChartsWin
    private var state: ChartsWindowState { workspace.chartsWindow(win) }

    private static let gap: CGFloat = 4

    @State private var lastGainers: [String] = []
    /// The Forex list's second page: the pairs past those the grid has room for, in its cells instead.
    @State private var showsRest = false
    /// The Forex list by each pair's range over its last 5 finished days, widest first (see `TradingEngine.setForexByRange`).
    @AppStorage private var forexByRange: Bool
    @AppStorage private var masterTimeframe: Timeframe
    @AppStorage private var headerHeight: Double
    @AppStorage private var isPaused: Bool
    @AppStorage private var layout: SecondaryCharts.Layout
    @AppStorage private var customColumns: Int
    @AppStorage private var customRows: Int
    /// Bars on screen at the default zoom, one for All Charts and one for the custom grid.
    @AppStorage private var allZoom: Double
    @AppStorage private var customZoom: Double
    @State private var columnSplits: SplitStore
    @State private var rowSplits: SplitStore

    init(win: ChartsWin) {
        self.win = win
        _forexByRange = AppStorage(wrappedValue: false, win.key("secondaryChartsForexByRange"))
        _masterTimeframe = AppStorage(wrappedValue: .m1, win.key(SecondaryCharts.timeframeKey))
        _headerHeight = AppStorage(wrappedValue: 28, win.key("secondaryHeaderHeight"))
        _isPaused = AppStorage(wrappedValue: false, win.key(SecondaryCharts.pausedKey))
        _layout = AppStorage(wrappedValue: win == .first ? .all : .custom, win.key(SecondaryCharts.layoutKey))
        _customColumns = AppStorage(wrappedValue: win.defaultColumns, win.key(SecondaryCharts.columnsKey))
        _customRows = AppStorage(wrappedValue: win.defaultRows, win.key(SecondaryCharts.rowsKey))
        _allZoom = AppStorage(wrappedValue: ChartModel.initialVisibleBars, win.key(SecondaryCharts.allZoomKey))
        _customZoom = AppStorage(wrappedValue: ChartModel.initialVisibleBars, win.key(SecondaryCharts.customZoomKey))
        _columnSplits = State(initialValue: SplitStore(key: win.layoutWindow.columnSplitsKey))
        _rowSplits = State(initialValue: SplitStore(key: win.layoutWindow.rowSplitsKey))
    }

    private var columns: Int { layout == .all ? win.allColumns : customColumns }
    private var rows: Int { layout == .all ? win.allRows : customRows }
    private var count: Int { columns * rows }
    @State private var dragStartHeight: Double?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if isPaused {
                Text("Paused")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let items = self.items
                SplitGrid(columns: columns, rows: rows, items: items,
                          gap: Self.gap, inset: Self.gap,
                          columnSplits: $columnSplits, rowSplits: $rowSplits) { chart in
                    SecondaryChartPane(win: win, chart: chart, cell: items.firstIndex { $0.id == chart.id })
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.35))
        .onAppear {
            applyZoom()
            workspace.syncChartsWindowScale(to: broker)
            if !isPaused { start() }
        }
        // On close only: hiding the window (ordering it out) keeps the charts live.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
            if ChartsWin.of(note.object as? NSWindow) == win { stop() }
        }
        // Fills the charts as soon as the scanner answers, e.g. right after P is turned off.
        .onChange(of: broker.scans[win.scannerOwner]?.symbols) {
            if !isPaused { syncWithGainers() }
        }
        .onChange(of: masterTimeframe) { _, new in
            workspace.setTimeframe(new, of: state.charts, broker: broker)
        }
        .onChange(of: isPaused) { _, paused in
            if paused { stop() } else { start() }
        }
        // Charts still in the new top N stay put; the rest are emptied (smaller grid) or filled (larger).
        // A chart set by hand whose cell is gone lets go of its stock.
        .onChange(of: count) {
            state.pins = state.pins.filter { $0.value < count }
            if !isPaused { lastGainers = []; syncWithGainers() }
        }
        // A chart set or let go by hand, or Reset: the gainers fill the cells around the ones set by hand.
        .onChange(of: state.pins) {
            if !isPaused { lastGainers = []; syncWithGainers() }
        }
        // Another list: the charts still in its top N stay, the rest load its stocks.
        .onChange(of: state.list) {
            if !isPaused { start() }
        }
        .onChange(of: state.resets) {
            workspace.syncChartsWindowScale(to: broker)
            workspace.resetViews(of: state.charts, zoom: layout == .all ? allZoom : customZoom, broker: broker)
        }
        .onChange(of: layout) { applyZoom() }
        // A chart layout loaded: its lines (see `GridLayout`).
        .onChange(of: workspace.gridLayoutLoads) {
            columnSplits = SplitStore(key: win.layoutWindow.columnSplitsKey)
            rowSplits = SplitStore(key: win.layoutWindow.rowSplitsKey)
        }
        .onChange(of: allZoom) { zoomMoved(to: $1) }
        .onChange(of: customZoom) { zoomMoved(to: $1) }
    }

    private var header: some View {
        HStack {
            Button {
                layout = layout == .all ? .custom : .all
            } label: {
                Text(layout == .all ? "All Charts" : "Top \(count)")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(layout == .all ? "Show the custom grid set by the sliders" : "Show the top \(win.allColumns * win.allRows), \(win.allColumns)×\(win.allRows)")
            Picker("", selection: Binding(get: { state.list }, set: { state.list = $0 })) {
                ForEach(ScannerKind.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            .help("The list these charts follow (the main window's stay on theirs). With this window in front: "
                  + ScannerKind.shortcutHelp.replacingOccurrences(of: "shows the list and loads it into the chart grid", with: "switches it"))
            GridSliders(columns: $customColumns, rows: $customRows, zoom: layout == .all ? $allZoom : $customZoom,
                        columnRange: 1...win.maxColumns, rowRange: 1...win.maxRows,
                        showsSize: layout == .custom)
            // Every chart's timeframe here, right of the sliders as in the main window's top bar.
            TimeframePicker(selection: Binding(
                get: { masterTimeframe },
                set: { masterTimeframe = $0 }
            ))
            .help("Every chart's timeframe here (with this window in front: ⌥1–6 or ⌃1–6); a chart's own switch changes just that chart")
            Button {
                workspace.resetChartsWindow(win, releasingHandSet: true)
            } label: {
                Text("Reset")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(Color.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.08)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Every chart here back to the Zoom slider's zoom, and the charts whose symbol you typed follow the list again. ⌘R does the first only, keeping those")
            // View sets / scales, then chart layouts, close together, as in the main window's top bar.
            HStack(spacing: 3) {
                ScaleButtons(window: win.layoutWindow)
                GridLayoutButtons(window: win.layoutWindow, showsIcon: false)
            }
            if state.list == .forex { forexButtons }
            // A failed scanner isn't retried, so the charts would sit on its last list without this.
            if !isPaused, let error = broker.scans[win.scannerOwner]?.error {
                Text(error).font(.system(size: 11)).foregroundStyle(.red).lineLimit(1).help(error)
            }
            Spacer()
            Button {
                isPaused.toggle()
            } label: {
                Text("P")
                    .font(.system(size: 10, weight: .regular).monospacedDigit())
                    .foregroundStyle(isPaused ? Color.primary : Color.secondary.opacity(0.7))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(isPaused ? 0.12 : 0)))
            }
            .buttonStyle(.plain)
            .help(isPaused ? "Turn the charts back on" : "Turn the charts off: no scanner, history or quotes until P is off again")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(height: headerHeight)
        // The height drag sits behind the controls so it never takes a slider's drag.
        .background(
            Color(nsColor: .textBackgroundColor).opacity(0.2)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            let start = dragStartHeight ?? headerHeight
                            dragStartHeight = start
                            headerHeight = max(24, min(start + value.translation.height, 100))
                        }
                        .onEnded { _ in dragStartHeight = nil }
                )
        )
    }

    /// Forex only: 1/2 flips between the pairs that fit the grid and the ones past them; 5D orders them by 5-day range.
    private var forexButtons: some View {
        HStack(spacing: 3) {
            forexButton(showsRest ? "2/2" : "1/2", lit: showsRest,
                        help: showsRest ? "Back to the first pairs of the Forex list" : "The Forex list's pairs past those the grid has room for") {
                showsRest.toggle()
                if !isPaused { lastGainers = []; syncWithGainers() }
            }
            forexButton("5D", lit: forexByRange,
                        help: forexByRange ? "Back to the Forex list's fixed order"
                            : "The pairs by their range over the last 5 finished days, (high − low) / low, widest first; set once a day, after 17:00 ET") {
                forexByRange.toggle()
                broker.setForexByRange(forexByRange, owner: win.scannerOwner)
            }
        }
    }

    private func forexButton(_ title: String, lit: Bool, help: String, action: @escaping () -> Void) -> some View {
        ForexListButton(title: title, lit: lit, help: help, action: action)
    }

    /// The Zoom slider moved, or a swipe moved it (that zoomed the charts already, see `zoomChartsWindow`).
    private func zoomMoved(to zoom: Double) {
        if state.swipedZoom == zoom {
            state.swipedZoom = nil
            return
        }
        applyZoom()
    }

    /// Sets every chart's default zoom for the current view and zooms them to it.
    private func applyZoom() {
        workspace.setZoom(layout == .all ? allZoom : customZoom, of: state.charts, broker: broker)
    }

    private func start() {
        lastGainers = []
        broker.setForexByRange(forexByRange, owner: win.scannerOwner)
        broker.setScanner(SecondaryCharts.scan(state.list), owner: win.scannerOwner)
        syncWithGainers()
    }

    /// Stops the scanner and empties every chart, cancelling their data.
    private func stop() {
        // A chart here was selected: the main window's last one is again.
        if ChartsWin.of(chartID: workspace.selectedChartID) == win {
            workspace.selectedChartID = workspace.lastMainChartID
            workspace.isChartSelected = false
        }
        broker.setScanner(nil, owner: win.scannerOwner)
        broker.setForexByRange(false, owner: win.scannerOwner)
        lastGainers = []
        state.pins = [:]
        state.displaced = [:]
        for chart in state.charts { workspace.clear(chart, broker: broker) }
    }

    /// Fills the charts not set by hand with the top gainers, as many as there are cells left around
    /// the ones set by hand; the other charts are emptied.
    private func syncWithGainers() {
        let pins = state.pins
        // Less the stocks the charts set by hand replaced.
        let displaced = Set(pins.keys.compactMap { state.displaced[$0] })
        var gainers = (broker.scans[win.scannerOwner]?.symbols ?? []).filter { !displaced.contains($0) }
        let slots = count - pins.values.filter { $0 < count }.count
        // The Forex list's second page: the pairs past the first `slots`, less those set by hand.
        if showsRest, state.list == .forex {
            let pinned = Set(state.charts.filter { pins[$0.id] != nil }.map(\.symbol))
            gainers = Array(gainers.filter { !pinned.contains($0) }.dropFirst(slots))
        }
        guard !gainers.isEmpty, gainers != lastGainers else { return }
        lastGainers = gainers
        workspace.fill(state.charts.filter { pins[$0.id] == nil },
                       withTop: slots, of: gainers, broker: broker)
    }

    /// The charts in grid order: one set by hand in its own cell, the others in gainer rank order around them.
    private var items: [ChartModel] {
        let pins = state.pins
        let pinned = Dictionary(pins.map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        var rest = workspace.ranked(state.charts.filter { pins[$0.id] == nil }, by: lastGainers)[...]
        return (0..<state.charts.count).compactMap { cell in
            if let id = pinned[cell], let chart = state.charts.first(where: { $0.id == id }) { return chart }
            return rest.popFirst()
        }
    }
}

/// A Charts window chart pane: clicking it selects it, as a main-window chart (see `ChartPane`).
/// ⌃-click, the what-if, its lines and hover P/L work as on the main charts.
struct SecondaryChartPane: View {
    @Environment(Broker.self) private var broker
    @Environment(\.sideColors) private var sideColors
    @Environment(Workspace.self) private var workspace
    let win: ChartsWin
    let chart: ChartModel
    /// Its place in the grid, which a symbol typed into it keeps.
    var cell: Int?

    @AppStorage private var layout: SecondaryCharts.Layout
    @AppStorage(HeaderPerformance.freezeKey) private var freezesHeaders = HeaderPerformance.defaultOn
    @AppStorage private var allZoom: Double
    @AppStorage private var customZoom: Double

    init(win: ChartsWin, chart: ChartModel, cell: Int?) {
        self.win = win
        self.chart = chart
        self.cell = cell
        _layout = AppStorage(wrappedValue: win == .first ? .all : .custom, win.key(SecondaryCharts.layoutKey))
        _allZoom = AppStorage(wrappedValue: ChartModel.initialVisibleBars, win.key(SecondaryCharts.allZoomKey))
        _customZoom = AppStorage(wrappedValue: ChartModel.initialVisibleBars, win.key(SecondaryCharts.customZoomKey))
    }

    private var state: ChartsWindowState { workspace.chartsWindow(win) }
    @State private var symbolText = ""
    /// The symbol box is being edited: only a click on it starts that (see `SymbolField`).
    @State private var symbolFocused = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            TradingChart(chart: chart, onTrade: { workspace.selectedChartID = chart.id }) { factor in
                // Every chart in this window, from the zoom on screen; the header's Zoom slider follows.
                if layout == .all {
                    allZoom = workspace.zoomChartsWindow(by: factor, from: chart, sliderZoom: allZoom, broker: broker)
                } else {
                    customZoom = workspace.zoomChartsWindow(by: factor, from: chart, sliderZoom: customZoom, broker: broker)
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay { ChartOutline(chart: chart) }
        .simultaneousGesture(TapGesture().onEnded { workspace.selectedChartID = chart.id })
        // The header's buying and short selling power, kept current while selected (as every main chart's is;
        // a whole grid of them here would ask IB too often).
        .task(id: "\(workspace.selectedChartID == chart.id) \(chart.symbol)") {
            guard workspace.selectedChartID == chart.id, !chart.symbol.isEmpty else {
                // A frozen header asks once, as its stock loads (spread out, so a new list doesn't ask all at once).
                guard freezesHeaders, !chart.symbol.isEmpty else { return }
                try? await Task.sleep(for: .milliseconds(200 * (cell ?? 0)))
                if !Task.isCancelled { broker.refreshMarginSize(symbol: chart.symbol) }
                return
            }
            while !Task.isCancelled {
                broker.refreshMarginSize(symbol: chart.symbol)
                try? await Task.sleep(for: .seconds(5))
            }
        }
        .onAppear { symbolText = chart.symbol }
        .onChange(of: chart.symbol) { _, new in
            if !symbolFocused { symbolText = new }
        }
        .onChange(of: symbolFocused) { _, focused in
            if !focused { symbolText = chart.symbol }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            SymbolField(text: $symbolText, isFocused: $symbolFocused) {
                // Typed by hand: the chart keeps it and its cell; an emptied field gives it back to the gainers.
                let symbol = ForexPair.normalize(symbolText)
                if symbol.isEmpty {
                    state.displaced[chart.id] = nil
                    state.pins[chart.id] = nil
                } else {
                    // The stock it showed while following the gainers leaves the charts, so nothing else moves.
                    if state.pins[chart.id] == nil, !chart.symbol.isEmpty {
                        state.displaced[chart.id] = chart.symbol
                    }
                    if symbol != chart.symbol { workspace.load(symbol, into: chart, broker: broker) }
                    if let cell { state.pins[chart.id] = cell }
                }
                symbolText = chart.symbol
                symbolFocused = false
            }
            .frame(width: 70)
            ChartHeaderInfo(chart: chart, alwaysMenu: true, freezesUnlessLive: freezesHeaders)
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(broker.positionTint(chart.symbol, colors: sideColors))
    }
}

/// The Forex list's 1/2 and 5D buttons' look, in the Charts window's top bar and the main window's (see `MainForexButtons`).
struct ForexListButton: View {
    let title: String
    let lit: Bool
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(lit ? Color.primary : Color.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(lit ? 0.16 : 0.08)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
