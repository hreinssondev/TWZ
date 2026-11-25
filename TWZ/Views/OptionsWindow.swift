//
//  OptionsWindow.swift
//  TWZ
//
//  The Options window (⌥⌘O, or Window › Options): options on one underlying, in four layouts switched in its top bar
//  (⌘1–4), with an order ticket beside them.
//  Simple: one call or put to buy or sell, each strike with its cost, breakeven, the move it needs and its chance of
//  profit, said in plain words. Chain: the classic chain, calls left, puts right, a click on a bid sells, on an ask buys.
//  Strategy: what you expect the stock to do, a strategy for it built around the price, its profit and loss chart and
//  odds. Positions: the option positions with their P/L, Greeks and days left, a risk chart, and closing them.
//  The expiries run along the top (the one nearest 30 days out picked at first); the chain shows the strikes around the
//  price, as many each side as the top bar's Strikes says (each strike's call and put take two of IB's market data
//  lines). The window streams nothing once closed.
//  Orders go only from the ticket's Review, a limit for the day; several legs go as one combo order. They follow the main
//  window's mode: with KEYS ON they go to IB; in SIM they're what-if trades, filled at once at their price and never sent
//  to IB. The trading
//  shortcuts (order keys, hotkeys, ⌘⌫ …) don't work with this window in front, so no key sends a stock order from here.
//

import AppKit
import SwiftUI

enum OptionsWindow {
    static let windowID = "options"
    static let windowTitle = "Options"
    static let quoteOwner = "options-window"

    static func isWindow(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        return window.identifier?.rawValue.hasPrefix(windowID) == true || window.title == windowTitle
    }
}

enum OptionsLayout: String, CaseIterable, Identifiable {
    case simple = "Simple", chain = "Chain", strategy = "Strategy", positions = "Positions"

    var id: String { rawValue }

    var number: Int { (Self.allCases.firstIndex(of: self) ?? 0) + 1 }

    var help: String {
        switch self {
        case .simple: "Buy or sell one call or put: each strike's cost, breakeven and chance of profit, in plain words"
        case .chain: "The classic option chain: calls left, puts right, the strike between; a click on a bid sells, on an ask buys"
        case .strategy: "Pick what you expect the stock to do, then a strategy for it: its legs, profit and loss chart and odds"
        case .positions: "Your option positions: profit and loss, Greeks, days left, a risk chart, closing them"
        }
    }
}

/// One option in the ticket, bought or sold, `ratio` of it per unit of the order.
struct OptionLeg: Identifiable, Equatable {
    var id = UUID()
    var contract: OptionContract
    var buy: Bool
    var ratio = 1
}

/// The options listed for the window's expiry, by strike.
struct OptionBook {
    let underlying: String
    let expiry: String?
    let strikes: [Double]
    private let byKey: [String: OptionContract]

    init(underlying: String, expiry: String?, listed: [ListedOption]?) {
        self.underlying = underlying
        self.expiry = expiry
        var byKey: [String: OptionContract] = [:]
        for option in listed ?? [] { byKey[Self.key(option.contract.strike, option.contract.right)] = option.contract }
        self.byKey = byKey
        strikes = Set((listed ?? []).map(\.contract.strike)).sorted()
    }

    var isLoaded: Bool { !strikes.isEmpty }

    private static func key(_ strike: Double, _ right: OptionRight) -> String { "\(strike)\(right.rawValue)" }

    func contract(_ strike: Double, _ right: OptionRight) -> OptionContract? { byKey[Self.key(strike, right)] }

    /// The strike nearest `spot`.
    func centerIndex(spot: Double?) -> Int? {
        guard !strikes.isEmpty else { return nil }
        guard let spot else { return strikes.count / 2 }
        return strikes.indices.min { abs(strikes[$0] - spot) < abs(strikes[$1] - spot) }
    }

    /// `each` strikes either side of the one nearest `spot`, and it.
    func visible(spot: Double?, each: Int) -> [Double] {
        guard let c = centerIndex(spot: spot) else { return [] }
        return Array(strikes[max(0, c - each)...min(strikes.count - 1, c + each)])
    }
}

/// What the Options window shows and the ticket holds. Its underlying, layout, strikes and strategy are kept.
@Observable
final class OptionsDesk {
    private static let defaults = UserDefaults.standard

