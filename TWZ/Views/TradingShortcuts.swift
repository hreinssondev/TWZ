//
//  TradingShortcuts.swift
//  TWZ
//
//  App-wide order shortcuts, handled before any text field sees the key.
//  The ones that send orders (order keys, a hotkey's own shortcut, ⌘⇧↩, ⌥⌘⇧↩, ⌘⌫) go to IB only with KEYS ON, ⌘ and
//  the Globe (fn) key turning it on and off (see `Workspace.orderShortcutsOn`); with KEYS off, SIM, as at every
//  launch, the same shortcuts trade what-if positions instead (simulated, never sent to IB, see `Broker.runSim`;
//  ⌘⌫ closes the what-if trade), and the Positions column shows the what-if trades (real positions with KEYS ON).
//  Cancelling (⌘A, ⌘Z, ⌥Z, ⌥<) works on real orders either way.
//  ⌥Z cancels the last order placed; ⌥< cancels every order in the selected chart's symbol,
//  stop loss and take profit included. Matched by character, so ⌥< is the < key on Nordic
//  keyboards (⌥⇧, on US ones).
//  In the main window (not while a sheet or popover is open), for the selected chart's symbol:
//  a hotkey's own keyboard shortcut sends that hotkey; ⌘⇧↩ sends the selected hotkey; ⌘↩ makes the
//  selected chart fast or not, so it keeps tick-by-tick trades once deselected (see
//  `Workspace.fastChartIDs`); ⌘A, like ⌥<,
//  cancels every order in the symbol, stop loss and take profit included (with no chart selected, the last
//  order placed, as ⌘Z); ⌘⌫ does too, then closes
//  the whole position at market; both also remove the symbol's ⌃-click what-if, and ⌘⇧⌫ removes just that; ⌘Z, like ⌥Z, cancels the last order placed; ⌥⇧ and a color's letter
//  (R, G, B, Y, O, P, M, W, K khaki, I pink, N brown, F turquoise, L lime) colors the stock (see `StockColor`), ⌥⇧⌫ takes it off.
//  While typing in a text field, ⌘↩ / ⌘⇧↩ do nothing, ⌘A / ⌘⌫ / ⌘Z stay Select All / delete to the
//  line's start / Undo, and shortcuts without ⌘, ⌃ or ⌥ (other than F-keys) type.
//  ⌃⌥⇧1 / 2 / 3 / 4 sells (shorts) a what-if trade (simulated, see `SimTrades.swift`) of $1,000 / $2,000 /
//  $3,000 / 85% of the buying power in the selected chart's symbol (⌥⇧1–4 no longer buys one: ⌥⇧ and
//  numbers are timeframes). Matched by key, number row or keypad, whatever the keyboard layout types there.
//  ⌘R, ⇧R (outside a text field) or ⌘⇧R does what the top bar's Reset does.
//  ⌘⇧M switches the order numbers between dollars and a percent of the buying power (see `SizeMode`): KEYS $ or
//  KEYS % in the top bar.
//  ⌘⇧ and a list's letter (S Most Active $, L Top Losers, H AH Gainers, A Top Gainers, F Forex)
//  shows that list and loads it into the chart grid (see `ListPanel.takeUp`).
//  With the order shortcuts on, an order key (Settings › Order Keys, see `OrderKeys`) sends its order, once per
//  press (a held key doesn't send another): by default ⌘1–9 buys and ⌥⌘1–9 sells short that many steps of the
//  $ / % switch (see `SizeMode`) at the mid; a ⌘ number with neither an order key nor a hotkey beeps.
//  ⌥1 / 2 / 3 / 4 / 5 / 6 (or ⇧1–6 outside a text field, or ⌥⇧1–6) sets the account bar's timeframe, every main chart's, to 1m / 5m / 15m / 30m / 1h / D
//  (number row or keypad), also while typing, and puts back a chart whose own switch was changed.
//  ⌥0, or ⇧A outside a text field, gives every other chart in the grid the selected chart's view: zoom,
//  place and price scale (see `Workspace.matchViews`).
//  Nothing fires while a shortcut is being recorded. With no chart selected there's no symbol, so
//  everything but cancelling the last order (⌘A too) and Cancel All / Flatten All hotkeys does nothing.
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
                monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [broker, workspace] event in
                    if event.type == .keyUp { return event }
                    if ShortcutRecorder.isRecording { return event }
                    // ⌘ and the Globe (fn) key, pressed in either order, turn the shortcuts that send orders on
                    // or off. The keys go on to the rest of the app either way.
                    if event.type == .flagsChanged {
                        let flags = event.modifierFlags.intersection([.option, .command, .control, .shift, .function])
                        let wentDown = event.keyCode == 63 ? flags.contains(.function)
                            : (event.keyCode == 54 || event.keyCode == 55) && flags.contains(.command)
                        if wentDown, flags == [.command, .function], event.window?.attachedSheet == nil {
                            workspace.orderShortcutsOn.toggle()
                            broker.say(workspace.orderShortcutsOn ? "KEYS ON: order shortcuts go to IB, for real (⌘🌐: SIM)"
                                                                  : "SIM: order shortcuts trade what-if positions, nothing goes to IB (⌘🌐: KEYS ON)")
                        }
                        return event
                    }
                    let modifiers = event.modifierFlags.intersection([.option, .command, .control, .shift])
                    let inMainWindow = event.window.map { $0 === NSApp.mainWindow && $0.attachedSheet == nil } ?? false
                    /// An order: with KEYS ON for real, with them off (SIM) as a what-if trade (see `Broker.runSim`);
                    /// Positions shows the real positions or the what-if trades to match.
                    func place(_ hotkey: Hotkey) {
                        let real = workspace.orderShortcutsOn
                        UserDefaults.standard.set(!real, forKey: PositionsView.showsSimKey)
                        if real {
                            broker.run(hotkey, symbol: workspace.targetSymbol)
                        } else {
                            broker.runSim(hotkey, symbol: workspace.targetSymbol)
                        }
                    }
                    // An order key (Settings › Order Keys): its order, once per press (a held key doesn't send another).
                    if inMainWindow, let orderKey = workspace.orderKey(for: KeyShortcut(event)) {
                        if event.window?.firstResponder is NSTextView, KeyShortcut(event).isPlain { return event }
                        if !event.isARepeat { place(orderKey) }
                        return nil
                    }
                    if inMainWindow, let hotkey = workspace.hotkeys.first(where: { $0.shortcut == KeyShortcut(event) }) {
                        if event.window?.firstResponder is NSTextView, KeyShortcut(event).isPlain { return event }
                        if !event.isARepeat { place(hotkey) }
                        return nil
                    }
                    let isReturn = event.keyCode == 36 || event.keyCode == 76      // Return or keypad Enter
                    // ⌘⇧↩: the selected hotkey button's order, or with none the order pad's, bought; ⌥⌘⇧↩ sells the pad's
                    // (see `OrderPad`). A symbol still being typed isn't the chart's yet.
                    if modifiers == [.command, .shift] || modifiers == [.option, .command, .shift],
                       isReturn, inMainWindow, let window = event.window {
                        if window.firstResponder is NSTextView { return event }
                        if !event.isARepeat { place(workspace.activeHotkey(selling: modifiers.contains(.option))) }
                        return nil
                    }
                    // ⌃⌥⇧1–4 sells a what-if trade in the selected chart's symbol (⌥⇧ and numbers are timeframes).
                    if inMainWindow, modifiers == [.control, .option, .shift], let size = SimSize(keyCode: event.keyCode) {
                        let symbol = workspace.targetSymbol
                        if symbol.isEmpty {
                            NSSound.beep()
                        } else {
                            broker.placeSim("SELL", size, symbol: symbol)
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
                    // ⇧R (outside a text field) or ⌘⇧R: the top bar's Reset, as ⌘R.
                    if inMainWindow, modifiers == .shift || modifiers == [.command, .shift],
                       event.charactersIgnoringModifiers?.lowercased() == "r" {
                        if modifiers == .shift, event.window?.firstResponder is NSTextView { return event }
                        workspace.resetToGainers()
                        return nil
                    }
                    // ⌘⇧M: the order numbers in dollars or a percent of the buying power (see `SizeMode`).
                    if inMainWindow, modifiers == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "m" {
                        if !event.isARepeat {
                            let next: SizeMode = SizeMode.current == .dollars ? .percent : .dollars
                            UserDefaults.standard.set(next.rawValue, forKey: SizeMode.storageKey)
                            broker.say(next == .dollars ? "KEYS $: the numbers are dollars, 1 is $1,000, 9 is $9,000"
                                                        : "KEYS %: the numbers are a share of the buying power, 1 is 20%, 4 is 80% (5–9 none)")
                        }
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
                    // ⌘ numbers are the order keys' and hotkeys' (above): one with neither does nothing.
                    if inMainWindow, modifiers == .command, OrderKeys.number(keyCode: event.keyCode) != nil {
                        NSSound.beep()
                        broker.say("\(KeyShortcut(event).display) has no order key or hotkey (Settings › Order Keys)")
                        return nil
                    }
                    // ⌥1–6, ⇧1–6 (outside a text field) or ⌥⇧1–6: the account bar's timeframe; ChartGrid follows it.
                    // Set again too, so a chart whose own switch was changed goes back to it.
                    if modifiers == .option || modifiers == .shift || modifiers == [.option, .shift],
                       inMainWindow, let timeframe = Timeframe(keyCode: event.keyCode) {
                        if modifiers == .shift, event.window?.firstResponder is NSTextView { return event }
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
                            if !workspace.isChartSelected {
                                // No chart selected: the last order placed, as ⌘Z and ⌥Z.
                                broker.cancelLastOrder()
                            } else if symbol.isEmpty {
                                NSSound.beep()
                            } else {
                                workspace.whatIfs[symbol] = nil
                                broker.cancelOrders(for: symbol)
                            }
                        case "⌫":
                            if typing { return event }
                            // KEYS ON: the real position; SIM (KEYS off): the what-if trade.
                            let s = symbol.uppercased()
                            if symbol.isEmpty {
                                NSSound.beep()
                            } else if workspace.orderShortcutsOn {
                                workspace.whatIfs[symbol] = nil
                                UserDefaults.standard.set(false, forKey: PositionsView.showsSimKey)
                                broker.closePosition(symbol)
                            } else if broker.simPositions[s] == nil {
                                NSSound.beep()
                                broker.say("SIM: no what-if trade in \(s) to close (KEYS ON, ⌘🌐, closes the real position)")
                            } else {
                                workspace.whatIfs[symbol] = nil
                                UserDefaults.standard.set(true, forKey: PositionsView.showsSimKey)
                                broker.closeSimAtMarket(s)
                            }
                        case "z":
                            if typing { return event }
                            broker.cancelLastOrder()
                        case "r":
                            // The top bar's Reset.
                            workspace.resetToGainers()
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
    /// The 1–6 keys, on the number row or the keypad: 1m, 5m, 15m, 30m, 1h, D.
    init?(keyCode: UInt16) {
        switch keyCode {
        case 18, 83: self = .m1
        case 19, 84: self = .m5
        case 20, 85: self = .m15
        case 21, 86: self = .m30
        case 23, 87: self = .h1
        case 22, 88: self = .d1
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
        if command, shift, !option, !control, k == "m" {
            return "⌘⇧M switches the order numbers between $ and %"
        }
        if command, option, shift, !control, keyCode == 36 || keyCode == 76 {
            return "⌥⌘⇧↩ sells the order pad's order"
        }
        if shift, !command, !option, !control, k == "r" {
            return "⇧R resets the chart grid, as the top bar's Reset"
        }
        if command, shift, !option, !control, k == "r" {
            return "⌘⇧R resets the chart grid, as the top bar's Reset"
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
            if k == "r" { return "⌘R resets the chart grid, as the top bar's Reset" }
            if ["q", "w", "h", "m", ",", "c", "v", "x"].contains(k) { return "\(display) is a standard macOS shortcut" }
        }
        if option, !command, !control, k == "z" || k == "<" { return "\(display) cancels orders" }
        if option, !shift, !command, !control, keyCode == 29 || keyCode == 82 {
            return "⌥0 gives every chart the selected chart's view"
        }
        if shift, !option, !command, !control, k == "a" {
            return "⇧A gives every chart the selected chart's view"
        }
        if option || shift, !command, !control, let timeframe = Timeframe(keyCode: keyCode) {
            return "\(display) sets every chart to \(timeframe.rawValue)"
        }
        if control, option, shift, !command, SimSize.keyCodes.contains(keyCode) {
            return "\(display) sells a what-if trade"
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
