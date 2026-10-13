//
//  TradingShortcuts.swift
//  TWZ
//
//  App-wide order shortcuts, handled before any text field sees the key:
//  ⌥Z cancels the last order placed; ⌥< cancels every order in the selected chart's symbol,
//  stop loss and take profit included. Matched by character, so ⌥< is the < key on Nordic
//  keyboards (⌥⇧, on US ones).
//  In the main window (not while a sheet or popover is open): ⌘A sends the selected hotkey for
//  the selected chart's symbol (while typing in a text field it stays Select All), and ⌘S closes
//  100% of the selected chart's position at market.
//

import AppKit
import SwiftUI

struct TradingShortcuts: ViewModifier {
    @Environment(Broker.self) private var broker
    @Environment(Workspace.self) private var workspace
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard monitor == nil else { return }
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [broker, workspace] event in
                    let modifiers = event.modifierFlags.intersection([.option, .command, .control, .shift])
                    if modifiers == .command, let window = event.window, window === NSApp.mainWindow,
                       window.attachedSheet == nil {
                        let symbol = workspace.selectedChart.symbol
                        switch event.charactersIgnoringModifiers?.lowercased() {
                        case "a":
                            if window.firstResponder is NSTextView { return event }
                            if let hotkey = workspace.selectedHotkey {
                                broker.run(hotkey, symbol: symbol)
                            } else {
                                NSSound.beep()
                            }
                        case "s": broker.run(.closeAllMarket, symbol: symbol)
                        default: return event
                        }
                        return nil
                    }
                    guard event.modifierFlags.intersection([.option, .command, .control]) == .option else { return event }
                    switch event.charactersIgnoringModifiers?.lowercased() {
                    case "z": broker.cancelLastOrder()
                    case "<": broker.cancelOrders(for: workspace.selectedChart.symbol)
                    default: return event
                    }
                    return nil
                }
            }
            .onDisappear {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
            }
    }
}
