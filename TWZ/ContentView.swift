//
//  ContentView.swift
//  TWZ
//
//  ┌──── ●●● account bar (in the title bar) ──────┐
//  │  chart 1  │  chart 2  ┃  list A  ┃  list B  │
//  │ ──────────●────────── ┃          ┃          │
//  │  chart 3  │  chart 4  ┃          ┃          │
//  ╞═══ handle ════════════╡┃━━━━━ handle ━━━━━━━┥
//  │  hotkeys (6×2) │ NOK  ┃ orders ┃ filled ┃ pos │
//  └───────────────────────┴───────────────────────┘
//
//  Every ┃/═/━ separator is a drag handle (resize cursor on hover, double-click resets):
//  charts ↕ hotkeys, left column ↔ right column, list A ↔ list B, lists ↕ orders, and
//  the Orders / Filled / Positions columns ↕ round trips. The account bar's Cols / Rows sliders size
//  the chart grid, whose charts follow the top gainers (see `ChartGrid`); a ● where four charts meet
//  drags that column and row line together. The button beside a list's filters makes lists A and B
//  one list across their space (Top Gainers by default; it keeps its own scanner choice), or splits
//  them again, and moves the right column as far right as that allows. The hotkey buttons keep a
//  fixed size while there's
//  room (the free space around them changes); dragged shorter, they and the amount box shrink,
//  and dragged on down the hotkey row collapses, giving the charts the space (drag up to bring it back).
//

import SwiftUI

struct ContentView: View {
    @Environment(Workspace.self) private var workspace
    /// 0 = the hotkey row is collapsed.
    @AppStorage("bottomRowHeight") private var bottomHeight: Double = 190
    @AppStorage("sideWidth") private var storedSideWidth: Double = 0      // 0 = default (a third)
    @AppStorage("listSplit") private var listSplit: Double = 0.5          // left list's share of the lists
    @AppStorage(ListPanel.singleKey) private var singleList = false
    @AppStorage("ordersHeight") private var ordersHeight: Double = 190

    private static let gap: CGFloat = 6
    private static let minTopHeight: CGFloat = 240
    private static let minChartsWidth: CGFloat = 520
    /// The price columns take 188; the rest leaves room for a symbol.
    private static let minListWidth: CGFloat = 240
    /// The right column's narrowest with one list, which has room for symbols there; also what the
    /// Orders / Filled / Positions columns below need.
    private static let minSingleListSide: CGFloat = 386
    private static let minListsHeight: CGFloat = 160
    private static let minOrdersHeight: CGFloat = 80

    var body: some View {
        VStack(spacing: 0) {
            AccountBar()
            Divider()
            GeometryReader { geo in
                let gap = Self.gap
                let inner = CGSize(width: geo.size.width - gap * 2, height: geo.size.height - gap * 2)

                let minBottom = HotkeyPanel.minHeight
                let maxBottom = max(minBottom, inner.height - gap - Self.minTopHeight)
                let rowHeight = bottomHeight <= 0 ? 0 : clamp(bottomHeight, minBottom...maxBottom)

                let minSide = Self.minSideWidth(singleList: singleList)
                let maxSide = max(minSide, inner.width - gap - Self.minChartsWidth)
                let sideWidth = clamp(storedSideWidth > 0 ? storedSideWidth : (inner.width - gap) / 3, minSide...maxSide)

                let listsWidth = sideWidth - gap
                let leftListRange = Self.minListWidth...max(Self.minListWidth, listsWidth - Self.minListWidth)
                let leftListWidth = clamp(listsWidth * listSplit, leftListRange)

                let maxOrders = max(Self.minOrdersHeight, inner.height - gap - Self.minListsHeight)
                let ordersRange = Self.minOrdersHeight...maxOrders
                let ordersPanelHeight = clamp(ordersHeight, ordersRange)

                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        ChartGrid(gap: gap)
                        ResizeHandle(resizes: .vertical, thickness: gap, current: rowHeight,
                                     range: minBottom...maxBottom, inverted: true, collapsible: true,
                                     onChange: { bottomHeight = $0 }, onReset: { bottomHeight = 190 })
                        if rowHeight > 0 {
                            HotkeyPanel()
                                .frame(height: rowHeight)
                        }
                    }
                    ResizeHandle(resizes: .horizontal, thickness: gap, current: sideWidth,
                                 range: minSide...maxSide, inverted: true,
                                 onChange: { storedSideWidth = $0 }, onReset: { storedSideWidth = 0 })
                    VStack(spacing: 0) {
                        HStack(spacing: 0) {
                            if singleList {
                                ListPanel(panelId: "list-single", defaultScanner: .gainers)
                            } else {
                                ListPanel(panelId: "list-left", defaultScanner: .gainers)
                                    .frame(width: leftListWidth)
                                ResizeHandle(resizes: .horizontal, thickness: gap, current: leftListWidth,
                                             range: leftListRange,
                                             onChange: { listSplit = $0 / listsWidth }, onReset: { listSplit = 0.5 })
                                ListPanel(panelId: "list-right", defaultScanner: .dollarVolume)
                            }
                        }
                        ResizeHandle(resizes: .vertical, thickness: gap, current: ordersPanelHeight,
                                     range: ordersRange, inverted: true,
                                     onChange: { ordersHeight = $0 }, onReset: { ordersHeight = 190 })
                        OrdersPanel()
                            .frame(height: ordersPanelHeight)
                    }
                    .frame(width: sideWidth)
                }
                .padding(gap)
            }
        }
        // The title bar is hidden; the account bar takes its place, next to the window controls.
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 1200, minHeight: 760)
        // Switching between one list and two moves the right column as far right as it goes for that.
        .onChange(of: singleList) { _, single in storedSideWidth = Self.minSideWidth(singleList: single) }
    }

    /// The right column's narrowest: two lists need room for their symbols, one list less.
    private static func minSideWidth(singleList: Bool) -> CGFloat {
        singleList ? minSingleListSide : minListWidth * 2 + gap
    }

    private func clamp(_ value: Double, _ range: ClosedRange<CGFloat>) -> CGFloat {
        min(range.upperBound, max(range.lowerBound, value))
    }
}
