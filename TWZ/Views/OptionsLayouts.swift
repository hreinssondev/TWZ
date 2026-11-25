//
//  OptionsLayouts.swift
//  TWZ
//
//  The Options window's layouts (see `OptionsWindow`): Simple, Chain, Strategy and Positions.
//

import SwiftUI

/// "45%".
private func chance(_ v: Double?) -> String {
    guard let v else { return "—" }
    return (v * 100).formatted(.number.precision(.fractionLength(0))) + "%"
}

private func ivText(_ v: Double?) -> String {
    guard let v else { return "—" }
    return (v * 100).formatted(.number.precision(.fractionLength(1)))
}

private func count(_ v: Double?) -> String {
    guard let v, v > 0 else { return "—" }
    return v >= 10_000 ? (v / 1000).formatted(.number.precision(.fractionLength(0))) + "k" : Int(v).formatted()
}

/// A table cell: fixed width, small monospaced digits.
private struct Cell: View {
    let text: String
    let width: CGFloat
    var alignment: Alignment = .trailing
    var color: Color = .primary
    var weight: Font.Weight = .regular

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: weight).monospacedDigit())
            .foregroundStyle(color)
            .lineLimit(1)
            .frame(width: width, alignment: alignment)
    }
}

/// A column title, with what it means on hover.
private struct Heading: View {
    let text: String
    let width: CGFloat
    var alignment: Alignment = .trailing
    var help = ""

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(width: width, alignment: alignment)
            .help(help)
    }
}

/// Where the price is, between the strikes.
private struct SpotLine: View {
    let underlying: String
    let spot: Double

    var body: some View {
        HStack(spacing: 6) {
            Rectangle().fill(Color.yellow.opacity(0.6)).frame(height: 1)
            Text("\(underlying) \(Fmt.price(spot))").font(.system(size: 10, weight: .semibold).monospacedDigit()).foregroundStyle(.yellow)
            Rectangle().fill(Color.yellow.opacity(0.6)).frame(height: 1)
        }
        .padding(.vertical, 2)
    }
}

/// Rows of strikes with the price's line where it falls.
private enum StrikeItem: Hashable, Identifiable {
    case strike(Double)
    case spot
    var id: String { if case .strike(let k) = self { "\(k)" } else { "spot" } }

    static func items(_ strikes: [Double], spot: Double?) -> [StrikeItem] {
        var items: [StrikeItem] = []
        var placed = spot == nil
        for k in strikes {
            if !placed, let spot, k > spot { items.append(.spot); placed = true }
            items.append(.strike(k))
        }
        if !placed { items.append(.spot) }
        return items
    }
}

// MARK: - Simple

/// One call or put to buy or sell: each strike with what it costs, where it breaks even, how far the price must go
/// and the chance it pays, said in plain words above.
struct OptionsSimpleLayout: View {
    @Bindable var desk: OptionsDesk
    let book: OptionBook
    let spot: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("I want to").font(.system(size: 12)).foregroundStyle(.secondary)
                Picker("", selection: $desk.simpleBuy) {
                    Text("Buy").tag(true)
                    Text("Sell").tag(false)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Picker("", selection: $desk.simpleRight) {
                    Text("Calls").tag(OptionRight.call)
                    Text("Puts").tag(OptionRight.put)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Spacer()
            }
            Text(explanation)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SimpleRow.header(buy: desk.simpleBuy)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(StrikeItem.items(book.visible(spot: spot, each: desk.strikesEachSide), spot: spot)) { item in
                        switch item {
                        case .spot: if let spot { SpotLine(underlying: desk.underlying, spot: spot) }
                        case .strike(let k):
                            if let contract = book.contract(k, desk.simpleRight) {
                                SimpleRow(desk: desk, contract: contract, spot: spot)
                            }
                        }
                    }
                }
            }
        }
        .padding(12)
    }

    private var explanation: String {
        let u = desk.underlying
        switch (desk.simpleBuy, desk.simpleRight) {
        case (true, .call):
            return "Buying a call: the right to buy 100 shares of \(u) at the strike until expiry. You gain if \(u) ends above the breakeven "
                + "(the strike plus what you paid). The most you can lose is what you pay. Pick a row to put it in the ticket."
        case (true, .put):
            return "Buying a put: the right to sell 100 shares of \(u) at the strike until expiry. You gain if \(u) ends below the breakeven "
                + "(the strike less what you paid). The most you can lose is what you pay. Pick a row to put it in the ticket."
        case (false, .call):
            return "Selling a call: you're paid now and keep it all if \(u) ends below the strike. Above the breakeven you lose, with no limit, "
                + "unless you own 100 shares a contract (a covered call). Needs IB's permission to sell options and margin."
        case (false, .put):
            return "Selling a put: you're paid now and keep it all if \(u) ends above the strike. Below it you may have to buy 100 shares a "
                + "contract at the strike, so keep that much cash (a cash-secured put). Below the breakeven you lose."
        }
    }
}

