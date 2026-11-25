//
//  OptionsTicket.swift
//  TWZ
//
//  The Options window's order ticket: the legs, how many, the limit (following the mid until set by hand), what it
//  can make and lose, its breakevens and chance of profit, said in plain words; Review shows it all once more, frozen
//  at its price, before it goes to IB. And the P/L chart the window draws for the ticket, a strategy and positions.
//

import SwiftUI

extension OptionsDesk {
    /// The legs as a combo order's, by IB's contract ids; nil while one isn't known (its expiry not loaded).
    func comboLegs(_ broker: Broker) -> [ComboLegSpec]? {
        var specs: [ComboLegSpec] = []
        for leg in reducedLegs {
            guard let listed = broker.listedOptions(leg.contract.underlying, expiry: leg.contract.expiry)?
                .first(where: { $0.contract == leg.contract }) else { return nil }
            specs.append(ComboLegSpec(conId: listed.conId, ratio: leg.ratio, action: leg.buy ? "BUY" : "SELL"))
        }
        return specs
    }

    /// Net delta in shares and theta in dollars a day for the whole order; nil until IB's model has them for each leg.
    func netGreeks(_ broker: Broker) -> (delta: Double, theta: Double)? {
        var delta = 0.0, theta = 0.0
        for leg in reducedLegs {
            guard let g = broker.quote(leg.contract.symbol)?.greeks, let d = g.delta, let t = g.theta else { return nil }
            let n = Double((leg.buy ? 1 : -1) * leg.ratio * quantity) * OptionContract.multiplier
            delta += d * n
            theta += t * n
        }
        return (delta, theta)
    }

    /// The order in a sentence.
    func plainWords(summary: OptionPayoff.Summary, price: Double) -> String {
        let total = Fmt.money(abs(price) * OptionContract.multiplier * Double(quantity))
        let pays = price >= 0 ? "You pay \(total) now." : "You're paid \(total) now."
        let expiry = legs.map(\.contract.expiry).min().map(OptionContract.expiryLabel) ?? ""
        let gain = summary.maxProfit.map { "at most \(Fmt.money($0))" } ?? "with no limit"
        let loss = summary.maxLoss.map { "at most \(Fmt.money(abs($0)))" } ?? "with no limit"
        let ends: String
        switch summary.breakevens.count {
        case 0: ends = ""
        case 1:
            let up = (summary.maxProfit ?? .infinity) > 0 && payoffRisesAbove(summary.breakevens[0])
            ends = " You gain if \(underlying) ends \(expiry) \(up ? "above" : "below") \(Fmt.price(summary.breakevens[0]))."
        default:
            let inside = !payoffRisesAbove(summary.breakevens.last!)
            ends = " You gain if \(underlying) ends \(expiry) \(inside ? "between" : "outside") \(summary.breakevens.map { Fmt.price($0) }.joined(separator: " and "))."
        }
        return pays + ends + " You can gain \(gain) and lose \(loss)."
    }

    /// Gains above `price` at expiry (or loses), going by its legs.
    private func payoffRisesAbove(_ price: Double) -> Bool {
        let units = reducedLegs.map { leg -> (OptionContract, Double) in (leg.contract, leg.buy ? 1 : -1) }
        let at = { (s: Double) in units.reduce(0.0) { $0 + $1.1 * $1.0.intrinsic(at: s) } }
        return at(price * 1.01) > at(price * 0.99)
    }
}

