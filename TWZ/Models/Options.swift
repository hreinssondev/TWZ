//
//  Options.swift
//  TWZ
//
//  Options: a listed option as the app's symbol string (as a forex pair is "EUR.USD", see `OptionContract`), an
//  underlying's chain as IB lists it, the Greeks IB works out, and the math the Options window shows: what a set of
//  options is worth at any underlying price, today (Black-Scholes at each leg's implied volatility) and at expiry,
//  its breakevens, its most profit and loss, and its chance of ending in profit; and the strategy templates.
//

import Foundation

nonisolated enum OptionRight: String, Codable, Sendable, CaseIterable, Hashable {
    case call = "C", put = "P"

    var name: String { self == .call ? "Call" : "Put" }

    /// IB's right field: "C", "CALL", "P" or "PUT".
    init?(ib: String) {
        switch ib.uppercased().first {
        case "C": self = .call
        case "P": self = .put
        default: return nil
        }
    }
}

/// One listed option. Its symbol, by which its quotes, orders, fills and positions go, is the underlying, the expiry
/// day (yyyyMMdd), then the strike and C or P: "AAPL 20260116 200C"; a trading class other than the underlying's own
/// follows ("SPX 20261218 6000C SPXW"). US options on SMART in dollars, 100 shares each.
nonisolated struct OptionContract: Hashable, Sendable {
    var underlying: String
    var expiry: String
    var strike: Double
    var right: OptionRight
    /// Empty when it's the underlying's own.
    var tradingClass: String

    /// Shares per contract: prices are per share, a contract costs 100 times its price.
    static let multiplier = 100.0

    init(underlying: String, expiry: String, strike: Double, right: OptionRight, tradingClass: String = "") {
        self.underlying = underlying
        self.expiry = String(expiry.prefix(8))
        self.strike = strike
        self.right = right
        self.tradingClass = tradingClass == underlying ? "" : tradingClass
    }

    init?(_ symbol: String) {
        guard symbol.contains(" ") else { return nil }
        let parts = symbol.split(separator: " ").map(String.init)
        guard let i = parts.lastIndex(where: { $0.count == 8 && $0.allSatisfy { $0.isASCII && $0.isNumber } }),
              i > 0, i + 1 < parts.count, parts.count <= i + 3,
              let last = parts[i + 1].last, let right = OptionRight(rawValue: String(last)),
              let strike = Double(parts[i + 1].dropLast()), strike > 0 else { return nil }
        self.init(underlying: parts[..<i].joined(separator: " "), expiry: parts[i], strike: strike, right: right,
                  tradingClass: i + 2 < parts.count ? parts[i + 2] : "")
    }

    static func isOption(_ symbol: String) -> Bool { OptionContract(symbol) != nil }

    var symbol: String {
        "\(underlying) \(expiry) \(Self.strikeText(strike))\(right.rawValue)" + (tradingClass.isEmpty ? "" : " \(tradingClass)")
    }

    /// "200", "202.5".
    static func strikeText(_ strike: Double) -> String {
        strike == strike.rounded() ? String(Int(strike)) : String(format: "%g", strike)
    }

    /// "SPY Nov 28 600 Call".
    var display: String { "\(underlying) \(Self.expiryLabel(expiry)) \(Self.strikeText(strike)) \(right.name)" }

    /// "Nov 28 600C".
    var short: String { "\(Self.expiryLabel(expiry)) \(Self.strikeText(strike))\(right.rawValue)" }

    func intrinsic(at spot: Double) -> Double {
        right == .call ? max(0, spot - strike) : max(0, strike - spot)
    }

    /// In the money with the underlying at `spot`.
    func isInTheMoney(at spot: Double) -> Bool { right == .call ? spot > strike : spot < strike }

    // MARK: Expiry

    static let newYork = TimeZone(identifier: "America/New_York")!
    private static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = newYork
        return c
    }()
    private static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    /// 16:00 New York time on the expiry day, when most options stop trading.
    static func date(_ expiry: String) -> Date? {
        guard expiry.count == 8, let y = Int(expiry.prefix(4)), let m = Int(expiry.dropFirst(4).prefix(2)),
              let d = Int(expiry.suffix(2)) else { return nil }
        return calendar.date(from: DateComponents(year: y, month: m, day: d, hour: 16))
    }

    /// Calendar days from today (New York) to the expiry day: 0 on the day itself.
    static func daysLeft(_ expiry: String, from now: Date = Date()) -> Int {
        guard let date = date(expiry) else { return 0 }
        return calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
    }

    /// Years until the expiry's close, a minute at least (for the math).
    static func years(_ expiry: String, from now: Date = Date()) -> Double {
        max((date(expiry) ?? now).timeIntervalSince(now), 60) / (365 * 86_400)
    }

    /// The third Friday of its month: the standard monthly expiry (the others are weeklies).
    static func isMonthly(_ expiry: String) -> Bool {
        guard let date = date(expiry) else { return false }
        let c = calendar.dateComponents([.weekday, .day], from: date)
        return c.weekday == 6 && (15...21).contains(c.day ?? 0)
    }

    /// "Nov 28", or "Jan 15 '27" in another year.
    static func expiryLabel(_ expiry: String) -> String {
        guard expiry.count == 8, let y = Int(expiry.prefix(4)), let m = Int(expiry.dropFirst(4).prefix(2)),
              let d = Int(expiry.suffix(2)), (1...12).contains(m) else { return expiry }
        let thisYear = calendar.component(.year, from: Date())
        return "\(months[m - 1]) \(d)" + (y == thisYear ? "" : " '\(String(format: "%02d", y % 100))")
    }

    /// Price steps an option order can use: 5 cents from $3 up, a cent below (the classes quoted in pennies at every price
    /// take 5 cents too).
    static func tick(for price: Double) -> Double { abs(price) >= 3 ? 0.05 : 0.01 }

    static func rounded(_ price: Double) -> Double {
        let tick = tick(for: price)
        return ((price / tick).rounded() * tick * 100).rounded() / 100
    }
}

