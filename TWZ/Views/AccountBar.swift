//
//  AccountBar.swift
//  TWZ
//

import SwiftUI

struct AccountBar: View {
    @Environment(Broker.self) private var broker
    @Environment(Workspace.self) private var workspace
    @State private var showSettings = false
    @AppStorage(MainGrid.columnsKey) private var gridColumns = 2
    @AppStorage(MainGrid.rowsKey) private var gridRows = 2
    @AppStorage(MainGrid.zoomKey) private var gridZoom: Double = ChartModel.initialVisibleBars
    @AppStorage(MainGrid.timeframeKey) private var gridTimeframe: Timeframe = .m1
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

            // Account values are in the base currency (NOK), shown as bare numbers.
            stat("Equity", Fmt.amount(broker.netLiquidation))
            stat("P/L Today", Fmt.amount(broker.dailyPnL, signed: true), color: color(broker.dailyPnL))
            stat("Unrealized", Fmt.amount(broker.unrealizedPnL, signed: true), color: color(broker.unrealizedPnL))
            stat("Positions", Fmt.amount(broker.totalPositionValueNOK))

            // The chart grid's size, its charts' zoom and timeframe (see `ChartGrid`).
            GridSliders(columns: $gridColumns, rows: $gridRows, zoom: $gridZoom,
                        columnRange: 2...MainGrid.maxColumns, rowRange: 2...MainGrid.maxRows)
                .background(NoWindowDrag())

            HStack(spacing: 8) {
                TimeframePicker(selection: $gridTimeframe)
                    .help("Every chart's timeframe; a chart's own switch changes just that chart, until it gets a new gainer or Reset")

                Button {
                    workspace.resetToGainers()
                } label: {
                    Text("Reset")
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(Color.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.08)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Every chart shows the top gainers in order again, on the timeframe beside it and at the Zoom slider's zoom; charts set by hand let go of their stock")
            }

            Spacer()

            IndicatorToggles()

            // The status text (e.g. why it disconnected) shows on hover.
            Circle().fill(statusColor).frame(width: 8, height: 8)
                .help(broker.statusText)

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
            .help("Settings")
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

/// Turns the charts' indicator lines on and off (the same settings as Settings › Appearance),
/// styled like the charts' timeframe switch: the lit chips are the lines being drawn. "Alt-Click" first
/// switches ⌥-click chart orders.
private struct IndicatorToggles: View {
    @AppStorage(Indicators.vwapKey) private var showVWAP = true
    @AppStorage(Indicators.fastSMAKey) private var showFastSMA = true
    @AppStorage(Indicators.slowSMAKey) private var showSlowSMA = true
    @AppStorage(Indicators.tradesKey) private var showTrades = false
    @AppStorage(AltClickOrders.enabledKey) private var altClickOrders = true

    var body: some View {
        HStack(spacing: 1) {
            chip("Alt-Click", isOn: $altClickOrders, help: "Turn ⌥-click chart orders on or off")
            chip("Trades", isOn: $showTrades)
            chip("VWAP", isOn: $showVWAP)
            chip("SMA9", isOn: $showFastSMA)
            chip("SMA21", isOn: $showSlowSMA)
        }
    }

    private func chip(_ title: String, isOn: Binding<Bool>, help: String? = nil) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            Text(title)
                .font(.system(size: 10, weight: isOn.wrappedValue ? .semibold : .regular).monospacedDigit())
                .foregroundStyle(isOn.wrappedValue ? Color.primary : Color.secondary.opacity(0.7))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(isOn.wrappedValue ? 0.12 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help ?? "Show or hide \(title) on the charts")
    }
}

/// Keeps the window from moving while the pointer is over its area. The account bar sits in the
/// title bar, where dragging a slider would otherwise move the window.
private struct NoWindowDrag: NSViewRepresentable {
    func makeNSView(context: Context) -> Tracker { Tracker() }
    func updateNSView(_ view: Tracker, context: Context) {}

    final class Tracker: NSView {
        override var mouseDownCanMoveWindow: Bool { false }

        // Clicks go to the sliders on top; this view only tracks the pointer.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                           owner: self))
        }

        override func mouseEntered(with event: NSEvent) { window?.isMovable = false }
        override func mouseExited(with event: NSEvent) { window?.isMovable = true }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            window?.isMovable = true
            super.viewWillMove(toWindow: newWindow)
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
