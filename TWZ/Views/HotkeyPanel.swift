//
//  HotkeyPanel.swift
//  TWZ
//
//  6 × 2 grid of configurable order buttons acting on the selected chart's symbol.
//  Click the "Hotkeys" title to customize them all, or right-click a button to edit just that one.
//

import SwiftUI

struct HotkeyPanel: View {
    @Environment(Broker.self) private var broker
    @Environment(Workspace.self) private var workspace
    @State private var editing: Int?
    @State private var showingCustomizer = false

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 6)

    static let buttonHeight: CGFloat = 44
    private static let spacing: CGFloat = 6
    private static let headerHeight: CGFloat = 14
    private static let padding: CGFloat = 8
    /// Height at which the buttons fit with no free space around them.
    static let minHeight = padding * 2 + headerHeight + spacing + buttonHeight * 2 + spacing

    var body: some View {
        VStack(alignment: .leading, spacing: Self.spacing) {
            HStack {
                Button {
                    showingCustomizer = true
                } label: {
                    HStack(spacing: 3) {
                        Text("Hotkeys")
                        Image(systemName: "slider.horizontal.3").font(.system(size: 9))
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointerStyle(.link)
                .help("Customize hotkeys")
                .popover(isPresented: $showingCustomizer, arrowEdge: .bottom) {
                    HotkeyCustomizer()
                }
                Text("→ \(workspace.selectedChart.symbol.isEmpty ? "no symbol" : workspace.selectedChart.symbol)")
                    .font(.system(size: 11, weight: .bold))
                Spacer()
                if let msg = broker.lastMessage {
                    Text(msg).font(.system(size: 10)).foregroundStyle(.orange).lineLimit(1)
                }
            }
            .frame(height: Self.headerHeight)
            // Buttons keep a fixed size; any extra height becomes space above and below them.
            LazyVGrid(columns: columns, spacing: Self.spacing) {
                ForEach(Array(workspace.hotkeys.prefix(12).enumerated()), id: \.element.id) { index, hotkey in
                    HotkeyButton(hotkey: hotkey) {
                        broker.run(hotkey, symbol: workspace.selectedChart.symbol)
                    }
                    .contextMenu {
                        Button("Edit…") { editing = index }
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
        .padding(Self.padding)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.12)))
        .sheet(item: Binding(
            get: { editing.map { EditTarget(index: $0) } },
            set: { editing = $0?.index }
        )) { target in
            HotkeyEditor(hotkey: workspace.hotkeys[target.index]) { updated in
                workspace.hotkeys[target.index] = updated
            }
        }
    }

    private struct EditTarget: Identifiable {
        let index: Int
        var id: Int { index }
    }
}

private extension Hotkey {
    var tint: Color {
        switch action {
        case .buy: .green
        case .sell: .red
        case .closeHalf, .closeAll: .orange
        case .cancelSymbol, .cancelAll: .gray
        case .flattenAll: .purple
        }
    }

    /// Compact description of what the button sends, e.g. "LMT Ask +0.02 · GTC".
    var subtitle: String {
        guard action.placesOrder else { return action.rawValue }
        let buy = action == .buy
        func money(_ v: Double) -> String { v.formatted(.number.precision(.fractionLength(2))) }
        let away = buy ? "Ask +" : "Bid −"      // toward a worse price (limits, stops)
        let toward = buy ? "Bid −" : "Ask +"    // toward a better price (touched orders)
        var text: String
        switch orderType {
        case .limit, .limitOnOpen, .limitOnClose: text = "\(orderType.short) \(away)\(money(offset))"
        case .stop, .stopLimit: text = "\(orderType.short) \(away)\(money(triggerOffset))"
        case .marketIfTouched, .limitIfTouched: text = "\(orderType.short) \(toward)\(money(triggerOffset))"
        case .trailingStop, .trailingStopLimit:
            text = "\(orderType.short) " + (trailUnit == .percent ? "\(trailAmount.formatted())%" : "$\(money(trailAmount))")
        case .relative: text = "REL \(money(offset))"
        default: text = orderType.short
        }
        if adaptive != .off && orderType.supportsAdaptive { text += " · Adaptive" }
        if orderType.fixedTIF == nil && tif != .day { text += " · \(tif.rawValue)" }
        return text
    }
}

private struct HotkeyButton: View {
    let hotkey: Hotkey
    var height: CGFloat = HotkeyPanel.buttonHeight
    var selected = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Text(hotkey.label).font(.system(size: 12, weight: .bold))
                Text(hotkey.subtitle).font(.system(size: 9)).opacity(0.75)
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .foregroundStyle(.white)
            .background(RoundedRectangle(cornerRadius: 5).fill(hotkey.tint.opacity(0.75)))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Color.accentColor, lineWidth: selected ? 2.5 : 0)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Popover for editing every hotkey: pick a slot in the 6 × 2 preview, edit it below.
/// Changes apply (and are saved) immediately.
private struct HotkeyCustomizer: View {
    @Environment(Workspace.self) private var workspace
    @State private var selected = 0

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 6)

    var body: some View {
        @Bindable var workspace = workspace
        let count = min(12, workspace.hotkeys.count)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Customize Hotkeys").font(.headline)
                Spacer()
                Button("Reset to Defaults") {
                    workspace.hotkeys = Hotkey.defaults
                }
                .controlSize(.small)
            }
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(Array(workspace.hotkeys.prefix(12).enumerated()), id: \.element.id) { index, hotkey in
                    HotkeyButton(hotkey: hotkey, height: 36, selected: index == selected) {
                        selected = index
                    }
                }
            }
            if selected < count {
                HotkeyFields(hotkey: $workspace.hotkeys[selected])
                    .id(workspace.hotkeys[selected].id)
            }
        }
        .padding(14)
        .frame(width: 560)
    }
}