/// What IB lists for an underlying's options on SMART: their trading class, expiries (today's and later, soonest
/// first) and every strike in any of them.
nonisolated struct OptionChainInfo: Equatable, Sendable {
    var tradingClass: String
    var expirations: [String]
    var strikes: [Double]
}

/// An option IB listed for an expiry, with IB's contract id (combo orders name their legs by it).
nonisolated struct ListedOption: Equatable, Sendable {
    var contract: OptionContract
    var conId: Int
}

/// What IB's option model works out for an option from its price: implied volatility (0.25 is 25% a year), the
/// Greeks (per share: delta in dollars per dollar of the underlying, theta per day, vega per volatility point) and
/// the underlying's price it used. From IB's model ticks when it sends them, else from the bid, ask or last.
nonisolated struct OptionGreeks: Equatable, Sendable {
    var impliedVol: Double?
    var delta: Double?
    var gamma: Double?
    var vega: Double?
    var theta: Double?
    var modelPrice: Double?
    var underlyingPrice: Double?
    var fromModel = false
}

/// An underlying's own volatility: the implied volatility of its options (30 days out, IB's tick 24) and the
/// historical volatility of its price (30 days, tick 23).
nonisolated struct UnderlyingVol: Equatable, Sendable {
    var implied: Double?
    var historical: Double?
}

/// A combo order (several options as one order): its symbol is the underlying's and " COMBO".
nonisolated enum OptionCombo {
    static func symbol(_ underlying: String) -> String { "\(underlying) COMBO" }

    static func underlying(of symbol: String) -> String? {
        symbol.hasSuffix(" COMBO") ? String(symbol.dropLast(6)) : nil
    }
}

/// One leg of a combo order as IB takes it.
nonisolated struct ComboLegSpec: Sendable, Equatable {
    var conId: Int
    var ratio: Int
    /// BUY or SELL.
    var action: String
}

// MARK: - Math

nonisolated enum OptionMath {
    /// The interest rate the math uses, a year.
    static let rate = 0.04

    static func cdf(_ x: Double) -> Double { 0.5 * erfc(-x / 2.0.squareRoot()) }
    static func pdf(_ x: Double) -> Double { exp(-x * x / 2) / (2 * Double.pi).squareRoot() }

    /// Black-Scholes value per share, `years` before expiry at volatility `vol`; at expiry, what it's worth exercised.
    static func value(_ right: OptionRight, spot: Double, strike: Double, years: Double, vol: Double) -> Double {
        let intrinsic = right == .call ? max(0, spot - strike) : max(0, strike - spot)
        guard years > 1e-9, vol > 0, spot > 0, strike > 0 else { return intrinsic }
        let sd = vol * years.squareRoot()
        let d1 = (log(spot / strike) + (rate + vol * vol / 2) * years) / sd
        let d2 = d1 - sd
        let discounted = strike * exp(-rate * years)
        let v = right == .call ? spot * cdf(d1) - discounted * cdf(d2) : discounted * cdf(-d2) - spot * cdf(-d1)
        return max(v, 0)
    }

    /// The chance the price ends above `level` after `years`, its log normally spread at `vol`.
    static func chanceAbove(_ level: Double, spot: Double, years: Double, vol: Double) -> Double {
        guard level > 0 else { return 1 }
        guard spot > 0, years > 0, vol > 0 else { return spot > level ? 1 : 0 }
        let sd = vol * years.squareRoot()
        return cdf((log(spot / level) + (rate - vol * vol / 2) * years) / sd)
    }

    /// One standard deviation of the price over `years`: about 2 in 3 times it ends within this of where it is.
    static func expectedMove(spot: Double, years: Double, vol: Double) -> Double {
        spot * vol * years.squareRoot()
    }
}

