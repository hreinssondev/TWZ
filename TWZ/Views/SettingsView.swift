//
//  SettingsView.swift
//  TWZ
//
//  Settings sheet: Connection (IB Gateway host/port/client, applied on reconnect),
//  Trading (what clicking a hotkey button does, and the keyboard shortcuts),
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
        case appearance = "Appearance"
        case layouts = "Layouts"
        var id: String { rawValue }

        var icon: String {
            switch self {
            case .connection: "network"
            case .trading: "keyboard"
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
            case .appearance: AppearanceSettings()
            case .layouts: LayoutSettings()
            }
        }
        .frame(width: 460, height: 440)
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

    private let shortcuts: [(String, String)] = [
        ("⌘🌐 (⌘ fn)", "Turn the shortcuts that send orders (hotkeys' own, ⌘⇧↩, ⌘⌫) on or off; off at every launch, KEYS ON in the top bar while on, when ⌘1–3 buy and ⌘4–9 are the hotkeys' instead of timeframes"),
        ("⌘⇧↩", "Send the selected hotkey button's order, or with none selected the order pad's"),
        ("⌘↩", "Keep the selected chart's tick-by-tick trades on or off once it's deselected (⚡ while on, "
            + "a red circle once IB's limit leaves it out); the selected chart always gets trades and bid/ask"),
        ("⌘A  /  ⌥<", "Cancel every order in the chart's symbol, stop loss and take profit included (⌘A also removes its ⌃-click what-if); with no chart selected, ⌘A cancels the last order placed, as ⌘Z"),
        ("⌘⌫", "Cancel every order in the chart's symbol, then close 100% of the position at market; removes its ⌃-click what-if too"),
        ("⌘⇧⌫", "Remove the chart's ⌃-click what-if (so does double-clicking anywhere on the chart)"),
        ("⌘Z  /  ⌥Z", "Cancel the last order placed"),
        ("⌃⌥⇧1 2 3 4", "What-if trade: sell (short) $1,000 / $2,000 / $3,000 / 85% of the buying power, simulated and never sent to IB "
            + "(not in a stock with a real position); ⌃-click its chart for a simulated stop loss or take profit, ⌘⌫ closes it"),
        ("⌘⇧S L H A F", "Show that list and load it into the chart grid: Most Active $, Top Losers, AH Gainers, "
            + "Top Gainers, Forex (S, H and L wait a moment for a second letter)"),
        ("⌘⇧ L+O  /  S+H", "Both letters held together: the trade mode, LONG or SHORT (the top bar's LIVE / PAPER badge green or red); Mode hotkeys buy while LONG, sell short while SHORT"),
        ("⌥, ⇧ or ⌥⇧ 1 2 3 4 5 6", "Every chart's timeframe: 1m / 5m / 15m / 30m / 1h / D (also ⌘ 1–6 with KEYS off)"),
        ("⌘ 1 2 3 with KEYS ON", "Buy $1,000 / $2,000 / $3,000 of the selected chart's stock: limit at the mid, no offset, outside regular hours too"),
        ("⌘ 4–9 with KEYS ON", "Free for hotkeys: give a hotkey button one as its shortcut to send its order"),
        ("⌘⌥ 1–9", "A Mode order (buy while LONG, short while SHORT) of 10–90% of the buying power IB allows in the stock: limit at the mid, no offset, outside regular hours too (with KEYS ON)"),
        ("⌘R, ⇧R or ⌘⇧R", "Reset, as the top bar's button: every chart follows the grid's list again"),
        ("⌥0  /  ⇧A", "Every other chart takes the selected chart's view: zoom, place and price scale (the same time span and right edge on other timeframes); ⇧A not while typing"),
        ("1 2 3 4 5 (top bar)", "View sets (by default): ⇧-click a number saves every chart's zoom and place on every timeframe; a click puts them back. With Appearance's \"Top bar numbers are scales\" on, scales: a click: every chart takes that saved scale (zoom, place and price scale), and keeps taking it as lists change until it's clicked again or Reset (a timeframe switch keeps each chart's view). The Zoom slider or ⇧- / ⌘- / ⌥-swipe trumps its zoom until a scale is picked; a chart zoomed or panned by hand keeps its view (per stock and timeframe) through list switches, until a number is clicked (or a right-click on that chart). Each list keeps its own views and lit scale. ⇧-click: save the selected chart's view as it"),
        ("Own shortcut", "Send that hotkey (set in the hotkey editor)"),
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
                     ? "Hovering a chart shows the P/L of buying that percent (1–100) of the largest long IB's margin allows at the last price, asked from IB as the pointer comes over the chart (a second or two, then kept a minute: the same answer as the chart header's buying power)."
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
            Section("Charts window") {
                @Bindable var workspace = workspace
                ShortcutRecorder(title: "Show / hide shortcut", shortcut: $workspace.chartsWindowShortcut, owner: .chartsWindow)
                if let failure = GlobalHotkey.shared.failure {
                    Text(failure).font(.caption).foregroundStyle(.red)
                }
                Text("Works from any app: shows the Charts window in front (opening it if needed); pressed again, hides the app and goes back to the one before. Hidden, its charts stay live, so it comes back instantly. Closing the window turns them off like P.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if workspace.chartsWindowShortcut?.isPlain == true {
                    Text("A single key works in every app, so other apps can't type it while it's set.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
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
                Text("Panel sizes, one list or two and their columns, the chart grid's size, lines, zoom and space, and every Appearance setting (colors, line styles, indicators). Loading one leaves the charts' stocks and timeframes and the lists' scanners as they are.")
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
    @AppStorage(SelectedOutline.widthKey) private var outlineWidth = SelectedOutline.defaultWidth
    @AppStorage(TimeframePickerStyle.storageKey) private var pickerStyle: TimeframePickerStyle = .minimal
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

    /// The selected chart's outline as it's drawn: the stored width is a third of it (see `SelectedOutline`).
    private var selectedOutline: Binding<Double> {
        Binding(get: { outlineWidth * SelectedOutline.selectedMultiple },
                set: { outlineWidth = $0 / SelectedOutline.selectedMultiple })
    }

    var body: some View {
        Form {
            Section("Presets") {
                ForEach(Array(AppearancePresets.slots), id: \.self) { PresetRow(slot: $0) }
            }
            Section("Candle colors") {
                ForEach(CandleTheme.allCases) { option in
                    let colors = option.colors(customUp: customUp, customDown: customDown)
                    Button {
                        theme = option
                    } label: {
                        HStack(spacing: 10) {
                            CandleSwatch(up: colors.up, down: colors.down)
                            Text(option.rawValue)
                            Spacer()
                            if theme == option {
                                Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if theme == .custom {
                    ColorWell(title: "Up candles", key: CandleTheme.customUpKey,
                              color: Color(hex: customUp) ?? Color(hex: CandleTheme.defaultUpHex)!)
                    ColorWell(title: "Down candles", key: CandleTheme.customDownKey,
                              color: Color(hex: customDown) ?? Color(hex: CandleTheme.defaultDownHex)!)
                }
            }
            Section("App colors") {
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

    private static let candles: [(isUp: Bool, low: CGFloat, open: CGFloat, close: CGFloat, high: CGFloat)] = [
        (true, 0.15, 0.30, 0.65, 0.80),
        (false, 0.35, 0.70, 0.45, 0.85),
        (true, 0.25, 0.40, 0.90, 1.00),
        (false, 0.05, 0.85, 0.25, 0.95),
    ]

    var body: some View {
        Canvas { ctx, size in
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
