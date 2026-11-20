//
//  OrdersPanel.swift
//  TWZ
//
//  Orders and Positions side by side as two always-visible columns, with a draggable divider
//  between them; clicking the Orders header stacks them instead, Positions on top (clicking again
//  puts them side by side). Clicking the Positions header switches it between real positions and
//  what-if trades, and the charts' arrows with it (see `PositionsView`). Rows are two lines so they
//  fit the narrow columns.
//  Orders lists the working orders and, once done, what each filled: dimmed, at its average fill price.
//  Positions lists the newest first, then the what-if trades, newest first too (see `positionItems`).
//  A ⌃-click what-if buy shows among them too, as What-if, with IB's preview of its commissions and fees
//  and the margin it would take (it's never sent); its ✕ removes it, like ⌃-clicking its line.
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
//  Double-clicking a position (real or what-if), an order or a round trip selects the chart showing its
//  stock; with none, the grid goes back to where it last showed it, its list and cell, rather than
//  replacing a chart on screen, or to the list that has it now, a forex pair's Forex (see `Workspace.showChart`).
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
    /// Positions shows what-if trades instead of real positions (see `PositionsView`).
    @AppStorage(PositionsView.showsSimKey) private var showsSim = false
    /// Height of the three columns as a share of the panel; round trips take the rest.
    @AppStorage("roundTripsSplit") private var columnsShare: Double = 0.5
    @AppStorage("bottomTab") private var bottomTab: BottomTab = .roundTrips
    /// Round trips clicked to show how their orders were placed ("Mid → Bid"), their entry and exit
    /// prices and their start time, by trip id.
    @State private var tripsShowingDetails: Set<String> = []

    private enum BottomTab: String { case roundTrips, borrow }

    private static let minColumnWidth: CGFloat = 60
    private static let minSectionHeight: CGFloat = 40
    /// Done orders and round trips are dimmed this much (Settings › Appearance).
    @AppStorage(Dimmed.opacityKey) private var doneOpacity = Dimmed.defaultOpacity
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

    /// Its header switches between real positions and what-if trades (the Orders header stacks them).
    private var positionsColumn: some View {
        column(title: {
            Text(showsSim ? "Sim positions" : "Positions").fontWeight(.semibold)
                .foregroundStyle(showsSim ? TradingChart.whatIfColor : Color.primary)
            Text("\(showsSim ? broker.simPositions.count : broker.positions.count)").foregroundStyle(.secondary)
        }, onEmptyClick: deselectChart, onHeaderClick: { showsSim.toggle() },
           headerHelp: showsSim ? "Click to show real positions (and their trade arrows on the charts)"
                                : "Click to show what-if trades (and their arrows on the charts)") { positionRows }
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
                                                 headerHelp: String? = nil,
                                                 @ViewBuilder rows: () -> Rows) -> some View {
        let content = rows()
        return VStack(spacing: 0) {
            HStack(spacing: 4) {
                title()
                Spacer(minLength: 0)
                if let trailing { trailing }
            }
            .font(.system(size: 10))
            .opacity(dimsHeader ? doneOpacity : 1)
            .padding(.horizontal, 6)
            .frame(height: 16)
            .background(Color.primary.opacity(0.05))
            .contentShape(Rectangle())
            .onTapGesture { onHeaderClick?() }
            .help(headerHelp ?? (onHeaderClick == nil ? "" : (stacked ? "Click to put side by side" : "Click to stack")))
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
        case whatIf(symbol: String, WhatIf)

        var id: String {
            switch self {
            case .working(let o): "order \(o.id)"
            case .filled(let g): g.id
            case .whatIf(let symbol, _): "what-if \(symbol)"
            }
        }

        var time: Date {
            switch self {
            case .working(let o): o.updated
            case .filled(let g): g.fill.time
            case .whatIf(_, let w): w.time ?? .distantPast
            }
        }
    }

    /// Working orders, ⌃-click what-ifs and filled orders, newest first.
    private var orderEntries: [OrderEntry] {
        let working = activeOrders
        let filled = fillGroups(excluding: Set(working.map(\.id)))
        let whatIfs = workspace.whatIfs.map { OrderEntry.whatIf(symbol: $0.key, $0.value) }
        return (working.map(OrderEntry.working) + whatIfs + filled.map(OrderEntry.filled)).sorted { $0.time > $1.time }
    }

    @ViewBuilder private var orderRows: some View {
        let entries = orderEntries
        let trips = tripOrders
        if entries.isEmpty { empty("No orders today") }
        ForEach(entries) { entry in
            switch entry {
            case .working(let o): workingRow(o, tripOrders: trips.numbers["\(o.symbol) \(o.id)"])
            case .filled(let g): filledRow(g, tripOrders: trips.numbers["\(g.fill.symbol) \(RoundTrip.orderKey(g.fill))"])
            case .whatIf(let symbol, let w): whatIfRow(symbol, w)
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
        let usd = broker.usdPerPriceUnit(o.symbol)
        let valueNOK = price.flatMap { p in usd.flatMap { usd in (o.usdNok ?? broker.usdNok).map { (o.quantity - o.filled) * p * usd * $0 } } }
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

    /// A ⌃-click what-if buy laid out like a working order, in the what-if line's color, never sent:
    /// its value in NOK, price and shares, and IB's preview of its commissions and fees (in NOK, a
    /// range when IB gives one); the margin it would take in its tooltip.
    private func whatIfRow(_ symbol: String, _ w: WhatIf) -> some View {
        let valueNOK = broker.usdPerPriceUnit(symbol).flatMap { usd in broker.usdNok.map { w.shares * w.price * usd * $0 } }
        let fees = w.preview?.commission
        let feesText = fees.map(commissionRange)
        var help = "What-if: BUY \(Fmt.shares(w.shares)) \(symbol) LMT \(Fmt.price(w.price, for: symbol)), never sent. "
        if let p = w.preview {
            help += "IB's preview: initial margin +\(Fmt.nok(p.initMarginChange, groupedFrom: 0)) NOK"
            if let maint = p.maintMarginChange { help += ", maintenance margin +\(Fmt.nok(maint, groupedFrom: 0)) NOK" }
            if let fees {
                help += ", commissions and fees \(Self.range(fees.min, fees.max) { Fmt.amount($0) }) \(fees.currency). "
            } else {
                help += ", no commission given. "
            }
        } else {
            help += "IB's preview of its commissions and margin isn't in. "
        }
        help += "Double-click to show the chart; ✕ or ⌃-clicking its line removes it."
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                symbolButton(symbol, onDoubleClick: { workspace.focusOrder(symbol, broker: broker) })
                Spacer(minLength: 2)
                Text("What-if").foregroundStyle(TradingChart.whatIfColor).font(.system(size: 10))
                Button {
                    workspace.whatIfs[symbol] = nil
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .help("Remove the what-if")
            }
            HStack(spacing: 4) {
                if let valueNOK { Text(Fmt.nok(valueNOK, groupedFrom: Self.groupedFrom)).foregroundStyle(sideColor(true)) }
                Text("LMT \(Fmt.price(w.price, for: symbol))")
                Text(Fmt.shares(w.shares, groupedFrom: Self.groupedFrom))
                Spacer(minLength: 0)
                if let feesText { Text(feesText).foregroundStyle(.secondary) }
            }
            .font(.system(size: 10).monospacedDigit())
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { workspace.focusOrder(symbol, broker: broker) }
        .help(help)
        .rowStyle()
    }

    /// IB's commission estimate in whole NOK (a range when it gives one), or in its own currency
    /// without a rate for it.
    private func commissionRange(_ c: OrderPreview.Commission) -> String {
        let rate: Double? = c.currency == "NOK" ? 1 : c.currency == "USD" ? broker.usdNok : nil
        guard let rate else { return "\(Self.range(c.min, c.max) { Fmt.amount($0) }) \(c.currency)" }
        return Self.range(c.min * rate, c.max * rate) { Fmt.nok($0, groupedFrom: Self.groupedFrom) }
    }

    /// "12" or "12–15": one figure when both ends round alike.
    private static func range(_ low: Double, _ high: Double, _ format: (Double) -> String) -> String {
        let a = format(low), b = format(high)
        return a == b ? a : "\(a)–\(b)"
    }

    /// A done order laid out like a working one, dimmed, with its fill time and average fill price.
    private func filledRow(_ g: FillGroup, tripOrders: Int?) -> some View {
        let f = g.fill
        let valueNOK = broker.usdPerPriceUnit(f.symbol).flatMap { usd in (f.usdNok ?? broker.usdNok).map { f.shares * f.price * usd * $0 } }
        let dim = doneOpacity
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
                Text("@ \(Fmt.price(f.price, for: f.symbol))").fontWeight(.semibold)
                Text(Fmt.shares(f.shares, groupedFrom: Self.groupedFrom)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
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

    /// A row of the Positions column: a position, or a what-if trade.
    private enum PositionItem: Identifiable {
        case real(Position), sim(SimPosition)

        var id: String {
            switch self {
            case .real(let p): "position \(p.symbol)"
            case .sim(let sim): "sim \(sim.id)"
            }
        }

        var symbol: String {
            switch self {
            case .real(let p): p.symbol
            case .sim(let sim): sim.symbol
            }
        }

        var isSim: Bool {
            if case .sim = self { true } else { false }
        }
    }

    /// Positions, then what-if trades, each newest first: a position by the first fill of its open round
    /// trip, a what-if by when it was bought. Positions held from before today's fills, whose opening
    /// isn't known, go last among the positions, by symbol.
    private var positionItems: [PositionItem] {
        let opened = Dictionary(
            RoundTrip.build(fills: Array(broker.fills.values), positions: broker.positions)
                .filter { $0.isOpen && $0.carried == 0 }.map { ($0.symbol, $0.start) },
            uniquingKeysWith: max)
        // Real positions or what-if trades, as the header switches (see `PositionsView`).
        let items = showsSim
            ? broker.simPositions.values.map { (item: PositionItem.sim($0), opened: Optional($0.opened)) }
            : broker.positions.values.map { (item: PositionItem.real($0), opened: opened[$0.symbol]) }
        return items.sorted { a, b in
            if a.item.isSim != b.item.isSim { return b.item.isSim }
            return switch (a.opened, b.opened) {
            case let (x?, y?) where x != y: x > y
            case (.some, nil): true
            case (nil, .some): false
            default: (a.item.symbol, a.item.id) < (b.item.symbol, b.item.id)
            }
        }.map(\.item)
    }

    @ViewBuilder private var positionRows: some View {
        let items = positionItems
        let openTripOrders = tripOrders.open
        if items.isEmpty { empty(showsSim ? "No what-if trades" : "No positions") }
        ForEach(items) { item in
            switch item {
            case .real(let p): positionRow(p, tripOrders: openTripOrders[p.symbol])
            case .sim(let sim): simRow(sim)
            }
        }
    }

    private func positionRow(_ p: Position, tripOrders: Int?) -> some View {
        let last = broker.quote(p.symbol)?.last
        // In dollars: a forex pair's at its currency's dollar rate.
        let usd = broker.usdPerPriceUnit(p.symbol)
        let pnl = last.flatMap { last in usd.map { (last - p.avgCost) * p.quantity * $0 } }
        // Market value in NOK (at cost until there's a quote), under the symbol: green long, red short.
        let valueNOK = usd.flatMap { usd in broker.usdNok.map { abs(p.quantity) * (last ?? p.avgCost) * usd * $0 } }
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                // Double-click is told apart from the symbol's single click (loading it into the selected chart).
                Text(p.symbol).fontWeight(.semibold)
                    .onTapGesture(count: 2) { workspace.focusPosition(p.symbol, broker: broker) }
                    .onTapGesture { workspace.loadIntoSelectedChart(p.symbol, broker: broker) }
                tripOrdersText(tripOrders)
                Spacer(minLength: 2)
                // In NOK at the current rate, like the chart's position badge (dollars without a rate).
                Text(pnl.map { usd in broker.usdNok.map { Fmt.nok(usd * $0, signed: true, groupedFrom: Self.groupedFrom) }
                                   ?? Fmt.amount(usd, signed: true) } ?? "—")
                    .foregroundStyle(sideColors.of((pnl ?? 0) >= 0))
            }
            HStack(spacing: 4) {
                if let valueNOK { Text(Fmt.nok(valueNOK, groupedFrom: Self.groupedFrom)).foregroundStyle(sideColor(p.quantity > 0)) }
                Text("\(Fmt.shares(p.quantity, groupedFrom: Self.groupedFrom)) - \(Fmt.price(p.avgCost, for: p.symbol))")
                Spacer(minLength: 0)
            }
            .font(.system(size: 10).monospacedDigit())
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { workspace.focusPosition(p.symbol, broker: broker) }
        .help("Double-click to show \(p.symbol)'s chart")
        .rowStyle()
    }

    /// A what-if trade (simulated, see `SimTrades.swift`) laid out like a position, its symbol in the
    /// what-if pink: its P/L and value in NOK, shares and average price, its simulated stop loss
    /// and take profit, and IB's estimate of its commissions in and out (twice the way in's). ✕ takes it
    /// off without a fill.
    private func simRow(_ sim: SimPosition) -> some View {
        let symbol = sim.symbol
        let last = broker.quote(symbol)?.last
        let pnl = last.flatMap { broker.simPnLNOK(sim, at: $0) }
        let valueNOK = broker.usdPerPriceUnit(symbol).flatMap { usd in
            broker.usdNok.map { abs(sim.quantity) * (last ?? sim.avgCost) * usd * $0 }
        }
        let fees = sim.entryCommission.map { OrderPreview.Commission(min: $0.min * 2, max: $0.max * 2, currency: $0.currency) }
        let exits = [sim.stopLoss.map { "SL \(Fmt.price($0, for: symbol))" }, sim.takeProfit.map { "TP \(Fmt.price($0, for: symbol))" }]
            .compactMap { $0 }
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                // The symbol in the what-if color marks it as simulated.
                symbolButton(symbol, color: TradingChart.whatIfColor, onDoubleClick: { workspace.focusPosition(symbol, broker: broker) })
                Spacer(minLength: 2)
                Text(pnl.map { Fmt.nok($0, signed: true, groupedFrom: Self.groupedFrom) } ?? "—")
                    .foregroundStyle(sideColors.of((pnl ?? 0) >= 0))
                Button {
                    broker.removeSim(symbol)
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Take the what-if trade off (⌘⌫ on its chart closes it at market instead)")
            }
            HStack(spacing: 4) {
                if let valueNOK { Text(Fmt.nok(valueNOK, groupedFrom: Self.groupedFrom)).foregroundStyle(sideColor(sim.isLong)) }
                Text("\(Fmt.shares(sim.quantity, groupedFrom: Self.groupedFrom)) - \(Fmt.price(sim.avgCost, for: symbol))")
                if !exits.isEmpty { Text(exits.joined(separator: " ")).foregroundStyle(.secondary) }
                Spacer(minLength: 0)
                if let fees { Text(commissionRange(fees)).foregroundStyle(.secondary) }
            }
            .font(.system(size: 10).monospacedDigit())
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { workspace.focusPosition(symbol, broker: broker) }
        .help("What-if trade in \(symbol), simulated and never sent to IB; fees are IB's estimate in and out. "
              + "Double-click to show its chart.")
        .rowStyle()
    }

    /// Today's round trips, newest first; the header sums the closed ones.
    private var roundTrips: some View {
        let trips = RoundTrip.build(fills: Array(broker.fills.values), positions: broker.positions)
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
                        let prices = "\(t.entryPrice.map { Fmt.price($0, for: t.symbol) } ?? "earlier") → \(t.exitPrice.map { Fmt.price($0, for: t.symbol) } ?? "…")"
                        // The position's value in NOK at the entry price (the exit's for shares held from before today);
                        // in dollars until there's an exchange rate.
                        let usd = broker.usdPerPriceUnit(t.symbol)
                        let value = (t.entryPrice ?? t.exitPrice).flatMap { p in usd.map { usd in
                            (t.usdNok ?? broker.usdNok).map { Fmt.nok(t.entryShares * p * usd * $0, groupedFrom: Self.groupedFrom) }
                                ?? "$" + Int((t.entryShares * p * usd).rounded()).formatted()
                        } }
                        if details {
                            Text(value.map { "\($0) - \(prices)" } ?? prices)
                        } else if let value {
                            Text(value)
                        }
                        if details || value != nil { Text("-").foregroundStyle(.secondary) }
                        shares
                        Spacer(minLength: 2)
                        if details { Text(t.start, format: .dateTime.hour().minute()).foregroundStyle(.secondary) }
                        commissionText(t.commissions != 0 ? t.commissions : nil, usdNok: t.usdNok ?? broker.usdNok)
                    }
                    .font(.system(size: 10).monospacedDigit())
                }
                .opacity(doneOpacity)
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
        guard let rate = broker.usdPerPriceUnit(t.symbol), let usd = t.pnl(last: last, usdPerUnit: rate) else { return nil }
        return (t.usdNok ?? broker.usdNok).map { (usd * $0, true) } ?? (usd, false)
    }

    /// Commissions and fees reported for a working order's fills so far, in dollars (nil before any).
    private func orderCommission(_ id: Int) -> Double? {
        let reported = broker.fills.values.filter { $0.orderId == id }.compactMap(\.commission)
        return reported.isEmpty ? nil : reported.reduce(0, +)
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
        let prices = [auxPrice, limitPrice].compactMap { $0 }.map { Fmt.price($0, for: symbol) }
        return prices.isEmpty ? orderType : "\(orderType) \(prices.joined(separator: "/"))"
    }
}

private extension View {
    func rowStyle() -> some View {
        padding(.horizontal, 6).padding(.vertical, 3).lineLimit(1)
            .overlay(alignment: .bottom) { Divider().opacity(0.4) }
    }
}
