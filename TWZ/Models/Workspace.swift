//
//  Workspace.swift
//  TWZ
//
//  UI state that survives relaunches: chart symbols/timeframes,
//  watchlists, scanner filters and hotkey configuration.
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

    init(id: Int, symbol: String, timeframe: Timeframe) {
        self.id = id
        self.symbol = symbol
        self.timeframe = timeframe
    }
}

@Observable
final class Workspace {
    static let watchlistNames = ["Watchlist 1", "Watchlist 2", "Watchlist 3", "Watchlist 4"]

    let charts: [ChartModel]
    var selectedChartIndex = 0

    var watchlists: [String: [String]] { didSet { save() } }
    var hotkeys: [Hotkey] { didSet { save() } }
    /// Scanner filters per list panel and scanner, keyed "panelId|scanner".
    var scanFilters: [String: ScannerFilter] { didSet { save() } }

    var selectedChart: ChartModel { charts[selectedChartIndex] }

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

        if let data = defaults.data(forKey: "watchlists"),
           let lists = try? JSONDecoder().decode([String: [String]].self, from: data) {
            watchlists = lists
        } else {
            watchlists = [
                "Watchlist 1": ["SPY", "QQQ", "IWM", "DIA"],
                "Watchlist 2": ["AAPL", "MSFT", "NVDA", "TSLA", "AMD", "META", "AMZN", "GOOGL"],
            ]
        }

        if let data = defaults.data(forKey: "hotkeys"),
           let keys = try? JSONDecoder().decode([Hotkey].self, from: data) {
            hotkeys = keys
        } else {
            hotkeys = Hotkey.defaults
        }

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

    func symbols(in list: String) -> [String] { watchlists[list] ?? [] }

    func add(_ symbol: String, to list: String) {
        let s = symbol.trimmingCharacters(in: .whitespaces).uppercased()
        guard !s.isEmpty, !symbols(in: list).contains(s) else { return }
        watchlists[list, default: []].append(s)
    }

    func remove(_ symbol: String, from list: String) {
        watchlists[list]?.removeAll { $0 == symbol }
    }

    func saveCharts() {
        defaults.set(charts.map(\.symbol), forKey: "chartSymbols")
        defaults.set(charts.map(\.timeframe.rawValue), forKey: "chartTimeframes")
    }

    private func save() {
        if let data = try? JSONEncoder().encode(watchlists) { defaults.set(data, forKey: "watchlists") }
        if let data = try? JSONEncoder().encode(hotkeys) { defaults.set(data, forKey: "hotkeys") }
        if let data = try? JSONEncoder().encode(scanFilters) { defaults.set(data, forKey: "scanFilters") }
    }
}
