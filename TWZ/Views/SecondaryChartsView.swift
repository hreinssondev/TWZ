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
    /// Each list's own timeframe in this window, as it was left (see `SecondaryChartsView.listChanged`).
    func listTimeframeKey(_ list: ScannerKind) -> String { key(SecondaryCharts.timeframeKey) + "." + list.rawValue }
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
    /// Rows in its grid now, for ⌘← / ⌘→ on the Colored list (see `Workspace.moveColored`).
    @ObservationIgnored var gridRows = 2
    /// One chart for each cell of its largest grid, empty until the window's open.
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
    /// The next Reset on the Colored list: only the close-ups (true) or only the other charts (false), as the pointer
    /// was over one or the other when it was asked for; nil: all of them.
    @ObservationIgnored var resetsCloseUps: Bool?
    /// The list and timeframe shown before, which ´ goes back to (see `noteView`).
    @ObservationIgnored var previousView: Workspace.GridView?
    /// ´ pressed: the switch on its way, so arriving there keeps the view left as the one to go back to.
    @ObservationIgnored var viewSwitch: (from: Workspace.GridView, to: Workspace.GridView, at: Date)?
    @ObservationIgnored private var listSwitchedAt: Date?

    /// The list or timeframe changed: the view left is the one ´ goes back to. A list brings its own timeframe a moment
    /// after it (see `SecondaryChartsView.listChanged`): that's the same switch.
    func noteView(from old: Workspace.GridView, to new: Workspace.GridView) {
        if let pending = viewSwitch, Date().timeIntervalSince(pending.at) < 3 {
            if new == pending.to {
                previousView = pending.from
                viewSwitch = nil
            }
            return
        }
        viewSwitch = nil
        guard old != new else { return }
        if old.list == new.list, let at = listSwitchedAt, Date().timeIntervalSince(at) < 1 { return }
        if old.list != new.list { listSwitchedAt = Date() }
        previousView = old
    }

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
        // A symbol shown twice (a Colored list's close-up left behind, say) keeps only its first chart.
        var kept: Set<String> = []
        for chart in charts {
            if top.contains(chart.symbol), kept.insert(chart.symbol).inserted { continue }
            if let symbol = incoming.popFirst() {
                load(symbol, into: chart, broker: broker)
            } else {
                clear(chart, broker: broker)
            }
        }
    }

    /// ⇧-, ⌘- or ⌥-swipe on Charts window chart `chart`: every chart there zooms by `factor` from the zoom on
    /// screen, as `zoomGrid` does for the main charts; on Forex + Active, only the pairs or only the stocks,
    /// as `chart` is one (see `zoomSide`). The new zoom, for the window's Zoom slider.
    func zoomChartsWindow(by factor: Double, from chart: ChartModel, sliderZoom: Double, broker: Broker) -> Double {
        guard let win = ChartsWin.of(chartID: chart.id) else { return sliderZoom }
        let window = chartsWindow(win)
        let charts = zoomSide(of: window.charts, from: chart, list: window.list)
        let shown = charts.filter { !$0.symbol.isEmpty }
        let base = !GridZoom.resetsAdjusted && chart.adjustedByHand
            ? shown.first { !$0.adjustedByHand }?.visibleBars ?? sliderZoom
            : chart.visibleBars
        guard base > 0 else { return sliderZoom }
        let most = shown.map { Double($0.bars.count) }.max() ?? 0
        let zoom = min(max(ChartModel.maxVisibleBars, most, base), max(15, base * factor))
        setZoom(zoom, of: charts, broker: broker, by: zoom / base)
        // The Colored list's close-ups zoom apart from the slider.
        if window.list == .colored, closeUpChartIDs.contains(chart.id) {
            closeUpZoom = zoom
            return sliderZoom
        }
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
    /// On the Colored list: the charts' ids in cell order (see `ColoredLayout`).
    @State private var coloredOrder: [Int] = []
    /// The Forex list's second page: the pairs past those the grid has room for, in its cells instead.
    @State private var showsRest = false
    /// The Forex list by each pair's range over its last 5 finished days, widest first (see `TradingEngine.setForexByRange`).
    @AppStorage private var forexByRange: Bool
    @AppStorage private var masterTimeframe: Timeframe
    @AppStorage private var headerHeight: Double
    /// P: the main window's right side (the lists, Orders, Positions, Round trips) beside the charts. Saved.
    @AppStorage private var showsSidePanel: Bool
    @AppStorage private var sidePanelWidth: Double
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
        _showsSidePanel = AppStorage(wrappedValue: false, win.key("chartsWindowSidePanel"))
        _sidePanelWidth = AppStorage(wrappedValue: 420, win.key("chartsWindowSidePanelWidth"))
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
            HStack(spacing: 0) {
                let items = self.items
                SplitGrid(columns: columns, rows: rows, items: items,
                          gap: Self.gap, inset: Self.gap,
                          columnSplits: $columnSplits, rowSplits: $rowSplits) { chart in
                    SecondaryChartPane(win: win, chart: chart, cell: items.firstIndex { $0.id == chart.id })
                }
                if showsSidePanel {
                    ResizeHandle(resizes: .horizontal, thickness: Self.gap, current: sidePanelWidth, range: 240...1200,
                                 inverted: true, onChange: { sidePanelWidth = $0 }, onReset: { sidePanelWidth = 420 })
                    ChartsWindowSidePanel(win: win, onPick: pick)
                        .frame(width: sidePanelWidth)
                        .padding([.vertical, .trailing], Self.gap)
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.35))
        .onAppear {
            broker.chartsWindowLists[win] = state.list.rawValue
            applyZoom()
            workspace.syncChartsWindowScale(to: broker)
            start()
        }
        // On close only: hiding the window (ordering it out) keeps the charts live.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
            if ChartsWin.of(note.object as? NSWindow) == win { stop() }
        }
        // Fills the charts as soon as the scanner answers.
        .onChange(of: broker.scans[win.scannerOwner]?.symbols) { syncWithGainers() }
        .onChange(of: masterTimeframe) { _, new in
            workspace.setTimeframe(new, of: workspace.gridCharts(state.charts, list: state.list), broker: broker)
            // The list on screen keeps it; the others keep theirs (see `listChanged`).
            UserDefaults.standard.set(new.rawValue, forKey: listTimeframeKey(state.list))
        }
        // Charts still in the new top N stay put; the rest are emptied (smaller grid) or filled (larger).
        // A chart set by hand whose cell is gone lets go of its stock.
        .onChange(of: count) {
            state.pins = state.pins.filter { $0.value < count }
            lastGainers = []; syncWithGainers()
        }
        // A chart set or let go by hand, or Reset: the gainers fill the cells around the ones set by hand.
        .onChange(of: state.pins) {
            lastGainers = []; syncWithGainers()
        }
        // Another list: the charts still in its top N stay, the rest load its stocks.
        .onChange(of: state.list) { old, new in listChanged(from: old, to: new) }
        // The view left (list or timeframe) is the one ´ goes back to.
        .onChange(of: Workspace.GridView(list: state.list, timeframe: masterTimeframe)) { old, new in state.noteView(from: old, to: new) }
        .onChange(of: state.resets) { reset() }
        .onChange(of: layout) { applyZoom() }
        // A chart layout loaded: its lines (see `GridLayout`).
        .onChange(of: workspace.gridLayoutLoads) {
            columnSplits = SplitStore(key: win.layoutWindow.columnSplitsKey)
            rowSplits = SplitStore(key: win.layoutWindow.rowSplitsKey)
        }
        .onChange(of: allZoom) { zoomMoved(to: $1) }
        .onChange(of: customZoom) { zoomMoved(to: $1) }
    }

    /// The Zoom slider: a swipe's zoom while it's held unsaved (see `Workspace.holdZoom`), else the stored one.
    private var liveZoomBinding: Binding<Double> {
        let key = win.key(layout == .all ? SecondaryCharts.allZoomKey : SecondaryCharts.customZoomKey)
        let stored = layout == .all ? $allZoom : $customZoom
        return Binding(get: { workspace.liveZooms[key] ?? stored.wrappedValue },
                       set: { workspace.dropLiveZoom(key); stored.wrappedValue = $0 })
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
            GridSliders(columns: $customColumns, rows: $customRows, zoom: liveZoomBinding,
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
            ColoredColorsButton(list: state.list)
            // A failed scanner isn't retried, so the charts would sit on its last list without this.
            if let error = broker.scans[win.scannerOwner]?.error {
                Text(error).font(.system(size: 11)).foregroundStyle(.red).lineLimit(1).help(error)
            }
            Spacer()
            SharpnessToggles()
            FrameMeterBadge()
            Button {
                showsSidePanel.toggle()
            } label: {
                Text("P")
                    .font(.system(size: 10, weight: .regular).monospacedDigit())
                    .foregroundStyle(showsSidePanel ? Color.primary : Color.secondary.opacity(0.7))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(showsSidePanel ? 0.12 : 0)))
            }
            .buttonStyle(.plain)
            .help(showsSidePanel ? "Hide the lists, Orders and Positions" : "The lists, Orders, Positions and Round trips beside the charts, as in the main window")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        // Whole points, so the charts under it start on a whole pixel (see `SplitGrid`).
        .frame(height: headerHeight.rounded())
        // A ticker given a color or its color taken off: the Colored list follows.
        .onChange(of: workspace.coloredSymbols) {
            if state.list == .colored { syncWithGainers() }
        }
        // A stock given its first trend line or its last taken off: the Alerts list follows.
        .onChange(of: workspace.alertSymbols) {
            if state.list == .alerts { syncWithGainers() }
        }
        // The height drag sits behind the controls so it never takes a slider's drag; a click there
        // deselects the chart, as a click on empty space in Orders or Positions does.
        .background(
            Color(nsColor: .textBackgroundColor).opacity(0.2)
                .contentShape(Rectangle())
                .onTapGesture { workspace.isChartSelected = false }
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
                lastGainers = []; syncWithGainers()
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

    /// Another list: the charts still in its top N stay, the rest load its stocks; the Colored list's close-ups
    /// go back to the window's timeframe when it's left, and start at the forex charts' zoom when it's picked.
    /// Each list keeps where its charts were left on each stock and timeframe, and its zoom (see `Broker.leaveChartsWindowList`).
    /// Each list has its own timeframe here, as it was left: the charts take it before they load the list's stocks, so
    /// each loads once; one keeping its stock loads it on that timeframe.
    private func listChanged(from old: ScannerKind, to new: ScannerKind) {
        let leaving = workspace.gridCharts(state.charts, list: old)
        broker.leaveChartsWindowList(win, charts: leaving)
        broker.chartsWindowLists[win] = new.rawValue
        var retimed: [Int: String] = [:]
        if let own = UserDefaults.standard.string(forKey: listTimeframeKey(new)).flatMap(Timeframe.init(rawValue:)), own != masterTimeframe {
            masterTimeframe = own
            for chart in leaving where chart.timeframe != own {
                chart.timeframe = own
                retimed[chart.id] = chart.symbol
            }
        }
        if old == .colored { workspace.leaveColored(state.charts, timeframe: masterTimeframe, broker: broker) }
        if new == .colored { workspace.closeUpZoom = workspace.closeUpStartZoom(fallback: layout == .all ? allZoom : customZoom) }
        coloredOrder = []
        start()
        // Charts that kept their stock: on the new timeframe now.
        for chart in state.charts where !chart.symbol.isEmpty && retimed[chart.id] == chart.symbol {
            broker.loadChart(chart)
        }
        broker.adoptChartsWindowList(win, charts: workspace.gridCharts(state.charts, list: new))
    }

    private func listTimeframeKey(_ list: ScannerKind) -> String { win.listTimeframeKey(list) }

    /// A row clicked in the side panel's lists: into the selected chart when it's one of this window's, which keeps it
    /// and its cell as if typed in its symbol field; else into the main window's selected chart, as there.
    private func pick(_ symbol: String) {
        let s = ForexPair.normalize(symbol)
        guard !s.isEmpty else { return }
        guard workspace.isChartSelected, let chart = state.charts.first(where: { $0.id == workspace.selectedChartID }) else {
            return workspace.loadIntoSelectedChart(s, broker: broker)
        }
        if state.pins[chart.id] == nil, !chart.symbol.isEmpty { state.displaced[chart.id] = chart.symbol }
        if s != chart.symbol { workspace.load(s, into: chart, broker: broker) }
        if let cell = items.firstIndex(where: { $0.id == chart.id }) { state.pins[chart.id] = cell }
    }

    /// Reset: every chart back to the Zoom slider's zoom; on the Colored list, the close-ups to theirs.
    /// On the Colored list, only the close-ups or only the other charts when the pointer was over one (see `resetsCloseUps`).
    private func reset() {
        let closeUpsOnly = state.list == .colored ? state.resetsCloseUps : nil
        state.resetsCloseUps = nil
        workspace.syncChartsWindowScale(to: broker)
        if closeUpsOnly != true {
            workspace.resetViews(of: workspace.gridCharts(state.charts, list: state.list), zoom: layout == .all ? allZoom : customZoom, broker: broker)
        }
        if closeUpsOnly != false, state.list == .colored, let closeUpZoom = workspace.closeUpZoom {
            workspace.resetViews(of: state.charts.filter { workspace.closeUpChartIDs.contains($0.id) }, zoom: closeUpZoom, broker: broker)
        }
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
        workspace.setZoom(layout == .all ? allZoom : customZoom, of: workspace.gridCharts(state.charts, list: state.list), broker: broker)
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
        // The Colored list: the tickers given a color, each with its close-up (see `ColoredLayout`); charts set by hand
        // don't keep their cells here.
        if state.list.isWorkspaceList {
            state.gridRows = rows
            let plan = workspace.workspacePlan(state.list, rowColumns: Array(repeating: columns, count: rows))
            let ordered = coloredOrder.compactMap { id in state.charts.first { $0.id == id } }
            let charts = ordered + state.charts.filter { !coloredOrder.contains($0.id) }
            coloredOrder = workspace.layOutColored(charts, plan: plan, timeframe: masterTimeframe, broker: broker).map(\.id)
            return
        }
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
        // Forex + Active: the pairs, then the top stocks in the last charts (see `ScannerKind.activeCells`).
        if state.list == .forexActive {
            let active = ScannerKind.activeCells(of: slots)
            let stocks = gainers.filter { !ForexPair.isForex($0) }.prefix(active)
            gainers = Array(gainers.filter(ForexPair.isForex).prefix(slots - stocks.count)) + stocks
        }
        guard !gainers.isEmpty, gainers != lastGainers else { return }
        lastGainers = gainers
        workspace.fill(state.charts.filter { pins[$0.id] == nil },
                       withTop: slots, of: gainers, broker: broker)
    }

    /// The charts in grid order: one set by hand in its own cell, the others in gainer rank order around them.
    private var items: [ChartModel] {
        if state.list.isWorkspaceList, !coloredOrder.isEmpty {
            return coloredOrder.compactMap { id in state.charts.first { $0.id == id } }
        }
        let pins = state.pins
        let pinned = Dictionary(pins.map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        var rest = workspace.ranked(state.charts.filter { pins[$0.id] == nil }, by: lastGainers)[...]
        // Forex + Active: the stocks in the rightmost cells (see `ScannerKind.stockCells`), the pairs left of them.
        if state.list == .forexActive {
            let stockCells = ScannerKind.stockCells(columns: columns, rows: rows, taken: Set(pinned.keys.filter { $0 < count }))
            var stocks = rest.filter { !$0.symbol.isEmpty && !ForexPair.isForex($0.symbol) }[...]
            var others = rest.filter { $0.symbol.isEmpty || ForexPair.isForex($0.symbol) }[...]
            return (0..<state.charts.count).compactMap { cell in
                if let id = pinned[cell], let chart = state.charts.first(where: { $0.id == id }) { return chart }
                return stockCells.contains(cell) ? stocks.popFirst() ?? others.popFirst() : others.popFirst() ?? stocks.popFirst()
            }
        }
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

    init(win: ChartsWin, chart: ChartModel, cell: Int?) {
        self.win = win
        self.chart = chart
        self.cell = cell
        _layout = AppStorage(wrappedValue: win == .first ? .all : .custom, win.key(SecondaryCharts.layoutKey))
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
                // Saved once the zooming pauses (see `Workspace.holdZoom`).
                let key = win.key(layout == .all ? SecondaryCharts.allZoomKey : SecondaryCharts.customZoomKey)
                workspace.holdZoom(workspace.zoomChartsWindow(by: factor, from: chart, sliderZoom: workspace.currentZoom(key), broker: broker),
                                   key: key)
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
