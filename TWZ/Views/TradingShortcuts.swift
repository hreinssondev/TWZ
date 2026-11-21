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
//  ⌘⇧ with two letters held together switches the trade mode (see `TradeMode`): S + H SHORT, L + O LONG,
//  both trading for real, out of SIM mode; S + I SIM mode (see `SimMode`), where every order shortcut trades
//  what-if positions instead. S, H and L alone (lists' letters too) wait a moment for the other letter first.
//  ⌘⇧ and a list's letter (S Most Active $, L Top Losers, H AH Gainers, A Top Gainers, F Forex)
//  shows that list and loads it into the chart grid (see `ListPanel.takeUp`).
//  With the order shortcuts on, an order key (Settings › Order Keys, see `OrderKeys`) sends its order, once per
//  press (a held key doesn't send another): by default ⌘1 / 2 / 3 / 4 buys $1,000 / $2,000 / $3,000 / 85% of
//  the buying power at the mid, ⌥⌘ and them sells short $1,000 / $2,000 / $3,000 / 80%, ⌥⌘5–9 a Mode order of
//  25% / 30% / 50% / 75% / 85%; a ⌘ number with neither an order key nor a hotkey beeps.
//  ⌥1 / 2 / 3 / 4 / 5 / 6 (or ⇧1–6 outside a text field, ⌥⇧1–6, or ⌘1–6 while the order shortcuts are off) sets the account bar's timeframe, every main chart's, to 1m / 5m / 15m / 30m / 1h / D
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

    /// What a two-letter ⌘⇧ shortcut switches to.
    private enum ChordTarget { case long, short, sim }
    /// The two-letter ⌘⇧ shortcuts, by either letter's key: the other letter's, and what they switch to.
    /// S + H SHORT, L + O LONG, S + I SIM (by position, as on a US keyboard).
    private static let chords: [UInt16: [(partner: CGKeyCode, target: ChordTarget)]] = [
        1: [(4, .short), (34, .sim)], 4: [(1, .short)],     // S, H
        34: [(1, .sim)],                                      // I
        37: [(31, .long)], 31: [(37, .long)],                 // L, O
    ]

    /// ⌘⇧ L+O / S+H: LONG / SHORT, trading for real (out of SIM mode, the Positions column back on the real
    /// positions); S+I: SIM mode, the Positions column on the what-if trades (see `SimMode`).
    private static func switchMode(to target: ChordTarget, broker: Broker) {
        let defaults = UserDefaults.standard
        let wasSim = SimMode.isOn
        switch target {
        case .sim:
            defaults.set(true, forKey: SimMode.storageKey)
            defaults.set(true, forKey: PositionsView.showsSimKey)
            if !wasSim {
                broker.say("SIM mode: order shortcuts trade what-if positions, nothing goes to IB (⌘⇧ L+O or S+H trades for real again)")
            }
        case .long, .short:
            defaults.set((target == .long ? TradeMode.long : .short).rawValue, forKey: TradeMode.storageKey)
            if wasSim {
                defaults.set(false, forKey: SimMode.storageKey)
                defaults.set(false, forKey: PositionsView.showsSimKey)
                broker.say("Real trading, \(target == .long ? "LONG" : "SHORT"): order shortcuts go to IB again")
            }
        }
    }
    /// How long S, H or L alone wait for the other letter before showing their list.
    private static let chordWait = 0.15
    private static var pendingList: DispatchWorkItem?
    /// Keys down now (by key code), from the key-down and key-up events seen.
    private static var heldKeys: Set<UInt16> = []

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard monitor == nil else { return }
                monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [broker, workspace] event in
                    // The letters held down, for the two-letter ⌘⇧ shortcuts.
                    if event.type == .keyUp {
                        Self.heldKeys.remove(event.keyCode)
                        return event
                    }
                    if event.type == .flagsChanged, !event.modifierFlags.contains(.command) { Self.heldKeys.removeAll() }
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
                    // ⌘1–6 switch timeframes while the order shortcuts are off, an order key or hotkey on one of them or not.
                    let timeframeKey = modifiers == .command && Timeframe(keyCode: event.keyCode) != nil
                    // An order key (Settings › Order Keys): with KEYS ON its order, once per press (a held key doesn't
                    // send another).
                    if inMainWindow, let orderKey = workspace.orderKey(for: KeyShortcut(event)), workspace.orderShortcutsOn || !timeframeKey {
                        if event.window?.firstResponder is NSTextView, KeyShortcut(event).isPlain { return event }
                        guard workspace.orderShortcutsOn else { return refuse() }
                        if !event.isARepeat { broker.run(orderKey, symbol: workspace.targetSymbol) }
                        return nil
                    }
                    if inMainWindow, workspace.orderShortcutsOn || !timeframeKey,
                       let hotkey = workspace.hotkeys.first(where: { $0.shortcut == KeyShortcut(event) }) {
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
                        // The selected hotkey button, or the order pad's order (see `OrderPad`).
                        broker.run(workspace.activeHotkey, symbol: workspace.targetSymbol)
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
                    // ⌘⇧ with two letters held together: S + H the SHORT trade mode, L + O the LONG one (see
                    // `TradeMode`), S + I SIM mode (see `SimMode`). S, H and L alone are lists' letters too: those
                    // wait a moment for the other letter before showing the list.
                    if inMainWindow, modifiers == [.command, .shift], let chords = Self.chords[event.keyCode] {
                        if event.isARepeat { return nil }
                        let chord = chords.first { Self.heldKeys.contains($0.partner)
                            || CGEventSource.keyState(.combinedSessionState, key: $0.partner) }
                        Self.heldKeys.insert(event.keyCode)
                        if let chord {
                            Self.pendingList?.cancel()
                            Self.pendingList = nil
                            Self.switchMode(to: chord.target, broker: broker)
                            return nil
                        }
                        if let kind = ScannerKind.forShortcut(event.charactersIgnoringModifiers?.lowercased() ?? "") {
                            Self.pendingList?.cancel()
                            let show = DispatchWorkItem { workspace.listShortcut = Workspace.ListShortcut(kind: kind) }
                            Self.pendingList = show
                            DispatchQueue.main.asyncAfter(deadline: .now() + Self.chordWait, execute: show)
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
                    // With the order shortcuts on, ⌘ numbers are the order keys' and hotkeys' (above): one with neither
                    // does nothing.
                    if inMainWindow, modifiers == .command, workspace.orderShortcutsOn, OrderKeys.number(keyCode: event.keyCode) != nil {
                        NSSound.beep()
                        broker.say("\(KeyShortcut(event).display) has no order key or hotkey (Settings › Order Keys)")
                        return nil
                    }
                    // ⌥1–6, ⇧1–6 (outside a text field) or ⌥⇧1–6, or ⌘1–6 while the order shortcuts are off: the
                    // account bar's timeframe; ChartGrid follows it. Set again too, so a chart whose own switch
                    // was changed goes back to it.
                    if modifiers == .option || modifiers == .shift || modifiers == [.option, .shift] || modifiers == .command,
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
                            // A what-if trade alone closes either way (see `Broker.closePosition`).
                            let s = symbol.uppercased()
                            // SIM mode: only ever the what-if trade (see `Broker.closePosition`).
                            let simOnly = SimMode.isOn
                                || (broker.positions[s].map { $0.quantity == 0 } ?? true) && broker.simPositions[s] != nil
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
        if command, shift, !option, !control, k == "o" {
            return "⌘⇧ with L and O held together switches to LONG"
        }
        if command, shift, !option, !control, k == "i" {
            return "⌘⇧ with S and I held together switches to SIM mode"
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
