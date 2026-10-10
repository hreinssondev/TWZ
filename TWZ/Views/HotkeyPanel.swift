//
//  HotkeyPanel.swift
//  TWZ
//
//  6 × 2 grid of configurable order buttons acting on the selected chart's symbol.
//  Right-click a button to edit it.
//

import SwiftUI

struct HotkeyPanel: View {
    @Environment(Broker.self) private var broker
    @Environment(Workspace.self) private var workspace
    @State private var editing: Int?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 6)

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Hotkeys").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Text("→ \(workspace.selectedChart.symbol.isEmpty ? "no symbol" : workspace.selectedChart.symbol)")
                    .font(.system(size: 11, weight: .bold))
                Spacer()
                if let msg = broker.lastMessage {
                    Text(msg).font(.system(size: 10)).foregroundStyle(.orange).lineLimit(1)
                }
            }
            LazyVGrid(columns: columns, spacing: 6) {
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
        .padding(8)
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

private struct HotkeyButton: View {
    let hotkey: Hotkey
    let action: () -> Void

    private var tint: Color {
        switch hotkey.action {
        case .buy: .green
        case .sell: .red
        case .closeHalf, .closeAll: .orange
        case .cancelSymbol, .cancelAll: .gray
        case .flattenAll: .purple
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Text(hotkey.label).font(.system(size: 12, weight: .bold))
                Text(subtitle).font(.system(size: 9)).opacity(0.75)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(.white)
            .background(RoundedRectangle(cornerRadius: 5).fill(tint.opacity(0.75)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var subtitle: String {
        guard hotkey.action.needsPrice else { return hotkey.action.rawValue }
        if hotkey.priceType == .market { return "MKT" }
        let side = (hotkey.action == .buy) ? "Ask" : "Bid"
        let sign = (hotkey.action == .buy) ? "+" : "−"
        return "LMT \(side) \(sign)\(hotkey.offset.formatted(.number.precision(.fractionLength(2))))"
    }
}

struct HotkeyEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var hotkey: Hotkey
    let onSave: (Hotkey) -> Void

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
            if hotkey.action.needsPrice || hotkey.action == .flattenAll {
                Picker("Order type", selection: $hotkey.priceType) {
                    ForEach(Hotkey.PriceType.allCases) { Text($0.rawValue).tag($0) }
                }
                TextField("Limit offset ($)", value: $hotkey.offset, format: .number.precision(.fractionLength(2...4)))
                Text("Buys: ask + offset · Sells: bid − offset. Outside regular hours, market orders are sent as marketable limits.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { onSave(hotkey); dismiss() }
            }
        }
    }
}
