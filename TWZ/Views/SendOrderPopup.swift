//
//  SendOrderPopup.swift
//  TWZ
//
//  Over the main window's top while an order is held with ⇧ (see `HeldOrder`): what it is, Send (↩) and
//  Cancel (Esc). The keys are taken in `TradingShortcuts`, so they work wherever the focus is.
//

import SwiftUI

struct SendOrderPopup: View {
    @Environment(Broker.self) private var broker
    @Environment(\.sideColors) private var sideColors

    var body: some View {
        if let held = broker.heldOrder {
            let symbol = held.symbol
            let valueNOK = broker.usdPerPriceUnit(symbol).flatMap { usd in broker.usdNok.map { held.quantity * held.price * usd * $0 } }
            let short = !held.isBuy && held.quantity > max(0, broker.positions[symbol]?.quantity ?? 0)
            let notes = [
                held.summary,
                held.fallback.map { "no live quote, priced off \($0)" },
                short && !held.sim && held.stop == nil && broker.ssrReason(symbol) != nil
                    ? "SSR: goes in a tick above the bid if that's higher" : nil,
                held.exchange == "OVERNIGHT" ? "IBKR overnight" : nil,
            ].compactMap { $0 }
            VStack(alignment: .leading, spacing: 6) {
                Text(held.sim ? "Make what-if trade? (SIM)" : "Send order?")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Text("\(held.action) \(Fmt.shares(held.quantity)) \(symbol)")
                        .foregroundStyle(sideColors.of(held.isBuy))
                    Text(held.typeLabel)
                    if held.limit != nil || held.stop != nil {
                        Text(Fmt.price(held.stop ?? held.price, for: symbol))
                    } else {
                        Text("≈ \(Fmt.price(held.price, for: symbol))").foregroundStyle(.secondary)
                    }
                    if let valueNOK { Text(Fmt.nok(valueNOK)).foregroundStyle(.secondary) }
                }
                .font(.system(size: 15, weight: .semibold).monospacedDigit())
                if !notes.isEmpty {
                    Text(notes.joined(separator: "; ")).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    Spacer()
                    Button { broker.dropHeld() } label: { Text("Cancel  Esc") }
                    Button { broker.sendHeld() } label: { Text("Send  ↩").fontWeight(.semibold) }
                        .tint(sideColors.of(held.isBuy))
                        .buttonStyle(.borderedProminent)
                }
                .controlSize(.small)
            }
            .padding(12)
            .frame(minWidth: 300)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .windowBackgroundColor))
                .shadow(color: .black.opacity(0.4), radius: 12))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(TradingChart.heldColor, lineWidth: 1.5))
        }
    }
}
