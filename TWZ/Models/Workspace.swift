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
    /// Every load starts with a short history; once the view reaches its oldest bar, the full
    /// history loads (see `Broker.loadFullHistory`).
    var hasFullHistory = false
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
}

/// A pretend buy at the clicked price, placed by ⌃-clicking a chart with no position open: 80% of the
/// largest long IB's margin allows in the symbol at that moment. Only a margin preview goes to IB,
/// never an order; hovering the chart shows what it would have made or lost. ⌃-clicking its line
/// removes it.
nonisolated struct WhatIf: Codable {
    static let buyingPowerFraction = 0.8
    /// Stands in for an order id on the what-if line, so double-clicking the line removes it.
    static let lineId = -1

    var price: Double
    var shares: Double

    /// P/L if sold at `exit`.
    func pnl(at exit: Double) -> Double { (exit - price) * shares }
}

/// A main-window chart given a stock by hand, as saved: its cell and what it shows.
nonisolated struct MainGridPin: Codable, Equatable {
    var column: Int
    var row: Int
    var symbol: String
    var timeframe: Timeframe
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
    /// The main charts that get tick-by-tick streams (⌘↩ toggles the selected one); four at first.
    var fastChartIDs: Set<Int> { didSet { save() } }
    /// System-wide shortcut that shows and hides the Charts window (see `ChartsWindowShortcut`).
    var chartsWindowShortcut: KeyShortcut? { didSet { save() } }
    /// Main-window charts given a stock by hand (a list, a symbol field): they keep it and their cell
    /// instead of following the gainers, until Reset (see `ChartGrid`). Saved with their stock
    /// (see `mainGridPins`).
    var manualChartIDs: Set<Int> = []
    /// Counts the account bar's Resets: every main-window chart follows the gainers again, on the
    /// top bar's timeframe.
    var gainerResets = 0

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
            hotkeys = keys
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
                               symbol: chart.symbol, timeframe: chart.timeframe)
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
