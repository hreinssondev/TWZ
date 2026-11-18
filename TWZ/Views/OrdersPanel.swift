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
//  A number after the symbol counts the orders that opened or added to its round trip, long or short, not
//  the closing ones (an order in several fills once): a position's open trip, each round trip. An order's
//  number is its own place in its trip: the 1st, 2nd, 3rd order opening or adding to it, or the 1st, 2nd
//  closing it, once it has fills.
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
    @Environment(\.sideColors) private var sideColors
    /// Width of the Orders column as a share of the panel; Positions takes the rest.
    @AppStorage("ordersWidth") private var ordersShare: Double = 1 / 2
    /// Positions on top of Orders instead of side by side.
    @AppStorage("ordersStacked") private var stacked = false
    /// Height of the Positions row as a share of the stack; Orders takes the rest.
    @AppStorage("positionsRow") private var positionsRowShare: Double = 1 / 3
    /// Height of the three columns as a share of the panel; round trips take the rest.
    @AppStorage("roundTripsSplit") private var columnsShare: Double = 0.5
    @AppStorage("bottomTab") private var bottomTab: BottomTab = .roundTrips
    /// Round trips clicked to show how their orders were placed ("Mid → Bid"), their entry and exit
    /// prices and their start time, by trip id.
    @State private var tripsShowingDetails: Set<String> = []

    private enum BottomTab: String { case roundTrips, borrow }

    private static let minColumnWidth: CGFloat = 60
    private static let minSectionHeight: CGFloat = 40
    /// Done orders and round trips are dimmed this much.
    private static let doneOpacity = 0.45
    /// NOK values and share counts from five digits up are grouped by thousands ("10 000"), shorter
    /// ones not ("9999").
    private static let groupedFrom = 10_000

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

    /// A column whose header starts with `title` (the bottom section's tabs, whose header is dimmed
    /// like its round trips: `dimsHeader`).
    private func column<Title: View, Rows: View>(@ViewBuilder title: () -> Title, trailing: Text? = nil,
                                                 dimsHeader: Bool = false,
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
            .opacity(dimsHeader ? Self.doneOpacity : 1)
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
        let trips = tripOrders
        if entries.isEmpty { empty("No orders today") }
        ForEach(entries) { entry in
            switch entry {
            case .working(let o): workingRow(o, tripOrders: trips.numbers["\(o.symbol) \(o.id)"])
            case .filled(let g): filledRow(g, tripOrders: trips.numbers["\(g.fill.symbol) \(RoundTrip.orderKey(g.fill))"])
            }
        }
    }

    /// Each order's place in its round trip, by symbol and `RoundTrip.orderKey`: the nth opening or
    /// adding to it, or the nth closing it (an order that flips a position, in the newer trip). And by
    /// symbol, the orders that opened or added to its open trip.
    private var tripOrders: (numbers: [String: Int], open: [String: Int]) {
        var numbers: [String: Int] = [:], open: [String: Int] = [:]
        for t in RoundTrip.build(fills: Array(broker.fills.values), positions: broker.positions).reversed() {
            for (i, order) in t.exitOrders.enumerated() { numbers["\(t.symbol) \(order)"] = i + 1 }
            for (i, order) in t.entryOrders.enumerated() { numbers["\(t.symbol) \(order)"] = i + 1 }
            if t.isOpen { open[t.symbol] = t.orderCount }
        }
        return (numbers, open)
    }

    /// "6" right after a symbol: the orders that opened or added to its round trip, or an order's place in it.
    @ViewBuilder private func tripOrdersText(_ count: Int?) -> some View {
        if let count, count > 0 { Text("\(count)").foregroundStyle(.primary) }
    }

    private func workingRow(_ o: OrderRow, tripOrders: Int?) -> some View {
        // Value in NOK of the shares still to fill, at the order's price (the last price for market orders).
        let price = o.limitPrice ?? o.auxPrice ?? broker.quote(o.symbol)?.last
        let valueNOK = price.flatMap { p in (o.usdNok ?? broker.usdNok).map { (o.quantity - o.filled) * p * $0 } }
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                symbolButton(o.symbol, onDoubleClick: { workspace.focusOrder(o.symbol, broker: broker) })
                tripOrdersText(tripOrders)
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
                if let valueNOK { Text(Fmt.nok(valueNOK, groupedFrom: Self.groupedFrom)).foregroundStyle(sideColor(o.action == "BUY")) }
                Text(o.priceSummary)
                // Shares still to fill; the bar below shows how much has filled.
                Text(Fmt.shares(o.quantity - o.filled, groupedFrom: Self.groupedFrom))
                Spacer(minLength: 0)
                tieredText(orderTiered(o.id), usdNok: o.usdNok ?? broker.usdNok)
                commissionText(orderCommission(o.id), usdNok: o.usdNok ?? broker.usdNok)
            }
            .font(.system(size: 10).monospacedDigit())
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { workspace.focusOrder(o.symbol, broker: broker) }
        .help("Double-click to show \(o.symbol)'s chart")
        .rowStyle()
        // Only while it's partly filled.
        .overlay(alignment: .bottom) { if o.filled > 0, o.filled < o.quantity { fillBar(o) } }
    }

    /// A done order laid out like a working one, dimmed, with its fill time and average fill price.
    private func filledRow(_ g: FillGroup, tripOrders: Int?) -> some View {
        let f = g.fill
        let valueNOK = (f.usdNok ?? broker.usdNok).map { f.shares * f.price * $0 }
        let dim = Self.doneOpacity
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                symbolButton(f.symbol, onDoubleClick: { showFills(g) })
                tripOrdersText(tripOrders)
                Spacer(minLength: 2)
                if let source = broker.sourceLabel(g.orderIds) { Text(source) }
                Text(f.time, format: .dateTime.hour().minute().second())
            }
            .foregroundStyle(.secondary)
            .opacity(dim)
            HStack(spacing: 4) {
                if let valueNOK { Text(Fmt.nok(valueNOK, groupedFrom: Self.groupedFrom)).foregroundStyle(sideColor(f.side == "BOT")) }
                if let order = g.order { Text(order.priceSummary) }
                Text("@ \(Fmt.price(f.price))").fontWeight(.semibold)
                Text(Fmt.shares(f.shares, groupedFrom: Self.groupedFrom)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                tieredText(tiered(g.fillIds), usdNok: f.usdNok ?? broker.usdNok)
                commissionText(f.commission, usdNok: f.usdNok ?? broker.usdNok)
            }
            .opacity(dim)
            .font(.system(size: 10).monospacedDigit())
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { showFills(g) }
        .help("Double-click to show its fills on \(f.symbol)'s chart")
        .rowStyle()
    }

    /// A filled order's fills on its stock's chart; just the chart while they haven't arrived.
    private func showFills(_ g: FillGroup) {
        if g.fillIds.isEmpty {
            workspace.focusOrder(g.fill.symbol, broker: broker)
        } else {
            workspace.showFills(g.fillIds, symbol: g.fill.symbol, broker: broker)
        }
    }

    /// Filled share of the order, growing to the right; a scaled shape, so updates cost no layout.
    private func fillBar(_ o: OrderRow) -> some View {
        let fraction = o.quantity > 0 ? min(1, max(0, o.filled / o.quantity)) : 0
        let color = sideColors.of(o.action == "BUY")
        return Rectangle()
            .fill(color.opacity(0.7))
            .scaleEffect(x: fraction, y: 1, anchor: .leading)
            .background(color.opacity(0.12))
            .frame(height: 3)
            .animation(.easeOut(duration: 0.25), value: fraction)
            .allowsHitTesting(false)
    }

    /// What filled of one done order (or, for orders entered in TWS, of fills in one symbol, side and
    /// second), at the volume-weighted average price, timed at the last fill, with the commissions and
    /// fees reported for its fills so far.
    private struct FillGroup: Identifiable {
        var fill: Fill
        var orderIds: [Int]
        /// The fills' exec ids; none for a done order whose fills haven't arrived.
        var fillIds: Set<String> = []
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
                groups[key] = FillGroup(fill: f, orderIds: [f.orderId], fillIds: [f.id], order: f.orderId != 0 ? broker.orders[f.orderId] : nil)
                continue
            }
            g.fillIds.insert(f.id)
            let shares = g.fill.shares + f.shares
            if shares > 0 { g.fill.price = (g.fill.price * g.fill.shares + f.price * f.shares) / shares }
            g.fill.shares = shares
            g.fill.time = f.time
            if let c = f.commission { g.fill.commission = (g.fill.commission ?? 0) + c }
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
        let openTripOrders = tripOrders.open
        if positions.isEmpty { empty("No positions") }
        ForEach(positions) { p in
            let last = broker.quote(p.symbol)?.last
            let pnl = last.map { ($0 - p.avgCost) * p.quantity }
            // Market value in NOK (at cost until there's a quote), under the symbol: green long, red short.
            let valueNOK = broker.usdNok.map { abs(p.quantity) * (last ?? p.avgCost) * $0 }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    // Double-click is told apart from the symbol's single click (loading it into the selected chart).
                    Text(p.symbol).fontWeight(.semibold)
                        .onTapGesture(count: 2) { workspace.focusPosition(p.symbol, broker: broker) }
                        .onTapGesture { workspace.loadIntoSelectedChart(p.symbol, broker: broker) }
                    tripOrdersText(openTripOrders[p.symbol])
                    Spacer(minLength: 2)
                    // In NOK at the current rate, like the chart's position badge (dollars without a rate).
                    Text(pnl.map { usd in broker.usdNok.map { Fmt.nok(usd * $0, signed: true, groupedFrom: Self.groupedFrom) }
                                       ?? Fmt.amount(usd, signed: true) } ?? "—")
                        .foregroundStyle(sideColors.of((pnl ?? 0) >= 0))
                }
                HStack(spacing: 4) {
                    if let valueNOK { Text(Fmt.nok(valueNOK, groupedFrom: Self.groupedFrom)).foregroundStyle(sideColor(p.quantity > 0)) }
                    Text("\(Fmt.shares(p.quantity, groupedFrom: Self.groupedFrom)) - \(Fmt.price(p.avgCost))")
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
        let trips = RoundTrip.build(fills: Array(broker.fills.values), positions: broker.positions, tiered: broker.tieredEstimates)
        // Without any USD.NOK rate, every trip's P/L is in dollars, so the sum is in one currency either way.
        let closed = trips.filter { !$0.isOpen }.compactMap { tripPnL($0, last: nil) }
        let realized = closed.first.map { (value: closed.reduce(0) { $0 + $1.value }, inNOK: $0.inNOK) }
        return column(title: { tabs(roundTripCount: trips.count) },
                      trailing: realized.map { pnlText($0.value, inNOK: $0.inNOK).fontWeight(.semibold) }, dimsHeader: true) {
            if trips.isEmpty { empty("No trades today") }
            ForEach(trips) { t in
                let pnl = tripPnL(t, last: broker.quote(t.symbol)?.last)
                let details = tripsShowingDetails.contains(t.id)
                // Shares bought and sold in the trip together (today's fills), after the prices with the
                // details shown, after the NOK value without; a "-" before them, colored like them.
                let shares = Text(Fmt.shares(t.buyShares + t.sellShares, groupedFrom: Self.groupedFrom)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        symbolButton(t.symbol)
                        // Every order in the trip, entries and exits (other rows count entries only).
                        tripOrdersText(t.entryOrders.count + t.exitOrders.count)
                        if details, let sources = tripSources(t) {
                            Text(sources).foregroundStyle(.secondary)
                        }
                        if t.isOpen { Text("open").foregroundStyle(.secondary) }
                        Spacer(minLength: 2)
                        if let pnl { pnlText(pnl.value, inNOK: pnl.inNOK) } else { Text("—").foregroundStyle(.secondary) }
                    }
                    HStack(spacing: 4) {
                        let prices = "\(t.entryPrice.map { Fmt.price($0) } ?? "earlier") → \(t.exitPrice.map { Fmt.price($0) } ?? "…")"
                        // The position's value in NOK at the entry price (the exit's for shares held from before today);
                        // in dollars until there's an exchange rate.
                        let value = (t.entryPrice ?? t.exitPrice).map { p in
                            (t.usdNok ?? broker.usdNok).map { Fmt.nok(t.entryShares * p * $0, groupedFrom: Self.groupedFrom) } ?? "$" + Int((t.entryShares * p).rounded()).formatted()
                        }
                        if details {
                            Text(value.map { "\($0) - \(prices)" } ?? prices)
                        } else if let value {
                            Text(value)
                        }
                        if details || value != nil { Text("-").foregroundStyle(.secondary) }
                        shares
                        Spacer(minLength: 2)
                        if details { Text(t.start, format: .dateTime.hour().minute()).foregroundStyle(.secondary) }
                        tieredText(t.tieredCommissions != 0 ? t.tieredCommissions : nil, usdNok: t.usdNok ?? broker.usdNok)
                        commissionText(t.commissions != 0 ? t.commissions : nil, usdNok: t.usdNok ?? broker.usdNok)
                    }
                    .font(.system(size: 10).monospacedDigit())
                }
                .opacity(Self.doneOpacity)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { workspace.showTrip(t, broker: broker) }
                .onTapGesture { tripsShowingDetails.formSymmetricDifference([t.id]) }
                .help("Click to show or hide how its orders were placed and its prices · Double-click to show the trade on \(t.symbol)'s chart")
                .rowStyle()
            }
        }
    }

    private var borrow: some View {
        column(title: { tabs(roundTripCount: RoundTrip.build(fills: Array(broker.fills.values), positions: broker.positions).count) },
               dimsHeader: true) {
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

    /// A round trip's P/L in NOK at the trip's rate (the current one for a trip from before there was a
    /// rate), or in dollars without any rate.
    private func tripPnL(_ t: RoundTrip, last: Double?) -> (value: Double, inNOK: Bool)? {
        guard let usd = t.pnl(last: last) else { return nil }
        return (t.usdNok ?? broker.usdNok).map { (usd * $0, true) } ?? (usd, false)
    }

    /// Commissions and fees reported for a working order's fills so far, in dollars (nil before any).
    private func orderCommission(_ id: Int) -> Double? {
        let reported = broker.fills.values.filter { $0.orderId == id }.compactMap(\.commission)
        return reported.isEmpty ? nil : reported.reduce(0, +)
    }

    /// What a working order's fills so far would have cost on IBKR Pro Tiered, in dollars (nil before any estimate).
    private func orderTiered(_ id: Int) -> Double? {
        tiered(Set(broker.fills.values.filter { $0.orderId == id }.map(\.id)))
    }

    /// What these fills would have cost on IBKR Pro Tiered, in dollars (nil before any estimate).
    private func tiered(_ fillIds: Set<String>) -> Double? {
        let estimates = fillIds.compactMap { broker.tieredEstimates[$0] }
        return estimates.isEmpty ? nil : estimates.reduce(0, +)
    }

    /// The commissions and fees IBKR Pro Tiered would have charged, left of what IB charged: whole NOK
    /// at `usdNok` (dollars and cents without a rate), a slightly darker gray than it.
    @ViewBuilder private func tieredText(_ usd: Double?, usdNok: Double?) -> some View {
        if let usd {
            Text(usdNok.map { Fmt.nok(usd * $0, groupedFrom: Self.groupedFrom) } ?? Fmt.amount(usd))
                .foregroundStyle(.secondary.opacity(0.7))
                .help("Commissions and fees on IBKR Pro Tiered (estimate)")
        }
    }

    /// Commissions and fees, dimmed like the times: whole NOK at `usdNok`, dollars and cents without a rate.
    @ViewBuilder private func commissionText(_ usd: Double?, usdNok: Double?) -> some View {
        if let usd {
            Text(usdNok.map { Fmt.nok(usd * $0, groupedFrom: Self.groupedFrom) } ?? Fmt.amount(usd))
                .foregroundStyle(.secondary)
                .help("Commissions and fees")
        }
    }

    /// Whole kroner, or dollars and cents.
    private func pnlText(_ pnl: Double, inNOK: Bool) -> Text {
        Text(inNOK ? Fmt.nok(pnl, signed: true, groupedFrom: Self.groupedFrom) : Fmt.amount(pnl, signed: true))
            .foregroundStyle(sideColors.of(pnl >= 0))
    }

    /// Text color for a buy / long (green) or sell / short (red).
    private func sideColor(_ isBuy: Bool) -> Color {
        sideColors.of(isBuy)
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
