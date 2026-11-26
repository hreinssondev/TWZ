//
//  SettingsView.swift
//  TWZ
//
//  Settings sheet: Connection (IB Gateway host/port/client, applied on reconnect),
//  Trading (what clicking a hotkey button does, and the keyboard shortcuts), Order Keys (every shortcut that
//  trades: the order keys, added and edited there, hotkey buttons' shortcuts, the fixed ones),
//  Appearance (candle and chart line colors, applied immediately) and Layouts (the main window's
//  layout saved under a name, loaded back; see `Layouts`).
//

import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("settingsTab") private var tab: Tab = .connection

    enum Tab: String, CaseIterable, Identifiable {
        case connection = "Connection"
        case trading = "Trading"
        case orderKeys = "Order Keys"
        case appearance = "Appearance"
        case layouts = "Layouts"
        var id: String { rawValue }

        var icon: String {
            switch self {
            case .connection: "network"
            case .trading: "keyboard"
            case .orderKeys: "command"
            case .appearance: "paintpalette"
            case .layouts: "rectangle.3.group"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Tab bar in the style of System Settings: icon above label, evenly spaced.
            HStack(spacing: 4) {
                ForEach(Tab.allCases) { t in
                    Button {
                        tab = t
                    } label: {
                        VStack(spacing: 3) {
                            Image(systemName: t.icon).font(.system(size: 18))
                            Text(t.rawValue).font(.system(size: 11))
                        }
                        .frame(width: 96, height: 50)
                        .foregroundStyle(tab == t ? Color.accentColor : Color.secondary)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(tab == t ? 0.1 : 0)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            Divider()

            switch tab {
            case .connection: ConnectionSettings()
            case .trading: TradingSettings()
            case .orderKeys: OrderKeysSettings()
            case .appearance: AppearanceSettings()
            case .layouts: LayoutSettings()
            }
        }
        .frame(width: 560, height: 520)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
    }
}

// MARK: - Connection

private struct ConnectionSettings: View {
    @Environment(Broker.self) private var broker

    @State private var host = ""
    @State private var port = 4002
    @State private var clientId = 1
    @State private var confirmLive = false
    @AppStorage(OrderLog.enabledKey) private var orderLog = true
    @AppStorage(SimShare.enabledKey) private var shareSim = true
    @AppStorage(KeepAwake.key) private var keepAwake = true

    private let presets: [(String, Int)] = [
        ("IB Gateway – Paper", 4002), ("IB Gateway – Live", 4001),
        ("TWS – Paper", 7497), ("TWS – Live", 7496),
    ]

    private var hasChanges: Bool {
        host.trimmingCharacters(in: .whitespaces) != broker.host || port != broker.port
            || clientId != broker.clientId
    }

    var body: some View {
        Form {
            Section("IB Gateway") {
                TextField("Host", text: $host)
                Picker("Port", selection: $port) {
                    ForEach(presets, id: \.1) { name, p in Text("\(name) (\(String(p)))").tag(p) }
                }
                TextField("Client ID", value: $clientId, format: .number.grouping(.never))
                LabeledContent("Status") {
                    HStack {
                        Text(broker.statusText).foregroundStyle(.secondary).lineLimit(1)
                        // With the saved host, port and client ID (Save & Reconnect applies changed ones).
                        Button("Reconnect") {
                            broker.disconnect()
                            broker.connect()
                        }
                        .controlSize(.small)
                    }
                }
            }
            Section("TWZ-iOS") {
                Toggle("Share what-if trades with the iPhone app", isOn: $shareSim)
                    .onChange(of: shareSim) { _, on in
                        if on { SimShare.shared.start(broker: broker) } else { SimShare.shared.stop() }
                    }
                Text("Its what-if trades on port \(String(SimShare.port)), and its widget's stock quote on \(String(SimShare.quotePort)). Read-only, and only to this Mac and Tailscale's addresses (100.x).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Keep the Mac awake while TWZ runs", isOn: $keepAwake)
                    .onChange(of: keepAwake) { KeepAwake.update() }
                Text("The Mac doesn't sleep when left idle, so IB Gateway stays reachable from the iPhone app. Closing the lid still puts it to sleep (unless it's on power with an external display). Uses more battery.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Market data") {
                Text("Real-time data only. Stocks you aren't subscribed for show no quote; if no real-time data comes through at all, the app goes offline.")
                    .foregroundStyle(.secondary)
            }
            Section("Diagnostics") {
                Toggle("Order log", isOn: $orderLog)
                    .onChange(of: orderLog) { _, on in OrderLog.shared.isEnabled = on }
                HStack {
                    Text("Every order sent, changed or cancelled and why, with IB's replies. One file per day, kept \(OrderLog.keptDays) days.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Show in Finder") {
                        try? FileManager.default.createDirectory(at: OrderLog.shared.directory, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(OrderLog.shared.directory)
                    }
                    .controlSize(.small)
                }
            }
        }
        .formStyle(.grouped)
        // Outside the form so it never scrolls out of the fixed-height sheet.
        .safeAreaInset(edge: .bottom) {
            HStack {
                if port == 4001 || port == 7496 {
                    Text("⚠︎ Live trading: hotkeys will send real orders.")
                        .foregroundStyle(.red)
                }
                Spacer()
                Button("Save & Reconnect") {
                    let goingLive = (port == 4001 || port == 7496) && !broker.isLivePort
                    if goingLive { confirmLive = true } else { apply() }
                }
                .disabled(!hasChanges)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(.bar)
        }
        .onAppear {
            host = broker.host
            port = broker.port
            clientId = broker.clientId
        }
        .alert("Switch to LIVE trading?", isPresented: $confirmLive) {
            Button("Cancel", role: .cancel) {}
            Button("Go Live", role: .destructive) { apply() }
        } message: {
            Text("Orders placed from hotkeys will be sent to your real account.")
        }
    }

    private func apply() {
        broker.host = host.trimmingCharacters(in: .whitespaces)
        broker.port = port
        broker.clientId = clientId
        broker.disconnect()
        broker.connect()
    }
}

// MARK: - Trading

/// What the app takes in memory, as Activity Monitor's Memory column shows it, and what the bars kept
/// for coming back to a timeframe or stock take of it (see `BarCache`); every 2 seconds.
private struct MemoryUsage: View {
    @Environment(Broker.self) private var broker
    @State private var app: UInt64?
    @State private var cache = BarCache.Usage()
    @State private var disk: (files: Int, bytes: Int) = (0, 0)

    var body: some View {
        LabeledContent("TWZ") {
            Text(app.map { Self.bytes(Int64($0)) } ?? "—").monospacedDigit()
        }
        LabeledContent("Saved candlesticks") {
            Text("\(Self.bytes(Int64(cache.bytes))) · \(cache.series) series, \(cache.bars.formatted()) bars")
                .monospacedDigit()
        }
        .help("Bars kept in memory for switching back to a timeframe or stock, so it shows at once")
        LabeledContent("Saved candlesticks on disk") {
            Text("\(Self.bytes(Int64(disk.bytes))) · \(disk.files) series").monospacedDigit()
        }
        .help("Bars kept on disk, so they're there after a relaunch; a series not shown for two days is deleted at launch")
        .task {
            while !Task.isCancelled {
                app = Self.footprint()
                cache = broker.barCacheUsage
                disk = await Task.detached(priority: .utility) { BarStore.shared.usage() }.value
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .memory)
    }

    /// The app's physical footprint, what Activity Monitor shows as its Memory.
    private static func footprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : nil
    }
}

private struct TradingSettings: View {
    @Environment(Workspace.self) private var workspace
    @Environment(Broker.self) private var broker
    @AppStorage(HoverPnLSize.storageKey) private var hoverSizing: HoverPnLSize = .buyingPower
    @AppStorage(HoverPnLSize.percentKey) private var hoverPercent = HoverPnLSize.defaultPercent
    @AppStorage(HoverPnLSize.amountKey) private var hoverAmount = HoverPnLSize.defaultAmount
    @AppStorage(ForexOrders.storageKey) private var forexOrders: ForexOrders = ForexOrders.defaultValue
    @AppStorage(Confetti.enabledKey) private var confetti = Confetti.defaultEnabled
    @AppStorage(OvernightCheck.enabledKey) private var overnightCheck = OvernightCheck.defaultEnabled
    @AppStorage(OvernightCheck.minutesKey) private var overnightMinutes = OvernightCheck.defaultMinutes

    private let shortcuts: [(String, String)] = [
        ("Order keys", "The shortcuts that send orders (⌘ / ⌥⌘ and numbers, hotkeys' own, ⌘⇧↩, ⌘⌫, …): Settings › Order Keys"),
        ("⌘↩", "Keep the selected chart's tick-by-tick trades on or off once it's deselected (⚡ while on, "
            + "a red circle once IB's limit leaves it out); the selected chart always gets trades and bid/ask"),
        ("⌘⇧S L H A F", "Show that list and load it into the chart grid: Most Active $, Top Losers, AH Gainers, "
            + "Top Gainers, Forex (S, H and L wait a moment for a second letter)"),
        ("⌥ or ⌃ 1 2 3 4 5 6", "Every chart's timeframe: 1m / 5m / 15m / 30m / 1h / D (one modifier alone: two together, ⌃⌥3 say, are free for a hotkey or order key)"),
        ("⌃⇧1 … 9, 0", "Candle colors: the themes in Settings › Appearance › Candle colors, top first (⌃⇧0: the tenth)"),
        ("⌃⇧Q W E R T Y U I O P", "Chart themes: candles, background, grid and labels together (Settings › Appearance › Chart themes)"),
        ("⇧1 2 3 4 5", "The chart layout saved under that number in the top bar's layout numbers (▦ 1–5: ⇧-click saves the grid's columns, rows and lines there, a click loads it); with the Charts window in front, that window's own. Not while typing"),
        ("⌘R, ⇧R, ⌥R, ⌃R or ⌘⇧R", "Reset, as the top bar's button: every chart follows the grid's list again"),
        ("´", "Back to the grid shown before (its list and timeframe: from 15m to 5m, from Forex to Most Active $), and pressed again back here; not while typing"),
        ("⌥0  /  ⇧A", "Every other chart takes the selected chart's view: zoom, place and price scale (the same time span and right edge on other timeframes); ⇧A not while typing"),
        ("1 2 3 4 5 (top bar)", "View sets (by default): ⇧-click a number saves every chart's zoom and place on every timeframe; a click (or ⌥⇧ and the number) puts them back. With Appearance's \"Top bar numbers are scales\" on, scales: a click: every chart takes that saved scale (zoom, place and price scale), and keeps taking it as lists change until it's clicked again or Reset (a timeframe switch keeps each chart's view). The Zoom slider or ⇧- / ⌘- / ⌥-swipe trumps its zoom until a scale is picked; a chart zoomed or panned by hand keeps its view (per stock and timeframe) through list switches, until a number is clicked (or a right-click on that chart). Each list keeps its own views and lit scale. ⇧-click: save the selected chart's view as it"),
    ]

    var body: some View {
        Form {
            Section("Memory") { MemoryUsage() }
            Section("Lists and charts") {
                Toggle("Hide restricted stocks", isOn: Bindable(broker).hideRestricted)
                Text("Leaves the stocks IB won't let you buy (closing-only, no KID for your country, a compliance restriction) out of the lists and the charts that follow them. Each listed stock is checked with a what-if buy of one share, never placed, and again every 30 minutes. A stock you hold or have a working order in stays; one you load by hand shows.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Hover P/L with no position open") {
                Picker("Pretend buy at the last price", selection: $hoverSizing) {
                    ForEach(HoverPnLSize.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.radioGroup)
                LabeledContent("Buying power (%)") {
                    TextField("", value: $hoverPercent, format: .number.precision(.fractionLength(0)))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                }
                .disabled(hoverSizing != .buyingPower)
                LabeledContent("Amount (NOK)") {
                    TextField("", value: $hoverAmount, format: .number.precision(.fractionLength(0)))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                }
                .disabled(hoverSizing != .nok)
                Text(hoverSizing == .buyingPower
                     ? "Hovering a chart shows the P/L of that percent (1–100) of the largest position IB's margin allows at the last price: above it the largest long, below it the largest short (so a stock with less room to short shows a smaller amount below). Asked from IB as the pointer comes over the chart (a second or two, then kept a minute: the same answers as the chart header's buying power)."
                     : "Hovering a chart shows the P/L of buying the shares this amount buys at the last price, at the current USD.NOK rate.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Forex") {
                Picker("Orders go to IB as", selection: $forexOrders) {
                    ForEach(ForexOrders.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.radioGroup)
                Text((forexOrders == .cfd
                      ? "Leveraged, the way IBKR's European accounts trade currencies (needs the CFD trading permission). Positions shown are the pairs' CFDs."
                      : "Leveraged only with IBKR's leveraged forex permission; without it IB takes just the trades that convert currency the account holds. Positions shown are IDEALPRO's, conversions included.")
                     + " Quotes and charts come from IDEALPRO either way. Applies from the next Connect.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Overnight check") {
                Toggle("Check the overnight margin before the close", isOn: $overnightCheck)
                Stepper("Minutes before the close: \(overnightMinutes)", value: $overnightMinutes, in: 1...60)
                    .disabled(!overnightCheck)
                HStack {
                    Text("With stock positions open, a banner over the charts from that many minutes before the close (16:00 ET, 13:00 ET on early closes; not on NYSE holidays) says whether they fit the margin IB asks for after the close (IB's look-ahead available funds and excess liquidity, asked again every 30 seconds), and if not, how many shares of each to sell or buy back: every stock cut by the same share, with 10% of the overnight margin to spare. Its Trim button sends those orders to IB (KEYS ON or SIM alike), limits a cent across the spread; the stop losses and take profits follow the smaller positions. Forex and options aren't trimmed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Check now") {
                        NotificationCenter.default.post(name: OvernightBanner.checkNow, object: nil)
                    }
                    .controlSize(.small)
                }
            }
            Section("Confetti") {
                Toggle("Confetti when a LIVE trade opens", isOn: $confetti)
                HStack {
                    Text("Over every screen as a position opens, from flat or flipping sides, on a LIVE account. Adding to a position doesn't fire it, nor does paper trading. Clicks and keys go straight through it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Preview") { Confetti.fire() }
                        .controlSize(.small)
                }
            }
            Section("Keyboard shortcuts (selected chart's symbol)") {
                ForEach(shortcuts, id: \.0) { keys, action in
                    LabeledContent(keys) {
                        Text(action).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                    }
                }
            }
            Section("Charts windows") {
                ForEach(workspace.chartsWindows, id: \.win) { window in
                    @Bindable var window = window
                    ShortcutRecorder(title: "\(window.win.title) show / hide shortcut", shortcut: $window.shortcut, owner: .chartsWindow(window.win))
                    if let failure = GlobalHotkey.shared.failure(window.win.rawValue) {
                        Text(failure).font(.caption).foregroundStyle(.red)
                    }
                    if window.shortcut?.isPlain == true {
                        Text("A single key works in every app, so other apps can't type it while it's set.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                Text("Works from any app: shows that Charts window in front (opening it if needed); pressed again, hides the app and goes back to the one before. Hidden, its charts stay live, so it comes back instantly. Closing the window turns them off like P. Each window has its own list, grid, zoom, numbers and layouts; Charts 2 is laid out for a portrait screen (All Charts 3×6, up to 4 columns × 8 rows). The Window menu opens either.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Order Keys

/// Every keyboard shortcut that trades, in one place: the order keys (see `OrderKeys`), listed by shortcut,
/// each added, edited (double-click, or the pencil) or deleted here; the hotkey buttons given a shortcut (edited
/// in the hotkey panel); and the fixed ones (⌘⇧↩, ⌘⌫, cancelling, the $ / % switch, what-if trades).
private struct OrderKeysSettings: View {
    @Environment(Workspace.self) private var workspace
    @AppStorage(SizeMode.storageKey) private var sizeMode: SizeMode = .percent
    @State private var editing: Editing?

    private struct Editing: Identifiable {
        var key: Hotkey
        var id: UUID { key.id }
    }

    private static let fixed: [(String, String)] = [
        ("⌘🌐 (⌘ fn)", "KEYS ON / SIM: with KEYS ON every order shortcut here goes to IB, for real; off, SIM (as at launch), the same shortcuts trade what-if positions, never sent to IB, filled at once at the order's price (a limit at its reference ± offset, MIDPRICE at the mid, market at the ask or bid). At launch it's KEYS ON instead when a live position is open. The charts and Positions show the real positions and orders and the what-if trades together either way. The top bar reads KEYS $ / % or SIM $ / %"),
        ("⌘⇧↩  /  ⌥⌘⇧↩", "Send the selected hotkey button's order; with none selected, buy (⌘⇧↩) or sell short (⌥⌘⇧↩) the order pad's"),
        ("⌘⇧M", "Switch the order numbers between dollars ($1,000 a step: 1–9 are $1,000–$9,000) and a percent of the buying power (20% a step: 1–4 are 20–80%, 5–9 none): KEYS $ or KEYS % in the top bar, and the order pad's $ and %"),
        ("⌘⌫", "Cancel every order in the chart's symbol, then close 100% of the position at market; removes its ⌃-click what-if too. In SIM it closes the chart's what-if trade instead"),
        ("⌘A  /  ⌥<  /  Hyper A, Hyper ⌫", "Cancel every order in the chart's symbol, stop loss and take profit included (⌘A also removes its ⌃-click what-if); with no chart selected, ⌘A cancels the last order placed, as ⌘Z"),
        ("⌘Z  /  ⌥Z", "Cancel the last order placed"),
        ("⌘⇧⌫", "Remove the chart's ⌃-click what-if (so does double-clicking anywhere on the chart)"),
        ("⌃⌥⇧1 2 3 4", "What-if trade: sell (short) $1,000 / $2,000 / $3,000 / 85% of the buying power, simulated and never sent to IB "
            + "(not in a stock with a real position); ⌃-click its chart for a simulated stop loss or take profit, ⌘⌫ closes it"),
    ]

    /// A side's modifier sets, each changed (↩) or taken off (⌫) by recording over it, and a row adding one (Hyper
    /// offered while no side has it).
    @ViewBuilder private func numberRows(_ title: String, sets: [ModifierSet], selling: Bool) -> some View {
        ForEach(Array(sets.enumerated()), id: \.element.display) { index, set in
            ModifierRecorder(title: index == 0 ? title : "", current: set,
                             save: { workspace.setNumberModifiers($0, selling: selling, replacing: set) },
                             remove: { workspace.removeNumberModifiers(set, selling: selling) })
        }
        ModifierRecorder(title: sets.isEmpty ? title : "", current: nil,
                         save: { workspace.setNumberModifiers($0, selling: selling) },
                         offersHyper: !(workspace.buyModifierSets + workspace.sellModifierSets).contains(.hyper))
    }

    /// By modifiers (⌘ before ⌥⌘), then key; keys still without a shortcut last.
    private var sortedKeys: [Hotkey] {
        workspace.orderKeys.sorted { a, b in
            guard let x = a.shortcut else { return false }
            guard let y = b.shortcut else { return true }
            let mx = x.display.dropLast(x.key.count), my = y.display.dropLast(y.key.count)
            if mx != my { return mx.count != my.count ? mx.count < my.count : mx < my }
            return x.key.localizedStandardCompare(y.key) == .orderedAscending
        }
    }

    var body: some View {
        Form {
            Section {
                numberRows("Buy", sets: workspace.buyModifierSets, selling: false)
                numberRows("Sell", sets: workspace.sellModifierSets, selling: true)
            } header: {
                Text("Number keys")
            } footer: {
                Text("The modifier keys of the 1–9 order keys: each set listed works, ⌘ and Hyper both buying, say. Click one, hold the keys (⌘, ⌥, ⌃, ⇧), then ↩ to change it, or ⌫ to take it off; Esc cancels. Add… adds a set; Hyper adds ⌃⌥⇧⌘ (Raycast's Caps Lock) at once.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                if workspace.orderKeys.isEmpty {
                    Text("No order keys: + adds one, Restore Defaults brings back ⌘1–9 and ⌥⌘1–9.")
                        .foregroundStyle(.secondary)
                }
                ForEach(sortedKeys) { key in
                    OrderKeyRow(key: key, triggers: workspace.triggers(of: key),
                                overriddenBy: workspace.triggers(of: key).lazy.compactMap(workspace.hotkeyOverriding).first?.label,
                                onEdit: { editing = Editing(key: key) }) {
                        workspace.orderKeys.removeAll { $0.id == key.id }
                    }
                }
            } header: {
                HStack {
                    Text("Order keys")
                    Spacer()
                    Button("Restore Defaults") {
                        workspace.buyModifiers = .buy
                        workspace.sellModifiers = .sell
                        workspace.buyModifierSets = [.buy]
                        workspace.sellModifierSets = [.sell]
                        workspace.orderKeys = OrderKeys.defaults()
                    }
                        .help("⌘1–9 buy and ⌥⌘1–9 sell short 1–9 steps: $1,000–$9,000, or 20–80% of the buying power for 1–4 (⌘⇧M)")
                    Button {
                        editing = Editing(key: OrderKeys.newKey())
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                    .help("A new order key: record its shortcut, then pick the order")
                }
                .controlSize(.small)
            } footer: {
                Text("For the selected chart's symbol, once per press: holding the key doesn't send another. With KEYS ON they go to IB; in SIM (KEYS off, as at every launch) they trade what-if positions (⌘🌐 switches; now \(workspace.orderShortcutsOn ? "KEYS ON, real" : "SIM")). A keypad number works as the number row's. Sized in steps, they go by ⌘⇧M (now \(sizeMode == .dollars ? "$, $1,000 a step" : "%, 20% of the buying power a step, 5–9 none")).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Hotkey buttons with a shortcut") {
                let keyed = workspace.hotkeys.filter { $0.shortcut != nil }
                if keyed.isEmpty {
                    Text("None yet.").foregroundStyle(.secondary)
                }
                ForEach(keyed) { button in
                    OrderKeyRow(key: button, overrides: button.shortcut.flatMap(workspace.orderKey(for:))?.label)
                }
                Text("Edited in the hotkey panel: right-click a button, or click the Hotkeys title.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Other order shortcuts") {
                ForEach(Self.fixed, id: \.0) { keys, action in
                    LabeledContent {
                        Text(action).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                    } label: {
                        KeyCap(text: keys)
                    }
                }
            }
            Section("Reset") {
                @Bindable var workspace = workspace
                ShortcutRecorder(title: "Another Reset shortcut", shortcut: $workspace.resetShortcut, owner: .reset)
                Text("Does what ⌘R, ⇧R, ⌥R, ⌃R and ⌘⇧R do: every chart follows the grid's list again. Try ⌃ and a letter; one text fields use (⌃A, ⌃E, ⌃K…) resets there too instead of moving the cursor.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editing) { target in
            HotkeyEditor(hotkey: target.key, isOrderKey: true) { updated in
                if let i = workspace.orderKeys.firstIndex(where: { $0.id == updated.id }) {
                    workspace.orderKeys[i] = updated
                } else {
                    workspace.orderKeys.append(updated)
                }
            }
        }
    }
}

/// One order key or hotkey: its shortcut, what it does (BUY green, SELL red), its size (steps as ⌘⇧M has them
/// now, and the other way) and how it's priced; the pencil and trash where it's edited here.
private struct OrderKeyRow: View {
    let key: Hotkey
    /// The shortcuts that press it, when not just its own (a number key's, see `Workspace.triggers`).
    var triggers: [KeyShortcut]?
    /// An order key's: the hotkey button that has its shortcut now, overriding it.
    var overriddenBy: String?
    /// A hotkey button's: the order key whose shortcut it has, overriding it.
    var overrides: String?
    @AppStorage(SizeMode.storageKey) private var sizeMode: SizeMode = .percent
    var onEdit: (() -> Void)?
    var onDelete: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            let keys = triggers ?? key.shortcut.map { [$0] } ?? []
            KeyCap(text: keys.isEmpty ? "None" : keys.map(\.display).joined(separator: "  ·  "))
                .opacity(keys.isEmpty ? 0.5 : 1)
                .frame(minWidth: 58, alignment: .leading)
            Text(side)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(key.tint.opacity(0.8)))
                .frame(width: 92, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(size).font(.system(size: 12, weight: .semibold)).monospacedDigit()
                if !details.isEmpty {
                    Text(details).font(.caption).foregroundStyle(.secondary)
                }
                if let overriddenBy {
                    Text("Overridden by the \"\(overriddenBy)\" button while it has this shortcut")
                        .font(.caption).foregroundStyle(.orange)
                }
                if let overrides {
                    Text("Overrides the order key \"\(overrides)\" while it has this shortcut")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            .opacity(overriddenBy == nil ? 1 : 0.6)
            Spacer(minLength: 4)
            if let onEdit {
                Button(action: onEdit) { Image(systemName: "pencil") }
                    .buttonStyle(.borderless)
                    .help("Edit")
            }
            if let onDelete {
                Button(action: onDelete) { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help("Delete")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onEdit?() }
    }

    private var side: String {
        switch key.action {
        case .buy: "BUY"
        case .sell: "SELL"
        default: key.action.rawValue.uppercased()
        }
    }

    private var size: String {
        guard key.action.needsSize else {
            return switch key.action {
            case .closeHalf: "Half the position"
            case .closeAll: "The whole position"
            case .cancelSymbol: "Every order in the symbol"
            case .cancelAll: "Every order"
            default: "Every position"
            }
        }
        let amount = key.amount.formatted(.number.precision(.fractionLength(0...2)))
        return switch key.sizing {
        case .dollars: "$" + amount
        case .buyingPower: amount + "% of the buying power"
        case .shares: amount + (key.amount == 1 ? " share" : " shares")
        case .steps:
            sizeMode.text(steps: key.amount) + (sizeMode == .percent ? " of the buying power" : "")
                + "  (\((sizeMode == .dollars ? SizeMode.percent : .dollars).text(steps: key.amount)) in \(sizeMode == .dollars ? "%" : "$"))"
        }
    }

    private var details: String {
        guard key.action.placesOrder else { return "" }
        var parts: [String] = []
        switch key.orderType {
        case .market: parts.append("Market")
        case .midprice: parts.append("MIDPRICE")
        case .limit:
            parts.append(key.priceReference == .cross ? "Limit across the spread" : "Limit at the " + key.priceReference.rawValue.lowercased())
        }
        if key.orderType != .market {
            let sign = key.offset < 0 ? "−" : "+"
            parts.append("offset \(sign)\(abs(key.offset).formatted(.number.precision(.fractionLength(2...4))))")
        }
        parts.append(key.tif.rawValue)
        if key.orderType == .limit, key.outsideRth { parts.append("outside regular hours") }
        return parts.joined(separator: " · ")
    }
}

/// A shortcut drawn as a key cap.
private struct KeyCap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.18)))
    }
}

// MARK: - Layouts

private struct LayoutSettings: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""
    @State private var replacing: SavedLayout?
    @State private var deleting: SavedLayout?

    var body: some View {
        @Bindable var workspace = workspace
        Form {
            Section {
                HStack {
                    TextField("Name", text: $newName, prompt: Text("Layout \(workspace.layouts.count + 1)"))
                        .onSubmit(saveNew)
                    Button("Save", action: saveNew)
                }
            } header: {
                Text("Save the current layout")
            } footer: {
                Text("Panel sizes, the lists' columns, the chart grid's size, lines, zoom and space, and every Appearance setting (colors, line styles, indicators). Loading one leaves the charts' stocks and timeframes and the lists' scanners as they are.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Saved layouts") {
                if workspace.layouts.isEmpty {
                    Text("None yet").foregroundStyle(.secondary)
                }
                ForEach($workspace.layouts) { $layout in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            // The layout's name, editable in place (no "Name" label beside it).
                            TextField("Name", text: $layout.name)
                                .textFieldStyle(.plain)
                                .labelsHidden()
                                .fontWeight(.medium)
                            Text(layout.saved, format: .dateTime.day().month().hour().minute())
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Load") {
                            workspace.loadLayout(layout)
                            dismiss()
                        }
                        Button("Update") { replacing = layout }
                            .help("Replace with the current layout")
                        Button(role: .destructive) { deleting = layout } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .help("Delete")
                    }
                    .controlSize(.small)
                }
                .onMove { workspace.layouts.move(fromOffsets: $0, toOffset: $1) }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Replace “\(replacing?.name ?? "")” with the current layout?",
                            isPresented: Binding(get: { replacing != nil }, set: { if !$0 { replacing = nil } })) {
            Button("Replace") {
                if let replacing { workspace.saveLayout(name: replacing.name, replacing: replacing.id) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete “\(deleting?.name ?? "")”?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) {
                workspace.layouts.removeAll { $0.id == deleting?.id }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func saveNew() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        workspace.saveLayout(name: name.isEmpty ? "Layout \(workspace.layouts.count + 1)" : name)
        newName = ""
    }
}

// MARK: - Appearance

private struct AppearanceSettings: View {
    @AppStorage(CandleTheme.storageKey) private var theme: CandleTheme = .teal
    @AppStorage(CandleTheme.customUpKey) private var customUp = CandleTheme.defaultUpHex
    @AppStorage(CandleTheme.customDownKey) private var customDown = CandleTheme.defaultDownHex
    @AppStorage(LineColors.lastPriceKey) private var lastPriceHex = ""
    @AppStorage(LineColors.avgCostKey) private var avgCostHex = ""
    @AppStorage(LineColors.altClickKey) private var altClickHex = ""
    @AppStorage(LineColors.hoverKey) private var hoverHex = ""
    @AppStorage(LineColors.stopLossKey) private var stopLossHex = ""
    @AppStorage(LineColors.takeProfitKey) private var takeProfitHex = ""
    @AppStorage(LineColors.closedTradeKey) private var closedTradeHex = ""
    @AppStorage(LineColors.trendKey) private var trendHex = ""
    @AppStorage(TrendLines.widthKey) private var trendWidth = TrendLines.defaultWidth
    @AppStorage(TrendLines.priceBoxKey) private var trendPriceBox = TrendLines.defaultPriceBox
    @Environment(Workspace.self) private var workspace
    @Environment(\.sideColors) private var sideColors
    @AppStorage(LineColors.ordersKey) private var ordersHex = ""
    @AppStorage(LineColors.showLastPriceLineKey) private var showLastPriceLine = true
    @AppStorage(LineColors.showLastTradeLinesKey) private var showLastTradeLines = true
    @AppStorage(LineColors.showGridKey) private var showGrid = false
    @AppStorage(VolumeBars.opacityKey) private var volumeOpacity = VolumeBars.defaultOpacity
    @AppStorage(SideColors.sourceKey) private var sideSource: SideColors.Source = .candles
    @AppStorage(Dimmed.opacityKey) private var dimmedOpacity = Dimmed.defaultOpacity
    @AppStorage(SideColors.customUpKey) private var sideUp = ""
    @AppStorage(SideColors.customDownKey) private var sideDown = ""
    @AppStorage(AppBackground.key) private var appBackgroundHex = ""
    @AppStorage(SelectedOutline.widthKey) private var outlineWidth = SelectedOutline.defaultWidth
    @AppStorage(TimeframePickerStyle.storageKey) private var pickerStyle: TimeframePickerStyle = TimeframePickerStyle.defaultStyle
    @AppStorage(AccountBarPosition.storageKey) private var barPosition: AccountBarPosition = .top
    @AppStorage(Indicators.vwapKey) private var showVWAP = true
    @AppStorage(Indicators.fastSMAKey) private var showFastSMA = true
    @AppStorage(Indicators.slowSMAKey) private var showSlowSMA = true
    @AppStorage(Indicators.tradesKey) private var showTrades = false
    @AppStorage(Indicators.lineWidthKey) private var indicatorWidth = Indicators.defaultLineWidth
    @AppStorage(PriceAxis.fontSizeKey) private var axisFontSize = PriceAxis.defaultFontSize
    @AppStorage(PriceAxis.labelSpacingKey) private var labelSpacing = PriceAxis.defaultLabelSpacing
    @AppStorage(PriceAxis.lastPriceOpacityKey) private var lastPriceOpacity = PriceAxis.defaultLastPriceOpacity
    @AppStorage(TimeframeSwitch.keepViewKey) private var keepViewOnTimeframeSwitch = TimeframeSwitch.defaultKeepView
    @AppStorage(GridZoom.resetsAdjustedKey) private var gridZoomResetsAdjusted = GridZoom.defaultResetsAdjusted
    @AppStorage(NumberButtons.scalesKey) private var numberButtonsAreScales = NumberButtons.defaultScales
    @AppStorage(HeaderPerformance.freezeKey) private var headersFrozen = HeaderPerformance.defaultOn
    @AppStorage(HeaderPerformance.layoutKey) private var headerLayoutByWidth = HeaderPerformance.defaultOn
    @AppStorage(HeaderPerformance.perStockKey) private var headerPerStock = HeaderPerformance.defaultOn
    @AppStorage(FrameMeter.enabledKey) private var frameMeter = false
    @AppStorage(Swiping.zoomsAllKey) private var swipeZoomsAll = Swiping.defaultZoomsAll
    @AppStorage(Swiping.locksPanKey) private var swipeLocksPan = Swiping.defaultLocksPan
    @AppStorage(ViewSync.key) private var viewSync = ViewSync.defaultOn
    @AppStorage(ZoomAnchor.keepsLatestKey) private var zoomKeepsLatest = ZoomAnchor.defaultKeepsLatest

    /// The selected chart's outline as it's drawn: the stored width is a third of it (see `SelectedOutline`).
    private var selectedOutline: Binding<Double> {
        Binding(get: { outlineWidth * SelectedOutline.selectedMultiple },
                set: { outlineWidth = $0 / SelectedOutline.selectedMultiple })
    }

    /// A theme to pick, with a preview, its shortcut and a checkmark while it's on.
    private func themeRow(_ option: CandleTheme) -> some View {
        let colors = option.colors(customUp: customUp, customDown: customDown)
        return Button {
            theme = option
        } label: {
            HStack(spacing: 10) {
                CandleSwatch(up: colors.up, down: colors.down, scene: option.scene)
                Text(option.rawValue)
                Spacer()
                Text(option.shortcut)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                if theme == option {
                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    var body: some View {
        Form {
            Section("Presets") {
                ForEach(Array(AppearancePresets.slots), id: \.self) { PresetRow(slot: $0) }
            }
            Section("Candle colors") {
                ForEach(CandleTheme.candleOnly) { themeRow($0) }
            }
            Section("Chart themes") {
                ForEach(CandleTheme.chartThemes) { themeRow($0) }
                Text("The candles and the chart's own background, grid and labels. A candle color above goes back to the app's look.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("App colors") {
                HStack {
                    ColorWell(title: "App background", key: AppBackground.key,
                              color: Color(hex: appBackgroundHex) ?? AppBackground.defaultColor)
                    Button("Default") { appBackgroundHex = "" }
                        .controlSize(.small)
                        .disabled(appBackgroundHex.isEmpty)
                        .help("Back to the dark gray")
                }
                Picker("Up / down outside the candles", selection: $sideSource) {
                    ForEach(SideColors.Source.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.radioGroup)
                if sideSource == .custom {
                    let candles = theme.colors(customUp: customUp, customDown: customDown)
                    ColorWell(title: "Up, gains, buys", key: SideColors.customUpKey, color: Color(hex: sideUp) ?? candles.up)
                    ColorWell(title: "Down, losses, sells", key: SideColors.customDownKey, color: Color(hex: sideDown) ?? candles.down)
                    Button("Back to the candle colors") {
                        sideUp = ""
                        sideDown = ""
                    }
                    .disabled(sideUp.isEmpty && sideDown.isEmpty)
                }
                Text("Lists, Orders / Positions / Round trips, P/L, the position badge and tint, fill bars, trade arrows and buy / sell lines. Own colors start at the candle colors until picked.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Panels") {
                LabeledContent("Dimmed rows") {
                    HStack {
                        Slider(value: $dimmedOpacity, in: Dimmed.opacityRange, step: 0.05)
                        Text("\(Int((dimmedOpacity * 100).rounded()))%")
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                Text("How strongly filled orders, round trips and a list's partial recent change show: lower is fainter, 100% not dimmed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Chart lines") {
                lineColorRow("Last price", key: LineColors.lastPriceKey, hex: $lastPriceHex,
                             default: LineColors.defaultLastPrice,
                             dashedKey: LineDashes.lastPriceKey, dashedDefault: LineDashes.defaultLastPrice)
                Toggle("Show last price line (the price box stays)", isOn: $showLastPriceLine)
                lineColorRow("Average position", key: LineColors.avgCostKey, hex: $avgCostHex,
                             default: LineColors.defaultAvgCost,
                             dashedKey: LineDashes.avgCostKey, dashedDefault: LineDashes.defaultAvgCost)
                lineColorRow("Orders", key: LineColors.ordersKey, hex: $ordersHex,
                             default: LineColors.defaultOrders,
                             dashedKey: LineDashes.ordersKey, dashedDefault: LineDashes.defaultOrders)
                lineColorRow("⌥-click orders", key: LineColors.altClickKey, hex: $altClickHex,
                             default: LineColors.defaultAltClick,
                             dashedKey: LineDashes.altClickKey, dashedDefault: LineDashes.defaultAltClick)
                lineColorRow("Hover price", key: LineColors.hoverKey, hex: $hoverHex,
                             default: LineColors.defaultHover,
                             dashedKey: LineDashes.hoverKey, dashedDefault: LineDashes.defaultHover)
                lineColorRow("Stop loss (⌃-click)", key: LineColors.stopLossKey, hex: $stopLossHex,
                             default: LineColors.defaultStopLoss,
                             dashedKey: LineDashes.stopLossKey, dashedDefault: LineDashes.defaultStopLoss)
                lineColorRow("Take profit (⌃-click)", key: LineColors.takeProfitKey, hex: $takeProfitHex,
                             default: LineColors.defaultTakeProfit,
                             dashedKey: LineDashes.takeProfitKey, dashedDefault: LineDashes.defaultTakeProfit)
                // The style also sets the Avg line shown with it.
                lineColorRow("Closed trade (exit)", key: LineColors.closedTradeKey, hex: $closedTradeHex,
                             default: sideColors.down,
                             dashedKey: LineDashes.lastTradeKey, dashedDefault: LineDashes.defaultLastTrade)
                lineColorRow("Trend lines (⌘⇧-click)", key: LineColors.trendKey, hex: $trendHex,
                             default: LineColors.defaultTrend,
                             dashedKey: LineDashes.trendKey, dashedDefault: LineDashes.defaultTrend)
                LabeledContent("Trend line width") {
                    HStack {
                        Slider(value: $trendWidth, in: TrendLines.widthRange, step: 0.5)
                        Text(trendWidth.formatted(.number.precision(.fractionLength(1))) + " pt")
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                Toggle("Show trend lines' price on the axis", isOn: $trendPriceBox)
                HStack {
                    Text("⌘⇧-click a chart for a horizontal trend line at that price; double-click the line to remove it. Kept per stock.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    let count = workspace.trendLines.values.reduce(0) { $0 + $1.count }
                    Button("Remove All (\(count))") { workspace.trendLines = [:] }
                        .controlSize(.small)
                        .disabled(count == 0)
                }
                Toggle("Show last trade lines after a round trip closes", isOn: $showLastTradeLines)
                Toggle("Show grid lines (the price and time labels stay)", isOn: $showGrid)
                Text("Once a round trip closes, its chart shows the exit line in the closed trade color, and the Avg line (same line style). On: they stay until you click the chart or place an order. Off: just the exit line, for 7 seconds or until a click.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Indicators") {
                Toggle("VWAP (intraday charts)", isOn: $showVWAP)
                Toggle("SMA 9", isOn: $showFastSMA)
                Toggle("SMA 21", isOn: $showSlowSMA)
                Toggle("Trades (▲ buys, ▼ sells)", isOn: $showTrades)
                LabeledContent("Volume bars opacity") {
                    HStack {
                        Slider(value: $volumeOpacity, in: VolumeBars.opacityRange, step: 0.05)
                        Text("\(Int((volumeOpacity * 100).rounded()))%")
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                LabeledContent("Line thickness") {
                    HStack {
                        Slider(value: $indicatorWidth, in: Indicators.lineWidthRange, step: 0.25)
                        Text("\(indicatorWidth.formatted(.number.precision(.fractionLength(0...2)))) pt")
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            }
            Section("Price axis") {
                LabeledContent("Text size") {
                    HStack {
                        Slider(value: $axisFontSize, in: PriceAxis.fontSizeRange, step: 1)
                        Text("\(Int(axisFontSize)) pt")
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                LabeledContent("Price labels") {
                    // Slider runs fewer → more, i.e. from the widest spacing to the tightest.
                    Slider(value: Binding(get: { -labelSpacing }, set: { labelSpacing = -$0 }),
                           in: -PriceAxis.labelSpacingRange.upperBound ... -PriceAxis.labelSpacingRange.lowerBound) {
                        EmptyView()
                    } minimumValueLabel: {
                        Text("Fewer").font(.caption)
                    } maximumValueLabel: {
                        Text("More").font(.caption)
                    }
                }
                // All the way left removes the box, leaving the dotted line and the price.
                LabeledContent("Last price box opacity") {
                    HStack {
                        Slider(value: $lastPriceOpacity, in: PriceAxis.lastPriceOpacityRange, step: 0.05)
                        Text(PriceAxis.hidesLastPriceBox(lastPriceOpacity) ? "Off" : "\(Int((lastPriceOpacity * 100).rounded())) %")
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            }
            Section("Top bar") {
                Picker("Position", selection: $barPosition) {
                    ForEach(AccountBarPosition.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                if barPosition == .bottom {
                    Text("At the bottom, the window's close / minimize / zoom buttons are hidden; ⌘W, ⌘M and ⌃⌘F still work.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Chart header") {
                Picker("Timeframe picker", selection: $pickerStyle) {
                    ForEach(TimeframePickerStyle.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Section("Chart views") {
                Toggle("Moving one chart's view moves every chart in its window", isOn: $viewSync)
                Text(viewSync
                     ? "Dragging, swiping, pinching, ⌃-scaling or resetting a chart does the same to every other chart in that window (the same time on screen, prices moved alike); the other window's charts stay. Hold ⇧, ⌘ or ⌥ to move only the chart under the pointer."
                     : "Only the chart you move changes; ⌥0 or ⇧A gives the others its view.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Keep the view when switching timeframe", isOn: $keepViewOnTimeframeSwitch)
                Text(keepViewOnTimeframeSwitch
                     ? "The same time stays on screen, the right edge where it was; only the candles change."
                     : "Each timeframe keeps its own zoom and place, and switching back goes to them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("⇧-, ⌘- or ⌥-swipe zooms charts adjusted by hand to the same zoom", isOn: $gridZoomResetsAdjusted)
                Text(gridZoomResetsAdjusted
                     ? "⇧-, ⌘- or ⌥-swipe and the Zoom slider put every chart at the same zoom, those zoomed or panned by hand too."
                     : "Charts zoomed or panned by hand keep their own zoom and zoom in or out by as much as the rest.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Top bar numbers are scales", isOn: $numberButtonsAreScales)
                Text(numberButtonsAreScales
                     ? "⇧-click a number saves the selected chart's view as a scale; picking it gives every chart that view."
                     : "⇧-click a number saves every chart's zoom and place on every timeframe; picking it puts them all back.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Selected chart") {
                LabeledContent("Outline thickness") {
                    HStack {
                        Slider(value: selectedOutline, in: SelectedOutline.range.lowerBound * SelectedOutline.selectedMultiple
                                ... SelectedOutline.range.upperBound * SelectedOutline.selectedMultiple, step: 0.5)
                        Text("\(selectedOutline.wrappedValue.formatted(.number.precision(.fractionLength(0...1)))) pt")
                            .monospacedDigit()
                            .frame(width: 52, alignment: .trailing)
                    }
                }
            }
            Section("Performance") {
                Toggle("Charts window: headers update only while selected or with a position", isOn: $headersFrozen)
                Text(headersFrozen
                     ? "Each header there is drawn as its stock loads (and again a few seconds later), then only while its chart is selected or has a position or what-if trade open."
                     : "Every header there updates as its stock's data changes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Chart headers lay out once for their width", isOn: $headerLayoutByWidth)
                Text(headerLayoutByWidth
                     ? "A header measures the room it has and builds the one layout that fits (again only when the chart is resized)."
                     : "A header tries each of its layouts every time it's drawn, keeping the first that fits.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Chart headers redraw only for their own stock", isOn: $headerPerStock)
                Text(headerPerStock
                     ? "A fill, position or margin change redraws only the headers of that stock."
                     : "Any stock's fill, position or margin change redraws every header.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Frame meter", isOn: $frameMeter)
                Text("In the top bar (and the Charts windows'), over the last second: chart frames per second / the screen's refresh rate, the main thread's time to draw a frame's charts in ms (average / slowest; orange past one refresh's budget), and scroll / swipe / pinch / drag events per second. Hover it for more. Zoom or pan to read it: still charts only redraw on new prices.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Swiping") {
                Toggle("Swipe zooms every chart", isOn: $swipeZoomsAll)
                Text(swipeZoomsAll
                     ? "A trackpad swipe zooms every chart, as the Zoom slider; ⇧-, ⌘- or ⌥-swipe pans and zooms only the chart under the pointer."
                     : "A trackpad swipe pans and zooms the chart under the pointer; ⇧-, ⌘- or ⌥-swipe zooms every chart, as the Zoom slider.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Zoom keeps the latest candle in place", isOn: $zoomKeepsLatest)
                Text(zoomKeepsLatest
                     ? "Zooming (a swipe, pinch or wheel, the Zoom slider) leaves the latest candle where it is; the bars before it spread out or close up to its left."
                     : "A chart zooms around the pointer, and zooming every chart keeps the Space slider's bars right of the latest candle, so the candles move sideways as they widen or narrow.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Pan locks once swiped sideways", isOn: $swipeLocksPan)
                Text(swipeLocksPan
                     ? "Swiping up or down zooms as usual (every chart, with Swipe zooms every chart on), but once a two-finger swipe goes left or right it only pans the chart under the pointer, until the fingers lift (and through its glide after)."
                     : "A nearly straight swipe only pans or only zooms; a clearly diagonal one does both.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Reset to Defaults") { AppearanceDefaults.reset() }
            }
        }
        .formStyle(.grouped)
    }

    /// Color swatch, solid / dashes / dots switch, and a Reset button while a custom color is set (empty hex = default).
    private func lineColorRow(_ title: String, key: String, hex: Binding<String>, default fallback: Color,
                              dashedKey: String, dashedDefault: Bool) -> some View {
        HStack {
            ColorWell(title: title, key: key, color: LineColors.resolve(hex.wrappedValue, default: fallback))
            LineStylePicker(key: dashedKey, default: dashedDefault)
            if !hex.wrappedValue.isEmpty {
                Button("Reset") { hex.wrappedValue = "" }
                    .controlSize(.small)
            }
        }
    }
}

/// One preset slot: Load applies it, Save stores the current Appearance settings in it.
private struct PresetRow: View {
    let slot: Int
    @AppStorage private var data: Data?
    @State private var confirmReplace = false

    init(slot: Int) {
        self.slot = slot
        _data = AppStorage(AppearancePresets.key(slot))
    }

    var body: some View {
        LabeledContent("Preset \(slot)") {
            HStack {
                if data == nil {
                    Text("Empty").foregroundStyle(.secondary)
                }
                Button("Load") { AppearancePresets.load(slot) }
                    .disabled(data == nil)
                Button("Save") {
                    if data == nil { AppearancePresets.save(slot) } else { confirmReplace = true }
                }
            }
            .controlSize(.small)
        }
        .confirmationDialog("Replace Preset \(slot) with the current settings?", isPresented: $confirmReplace) {
            Button("Replace") { AppearancePresets.save(slot) }
            Button("Cancel", role: .cancel) {}
        }
    }
}

/// Solid / dashed switch for the chart line whose style is stored under `key`.
/// Solid, dashes or small dots, stored as the line's dashed key and its dots key beside it.
private struct LineStylePicker: View {
    @AppStorage private var dashed: Bool
    @AppStorage private var dots: Bool

    private enum Style { case solid, dashes, dots }

    init(key: String, default dashedDefault: Bool) {
        _dashed = AppStorage(wrappedValue: dashedDefault, key)
        _dots = AppStorage(wrappedValue: LineDashes.defaultDots(key), LineDashes.dotsKey(key))
    }

    private var style: Binding<Style> {
        Binding(get: { !dashed ? .solid : dots ? .dots : .dashes },
                set: { style in
                    dashed = style != .solid
                    if style != .solid { dots = style == .dots }
                })
    }

    var body: some View {
        Picker("", selection: style) {
            Text("Solid").tag(Style.solid)
            Text("Dashes").tag(Style.dashes)
            Text("Dots").tag(Style.dots)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
    }
}

/// A few mini candles alternating up/down, to preview a theme.
private struct CandleSwatch: View {
    let up: Color
    let down: Color
    /// A chart theme's background behind them.
    var scene: ChartScene? = nil

    private static let candles: [(isUp: Bool, low: CGFloat, open: CGFloat, close: CGFloat, high: CGFloat)] = [
        (true, 0.15, 0.30, 0.65, 0.80),
        (false, 0.35, 0.70, 0.45, 0.85),
        (true, 0.25, 0.40, 0.90, 1.00),
        (false, 0.05, 0.85, 0.25, 0.95),
    ]

    var body: some View {
        Canvas { ctx, size in
            if let scene {
                ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 3),
                         with: .linearGradient(scene.background, startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            }
            let slot = size.width / CGFloat(Self.candles.count)
            func y(_ v: CGFloat) -> CGFloat { size.height * (1 - v) }
            for (i, c) in Self.candles.enumerated() {
                let color = c.isUp ? up : down
                let midX = slot * (CGFloat(i) + 0.5)
                var wick = Path()
                wick.move(to: CGPoint(x: midX, y: y(c.high)))
                wick.addLine(to: CGPoint(x: midX, y: y(c.low)))
                ctx.stroke(wick, with: .color(color), lineWidth: 1)
                let top = y(max(c.open, c.close)), bottom = y(min(c.open, c.close))
                ctx.fill(Path(CGRect(x: midX - slot * 0.3, y: top, width: slot * 0.6, height: bottom - top)),
                         with: .color(color))
            }
        }
        .frame(width: 36, height: 18)
    }
}
