//
//  AccountBar.swift
//  TWZ
//

import SwiftUI

struct AccountBar: View {
    @Environment(Broker.self) private var broker
    @Environment(Workspace.self) private var workspace
    @AppStorage(MainGrid.columnsKey) private var gridColumns = 2
    @AppStorage(MainGrid.rowsKey) private var gridRows = 2
    @AppStorage(MainGrid.zoomKey) private var gridZoom: Double = ChartModel.initialVisibleBars
    @AppStorage(MainGrid.timeframeKey) private var gridTimeframe: Timeframe = .m1
    @AppStorage(AccountBarPosition.storageKey) private var position: AccountBarPosition = .top
    /// Distance from the window's top edge to the center of the close/minimize/zoom buttons.
    @State private var controlsCenterY: CGFloat = 14

    /// Room for the close/minimize/zoom buttons at the leading edge.
    private static let trafficLightsWidth: CGFloat = 80

    var body: some View {
        // Two groups with a small least gap between them, so the left one can come close to the right one
        // in a narrow window before anything in it is squeezed.
        HStack(spacing: 0) {
            HStack(spacing: 18) {
                // LIVE or PAPER, in the trade mode's color: green while LONG, red while SHORT.
                AccountBadge(isLive: broker.isLivePort)

                OrderShortcutsBadge(isOn: workspace.orderShortcutsOn)

                // Account values are in the base currency (NOK), shown as bare numbers.
                HStack(spacing: 12) {
                    stat("Equity", Fmt.amount(broker.netLiquidation))
                    stat("P/L Today", Fmt.amount(broker.dailyPnL, signed: true))
                    stat("Unrealized", Fmt.amount(broker.unrealizedPnL, signed: true))
                    stat("Positions", Fmt.amount(broker.totalPositionValueNOK))
                }

                // The chart grid's size, its charts' zoom and timeframe (see `ChartGrid`).
                // Zoom moved by hand trumps the lit scale's (see `Workspace.manualZoom`).
                GridSliders(columns: $gridColumns, rows: $gridRows,
                            zoom: Binding(get: { gridZoom }, set: { gridZoom = $0; workspace.manualZoom = $0 }),
                            columnRange: 2...MainGrid.maxColumns, rowRange: 2...MainGrid.maxRows)
                    .background(NoWindowDrag())

                HStack(spacing: 8) {
                    TimeframePicker(selection: $gridTimeframe)
                        .help("Every chart's timeframe (⌥1–6, or ⌘1–6 with KEYS off: 1m, 5m, 15m, 30m, 1h, D); a chart's own switch changes just that chart, until it gets a new gainer or Reset")

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
                    .help("⌘⇧R. Every chart follows the list loaded into the grid in order again (the top gainers unless another list was loaded), on the timeframe beside it and at the Zoom slider's zoom (zooms and places kept on other timeframes stay); charts set by hand let go of their stock")

                    ScaleButtons()
                }
                .fixedSize()
            }

            Spacer(minLength: 10)

            HStack(spacing: 18) {
                IndicatorToggles()

                // The status text (e.g. why it disconnected) shows on hover; disconnected, a click connects.
                Circle().fill(statusColor).frame(width: 8, height: 8)
                    .padding(4)
                    .contentShape(Rectangle())
                    .onTapGesture { if broker.state == .disconnected { broker.connect() } }
                    .help(broker.state == .disconnected ? "\(broker.statusText) · click to connect" : broker.statusText)

                Button {
                    workspace.showsSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help("Settings")
            }
        }
        // At the top, beside the window controls and centered on them, so the stats line up with them;
        // at the bottom (controls hidden), from the window's edge.
        .padding(.leading, position == .top ? Self.trafficLightsWidth : 12)
        .padding(.trailing, 12)
        .frame(height: position == .top ? max(28, controlsCenterY * 2) : 28)
        .background(.bar)
        .background(WindowControlsProbe { controlsCenterY = $0 })
    }

    private var statusColor: Color {
        switch broker.state {
        case .connected: .green
        case .connecting: .yellow
        case .disconnected: .red
        }
    }

    /// One line of plain text, small like the bar's buttons: the title dimmed, the value a little
    /// brighter; a point lower, in line with the buttons' text.
    private func stat(_ title: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(title).foregroundStyle(Color.secondary.opacity(0.7))
            Text(value).foregroundStyle(Color.primary.opacity(0.8))
        }
        .font(.system(size: 10).monospacedDigit())
        .offset(y: 1)
    }
}

