//
//  Layouts.swift
//  TWZ
//
//  Saved layouts (Settings › Layouts): the main window as it is, kept under a name and brought back
//  with Load. A layout holds the panels' sizes (charts ↕ hotkeys, the right column, the lists, Orders /
//  Positions / Round trips), one list or two and their column widths, the chart grid's size, column and
//  row lines, zoom and space, and every Appearance setting (colors, line styles, indicators, price
//  axis), as an Appearance preset does. What's shown stays as it is on Load: the charts' stocks and
//  timeframes, the list the grid follows and each list's scanner.
//

import Foundation

nonisolated struct SavedLayout: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var saved = Date()
    /// The layout's settings by key, as a property list (see `Layouts.keys`).
    var values: Data
}

enum Layouts {
    static let storageKey = "savedLayouts"

    /// The settings a layout holds; anything else (stocks, scanners, timeframes, hotkeys, filters…) stays
    /// as it is on Load.
    static let keys: [String] = {
        var keys = [
            "bottomRowHeight", "sideWidth", "listSplit", ListPanel.singleKey, "ordersHeight",
            "ordersWidth", "ordersStacked", "positionsRow", "roundTripsSplit",
            MainGrid.columnsKey, MainGrid.rowsKey, MainGrid.zoomKey,
            "mainChartColumnSplits", "mainChartRowSplits", RightSpace.key,
        ]
        for panel in ["list-left", "list-right", "list-single"] {
            keys += ["listColumn.last.\(panel)", "listColumn.change.\(panel)", "listColumn.recent.\(panel)"]
        }
        return keys + AppearanceDefaults.keys
    }()

    /// Marks a layout saved with its Appearance settings; older layouts leave the colors as they are.
    private static let appearanceKey = "layoutHasAppearance"

    /// The keys loading `values` sets.
    static func keys(loading values: [String: Any]) -> [String] {
        values[appearanceKey] != nil ? keys : keys.filter { !AppearanceDefaults.keys.contains($0) }
    }

    /// The current layout's settings.
    static func capture() -> Data? {
        var values: [String: Any] = [appearanceKey: true]
        for k in keys {
            if let v = UserDefaults.standard.object(forKey: k) { values[k] = v }
        }
        return try? PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0)
    }

    static func decode(_ data: Data) -> [String: Any]? {
        try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }
}

extension Workspace {
    /// Saves the main window as it is under `name`, or over the layout with id `replacing`.
    func saveLayout(name: String, replacing id: UUID? = nil) {
        saveMainGridPins()
        guard let values = Layouts.capture() else { return }
        if let id, let i = layouts.firstIndex(where: { $0.id == id }) {
            layouts[i].values = values
            layouts[i].saved = Date()
        } else {
            layouts.append(SavedLayout(name: name, values: values))
        }
    }

    /// Brings a saved layout back: its settings take over (any it doesn't hold go back to their
    /// default). The grid takes its size as with the Cols / Rows sliders; every chart keeps its stock.
    func loadLayout(_ layout: SavedLayout) {
        guard let values = Layouts.decode(layout.values) else { return }
        let defaults = UserDefaults.standard

        // The one-list button would otherwise move the right column as it changes (see `ContentView`).
        let singleKey = ListPanel.singleKey
        if (values[singleKey] as? Bool ?? false) != defaults.bool(forKey: singleKey) {
            layoutSkips.insert(singleKey)
        }
        for k in Layouts.keys(loading: values) {
            if let v = values[k] { defaults.set(v, forKey: k) } else { defaults.removeObject(forKey: k) }
        }
        layoutLoads += 1
    }
}
