//
//  Workspace.swift
//  TWZ
//
//  UI state that survives relaunches: chart symbols/timeframes,
//  scanner filters, hotkey configuration and what-if buys.
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
    /// A secondary-window chart: short history, no tick-by-tick streams, not saved.
    let isCompact: Bool

    init(id: Int, symbol: String, timeframe: Timeframe, isCompact: Bool = false) {
        self.id = id
        self.symbol = symbol
        self.timeframe = timeframe
        self.isCompact = isCompact
        let zoom = isCompact ? Self.compactDefaultVisibleBars : 120
        defaultVisibleBars = zoom
        visibleBars = zoom
    }

    /// Bars on screen at the default zoom (double-click goes back to it); compact charts start zoomed
    /// out twice as far, and the Charts window's All Charts view sets its own with a slider.
    var defaultVisibleBars: Double
    static let compactDefaultVisibleBars: Double = 240
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

@Observable
final class Workspace {
    let charts: [ChartModel]
    let secondaryCharts: [ChartModel]
    /// The main window's cells past its four charts (see `ChartGrid`); compact and unsaved like the
    /// secondary charts.
    let mainGainerCharts: [ChartModel]
    /// The selected chart, or the last one selected while none is (see `isChartSelected`).
    var selectedChartIndex = 0 { didSet { isChartSelected = true } }
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
    /// System-wide shortcut that shows and hides the Charts window (see `ChartsWindowShortcut`).
    var chartsWindowShortcut: KeyShortcut? { didSet { save() } }

    var selectedChart: ChartModel { charts[selectedChartIndex] }
    /// The symbol orders go to: the selected chart's, or "" with no chart selected (nothing is sent).
    var targetSymbol: String { isChartSelected ? selectedChart.symbol : "" }

    @ObservationIgnored private let defaults = UserDefaults.standard

    init() {
        let symbols = defaults.stringArray(forKey: "chartSymbols") ?? ["SPY", "QQQ", "AAPL", "NVDA"]
        let frames = (defaults.stringArray(forKey: "chartTimeframes") ?? [])
            .compactMap(Timeframe.init(rawValue:))
        let defaultFrames: [Timeframe] = [.m1, .m5, .m15, .d1]
        charts = (0..<4).map { i in
            ChartModel(
                id: i,
                symbol: i < symbols.count ? symbols[i] : "",
                timeframe: i < frames.count ? frames[i] : defaultFrames[i]
            )
        }

        // Secondary charts start empty: the window fills them from the gainers scanner while it's
        // open and not paused, so nothing loads for them at launch.
        let secondaryTimeframe = defaults.string(forKey: SecondaryCharts.timeframeKey)
            .flatMap(Timeframe.init(rawValue:)) ?? .m1
        secondaryCharts = (0..<SecondaryCharts.count).map { i in
            ChartModel(id: 100 + i, symbol: "", timeframe: secondaryTimeframe, isCompact: true)
        }
        mainGainerCharts = (0..<MainGrid.gainerCount).map { i in
            ChartModel(id: 200 + i, symbol: "", timeframe: secondaryTimeframe, isCompact: true)
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

        chartsWindowShortcut = defaults.data(forKey: "chartsWindowShortcut")
            .flatMap { try? JSONDecoder().decode(KeyShortcut.self, from: $0) }
    }

    func scanFilter(panel: String, _ kind: ScannerKind) -> ScannerFilter {
        scanFilters["\(panel)|\(kind.rawValue)"] ?? kind.defaultFilter
    }

    func setScanFilter(_ filter: ScannerFilter, panel: String, _ kind: ScannerKind) {
        scanFilters["\(panel)|\(kind.rawValue)"] = filter
    }

    func saveCharts() {
        defaults.set(charts.map(\.symbol), forKey: "chartSymbols")
        defaults.set(charts.map(\.timeframe.rawValue), forKey: "chartTimeframes")
    }

    /// Saves the main charts; secondary charts aren't saved (see `secondaryCharts`).
    func saveChart(_ chart: ChartModel) {
        if !chart.isCompact { saveCharts() }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(hotkeys) { defaults.set(data, forKey: "hotkeys") }
        if let data = try? JSONEncoder().encode(scanFilters) { defaults.set(data, forKey: "scanFilters") }
        if let data = try? JSONEncoder().encode(whatIfs) { defaults.set(data, forKey: "whatIfs") }
        defaults.set(chartsWindowShortcut.flatMap { try? JSONEncoder().encode($0) }, forKey: "chartsWindowShortcut")
    }
}
