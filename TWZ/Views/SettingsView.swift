//
//  SettingsView.swift
//  TWZ
//
//  Settings sheet: Connection (IB Gateway host/port/client, applied on reconnect)
//  and Appearance (candle and chart line colors, applied immediately).
//

import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("settingsTab") private var tab: Tab = .connection

    enum Tab: String, CaseIterable, Identifiable {
        case connection = "Connection"
        case appearance = "Appearance"
        var id: String { rawValue }

        var icon: String {
            switch self {
            case .connection: "network"
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
            if port == 4001 || port == 7496 {
                Text("⚠︎ Live trading: hotkeys will send real orders.")
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Save & Reconnect") {
                    let goingLive = (port == 4001 || port == 7496) && !broker.isLivePort
                    if goingLive { confirmLive = true } else { apply() }
                }
                .disabled(!hasChanges)
            }
        }
        .formStyle(.grouped)
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

// MARK: - Appearance

private struct AppearanceSettings: View {
    @AppStorage(CandleTheme.storageKey) private var theme: CandleTheme = .teal
    @AppStorage(CandleTheme.customUpKey) private var customUp = CandleTheme.defaultUpHex
    @AppStorage(CandleTheme.customDownKey) private var customDown = CandleTheme.defaultDownHex
    @AppStorage(LineColors.lastPriceKey) private var lastPriceHex = ""
    @AppStorage(LineColors.avgCostKey) private var avgCostHex = ""
    @AppStorage(LineColors.altClickKey) private var altClickHex = ""
    @AppStorage(LineColors.hoverKey) private var hoverHex = ""
    @AppStorage(SelectedOutline.widthKey) private var outlineWidth = SelectedOutline.defaultWidth
    @AppStorage(TimeframePickerStyle.storageKey) private var pickerStyle: TimeframePickerStyle = .minimal
    @AppStorage(Indicators.vwapKey) private var showVWAP = true
    @AppStorage(Indicators.fastSMAKey) private var showFastSMA = true
    @AppStorage(Indicators.slowSMAKey) private var showSlowSMA = true
    @AppStorage(Indicators.lineWidthKey) private var indicatorWidth = Indicators.defaultLineWidth
    @AppStorage(PriceAxis.fontSizeKey) private var axisFontSize = PriceAxis.defaultFontSize
    @AppStorage(PriceAxis.labelSpacingKey) private var labelSpacing = PriceAxis.defaultLabelSpacing
    @AppStorage(PriceAxis.lastPriceOpacityKey) private var lastPriceOpacity = PriceAxis.defaultLastPriceOpacity

    var body: some View {
        Form {
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
                             default: LineColors.defaultLastPrice)
                lineColorRow("Average position", key: LineColors.avgCostKey, hex: $avgCostHex,
                             default: LineColors.defaultAvgCost)
                lineColorRow("⌥-click orders", key: LineColors.altClickKey, hex: $altClickHex,
                             default: LineColors.defaultAltClick)
                lineColorRow("Hover price", key: LineColors.hoverKey, hex: $hoverHex,
                             default: LineColors.defaultHover)
            }
            Section("Indicators") {
                Toggle("VWAP (intraday charts)", isOn: $showVWAP)
                Toggle("SMA 9", isOn: $showFastSMA)
                Toggle("SMA 21", isOn: $showSlowSMA)
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

    /// Color swatch plus a Reset button while a custom color is set (empty hex = default).
    private func lineColorRow(_ title: String, key: String, hex: Binding<String>, default fallback: Color) -> some View {
        HStack {
            ColorWell(title: title, key: key, color: LineColors.resolve(hex.wrappedValue, default: fallback))
            if !hex.wrappedValue.isEmpty {
                Button("Reset") { hex.wrappedValue = "" }
                    .controlSize(.small)
            }
        }
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