private struct SimpleRow: View {
    let desk: OptionsDesk
    let contract: OptionContract
    let spot: Double?
    @Environment(Broker.self) private var broker
    @Environment(\.sideColors) private var sides

    static let widths: [CGFloat] = [72, 64, 92, 84, 96, 76, 120, 64, 70]

    static func header(buy: Bool) -> some View {
        HStack(spacing: 0) {
            Heading(text: "Strike", width: widths[0], alignment: .leading, help: "The price the option lets you buy (call) or sell (put) the shares at")
            Heading(text: "Price", width: widths[1], help: "The option's price per share, the middle of its bid and ask. A contract is 100 shares")
            Heading(text: buy ? "Cost" : "You get", width: widths[2], help: buy ? "What one contract costs: the price × 100. The most you can lose" : "What you're paid for one contract: the price × 100. The most you can make")
            Heading(text: "Breakeven", width: widths[3], help: "Where the stock must end at expiry for the trade to neither gain nor lose")
            Heading(text: buy ? "To breakeven" : "Cushion", width: widths[4], help: buy ? "How far the stock must move from here to reach the breakeven by expiry" : "How far the stock can move against you before you lose")
            Heading(text: "Chance ITM", width: widths[5], help: "The chance it ends in the money (past the strike), from its delta")
            Heading(text: "Chance of profit", width: widths[6], help: "The chance the trade ends with a gain at expiry, from the options' implied volatility. An estimate, not a promise")
            Heading(text: "Volume", width: widths[7], help: "Contracts traded today")
            Heading(text: "Open int.", width: widths[8], help: "Contracts open. Busy options (high volume and open interest) have tighter bid–ask spreads")
        }
    }

    var body: some View {
        let q = broker.quote(contract.symbol)
        let mid = q?.optionMark
        let buy = desk.simpleBuy
        let isCall = contract.right == .call
        let vol = OptionsDesk.vol(contract, broker: broker)
        let years = OptionContract.years(contract.expiry)
        let breakeven = mid.map { isCall ? contract.strike + $0 : contract.strike - $0 }
        let move = breakeven.flatMap { be in spot.map { (be - $0) / $0 * 100 } }
        let itm = q?.greeks?.delta.map(abs) ?? spot.map { s in
            let above = OptionMath.chanceAbove(contract.strike, spot: s, years: years, vol: vol)
            return isCall ? above : 1 - above
        }
        let above = breakeven.flatMap { be in spot.map { OptionMath.chanceAbove(be, spot: $0, years: years, vol: vol) } }
        let profit = above.map { (isCall == buy) ? $0 : 1 - $0 }
        let selected = desk.legs.count == 1 && desk.legs[0].contract == contract && desk.legs[0].buy == buy
        let inTheMoney = spot.map { contract.isInTheMoney(at: $0) } ?? false
        HStack(spacing: 0) {
            Cell(text: OptionContract.strikeText(contract.strike), width: Self.widths[0], alignment: .leading, weight: .semibold)
            Cell(text: Fmt.price(mid), width: Self.widths[1])
            Cell(text: Fmt.money(mid.map { $0 * OptionContract.multiplier }), width: Self.widths[2], color: buy ? .primary : sides.up)
            Cell(text: Fmt.price(breakeven), width: Self.widths[3])
            Cell(text: move.map { Fmt.percent($0) } ?? "—", width: Self.widths[4], color: .secondary)
            Cell(text: chance(itm), width: Self.widths[5], color: .secondary)
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.08))
                        Capsule().fill((profit ?? 0) >= 0.5 ? sides.up.opacity(0.8) : sides.down.opacity(0.7))
                            .frame(width: geo.size.width * (profit ?? 0))
                    }
                }
                .frame(width: 50, height: 5)
                Text(chance(profit)).font(.system(size: 12, weight: .medium).monospacedDigit()).frame(width: 40, alignment: .trailing)
            }
            .frame(width: Self.widths[6])
            Cell(text: count(q?.volume), width: Self.widths[7], color: .secondary)
            Cell(text: count(q?.openInterest), width: Self.widths[8], color: .secondary)
        }
        .padding(.vertical, 4)
        .background(selected ? Color.accentColor.opacity(0.3) : inTheMoney ? Color.primary.opacity(0.05) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            desk.legs = [OptionLeg(contract: contract, buy: buy)]
        }
        .help("\(buy ? "Buy" : "Sell") the \(contract.display)\(inTheMoney ? ", in the money" : ""): click to put it in the ticket")
    }
}

