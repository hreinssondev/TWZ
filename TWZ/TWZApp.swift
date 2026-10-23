//
//  TWZApp.swift
//  TWZ
//
//  Created by H on 10/10/2026.
//

import SwiftUI

@main
struct TWZApp: App {
    @State private var broker = Broker()
    @State private var workspace = Workspace()

    init() {
        AppearancePresets.seedIfNeeded()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .modifier(TradingShortcuts())
                .modifier(ClickToUnfocus())
                .modifier(ChartsWindowShortcut())
                .environment(broker)
                .environment(workspace)
                .preferredColorScheme(.dark)
                .onAppear {
                    broker.registerCharts(workspace.charts + workspace.secondaryCharts + workspace.mainGainerCharts)
                    broker.setFastCharts(workspace.fastChartIDs)
                    broker.connect()
                }
                .onChange(of: workspace.fastChartIDs) { _, ids in broker.setFastCharts(ids) }
                .onChange(of: workspace.selectedChartID, initial: true) { _, id in
                    broker.setSelectedChart(id)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowBackgroundDragBehavior(.enabled)
        .defaultSize(width: 1600, height: 1000)

        Window(SecondaryCharts.windowTitle, id: SecondaryCharts.windowID) {
            SecondaryChartsView()
                .environment(broker)
                .environment(workspace)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .windowBackgroundDragBehavior(.enabled)
        .defaultSize(width: 1400, height: 900)
    }
}
