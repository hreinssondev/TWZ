//
//  HotkeyPanel.swift
//  TWZ
//
//  Two-row grid (6 × 2 by default) of configurable order buttons acting on the selected chart's symbol.
//  Clicking a button selects it, and ⌘↩ sends the selected one (see TradingShortcuts); or, set in
//  Settings ▸ Trading, clicking sends the order on mouse-down (and selects it too).
//  Click the "Hotkeys" title to customize them all, or right-click a button to edit just that one.
//  Beside them, the NOK amount that ⌥-clicking a chart buys.
//

import SwiftUI
import UniformTypeIdentifiers

struct HotkeyPanel: View {
    @Environment(Broker.self) private var broker
    @Environment(Workspace.self) private var workspace
    @State private var editing: Int?
    @State private var showingCustomizer = false
    @AppStorage(HotkeyClickMode.storageKey) private var clickMode: HotkeyClickMode = .select

    static let buttonHeight: CGFloat = 44
    /// Buttons shrink down to this when the panel is dragged shorter than they need at full height.
    static let minButtonHeight: CGFloat = 20
    private static let spacing: CGFloat = 6
    private static let headerHeight: CGFloat = 14
    private static let padding: CGFloat = 8
    /// Height at which the shrunk buttons fit with no free space around them.
    static let minHeight = padding * 2 + headerHeight + spacing + minButtonHeight * 2 + spacing

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
                Text("→ \(!workspace.isChartSelected ? "no chart selected" : workspace.targetSymbol.isEmpty ? "no symbol" : workspace.targetSymbol)")
                    .font(.system(size: 11, weight: .bold))
                Spacer()
                if let msg = broker.lastMessage {
                    MessageLabel(text: msg, color: .orange)
                }
            }
            .frame(height: Self.headerHeight)
            // The order amount box, two buttons tall, keeps a seventh of the width; the hotkeys share
            // the rest in two rows, narrowing as buttons are added beyond 6 × 2.
            // Buttons are full height when there's room, any extra becoming space above and below
            // them; a shorter panel shrinks them (and the amount box) down to minButtonHeight.
            GeometryReader { geo in
                let column = (geo.size.width - Self.spacing * 6) / 7
                let height = min(Self.buttonHeight, max(Self.minButtonHeight, (geo.size.height - Self.spacing) / 2))
                HStack(spacing: Self.spacing) {
                    LazyVGrid(columns: Self.gridColumns(workspace.hotkeys.count), spacing: Self.spacing) {
                        ForEach(Array(workspace.hotkeys.enumerated()), id: \.element.id) { index, hotkey in
                            HotkeyButton(hotkey: hotkey, height: height,
                                         selected: hotkey.id == workspace.selectedHotkeyID, firesOnPress: true) {
                                workspace.selectedHotkeyID = hotkey.id
                                if clickMode == .send { broker.run(hotkey, symbol: workspace.targetSymbol) }
                            }
                            .help((clickMode == .send ? "Click sends · ⌘↩ sends it again" : "Click to select · ⌘↩ sends it")
                                  + (hotkey.shortcut.map { " · \($0.display) sends it any time" } ?? "")
                                  + " · ⌘S closes 100% at market")
                            .contextMenu {
                                Button("Edit…") { editing = index }
                            }
                        }
                    }
                    .frame(width: max(0, geo.size.width - column - Self.spacing))
                    OrderAmountBox(height: height * 2 + Self.spacing)
                        .frame(width: max(0, column))
                }
                .frame(height: height * 2 + Self.spacing)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
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

    static func gridColumns(_ count: Int) -> [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: spacing), count: Hotkey.columns(for: count))
    }

    private struct EditTarget: Identifiable {
        let index: Int
        var id: Int { index }
    }
}

private extension Hotkey {
    var tint: Color { (color ?? action.defaultColor).color }

