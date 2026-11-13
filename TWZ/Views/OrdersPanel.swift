//
//  OrdersPanel.swift
//  TWZ
//
//  Orders, Filled and Positions side by side as three always-visible columns,
//  with draggable dividers between them. Rows are two lines so they fit the narrow columns.
//  Fills in the same symbol, side and second show as one row at their average price.
//  Fills and round trips name what placed their orders: the hotkey's price (Mid, Last, Bid, Ask),
//  Mkt, ⌥-click, or SL / TP.
//  A working order's row has a thin bar along its bottom that fills to the right as the order fills.
//  Below them, behind a draggable divider, two tabs: today's round trips with their profit or loss,
//  and Borrow, what shorting the selected chart's stock takes (see BorrowTab).
//  Clicking empty space in the Orders or Positions column deselects the chart, so no hotkey or
//  order shortcut has a symbol to act on until a chart is clicked again.
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
    @AppStorage("bottomTab") private var bottomTab: BottomTab = .roundTrips

    private enum BottomTab: String { case roundTrips, borrow }

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
                switch bottomTab {
                case .roundTrips: roundTrips
                case .borrow: borrow
                }
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
                column("Orders", count: activeOrders.count, onEmptyClick: deselectChart) { activeRows }
                    .frame(width: ordersW)
                // Each divider trades width with its neighbour; the column on the far side stays put.
                ResizeHandle(resizes: .horizontal, style: .line, thickness: 1, current: ordersW,
                             range: minW...(ordersW + filledW - minW),
                             onChange: { w in
                                 ordersShare = w / total
                                 filledShare = (ordersW + filledW - w) / total
                             },
                             onReset: resetColumns)
                column("Filled", count: groupedFills.count) { filledRows }
                    .frame(width: filledW)
                ResizeHandle(resizes: .horizontal, style: .line, thickness: 1, current: filledW,
                             range: minW...(total - ordersW - minW),
                             onChange: { filledShare = $0 / total },
                             onReset: resetColumns)
                column("Positions", count: broker.positions.count, onEmptyClick: deselectChart) { positionRows }
            }
        }
    }

    private func deselectChart() {
        workspace.isChartSelected = false
    }

    private func resetColumns() {
        ordersShare = 1 / 3
        filledShare = 1 / 3
    }

    /// One always-visible column: a compact header and its own scrolling rows. `onEmptyClick` is
    /// called for clicks on the column's empty space (not on its rows' text or buttons).
    private func column<Rows: View>(_ title: String, count: Int, trailing: Text? = nil,
                                    onEmptyClick: (() -> Void)? = nil,
                                    @ViewBuilder rows: () -> Rows) -> some View {
        column(title: {
            Text(title).fontWeight(.semibold)
            Text("\(count)").foregroundStyle(.secondary)
        }, trailing: trailing, onEmptyClick: onEmptyClick, rows: rows)
    }

    /// A column whose header starts with `title` (the bottom section's tabs).
    private func column<Title: View, Rows: View>(@ViewBuilder title: () -> Title, trailing: Text? = nil,
                                                 onEmptyClick: (() -> Void)? = nil,
                                                 @ViewBuilder rows: () -> Rows) -> some View {
        let content = rows()
        return VStack(spacing: 0) {
            HStack(spacing: 4) {
                title()
                Spacer(minLength: 0)
                if let trailing { trailing }
            }
            .font(.system(size: 10))
            .padding(.horizontal, 6)
            .frame(height: 16)
            .background(Color.primary.opacity(0.05))
            GeometryReader { geo in
                ScrollView {
                    LazyVStack(spacing: 0) { content }
                        .frame(minHeight: geo.size.height, alignment: .top)
                        .background {
                            if let onEmptyClick {
                                Color.clear.contentShape(Rectangle()).onTapGesture(perform: onEmptyClick)
                            }
                        }
                }
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
                    symbolButton(o.symbol, color: sideColor(o.action == "BUY"))
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
                    // Shares still to fill; the bar below shows how much has filled.
                    Text(Fmt.shares(o.quantity - o.filled))
                        .foregroundStyle(sideColor(o.action == "BUY"))
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
            .frame(height: 3)
            .animation(.easeOut(duration: 0.25), value: fraction)
            .allowsHitTesting(false)
    }

    /// A row of fills in one symbol, side and second, with the orders they came from.
    private struct FillGroup: Identifiable {
        var fill: Fill
        var orderIds: [Int]
        var id: String { fill.id }
    }

    /// The day's fills, newest first, with fills in the same symbol, side and second added together
    /// at their volume-weighted average price.
    private var groupedFills: [FillGroup] {
        struct Key: Hashable { var symbol: String; var side: String; var second: Int }
        var groups: [Key: FillGroup] = [:]
        for f in broker.fills.values.sorted(by: { ($0.time, $0.id) < ($1.time, $1.id) }) {
            let key = Key(symbol: f.symbol, side: f.side, second: Int(f.time.timeIntervalSince1970.rounded(.down)))
            guard var g = groups[key] else { groups[key] = FillGroup(fill: f, orderIds: [f.orderId]); continue }
            let shares = g.fill.shares + f.shares
            if shares > 0 { g.fill.price = (g.fill.price * g.fill.shares + f.price * f.shares) / shares }
            g.fill.shares = shares
            if !g.orderIds.contains(f.orderId) { g.orderIds.append(f.orderId) }
            groups[key] = g
        }
        return groups.values.sorted { ($0.fill.time, $0.fill.id) > ($1.fill.time, $1.fill.id) }
    }

    @ViewBuilder private var filledRows: some View {
        let fills = groupedFills
        if fills.isEmpty { empty("No fills today") }
        ForEach(fills) { group in
            let f = group.fill
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    symbolButton(f.symbol, color: sideColor(f.side == "BOT"))
                    Spacer(minLength: 2)
                    Text(f.time, format: .dateTime.hour().minute().second()).foregroundStyle(.secondary)
                }
                HStack(spacing: 4) {
                    Text("\(Text(Fmt.shares(f.shares)).foregroundStyle(sideColor(f.side == "BOT"))) - \(Fmt.price(f.price))")
                    Spacer(minLength: 2)
                    if let source = broker.sourceLabel(group.orderIds) {
                        Text(source).foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 10).monospacedDigit())
            }
            .rowStyle()
        }
    }

    @ViewBuilder private var positionRows: some View {
        let positions = broker.positions.values.sorted { $0.symbol < $1.symbol }
        if positions.isEmpty { empty("No positions") }
        ForEach(positions) { p in
            let last = broker.quote(p.symbol)?.last
            let pnl = last.map { ($0 - p.avgCost) * p.quantity }
            // Market value in NOK (at cost until there's a quote), under the P/L.
            let valueNOK = broker.usdNok.map { abs(p.quantity) * (last ?? p.avgCost) * $0 }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    symbolButton(p.symbol, color: sideColor(p.quantity > 0))
                    Spacer(minLength: 2)
                    Text(Fmt.money(pnl, signed: true)).foregroundStyle((pnl ?? 0) >= 0 ? .green : .red)
                }
                HStack(spacing: 4) {
                    Text("\(Text(Fmt.shares(p.quantity)).foregroundStyle(sideColor(p.quantity > 0))) - \(Fmt.price(p.avgCost))")
                    if let valueNOK {
                        Spacer(minLength: 2)
                        Text(Fmt.amount(valueNOK)).foregroundStyle(.secondary)
                    }
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
        return column(title: { tabs(roundTripCount: trips.count) },
                      trailing: realized.map { pnlText($0).fontWeight(.semibold) }) {
            if trips.isEmpty { empty("No trades today") }
            ForEach(trips) { t in
                let pnl = t.pnl(last: broker.quote(t.symbol)?.last)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        symbolButton(t.symbol, color: sideColor(t.isLong))
                        if let sources = tripSources(t) { Text(sources).foregroundStyle(.secondary) }
                        if t.isOpen { Text("open").foregroundStyle(.secondary) }
                        Spacer(minLength: 2)
                        if let pnl { pnlText(pnl) } else { Text("—").foregroundStyle(.secondary) }
                    }
                    HStack(spacing: 4) {
                        let prices = "\(t.entryPrice.map { Fmt.price($0) } ?? "earlier") → \(t.exitPrice.map { Fmt.price($0) } ?? "…")"
                        Text("\(Text(Fmt.shares(t.entryShares)).foregroundStyle(sideColor(t.isLong))) - \(prices)")
                        Spacer(minLength: 2)
                        Text(t.start, format: .dateTime.hour().minute()).foregroundStyle(.secondary)
                    }
                    .font(.system(size: 10).monospacedDigit())
                }
                .rowStyle()
            }
        }
    }

    private var borrow: some View {
        column(title: { tabs(roundTripCount: RoundTrip.build(fills: Array(broker.fills.values), positions: broker.positions).count) }) {
            BorrowTab()
        }
    }

    /// "Round trips 3  Borrow": the bottom section's tabs, the open one in bold.
    private func tabs(roundTripCount: Int) -> some View {
        HStack(spacing: 10) {
            tab(.roundTrips) {
                Text("Round trips")
                Text("\(roundTripCount)").foregroundStyle(.secondary)
            }
            tab(.borrow) {
                Text("Borrow")
                if !workspace.targetSymbol.isEmpty { Text(workspace.targetSymbol).foregroundStyle(.secondary) }
            }
        }
    }

    private func tab<Label: View>(_ tab: BottomTab, @ViewBuilder label: () -> Label) -> some View {
        HStack(spacing: 4) { label() }
            .fontWeight(bottomTab == tab ? .semibold : .regular)
            .opacity(bottomTab == tab ? 1 : 0.6)
            .contentShape(Rectangle())
            .onTapGesture { bottomTab = tab }
    }

    /// "Mid → Bid": what placed the entry and exit orders ("?" for an unknown side).
    private func tripSources(_ t: RoundTrip) -> String? {
        let entry = broker.sourceLabel(t.entryOrderIds), exit = broker.sourceLabel(t.exitOrderIds)
        if entry == nil, exit == nil { return nil }
        guard !t.exitOrderIds.isEmpty else { return entry }
        return "\(entry ?? "?") → \(exit ?? "?")"
    }

    private func pnlText(_ pnl: Double) -> Text {
        Text(Fmt.money(pnl, signed: true)).foregroundStyle(pnl >= 0 ? .green : .red)
    }

    /// Text color for a buy / long (green) or sell / short (red).
    private func sideColor(_ isBuy: Bool) -> Color {
        isBuy ? .green : .red
    }

    private func symbolButton(_ symbol: String, color: Color = .primary) -> some View {
        Text(symbol).fontWeight(.semibold).foregroundStyle(color)
            .onTapGesture { workspace.loadIntoSelectedChart(symbol, broker: broker) }
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
