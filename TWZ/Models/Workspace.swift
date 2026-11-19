//
//  Workspace.swift
//  TWZ
//
//  UI state that survives relaunches: charts set by hand, scanner filters, hotkey configuration
//  and what-if buys.
//

import Foundation
import Observation

@Observable
final class ChartModel: Identifiable {
    let id: Int
    var symbol: String
    var timeframe: Timeframe
    var bars: [Bar] = []
    var isLoading = false
    var error: String?

    // Viewport: how many bars fit on screen and how far we've scrolled back from the latest bar.
    var visibleBars: Double
    var scrollBack: Double = 0
    /// Vertical drag, as a fraction of the auto-fitted price range (positive = moved down).
    var priceShift: Double = 0
    /// ⌘-swipe vertical zoom: the auto-fitted price range times this (above 1 = zoomed out).
    var priceScale: Double = 1
    /// When the chart last loaded a symbol, counted across charts: of two main-window charts showing
    /// the same stock, the lower one showed it first (see `Workspace.timeframe(showing:in:otherwise:)`).
    @ObservationIgnored var loadOrder = 0

    init(id: Int, symbol: String, timeframe: Timeframe) {
        self.id = id
        self.symbol = symbol
        self.timeframe = timeframe
        defaultVisibleBars = Self.initialVisibleBars
        visibleBars = Self.initialVisibleBars
    }

    /// Bars on screen at the default zoom (double-click goes back to it); each grid's Zoom slider sets it.
    var defaultVisibleBars: Double
    static let initialVisibleBars: Double = 240
    /// The furthest out the Zoom sliders and gestures go (a full extended-hours day of 1m bars fits).
    static let maxVisibleBars: Double = 1200
}

/// A pretend buy at the clicked price, placed by ⌃-clicking a chart with no position open: 80% of the
/// largest long IB's margin allows in the symbol at that moment. Only a margin preview goes to IB,
/// never an order; hovering the chart shows what it would have made or lost. ⌃-clicking its line,
/// double-clicking anywhere on its chart, ⌘A, ⌘⌫ or ⌘⇧⌫ removes it.
nonisolated struct WhatIf: Codable {
    static let buyingPowerFraction = 0.8
    /// Stands in for an order id on the what-if line, so double-clicking the line removes it.
    static let lineId = -1

    var price: Double
    var shares: Double
    /// When it was made: tells it apart from a later one in the same symbol.
    var time: Date?
    /// IB's preview of the buy, a second or two after it's made (see `Broker.previewOrder`).
    var preview: OrderPreview?

    /// P/L if sold at `exit`.
    func pnl(at exit: Double) -> Double { (exit - price) * shares }
}

/// What IB's preview of an order (a what-if, never placed) says it would take.
nonisolated struct OrderPreview: Codable, Equatable, Sendable {
    /// Initial and maintenance margin the order adds, in the account's currency (NOK).
    var initMarginChange: Double
    var maintMarginChange: Double?
    var commission: Commission?

    /// Commissions and fees: IB's estimate is a range (`min` = `max` when it's sure).
    struct Commission: Codable, Equatable, Sendable {
        var min: Double
        var max: Double
        var currency: String
    }
}

/// A main-window chart given a stock by hand, as saved: its cell and what it shows.
nonisolated struct MainGridPin: Codable, Equatable {
    var column: Int
    var row: Int
    var symbol: String
    var timeframe: Timeframe
    /// The gainer the chart showed before it was set by hand, kept off the grid meanwhile (see
    /// `Workspace.handDisplaced`).
    var displaced: String?
}

@Observable
final class Workspace {
    /// The main window's charts, one for each cell of the largest grid (see `ChartGrid`).
    let mainCharts: [ChartModel]
    let secondaryCharts: [ChartModel]
    /// The main-window chart in each cell, in reading order, laid out for `mainColumns` columns.
    var mainCells: [Int]
    var mainColumns: Int
    /// The selected chart's id: a main-window chart; the last one selected while none is
    /// (see `isChartSelected`).
    var selectedChartID = 0 { didSet { isChartSelected = true } }
    /// False after clicking empty space in the Orders or Positions column: no chart is selected, so
    /// hotkeys and order shortcuts have no symbol to act on until a chart is selected again.
    var isChartSelected = true