    /// One-line label for buttons too short for a subtitle: the price it sends at and the size,
    /// e.g. "Mid 1000$", "Ask 100" or "MKT 500"; other actions keep their label.
    var compactLabel: String {
        guard action.needsSize else { return label }
        let price = orderType == .market ? "MKT" : priceReference.label(isBuy: action == .buy)
        let size = amount.formatted(.number.grouping(.never).precision(.fractionLength(0...2)))
        return "\(price) \(size)\(sizing == .dollars ? "$" : "")"
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
    /// Fire as the mouse goes down instead of on release (the panel's buttons; the customizer keeps
    /// a normal click so its slots can be dragged).
    var firesOnPress = false
    let action: () -> Void

    @State private var pressed = false

    /// Below this the button shows only its label.
    private static let subtitleMinHeight: CGFloat = 30

    var body: some View {
        if firesOnPress {
            face
                .brightness(pressed ? -0.12 : 0)
                // A zero-distance drag reports the mouse-down itself; one press fires once.
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            guard !pressed else { return }
                            pressed = true
                            action()
                        }
                        .onEnded { _ in pressed = false }
                )
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { action() }
        } else {
            Button(action: action) { face }
                .buttonStyle(.plain)
        }
    }

    private var face: some View {
        VStack(spacing: 1) {
            if height >= Self.subtitleMinHeight {
                Text(hotkey.label).font(.system(size: 12, weight: .bold))
                Text(hotkey.subtitle).font(.system(size: 9)).opacity(0.75)
            } else {
                Text(hotkey.compactLabel).font(.system(size: 12, weight: .bold))
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .padding(.horizontal, 3)
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .foregroundStyle(.white)
        .background(RoundedRectangle(cornerRadius: 5).fill(hotkey.tint.opacity(0.75)))
        .overlay(alignment: .topTrailing) {
            if let shortcut = hotkey.shortcut, height >= Self.subtitleMinHeight {
                Text(shortcut.display)
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.top, 2).padding(.trailing, 4)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(Color.accentColor, lineWidth: selected ? 2.5 : 0)
        )
        .contentShape(Rectangle())
    }
}

/// The NOK amount ⌥-clicking a chart buys (a DAY limit at the clicked price), converted to shares
/// at the live USD.NOK rate. Type it, or step it in 5 000 NOK steps with ↑/↓ or the arrows.
/// When the panel is short it drops the title, then the size line, keeping just the field.
private struct OrderAmountBox: View {
    let height: CGFloat
    @Environment(Broker.self) private var broker
    @Environment(Workspace.self) private var workspace
    @AppStorage(OrderAmount.storageKey) private var amount = OrderAmount.initial
    @State private var text = ""
    @FocusState private var focused: Bool
    /// The field editor whose caret is hidden, and its original color.
    @State private var caretEditor: (NSTextView, NSColor)?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if height >= 64 {
                Text("⌥-click buy")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
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
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.15)))
            Spacer(minLength: 0)
            if height >= 44 {
                Text(sizeText)
                    .font(.system(size: 10).monospacedDigit())
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .padding(height >= 64 ? 5 : 3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.12)))
        .help("⌥-click a chart to place a limit buy for this many NOK at the clicked price. ↑/↓ step 5 000 NOK (500–300 000).")
        .onAppear { text = OrderAmount.format(amount) }
        .onChange(of: text) { _, new in
            if let typed = OrderAmount.parse(new) { amount = OrderAmount.clamp(typed) }
        }
        .onChange(of: focused) { _, isFocused in
            if isFocused {
                hideCaret()
            } else {
                restoreCaret()
                commit()
            }
        }
    }

    /// The window's field editor is shared by every text field, so the caret is hidden only while
    /// this one is being edited. Deferred a tick: focus flips before the editor becomes first responder.
    private func hideCaret() {
        DispatchQueue.main.async {
            guard focused, let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return }
            if caretEditor == nil { caretEditor = (editor, editor.insertionPointColor) }
            editor.insertionPointColor = .clear
        }
    }

    private func restoreCaret() {
        guard let (editor, color) = caretEditor else { return }
        editor.insertionPointColor = color
        caretEditor = nil
    }

    /// "≈ $4,566 · 45 AAPL": the USD value, and what it buys of the selected symbol at its last price.
    private var sizeText: String {
        guard let rate = broker.usdNok, rate > 0 else { return "No USD.NOK rate" }
        var text = "≈ $" + Int(amount / rate).formatted()
        let symbol = workspace.targetSymbol
        if let last = broker.quote(symbol)?.last, let shares = broker.shares(forNOK: amount, at: last) {
            text += " · \(Fmt.shares(shares)) \(symbol)"
        }
        return text
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

/// Popover for editing every hotkey: pick a slot in the two-row preview, edit it below; drag a slot
/// onto another to reorder them, + adds a button and − removes the selected one.
/// Changes apply (and are saved) immediately.
private struct HotkeyCustomizer: View {
    @Environment(Workspace.self) private var workspace
    @State private var selectedID: UUID?
    @State private var draggingID: UUID?

    var body: some View {
        @Bindable var workspace = workspace
        let slots = workspace.hotkeys
        let selected = slots.firstIndex { $0.id == selectedID } ?? 0
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Customize Hotkeys").font(.headline)
                Text("Drag to reorder").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    if selected < slots.count { workspace.removeHotkey(slots[selected].id) }
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(slots.count <= 1)
                .help("Remove the selected hotkey")
                Button {
                    if let id = workspace.addHotkey() { selectedID = id }
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(slots.count >= Hotkey.maxCount)
                .help("Add a hotkey")
                Button("Reset to Defaults") {
                    workspace.hotkeys = Hotkey.defaults
                }
                .controlSize(.small)
            }
            LazyVGrid(columns: HotkeyPanel.gridColumns(slots.count), spacing: 6) {
                ForEach(Array(slots.enumerated()), id: \.element.id) { index, hotkey in
                    HotkeyButton(hotkey: hotkey, height: 36, selected: index == selected) {
                        selectedID = hotkey.id
                    }
                    .onDrag {
                        draggingID = hotkey.id
                        return NSItemProvider(object: hotkey.id.uuidString as NSString)
                    }
                    .onDrop(of: [.text], delegate: HotkeyReorder(target: hotkey.id, hotkeys: $workspace.hotkeys,
                                                                  draggingID: $draggingID))
                }
            }
            if selected < slots.count {
                HotkeyFields(hotkey: $workspace.hotkeys[selected])
                    .id(workspace.hotkeys[selected].id)
            }
        }
        .padding(14)
        .frame(width: 560)
    }
}

