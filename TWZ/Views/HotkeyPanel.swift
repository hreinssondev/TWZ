//
//  HotkeyPanel.swift
//  TWZ
//
//  6 × 2 grid of configurable order buttons acting on the selected chart's symbol.
//  Click the "Hotkeys" title to customize them all, or right-click a button to edit just that one.
//  Beside them, the NOK amount that ⌥-clicking a chart buys.
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
                    MessageLabel(text: msg, color: .orange)
                }
            }
            .frame(height: Self.headerHeight)
            // Seven equal columns: the 6 × 2 hotkeys, then the order amount box two buttons tall.
            // Buttons keep a fixed height; any extra height becomes space above and below them.
            GeometryReader { geo in
                let column = (geo.size.width - Self.spacing * 6) / 7
                HStack(spacing: Self.spacing) {
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
                    .frame(width: max(0, geo.size.width - column - Self.spacing))
                    OrderAmountBox()
                        .frame(width: max(0, column))
                }
            }
            .frame(height: Self.buttonHeight * 2 + Self.spacing)
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

    /// Compact description of what the button sends, e.g. "MKT" or "LMT Mid +0.02 · GTC".
    var subtitle: String {
        guard action.placesOrder else { return action.rawValue }
        let buy = action == .buy
        let sign = buy ? "+" : "−"
        var text = orderType == .market ? "MKT" : "LMT \(priceReference.label(isBuy: buy))"
        if orderType == .limit, offset != 0 {
            let signed = offset > 0 ? sign : (buy ? "−" : "+")
            text += " \(signed)\(abs(offset).formatted(.number.precision(.fractionLength(2))))"
        }
        if tif != .day { text += " · \(tif.rawValue)" }
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
            .minimumScaleFactor(0.75)
            .padding(.horizontal, 3)
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

/// The NOK amount ⌥-clicking a chart buys (a DAY limit at the clicked price), converted to shares
/// at the live USD.NOK rate. Type it, or step it in 5 000 NOK steps with ↑/↓ or the arrows.
private struct OrderAmountBox: View {
    @Environment(Broker.self) private var broker
    @Environment(Workspace.self) private var workspace
    @AppStorage(OrderAmount.storageKey) private var amount = OrderAmount.initial
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("⌥-click buy · NOK")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 2) {
                TextField("", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .bold).monospacedDigit())
                    .focused($focused)
                    .onSubmit(commit)
                    .onExitCommand { focused = false }
                    .onKeyPress(.upArrow) { step(up: true); return .handled }
                    .onKeyPress(.downArrow) { step(up: false); return .handled }
                VStack(spacing: 0) {
                    stepButton(up: true)
                    stepButton(up: false)
                }
            }
            .padding(.leading, 5)
            .padding(.trailing, 2)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 4)
                .strokeBorder(focused ? Color.purple : Color.primary.opacity(0.15)))
            Spacer(minLength: 0)
            Text(sizeText)
                .font(.system(size: 10).monospacedDigit())
            Text(rateText)
                .font(.system(size: 9).monospacedDigit())
                .foregroundStyle(broker.usdNokIsLive ? Color.secondary : Color.orange)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .padding(5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.purple.opacity(0.15)))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.purple.opacity(0.5)))
        .help("⌥-click a chart to place a limit buy for this many NOK at the clicked price. ↑/↓ step 5 000 NOK (500–300 000).")
        .onAppear { text = OrderAmount.format(amount) }
        .onChange(of: text) { _, new in
            if let typed = OrderAmount.parse(new) { amount = OrderAmount.clamp(typed) }
        }
        .onChange(of: focused) { _, isFocused in
            if !isFocused { commit() }
        }
    }

    /// "≈ $4,566 · 45 AAPL": the USD value, and what it buys of the selected symbol at its last price.
    private var sizeText: String {
        guard let rate = broker.usdNok, rate > 0 else { return "No USD.NOK rate" }
        var text = "≈ $" + Int(amount / rate).formatted()
        let symbol = workspace.selectedChart.symbol
        if let last = broker.quotes[symbol]?.last, let shares = broker.shares(forNOK: amount, at: last) {
            text += " · \(Fmt.shares(shares)) \(symbol)"
        }
        return text
    }

    private var rateText: String {
        guard let rate = broker.usdNok else { return "Connect for USD.NOK" }
        let value = rate.formatted(.number.precision(.fractionLength(4)))
        return "USD/NOK \(value)" + (broker.usdNokIsLive ? "" : " (saved)")
    }

    private func stepButton(up: Bool) -> some View {
        Button { step(up: up) } label: {
            Image(systemName: up ? "chevron.up" : "chevron.down")
                .font(.system(size: 7, weight: .bold))
                .frame(width: 12, height: 9)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }

    private func step(up: Bool) {
        amount = OrderAmount.stepped(OrderAmount.parse(text) ?? amount, up: up)
        text = OrderAmount.format(amount)
    }

    private func commit() {
        amount = OrderAmount.clamp(OrderAmount.parse(text) ?? amount)
        text = OrderAmount.format(amount)
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
            TextField("Label", text: $hotkey.label, prompt: Text("Automatic"))
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
        .onChange(of: labelInputs) { old, new in
            // Keep an automatic label in sync ("Buy 100" → "Buy 1000$"); leave custom labels alone.
            if Hotkey.isAutoLabel(hotkey.label, action: old.action, sizing: old.sizing, amount: old.amount) {
                hotkey.label = Hotkey.autoLabel(action: new.action, sizing: new.sizing, amount: new.amount)
            }
        }
    }

    private struct LabelInputs: Equatable {
        var action: Hotkey.Action
        var sizing: Hotkey.Sizing
        var amount: Double
    }

    private var labelInputs: LabelInputs {
        LabelInputs(action: hotkey.action, sizing: hotkey.sizing, amount: hotkey.amount)
    }

    @ViewBuilder private var orderSection: some View {
        Section("Order") {
            Picker("Order type", selection: $hotkey.orderType) {
                ForEach(OrderType.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            if hotkey.orderType == .limit {
                Picker("Limit price based on", selection: $hotkey.priceReference) {
                    ForEach(PriceReference.allCases) { ref in
                        Text(ref == .cross ? "Bid/Ask (ask for buys, bid for sells)" : ref.rawValue).tag(ref)
                    }
                }
                TextField("Offset ($)", value: $hotkey.offset, format: .number.precision(.fractionLength(2...4)))
            }
            Picker("Time in force", selection: $hotkey.tif) {
                ForEach(TimeInForce.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            if hotkey.orderType == .limit {
                Toggle("Allow outside regular hours", isOn: $hotkey.outsideRth)
            }
            Text(hotkey.orderType == .market
                 ? "Regular hours: market order. Pre-market / after hours: limit 0.5% through the ask (buys) or bid (sells). Overnight / closed: limit at the bid (buys) or ask (sells)."
                 : "Buys: price + offset · Sells: price − offset. A positive offset fills more easily; a negative one waits for a better price.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