    var hotkeys: [Hotkey] { didSet { save() } }
    /// The hotkey ⌘A sends; picked by clicking a hotkey button.
    var selectedHotkeyID: UUID? {
        didSet { defaults.set(selectedHotkeyID?.uuidString, forKey: "selectedHotkey") }
    }
    var selectedHotkey: Hotkey? { hotkeys.first { $0.id == selectedHotkeyID } }
    /// Scanner filters per list panel and scanner, keyed "panelId|scanner".
    var scanFilters: [String: ScannerFilter] { didSet { save() } }
    /// What-if buys by symbol.
    var whatIfs: [String: WhatIf] { didSet { save() } }
    /// The main charts that get tick-by-tick trades (⌘↩ toggles the selected one); four at first.
    /// The selected chart gets trades and bid/ask either way (see `TradingEngine.syncTickByTick`).
    var fastChartIDs: Set<Int> { didSet { save() } }
    /// System-wide shortcut that shows and hides the Charts window (see `ChartsWindowShortcut`).
    var chartsWindowShortcut: KeyShortcut? { didSet { save() } }
    /// Main-window charts given a stock by hand (a list, a symbol field): they keep it and their cell
    /// instead of following the gainers, until Reset (see `ChartGrid`). Saved with their stock
    /// (see `mainGridPins`).
    var manualChartIDs: Set<Int> = []
    /// Charts window charts given a stock by hand (their symbol field), by chart id, with the cell each
    /// keeps: the gainers fill the other cells around them, until the top bar's Reset, an emptied field,
    /// or a smaller grid without that cell (see `SecondaryChartsView`).
    var secondaryPins: [Int: Int] = [:]
    /// The stock a main-window chart following the gainers showed when it was given one by hand, by chart
    /// id: it leaves the grid while that chart keeps its own stock, so no other chart moves (see
    /// `followGainers`). Reset, or the chart letting go, brings it back.
    var handDisplaced: [Int: String] = [:]
    /// The same for the Charts window's charts set by hand (see `secondaryPins`).
    var secondaryDisplaced: [Int: String] = [:]

    /// The stocks kept off the main grid: those the charts still set by hand replaced.
    var displacedGainers: Set<String> { Set(manualChartIDs.compactMap { handDisplaced[$0] }) }
    /// Round trips double-clicked in the Round trips tab, by symbol: their fills' arrows and entry / exit
    /// lines show on the symbol's charts until the row, or one of those charts, is double-clicked.
    var shownTrips: [String: String] = [:]
    /// Filled orders double-clicked in the Orders list, by symbol: their fills (exec ids), whose arrows
    /// and average fill price show on the symbol's charts in place of a shown round trip, until the
    /// row, or one of those charts, is double-clicked.
    var shownOrderFills: [String: Set<String>] = [:]
    /// What each list panel on screen shows, by panel id (the lists keep it up to date).
    var shownLists: [String: ScannerKind] = [:]
    /// ⌘⇧ + a list's letter (see `ScannerKind.forShortcut`): the list to show and load into the chart grid,
    /// taken up by the list panels (see `ListPanel`). A new one each press, so the same key works again.
    var listShortcut: ListShortcut?

    struct ListShortcut: Equatable {
        var kind: ScannerKind
        var id = UUID()
    }
    /// Counts the account bar's Resets: every main-window chart follows the grid's list again, on the
    /// top bar's timeframe.
    var gainerResets = 0
    /// The list the main-window charts follow in place of the top gainers, from a list's load button
    /// or ⌘⇧ shortcut, until another list loads; Reset keeps it (nil: the gainers). Saved.
    var gridScan: ScanSpec? {
        didSet { defaults.set(gridScan.flatMap { try? JSONEncoder().encode($0) }, forKey: MainGrid.scanKey) }
    }
    /// Colors given to stocks with ⌥⇧ and a color's letter, by symbol (see `StockColor`). Saved, so a
    /// stock that leaves the charts has its color again when it comes back. Set with `setColor`.
    private(set) var stockColors: [String: StockColor] {
        didSet { defaults.set(stockColors.mapValues(\.rawValue), forKey: StockColor.storageKey) }
    }

    /// Gives `symbol` a color, or takes its color off (nil). A color marks one stock: the stock that
    /// had it before loses it, on the charts or not.
    func setColor(_ color: StockColor?, of symbol: String) {
        var colors = color.map { color in stockColors.filter { $0.value != color } } ?? stockColors
        colors[symbol] = color
        stockColors = colors
    }
    /// Saved layouts, in the order saved (see `Layouts`).
    var layouts: [SavedLayout] {
        didSet { defaults.set(try? JSONEncoder().encode(layouts), forKey: Layouts.storageKey) }
    }
    /// The Settings sheet is open (shown from the main window, so it stays open while the account bar
    /// moves between top and bottom).
    var showsSettings = false
    /// Counts layouts loaded, so views holding layout state of their own (the grid's lines) reload it.
    var layoutLoads = 0
    /// Settings a layout load just changed whose change handler should let it be once (see `loadLayout`).
    @ObservationIgnored var layoutSkips: Set<String> = []

    var selectedChart: ChartModel { chart(id: selectedChartID) ?? mainCharts[0] }

    /// A main-window chart.
    func chart(id: Int) -> ChartModel? {
        mainCharts.first { $0.id == id }
    }
    /// The symbol orders go to: the selected chart's, or "" with no chart selected (nothing is sent).
    var targetSymbol: String { isChartSelected ? selectedChart.symbol : "" }

    @ObservationIgnored private let defaults = UserDefaults.standard
    /// Symbol loads so far (see `ChartModel.loadOrder`).
    @ObservationIgnored private var loads = 0

