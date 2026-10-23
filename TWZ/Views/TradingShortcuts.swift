//
//  TradingShortcuts.swift
//  TWZ
//
//  App-wide order shortcuts, handled before any text field sees the key:
//  ⌥Z cancels the last order placed; ⌥< cancels every order in the selected chart's symbol,
//  stop loss and take profit included. Matched by character, so ⌥< is the < key on Nordic
//  keyboards (⌥⇧, on US ones).
//  In the main window (not while a sheet or popover is open), for the selected chart's symbol:
//  a hotkey's own keyboard shortcut sends that hotkey; ⌘⇧↩ sends the selected hotkey; ⌘↩ turns the
//  selected chart's tick-by-tick streams on or off (see `Workspace.fastChartIDs`); ⌘A, like ⌥<,
//  cancels every order in the symbol, stop loss and take profit included; ⌘S closes 100% of the
//  position at market; ⌘Z, like ⌥Z, cancels the last order placed.
//  While typing in a text field, ⌘↩ / ⌘⇧↩ do nothing, ⌘A / ⌘Z stay Select All / Undo, and shortcuts
//  without ⌘, ⌃ or ⌥ (other than F-keys) type.
//  Nothing fires while a shortcut is being recorded. With no chart selected there's no symbol, so
//  everything but cancelling the last order (and Cancel All / Flatten All hotkeys) does nothing.
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
                    if ShortcutRecorder.isRecording { return event }
                    let modifiers = event.modifierFlags.intersection([.option, .command, .control, .shift])
                    let inMainWindow = event.window.map { $0 === NSApp.mainWindow && $0.attachedSheet == nil } ?? false
                    if inMainWindow, let hotkey = workspace.hotkeys.first(where: { $0.shortcut == KeyShortcut(event) }) {
                        let shortcut = KeyShortcut(event)
                        let typing = event.window?.firstResponder is NSTextView
                        if typing, !shortcut.command, !shortcut.option, !shortcut.control, !shortcut.isFunctionKey {
                            return event
                        }
                        broker.run(hotkey, symbol: workspace.targetSymbol)
                        return nil
                    }
                    let isReturn = event.keyCode == 36 || event.keyCode == 76      // Return or keypad Enter
                    // ⌘⇧↩: a symbol still being typed isn't the chart's yet.
                    if modifiers == [.command, .shift], isReturn, inMainWindow, let window = event.window {
                        if window.firstResponder is NSTextView { return event }
                        if let hotkey = workspace.selectedHotkey {
                            broker.run(hotkey, symbol: workspace.targetSymbol)
                        } else {
                            NSSound.beep()
                        }
                        return nil
                    }
                    if modifiers == .command, inMainWindow, let window = event.window {
                        let symbol = workspace.targetSymbol
                        let typing = window.firstResponder is NSTextView
                        // ⌘↩: only the four charts stream tick by tick, so a gainer chart just beeps.
                        if isReturn {
                            if typing { return event }
                            let chart = workspace.selectedChart
                            if workspace.isChartSelected, !chart.isCompact {
                                workspace.fastChartIDs.formSymmetricDifference([chart.id])
                            } else {
                                NSSound.beep()
                            }
                            return nil
                        }
                        switch event.charactersIgnoringModifiers?.lowercased() {
                        case "a":
                            if typing { return event }
                            if symbol.isEmpty { NSSound.beep() } else { broker.cancelOrders(for: symbol) }
                        case "s": broker.run(.closeAllMarket, symbol: symbol)
                        case "z":
                            if typing { return event }
                            broker.cancelLastOrder()
                        default: return event
                        }
                        return nil
                    }
                    guard event.modifierFlags.intersection([.option, .command, .control]) == .option else { return event }
                    switch event.charactersIgnoringModifiers?.lowercased() {
                    case "z": broker.cancelLastOrder()
                    case "<":
                        let symbol = workspace.targetSymbol
                        if symbol.isEmpty { NSSound.beep() } else { broker.cancelOrders(for: symbol) }
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

extension KeyShortcut {
    init(_ event: NSEvent) {
        let flags = event.modifierFlags
        let function = Self.functionKeys[event.keyCode]
        self.init(keyCode: event.keyCode,
                  key: function ?? Self.named[event.keyCode] ?? (event.charactersIgnoringModifiers ?? "?").uppercased(),
                  command: flags.contains(.command), option: flags.contains(.option),
                  control: flags.contains(.control), shift: flags.contains(.shift),
                  isFunctionKey: function != nil)
    }

    /// Why this shortcut can't be used, if it's one the app or macOS already uses.
    var reservedFor: String? {
        let k = key.lowercased()
        if command, !option, !control {
            if keyCode == 36 || keyCode == 76 {
                return shift ? "⌘⇧↩ sends the selected hotkey" : "⌘↩ turns the selected chart's tick-by-tick on or off"
            }
            if k == "a" { return "⌘A cancels the symbol's orders" }
            if k == "s" { return "⌘S closes 100% at market" }
            if k == "z" { return "⌘Z cancels the last order" }
            if ["q", "w", "h", "m", ",", "c", "v", "x"].contains(k) { return "\(display) is a standard macOS shortcut" }
        }
        if option, !command, !control, k == "z" || k == "<" { return "\(display) cancels orders" }
        return nil
    }

    private static let functionKeys: [UInt16: String] = [
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
        106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
    ]

    private static let named: [UInt16: String] = [
        49: "Space", 36: "↩", 76: "⌤", 48: "⇥", 123: "←", 124: "→", 125: "↓", 126: "↑",
        115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
    ]
}
