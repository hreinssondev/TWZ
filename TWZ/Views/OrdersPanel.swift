//
//  OrdersPanel.swift
//  TWZ
//

import SwiftUI

struct OrdersPanel: View {
    @Environment(Broker.self) private var broker
    @Environment(Workspace.self) private var workspace
    @AppStorage("ordersTab") private var tab = Tab.active

    enum Tab: String, CaseIterable { case active = "Active", filled = "Filled", positions = "Positions" }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { t in Text(title(for: t)).tag(t) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .padding(6)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    switch tab {
                    case .active: activeRows
                    case .filled: filledRows
                    case .positions: positionRows
                    }
                }
            }
        }
        .font(.system(size: 11).monospacedDigit())
        .background(Color(nsColor: .textBackgroundColor).opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.12)))
    }

    private var activeOrders: [OrderRow] {
        broker.orders.values.filter(\.isActive).sorted { $0.updated > $1.updated }
    }

    private func title(for tab: Tab) -> String {
        switch tab {
        case .active: "Active (\(activeOrders.count))"
        case .filled: "Filled (\(broker.fills.count))"
        case .positions: "Positions (\(broker.positions.count))"
        }
    }

    @ViewBuilder private var activeRows: some View {
        if activeOrders.isEmpty { empty("No working orders") }
        ForEach(activeOrders) { o in
            HStack(spacing: 6) {
                side(o.action == "BUY")
                symbolButton(o.symbol)
                Text("\(Fmt.shares(o.filled))/\(Fmt.shares(o.quantity))")
                Spacer()
                Text(o.orderType == "MKT" ? "MKT" : Fmt.price(o.limitPrice))
                Text(o.status).foregroundStyle(.secondary).frame(width: 74, alignment: .trailing)
                Button {
                    broker.cancelOrder(o.id)
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .help("Cancel order")
                .disabled(o.id <= 0)
            }
            .rowStyle()
        }
    }

    @ViewBuilder private var filledRows: some View {
        let fills = broker.fills.values.sorted { $0.time > $1.time }
        if fills.isEmpty { empty("No fills today") }
        ForEach(fills) { f in
            HStack(spacing: 6) {
                side(f.side == "BOT")
                symbolButton(f.symbol)
                Text(Fmt.shares(f.shares))
                Text("@ \(Fmt.price(f.price))")
                Spacer()
                Text(f.time, format: .dateTime.hour().minute().second()).foregroundStyle(.secondary)
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
            HStack(spacing: 6) {
                side(p.quantity > 0, long: true)
                symbolButton(p.symbol)
                Text(Fmt.shares(p.quantity))
                Text("@ \(Fmt.price(p.avgCost))").foregroundStyle(.secondary)
                Spacer()
                Text(Fmt.money(pnl, signed: true)).foregroundStyle((pnl ?? 0) >= 0 ? .green : .red)
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
        Text(text).foregroundStyle(.secondary).padding(.top, 16)
    }
}

private extension View {
    func rowStyle() -> some View {
        padding(.horizontal, 8).padding(.vertical, 3).lineLimit(1)
    }
}