// MARK: - Chain

/// The classic chain: calls left, puts right, the strike between, in the money shaded; a click on an ask buys, on a
/// bid sells (up to 4 legs in the ticket, as one order).
struct OptionsChainLayout: View {
    let desk: OptionsDesk
    let book: OptionBook
    let spot: Double?

    static let side: [(title: String, width: CGFloat, help: String)] = [
        ("Open int.", 60, "Contracts open"),
        ("Volume", 56, "Contracts traded today"),
        ("IV %", 52, "Implied volatility: the yearly move the option's price implies. Higher: a dearer option"),
        ("Delta", 52, "How much the option moves for $1 in the stock; also about the chance it ends in the money"),
        ("Bid", 58, "What buyers pay: a click sells at about here"),
        ("Ask", 58, "What sellers ask: a click buys at about here"),
    ]
    static let strikeWidth: CGFloat = 74

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("CALLS").frame(maxWidth: .infinity)
                Color.clear.frame(width: Self.strikeWidth, height: 1)
                Text("PUTS").frame(maxWidth: .infinity)
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: Self.totalWidth)
            .padding(.bottom, 4)
            HStack(spacing: 0) {
                ForEach(Self.side.indices, id: \.self) { i in Heading(text: Self.side[i].title, width: Self.side[i].width, help: Self.side[i].help) }
                Heading(text: "Strike", width: Self.strikeWidth, alignment: .center, help: "The price the option lets you buy (call) or sell (put) at")
                ForEach(Self.side.indices.reversed(), id: \.self) { i in Heading(text: Self.side[i].title, width: Self.side[i].width, help: Self.side[i].help) }
            }
            .frame(width: Self.totalWidth)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(StrikeItem.items(book.visible(spot: spot, each: desk.strikesEachSide), spot: spot)) { item in
                        switch item {
                        case .spot: if let spot { SpotLine(underlying: desk.underlying, spot: spot) }
                        case .strike(let k):
                            ChainRow(desk: desk, strike: k, call: book.contract(k, .call), put: book.contract(k, .put), spot: spot)
                        }
                    }
                }
                .frame(width: Self.totalWidth)
            }
            Text("Click an ask to buy, a bid to sell; again to take it out. Up to 4 legs go to IB as one order. Shaded: in the money.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .padding(.top, 6)
        }
        .padding(12)
    }

    static var totalWidth: CGFloat { side.map(\.width).reduce(0, +) * 2 + strikeWidth }
}

private struct ChainRow: View {
    let desk: OptionsDesk
    let strike: Double
    let call: OptionContract?
    let put: OptionContract?
    let spot: Double?

    var body: some View {
        HStack(spacing: 0) {
            ChainSide(desk: desk, contract: call, spot: spot, mirrored: false)
            Text(OptionContract.strikeText(strike))
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .frame(width: OptionsChainLayout.strikeWidth)
                .padding(.vertical, 4)
                .background(Color.primary.opacity(0.07))
            ChainSide(desk: desk, contract: put, spot: spot, mirrored: true)
        }
    }
}