extension Workspace {
    /// Adds a "Buy 100" button as a new column (end of the top row) or, when the top row is already
    /// the longer one, at the end of the bottom row, so neither row's buttons shift. Returns its id.
    @discardableResult
    func addHotkey() -> UUID? {
        guard hotkeys.count < Hotkey.maxCount else { return nil }
        let hotkey = Hotkey(label: Hotkey.autoLabel(action: .buy, sizing: .shares, amount: 100), action: .buy)
        hotkeys.insert(hotkey, at: hotkeys.count.isMultiple(of: 2) ? hotkeys.count / 2 : hotkeys.count)
        return hotkey.id
    }

    func removeHotkey(_ id: UUID) {
        guard hotkeys.count > 1 else { return }
        hotkeys.removeAll { $0.id == id }
    }
}

/// Moves the dragged hotkey into a slot as soon as it's dragged over it, so the grid shows the
/// new order while dragging.
private struct HotkeyReorder: DropDelegate {
    let target: UUID
    @Binding var hotkeys: [Hotkey]
    @Binding var draggingID: UUID?

    func dropEntered(info: DropInfo) {
        guard let draggingID, draggingID != target,
              let from = hotkeys.firstIndex(where: { $0.id == draggingID }),
              let to = hotkeys.firstIndex(where: { $0.id == target }) else { return }
        withAnimation(.snappy(duration: 0.2)) {
            hotkeys.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        draggingID = nil
        return true
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
            LabeledContent("Color") { colorSwatches }
            ShortcutRecorder(shortcut: $hotkey.shortcut, owner: .hotkey(hotkey.id))
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

    /// Preset colors; picking the action's default stores none, so it keeps following the action.
    private var colorSwatches: some View {
        let current = hotkey.color ?? hotkey.action.defaultColor
        return HStack(spacing: 5) {
            ForEach(HotkeyColor.allCases) { option in
                Button {
                    hotkey.color = option == hotkey.action.defaultColor ? nil : option
                } label: {
                    Circle()
                        .fill(option.color.opacity(0.75))
                        .frame(width: 16, height: 16)
                        .padding(2)
                        .overlay(Circle().strokeBorder(Color.primary.opacity(option == current ? 0.8 : 0), lineWidth: 1.5))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(option.rawValue.capitalized + (option == hotkey.action.defaultColor ? " (default)" : ""))
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
