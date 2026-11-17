//
//  OrdersPanel.swift
//  TWZ
//
//  Orders and Positions side by side as two always-visible columns, with a draggable divider
//  between them; clicking one of their headers stacks them instead, Positions on top (clicking again
//  puts them side by side). Rows are two lines so they fit the narrow columns.
//  Orders lists the working orders and, once done, what each filled: dimmed, at its average fill price.
//  Fills of orders entered in TWS (which IB reports without an order id) in the same symbol, side and
//  second show as one row.
//  Filled orders and round trips name what placed them: the hotkey's price (Mid, Last, Bid, Ask),
//  Mkt, ⌥-click, or SL / TP.
//  A working order's row has a thin bar along its bottom that fills to the right as the order fills.
//  Below them, behind a draggable divider, two tabs: today's round trips with their profit or loss (dimmed),
//  and Borrow, what shorting the selected chart's stock takes (see BorrowTab).
//  Clicking empty space in the Orders or Positions column deselects the chart, so no hotkey or
//  order shortcut has a symbol to act on until a chart is clicked again.
//  Double-clicking a position selects the chart showing its stock, or loads it into the grid's last chart;
//  double-clicking an order selects the chart showing its stock, or loads it into the selected chart.
//

import SwiftUI

struct OrdersPanel: View {
    @Environment(Broker.self) private var broker
    @Environment(Workspace.self) private var workspace
    /// Width of the Orders column as a share of the panel; Positions takes the rest.
    @AppStorage("ordersWidth") private var ordersShare: Double = 1 / 2
    /// Positions on top of Orders instead of side by side.
    @AppStorage("ordersStacked") private var stacked = false
    /// Height of the Positions row as a share of the stack; Orders takes the rest.
    @AppStorage("positionsRow") private var positionsRowShare: Double = 1 / 3
    /// Height of the three columns as a share of the panel; round trips take the rest.
    @AppStorage("roundTripsSplit") private var columnsShare: Double = 0.5
    @AppStorage("bottomTab") private var bottomTab: BottomTab = .roundTrips

    private enum BottomTab: String { case roundTrips, borrow }

