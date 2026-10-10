//
//  ContentView.swift
//  TWZ
//
//  ┌──────────────── account bar ────────────────┐
//  │  chart 1  │  chart 2  │  list A  │  list B  │
//  │  chart 3  │  chart 4  │          │          │
//  ├────────── hotkeys (6×2) ─────────┬─ orders ─┤
//  └──────────────────────────────────┴──────────┘
//

import SwiftUI

struct ContentView: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        VStack(spacing: 0) {
            AccountBar()
            Divider()
            GeometryReader { geo in
                let gap: CGFloat = 6
                let bottomHeight = min(190, max(140, geo.size.height * 0.2))
                VStack(spacing: gap) {
                    HStack(spacing: gap) {
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
                        HStack(spacing: gap) {
                            ListPanel(panelId: "list-left", defaultList: "Watchlist 1")
                            ListPanel(panelId: "list-right", defaultList: "Watchlist 2")
                        }
                        .frame(width: (geo.size.width - gap * 3) / 3)
                    }
                    HStack(spacing: gap) {
                        HotkeyPanel()
                        OrdersPanel()
                            .frame(width: (geo.size.width - gap * 3) / 3)
                    }
                    .frame(height: bottomHeight)
                }
                .padding(gap)
            }
        }
        .frame(minWidth: 1200, minHeight: 760)
    }
}