/// A set of options against the underlying's price: each leg in contracts (bought positive, sold negative), at its own
/// implied volatility, and what they all cost in dollars (taken in: negative).
nonisolated struct OptionPayoff {
    struct Leg {
        var contract: OptionContract
        var contracts: Double
        var vol: Double
    }

    struct Summary {
        /// nil: no limit.
        var maxProfit: Double?
        var maxLoss: Double?
        var breakevens: [Double]
        /// The chance of ending in profit at the first expiry, the price log normally spread at the legs' volatility.
        var chanceOfProfit: Double?
    }

    var legs: [Leg]
    var cost: Double

    /// The first expiry: P/L "at expiry" is then (legs expiring later valued at what's left of their time).
    var horizon: String { legs.map(\.contract.expiry).min() ?? "" }

    /// P/L in dollars with the underlying at `spot` at the first expiry.
    func pnlAtExpiry(_ spot: Double) -> Double {
        let end = OptionContract.years(horizon)
        return legs.reduce(-cost) { sum, leg in
            let left = OptionContract.years(leg.contract.expiry) - end
            return sum + leg.contracts * OptionContract.multiplier
                * OptionMath.value(leg.contract.right, spot: spot, strike: leg.contract.strike, years: left > 1e-6 ? left : 0, vol: leg.vol)
        }
    }

    /// P/L in dollars were the underlying at `spot` now (Black-Scholes at each leg's volatility).
    func pnlNow(_ spot: Double) -> Double {
        legs.reduce(-cost) { sum, leg in
            sum + leg.contracts * OptionContract.multiplier
                * OptionMath.value(leg.contract.right, spot: spot, strike: leg.contract.strike,
                                   years: OptionContract.years(leg.contract.expiry), vol: leg.vol)
        }
    }

    /// The prices from `low` to `high` in `count` steps, with the strikes in between.
    func prices(from low: Double, to high: Double, count: Int) -> [Double] {
        guard high > low, count > 1 else { return [low] }
        let step = (high - low) / Double(count - 1)
        var xs = (0..<count).map { low + Double($0) * step }
        xs += legs.map(\.contract.strike).filter { $0 > low && $0 < high }
        return xs.sorted()
    }

    func summary(spot: Double, vol: Double) -> Summary {
        guard !legs.isEmpty, spot > 0 else { return Summary(breakevens: []) }
        let top = max(spot, legs.map(\.contract.strike).max() ?? spot) * 3
        let xs = prices(from: 0, to: top, count: 1500)
        let ys = xs.map(pnlAtExpiry)
        // Past the top: the slope from there on (calls bought or sold keep it moving).
        let slope = (pnlAtExpiry(top * 2) - pnlAtExpiry(top)) / top
        var breakevens: [Double] = []
        for i in 1..<xs.count where (ys[i - 1] < 0) != (ys[i] < 0) && ys[i] != ys[i - 1] {
            let x = xs[i - 1] + (xs[i] - xs[i - 1]) * (0 - ys[i - 1]) / (ys[i] - ys[i - 1])
            if x > 0.005, breakevens.last.map({ abs($0 - x) > 0.005 }) ?? true { breakevens.append(x) }
        }
        var chance: Double?
        let years = OptionContract.years(horizon)
        if vol > 0 {
            let sd = vol * years.squareRoot(), mean = log(spot) + (OptionMath.rate - vol * vol / 2) * years
            let dz = 0.01
            var p = 0.0, z = -6.0
            while z <= 6 {
                if pnlAtExpiry(exp(mean + sd * z)) > 0 { p += OptionMath.pdf(z) * dz }
                z += dz
            }
            chance = min(1, max(0, p))
        }
        return Summary(maxProfit: slope > 1e-6 ? nil : ys.max(), maxLoss: slope < -1e-6 ? nil : ys.min(),
                       breakevens: breakevens, chanceOfProfit: chance)
    }
}

// MARK: - Strategies

