//
//  AlertFocus.swift
//  TWZ
//
//  A trend line alert takes the main grid to its stock: to the first of the Colored, Forex + Active and Forex lists
//  that shows it, in that order (as ⌘⇧C, ⌘⇧D, ⌘⇧F do), and once the grid shows that list, its chart is selected.
//  Already on that list: its chart is selected at once. On none of them: its chart is selected if the grid shows it.
//

import Foundation

struct PendingAlertFocus {
    var symbol: String
    var list: ScannerKind
    /// Given up after this, should the list not show the stock.
    var until: Date
}

extension Workspace {
    /// The lists an alert's stock goes to, first one first.
    static let alertLists: [ScannerKind] = [.colored, .forexActive, .forex]

    func focusAlert(_ symbol: String, broker: Broker) {
        guard let list = Self.alertLists.first(where: { alertListShows(symbol, $0, broker: broker) }) else {
            if let id = alertChart(showing: symbol) { selectedChartID = id }
            return
        }
        alertFocus = PendingAlertFocus(symbol: symbol, list: list, until: Date().addingTimeInterval(15))
        if gridScan?.kind == list {
            showAlertFocus()
        } else {
            listShortcut = ListShortcut(kind: list)
        }
    }

    /// The grid has followed its list: an alert waiting for it selects its stock's chart, once one shows it.
    func showAlertFocus() {
        guard let focus = alertFocus else { return }
        guard Date() < focus.until else { alertFocus = nil; return }
        guard gridScan?.kind == focus.list, let id = alertChart(showing: focus.symbol) else { return }
        alertFocus = nil
        selectedChartID = id
    }

    /// Whether `list` in the main grid shows `symbol`: Colored, the tickers given a color; Forex + Active, those and
    /// Most Active $'s stocks; Forex, its pairs.
    private func alertListShows(_ symbol: String, _ list: ScannerKind, broker: Broker) -> Bool {
        switch list {
        case .colored:
            return coloredSymbols.contains(symbol)
        case .forexActive:
            var rows: [String] = []
            if [.forexActive, .dollarVolume].contains(gridScan?.kind), let symbols = broker.scans[MainGrid.scannerOwner]?.symbols {
                rows += symbols
            }
            for (panel, kind) in shownLists where kind == .forexActive || kind == .dollarVolume {
                rows += broker.scans[panel]?.symbols ?? []
            }
            return mainGridSymbols(rows, kind: .forexActive).prefix(mainCells.count).contains(symbol)
        case .forex:
            return ForexPair.listed.contains(symbol)
        default:
            return false
        }
    }

    /// The main grid's first chart showing `symbol`, a Colored close-up only when no other chart does.
    private func alertChart(showing symbol: String) -> Int? {
        let showing = mainCells.filter { chart(id: $0)?.symbol == symbol }
        return showing.first { !closeUpChartIDs.contains($0) } ?? showing.first
    }
}
