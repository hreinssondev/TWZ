//
//  OrdersPanel.swift
//  TWZ
//
//  Orders, Filled and Positions side by side as three always-visible columns,
//  with draggable dividers between them. Rows are two lines so they fit the narrow columns.
//  A working order's row has a thin bar along its bottom that fills to the right as the order fills.
//  Below them, behind a draggable divider, today's round trips with their profit or loss.
//

import SwiftUI

struct OrdersPanel: View {
    @Environment(Broker.self) private var broker
    @Environment(Workspace.self) private var workspace
    // Widths of the Orders and Filled columns as shares of the panel; Positions takes the rest.
    @AppStorage("ordersColumn") private var ordersShare: Double = 1 / 3
    @AppStorage("filledColumn") private var filledShare: Double = 1 / 3
    /// Height of the three columns as a share of the panel; round trips take the rest.
    @AppStorage("roundTripsSplit") private var columnsShare: Double = 0.5

    private static let minColumnWidth: CGFloat = 90
    private static let minSectionHeight: CGFloat = 40

    var body: some View {
        GeometryReader { geo in
            let total = max(geo.size.height - 1, Self.minSectionHeight * 2)   // minus the 1pt divider
            let minH = Self.minSectionHeight
            let columnsH = min(max(total * columnsShare, minH), total - minH)
            VStack(spacing: 0) {
                columns
                    .frame(height: columnsH)
                ResizeHandle(resizes: .vertical, style: .line, thickness: 1, current: columnsH,
                             range: minH...(total - minH),
                             onChange: { columnsShare = $0 / total },
                             onReset: { columnsShare = 0.5 })
                roundTrips
            }
        }
        .font(.system(size: 11).monospacedDigit())
        .background(Color(nsColor: .textBackgroundColor).opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.12)))
    }

    private var columns: some View {
        GeometryReader { geo in
            let total = max(geo.size.width - 2, Self.minColumnWidth * 3)   // minus the two 1pt dividers
            let minW = Self.minColumnWidth
            let ordersW = min(max(total * ordersShare, minW), total - minW * 2)
            let filledW = min(max(total * filledShare, minW), total - ordersW - minW)
            HStack(spacing: 0) {
                column("Orders", count: activeOrders.count) { activeRows }
                    .frame(width: ordersW)
                // Each divider trades width with its neighbour; the column on the far side stays put.
                ResizeHandle(resizes: .horizontal, style: .line, thickness: 1, current: ordersW,
                             range: minW...(ordersW + filledW - minW),
                             onChange: { w in
                                 ordersShare = w / total
                                 filledShare = (ordersW + filledW - w) / total
                             },
                             onReset: resetColumns)
                column("Filled", count: broker.fills.count) { filledRows }
                    .frame(width: filledW)
                ResizeHandle(resizes: .horizontal, style: .line, thickness: 1, current: filledW,
                             range: minW...(total - ordersW - minW),
                             onChange: { filledShare = $0 / total },
                             onReset: resetColumns)
                column("Positions", count: broker.positions.count) { positionRows }
            }
        }
    }

    private func resetColumns() {
        ordersShare = 1 / 3
        filledShare = 1 / 3
    }

    /// One always-visible column: a compact header and its own scrolling rows.
    private func column<Rows: View>(_ title: String, count: Int, trailing: Text? = nil,
                                    @ViewBuilder rows: () -> Rows) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Text(title).fontWeight(.semibold)
                Text("\(count)").foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if let trailing { trailing }
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
                        broker.cancelOrder(o.id, why: "Orders panel ✕")
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .help("Cancel order")
                    .disabled(o.id <= 0)
                }
                HStack(spacing: 4) {
                    Text("\(Fmt.shares(o.filled))/\(Fmt.shares(o.quantity))")
                    Text(o.priceSummary)
                    Spacer(minLength: 2)
                    Text(o.status).foregroundStyle(.secondary)
                }
                .font(.system(size: 10).monospacedDigit())
            }
            .rowStyle()
            .overlay(alignment: .bottom) { fillBar(o) }
        }
    }

    /// Filled share of the order, growing to the right; a scaled shape, so updates cost no layout.
    private func fillBar(_ o: OrderRow) -> some View {
        let fraction = o.quantity > 0 ? min(1, max(0, o.filled / o.quantity)) : 0
        let color = o.action == "BUY" ? Color.green : Color.red
        return Rectangle()
            .fill(color.opacity(0.7))
            .scaleEffect(x: fraction, y: 1, anchor: .leading)
            .background(color.opacity(0.12))
            .frame(height: 2)
            .animation(.easeOut(duration: 0.25), value: fraction)
            .allowsHitTesting(false)
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

    /// Today's round trips, newest first; the header sums the closed ones.
    private var roundTrips: some View {
        let trips = RoundTrip.build(fills: Array(broker.fills.values), positions: broker.positions)
        let closed = trips.filter { !$0.isOpen }.compactMap { $0.pnl(last: nil) }
        let realized = closed.isEmpty ? nil : closed.reduce(0, +)
        return column("Round trips", count: trips.count,
                      trailing: realized.map { pnlText($0).fontWeight(.semibold) }) {
            if trips.isEmpty { empty("No trades today") }
            ForEach(trips) { t in
                let pnl = t.pnl(last: broker.quotes[t.symbol]?.last)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        side(t.isLong, long: true)
                        symbolButton(t.symbol)
                        if t.isOpen { Text("open").foregroundStyle(.secondary) }
                        Spacer(minLength: 2)
                        if let pnl { pnlText(pnl) } else { Text("—").foregroundStyle(.secondary) }
                    }
                    HStack(spacing: 4) {
                        Text("\(Fmt.shares(t.entryShares)) @ \(t.entryPrice.map { Fmt.price($0) } ?? "earlier")"
                             + " → \(t.exitPrice.map { Fmt.price($0) } ?? "…")")
                        Spacer(minLength: 2)
                        Text(t.start, format: .dateTime.hour().minute()).foregroundStyle(.secondary)
                    }
                    .font(.system(size: 10).monospacedDigit())
                }
                .rowStyle()
            }
        }
    }

    private func pnlText(_ pnl: Double) -> Text {
        Text(Fmt.money(pnl, signed: true)).foregroundStyle(pnl >= 0 ? .green : .red)
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

private extension OrderRow {
    /// "LMT 12.30", "STP 12.10", "STP LMT 12.10/12.05", "MKT" …
    var priceSummary: String {
        let prices = [auxPrice, limitPrice].compactMap { $0 }.map { Fmt.price($0) }
        return prices.isEmpty ? orderType : "\(orderType) \(prices.joined(separator: "/"))"
    }
}

private extension View {
    func rowStyle() -> some View {
        padding(.horizontal, 6).padding(.vertical, 3).lineLimit(1)
            .overlay(alignment: .bottom) { Divider().opacity(0.4) }
    }
}