/// Option strategies a newcomer can start from, built around the strike nearest the price.
nonisolated enum OptionStrategy: String, CaseIterable, Identifiable, Sendable {
    case longCall, bullCallSpread, bullPutSpread, cashSecuredPut
    case longPut, bearPutSpread, bearCallSpread
    case ironCondor, ironButterfly
    case longStraddle, longStrangle

    enum Outlook: String, CaseIterable, Identifiable {
        case bullish = "Bullish", bearish = "Bearish", neutral = "Sideways", volatile = "Big move"
        var id: String { rawValue }
        var blurb: String {
            switch self {
            case .bullish: "You think it goes up"
            case .bearish: "You think it goes down"
            case .neutral: "You think it stays in a range"
            case .volatile: "You think it moves a lot, either way"
            }
        }
    }

    var id: String { rawValue }

    var name: String {
        switch self {
        case .longCall: "Long Call"
        case .bullCallSpread: "Bull Call Spread"
        case .bullPutSpread: "Bull Put Spread"
        case .cashSecuredPut: "Cash-Secured Put"
        case .longPut: "Long Put"
        case .bearPutSpread: "Bear Put Spread"
        case .bearCallSpread: "Bear Call Spread"
        case .ironCondor: "Iron Condor"
        case .ironButterfly: "Iron Butterfly"
        case .longStraddle: "Long Straddle"
        case .longStrangle: "Long Strangle"
        }
    }

    var outlook: Outlook {
        switch self {
        case .longCall, .bullCallSpread, .bullPutSpread, .cashSecuredPut: .bullish
        case .longPut, .bearPutSpread, .bearCallSpread: .bearish
        case .ironCondor, .ironButterfly: .neutral
        case .longStraddle, .longStrangle: .volatile
        }
    }

    /// What it is and when it pays, in a line or two.
    var blurb: String {
        switch self {
        case .longCall: "Buy a call. Gains as the price rises past the strike plus what you paid; the most you can lose is what you paid."
        case .bullCallSpread: "Buy a call, sell a higher one. Cheaper than a call alone; the gain stops at the higher strike."
        case .bullPutSpread: "Sell a put, buy a lower one. You're paid now and keep it if the price stays above the higher strike."
        case .cashSecuredPut: "Sell a put. You're paid now; below the strike you buy 100 shares a contract at the strike. Needs that much cash."
        case .longPut: "Buy a put. Gains as the price falls past the strike less what you paid; the most you can lose is what you paid."
        case .bearPutSpread: "Buy a put, sell a lower one. Cheaper than a put alone; the gain stops at the lower strike."
        case .bearCallSpread: "Sell a call, buy a higher one. You're paid now and keep it if the price stays below the lower strike."
        case .ironCondor: "A bull put spread and a bear call spread. You're paid now and keep it if the price stays between the sold strikes."
        case .ironButterfly: "Sell a call and a put at the price, buy wings further out. Pays most if the price ends right where it is."
        case .longStraddle: "Buy a call and a put at the price. Gains on a big move either way; time and calm cost you."
        case .longStrangle: "Buy a call above and a put below the price. Cheaper than a straddle, needs a bigger move."
        }
    }

    /// Whether the most it can lose is known when it's opened (and no bigger than the spread).
    var risk: String {
        switch self {
        case .longCall, .longPut, .longStraddle, .longStrangle: "Risk: what you pay"
        case .bullCallSpread, .bearPutSpread: "Risk: what you pay"
        case .bullPutSpread, .bearCallSpread, .ironCondor, .ironButterfly: "Risk: the width less what you're paid"
        case .cashSecuredPut: "Risk: the strike × 100 less what you're paid"
        }
    }

    /// The legs: call or put, strikes from the one nearest the price (+ higher, − lower), and bought or sold;
    /// `width` strikes between a spread's legs.
    func shape(width w: Int) -> [(right: OptionRight, offset: Int, buy: Bool)] {
        switch self {
        case .longCall: [(.call, 0, true)]
        case .bullCallSpread: [(.call, 0, true), (.call, w, false)]
        case .bullPutSpread: [(.put, -1, false), (.put, -1 - w, true)]
        case .cashSecuredPut: [(.put, -1, false)]
        case .longPut: [(.put, 0, true)]
        case .bearPutSpread: [(.put, 0, true), (.put, -w, false)]
        case .bearCallSpread: [(.call, 1, false), (.call, 1 + w, true)]
        case .ironCondor: [(.put, -w - 1, true), (.put, -1, false), (.call, 1, false), (.call, w + 1, true)]
        case .ironButterfly: [(.put, -w, true), (.put, 0, false), (.call, 0, false), (.call, w, true)]
        case .longStraddle: [(.call, 0, true), (.put, 0, true)]
        case .longStrangle: [(.call, w, true), (.put, -w, true)]
        }
    }

    /// Strategies with one leg have no width.
    var hasWidth: Bool { shape(width: 1).count > 1 && self != .longStraddle }
}