struct OptionsTicket: View {
    @Bindable var desk: OptionsDesk
    let book: OptionBook
    let spot: Double?
    @Environment(Broker.self) private var broker
    @Environment(Workspace.self) private var workspace
    @Environment(\.sideColors) private var sides

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("ORDER TICKET").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                    OptionsModeBadge()
                    Spacer()
                    if !desk.legs.isEmpty {
                        Button("Clear") { desk.legs = [] }.buttonStyle(.borderless).controlSize(.small)
                    }
                }
                if desk.legs.isEmpty {
                    Text(hint).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    OptionLegList(desk: desk, book: book)
                    Divider()
                    quantity
                    price
                    Divider()
                    numbers
                    warnings
                    Button {
                        desk.reviewing = true
                    } label: {
                        Text(workspace.optionOrdersReal ? "Review order…" : "Review what-if trade…").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!canReview)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Shows the order once more, its price frozen, before it goes to IB (⌘↩)")
                }
                OptionOrdersList(underlying: desk.underlying)
            }
            .padding(12)
        }
    }

    private var hint: String {
        switch desk.layout {
        case .simple: "Pick Buy or Sell, Calls or Puts, then a strike: it comes here, with what it costs and can make or lose."
        case .chain: "Click an ask to buy or a bid to sell. Several legs (a spread, say) go to IB as one order."
        case .strategy: "Pick a strategy on the left: its legs come here."
        case .positions: "A position's Close… puts the order closing it here."
        }
    }

    private var canReview: Bool {
        broker.state == .connected && desk.price(broker).map { $0 != 0 } == true
            && (!desk.isCombo || !workspace.optionOrdersReal || desk.comboLegs(broker) != nil)
    }

    private var quantity: some View {
        Stepper(value: $desk.quantity, in: 1...500) {
            HStack(spacing: 4) {
                Text("\(desk.quantity)").font(.system(size: 13, weight: .semibold).monospacedDigit())
                Text(desk.isCombo ? (desk.quantity == 1 ? "combo" : "combos") : (desk.quantity == 1 ? "contract" : "contracts"))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Text("(\(desk.quantity * 100) shares\(desk.isCombo ? " a leg" : ""))").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
        .help("A contract is 100 shares: its price × 100 is what it costs")
    }

    private var price: some View {
        let mid = desk.netMid(broker)
        let natural = desk.netNatural(broker)
        let current = desk.price(broker)
        let credit = (current ?? mid ?? 1) < 0
        let step = desk.isCombo ? 0.01 : OptionContract.tick(for: abs(current ?? 0))
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Limit").font(.system(size: 12)).foregroundStyle(.secondary)
                Button { nudge(-step, current: current, credit: credit) } label: { Image(systemName: "minus") }
                TextField("", value: Binding(
                    get: { abs(current ?? 0) },
                    set: { desk.limit = (credit ? -1 : 1) * max(0.01, abs($0)) }
                ), format: .number.precision(.fractionLength(2)))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .frame(width: 70)
                Button { nudge(step, current: current, credit: credit) } label: { Image(systemName: "plus") }
                Text(credit ? "credit" : "debit").font(.system(size: 11)).foregroundStyle(credit ? sides.up : .secondary)
                Spacer()
            }
            .buttonStyle(.borderless)
            HStack(spacing: 6) {
                Button("Mid \(mid.map { Fmt.price(abs($0)) } ?? "—")") { desk.limit = nil }
                    .help("The middle of the bid and ask, following them: the usual place to start")
                Button("Natural \(natural.map { Fmt.price(abs($0)) } ?? "—")") {
                    if let natural { desk.limit = desk.isCombo ? (natural * 100).rounded() / 100 : natural }
                }
                .help("Buying at the ask and selling at the bid: fills at once, but costs the whole spread")
                .disabled(natural == nil)
            }
            .controlSize(.small)
            if let current {
                let total = abs(current) * OptionContract.multiplier * Double(desk.quantity)
                Text(current >= 0 ? "You pay \(Fmt.money(total))" : "You receive \(Fmt.money(total))")
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(current >= 0 ? Color.primary : sides.up)
            }
        }
    }

    private func nudge(_ step: Double, current: Double?, credit: Bool) {
        guard let current else { return }
        let next = max(0.01, abs(current) + step)
        desk.limit = (credit ? -1 : 1) * (next * 100).rounded() / 100
    }

    @ViewBuilder private var numbers: some View {
        if let payoff = desk.payoff(broker), let spot, let price = desk.price(broker) {
            let summary = payoff.summary(spot: spot, vol: desk.averageVol(broker))
            VStack(alignment: .leading, spacing: 6) {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    row("Max profit", summary.maxProfit.map { Fmt.money($0) } ?? "No limit", color: sides.up)
                    row("Max loss", summary.maxLoss.map { Fmt.money($0) } ?? "No limit", color: sides.down)
                    row("Breakeven", summary.breakevens.isEmpty ? "—" : summary.breakevens.map { Fmt.price($0) }.joined(separator: ", "))
                    row("Chance of profit", summary.chanceOfProfit.map { ($0 * 100).formatted(.number.precision(.fractionLength(0))) + "%" } ?? "—")
                    if let g = desk.netGreeks(broker) {
                        row("Moves like", "\(Fmt.shares(g.delta.rounded())) shares")
                        row("A day passing", Fmt.money(g.theta, signed: true), color: g.theta >= 0 ? sides.up : sides.down)
                    }
                }
                .help("At expiry, at this price. Chance of profit: from the options' implied volatility, an estimate. "
                      + "Moves like: the delta, how many shares of the stock it moves like now. A day passing: theta, what a day costs or makes, the rest the same")
                Text(desk.plainWords(summary: summary, price: price))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if desk.layout != .strategy {
                    PayoffChart(payoff: payoff, spot: spot, vol: desk.averageVol(broker), compact: true)
                        .frame(height: 150)
                }
            }
        } else {
            Text("Waiting for the options' prices…").font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private func row(_ title: String, _ value: String, color: Color = .primary) -> some View {
        GridRow {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 12, weight: .medium).monospacedDigit()).foregroundStyle(color)
        }
    }

    @ViewBuilder private var warnings: some View {
        let notes = Self.warnings(desk: desk, broker: broker, spot: spot)
        if !notes.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(notes, id: \.self) { note in
                    Label(note, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    static func warnings(desk: OptionsDesk, broker: Broker, spot: Double?) -> [String] {
        var notes: [String] = []
        if let payoff = desk.payoff(broker), let spot, payoff.summary(spot: spot, vol: desk.averageVol(broker)).maxLoss == nil {
            notes.append("No limit to the loss: calls sold without the shares (or bought calls) to cover them. IB needs margin and the permission to sell uncovered options.")
        }
        if desk.legs.count == 1, !desk.legs[0].buy, desk.legs[0].contract.right == .put {
            let cash = desk.legs[0].contract.strike * OptionContract.multiplier * Double(desk.quantity)
            notes.append("Assigned, you buy \(desk.quantity * 100) shares at the strike: keep \(Fmt.money(cash)) for them.")
        }
        if let days = desk.legs.map({ OptionContract.daysLeft($0.contract.expiry) }).min(), days <= 1 {
            notes.append(days == 0 ? "Expires today: prices swing hard and what's left of its time value goes by the close."
                                   : "Expires tomorrow: prices swing hard and its time value is nearly gone.")
        }
        if desk.legs.contains(where: { broker.quote($0.contract.symbol)?.isDelayed == true }) {
            notes.append("Prices delayed 15 minutes (no real-time options data at IB): the mid may be far from where it trades now.")
        }
        for leg in desk.legs {
            if let q = broker.quote(leg.contract.symbol), let bid = q.bid, let ask = q.ask, ask > 0, let mid = q.mid, mid > 0,
               (ask - bid) / mid > 0.15, ask - bid > 0.05 {
                notes.append("Wide bid–ask on the \(leg.contract.short) (\(Fmt.price(bid))–\(Fmt.price(ask))): a limit near the mid saves money, it may take a while to fill.")
            }
        }
        return notes
    }
}

/// The order once more, its price frozen, and Send.
struct OptionsReview: View {
    let desk: OptionsDesk
    let spot: Double?
    @Environment(Broker.self) private var broker
    @Environment(Workspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    @Environment(\.sideColors) private var sides
    @State private var frozen: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(workspace.optionOrdersReal ? "Send this order?" : "Simulate this order?").font(.system(size: 17, weight: .semibold))
                Spacer()
                OptionsModeBadge()
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(desk.reducedLegs) { leg in
                    HStack(spacing: 8) {
                        Text(leg.buy ? "BUY" : "SELL").font(.system(size: 11, weight: .bold)).foregroundStyle(sides.of(leg.buy)).frame(width: 36, alignment: .leading)
                        Text("\(leg.ratio * desk.quantity)").font(.system(size: 12, weight: .semibold).monospacedDigit())
                        Text(leg.contract.display).font(.system(size: 12))
                    }
                }
            }
            Divider()
            if let price = frozen {
                let total = abs(price) * OptionContract.multiplier * Double(desk.quantity)
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                    GridRow {
                        Text("Order").foregroundStyle(.secondary)
                        Text(desk.isCombo ? "One combo order, \(desk.quantity) at \(Fmt.price(abs(price))) \(price < 0 ? "credit" : "debit") each; limit, day"
                                          : "Limit \(Fmt.price(abs(price))) a share, day")
                    }
                    GridRow {
                        Text("Total").foregroundStyle(.secondary)
                        Text(price >= 0 ? "You pay \(Fmt.money(total))" : "You receive \(Fmt.money(total))").fontWeight(.semibold)
                    }
                    if let payoff = payoff(price), let spot {
                        let summary = payoff.summary(spot: spot, vol: desk.averageVol(broker))
                        GridRow {
                            Text("Max loss").foregroundStyle(.secondary)
                            Text(summary.maxLoss.map { Fmt.money($0) } ?? "No limit").foregroundStyle(sides.down)
                        }
                        GridRow {
                            Text("Max profit").foregroundStyle(.secondary)
                            Text(summary.maxProfit.map { Fmt.money($0) } ?? "No limit").foregroundStyle(sides.up)
                        }
                        GridRow {
                            Text("Breakeven").foregroundStyle(.secondary)
                            Text(summary.breakevens.isEmpty ? "—" : summary.breakevens.map { Fmt.price($0) }.joined(separator: ", "))
                        }
                    }
                }
                .font(.system(size: 12).monospacedDigit())
                Text("A limit order: it fills at \(Fmt.price(abs(price))) or better, or not at all; unfilled, it ends at today's close. "
                     + "Options trade 9:30–16:00 New York time. Commissions come on top.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if !workspace.optionOrdersReal {
                Text("SIM: a what-if trade, filled at once at this price and never sent to IB. ⌘🌐 (KEYS ON) for real orders.")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if broker.isLiveAccount {
                Text("This goes to your LIVE account, with real money.").font(.system(size: 12, weight: .semibold)).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(workspace.optionOrdersReal ? "Send to IB" : "Simulate") {
                    send()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(frozen == nil || broker.state != .connected)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { frozen = desk.price(broker) }
    }

    private func payoff(_ price: Double) -> OptionPayoff? {
        guard var payoff = desk.payoff(broker) else { return nil }
        payoff.cost = price * OptionContract.multiplier * Double(desk.quantity)
        return payoff
    }

    private func send() {
        guard let price = frozen else { return }
        guard workspace.optionOrdersReal else {
            if desk.legs.count == 1 {
                let leg = desk.legs[0]
                broker.fillSimOption(leg.contract.symbol, leg.buy ? "BUY" : "SELL", contracts: Double(desk.quantity * leg.ratio), at: abs(price))
            } else {
                broker.fillSimOptionCombo(desk.reducedLegs.map { ($0.contract.symbol, $0.buy, $0.ratio) }, units: Double(desk.quantity), limit: price)
            }
            desk.limit = nil
            return
        }
        if desk.legs.count == 1 {
            let leg = desk.legs[0]
            broker.placeOption(leg.contract.symbol, action: leg.buy ? "BUY" : "SELL", contracts: Double(desk.quantity * leg.ratio), limit: abs(price))
        } else if let legs = desk.comboLegs(broker), let underlying = desk.legs.first?.contract.underlying {
            broker.placeOptionCombo(underlying: underlying, legs: legs, units: Double(desk.quantity), limit: price)
        }
        desk.limit = nil
    }
}

// MARK: - P/L chart

/// Profit and loss against the underlying's price: at the first expiry (solid, gains and losses shaded) and today
/// (dashed, Black-Scholes at the legs' volatility), where the price is now, the breakevens, and the expected move's
/// one standard deviation behind. Hovering reads both at the pointer's price.
struct PayoffChart: View {
    let payoff: OptionPayoff
    let spot: Double
    let vol: Double
    var compact = false
    @State private var hoverX: CGFloat?
    @Environment(\.sideColors) private var sides

    private struct Model {
        var lo: Double, hi: Double, yLo: Double, yHi: Double
        var rect: CGRect
        var xs: [Double], expiry: [Double], now: [Double]
        var move: Double
        var breakevens: [Double]

        func x(_ price: Double) -> CGFloat { rect.minX + CGFloat((price - lo) / (hi - lo)) * rect.width }
        func y(_ pnl: Double) -> CGFloat { rect.maxY - CGFloat((pnl - yLo) / (yHi - yLo)) * rect.height }
        func price(atX x: CGFloat) -> Double { lo + Double((x - rect.minX) / rect.width) * (hi - lo) }
    }

    var body: some View {
        GeometryReader { geo in
            let model = makeModel(geo.size)
            Canvas { context, _ in draw(model, in: &context) }
                .onContinuousHover { phase in
                    if case .active(let p) = phase, model.rect.insetBy(dx: -2, dy: -20).contains(p) { hoverX = p.x } else { hoverX = nil }
                }
                .overlay(alignment: .topTrailing) {
                    if !compact { legend.padding(.trailing, 8) }
                }
        }
    }

    private var legend: some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                Rectangle().fill(Color.primary).frame(width: 14, height: 1.5)
                Text("At expiry \(OptionContract.expiryLabel(payoff.horizon))")
            }
            HStack(spacing: 4) {
                Rectangle().fill(Color.cyan).frame(width: 14, height: 1)
                Text("Today")
            }
            HStack(spacing: 4) {
                Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 14, height: 8)
                Text("Expected move")
            }
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
    }

    private func makeModel(_ size: CGSize) -> Model {
        let years = OptionContract.years(payoff.horizon)
        let move = OptionMath.expectedMove(spot: spot, years: years, vol: vol)
        let strikes = payoff.legs.map(\.contract.strike)
        let minK = min(strikes.min() ?? spot, spot), maxK = max(strikes.max() ?? spot, spot)
        let span = max(2.2 * move, spot * 0.03, (maxK - minK) * 0.6)
        let lo = max(0, minK - span), hi = maxK + span
        let xs = payoff.prices(from: lo, to: hi, count: compact ? 140 : 260)
        let expiry = xs.map(payoff.pnlAtExpiry)
        let now = xs.map(payoff.pnlNow)
        var yLo = min(0, expiry.min() ?? 0, now.min() ?? 0), yHi = max(0, expiry.max() ?? 0, now.max() ?? 0)
        if yHi - yLo < 1 { yLo -= 1; yHi += 1 }
        let pad = (yHi - yLo) * 0.08
        yLo -= pad
        yHi += pad
        let left: CGFloat = compact ? 44 : 58
        let rect = CGRect(x: left, y: compact ? 6 : 22, width: max(10, size.width - left - 8), height: max(10, size.height - (compact ? 6 : 22) - 18))
        let breakevens = payoff.summary(spot: spot, vol: 0).breakevens.filter { $0 > lo && $0 < hi }
        return Model(lo: lo, hi: hi, yLo: yLo, yHi: yHi, rect: rect, xs: xs, expiry: expiry, now: now, move: move, breakevens: breakevens)
    }

    private func draw(_ m: Model, in context: inout GraphicsContext) {
        let r = m.rect
        let labelFont = Font.system(size: 9).monospacedDigit()
        // The expected move's band.
        if m.move > 0 {
            let band = CGRect(x: m.x(spot - m.move), y: r.minY, width: m.x(spot + m.move) - m.x(spot - m.move), height: r.height)
                .intersection(r)
            context.fill(Path(band), with: .color(Color.primary.opacity(0.06)))
        }
        // Grid and labels.
        for v in Self.ticks(m.yLo, m.yHi, count: compact ? 3 : 5) {
            let y = m.y(v)
            context.stroke(Path { $0.move(to: CGPoint(x: r.minX, y: y)); $0.addLine(to: CGPoint(x: r.maxX, y: y)) },
                           with: .color(Color.primary.opacity(0.07)), lineWidth: 1)
            context.draw(Text(Self.money(v)).font(labelFont).foregroundColor(.secondary), at: CGPoint(x: r.minX - 4, y: y), anchor: .trailing)
        }
        for v in Self.ticks(m.lo, m.hi, count: compact ? 4 : 7) {
            let x = m.x(v)
            context.draw(Text(Fmt.price(v)).font(labelFont).foregroundColor(.secondary), at: CGPoint(x: x, y: r.maxY + 3), anchor: .top)
        }
        // Gains and losses at expiry, shaded.
        var area = Path()
        area.move(to: CGPoint(x: m.x(m.xs[0]), y: m.y(0)))
        for (x, v) in zip(m.xs, m.expiry) { area.addLine(to: CGPoint(x: m.x(x), y: m.y(v))) }
        area.addLine(to: CGPoint(x: m.x(m.xs.last!), y: m.y(0)))
        area.closeSubpath()
        context.drawLayer { layer in
            layer.clip(to: Path(CGRect(x: r.minX, y: r.minY, width: r.width, height: m.y(0) - r.minY)))
            layer.fill(area, with: .color(sides.up.opacity(0.22)))
        }
        context.drawLayer { layer in
            layer.clip(to: Path(CGRect(x: r.minX, y: m.y(0), width: r.width, height: r.maxY - m.y(0))))
            layer.fill(area, with: .color(sides.down.opacity(0.22)))
        }
        context.stroke(Path { $0.move(to: CGPoint(x: r.minX, y: m.y(0))); $0.addLine(to: CGPoint(x: r.maxX, y: m.y(0))) },
                       with: .color(Color.primary.opacity(0.35)), lineWidth: 1)
        // Today, then at expiry on top.
        context.stroke(line(m, m.now), with: .color(.cyan), style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
        context.stroke(line(m, m.expiry), with: .color(.primary), lineWidth: 1.6)
        // Breakevens and the price now.
        for be in m.breakevens {
            let x = m.x(be)
            context.stroke(Path { $0.move(to: CGPoint(x: x, y: r.minY)); $0.addLine(to: CGPoint(x: x, y: r.maxY)) },
                           with: .color(Color.primary.opacity(0.4)), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
            if !compact {
                context.draw(Text("BE \(Fmt.price(be))").font(labelFont).foregroundColor(.secondary), at: CGPoint(x: x + 3, y: r.maxY - 3), anchor: .bottomLeading)
            }
        }
        let sx = m.x(spot)
        context.stroke(Path { $0.move(to: CGPoint(x: sx, y: r.minY)); $0.addLine(to: CGPoint(x: sx, y: r.maxY)) },
                       with: .color(Color.yellow.opacity(0.8)), lineWidth: 1)
        context.draw(Text("Now \(Fmt.price(spot))").font(labelFont.weight(.semibold)).foregroundColor(.yellow),
                     at: CGPoint(x: sx + 3, y: r.minY + 1), anchor: .topLeading)
        // The pointer's price.
        if let hoverX, hoverX >= r.minX, hoverX <= r.maxX {
            let price = m.price(atX: hoverX)
            let atExpiry = payoff.pnlAtExpiry(price), today = payoff.pnlNow(price)
            context.stroke(Path { $0.move(to: CGPoint(x: hoverX, y: r.minY)); $0.addLine(to: CGPoint(x: hoverX, y: r.maxY)) },
                           with: .color(Color.primary.opacity(0.5)), lineWidth: 1)
            for (v, c) in [(atExpiry, Color.primary), (today, Color.cyan)] {
                context.fill(Path(ellipseIn: CGRect(x: hoverX - 3, y: m.y(v) - 3, width: 6, height: 6)), with: .color(c))
            }
            let text = Text("\(Fmt.price(price)): ").foregroundColor(.secondary)
                + Text("expiry \(Fmt.money(atExpiry, signed: true))").foregroundColor(atExpiry >= 0 ? sides.up : sides.down)
                + Text("  today \(Fmt.money(today, signed: true))").foregroundColor(.cyan)
            let resolved = context.resolve(text.font(.system(size: 10, weight: .medium).monospacedDigit()))
            let size = resolved.measure(in: CGSize(width: 600, height: 40))
            var box = CGRect(x: hoverX + 8, y: r.minY + 14, width: size.width + 10, height: size.height + 6)
            if box.maxX > r.maxX { box.origin.x = hoverX - 8 - box.width }
            context.fill(Path(roundedRect: box, cornerRadius: 4), with: .color(Color(nsColor: .windowBackgroundColor).opacity(0.92)))
            context.draw(resolved, at: CGPoint(x: box.minX + 5, y: box.midY), anchor: .leading)
        }
    }

    private func line(_ m: Model, _ values: [Double]) -> Path {
        Path { p in
            for (i, (x, v)) in zip(m.xs, values).enumerated() {
                let pt = CGPoint(x: m.x(x), y: m.y(v))
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
        }
    }

    /// Round numbers between `lo` and `hi`, about `count` of them.
    static func ticks(_ lo: Double, _ hi: Double, count: Int) -> [Double] {
        guard hi > lo, count > 0 else { return [] }
        let raw = (hi - lo) / Double(count)
        let magnitude = pow(10, floor(log10(raw)))
        let step = [1.0, 2, 2.5, 5, 10].map { $0 * magnitude }.first { $0 >= raw } ?? raw
        var v = (lo / step).rounded(.up) * step, out: [Double] = []
        while v <= hi { out.append(v); v += step }
        return out
    }

    /// "+$1.2k", "-$350".
    static func money(_ v: Double) -> String {
        let sign = v < 0 ? "-" : v > 0 ? "+" : ""
        let a = abs(v)
        if a >= 1000 { return sign + "$" + (a / 1000).formatted(.number.precision(.fractionLength(a >= 10_000 ? 0 : 1))) + "k" }
        return sign + "$" + a.formatted(.number.precision(.fractionLength(0)))
    }
}
