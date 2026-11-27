//
//  ChartsWindowSidePanel.swift
//  TWZ
//
//  A Charts window's side panel (its top bar's P): the main window's right side beside its charts, one list over
//  Orders / Positions / Round trips, each as in the main window. The list follows the window's own as it switches
//  (⌘⇧ and a list's letter, or its top bar's menu); its load button switches the window to the list it shows, and a
//  row clicked loads into this window's selected chart (see `SecondaryChartsView.pick`). The ━ above Orders drags,
//  double-click resets.
//

import SwiftUI

extension ChartsWin {
    /// A side panel list's id (its scanner and settings are kept by it): "charts1-list-single", say.
    func sidePanelList(_ side: String) -> String { "charts\(rawValue)-list-\(side)" }
    static func isSidePanelList(_ panelId: String) -> Bool { panelId.hasPrefix("charts") }
}

struct ChartsWindowSidePanel: View {
    @Environment(Workspace.self) private var workspace
    let win: ChartsWin
    let onPick: (String) -> Void
    @AppStorage private var ordersHeight: Double

    private static let gap: CGFloat = 4
    private static let minListsHeight: CGFloat = 160
    private static let minOrdersHeight: CGFloat = 80
    private static let defaultOrdersHeight = 220.0

    init(win: ChartsWin, onPick: @escaping (String) -> Void) {
        self.win = win
        self.onPick = onPick
        _ordersHeight = AppStorage(wrappedValue: Self.defaultOrdersHeight, win.key("chartsWindowOrdersHeight"))
    }

    var body: some View {
        GeometryReader { geo in
            let gap = Self.gap
            let ordersRange = Self.minOrdersHeight...max(Self.minOrdersHeight, geo.size.height - gap - Self.minListsHeight)
            let orders = min(max(ordersHeight, ordersRange.lowerBound), ordersRange.upperBound)
            let list = workspace.chartsWindow(win).list
            VStack(spacing: 0) {
                ListPanel(panelId: win.sidePanelList("single"), defaultScanner: list, chartsWin: win, onPick: onPick, follows: list)
                ResizeHandle(resizes: .vertical, thickness: gap, current: orders, range: ordersRange, inverted: true,
                             onChange: { ordersHeight = $0 }, onReset: { ordersHeight = Self.defaultOrdersHeight })
                OrdersPanel()
                    .frame(height: orders)
            }
        }
    }
}
