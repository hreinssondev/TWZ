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

    var body: some Scene {
        WindowGroup {
            ContentView()
                .modifier(TradingShortcuts())
                .environment(broker)
                .environment(workspace)
                .preferredColorScheme(.dark)
                .onAppear {
                    broker.registerCharts(workspace.charts)
                    broker.connect()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowBackgroundDragBehavior(.enabled)
        .defaultSize(width: 1600, height: 1000)
    }
}
