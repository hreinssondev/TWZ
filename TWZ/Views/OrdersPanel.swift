//
//  OrdersPanel.swift
//  TWZ
//
//  Orders, Filled and Positions side by side as three always-visible columns.
//  Rows are two lines so they fit the narrow columns.
//

import SwiftUI

struct OrdersPanel: View {
    @Environment(Broker.self) private var broker
    @Environment(Workspace.self) private var workspace

    var body: some View {
        HStack(spacing: 0) {
            column("Orders", count: activeOrders.count) { activeRows }
            Divider()
            column("Filled", count: broker.fills.count) { filledRows }
            Divider()
            column("Positions", count: broker.positions.count) { positionRows }
        }
        .font(.system(size: 11).monospacedDigit())
        .background(Color(nsColor: .textBackgroundColor).opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.12)))
    }

    /// One always-visible column: a compact header and its own scrolling rows, sharing width equally.
    private func column<Rows: View>(_ title: String, count: Int, @ViewBuilder rows: () -> Rows) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Text(title).fontWeight(.semibold)
                Text("\(count)").foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .font(.system(size: 10))
            .padding(.horizontal, 6)
            .frame(height: 16)
            .background(Color.primary.opacity(0.05))
            ScrollView {
                LazyVStack(spacing: 0) { rows() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var activeOrders: [OrderRow] {
        broker.orders.values.filter(\.isActive).sorted { $0.updated > $1.updated }
    }

    @ViewBuilder private var activeRows: some View {
        if activeOrders.isEmpty { empty("No working orders") }
        ForEach(activeOrders) { o in
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    side(o.action == "BUY")
                    symbolButton(o.symbol)
                    Spacer(minLength: 2)
                    Button {
                        broker.cancelOrder(o.id)
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .help("Cancel order")
                    .disabled(o.id <= 0)
                }
                HStack(spacing: 4) {
                    Text("\(Fmt.shares(o.filled))/\(Fmt.shares(o.quantity))")
                    Text(o.orderType == "MKT" ? "MKT" : "@ \(Fmt.price(o.limitPrice))")
                    Spacer(minLength: 2)
                    Text(o.status).foregroundStyle(.secondary)
                }
                .font(.system(size: 10).monospacedDigit())
            }
            .rowStyle()
        }
    }

    @ViewBuilder private var filledRows: some View {
        let fills = broker.fills.values.sorted { $0.time > $1.time }
        if fills.isEmpty { empty("No fills today") }
        ForEach(fills) { f in
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    side(f.side == "BOT")
                    symbolButton(f.symbol)
                    Spacer(minLength: 2)
                    Text(f.time, format: .dateTime.hour().minute().second()).foregroundStyle(.secondary)
                }
                Text("\(Fmt.shares(f.shares)) @ \(Fmt.price(f.price))")
                    .font(.system(size: 10).monospacedDigit())
            }
            .rowStyle()
        }
    }

    @ViewBuilder private var positionRows: some View {
        let positions = broker.positions.values.sorted { $0.symbol < $1.symbol }
        if positions.isEmpty { empty("No positions") }
        ForEach(positions) { p in
            let last = broker.quotes[p.symbol]?.last
            let pnl = last.map { ($0 - p.avgCost) * p.quantity }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    side(p.quantity > 0, long: true)
                    symbolButton(p.symbol)
                    Spacer(minLength: 2)
                    Text(Fmt.money(pnl, signed: true)).foregroundStyle((pnl ?? 0) >= 0 ? .green : .red)
                }
                HStack(spacing: 4) {
                    Text(Fmt.shares(p.quantity))
                    Text("@ \(Fmt.price(p.avgCost))").foregroundStyle(.secondary)
                }
                .font(.system(size: 10).monospacedDigit())
            }
            .rowStyle()
        }
    }

    private func side(_ isBuy: Bool, long: Bool = false) -> some View {
        Text(long ? (isBuy ? "L" : "S") : (isBuy ? "B" : "S"))
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 16, height: 16)
            .background(RoundedRectangle(cornerRadius: 3).fill(isBuy ? Color.green.opacity(0.7) : Color.red.opacity(0.7)))
    }

    private func symbolButton(_ symbol: String) -> some View {
        Text(symbol).fontWeight(.semibold)
            .onTapGesture { workspace.load(symbol, into: workspace.selectedChart, broker: broker) }
    }

    private func empty(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private extension View {
    func rowStyle() -> some View {
        padding(.horizontal, 6).padding(.vertical, 3).lineLimit(1)
            .overlay(alignment: .bottom) { Divider().opacity(0.4) }
    }
}
