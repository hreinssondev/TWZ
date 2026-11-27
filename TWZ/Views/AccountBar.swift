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
                AccountSummary()

                // The chart grid's size, its charts' zoom and timeframe (see `ChartGrid`).
                // Zoom moved by hand trumps the lit scale's (see `Workspace.manualZoom`).
                GridSliders(columns: $gridColumns, rows: $gridRows,
                            zoom: Binding(get: { workspace.liveZooms[MainGrid.zoomKey] ?? gridZoom },
                                          set: { workspace.dropLiveZoom(MainGrid.zoomKey); gridZoom = $0; workspace.manualZoom = $0 }),
                            columnRange: 2...MainGrid.maxColumns, rowRange: 2...MainGrid.maxRows)
                    .background(NoWindowDrag())

                HStack(spacing: 8) {
                    TimeframePicker(selection: $gridTimeframe)
                        .help("Every chart's timeframe (⌥1–6 or ⌃1–6: 1m, 5m, 15m, 30m, 1h, D); a chart's own switch changes just that chart, until it gets a new gainer or Reset")

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
                    .help("⌘R, ⇧R, ⌥R, ⌃R or ⌘⇧R. Every chart follows the list loaded into the grid in order again (the top gainers unless another list was loaded), on the timeframe beside it and at the Zoom slider's zoom (zooms and places kept on other timeframes stay); charts set by hand let go of their stock")

                    // View sets / scales, then chart layouts, close together.
                    HStack(spacing: 3) {
                        ScaleButtons(window: .main)
                        GridLayoutButtons(window: .main, showsIcon: false)
                    }
                    if workspace.gridScan?.kind == .forex { MainForexButtons() }
                    ColoredColorsButton(list: workspace.gridScan?.kind ?? .gainers)
                }
                .fixedSize()
            }

            Spacer(minLength: 10)

            HStack(spacing: 18) {
                FrameMeterBadge()
                AccountStatusControls()
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

}

/// The account bar's account side: LIVE / PAPER (a click switches KEYS ON and SIM), KEYS ON / SIM, and the account's
/// values. Also in the Charts windows' title bar (see `ChartsWindowTitleBar`).
struct AccountSummary: View {
    @Environment(Broker.self) private var broker
    @Environment(Workspace.self) private var workspace