private struct ChainSide: View {
    let desk: OptionsDesk
    let contract: OptionContract?
    let spot: Double?
    /// The puts' side: bid and ask next to the strike, as the calls' are.
    let mirrored: Bool
    @Environment(Broker.self) private var broker
    @Environment(\.sideColors) private var sides

    var body: some View {
        let widths = OptionsChainLayout.side.map(\.width)
        let q = contract.flatMap { broker.quote($0.symbol) }
        let cells: [AnyView] = [
            AnyView(Cell(text: count(q?.openInterest), width: widths[0], color: .secondary)),
            AnyView(Cell(text: count(q?.volume), width: widths[1], color: .secondary)),
            AnyView(Cell(text: ivText(q?.greeks?.impliedVol), width: widths[2], color: .secondary)),
            AnyView(Cell(text: q?.greeks?.delta.map { $0.formatted(.number.precision(.fractionLength(2))) } ?? "—", width: widths[3])),
            AnyView(price(q?.bid, buy: false, width: widths[4])),
            AnyView(price(q?.ask, buy: true, width: widths[5])),
        ]
        let inTheMoney = contract.flatMap { c in spot.map { c.isInTheMoney(at: $0) } } ?? false
        HStack(spacing: 0) {
            ForEach(mirrored ? Array(cells.indices.reversed()) : Array(cells.indices), id: \.self) { cells[$0] }
        }
        .padding(.vertical, 4)
        .background(inTheMoney ? Color.primary.opacity(0.06) : Color.clear)
    }

    private func price(_ value: Double?, buy: Bool, width: CGFloat) -> some View {
        let inTicket = contract.map { c in desk.legs.contains { $0.contract == c && $0.buy == buy } } ?? false
        return Text(Fmt.price(value))
            .font(.system(size: 12, weight: inTicket ? .bold : .regular).monospacedDigit())
            .foregroundStyle(inTicket ? Color.white : sides.of(buy).opacity(0.95))
            .frame(width: width - 6, alignment: .trailing)
            .padding(.trailing, 3)
            .background(RoundedRectangle(cornerRadius: 3).fill(inTicket ? sides.of(buy).opacity(0.75) : Color.clear))
            .frame(width: width, alignment: .trailing)
            .contentShape(Rectangle())
            .onTapGesture {
                guard let contract else { return }
                desk.toggleLeg(contract, buy: buy)
            }
            .help(contract.map { "\(buy ? "Buy" : "Sell") the \($0.display)" } ?? "")
    }
}

// MARK: - Strategy

