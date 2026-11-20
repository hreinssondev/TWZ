//
//  TWZApp.swift
//  TWZ
//
//  Created by H on 10/10/2026.
//

import AppKit
import SwiftUI

@main
struct TWZApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
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
                    appDelegate.broker = broker
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

/// Asks before quitting with positions open: they stay open at IB after the app quits, with nothing
/// here watching them.
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var broker: Broker?

    /// Where every chart is, for the next launch (see `ChartViews`).
    func applicationWillTerminate(_ notification: Notification) {
        broker?.saveChartViews()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let broker, broker.state == .connected else { return .terminateNow }
        let open = broker.positions.values.filter { $0.quantity != 0 }.sorted { $0.symbol < $1.symbol }
        guard !open.isEmpty else { return .terminateNow }
        let kind = broker.isLiveAccount ? "LIVE" : "paper"
        let alert = NSAlert()
        alert.alertStyle = broker.isLiveAccount ? .critical : .warning
        alert.messageText = "Quit with \(open.count) \(kind) position\(open.count == 1 ? "" : "s") open?"
        let list = open.prefix(8).map { "\($0.quantity > 0 ? "LONG" : "SHORT") \(Fmt.shares(abs($0.quantity), groupedFrom: 10_000)) \($0.symbol)" }
        alert.informativeText = list.joined(separator: "\n") + (open.count > 8 ? "\n…and \(open.count - 8) more" : "")
            + "\n\nThey stay open at IB after TWZ quits, and so do their orders. Until TWZ is back, nothing"
            + " keeps stop losses and take profits sized to the positions, and hotkeys and ⌘⌫ can't close them."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Quit").hasDestructiveAction = true
        return alert.runModal() == .alertFirstButtonReturn ? .terminateCancel : .terminateNow
    }
}
