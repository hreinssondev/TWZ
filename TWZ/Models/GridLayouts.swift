//
//  GridLayouts.swift
//  TWZ
//
//  Chart layouts by number, in each window's top bar beside the view-set numbers (see `GridLayoutButtons`):
//  ⇧-click a number saves that window's chart grid as it is, its columns and rows (the Charts window's
//  All Charts / Top N too) and its column and row lines; a click, or ⇧1–5 (outside a text field) with
//  that window in front, puts it back. The main window and the Charts window keep their own five. The
//  charts' stocks, timeframes and zoom stay as they are.
//

import AppKit

nonisolated struct GridLayout: Codable, Equatable {
    enum Window: String, Codable, CodingKeyRepresentable {
        case main, chartsWindow, chartsWindow2

        /// The Charts window it is, if one.
        var chartsWin: ChartsWin? {
            switch self {
            case .main: nil
            case .chartsWindow: .first
            case .chartsWindow2: .second
            }
        }
        var columnsKey: String { chartsWin.map { $0.key(SecondaryCharts.columnsKey) } ?? MainGrid.columnsKey }
        var rowsKey: String { chartsWin.map { $0.key(SecondaryCharts.rowsKey) } ?? MainGrid.rowsKey }
        var columnSplitsKey: String { chartsWin.map { $0.key("secondaryChartsColumnSplits") } ?? "mainChartColumnSplits" }
        var rowSplitsKey: String { chartsWin.map { $0.key("secondaryChartsRowSplits") } ?? "mainChartRowSplits" }
        /// A Charts window's All Charts or custom grid; the main window has none.
        var modeKey: String? { chartsWin.map { $0.key(SecondaryCharts.layoutKey) } }
        var defaultColumns: Int { chartsWin?.defaultColumns ?? 2 }
        var defaultRows: Int { chartsWin?.defaultRows ?? 2 }
        var defaultMode: String? { chartsWin.map { ($0 == .first ? SecondaryCharts.Layout.all : .custom).rawValue } }
        /// "", "Charts window: ", "Charts window 2: ", before a message.
        var messagePrefix: String { chartsWin.map { "\($0.name): " } ?? "" }
    }

    static let slots = 1...5
    static let storageKey = "gridLayouts"
    static let activeKey = "activeGridLayouts"

    var mode: String?
    /// Which window's: All Charts is 6×3 in the first Charts window, 3×6 in the second (nil: saved before there were two).
    var window: Window?
    var columns: Int
    var rows: Int
    var columnSplits: [String: [Double]]
    var rowSplits: [String: [Double]]

    /// The window's grid as it is now.
    init(capturing window: Window) {
        let defaults = UserDefaults.standard
        mode = window.modeKey.map { defaults.string(forKey: $0) ?? window.defaultMode ?? "" }
        self.window = window
        columns = defaults.object(forKey: window.columnsKey) as? Int ?? window.defaultColumns
        rows = defaults.object(forKey: window.rowsKey) as? Int ?? window.defaultRows
        columnSplits = defaults.dictionary(forKey: window.columnSplitsKey) as? [String: [Double]] ?? [:]
        rowSplits = defaults.dictionary(forKey: window.rowSplitsKey) as? [String: [Double]] ?? [:]
    }

    /// Makes it the window's grid; the grids follow their settings (see `Workspace.gridLayoutLoads`).
    func apply(to window: Window) {
        let defaults = UserDefaults.standard
        if let key = window.modeKey, let mode { defaults.set(mode, forKey: key) }
        defaults.set(columns, forKey: window.columnsKey)
        defaults.set(rows, forKey: window.rowsKey)
        defaults.set(columnSplits, forKey: window.columnSplitsKey)
        defaults.set(rowSplits, forKey: window.rowSplitsKey)
    }

    /// The same columns, rows (and Charts window grid) as these; the lines aren't compared.
    func sameSize(mode: String?, columns: Int, rows: Int) -> Bool {
        self.mode == mode && self.columns == columns && self.rows == rows
    }

    /// "4×2", or "All Charts (6×3)".
    var label: String {
        mode == SecondaryCharts.Layout.all.rawValue ? (window?.chartsWin ?? .first).allLabel : "\(columns)×\(rows)"
    }
}

extension Workspace {
    /// ⇧-click on a layout number: the window's grid as it is, saved under `slot`.
    func saveGridLayout(_ slot: Int, in window: GridLayout.Window, broker: Broker) {
        let layout = GridLayout(capturing: window)
        gridLayouts[window, default: [:]][slot] = layout
        activeGridLayout[window] = slot
        broker.say("\(window.messagePrefix)layout \(slot) saved, \(layout.label)")
    }

    /// A click on a layout number, or ⇧1–5: the layout saved under `slot` back (with none, a beep).
    func pickGridLayout(_ slot: Int, in window: GridLayout.Window, broker: Broker) {
        let prefix = window.messagePrefix
        guard let layout = gridLayouts[window]?[slot] else {
            NSSound.beep()
            broker.say("\(prefix)no layout \(slot) yet: ⇧-click \(slot) in the layout numbers saves the charts' layout there")
            return
        }
        layout.apply(to: window)
        activeGridLayout[window] = slot
        gridLayoutLoads += 1
        broker.say("\(prefix)layout \(slot), \(layout.label)")
    }
}