/// A strategy for what you expect: the cards by outlook, the legs it builds around the price, its P/L chart.
struct OptionsStrategyLayout: View {
    @Bindable var desk: OptionsDesk
    let book: OptionBook
    let spot: Double?
    @Environment(Broker.self) private var broker

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(OptionStrategy.Outlook.allCases) { outlook in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(outlook.rawValue.uppercased()).font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                            Text(outlook.blurb).font(.system(size: 10)).foregroundStyle(.tertiary)
                            ForEach(OptionStrategy.allCases.filter { $0.outlook == outlook }) { strategy in card(strategy) }
                        }
                    }
                }
                .padding(10)
            }
            .frame(width: 230)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(desk.strategy.name).font(.system(size: 16, weight: .semibold))
                    Text(desk.strategy.blurb).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                controls
                if let payoff = desk.payoff(broker), let spot {
                    PayoffChart(payoff: payoff, spot: spot, vol: desk.averageVol(broker))
                        .frame(minHeight: 240, maxHeight: .infinity)
                } else {
                    Text(book.isLoaded ? desk.whyNoPayoff(broker, spot: spot) : "Loading the options…")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, minHeight: 240, maxHeight: .infinity)
                }
                OptionLegList(desk: desk, book: book)
            }
            .padding(12)
        }
        .onAppear { if desk.legs.isEmpty { desk.buildStrategy(book: book, spot: spot) } }
        .onChange(of: "\(desk.strategy.rawValue)|\(desk.width)|\(desk.shift)|\(desk.expiry ?? "")|\(book.isLoaded)") {
            desk.buildStrategy(book: book, spot: spot)
        }
    }

    private func card(_ strategy: OptionStrategy) -> some View {
        let selected = desk.strategy == strategy
        return Button {
            if selected { desk.buildStrategy(book: book, spot: spot) } else { desk.strategy = strategy }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(strategy.name).font(.system(size: 12, weight: .semibold))
                Text(strategy.risk).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor.opacity(0.4) : Color.primary.opacity(0.05)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(strategy.blurb)
    }

    private var controls: some View {
        HStack(spacing: 14) {
            if desk.strategy.hasWidth {
                Picker("Width", selection: $desk.width) {
                    ForEach(1...6, id: \.self) { Text("\($0)").tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .help("Strikes between the legs: wider costs (or risks) more and can gain more")
            }
            HStack(spacing: 4) {
                Text("Middle").font(.system(size: 11)).foregroundStyle(.secondary)
                Button { desk.shift -= 1 } label: { Image(systemName: "chevron.left") }
                Text(middleStrike).font(.system(size: 12, weight: .medium).monospacedDigit()).frame(minWidth: 52)
                Button { desk.shift += 1 } label: { Image(systemName: "chevron.right") }
                if desk.shift != 0 {
                    Button("At the price") { desk.shift = 0 }.controlSize(.small)
                }
            }
            .buttonStyle(.borderless)
            .help("Moves every leg up or down a strike: further from the price is cheaper and less likely to pay")
            Spacer()
            Button("Rebuild") { desk.buildStrategy(book: book, spot: spot) }
                .controlSize(.small)
                .help("Builds the legs again around the price as it is now")
        }
    }

    private var middleStrike: String {
        guard let c = book.centerIndex(spot: spot) else { return "—" }
        return OptionContract.strikeText(book.strikes[min(max(c + desk.shift, 0), book.strikes.count - 1)])
    }
}

/// The ticket's legs, each bought or sold (a click switches), its strike moved with the arrows, or taken out.
struct OptionLegList: View {
    @Bindable var desk: OptionsDesk
    let book: OptionBook
    @Environment(Broker.self) private var broker
    @Environment(\.sideColors) private var sides

    var body: some View {
        VStack(spacing: 4) {
            ForEach($desk.legs) { $leg in
                HStack(spacing: 8) {
                    Button { leg.buy.toggle() } label: {
                        Text(leg.buy ? "BUY" : "SELL")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 38)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(sides.of(leg.buy).opacity(0.8)))
                    }
                    .buttonStyle(.plain)
                    .help("Click to \(leg.buy ? "sell" : "buy") it instead")
                    if leg.ratio != 1 { Text("\(leg.ratio)×").font(.system(size: 11).monospacedDigit()) }
                    Text(leg.contract.short).font(.system(size: 12, weight: .medium).monospacedDigit())
                    if leg.contract.expiry == book.expiry {
                        Button { move(&leg, by: -1) } label: { Image(systemName: "chevron.left") }.buttonStyle(.borderless)
                        Button { move(&leg, by: 1) } label: { Image(systemName: "chevron.right") }.buttonStyle(.borderless)
                    }
                    Spacer()
                    Text(Fmt.price(broker.quote(leg.contract.symbol)?.optionMark)).font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                    Button { desk.legs.removeAll { $0.id == leg.id } } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .help("Take this leg out")
                }
                .help(leg.contract.display)
            }
        }
    }

    /// The leg's strike, `by` strikes up or down.
    private func move(_ leg: inout OptionLeg, by step: Int) {
        guard let i = book.strikes.firstIndex(of: leg.contract.strike) else { return }
        let j = i + step
        guard book.strikes.indices.contains(j), let c = book.contract(book.strikes[j], leg.contract.right),
              !desk.legs.contains(where: { $0.contract == c }) else { return NSSound.beep() }
        leg.contract = c
    }
}

// MARK: - Positions

/// The option positions: P/L, Greeks, days left, closing; the window's underlying's on a risk chart; working orders.
struct OptionsPositionsLayout: View {
    let desk: OptionsDesk
    let spot: Double?
    @Environment(Broker.self) private var broker
    @Environment(\.sideColors) private var sides

