//
//  Workspace.swift
//  TWZ
//
//  UI state that survives relaunches: chart symbols/timeframes,
//  scanner filters and hotkey configuration.
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
    var visibleBars: Double = 120
    var scrollBack: Double = 0
    /// Vertical drag, as a fraction of the auto-fitted price range (positive = moved down).
    var priceShift: Double = 0
    /// ⌘-swipe vertical zoom: the auto-fitted price range times this (above 1 = zoomed out).
    var priceScale: Double = 1

    init(id: Int, symbol: String, timeframe: Timeframe) {
        self.id = id
        self.symbol = symbol
        self.timeframe = timeframe
    }
}

@Observable
final class Workspace {
    let charts: [ChartModel]
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
    }

    func scanFilter(panel: String, _ kind: ScannerKind) -> ScannerFilter {
        scanFilters["\(panel)|\(kind.rawValue)"] ?? ScannerFilter()
    }

    func setScanFilter(_ filter: ScannerFilter, panel: String, _ kind: ScannerKind) {
        scanFilters["\(panel)|\(kind.rawValue)"] = filter
    }

    func saveCharts() {
        defaults.set(charts.map(\.symbol), forKey: "chartSymbols")
        defaults.set(charts.map(\.timeframe.rawValue), forKey: "chartTimeframes")
    }

    private func save() {
        if let data = try? JSONEncoder().encode(hotkeys) { defaults.set(data, forKey: "hotkeys") }
        if let data = try? JSONEncoder().encode(scanFilters) { defaults.set(data, forKey: "scanFilters") }
    }
}
