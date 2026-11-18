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
                .modifier(SideColorsFromSettings())
                .environment(broker)
                .environment(workspace)
                .preferredColorScheme(.dark)
                .onAppear {
                    broker.registerCharts(workspace.mainCharts + workspace.secondaryCharts)
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
        .commands {
            // The app menu's Settings item, on ⌘I; it opens the sheet the account bar's gear opens.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { workspace.showsSettings = true }
                    .keyboardShortcut("i")
            }
        }

        Window(SecondaryCharts.windowTitle, id: SecondaryCharts.windowID) {
            SecondaryChartsView()
                .modifier(SideColorsFromSettings())
                .environment(broker)
                .environment(workspace)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .windowBackgroundDragBehavior(.enabled)
        .defaultSize(width: 1400, height: 900)
    }
}
