//
//  SettingsView.swift
//  TWZ
//
//  Settings sheet: Connection (IB Gateway host/port/client, applied on reconnect)
//  and Appearance (candle colors, applied immediately).
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
    @State private var allowDelayed = true
    @State private var confirmLive = false

    private let presets: [(String, Int)] = [
        ("IB Gateway – Paper", 4002), ("IB Gateway – Live", 4001),
        ("TWS – Paper", 7497), ("TWS – Live", 7496),
    ]

    private var hasChanges: Bool {
        host.trimmingCharacters(in: .whitespaces) != broker.host || port != broker.port
            || clientId != broker.clientId || allowDelayed != broker.allowDelayedData
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
                Toggle("Fall back to delayed data when not subscribed", isOn: $allowDelayed)
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
            allowDelayed = broker.allowDelayedData
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
        broker.allowDelayedData = allowDelayed
        broker.disconnect()
        broker.connect()
    }
}

// MARK: - Appearance

private struct AppearanceSettings: View {
    @AppStorage(CandleTheme.storageKey) private var theme: CandleTheme = .teal
    @AppStorage(CandleTheme.customUpKey) private var customUp = CandleTheme.defaultUpHex
    @AppStorage(CandleTheme.customDownKey) private var customDown = CandleTheme.defaultDownHex

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
                    ColorPicker("Up candles", selection: hexBinding($customUp, fallback: CandleTheme.defaultUpHex),
                                supportsOpacity: false)
                    ColorPicker("Down candles", selection: hexBinding($customDown, fallback: CandleTheme.defaultDownHex),
                                supportsOpacity: false)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func hexBinding(_ hex: Binding<String>, fallback: String) -> Binding<Color> {
        Binding(
            get: { Color(hex: hex.wrappedValue) ?? Color(hex: fallback)! },
            set: { hex.wrappedValue = $0.hex }
        )
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
