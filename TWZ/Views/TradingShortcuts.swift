//
//  TradingShortcuts.swift
//  TWZ
//
//  App-wide order shortcuts, handled before any text field sees the key.
//  The ones that send orders (a hotkey's own shortcut, ⌘⇧↩, ⌘⌫) work only once ⌘ and the Globe (fn) key
//  turn them on, until pressed again; they're off at every launch (see `Workspace.orderShortcutsOn`). While off they
//  beep and say so. Cancelling (⌘A, ⌘Z, ⌥Z, ⌥<) and what-if trades always work.
//  ⌥Z cancels the last order placed; ⌥< cancels every order in the selected chart's symbol,
//  stop loss and take profit included. Matched by character, so ⌥< is the < key on Nordic
//  keyboards (⌥⇧, on US ones).
//  In the main window (not while a sheet or popover is open), for the selected chart's symbol:
//  a hotkey's own keyboard shortcut sends that hotkey; ⌘⇧↩ sends the selected hotkey; ⌘↩ makes the
//  selected chart fast or not, so it keeps tick-by-tick trades once deselected (see
//  `Workspace.fastChartIDs`); ⌘A, like ⌥<,
//  cancels every order in the symbol, stop loss and take profit included; ⌘⌫ does too, then closes
//  the whole position at market; both also remove the symbol's ⌃-click what-if, and ⌘⇧⌫ removes just that; ⌘Z, like ⌥Z, cancels the last order placed; ⌥⇧ and a color's letter
//  (R, G, B, Y, O, P, M, W, K khaki, I pink, N brown, F turquoise, L lime) colors the stock (see `StockColor`), ⌥⇧⌫ takes it off.
//  While typing in a text field, ⌘↩ / ⌘⇧↩ do nothing, ⌘A / ⌘⌫ / ⌘Z stay Select All / delete to the
//  line's start / Undo, and shortcuts without ⌘, ⌃ or ⌥ (other than F-keys) type.
//  ⌥⇧1 / 2 / 3 / 4 buys a what-if trade (simulated, see `SimTrades.swift`) of $1,000 / $2,000 / $3,000 /
//  85% of the buying power in the selected chart's symbol; ⌃⌥⇧1–4 sells (shorts) the same. Matched by
//  key, number row or keypad, whatever the keyboard layout types there.
//  ⌘⇧ and a list's letter (T or S Most Active $, L Top Losers, H AH Gainers, M or A Top Gainers, F Forex)
//  shows that list and loads it into the chart grid (see `ListPanel.takeUp`).
//  ⌥1 / 2 / 3 / 4 / 5 sets the account bar's timeframe, every main chart's, to 1m / 5m / 15m / 1h / D
//  (number row or keypad), also while typing, and puts back a chart whose own switch was changed.
//  ⌥0, or ⇧A outside a text field, gives every other chart in the grid the selected chart's view: zoom,
//  place and price scale (see `Workspace.matchViews`). ⇧1–5 outside a text field picks a saved scale,
//  as clicking its number in the top bar does (see `Workspace.pickScale`).
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
                monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [broker, workspace] event in
                    if ShortcutRecorder.isRecording { return event }
                    // ⌘ and the Globe (fn) key, pressed in either order, turn the shortcuts that send orders on
                    // or off. The keys go on to the rest of the app either way.
                    if event.type == .flagsChanged {
                        let flags = event.modifierFlags.intersection([.option, .command, .control, .shift, .function])
                        let wentDown = event.keyCode == 63 ? flags.contains(.function)
                            : (event.keyCode == 54 || event.keyCode == 55) && flags.contains(.command)
                        if wentDown, flags == [.command, .function], event.window?.attachedSheet == nil {
                            workspace.orderShortcutsOn.toggle()
                            broker.say(workspace.orderShortcutsOn ? "Order shortcuts on (⌘🌐 turns them off)"
                                                                  : "Order shortcuts off (⌘🌐 turns them on)")
                        }
                        return event
                    }
                    let modifiers = event.modifierFlags.intersection([.option, .command, .control, .shift])
                    let inMainWindow = event.window.map { $0 === NSApp.mainWindow && $0.attachedSheet == nil } ?? false
                    /// A shortcut that sends orders, pressed while they're off.
                    func refuse() -> NSEvent? {
                        NSSound.beep()
                        broker.say("Order shortcuts are off: ⌘🌐 turns them on")
                        return nil
                    }
                    if inMainWindow, let hotkey = workspace.hotkeys.first(where: { $0.shortcut == KeyShortcut(event) }) {
                        let shortcut = KeyShortcut(event)
                        let typing = event.window?.firstResponder is NSTextView
                        if typing, !shortcut.command, !shortcut.option, !shortcut.control, !shortcut.isFunctionKey {
                            return event
                        }
                        guard workspace.orderShortcutsOn else { return refuse() }
                        broker.run(hotkey, symbol: workspace.targetSymbol)
                        return nil
                    }
                    let isReturn = event.keyCode == 36 || event.keyCode == 76      // Return or keypad Enter
                    // ⌘⇧↩: a symbol still being typed isn't the chart's yet.
                    if modifiers == [.command, .shift], isReturn, inMainWindow, let window = event.window {
                        if window.firstResponder is NSTextView { return event }
                        guard workspace.orderShortcutsOn else { return refuse() }
                        if let hotkey = workspace.selectedHotkey {
                            broker.run(hotkey, symbol: workspace.targetSymbol)
                        } else {
                            NSSound.beep()
                        }
                        return nil
                    }
                    // ⌥⇧1–4 buys, ⌃⌥⇧1–4 sells a what-if trade in the selected chart's symbol.
                    if inMainWindow, modifiers == [.option, .shift] || modifiers == [.control, .option, .shift],
                       let size = SimSize(keyCode: event.keyCode) {
                        let symbol = workspace.targetSymbol
                        if symbol.isEmpty {
                            NSSound.beep()
                        } else {
                            broker.placeSim(modifiers.contains(.control) ? "SELL" : "BUY", size, symbol: symbol)
                        }
                        return nil
                    }
                    // ⌘⇧⌫ takes the selected chart's ⌃-click what-if off (as ⌘A and ⌘⌫ also do).
                    if modifiers == [.command, .shift], inMainWindow, event.keyCode == 51 {
                        if event.window?.firstResponder is NSTextView { return event }
                        let symbol = workspace.targetSymbol
                        if symbol.isEmpty || workspace.whatIfs.removeValue(forKey: symbol) == nil { NSSound.beep() }
                        return nil
                    }
                    // ⌘⇧ and a list's letter shows that list and loads it into the chart grid.
                    if inMainWindow, modifiers == [.command, .shift],
                       let kind = ScannerKind.forShortcut(event.charactersIgnoringModifiers?.lowercased() ?? "") {
                        workspace.listShortcut = Workspace.ListShortcut(kind: kind)
                        return nil
                    }
                    // ⌥⇧ and a color's letter colors the selected chart's stock; ⌥⇧⌫ takes its color off.
                    if modifiers == [.option, .shift], inMainWindow {
                        let color = StockColor(key: event.charactersIgnoringModifiers?.lowercased() ?? "")
                        if color != nil || event.keyCode == 51 {
                            let symbol = workspace.targetSymbol
                            if symbol.isEmpty { NSSound.beep() } else { workspace.setColor(color, of: symbol) }
                            return nil
                        }
                    }
                    // ⌥1–5 sets the account bar's timeframe; ChartGrid follows it. Set again too, so a chart
                    // whose own switch was changed goes back to it.
                    // ⇧1–5 outside a text field picks a saved scale, as clicking its number in the top bar does.
                    if modifiers == .shift, inMainWindow, let slot = ChartScale.slot(keyCode: event.keyCode) {
                        if event.window?.firstResponder is NSTextView { return event }
                        workspace.pickScale(slot, broker: broker)
                        return nil
                    }
                    // ⌥0, or ⇧A outside a text field: the other charts take the selected chart's view.
                    let matchKey = modifiers == .option && (event.keyCode == 29 || event.keyCode == 82)
                        || modifiers == .shift && event.charactersIgnoringModifiers?.lowercased() == "a"
                    if matchKey, inMainWindow {
                        if modifiers == .shift, event.window?.firstResponder is NSTextView { return event }
                        if workspace.isChartSelected, let chart = workspace.chart(id: workspace.selectedChartID), !chart.symbol.isEmpty {
                            workspace.matchViews(to: chart)
                            broker.say("Every chart follows \(chart.symbol)'s view")
                        } else {
                            NSSound.beep()
                        }
                        return nil
                    }
                    if modifiers == .option, inMainWindow, let timeframe = Timeframe(keyCode: event.keyCode) {
                        UserDefaults.standard.set(timeframe.rawValue, forKey: MainGrid.timeframeKey)
                        workspace.setMainTimeframe(timeframe, broker: broker)
                        return nil
                    }
                    if modifiers == .command, inMainWindow, let window = event.window {
                        let symbol = workspace.targetSymbol
                        let typing = window.firstResponder is NSTextView
                        if isReturn {
                            if typing { return event }
                            if workspace.isChartSelected {
                                workspace.fastChartIDs.formSymmetricDifference([workspace.selectedChartID])
                            } else {
                                NSSound.beep()
                            }
                            return nil
                        }
                        switch event.keyCode == 51 ? "⌫" : event.charactersIgnoringModifiers?.lowercased() {
                        case "a":
                            if typing { return event }
                            if symbol.isEmpty {
                                NSSound.beep()
                            } else {
                                workspace.whatIfs[symbol] = nil
                                broker.cancelOrders(for: symbol)
                            }
                        case "⌫":
                            if typing { return event }
                            // A what-if trade alone closes either way (see `Broker.closePosition`).
                            let s = symbol.uppercased()
                            let simOnly = (broker.positions[s].map { $0.quantity == 0 } ?? true) && broker.simPositions[s] != nil
                            if symbol.isEmpty {
                                NSSound.beep()
                            } else if !workspace.orderShortcutsOn, !simOnly {
                                return refuse()
                            } else {
                                workspace.whatIfs[symbol] = nil
                                broker.closePosition(symbol)
                            }
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

extension Timeframe {
    /// The 1–5 keys, on the number row or the keypad: 1m, 5m, 15m, 1h, D.
    init?(keyCode: UInt16) {
        switch keyCode {
        case 18, 83: self = .m1
        case 19, 84: self = .m5
        case 20, 85: self = .m15
        case 21, 86: self = .h1
        case 23, 87: self = .d1
        default: return nil
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
        if option, shift, !command, !control, keyCode == 51 || StockColor(key: k) != nil {
            return keyCode == 51 ? "⌥⇧⌫ takes the stock's color off" : "\(display) colors the stock"
        }
        if command, shift, !option, !control, let kind = ScannerKind.forShortcut(k) {
            return "\(display) shows the \(kind.rawValue) list"
        }
        if command, !option, !control {
            if keyCode == 36 || keyCode == 76 {
                return shift ? "⌘⇧↩ sends the selected hotkey" : "⌘↩ keeps the selected chart's tick-by-tick on or off"
            }
            if k == "a" { return "⌘A cancels the symbol's orders" }
            if keyCode == 51 { return shift ? "⌘⇧⌫ removes the what-if" : "⌘⌫ closes the position" }
            if k == "z" { return "⌘Z cancels the last order" }
            if ["q", "w", "h", "m", ",", "c", "v", "x"].contains(k) { return "\(display) is a standard macOS shortcut" }
        }
        if option, !command, !control, k == "z" || k == "<" { return "\(display) cancels orders" }
        if option, !shift, !command, !control, keyCode == 29 || keyCode == 82 {
            return "⌥0 gives every chart the selected chart's view"
        }
        if shift, !option, !command, !control, ChartScale.slot(keyCode: keyCode) != nil {
            return "\(display) picks a saved scale"
        }
        if shift, !option, !command, !control, k == "a" {
            return "⇧A gives every chart the selected chart's view"
        }
        if option, !shift, !command, !control, let timeframe = Timeframe(keyCode: keyCode) {
            return "\(display) sets every chart to \(timeframe.rawValue)"
        }
        if option, shift, !command, SimSize.keyCodes.contains(keyCode) {
            return "\(display) \(control ? "sells" : "buys") a what-if trade"
        }
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
