//
//  AccountBar.swift
//  TWZ
//

import SwiftUI

struct AccountBar: View {
    @Environment(Broker.self) private var broker
    @State private var showSettings = false
    /// Distance from the window's top edge to the center of the close/minimize/zoom buttons.
    @State private var controlsCenterY: CGFloat = 14

    /// Room for the close/minimize/zoom buttons at the leading edge.
    private static let trafficLightsWidth: CGFloat = 80

    var body: some View {
        HStack(spacing: 18) {
            Text(broker.isLivePort ? "LIVE" : "PAPER")
                .font(.system(size: 10, weight: .heavy))
                .foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(broker.isLivePort ? Color.red : Color.blue))

            stat("Equity", Fmt.money(broker.netLiquidation))
            stat("P/L Today", Fmt.money(broker.dailyPnL, signed: true), color: color(broker.dailyPnL))
            stat("Unrealized", Fmt.money(broker.unrealizedPnL, signed: true), color: color(broker.unrealizedPnL))
            stat("Realized", Fmt.money(broker.realizedPnL, signed: true), color: color(broker.realizedPnL))
            stat("Positions", Fmt.money(broker.totalPositionValue))

            Spacer()

            HStack(spacing: 6) {
                Circle().fill(statusColor).frame(width: 8, height: 8)
                Text(broker.statusText).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }

            Button(broker.state == .disconnected ? "Connect" : "Disconnect") {
                broker.state == .disconnected ? broker.connect() : broker.disconnect()
            }
            .controlSize(.small)

            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Connection settings")
        }
        .padding(.leading, Self.trafficLightsWidth)
        .padding(.trailing, 12)
        // Centered on the window controls, so the stats line up with them.
        .frame(height: max(28, controlsCenterY * 2))
        .background(.bar)
        .background(WindowControlsProbe { controlsCenterY = $0 })
        .sheet(isPresented: $showSettings) { SettingsView() }
    }

    private var statusColor: Color {
        switch broker.state {
        case .connected: .green
        case .connecting: .yellow
        case .disconnected: .red
        }
    }

    private func color(_ v: Double?) -> Color {
        guard let v, v != 0 else { return .primary }
        return v > 0 ? .green : .red
    }

    private func stat(_ title: String, _ value: String, color: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 13, weight: .semibold).monospacedDigit()).foregroundStyle(color)
        }
    }
}

/// Reports how far below the window's top edge the window controls are centered.
private struct WindowControlsProbe: NSViewRepresentable {
    var onChange: (CGFloat) -> Void

    func makeNSView(context: Context) -> Probe { Probe(onChange: onChange) }
    func updateNSView(_ view: Probe, context: Context) { view.onChange = onChange }

    final class Probe: NSView {
        var onChange: (CGFloat) -> Void

        init(onChange: @escaping (CGFloat) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // The title bar buttons are laid out after the content view joins the window.
            DispatchQueue.main.async { [weak self] in
                guard let self, let window,
                      let button = window.standardWindowButton(.closeButton) else { return }
                let frame = button.convert(button.bounds, to: nil)
                onChange((window.frame.height - frame.midY).rounded())
            }
        }
    }
}

struct SettingsView: View {
    @Environment(Broker.self) private var broker
    @Environment(\.dismiss) private var dismiss

    @State private var host = ""
    @State private var port = 4002
    @State private var clientId = 1
    @State private var allowDelayed = true
    @State private var confirmLive = false

    private let presets: [(String, Int)] = [
        ("IB Gateway – Paper", 4002), ("IB Gateway – Live", 4001),
        ("TWS – Paper", 7497), ("TWS – Live", 7496),
    ]

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
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .onAppear {
            host = broker.host
            port = broker.port
            clientId = broker.clientId
            allowDelayed = broker.allowDelayedData
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save & Reconnect") {
                    let goingLive = (port == 4001 || port == 7496) && !broker.isLivePort
                    if goingLive { confirmLive = true } else { apply() }
                }
            }
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
        dismiss()
    }
}