    var body: some View {
        HStack(spacing: 18) {
            // LIVE (red) or PAPER (blue).
            // A click switches KEYS ON and SIM, as ⌘🌐 does.
            AccountBadge(isLive: broker.isLivePort, isLit: workspace.orderShortcutsOn) {
                workspace.orderShortcutsOn.toggle()
                workspace.launchModeChosen = true
                broker.say(workspace.orderShortcutsOn ? "KEYS ON: order shortcuts go to IB, for real (⌘🌐: SIM)"
                                                      : "SIM: order shortcuts trade what-if positions, nothing goes to IB (⌘🌐: KEYS ON)")
            }

            OrderShortcutsBadge(isOn: workspace.orderShortcutsOn)

            // Account values are in the base currency (NOK), shown as bare numbers.
            HStack(spacing: 12) {
                stat("Equity", Fmt.amount(broker.netLiquidation))
                stat("P/L Today", Fmt.amount(broker.dailyPnL, signed: true))
                stat("Unrealized", Fmt.amount(broker.unrealizedPnL, signed: true))
                stat("Positions", Fmt.amount(broker.totalPositionValueNOK))
            }
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

/// The account bar's right end: the indicator switches, the connection dot (a click reconnects) and Settings. Also
/// in the Charts windows' title bar, where Settings brings the main window, its sheet's, to the front.
struct AccountStatusControls: View {
    @Environment(Broker.self) private var broker
    @Environment(Workspace.self) private var workspace

    var body: some View {
        HStack(spacing: 18) {
            IndicatorToggles()

            // The status text (e.g. why it disconnected) shows on hover; a click reconnects, as Settings ›
            // Connection's Reconnect does.
            Circle().fill(statusColor).frame(width: 8, height: 8)
                .padding(4)
                .contentShape(Rectangle())
                .onTapGesture {
                    broker.disconnect()
                    broker.connect()
                }
                .help("\(broker.statusText) · click to reconnect")

            Button {
                workspace.showsSettings = true
                NSApp.windows.first { ChartsWin.of($0) == nil && !OptionsWindow.isWindow($0) && $0.isVisible && $0.canBecomeMain }?
                    .makeKeyAndOrderFront(nil)
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Settings")
        }
    }

    private var statusColor: Color {
        switch broker.state {
        case .connected: .green
        case .connecting: .yellow
        case .disconnected: .red
        }
    }
}

/// A Charts window's title bar row, beside the window controls: what the main window's account bar has that the
/// window's own top bar hasn't (see `AccountSummary`, `AccountStatusControls`).
struct ChartsWindowTitleBar: View {
    @State private var controlsCenterY: CGFloat = 14

    var body: some View {
        HStack(spacing: 0) {
            AccountSummary()
                .fixedSize()
            Spacer(minLength: 10)
            AccountStatusControls()
                .fixedSize()
        }
        .padding(.leading, 80)
        .padding(.trailing, 12)
        .frame(height: max(28, controlsCenterY * 2))
        .background(WindowControlsProbe { controlsCenterY = $0 })
    }
}

/// The top bar's numbers, styled like the timeframe switch. By default view sets (see `ViewSet`): ⇧-click
/// saves every chart's zoom and place on every timeframe, a click puts them back and lights it. With
/// Settings' "Top bar numbers are scales" on, scales (see `ChartScale`): a click gives every chart the
/// view saved under that number, and lights it: charts loading another stock take it too, until it's
/// clicked again or Reset; ⇧-click saves the selected chart's view there. Either way a lit number
/// clicked again goes off, and numbers with nothing saved are dimmer.
/// The Charts window's header has its own (`window` .chartsWindow): view sets and scales of its own, for its charts.
struct ScaleButtons: View {
    @Environment(Broker.self) private var broker
    @Environment(Workspace.self) private var workspace
    @AppStorage(NumberButtons.scalesKey) private var asScales = NumberButtons.defaultScales
    let window: GridLayout.Window

    private var inChartsWindow: Bool { window.chartsWin != nil }
    private var cw: ChartsWindowState? { window.chartsWin.map(workspace.chartsWindow) }

    var body: some View {
        HStack(spacing: 1) {
            ForEach(ChartScale.slots, id: \.self) { slot in
                let lit = cw.map { asScales ? $0.activeScale == slot : $0.activeViewSet == slot }
                    ?? (asScales ? workspace.activeScale == slot : workspace.activeViewSet == slot)
                let saved = cw.map { asScales ? $0.scales[slot] != nil : $0.viewSets[slot] != nil }
                    ?? (asScales ? workspace.chartScales[slot] != nil : workspace.viewSets[slot] != nil)
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
        .onChange(of: asScales) {
            if inChartsWindow { workspace.syncChartsWindowScale(to: broker) } else { workspace.syncGridScale(to: broker) }
        }
    }

    private func help(_ slot: Int, saved: Bool) -> String {
        if inChartsWindow {
            if !asScales {
                return saved ? "Every chart here back to its zoom and place on every timeframe in view set \(slot) (⌥⇧\(slot) with this window in front); click again to turn it off. ⇧-click saves them here instead"
                             : "⇧-click saves every chart's zoom and place here on every timeframe as view set \(slot)"
            }
            return saved ? "Every chart here takes scale \(slot) (⌥⇧\(slot) with this window in front), also as its list changes; click again to turn it off. ⇧-click saves the selected chart's view here instead"
                         : "⇧-click saves the selected chart's view (one in this window) as scale \(slot)"
        }
        if !asScales {
            return saved ? "Every chart's zoom and place on every timeframe go back to view set \(slot) (⌥⇧\(slot)); click again to turn it off. ⇧-click saves them here instead"
                         : "⇧-click saves every chart's zoom and place on every timeframe as view set \(slot)"
        }
        return saved ? "Every chart takes scale \(slot) (⌥⇧\(slot)), its zoom, place and price scale, also as lists change; click again to turn it off. ⇧-click saves the selected chart's view here instead"
                     : "⇧-click saves the selected chart's view (zoom, place and price scale) as scale \(slot)"
    }

    private func pick(_ slot: Int) {
        let shift = NSEvent.modifierFlags.contains(.shift)
        if let win = window.chartsWin {
            if !asScales {
                if shift { workspace.saveChartsWindowViewSet(slot, in: win, broker: broker) } else { workspace.pickChartsWindowViewSet(slot, in: win, broker: broker) }
            } else if !shift {
                workspace.pickChartsWindowScale(slot, in: win, broker: broker)
            } else if workspace.saveChartsWindowScale(slot, in: win), let symbol = workspace.chart(id: workspace.selectedChartID)?.symbol {
                workspace.syncChartsWindowScale(to: broker)
                broker.say("\(win.name) scale \(slot) saved from \(symbol)'s view")
            } else {
                NSSound.beep()
                broker.say("Select a chart in the \(win.name) to save its view as scale \(slot)")
            }
            return
        }
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

/// LIVE (red) or PAPER (blue), the gateway port: lit with KEYS ON, dimmed like SIM's badge in SIM. A click
/// switches KEYS ON and SIM.
private struct AccountBadge: View {
    let isLive: Bool
    let isLit: Bool
    /// A click: KEYS ON or SIM.
    var onClick: () -> Void = {}

    var body: some View {
        Text(isLive ? "LIVE" : "PAPER")
            .font(.system(size: 10, weight: isLit ? .heavy : .regular))
            .foregroundStyle(isLit ? Color.white : Color.secondary.opacity(0.7))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(isLit ? (isLive ? Color.red.opacity(0.85) : Color.blue.opacity(0.8)) : Color.primary.opacity(0.08)))
            .contentShape(Capsule())
            .onTapGesture(perform: onClick)
            .help("\(isLive ? "Live" : "Paper") account\(isLit ? "" : "; dimmed in SIM, where order shortcuts don't go to it")"
                  + ". Click to switch \(isLit ? "to SIM" : "KEYS ON, order shortcuts going to IB for real") (⌘🌐 too).")
    }
}

/// Where the order shortcuts go and what their numbers are (see `SizeMode`): KEYS $ or KEYS % in orange with KEYS ON
/// (real orders), SIM $ or SIM % dimmed with it off (what-if trades). A click switches $ and %, as ⌘⇧M does.
private struct OrderShortcutsBadge: View {
    let isOn: Bool
    @Environment(Broker.self) private var broker
    @AppStorage(SizeMode.storageKey) private var sizeMode: SizeMode = .percent

    var body: some View {
        Text("\(isOn ? "KEYS" : "SIM") \(sizeMode.sign)")
            .font(.system(size: 10, weight: isOn ? .heavy : .regular))
            .foregroundStyle(isOn ? Color.white : Color.secondary.opacity(0.7))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(isOn ? Color.orange : Color.primary.opacity(0.08)))
            .contentShape(Capsule())
            .onTapGesture {
                sizeMode = sizeMode == .dollars ? .percent : .dollars
                let badge = isOn ? "KEYS" : "SIM"
                broker.say(sizeMode == .dollars ? "\(badge) $: the numbers are dollars, 1 is $1,000, 9 is $9,000"
                                                : "\(badge) %: the numbers are a share of the buying power, 1 is 20%, 4 is 80% (5–9 none)")
            }
            .help((isOn ? "KEYS ON: order shortcuts (order keys, hotkeys' own keys, ⌘⇧↩, ⌘⌫) go to IB, for real."
                        : "SIM: order shortcuts (order keys, hotkeys' own keys, ⌘⇧↩, ⌘⌫) trade what-if positions, never sent to IB.")
                  + " ⌘ and the Globe (fn) key switch; SIM at launch, KEYS ON with a live position open. Positions and the charts show real and what-if trades together either way."
                  + (sizeMode == .dollars ? " Numbers in dollars: 1 is $1,000, 9 is $9,000." : " Numbers in % of the buying power: 1 is 20%, 4 is 80%, 5–9 none.")
                  + " A click or ⌘⇧M switches $ and %. Cancelling (⌘A, ⌘Z, ⌥Z, ⌥<) works on real orders either way.")
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
struct WindowControlsProbe: NSViewRepresentable {
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
