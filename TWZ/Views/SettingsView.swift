//
//  SettingsView.swift
//  TWZ
//
//  Settings sheet: Connection (IB Gateway host/port/client, applied on reconnect),
//  Trading (what clicking a hotkey button does, and the keyboard shortcuts)
//  and Appearance (candle and chart line colors, applied immediately).
//

import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("settingsTab") private var tab: Tab = .connection

    enum Tab: String, CaseIterable, Identifiable {
        case connection = "Connection"
        case trading = "Trading"
        case appearance = "Appearance"
        var id: String { rawValue }

        var icon: String {
            switch self {
            case .connection: "network"
            case .trading: "keyboard"
            case .appearance: "paintpalette"
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

private struct TradingSettings: View {
    @Environment(Workspace.self) private var workspace
    @AppStorage(HotkeyClickMode.storageKey) private var clickMode: HotkeyClickMode = .select

    private let shortcuts: [(String, String)] = [
        ("⌘↩", "Send the selected hotkey"),
        ("⌘A  /  ⌥<", "Cancel every order in the chart's symbol, stop loss and take profit included"),
        ("⌘S", "Close 100% of the chart's position at market"),
        ("⌘Z  /  ⌥Z", "Cancel the last order placed"),
        ("Own shortcut", "Send that hotkey (set in the hotkey editor)"),
    ]

    var body: some View {
        Form {
            Section("Hotkey buttons") {
                Picker("Clicking a button", selection: $clickMode) {
                    ForEach(HotkeyClickMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.radioGroup)
                Text(clickMode == .send
                     ? "Fires as the mouse goes down. The clicked button is also selected, so ⌘↩ sends it again."
                     : "Click picks the hotkey; ⌘↩ sends it for the selected chart's symbol.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
    @AppStorage(LineColors.ordersKey) private var ordersHex = ""
    @AppStorage(LineColors.showLastPriceLineKey) private var showLastPriceLine = true
    @AppStorage(SelectedOutline.widthKey) private var outlineWidth = SelectedOutline.defaultWidth
    @AppStorage(TimeframePickerStyle.storageKey) private var pickerStyle: TimeframePickerStyle = .minimal
    @AppStorage(Indicators.vwapKey) private var showVWAP = true
    @AppStorage(Indicators.fastSMAKey) private var showFastSMA = true
    @AppStorage(Indicators.slowSMAKey) private var showSlowSMA = true
    @AppStorage(Indicators.tradesKey) private var showTrades = false
    @AppStorage(Indicators.lineWidthKey) private var indicatorWidth = Indicators.defaultLineWidth
    @AppStorage(PriceAxis.fontSizeKey) private var axisFontSize = PriceAxis.defaultFontSize
    @AppStorage(PriceAxis.labelSpacingKey) private var labelSpacing = PriceAxis.defaultLabelSpacing
    @AppStorage(PriceAxis.lastPriceOpacityKey) private var lastPriceOpacity = PriceAxis.defaultLastPriceOpacity

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
                LabeledContent("Last trade (Exit / Avg)") {
                    LineStylePicker(key: LineDashes.lastTradeKey, default: LineDashes.defaultLastTrade)
                }
            }
            Section("Indicators") {
                Toggle("VWAP (intraday charts)", isOn: $showVWAP)
                Toggle("SMA 9", isOn: $showFastSMA)
                Toggle("SMA 21", isOn: $showSlowSMA)
                Toggle("Trades (▲ buys, ▼ sells)", isOn: $showTrades)
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
            Section("Chart header") {
                Picker("Timeframe picker", selection: $pickerStyle) {
                    ForEach(TimeframePickerStyle.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Section("Selected chart") {
                LabeledContent("Outline thickness") {
                    HStack {
                        Slider(value: $outlineWidth, in: SelectedOutline.range, step: 0.25)
                        Text("\(outlineWidth.formatted(.number.precision(.fractionLength(0...2)))) pt")
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
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

    /// Color swatch, solid / dashed switch, and a Reset button while a custom color is set (empty hex = default).
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
private struct LineStylePicker: View {
    @AppStorage private var dashed: Bool

    init(key: String, default dashedDefault: Bool) {
        _dashed = AppStorage(wrappedValue: dashedDefault, key)
    }

    var body: some View {
        Picker("", selection: $dashed) {
            Text("Solid").tag(false)
            Text("Dashed").tag(true)
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