    private static let minColumnWidth: CGFloat = 60
    private static let minSectionHeight: CGFloat = 40
    /// Done orders and round trips are dimmed this much.
    private static let doneOpacity = 0.45

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
        .task { await BorrowTab.keepRatesLoaded(broker) }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.12)))
    }

    @ViewBuilder private var columns: some View {
        if stacked { stackedColumns } else { sideBySideColumns }
    }

    private var sideBySideColumns: some View {
        GeometryReader { geo in
            let total = max(geo.size.width - 1, Self.minColumnWidth * 2)   // minus the 1pt divider
            let minW = Self.minColumnWidth
            let ordersW = min(max(total * ordersShare, minW), total - minW)
            HStack(spacing: 0) {
                ordersColumn
                    .frame(width: ordersW)
                    .clipped()
                ResizeHandle(resizes: .horizontal, style: .line, thickness: 1, current: ordersW,
                             range: minW...(total - minW),
                             onChange: { ordersShare = $0 / total },
                             onReset: { ordersShare = 1 / 2 })
                positionsColumn
                    .clipped()
            }
        }
    }

    /// Positions over Orders.
    private var stackedColumns: some View {
        GeometryReader { geo in
            let total = max(geo.size.height - 1, Self.minSectionHeight * 2)   // minus the 1pt divider
            let minH = Self.minSectionHeight
            let positionsH = min(max(total * positionsRowShare, minH), total - minH)
            VStack(spacing: 0) {
                positionsColumn
                    .frame(height: positionsH)
                ResizeHandle(resizes: .vertical, style: .line, thickness: 1, current: positionsH,
                             range: minH...(total - minH),
                             onChange: { positionsRowShare = $0 / total },
                             onReset: { positionsRowShare = 1 / 3 })
                ordersColumn
            }
        }
    }

    private var ordersColumn: some View {
        column("Orders", count: activeOrders.count, onEmptyClick: deselectChart, onHeaderClick: toggleStacked) { orderRows }
    }

    private var positionsColumn: some View {
        column("Positions", count: broker.positions.count, onEmptyClick: deselectChart, onHeaderClick: toggleStacked) { positionRows }
    }

    private func toggleStacked() {
        stacked.toggle()
    }

    private func deselectChart() {
        workspace.isChartSelected = false
    }

    /// One always-visible column: a compact header and its own scrolling rows. `onEmptyClick` is
    /// called for clicks on the column's empty space (not on its rows' text or buttons), `onHeaderClick`
    /// for clicks on its header.
    private func column<Rows: View>(_ title: String, count: Int, trailing: Text? = nil,
                                    onEmptyClick: (() -> Void)? = nil, onHeaderClick: (() -> Void)? = nil,
                                    @ViewBuilder rows: () -> Rows) -> some View {
        column(title: {
            Text(title).fontWeight(.semibold)
            Text("\(count)").foregroundStyle(.secondary)
        }, trailing: trailing, onEmptyClick: onEmptyClick, onHeaderClick: onHeaderClick, rows: rows)
    }

    /// A column whose header starts with `title` (the bottom section's tabs).
    private func column<Title: View, Rows: View>(@ViewBuilder title: () -> Title, trailing: Text? = nil,
                                                 onEmptyClick: (() -> Void)? = nil, onHeaderClick: (() -> Void)? = nil,
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
            .contentShape(Rectangle())
            .onTapGesture { onHeaderClick?() }
            .help(onHeaderClick == nil ? "" : (stacked ? "Click to put side by side" : "Click to stack"))
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

    /// A row of the Orders column: a working order, or what a done order filled.
    private enum OrderEntry: Identifiable {
        case working(OrderRow)
        case filled(FillGroup)

        var id: String {
            switch self {
            case .working(let o): "order \(o.id)"
            case .filled(let g): g.id
            }
        }

        var time: Date {
            switch self {
            case .working(let o): o.updated
            case .filled(let g): g.fill.time
            }
        }
    }

    /// Working orders and filled ones, newest first.
    private var orderEntries: [OrderEntry] {
        let working = activeOrders
        let filled = fillGroups(excluding: Set(working.map(\.id)))
        return (working.map(OrderEntry.working) + filled.map(OrderEntry.filled)).sorted { $0.time > $1.time }
    }

    @ViewBuilder private var orderRows: some View {
        let entries = orderEntries
        if entries.isEmpty { empty("No orders today") }
        ForEach(entries) { entry in
            switch entry {
            case .working(let o): workingRow(o)
            case .filled(let g): filledRow(g)
            }
        }
    }

    private func workingRow(_ o: OrderRow) -> some View {
        // Value in NOK of the shares still to fill, at the order's price (the last price for market orders).
        let price = o.limitPrice ?? o.auxPrice ?? broker.quote(o.symbol)?.last
        let valueNOK = price.flatMap { p in broker.usdNok.map { (o.quantity - o.filled) * p * $0 } }
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                symbolButton(o.symbol, onDoubleClick: { workspace.focusOrder(o.symbol, broker: broker) })
                Spacer(minLength: 2)
                Text(o.status).foregroundStyle(.secondary).font(.system(size: 10))
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
                if let valueNOK { Text(Fmt.nok(valueNOK)).foregroundStyle(sideColor(o.action == "BUY")) }
                // Shares still to fill; the bar below shows how much has filled.
                Text("\(Fmt.shares(o.quantity - o.filled))\(o.priceSummary)")
                Spacer(minLength: 0)
            }
            .font(.system(size: 10).monospacedDigit())
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { workspace.focusOrder(o.symbol, broker: broker) }
        .help("Double-click to show \(o.symbol)'s chart")
        .rowStyle()
        .overlay(alignment: .bottom) { fillBar(o) }
    }

    /// A done order laid out like a working one, dimmed, with its fill time and average fill price.
    private func filledRow(_ g: FillGroup) -> some View {
        let f = g.fill
        let valueNOK = broker.usdNok.map { f.shares * f.price * $0 }
        let dim = Self.doneOpacity
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                symbolButton(f.symbol, onDoubleClick: { workspace.focusOrder(f.symbol, broker: broker) })
                Spacer(minLength: 2)
                if let source = broker.sourceLabel(g.orderIds) { Text(source) }
                Text(f.time, format: .dateTime.hour().minute().second())
            }
            .foregroundStyle(.secondary)
            .opacity(dim)
            HStack(spacing: 4) {
                if let valueNOK { Text(Fmt.nok(valueNOK)).foregroundStyle(sideColor(f.side == "BOT")) }
                Text("\(Fmt.shares(f.shares))\(g.order?.priceSummary ?? "")")
                Text("@ \(Fmt.price(f.price))").fontWeight(.semibold)
                Spacer(minLength: 0)
            }
            .opacity(dim)
            .font(.system(size: 10).monospacedDigit())
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { workspace.focusOrder(f.symbol, broker: broker) }
        .help("Double-click to show \(f.symbol)'s chart")
        .rowStyle()
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

    /// What filled of one done order (or, for orders entered in TWS, of fills in one symbol, side and
    /// second), at the volume-weighted average price, timed at the last fill.
    private struct FillGroup: Identifiable {
        var fill: Fill
        var orderIds: [Int]
        /// The order the fills came from, when known.
        var order: OrderRow?
        var id: String { fill.id }
    }

    /// The day's fills by order, leaving out those of `working` orders, which show as still working.
    /// A done order whose fills haven't arrived yet shows what its status reports (not TWS orders,
    /// whose fills can't be told apart by order).
    private func fillGroups(excluding working: Set<Int>) -> [FillGroup] {
        enum Key: Hashable { case order(Int), moment(symbol: String, side: String, second: Int) }
        var groups: [Key: FillGroup] = [:]
        for f in broker.fills.values.sorted(by: { ($0.time, $0.id) < ($1.time, $1.id) }) where !working.contains(f.orderId) {
            let key: Key = f.orderId != 0 ? .order(f.orderId)
                : .moment(symbol: f.symbol, side: f.side, second: Int(f.time.timeIntervalSince1970.rounded(.down)))
            guard var g = groups[key] else {
                groups[key] = FillGroup(fill: f, orderIds: [f.orderId], order: f.orderId != 0 ? broker.orders[f.orderId] : nil)
                continue
            }
            let shares = g.fill.shares + f.shares
            if shares > 0 { g.fill.price = (g.fill.price * g.fill.shares + f.price * f.shares) / shares }
            g.fill.shares = shares
            g.fill.time = f.time
            if !g.orderIds.contains(f.orderId) { g.orderIds.append(f.orderId) }
            groups[key] = g
        }
        for o in broker.orders.values where o.id > 0 && !o.isActive && o.filled > 0 && groups[.order(o.id)] == nil {
            let fill = Fill(id: "order \(o.id)", orderId: o.id, symbol: o.symbol, side: o.action == "BUY" ? "BOT" : "SLD",
                            shares: o.filled, price: o.avgFillPrice, time: o.updated)
            groups[.order(o.id)] = FillGroup(fill: fill, orderIds: [o.id], order: o)
        }
        return Array(groups.values)
    }

    @ViewBuilder private var positionRows: some View {
        let positions = broker.positions.values.sorted { $0.symbol < $1.symbol }
        if positions.isEmpty { empty("No positions") }
        ForEach(positions) { p in
            let last = broker.quote(p.symbol)?.last
            let pnl = last.map { ($0 - p.avgCost) * p.quantity }
            // Market value in NOK (at cost until there's a quote), under the symbol.
            let valueNOK = broker.usdNok.map { abs(p.quantity) * (last ?? p.avgCost) * $0 }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    // Double-click is told apart from the symbol's single click (loading it into the selected chart).
                    Text(p.symbol).fontWeight(.semibold)
                        .onTapGesture(count: 2) { workspace.focusPosition(p.symbol, broker: broker) }
                        .onTapGesture { workspace.loadIntoSelectedChart(p.symbol, broker: broker) }
                    Spacer(minLength: 2)
                    Text(Fmt.money(pnl, signed: true)).foregroundStyle((pnl ?? 0) >= 0 ? .green : .red)
                }
                HStack(spacing: 4) {
                    if let valueNOK { Text(Fmt.nok(valueNOK)) }
                    Text("\(Fmt.shares(p.quantity)) - \(Fmt.price(p.avgCost))")
                    Spacer(minLength: 0)
                }
                .font(.system(size: 10).monospacedDigit())
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { workspace.focusPosition(p.symbol, broker: broker) }
            .help("Double-click to show \(p.symbol)'s chart")
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
                        symbolButton(t.symbol)
                        if let sources = tripSources(t) { Text(sources).foregroundStyle(.secondary) }
                        if t.isOpen { Text("open").foregroundStyle(.secondary) }
                        Spacer(minLength: 2)
                        if let pnl { pnlText(pnl) } else { Text("—").foregroundStyle(.secondary) }
                    }
                    HStack(spacing: 4) {
                        let prices = "\(t.entryPrice.map { Fmt.price($0) } ?? "earlier") → \(t.exitPrice.map { Fmt.price($0) } ?? "…")"
                        // The position's value in NOK at the entry price (the exit's for shares held from before today);
                        // in dollars until there's an exchange rate.
                        let value = (t.entryPrice ?? t.exitPrice).map { p in
                            broker.usdNok.map { Fmt.nok(t.entryShares * p * $0) } ?? "$" + Int((t.entryShares * p).rounded()).formatted()
                        }
                        Text(value.map { "\($0) - \(prices)" } ?? prices)
                        Spacer(minLength: 2)
                        Text(t.start, format: .dateTime.hour().minute()).foregroundStyle(.secondary)
                    }
                    .font(.system(size: 10).monospacedDigit())
                }
                .opacity(Self.doneOpacity)
                .rowStyle()
            }
        }
    }

    private var borrow: some View {
        column(title: { tabs(roundTripCount: RoundTrip.build(fills: Array(broker.fills.values), positions: broker.positions).count) }) {
            BorrowTab()
        }
    }

    /// "3  Borrow AAPL Shortable 1.2M": the bottom section's tabs, the open one in bold.
    /// The selected chart's shortable status and shares to lend show on the Borrow tab either way.
    private func tabs(roundTripCount: Int) -> some View {
        HStack(spacing: 10) {
            tab(.roundTrips) {
                Text("\(roundTripCount)").foregroundStyle(.secondary)
            }
            tab(.borrow) {
                Text("Borrow")
                let symbol = workspace.targetSymbol
                if !symbol.isEmpty {
                    Text(symbol).foregroundStyle(.secondary)
                    if let level = broker.shortability[symbol] { ShortStatus(level: level) }
                    if let lendable = lendableShares(symbol, broker: broker) {
                        Text(lendable).foregroundStyle(.secondary).help("Shares IB has to lend")
                    }
                }
            }
        }
        .lineLimit(1)
    }

    private func tab<Label: View>(_ tab: BottomTab, @ViewBuilder label: () -> Label) -> some View {
        HStack(spacing: 4) { label() }
            .fontWeight(bottomTab == tab ? .semibold : .regular)
            .foregroundStyle(bottomTab == tab ? .primary : .secondary)
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

    /// A symbol that loads into the selected chart on click; with `onDoubleClick`, a double-click is
    /// told apart from that.
    @ViewBuilder
    private func symbolButton(_ symbol: String, color: Color = .primary, onDoubleClick: (() -> Void)? = nil) -> some View {
        let text = Text(symbol).fontWeight(.semibold).foregroundStyle(color)
        if let onDoubleClick {
            text
                .onTapGesture(count: 2, perform: onDoubleClick)
                .onTapGesture { workspace.loadIntoSelectedChart(symbol, broker: broker) }
        } else {
            text.onTapGesture { workspace.loadIntoSelectedChart(symbol, broker: broker) }
        }
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