    var underlying: String {
        didSet {
            guard underlying != oldValue else { return }
            Self.defaults.set(underlying, forKey: "options.underlying")
            expiry = nil
            legs = []
        }
    }
    var expiry: String?
    var layout: OptionsLayout { didSet { Self.defaults.set(layout.rawValue, forKey: "options.layout") } }
    /// Strikes shown each side of the price.
    var strikesEachSide: Int { didSet { Self.defaults.set(strikesEachSide, forKey: "options.strikes") } }
    var legs: [OptionLeg] = [] {
        didSet {
            if legs.map(\.contract) != oldValue.map(\.contract) || legs.map(\.buy) != oldValue.map(\.buy) { limit = nil }
        }
    }
    /// Contracts (one leg) or combos (several) to trade.
    var quantity = 1
    /// The limit a unit set by hand, a debit positive, a credit negative; nil: the legs' mid, as it moves.
    var limit: Double?
    var simpleBuy = true
    var simpleRight: OptionRight = .call
    var strategy: OptionStrategy { didSet { Self.defaults.set(strategy.rawValue, forKey: "options.strategy") } }
    /// Strikes between a strategy's legs, and how many strikes its middle sits from the price.
    var width = 1
    var shift = 0
    var reviewing = false

    static let strikeChoices = [4, 6, 8, 10, 12, 16, 20]

    init() {
        underlying = Self.defaults.string(forKey: "options.underlying") ?? "SPY"
        layout = Self.defaults.string(forKey: "options.layout").flatMap(OptionsLayout.init(rawValue:)) ?? .simple
        let strikes = Self.defaults.integer(forKey: "options.strikes")
        strikesEachSide = strikes > 0 ? strikes : 8
        strategy = Self.defaults.string(forKey: "options.strategy").flatMap(OptionStrategy.init(rawValue:)) ?? .bullCallSpread
    }

    /// The expiry nearest 30 days out (the usual starting point: time enough, little lost to time each day), past today's.
    static func defaultExpiry(_ expirations: [String]) -> String? {
        let ahead = expirations.filter { OptionContract.daysLeft($0) >= 1 }
        return ahead.min { abs(OptionContract.daysLeft($0) - 30) < abs(OptionContract.daysLeft($1) - 30) } ?? expirations.first
    }

    /// A click on a bid (sell) or ask (buy): the leg goes in, or out if it's in already, or flips side.
    func toggleLeg(_ contract: OptionContract, buy: Bool) {
        if let i = legs.firstIndex(where: { $0.contract == contract }) {
            if legs[i].buy == buy { legs.remove(at: i) } else { legs[i].buy = buy }
        } else if legs.count < 4 {
            legs.append(OptionLeg(contract: contract, buy: buy))
        } else {
            NSSound.beep()
        }
    }

    /// The strategy's legs around the strike nearest `spot` (moved `shift` strikes), `width` apart.
    func buildStrategy(book: OptionBook, spot: Double?) {
        guard let center = book.centerIndex(spot: spot) else { return }
        var built: [OptionLeg] = []
        for leg in strategy.shape(width: width) {
            let i = min(max(center + shift + leg.offset, 0), book.strikes.count - 1)
            guard let contract = book.contract(book.strikes[i], leg.right) else { return }
            if built.contains(where: { $0.contract == contract }) { continue }
            built.append(OptionLeg(contract: contract, buy: leg.buy))
        }
        legs = built
        quantity = max(quantity, 1)
    }

    func spot(_ broker: Broker) -> Double? {
        guard let q = broker.quote(underlying) else { return nil }
        return q.last ?? q.mid
    }

    /// Option quotes to stream: the visible strikes' calls and puts (not in Positions), and the ticket's legs.
    func quoteSymbols(book: OptionBook, spot: Double?) -> [String] {
        var symbols: Set<String> = [underlying]
        if layout != .positions {
            for strike in book.visible(spot: spot, each: strikesEachSide) {
                for right in OptionRight.allCases {
                    if let c = book.contract(strike, right) { symbols.insert(c.symbol) }
                }
            }
        }
        for leg in legs { symbols.insert(leg.contract.symbol) }
        return symbols.sorted()
    }

    /// An option's volatility for the math: IB's implied volatility for it, else the underlying's, else 30%.
    static func vol(_ contract: OptionContract, broker: Broker) -> Double {
        broker.quote(contract.symbol)?.greeks?.impliedVol ?? broker.underlyingVols[contract.underlying]?.implied ?? 0.3
    }

    /// The ticket's units: its legs' ratios over their greatest common divisor.
    var reducedLegs: [OptionLeg] {
        let divisor = legs.map(\.ratio).reduce(0) { gcd($0, $1) }
        return divisor > 1 ? legs.map { var l = $0; l.ratio /= divisor; return l } : legs
    }