    static let widths: [CGFloat] = [190, 50, 64, 64, 96, 64, 48, 76, 76, 56, 120]

    struct Item: Identifiable {
        var contract: OptionContract
        var position: Position
        /// A what-if trade (SIM), not a real position.
        var sim: Bool
        var id: String { (sim ? "sim " : "") + position.symbol }
    }

    var body: some View {
        let real = broker.optionPositions.values.compactMap { p in OptionContract(p.symbol).map { Item(contract: $0, position: p, sim: false) } }
        let sims = broker.simPositions.values.compactMap { s in
            OptionContract(s.symbol).map { Item(contract: $0, position: Position(symbol: s.symbol, quantity: s.quantity, avgCost: s.avgCost), sim: true) }
        }
        let positions = (real + sims)
            .sorted { ($0.contract.underlying, $0.contract.expiry, $0.contract.strike) < ($1.contract.underlying, $1.contract.expiry, $1.contract.strike) }
        VStack(alignment: .leading, spacing: 8) {
            if positions.isEmpty {
                Text("No option positions or what-if trades. Open one from Simple, Chain or Strategy; it shows here with its profit and loss, Greeks and a risk chart.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                header
                Divider()
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(positions) { item in
                            PositionRow(desk: desk, contract: item.contract, position: item.position, isSim: item.sim)
                        }
                    }
                }
                .frame(maxHeight: 260)
                Divider()
                riskChart(positions.filter { $0.contract.underlying == desk.underlying })
            }
            OptionOrdersList(underlying: nil)
            Spacer(minLength: 0)
        }
        .padding(12)
    }

    private var header: some View {
        let w = Self.widths
        return HStack(spacing: 0) {
            Heading(text: "Option", width: w[0], alignment: .leading)
            Heading(text: "Qty", width: w[1], help: "Contracts: bought positive, sold negative")
            Heading(text: "Avg", width: w[2], help: "What you paid (or got) a share on average")
            Heading(text: "Mark", width: w[3], help: "Its price now, the middle of its bid and ask")
            Heading(text: "P/L", width: w[4], help: "Profit or loss at the mark, in dollars")
            Heading(text: "P/L %", width: w[5])
            Heading(text: "Days", width: w[6], help: "Days to expiry")
            Heading(text: "Delta", width: w[7], help: "Moves like this many shares of the stock")
            Heading(text: "Theta/day", width: w[8], help: "What a day passing makes or costs, in dollars, the rest the same")
            Heading(text: "IV %", width: w[9], help: "Implied volatility")
            Heading(text: "", width: w[10])
        }
    }

    @ViewBuilder
    private func riskChart(_ positions: [Item]) -> some View {
        if !positions.isEmpty, let spot {
            let payoff = OptionPayoff(
                legs: positions.map { .init(contract: $0.contract, contracts: $0.position.quantity, vol: OptionsDesk.vol($0.contract, broker: broker)) },
                cost: positions.reduce(0) { $0 + $1.position.quantity * $1.position.avgCost * OptionContract.multiplier })
            let vol = positions.map { OptionsDesk.vol($0.contract, broker: broker) }.reduce(0, +) / Double(positions.count)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(desk.underlying) positions together\(positions.contains { $0.sim } ? ", what-if trades included" : ""), against its price").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                PayoffChart(payoff: payoff, spot: spot, vol: vol).frame(minHeight: 200, maxHeight: 320)
            }
        } else if !broker.optionPositions.isEmpty || broker.simPositions.keys.contains(where: OptionContract.isOption) {
            Text("No \(desk.underlying) option positions: click a position's Show for its risk chart.").font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

private struct PositionRow: View {
    let desk: OptionsDesk
    let contract: OptionContract
    let position: Position
    var isSim = false
    @Environment(Broker.self) private var broker
    @Environment(\.sideColors) private var sides

    /// The what-if trades' pink (as under Positions in the main window).
    private static let simColor = Color(red: 1, green: 0.45, blue: 0.75)

    var body: some View {
        let w = OptionsPositionsLayout.widths
        let q = broker.quote(contract.symbol)
        let mark = q?.optionMark
        let qty = position.quantity
        let pnl = mark.map { ($0 - position.avgCost) * qty * OptionContract.multiplier }
        let pnlPercent = mark.flatMap { m in position.avgCost > 0 ? (m - position.avgCost) / position.avgCost * 100 * (qty > 0 ? 1 : -1) : nil }
        let days = OptionContract.daysLeft(contract.expiry)
        HStack(spacing: 0) {
            Cell(text: (isSim ? "SIM " : "") + contract.display, width: w[0], alignment: .leading,
                 color: isSim ? Self.simColor : .primary, weight: contract.underlying == desk.underlying ? .semibold : .regular)
            Cell(text: Fmt.shares(qty), width: w[1], color: sides.of(qty > 0))
            Cell(text: Fmt.price(position.avgCost), width: w[2])
            Cell(text: Fmt.price(mark), width: w[3])
            Cell(text: Fmt.money(pnl, signed: true), width: w[4], color: pnl.map { sides.of($0 >= 0) } ?? .secondary, weight: .medium)
            Cell(text: Fmt.percent(pnlPercent), width: w[5], color: .secondary)
            Cell(text: "\(days)", width: w[6], color: days <= 7 ? .orange : .secondary)
            Cell(text: q?.greeks?.delta.map { Fmt.shares(($0 * qty * OptionContract.multiplier).rounded()) } ?? "—", width: w[7])
            Cell(text: q?.greeks?.theta.map { Fmt.money($0 * qty * OptionContract.multiplier, signed: true) } ?? "—", width: w[8], color: .secondary)
            Cell(text: ivText(q?.greeks?.impliedVol), width: w[9], color: .secondary)
            HStack(spacing: 6) {
                Button("Show") {
                    desk.underlying = contract.underlying
                    desk.expiry = contract.expiry
                }
                .help("Show \(contract.underlying)'s options, at this expiry, and its positions' risk chart")
                if isSim {
                    Button("Close") { broker.closeSimOption(contract.symbol) }
                        .help("Closes the what-if trade at the mid, simulated")
                } else {
                    Button("Close…") {
                        desk.underlying = contract.underlying
                        desk.expiry = contract.expiry
                        desk.legs = [OptionLeg(contract: contract, buy: qty < 0)]
                        desk.quantity = Int(abs(qty))
                    }
                    .help("Puts the order closing it in the ticket (\(qty < 0 ? "buy" : "sell") \(Fmt.shares(abs(qty))) at the mid), to review and send")
                }
            }
            .controlSize(.small)
            .frame(width: w[10], alignment: .trailing)
        }
        .padding(.vertical, 4)
    }
}

/// Working option and combo orders (the underlying's, or all), each with Cancel.
struct OptionOrdersList: View {
    let underlying: String?
    @Environment(Broker.self) private var broker
    @Environment(\.sideColors) private var sides

    var body: some View {
        let orders = broker.orders.values.filter { o in
            guard o.isActive else { return false }
            let und = OptionContract(o.symbol)?.underlying ?? OptionCombo.underlying(of: o.symbol)
            return und != nil && (underlying == nil || und == underlying)
        }
        .sorted { $0.id > $1.id }
        if !orders.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("WORKING ORDERS").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                ForEach(orders) { o in
                    HStack(spacing: 6) {
                        Text(o.action).font(.system(size: 10, weight: .bold)).foregroundStyle(sides.of(o.action == "BUY"))
                        Text(Fmt.shares(o.quantity)).font(.system(size: 11).monospacedDigit())
                        Text(OptionContract(o.symbol)?.display ?? o.symbol).font(.system(size: 11)).lineLimit(1)
                        Text(o.limitPrice.map { "@ \(Fmt.price($0))" } ?? o.orderType).font(.system(size: 11).monospacedDigit())
                        Text(o.filled > 0 ? "\(o.status) \(Fmt.shares(o.filled))/\(Fmt.shares(o.quantity))" : o.status)
                            .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 4)
                        Button("Cancel") { broker.cancelOrder(o.id, why: "Options window") }
                            .controlSize(.small)
                    }
                }
            }
        }
    }
}