/// Editing form for a single hotkey, shared by the customizer popover and the right-click editor.
private struct HotkeyFields: View {
    @Binding var hotkey: Hotkey

    var body: some View {
        Form {
            TextField("Label", text: $hotkey.label)
            Picker("Action", selection: $hotkey.action) {
                ForEach(Hotkey.Action.allCases) { Text($0.rawValue).tag($0) }
            }
            if hotkey.action.needsSize {
                Picker("Size in", selection: $hotkey.sizing) {
                    ForEach(Hotkey.Sizing.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                TextField(hotkey.sizing == .shares ? "Shares" : "Dollar amount",
                          value: $hotkey.amount, format: .number)
            }
            if hotkey.action.placesOrder {
                orderSection
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private var orderSection: some View {
        let kind = hotkey.orderType
        Section("Order") {
            Picker("Order type", selection: $hotkey.orderType) {
                ForEach(OrderKind.groups, id: \.0) { group in
                    Section(group.0) {
                        ForEach(group.1) { Text($0.rawValue).tag($0) }
                    }
                }
            }
            if kind.usesTrigger {
                money(kind == .stop || kind == .stopLimit ? "Stop offset ($)" : "Trigger offset ($)",
                      $hotkey.triggerOffset)
            }
            if kind.usesLimitOffset {
                money(kind.usesTrigger ? "Limit beyond trigger ($)" : "Limit offset ($)", $hotkey.offset)
            }
            if kind.isTrailing {
                HStack {
                    TextField("Trail by", value: $hotkey.trailAmount, format: .number.precision(.fractionLength(0...4)))
                    Picker("", selection: $hotkey.trailUnit) {
                        ForEach(Hotkey.TrailUnit.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                if kind == .trailingStopLimit {
                    money("Limit offset from stop ($)", $hotkey.offset)
                }
            }
            if kind == .relative {
                money("Peg offset ($)", $hotkey.offset)
            }
            if kind.fixedTIF == nil {
                Picker("Time in force", selection: $hotkey.tif) {
                    ForEach(TimeInForce.selectable) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            if kind.allowsOutsideRth {
                Toggle("Allow outside regular hours", isOn: $hotkey.outsideRth)
            }
            if kind.supportsAdaptive {
                Picker("Adaptive algo", selection: $hotkey.adaptive) {
                    ForEach(AdaptivePriority.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Text(Self.explanation(kind))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func money(_ title: String, _ value: Binding<Double>) -> some View {
        TextField(title, value: value, format: .number.precision(.fractionLength(2...4)))
    }

    private static func explanation(_ kind: OrderKind) -> String {
        switch kind {
        case .market:
            "Fills at the best available price. Outside regular hours it's sent as a marketable limit (bid/ask ± max(offset, 0.5%))."
        case .limit:
            "Buys at ask + offset, sells at bid − offset, or better."
        case .stop:
            "Becomes a market order when price reaches the stop: buys at ask + offset, sells at bid − offset."
        case .stopLimit:
            "When the stop (ask + offset for buys, bid − offset for sells) is hit, a limit order is placed that far beyond it."
        case .trailingStop:
            "Stop follows the price by a fixed amount or percent and becomes a market order when hit."
        case .trailingStopLimit:
            "Trailing stop that places a limit order (stop ± limit offset) when hit."
        case .marketIfTouched:
            "Becomes a market order when price touches the trigger: buys at bid − offset, sells at ask + offset."
        case .limitIfTouched:
            "Places a limit order when price touches the trigger: buys at bid − offset, sells at ask + offset."
        case .marketToLimit:
            "Executes at market; any unfilled part rests as a limit at the first fill price."
        case .midprice:
            "IBKR prices it at or better than the NBBO midpoint."
        case .relative:
            "Pegged to the NBBO: buys at bid + offset, sells at ask − offset, and follows the quote."
        case .marketOnOpen:
            "Executes at market in the opening auction (TIF OPG)."
        case .limitOnOpen:
            "Limit order for the opening auction (TIF OPG): ask + offset for buys, bid − offset for sells."
        case .marketOnClose:
            "Executes at market in the closing auction."
        case .limitOnClose:
            "Limit order for the closing auction: ask + offset for buys, bid − offset for sells."
        }
    }
}

struct HotkeyEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var hotkey: Hotkey
    let onSave: (Hotkey) -> Void

    var body: some View {
        HotkeyFields(hotkey: $hotkey)
            .frame(width: 420)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(hotkey); dismiss() }
                }
            }
    }
}
