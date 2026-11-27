//
//  ChartsWindowSidePanel.swift
//  TWZ
//
//  A Charts window's side panel (its top bar's P): the main window's right side beside its charts, two lists over
//  Orders / Positions / Round trips, each as in the main window. The lists are its own (their own scanners and
//  columns, kept per window); their load button switches this window's list, and a row clicked loads into this
//  window's selected chart (see `SecondaryChartsView.pick`). The ┃ and ━ between them drag, double-click resets.
//

import SwiftUI

extension ChartsWin {
    /// A side panel list's id (its scanner and settings are kept by it): "charts1-list-left", say.
    func sidePanelList(_ side: String) -> String { "charts\(rawValue)-list-\(side)" }
    static func isSidePanelList(_ panelId: String) -> Bool { panelId.hasPrefix("charts") }
}

struct ChartsWindowSidePanel: View {
    let win: ChartsWin
    let onPick: (String) -> Void
    @AppStorage private var listSplit: Double
    @AppStorage private var ordersHeight: Double

    private static let gap: CGFloat = 4
    private static let minListWidth: CGFloat = 100
    private static let minListsHeight: CGFloat = 160
    private static let minOrdersHeight: CGFloat = 80
    private static let defaultOrdersHeight = 220.0

    init(win: ChartsWin, onPick: @escaping (String) -> Void) {
        self.win = win
        self.onPick = onPick
        _listSplit = AppStorage(wrappedValue: 0.5, win.key("chartsWindowListSplit"))
        _ordersHeight = AppStorage(wrappedValue: Self.defaultOrdersHeight, win.key("chartsWindowOrdersHeight"))
    }

    var body: some View {
        GeometryReader { geo in
            let gap = Self.gap
            let listsWidth = geo.size.width - gap
            let leftRange = Self.minListWidth...max(Self.minListWidth, listsWidth - Self.minListWidth)
            let leftWidth = min(max(listsWidth * listSplit, leftRange.lowerBound), leftRange.upperBound)
            let ordersRange = Self.minOrdersHeight...max(Self.minOrdersHeight, geo.size.height - gap - Self.minListsHeight)
            let orders = min(max(ordersHeight, ordersRange.lowerBound), ordersRange.upperBound)
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    ListPanel(panelId: win.sidePanelList("left"), defaultScanner: .gainers, chartsWin: win, onPick: onPick)
                        .frame(width: leftWidth)
                    ResizeHandle(resizes: .horizontal, thickness: gap, current: leftWidth, range: leftRange,
                                 onChange: { listSplit = $0 / listsWidth }, onReset: { listSplit = 0.5 })
                    ListPanel(panelId: win.sidePanelList("right"), defaultScanner: .dollarVolume, chartsWin: win, onPick: onPick)
                }
                ResizeHandle(resizes: .vertical, thickness: gap, current: orders, range: ordersRange, inverted: true,
                             onChange: { ordersHeight = $0 }, onReset: { ordersHeight = Self.defaultOrdersHeight })
                OrdersPanel()
                    .frame(height: orders)
            }
        }
    }
}