    private func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }

    /// What a unit of the legs costs at their mids (a credit negative); nil until each has one.
    func netMid(_ broker: Broker) -> Double? {
        var sum = 0.0
        for leg in reducedLegs {
            guard let mid = broker.quote(leg.contract.symbol)?.mid else { return nil }
            sum += (leg.buy ? 1 : -1) * Double(leg.ratio) * mid
        }
        return sum
    }

    /// What a unit costs filled at once: bought at the ask, sold at the bid.
    func netNatural(_ broker: Broker) -> Double? {
        var sum = 0.0
        for leg in reducedLegs {
            let q = broker.quote(leg.contract.symbol)
            guard let price = leg.buy ? q?.ask : q?.bid, price > 0 else { return nil }
            sum += (leg.buy ? 1 : -1) * Double(leg.ratio) * price
        }
        return sum
    }

    var isCombo: Bool { legs.count > 1 }

    /// The order's limit a unit: as set by hand, else the mid, rounded to a price step.
    func price(_ broker: Broker) -> Double? {
        if let limit { return limit }
        guard let mid = netMid(broker) else { return nil }
        return isCombo ? (mid * 100).rounded() / 100 : (mid < 0 ? -1 : 1) * OptionContract.rounded(abs(mid))
    }

    /// The ticket's legs at the order's price, for the P/L chart and the numbers under it.
    func payoff(_ broker: Broker) -> OptionPayoff? {
        guard !legs.isEmpty, let price = price(broker) else { return nil }
        let legs = reducedLegs.map {
            OptionPayoff.Leg(contract: $0.contract, contracts: Double(($0.buy ? 1 : -1) * $0.ratio * quantity),
                             vol: Self.vol($0.contract, broker: broker))
        }
        return OptionPayoff(legs: legs, cost: price * OptionContract.multiplier * Double(quantity))
    }

    /// The legs' volatility together, for the chance of profit: the average of theirs.
    func averageVol(_ broker: Broker) -> Double {
        guard !legs.isEmpty else { return broker.underlyingVols[underlying]?.implied ?? 0.3 }
        return legs.map { Self.vol($0.contract, broker: broker) }.reduce(0, +) / Double(legs.count)
    }
}

struct OptionsView: View {
    @Environment(Broker.self) private var broker
    @State private var desk = OptionsDesk()

    var body: some View {
        let spot = desk.spot(broker)
        let book = OptionBook(underlying: desk.underlying, expiry: desk.expiry,
                              listed: desk.expiry.flatMap { broker.listedOptions(desk.underlying, expiry: $0) })
        VStack(spacing: 0) {
            OptionsHeader(desk: desk, spot: spot)
            Divider()
            ExpiryStrip(desk: desk, book: book, spot: spot)
            Divider()
            OptionsBanner(desk: desk, book: book)
            HStack(spacing: 0) {
                Group {
                    switch desk.layout {
                    case .simple: OptionsSimpleLayout(desk: desk, book: book, spot: spot)
                    case .chain: OptionsChainLayout(desk: desk, book: book, spot: spot)
                    case .strategy: OptionsStrategyLayout(desk: desk, book: book, spot: spot)
                    case .positions: OptionsPositionsLayout(desk: desk, spot: spot)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                Divider()
                OptionsTicket(desk: desk, book: book, spot: spot)
                    .frame(width: 340)
            }
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.35))
        .background(layoutKeys)
        .sheet(isPresented: $desk.reviewing) { OptionsReview(desk: desk, spot: spot) }
        .onChange(of: desk.quoteSymbols(book: book, spot: spot), initial: true) { _, symbols in
            broker.setQuoteSymbols(symbols, owner: OptionsWindow.quoteOwner)
        }
        .onChange(of: "\(desk.underlying)|\(broker.state == .connected)", initial: true) {
            broker.setVolUnderlying(desk.underlying)
            if broker.state == .connected { broker.loadOptionChain(desk.underlying) }
        }
        .onChange(of: broker.optionChains[desk.underlying]?.expirations, initial: true) { _, expirations in
            guard let expirations, !expirations.isEmpty else { return }
            if desk.expiry.map({ !expirations.contains($0) }) ?? true { desk.expiry = OptionsDesk.defaultExpiry(expirations) }
        }
        .onChange(of: "\(desk.underlying)|\(desk.expiry ?? "")|\(broker.state == .connected)", initial: true) {
            if let expiry = desk.expiry, broker.state == .connected { broker.loadOptionSeries(desk.underlying, expiry: expiry) }
        }
        // On close only: nothing streams for the window any more.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
            guard OptionsWindow.isWindow(note.object as? NSWindow) else { return }
            broker.setQuoteSymbols([], owner: OptionsWindow.quoteOwner)
            broker.setVolUnderlying(nil)
        }
    }