/// The top bar's numbers, styled like the timeframe switch. By default view sets (see `ViewSet`): ⇧-click
/// saves every chart's zoom and place on every timeframe, a click puts them back and lights it. With
/// Settings' "Top bar numbers are scales" on, scales (see `ChartScale`): a click gives every chart the
/// view saved under that number, and lights it: charts loading another stock take it too, until it's
/// clicked again or Reset; ⇧-click saves the selected chart's view there. Either way a lit number
/// clicked again goes off, and numbers with nothing saved are dimmer.
private struct ScaleButtons: View {
    @Environment(Broker.self) private var broker
    @Environment(Workspace.self) private var workspace
    @AppStorage(NumberButtons.scalesKey) private var asScales = NumberButtons.defaultScales

    var body: some View {
        HStack(spacing: 1) {
            ForEach(ChartScale.slots, id: \.self) { slot in
                let lit = asScales ? workspace.activeScale == slot : workspace.activeViewSet == slot
                let saved = asScales ? workspace.chartScales[slot] != nil : workspace.viewSets[slot] != nil
                Button {
                    pick(slot)
                } label: {
                    Text("\(slot)")
                        .font(.system(size: 10, weight: lit ? .semibold : .regular).monospacedDigit())
                        .foregroundStyle(lit ? Color.primary : Color.secondary.opacity(saved ? 0.7 : 0.35))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(lit ? 0.12 : 0)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(help(slot, saved: saved))
            }
        }
        // Switching what the numbers are: scales apply to charts loading another stock only as scales.
        .onChange(of: asScales) { workspace.syncGridScale(to: broker) }
    }

    private func help(_ slot: Int, saved: Bool) -> String {
        if !asScales {
            return saved ? "Every chart's zoom and place on every timeframe go back to view set \(slot); click again to turn it off. ⇧-click saves them here instead"
                         : "⇧-click saves every chart's zoom and place on every timeframe as view set \(slot)"
        }
        return saved ? "Every chart takes scale \(slot), its zoom, place and price scale, also as lists change; click again to turn it off. ⇧-click saves the selected chart's view here instead"
                     : "⇧-click saves the selected chart's view (zoom, place and price scale) as scale \(slot)"
    }

    private func pick(_ slot: Int) {
        let shift = NSEvent.modifierFlags.contains(.shift)
        if !asScales {
            if shift { workspace.saveViewSet(slot, broker: broker) } else { workspace.pickViewSet(slot, broker: broker) }
            return
        }
        if shift {
            if workspace.saveScale(slot), let symbol = workspace.chart(id: workspace.selectedChartID)?.symbol {
                broker.say("Scale \(slot) saved from \(symbol)'s view")
            } else {
                NSSound.beep()
                broker.say("Select a chart to save its view as scale \(slot)")
            }
        } else {
            workspace.pickScale(slot, byClick: true, broker: broker)
        }
    }
}

/// LIVE or PAPER (the gateway port), in the color of the trade mode Mode hotkeys go by (see
/// `TradeMode`): green while LONG, red while SHORT.
private struct AccountBadge: View {
    let isLive: Bool
    @AppStorage(TradeMode.storageKey) private var mode: TradeMode = .long

    var body: some View {
        Text(isLive ? "LIVE" : "PAPER")
            .font(.system(size: 10, weight: .heavy))
            .foregroundStyle(.white)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(mode == .long ? Color.green.opacity(0.8) : Color.red.opacity(0.85)))
            .help("\(isLive ? "Live" : "Paper") account · \(mode == .long ? "LONG" : "SHORT"): Mode hotkeys \(mode == .long ? "buy" : "sell short"). ⌘⇧ with L and O held together: LONG; with S and H: SHORT")
    }
}

/// Whether the keyboard shortcuts that send orders work: KEYS ON in orange while they do, dimmed while off.
private struct OrderShortcutsBadge: View {
    let isOn: Bool

    var body: some View {
        Text(isOn ? "KEYS ON" : "KEYS OFF")
            .font(.system(size: 10, weight: isOn ? .heavy : .regular))
            .foregroundStyle(isOn ? Color.white : Color.secondary.opacity(0.7))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(isOn ? Color.orange : Color.primary.opacity(0.08)))
            .help("Order shortcuts (hotkeys' own keys, ⌘⇧↩ and ⌘⌫) \(isOn ? "send orders" : "are off")."
                  + " ⌘ and the Globe (fn) key turn them on or off; they're off at every launch. Cancelling (⌘A, ⌘Z, ⌥Z, ⌥<) and what-if trades always work.")
    }
}

/// Turns the charts' indicator lines on and off (the same settings as Settings › Appearance),
/// styled like the charts' timeframe switch: the lit chips are the lines being drawn.
private struct IndicatorToggles: View {
    @AppStorage(Indicators.vwapKey) private var showVWAP = true
    @AppStorage(Indicators.fastSMAKey) private var showFastSMA = true
    @AppStorage(Indicators.slowSMAKey) private var showSlowSMA = true
    @AppStorage(Indicators.tradesKey) private var showTrades = false

    var body: some View {
        HStack(spacing: 1) {
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
