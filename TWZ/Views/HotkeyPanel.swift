//
//  HotkeyPanel.swift
//  TWZ
//
//  The order pad on the left (see `OrderPad`): $ or %, the price or order type, and 1–9, each a
//  button that picks that setting, lit while picked. Its order is the one ⌘⇧↩ sends while no
//  hotkey button is selected.
//  On the right, a two-row grid of configurable hotkey buttons (closing, cancelling, or orders of
//  their own) acting on the selected chart's symbol. Clicking one selects it (never sends it):
//  ⌘⇧↩ sends it, and its own shortcut (a ⌘ number too, with KEYS ON, where no order key is) sends it any time. New buttons go in on the left. Click the "Hotkeys" title to customize them
//  all, or right-click a button to edit just that one.
//

import SwiftUI
import UniformTypeIdentifiers

struct HotkeyPanel: View {
    @Environment(Broker.self) private var broker
    @Environment(Workspace.self) private var workspace
    @State private var editing: Int?
    @State private var showingCustomizer = false

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
            // The order pad, nine columns, on the left; the hotkey buttons on the right in two rows, every
            // column the same width. Buttons are full height when there's room, any extra becoming space
            // above and below them; a shorter panel shrinks them down to minButtonHeight.
            GeometryReader { geo in
                let hotkeyColumns = workspace.hotkeys.isEmpty ? 0 : Hotkey.columns(for: workspace.hotkeys.count)
                let columns = CGFloat(OrderPad.numbers.count + hotkeyColumns)
                let gap = Self.spacing * 3
                let column = (geo.size.width - gap - Self.spacing * (columns - 2)) / columns
                let padWidth = column * CGFloat(OrderPad.numbers.count) + Self.spacing * CGFloat(OrderPad.numbers.count - 1)
                let height = min(Self.buttonHeight, max(Self.minButtonHeight, (geo.size.height - Self.spacing) / 2))
                HStack(spacing: gap) {
                    OrderPadView(height: height, spacing: Self.spacing)
                        .frame(width: max(0, padWidth))
                    LazyVGrid(columns: Self.gridColumns(workspace.hotkeys.count), spacing: Self.spacing) {
                        ForEach(Array(workspace.hotkeys.enumerated()), id: \.element.id) { index, hotkey in
                            HotkeyButton(hotkey: hotkey, height: height,
                                         selected: hotkey.id == workspace.selectedHotkeyID, firesOnPress: true) {
                                // A click selects it: ⌘⇧↩ sends it.
                                workspace.selectedHotkeyID = hotkey.id
                            }
                            .help("Click to select: ⌘⇧↩ then sends it"
                                  + (hotkey.shortcut.map { " · \($0.display) sends it any time" } ?? ""))
                            .contextMenu {
                                Button("Edit…") { editing = index }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
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

extension Hotkey {
    var tint: Color { (color ?? action.defaultColor).color }

    /// A Mode hotkey as the trade mode makes it: "Long …", green, while LONG; "Short …", red, while SHORT.
    func shown(in mode: TradeMode) -> Hotkey {
        guard action == .mode else { return self }
        var hotkey = self
        if hotkey.label.hasPrefix(Action.mode.rawValue) {
            hotkey.label = (mode == .long ? "Long" : "Short") + hotkey.label.dropFirst(Action.mode.rawValue.count)
        }
        if hotkey.color == nil { hotkey.color = mode == .long ? .green : .red }
        return hotkey
    }

    /// One-line label for buttons too short for a subtitle: the price it sends at and the size,
    /// e.g. "Mid 1000$", "Ask 100", "MKT 500" or "Ask 80% BP"; other actions keep their label.
    var compactLabel: String {
        guard action.needsSize else { return label }
        let price = switch orderType {
        case .market: "MKT"
        case .midprice: "MidPx"
        case .limit: priceReference.label(isBuy: action == .buy)
        }
        let size = amount.formatted(.number.grouping(.never).precision(.fractionLength(0...2)))
        return "\(price) \(size)\(sizing.suffix)"
    }

    /// Compact description of what the button sends, e.g. "MKT" or "LMT Mid +0.02 · GTC".
    var subtitle: String {
        guard action.placesOrder else { return action.rawValue }
        let buy = action == .buy
        let sign = buy ? "+" : "−"
        var text = switch orderType {
        case .market: "MKT"
        case .midprice: "MIDPRICE"
        case .limit: "LMT \(priceReference.label(isBuy: buy))"
        }
        if orderType != .market, offset != 0 {
            let signed = offset > 0 ? sign : (buy ? "−" : "+")
            text += " \(signed)\(abs(offset).formatted(.number.precision(.fractionLength(2))))"
        }
        if tif != .day { text += " · \(tif.rawValue)" }
        return text
    }
}

private struct HotkeyButton: View {
    let hotkey: Hotkey
    @AppStorage(TradeMode.storageKey) private var mode: TradeMode = .long
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
        let hotkey = hotkey.shown(in: mode)
        return VStack(spacing: 1) {
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

/// The order pad (see `OrderPad`): two rows of nine buttons: $ and % (what the numbers are), the price or
/// order type, and 1–9. Each click picks that button's setting, lit in the trade mode's color (green
/// LONG, red SHORT), and makes the pad's order the one ⌘⇧↩ sends (no hotkey button selected);
/// while a hotkey button is selected the lit buttons dim. Fires on mouse-down, like the hotkey buttons.
private struct OrderPadView: View {
    @Environment(Workspace.self) private var workspace
    @AppStorage(TradeMode.storageKey) private var mode: TradeMode = .long
    let height: CGFloat
    let spacing: CGFloat

    var body: some View {
        let pad = workspace.orderPad
        VStack(spacing: spacing) {
            HStack(spacing: spacing) {
                button("$", "Dollars", lit: !pad.buyingPower, help: "The numbers are dollars: 1 is $1,000, 9 is $9,000") {
                    workspace.orderPad.buyingPower = false
                }
                button("%", "Buying power", lit: pad.buyingPower,
                       help: "The numbers are a share of the buying power IB's margin allows in the stock: 1 is 10%, 9 is 90%") {
                    workspace.orderPad.buyingPower = true
                }
                ForEach(OrderPad.Kind.allCases) { kind in
                    button(kind.rawValue, kind.detail, lit: pad.kind == kind, help: kind.detail + ", no offset") {
                        workspace.orderPad.kind = kind
                    }
                }
            }
            HStack(spacing: spacing) {
                ForEach(OrderPad.numbers, id: \.self) { number in
                    button("\(number)", pad.amountText(number), lit: pad.number == number,
                           help: "\(pad.amountText(number))\(pad.buyingPower ? " of the buying power" : "")") {
                        workspace.orderPad.number = number
                    }
                }
            }
        }
    }

    private func button(_ title: String, _ subtitle: String, lit: Bool, help: String,
                        pick: @escaping () -> Void) -> some View {
        PadButton(title: title, subtitle: height >= 30 ? subtitle : nil, height: height,
                  fill: lit ? (mode == .long ? Color.green : Color.red).opacity(workspace.selectedHotkeyID == nil ? 0.75 : 0.3)
                            : Color.primary.opacity(0.12)) {
            pick()
            // Picking on the pad makes its order the one ⌘⇧↩ sends.
            workspace.selectedHotkeyID = nil
        }
        .help(help + " · ⌘⇧↩ sends the pad's order")
    }
}

/// One order pad button: picks on mouse-down.
private struct PadButton: View {
    let title: String
    let subtitle: String?
    let height: CGFloat
    let fill: Color
    let pick: () -> Void
    @State private var pressed = false

    var body: some View {
        VStack(spacing: 1) {
            Text(title).font(.system(size: 12, weight: .bold))
            if let subtitle { Text(subtitle).font(.system(size: 9)).opacity(0.75) }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .padding(.horizontal, 2)
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .foregroundStyle(.white)
        .background(RoundedRectangle(cornerRadius: 5).fill(fill))
        .brightness(pressed ? -0.12 : 0)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !pressed else { return }
                    pressed = true
                    pick()
                }
                .onEnded { _ in pressed = false }
        )
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { pick() }
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
    /// Adds a "Mode 100" button on the left: at the start of the top row, or when the top row is already
    /// the longer one, at the start of the bottom row, so the rows line up again. Returns its id.
    @discardableResult
    func addHotkey() -> UUID? {
        guard hotkeys.count < Hotkey.maxCount else { return nil }
        let hotkey = Hotkey(label: Hotkey.autoLabel(action: .mode, sizing: .shares, amount: 100), action: .mode)
        hotkeys.insert(hotkey, at: hotkeys.count.isMultiple(of: 2) ? 0 : Hotkey.columns(for: hotkeys.count))
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

/// Editing form for a single hotkey, shared by the customizer popover and the right-click editor; for an
/// order key (Settings › Order Keys, see `OrderKeys`) without the label and color, which it has no button for.
private struct HotkeyFields: View {
    @Binding var hotkey: Hotkey
    var isOrderKey = false

    var body: some View {
        Form {
            if !isOrderKey {
                TextField("Label", text: $hotkey.label, prompt: Text("Automatic"))
            }
            Picker("Action", selection: $hotkey.action) {
                ForEach(Hotkey.Action.allCases) { Text($0.rawValue).tag($0) }
            }
            if !isOrderKey {
                LabeledContent("Color") { colorSwatches }
            }
            ShortcutRecorder(shortcut: $hotkey.shortcut, owner: isOrderKey ? .orderKey(hotkey.id) : .hotkey(hotkey.id))
            if hotkey.action.needsSize {
                Picker("Size in", selection: $hotkey.sizing) {
                    ForEach(Hotkey.Sizing.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                TextField(amountTitle, value: $hotkey.amount, format: .number)
                if hotkey.sizing == .buyingPower {
                    Text("Asks IB, before sending, for the most shares its margin allows in the stock at the order's price (a new long for buys, a new short for sells) and sends this percent of it, 1–100. IB answers in a second or two. Refused while holding a position on the other side.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if hotkey.action.placesOrder {
                orderSection
            }
        }
        .formStyle(.grouped)
        // A share or dollar amount isn't a percent: switching to % of buying power starts at 80%.
        .onChange(of: hotkey.sizing) { _, sizing in
            if sizing == .buyingPower, hotkey.amount > 100 { hotkey.amount = 80 }
        }
        .onChange(of: labelInputs) { old, new in
            // Keep an automatic label in sync ("Buy 100" → "Buy 1000$"); leave custom labels alone.
            if Hotkey.isAutoLabel(hotkey.label, action: old.action, sizing: old.sizing, amount: old.amount) {
                hotkey.label = Hotkey.autoLabel(action: new.action, sizing: new.sizing, amount: new.amount)
            }
        }
    }

    private var amountTitle: String {
        switch hotkey.sizing {
        case .shares: "Shares"
        case .dollars: "Dollar amount"
        case .buyingPower: "Percent of buying power"
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

    /// What the chosen order type sends, under the order fields.
    private var orderNote: String {
        switch hotkey.orderType {
        case .market:
            "Regular hours: market order. Pre-market / after hours: limit 0.5% through the ask (buys) or bid (sells). Overnight / closed: limit at the bid (buys) or ask (sells)."
        case .midprice:
            "Regular hours: IBKR's MIDPRICE order (DAY), which follows the midpoint as the quote moves and never pays more than the ask + offset (buys) or sells below the bid − offset. Pre-market, after hours and overnight: a limit at the mid + offset (buys) or − offset (sells)."
        case .limit:
            "Buys: price + offset · Sells: price − offset. A positive offset fills more easily; a negative one waits for a better price."
        }
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
            }
            if hotkey.orderType != .market {
                TextField("Offset ($)", value: $hotkey.offset, format: .number.precision(.fractionLength(2...4)))
            }
            Picker("Time in force", selection: $hotkey.tif) {
                ForEach(TimeInForce.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            if hotkey.orderType == .limit {
                Toggle("Allow outside regular hours", isOn: $hotkey.outsideRth)
            }
            Text(orderNote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct HotkeyEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var hotkey: Hotkey
    /// An order key's (see `HotkeyFields`): it needs a shortcut to save.
    var isOrderKey = false
    let onSave: (Hotkey) -> Void

    var body: some View {
        HotkeyFields(hotkey: $hotkey, isOrderKey: isOrderKey)
            .frame(width: 420)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(hotkey); dismiss() }
                        .disabled(isOrderKey && hotkey.shortcut == nil)
                        .help(isOrderKey && hotkey.shortcut == nil ? "Record its keyboard shortcut first" : "")
                }
            }
    }
}
