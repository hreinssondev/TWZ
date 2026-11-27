//
//  AlertFocus.swift
//  TWZ
//
//  A trend line alert takes the charts to its stock: an open Charts window's (the first, then Charts 2), else the main
//  window's. They go to the Alerts, Colored, Forex + Active and Forex lists that may show it, in that order (as ⌘⇧X,
//  ⌘⇧C, ⌘⇧D, ⌘⇧F do there); a list that doesn't show it within a few seconds gives way to the next. Nothing is selected:
//  the stock's charts pulse white until one of them is (see `Workspace.firedAlerts`).
//

import AppKit

extension Workspace {
    /// The lists an alert's stock goes to, first one first.
    static let alertLists: [ScannerKind] = [.alerts, .colored, .forexActive, .forex]
    /// How long a list has to show the stock before the next is tried.
    private static let alertListWait: Duration = .seconds(5)

    func focusAlert(_ symbol: String, broker: Broker) {
        firedAlerts.insert(symbol)
        let win = Self.alertWindow()
        let lists = Self.alertLists.filter { alertListMayShow(symbol, $0, in: win, broker: broker) }
        let token = UUID()
        alertFocusToken = token
        Task { @MainActor [weak self] in
            await self?.focusAlert(symbol, in: win, lists: lists, token: token)
        }
    }

    private func focusAlert(_ symbol: String, in win: ChartsWin?, lists: [ScannerKind], token: UUID) async {
        let clock = ContinuousClock()
        for list in lists {
            guard alertFocusToken == token else { return }
            if alertList(in: win) != list { showAlertList(list, in: win) }
            let deadline = clock.now + Self.alertListWait
            while clock.now < deadline {
                if alertChart(showing: symbol, in: win) != nil { return }
                try? await Task.sleep(for: .milliseconds(200))
                guard alertFocusToken == token else { return }
            }
        }
    }

    /// The first open Charts window, nil for none: the main window then.
    private static func alertWindow() -> ChartsWin? {
        ChartsWin.allCases.first { win in
            NSApp.windows.contains { ChartsWin.of($0) == win && $0.isVisible && !$0.isMiniaturized }
        }
    }

    private func alertList(in win: ChartsWin?) -> ScannerKind {
        win.map { chartsWindow($0).list } ?? gridScan?.kind ?? .gainers
    }

    private func showAlertList(_ list: ScannerKind, in win: ChartsWin?) {
        if let win {
            chartsWindow(win).list = list
        } else {
            listShortcut = ListShortcut(kind: list)
        }
    }

    /// Whether `list` may show `symbol` in that window: Colored, the tickers given a color; Forex + Active, Most Active
    /// $'s stocks, and in a Charts window the pairs too (the main window shows only those given a color); Forex, its pairs.
    private func alertListMayShow(_ symbol: String, _ list: ScannerKind, in win: ChartsWin?, broker: Broker) -> Bool {
        let forex = ForexPair.isForex(symbol)
        switch list {
        case .alerts:
            return alertSymbols.contains(symbol)
        case .colored:
            return coloredSymbols.contains(symbol)
        case .forexActive:
            if forex { return win != nil && ForexPair.listed.contains(symbol) }
            return mostActiveRows(broker).contains(symbol)
        case .forex:
            return ForexPair.listed.contains(symbol)
        default:
            return false
        }
    }

    /// Most Active $'s rows, from whatever shows them now: the main grid, a list panel or a Charts window.
    private func mostActiveRows(_ broker: Broker) -> [String] {
        let kinds: [ScannerKind] = [.forexActive, .dollarVolume]
        var owners: [String] = []
        if let kind = gridScan?.kind, kinds.contains(kind) { owners.append(MainGrid.scannerOwner) }
        owners += shownLists.filter { kinds.contains($0.value) }.keys
        owners += ChartsWin.allCases.filter { kinds.contains(chartsWindow($0).list) }.map(\.scannerOwner)
        return owners.flatMap { broker.scans[$0]?.symbols ?? [] }
    }

    /// That window's first chart showing `symbol`, a Colored close-up only when no other chart does.
    private func alertChart(showing symbol: String, in win: ChartsWin?) -> Int? {
        let ids = win.map { chartsWindow($0).charts.map(\.id) } ?? mainCells
        let showing = ids.filter { chart(id: $0)?.symbol == symbol }
        return showing.first { !closeUpChartIDs.contains($0) } ?? showing.first
    }
}