    /// ⌘1–4: the layouts.
    private var layoutKeys: some View {
        ZStack {
            ForEach(OptionsLayout.allCases) { layout in
                Button("") { desk.layout = layout }
                    .keyboardShortcut(KeyEquivalent(Character(String(layout.number))), modifiers: .command)
            }
        }
        .opacity(0)
        .allowsHitTesting(false)
    }
}

/// The underlying, its price and volatility, the layouts, how many strikes, and the account.
private struct OptionsHeader: View {
    @Bindable var desk: OptionsDesk
    let spot: Double?
    @Environment(Broker.self) private var broker
    @Environment(\.sideColors) private var sides
    @State private var text = ""
    @FocusState private var typing: Bool

    var body: some View {
        HStack(spacing: 12) {
            TextField("Symbol", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 84)
                .focused($typing)
                .onSubmit {
                    let symbol = text.trimmingCharacters(in: .whitespaces).uppercased()
                    if !symbol.isEmpty { desk.underlying = symbol }
                    text = desk.underlying
                    typing = false
                }
                .onAppear { text = desk.underlying }
                .onChange(of: desk.underlying) { text = desk.underlying }
                .help("The stock or ETF whose options to show (↩)")
            if let spot {
                Text(Fmt.price(spot)).font(.system(size: 15, weight: .semibold).monospacedDigit())
                if let change = broker.quote(desk.underlying)?.changePercent {
                    Text(Fmt.percent(change)).font(.system(size: 12).monospacedDigit()).foregroundStyle(sides.of(change >= 0))
                }
            } else {
                Text("—").foregroundStyle(.secondary)
            }
            volatility
            Spacer(minLength: 8)
            Picker("", selection: $desk.layout) {
                ForEach(OptionsLayout.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help(OptionsLayout.allCases.map { "\($0.rawValue) (⌘\($0.number)): \($0.help)" }.joined(separator: "\n"))
            Spacer(minLength: 8)
            Picker("Strikes", selection: $desk.strikesEachSide) {
                ForEach(OptionsDesk.strikeChoices, id: \.self) { Text("±\($0)").tag($0) }
            }
            .controlSize(.small)
            .fixedSize()
            .help("Strikes shown each side of the price. Each strike's call and put take two of IB's market data lines (100 in all by default, shared with the charts and lists)")
            OptionsModeBadge()
        }
        .padding(.leading, 78)      // the window's buttons
        .padding(.trailing, 12)
        .frame(height: 38)
    }

    @ViewBuilder private var volatility: some View {
        let vol = broker.underlyingVols[desk.underlying]
        if vol?.implied != nil || vol?.historical != nil {
            HStack(spacing: 6) {
                if let iv = vol?.implied {
                    Text("IV \(Self.percent(iv))").foregroundStyle(.primary)
                }
                if let hv = vol?.historical {
                    Text("HV \(Self.percent(hv))").foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 11).monospacedDigit())
            .help("IV, implied volatility: how much the options' prices say the stock will move in a year (30 days out), one standard deviation. "
                  + "HV, historical volatility: how much it did move, over the last 30 days. IV well above HV: options are dear (better to sell); below: cheap (better to buy).")
        }
    }

    static func percent(_ v: Double) -> String { (v * 100).formatted(.number.precision(.fractionLength(1))) + "%" }
}

/// The expiries, days left under each, the monthlies brighter; and how far the price may move by the one picked.
private struct ExpiryStrip: View {
    @Bindable var desk: OptionsDesk
    let book: OptionBook
    let spot: Double?
    @Environment(Broker.self) private var broker

    var body: some View {
        let expirations = broker.optionChains[desk.underlying]?.expirations ?? []
        HStack(spacing: 10) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(expirations, id: \.self) { expiry in chip(expiry).id(expiry) }
                    }
                    .padding(.horizontal, 12)
                }
                .onChange(of: desk.expiry, initial: true) { _, expiry in
                    if let expiry { proxy.scrollTo(expiry, anchor: .center) }
                }
            }
            expectedMove
        }
        .frame(height: 40)
    }

    private func chip(_ expiry: String) -> some View {
        let selected = desk.expiry == expiry
        let monthly = OptionContract.isMonthly(expiry)
        let days = OptionContract.daysLeft(expiry)
        return Button { desk.expiry = expiry } label: {
            VStack(spacing: 0) {
                Text(OptionContract.expiryLabel(expiry)).font(.system(size: 11, weight: selected || monthly ? .semibold : .regular))
                Text(days == 0 ? "today" : "\(days)d").font(.system(size: 9).monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(selected ? Color.accentColor.opacity(0.45) : Color.primary.opacity(monthly ? 0.10 : 0.04)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help((monthly ? "Monthly expiry (the third Friday): the most traded" : "Weekly expiry") + ", \(days) day\(days == 1 ? "" : "s") left. "
              + "Options lose value faster the nearer expiry is; 30–45 days out is the usual starting point")
    }

    /// One standard deviation by the picked expiry, from its at-the-money options' implied volatility.
    @ViewBuilder private var expectedMove: some View {
        if let expiry = desk.expiry, let spot, let vol = atmVol {
            let move = OptionMath.expectedMove(spot: spot, years: OptionContract.years(expiry), vol: vol)
            VStack(alignment: .trailing, spacing: 0) {
                Text("±\(Fmt.price(move))  (±\(OptionsHeader.percent(move / spot)))").font(.system(size: 12, weight: .medium).monospacedDigit())
                Text("expected move by \(OptionContract.expiryLabel(expiry))").font(.system(size: 9)).foregroundStyle(.secondary)
            }
            .padding(.trailing, 12)
            .help("What the options' prices say: about 2 times in 3 the price ends \(OptionContract.expiryLabel(expiry)) within \(Fmt.price(spot - move))–\(Fmt.price(spot + move)) (one standard deviation, at the at-the-money options' implied volatility, \(OptionsHeader.percent(vol)))")
        }
    }

    private var atmVol: Double? {
        guard let i = book.centerIndex(spot: spot) else { return nil }
        let vols = OptionRight.allCases.compactMap { book.contract(book.strikes[i], $0) }
            .compactMap { broker.quote($0.symbol)?.greeks?.impliedVol }
        return vols.isEmpty ? broker.underlyingVols[desk.underlying]?.implied : vols.reduce(0, +) / Double(vols.count)
    }
}

/// Where the window's orders go, as the main window's: SIM (what-if trades, dimmed), or with KEYS ON the account, LIVE
/// in red or PAPER in blue. A click switches, as ⌘🌐 does.
struct OptionsModeBadge: View {
    @Environment(Broker.self) private var broker
    @Environment(Workspace.self) private var workspace

    var body: some View {
        let real = workspace.optionOrdersReal
        Button {
            workspace.orderShortcutsOn.toggle()
            workspace.launchModeChosen = true
            broker.say(workspace.orderShortcutsOn ? "KEYS ON: orders go to IB, for real (⌘🌐: SIM)"
                                                  : "SIM: orders are what-if trades, nothing goes to IB (⌘🌐: KEYS ON)")
        } label: {
            Text(real ? (broker.isLiveAccount ? "LIVE" : "PAPER") : "SIM")
            .font(.system(size: 10, weight: .heavy))
            .foregroundStyle(real ? Color.white : Color.secondary)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(real ? (broker.isLiveAccount ? Color.red.opacity(0.85) : Color.blue.opacity(0.8)) : Color.primary.opacity(0.1)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(real ? "KEYS ON, as in the main window: orders from this window go to your \(broker.isLiveAccount ? "live" : "paper") account, for real. Click or ⌘🌐: SIM"
                   : "SIM, as in the main window: orders from this window are what-if trades, filled at once at their price, never sent to IB. Click or ⌘🌐: KEYS ON")
    }
}

/// Why there's nothing to show: no connection, IB refusing the chain or the quotes, or still loading.
private struct OptionsBanner: View {
    let desk: OptionsDesk
    let book: OptionBook
    @Environment(Broker.self) private var broker

    var body: some View {
        if let text = message {
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(isError ? Color.orange : Color.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(Color.primary.opacity(0.04))
                .textSelection(.enabled)
        }
    }

    private var isError: Bool { broker.state == .connected && (refused != nil || broker.optionErrors[desk.underlying] != nil) }

    private var refused: (symbol: String, reason: String)? {
        broker.unavailableQuotes.first { OptionContract($0.key)?.underlying == desk.underlying }.map { ($0.key, $0.value) }
    }

    private var message: String? {
        if broker.state != .connected { return "Not connected to IB: connect in Settings › Connection" }
        if let error = broker.optionErrors[desk.underlying] { return "\(desk.underlying) options: \(error)" }
        if let refused {
            return "IB sends no quotes for \(OptionContract(refused.symbol)?.display ?? refused.symbol): \(refused.reason) "
                + "(option quotes need IB's US options market data, OPRA)"
        }
        if broker.optionChains[desk.underlying] == nil { return "Loading \(desk.underlying)'s options…" }
        if let expiry = desk.expiry, !book.isLoaded { return "Loading the \(OptionContract.expiryLabel(expiry)) options…" }
        return nil
    }
}
