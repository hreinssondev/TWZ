//
//  ContentView.swift
//  TWZ
//
//  ┌──────────────── account bar ────────────────┐
//  │  chart 1  │  chart 2  │  list A  │  list B  │
//  │  chart 3  │  chart 4  │          │          │
//  ╞═══ drag handle (resizes) ═══╡   │          │
//  │      hotkeys (6×2)       ├────── orders ─────┤
//  └──────────────────────────┴──────────────────┘
//
//  The handle only splits the left column: charts above, hotkeys below. The hotkey buttons
//  keep a fixed size; only the free space around them changes, down to the height they need.
//  The right column (lists above a fixed-height orders panel) is unaffected.
//

import SwiftUI

struct ContentView: View {
    @Environment(Workspace.self) private var workspace
    @AppStorage("bottomRowHeight") private var bottomHeight: Double = 190
    @State private var dragStartHeight: Double?

    private static let minTopHeight: CGFloat = 240
    private static let ordersHeight: CGFloat = 190

    var body: some View {
        VStack(spacing: 0) {
            AccountBar()
            Divider()
            GeometryReader { geo in
                let gap: CGFloat = 6
                let minBottom = HotkeyPanel.minHeight
                let maxBottom = max(minBottom, geo.size.height - gap * 3 - Self.minTopHeight)
                let rowHeight = min(maxBottom, max(minBottom, bottomHeight))
                let sideWidth = (geo.size.width - gap * 3) / 3
                HStack(spacing: gap) {
                    VStack(spacing: 0) {
                        Grid(horizontalSpacing: gap, verticalSpacing: gap) {
                            GridRow {
                                ChartPane(chart: workspace.charts[0])
                                ChartPane(chart: workspace.charts[1])
                            }
                            GridRow {
                                ChartPane(chart: workspace.charts[2])
                                ChartPane(chart: workspace.charts[3])
                            }
                        }
                        resizeHandle(height: gap, current: rowHeight, range: minBottom...maxBottom)
                        HotkeyPanel()
                            .frame(height: rowHeight)
                    }
                    VStack(spacing: gap) {
                        HStack(spacing: gap) {
                            ListPanel(panelId: "list-left", defaultList: "Watchlist 1")
                            ListPanel(panelId: "list-right", defaultList: "Watchlist 2")
                        }
                        OrdersPanel()
                            .frame(height: Self.ordersHeight)
                    }
                    .frame(width: sideWidth)
                }
                .padding(gap)
            }
        }
        .frame(minWidth: 1200, minHeight: 760)
    }

    /// Thin grab strip in the gap between the charts and the hotkeys.
    private func resizeHandle(height: CGFloat, current: CGFloat, range: ClosedRange<CGFloat>) -> some View {
        Capsule()
            .fill(Color.primary.opacity(dragStartHeight == nil ? 0.15 : 0.35))
            .frame(width: 36, height: 3)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .contentShape(Rectangle())
            .pointerStyle(.rowResize)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = dragStartHeight ?? current
                        dragStartHeight = start
                        bottomHeight = min(range.upperBound, max(range.lowerBound, start - value.translation.height))
                    }
                    .onEnded { _ in dragStartHeight = nil }
            )
            .onTapGesture(count: 2) { bottomHeight = 190 }
    }
}