    init() {
        // Main charts start empty and fill from the gainers scanner, but for those set by hand,
        // which come back in their cells with their stock.
        let mainTimeframe = defaults.string(forKey: MainGrid.timeframeKey).flatMap(Timeframe.init(rawValue:)) ?? .m1
        mainCharts = (0..<MainGrid.maxColumns * MainGrid.maxRows).map { i in
            ChartModel(id: i, symbol: "", timeframe: mainTimeframe)
        }
        let columns = MainGrid.columns(defaults.object(forKey: MainGrid.columnsKey) as? Int ?? 2)
        let rows = MainGrid.rows(defaults.object(forKey: MainGrid.rowsKey) as? Int ?? 2)
        mainColumns = columns
        mainCells = Array(0..<columns * rows)

        // Secondary charts start empty: the window fills them from the gainers scanner while it's
        // open and not paused, so nothing loads for them at launch.
        let secondaryTimeframe = defaults.string(forKey: SecondaryCharts.timeframeKey)
            .flatMap(Timeframe.init(rawValue:)) ?? .m1
        secondaryCharts = (0..<SecondaryCharts.count).map { i in
            ChartModel(id: 100 + i, symbol: "", timeframe: secondaryTimeframe)
        }

        if let data = defaults.data(forKey: "hotkeys"),
           let keys = try? JSONDecoder().decode([Hotkey].self, from: data) {
            // A shortcut recorded before the app took it for itself (⌘⌫) is dropped: the hotkey's unassigned.
            hotkeys = keys.map { key in
                var key = key
                if key.shortcut?.reservedFor != nil { key.shortcut = nil }
                return key
            }
        } else {
            hotkeys = Hotkey.defaults
        }

        selectedHotkeyID = defaults.string(forKey: "selectedHotkey").flatMap(UUID.init(uuidString:))

        if let data = defaults.data(forKey: "scanFilters"),
           let filters = try? JSONDecoder().decode([String: ScannerFilter].self, from: data) {
            scanFilters = filters
        } else {
            scanFilters = [:]
        }

        if let data = defaults.data(forKey: "whatIfs"),
           let saved = try? JSONDecoder().decode([String: WhatIf].self, from: data) {
            whatIfs = saved
        } else {
            whatIfs = [:]
        }

        fastChartIDs = Set(defaults.array(forKey: "fastChartIDs") as? [Int] ?? Array(0..<4))

        stockColors = (defaults.dictionary(forKey: StockColor.storageKey) as? [String: String] ?? [:])
            .compactMapValues(StockColor.init(rawValue:))

        layouts = defaults.data(forKey: Layouts.storageKey)
            .flatMap { try? JSONDecoder().decode([SavedLayout].self, from: $0) } ?? []

        gridScan = defaults.data(forKey: MainGrid.scanKey).flatMap { try? JSONDecoder().decode(ScanSpec.self, from: $0) }

        chartsWindowShortcut = defaults.data(forKey: "chartsWindowShortcut")
            .flatMap { try? JSONDecoder().decode(KeyShortcut.self, from: $0) }

        let pins = defaults.data(forKey: MainGrid.pinsKey)
            .flatMap { try? JSONDecoder().decode([MainGridPin].self, from: $0) } ?? []
        for pin in pins where pin.column < columns && pin.row < rows {
            let chart = mainCharts[mainCells[pin.row * columns + pin.column]]
            chart.symbol = pin.symbol
            chart.timeframe = pin.timeframe
            countLoad(of: chart)
            manualChartIDs.insert(chart.id)
            handDisplaced[chart.id] = pin.displaced
        }
    }

    func scanFilter(panel: String, _ kind: ScannerKind) -> ScannerFilter {
        scanFilters["\(panel)|\(kind.rawValue)"] ?? kind.defaultFilter
    }

    func setScanFilter(_ filter: ScannerFilter, panel: String, _ kind: ScannerKind) {
        scanFilters["\(panel)|\(kind.rawValue)"] = filter
    }

    /// A chart is about to load a symbol: from now on it's the latest to show it.
    func countLoad(of chart: ChartModel) {
        loads += 1
        chart.loadOrder = loads
    }

    /// The charts set by hand, with their cell and stock.
    var mainGridPins: [MainGridPin] {
        mainCells.enumerated().compactMap { index, id in
            guard manualChartIDs.contains(id), let chart = chart(id: id), !chart.symbol.isEmpty else { return nil }
            return MainGridPin(column: index % mainColumns, row: index / mainColumns,
                               symbol: chart.symbol, timeframe: chart.timeframe, displaced: handDisplaced[id])
        }
    }

    func saveMainGridPins() {
        defaults.set(try? JSONEncoder().encode(mainGridPins), forKey: MainGrid.pinsKey)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(hotkeys) { defaults.set(data, forKey: "hotkeys") }
        if let data = try? JSONEncoder().encode(scanFilters) { defaults.set(data, forKey: "scanFilters") }
        if let data = try? JSONEncoder().encode(whatIfs) { defaults.set(data, forKey: "whatIfs") }
        defaults.set(fastChartIDs.sorted(), forKey: "fastChartIDs")
        defaults.set(chartsWindowShortcut.flatMap { try? JSONEncoder().encode($0) }, forKey: "chartsWindowShortcut")
    }
}
