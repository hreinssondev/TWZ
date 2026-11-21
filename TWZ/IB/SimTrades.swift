//
//  SimTrades.swift
//  TWZ
//
//  What-if trades: simulated positions, never sent to IB. ⌃⌥⇧1 / 2 / 3 sells (shorts) $1,000 / $2,000 /
//  $3,000 of the selected chart's symbol, ⌃⌥⇧4 85% of the largest position IB's margin allows in it
//  (⌥⇧1–4 buying the same is off; ⌃-click with no position buys one). The trade fills at once at the ask (a buy) or the bid (a
//  sell), and IB's preview of the order (asked, never placed) gives its commissions and fees. While
//  it's open the app shows it as it shows a position, marked as simulated: the chart's SIM badge,
//  arrows at its fills and hover P/L, and a row under Positions, its symbol in the what-if pink. ⌃-clicking its chart puts a simulated stop loss
//  (on the losing side of the average price) or take profit (on the winning side) on it, filled as
//  the last price reaches it: a stop at the bid / ask, no better than its price; a take profit at its
//  price. ⌘⌫ closes it at market, ⌘A takes its stop loss and take profit off. Nothing is simulated in
//  a symbol with a real position open. Kept across launches.
//  SIM (KEYS off, as at every launch): every order shortcut (an order key's or hotkey's own, ⌘⇧↩, ⌥⌘⇧↩, ⌘⌫)
//  trades what-if positions the same way as KEYS ON sends to IB: the order's side, size (shares, dollars or a percent of the buying power) and price, filled at
//  once at that price, a limit at its reference ± offset, MIDPRICE at the mid ± offset, market at the ask or
//  bid (nothing rests); closing, cancelling and flattening act on the what-if trades.
//

import Foundation

/// A what-if trade's position.
nonisolated struct SimPosition: Codable, Equatable, Identifiable {
    var id = UUID()
    var symbol: String
    /// Shares (a forex pair's base units): above 0 long, below 0 short.
    var quantity: Double
    var avgCost: Double
    var opened = Date()
    var stopLoss: Double?
    var takeProfit: Double?
    /// IB's preview of the commissions and fees of the fills that opened or added to it, summed.
    var entryCommission: OrderPreview.Commission?
    /// P/L of the fills that reduced it, in its price's currency (dollars for a stock).
    var realized = 0.0
    /// The fills that opened or added to it; its chart points an arrow at each. nil for what-if trades
    /// saved before these were kept (see `entryPoints`).
    var entries: [Entry]?

    struct Entry: Codable, Equatable {
        var time: Date
        var price: Double
    }

    /// Its fills in, or for one saved without them, its opening at the average price.
    var entryPoints: [Entry] { entries ?? [Entry(time: opened, price: avgCost)] }

    var isLong: Bool { quantity > 0 }

    /// P/L if all of it closed at `price`, in its price's currency, with what's been taken already.
    func pnl(at price: Double) -> Double { realized + (price - avgCost) * quantity }

    /// Stand in for order ids on its chart lines, so clicking one takes it off.
    static let stopLossLineId = -2
    static let takeProfitLineId = -3

    static let storageKey = "simPositions"

    static func saved() -> [String: SimPosition] {
        UserDefaults.standard.data(forKey: storageKey)
            .flatMap { try? JSONDecoder().decode([String: SimPosition].self, from: $0) } ?? [:]
    }

    static func save(_ sims: [String: SimPosition]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(sims), forKey: storageKey)
    }
}

/// What ⌥⇧1–4 (⌃⌥⇧1–4), or an order shortcut in SIM, trades.
nonisolated enum SimSize: Equatable {
    case shares(Double)
    case dollars(Double)
    /// A share of the largest new position IB's margin allows.
    case buyingPower(Double)

    /// The 1–4 keys, on the number row or the keypad.
    init?(keyCode: UInt16) {
        switch keyCode {
        case 18, 83: self = .dollars(1000)
        case 19, 84: self = .dollars(2000)
        case 20, 85: self = .dollars(3000)
        case 21, 86: self = .buyingPower(0.85)
        default: return nil
        }
    }

    static let keyCodes: Set<UInt16> = [18, 19, 20, 21, 83, 84, 85, 86]

    var label: String {
        switch self {
        case .shares(let n): Fmt.shares(n) + (n == 1 ? " share" : " shares")
        case .dollars(let d): "$" + Int(d).formatted()
        case .buyingPower(let f): "\(Int((f * 100).rounded()))% of the buying power"
        }
    }
}

extension Broker {
    static let simQuoteOwner = "sim-trades"

    /// Saves the what-if trades and keeps their symbols quoted (their stops fill off the quotes).
    func simPositionsChanged(from old: [String: SimPosition]) {
        SimPosition.save(simPositions)
        if Set(old.keys) != Set(simPositions.keys) {
            setQuoteSymbols(Array(simPositions.keys), owner: Self.simQuoteOwner)
        }
    }

    /// ⌥⇧1–4 (`BUY`) / ⌃⌥⇧1–4 (`SELL`): a what-if trade in `symbol`, at market (see the file's notes); in
    /// for an order shortcut in SIM at `hotkey`'s price (see `runSim`).
    func placeSim(_ action: String, _ size: SimSize, symbol rawSymbol: String, pricedAs hotkey: Hotkey? = nil) {
        let symbol = rawSymbol.uppercased(), isBuy = action == "BUY"
        guard state == .connected else { return say("Not connected to IB Gateway") }
        guard !hasRealPosition(symbol) else {
            return say("\(symbol): a real position is open, so no what-if trade in it")
        }
        let priceNow = {
            hotkey.map { self.simOrderPrice(symbol, hotkey: $0, isBuy: isBuy) } ?? self.simMarketPrice(symbol, isBuy: isBuy)
        }
        guard let price = priceNow() else {
            return say("\(symbol): no live price yet, so no what-if trade")
        }
        let held = simPositions[symbol]?.quantity ?? 0
        if !isBuy, held <= 0, !ForexPair.isForex(symbol), let level = shortability[symbol], level <= 1.5 {
            return say("\(symbol) can't be shorted at IB, so no what-if short")
        }
        guard let usd = usdPerPriceUnit(symbol) else { return say("No dollar rate for \(symbol) yet") }
        switch size {
        case .shares(let shares):
            fillSim(symbol, action, shares: shares.rounded(.down), at: price, sizedBy: size)
        case .dollars(let dollars):
            fillSim(symbol, action, shares: (dollars / (price * usd)).rounded(.down), at: price, sizedBy: size)
        case .buyingPower(let fraction):
            say("\(symbol) what-if trade: asking IB for the buying power…")
            askMaxNew(action, symbol: symbol, at: price) { [weak self] _, shares in
                guard let self else { return }
                guard let shares, shares >= 1 else {
                    return self.say("\(symbol): IB's margin leaves no room for a what-if \(isBuy ? "long" : "short")")
                }
                // Filled at the price when IB answers, a second or two later.
                let now = priceNow() ?? price
                self.fillSim(symbol, action, shares: (shares * fraction).rounded(.down), at: now, sizedBy: size)
            }
        }
    }

    /// An order shortcut in SIM, KEYS off (see `TradingShortcuts`): `hotkey`'s order as a what-if trade, never sent to IB: a
    /// buy or sell of its size (steps in $ or %, see `SizeMode`) at its price (see `simOrderPrice`); Close 50% / 100% the
    /// what-if trade at its price; Cancel Symbol / Cancel All take the what-if trades' stop losses and take
    /// profits off; Flatten All closes every one at market.
    func runSim(_ hotkey: Hotkey, symbol rawSymbol: String) {
        guard let hotkey = resolved(hotkey) else { return }
        let symbol = rawSymbol.uppercased()
        if symbol.isEmpty, hotkey.action != .cancelAll, hotkey.action != .flattenAll {
            return say("Select a chart with a symbol first")
        }
        switch hotkey.action {
        case .buy, .sell:
            let size: SimSize = switch hotkey.sizing {
            case .shares: .shares(hotkey.amount)
            case .dollars, .steps: .dollars(hotkey.amount)   // steps resolved above
            case .buyingPower: .buyingPower(hotkey.amount / 100)
            }
            placeSim(hotkey.action == .buy ? "BUY" : "SELL", size, symbol: symbol, pricedAs: hotkey)
        case .closeHalf, .closeAll:
            guard let sim = simPositions[symbol] else { return say("No what-if trade in \(symbol)") }
            guard let price = simOrderPrice(symbol, hotkey: hotkey, isBuy: !sim.isLong) else {
                return say("\(symbol): no live price yet, so the what-if trade can't close")
            }
            // As a real close: half rounded down, all of it when that's under one share.
            let held = abs(sim.quantity)
            let half = (held * 0.5).rounded(.down)
            let shares = hotkey.action == .closeAll || half < 1 ? held : half
            if shares >= held {
                closeSim(symbol, at: price, why: hotkey.label)
            } else {
                fillSim(symbol, sim.isLong ? "SELL" : "BUY", shares: shares, at: price, sizedBy: .shares(shares))
            }
        case .cancelSymbol:
            removeSimProtective(symbol)
            say("\(symbol)'s what-if stop loss and take profit off")
        case .cancelAll:
            for s in simPositions.keys { removeSimProtective(s) }
            say("Every what-if stop loss and take profit off")
        case .flattenAll:
            if simPositions.isEmpty { say("No what-if trades to close") }
            for s in Array(simPositions.keys) { closeSimAtMarket(s) }
        }
    }

    /// ⌘⌫ with a what-if trade and no real position: closes it at market.
    func closeSimAtMarket(_ symbol: String) {
        guard let sim = simPositions[symbol] else { return }
        guard let price = simMarketPrice(symbol, isBuy: !sim.isLong) else {
            return say("\(symbol): no live price yet, so the what-if trade can't close")
        }
        closeSim(symbol, at: price, why: "closed at market")
    }

    /// Takes a what-if trade off without a fill (its × under Positions).
    func removeSim(_ symbol: String) {
        guard simPositions.removeValue(forKey: symbol) != nil else { return }
        say("\(symbol): what-if trade removed")
    }

    /// What a ⌃-click at `price` puts on the what-if trade (as `TradingEngine.protectiveKind`), nil when
    /// there's none or it would fill right away.
    func simProtectiveKind(_ symbol: String, at price: Double) -> Protective.Kind? {
        guard let sim = simPositions[symbol] else { return nil }
        let position = Position(symbol: symbol, quantity: sim.quantity, avgCost: sim.avgCost)
        guard let kind = TradingEngine.protectiveKind(position, at: price),
              !TradingEngine.protectiveFillsNow(position, last: quotes[symbol]?.last, kind: kind, at: price) else { return nil }
        return kind
    }

    /// ⌃-click on a chart with a what-if trade: its simulated stop loss or take profit at `price`
    /// (moved there if it has one).
    func placeSimProtective(symbol: String, at rawPrice: Double) {
        guard simPositions[symbol] != nil else { return }
        let price = Self.simTick(rawPrice, symbol)
        guard let kind = simProtectiveKind(symbol, at: price) else {
            return say("\(symbol): there the what-if trade's stop loss or take profit would fill right away, so it wasn't set")
        }
        let moved = kind == .stopLoss ? simPositions[symbol]?.stopLoss != nil : simPositions[symbol]?.takeProfit != nil
        if kind == .stopLoss { simPositions[symbol]?.stopLoss = price } else { simPositions[symbol]?.takeProfit = price }
        say("\(symbol) what-if trade: \(kind == .stopLoss ? "stop loss" : "take profit") @ \(Fmt.price(price, for: symbol))"
            + (moved ? " (moved)" : ""))
    }

    /// Takes the what-if trade's stop loss and / or take profit off.
    func removeSimProtective(_ symbol: String, stopLoss: Bool = true, takeProfit: Bool = true) {
        guard let sim = simPositions[symbol], sim.stopLoss != nil || sim.takeProfit != nil else { return }
        if stopLoss { simPositions[symbol]?.stopLoss = nil }
        if takeProfit { simPositions[symbol]?.takeProfit = nil }
    }

    /// Fills the what-if trades' stop losses and take profits the last price has reached; on every quote update.
    func checkSimExits() {
        for sim in simPositions.values where sim.stopLoss != nil || sim.takeProfit != nil {
            guard let q = quotes[sim.symbol], let last = q.last, last > 0 else { continue }
            let long = sim.isLong
            if let stop = sim.stopLoss, long ? last <= stop : last >= stop {
                // A stop fills at market once the last price reaches it: the bid (closing a long) or the
                // ask (closing a short), no better than the stop.
                let market = (long ? q.bid : q.ask).flatMap { $0 > 0 ? $0 : nil } ?? last
                closeSim(sim.symbol, at: long ? min(stop, market) : max(stop, market), why: "stop loss")
            } else if let target = sim.takeProfit, long ? last >= target : last <= target {
                closeSim(sim.symbol, at: target, why: "take profit")
            }
        }
    }

    /// A what-if trade's P/L in NOK at `price` (nil without the rates), as for a position.
    func simPnLNOK(_ sim: SimPosition, at price: Double) -> Double? {
        guard let usd = usdPerPriceUnit(sim.symbol), let usdNok else { return nil }
        return sim.pnl(at: price) * usd * usdNok
    }

    /// IB's commission estimate in NOK (a range), nil without a rate for its currency.
    func commissionNOK(_ c: OrderPreview.Commission) -> (min: Double, max: Double)? {
        let rate: Double? = c.currency == "NOK" ? 1 : c.currency == "USD" ? usdNok : nil
        return rate.map { (c.min * $0, c.max * $0) }
    }

    // MARK: - Private

    private func hasRealPosition(_ symbol: String) -> Bool {
        positions[symbol].map { $0.quantity != 0 } ?? false
    }

    /// Where a market order fills: the ask for a buy, the bid for a sell; the last price without them.
    private func simMarketPrice(_ symbol: String, isBuy: Bool) -> Double? {
        let q = quotes[symbol]
        return [isBuy ? q?.ask : q?.bid, q?.last].compactMap { $0 }.first { $0 > 0 }
    }

    /// Where a ⌃ (what-if) order fills (see `runSim`): a limit at its price (its reference ± offset: plus for a
    /// buy, minus for a sell), MIDPRICE at the mid ± offset, a market order at the ask or bid; on the symbol's
    /// steps. The last price stands in for a side of the quote not in yet.
    private func simOrderPrice(_ symbol: String, hotkey: Hotkey, isBuy: Bool) -> Double? {
        let q = quotes[symbol]
        let bid = q?.bid.flatMap { $0 > 0 ? $0 : nil }, ask = q?.ask.flatMap { $0 > 0 ? $0 : nil }
        let last = q?.last.flatMap { $0 > 0 ? $0 : nil }
        let mid = bid.flatMap { b in ask.map { (b + $0) / 2 } } ?? last
        let reference: Double?
        switch hotkey.orderType {
        case .market:
            return simMarketPrice(symbol, isBuy: isBuy)
        case .midprice:
            reference = mid
        case .limit:
            reference = switch hotkey.priceReference {
            case .cross: (isBuy ? ask : bid) ?? last
            case .bid: bid ?? last
            case .ask: ask ?? last
            case .mid: mid
            case .last: last ?? mid
            }
        }
        guard let reference else { return nil }
        return Self.simTick(reference + (isBuy ? hotkey.offset : -hotkey.offset), symbol)
    }

    /// A price on the symbol's steps: a cent (a hundredth of one under $1), half a pip for forex.
    private static func simTick(_ price: Double, _ symbol: String) -> Double {
        guard let pair = ForexPair(symbol) else { return TradingEngine.roundToTick(price) }
        let scale = pow(10, Double(pair.decimals + 1))
        return ((price / pair.defaultTick).rounded() * pair.defaultTick * scale).rounded() / scale
    }

    /// Fills a what-if order: opens or adds to the trade, or reduces it, closing it (and opening the
    /// rest the other way) when the order is bigger than what's held.
    private func fillSim(_ symbol: String, _ action: String, shares: Double, at price: Double, sizedBy size: SimSize) {
        let isBuy = action == "BUY"
        guard shares >= 1 else {
            return say("\(symbol): \(size.label) is less than one share at \(Fmt.price(price, for: symbol)), so no what-if trade")
        }
        guard !hasRealPosition(symbol) else {
            return say("\(symbol): a real position is open, so no what-if trade in it")
        }
        var shares = shares
        if let sim = simPositions[symbol], sim.isLong != isBuy {
            // Against the trade: closes it first.
            let closing = min(shares, abs(sim.quantity))
            if closing < abs(sim.quantity) {
                simPositions[symbol]?.realized += (price - sim.avgCost) * closing * (sim.isLong ? 1 : -1)
                simPositions[symbol]?.quantity += isBuy ? closing : -closing
                return say("\(symbol) what-if trade: \(action) \(Fmt.shares(closing)) @ \(Fmt.price(price, for: symbol)), "
                           + "\(Fmt.shares(abs(sim.quantity) - closing)) left")
            }
            closeSim(symbol, at: price, why: "\(action) \(size.label)")
            shares -= closing
            guard shares >= 1 else { return }
        }
        var sim = simPositions[symbol] ?? SimPosition(symbol: symbol, quantity: 0, avgCost: price)
        let held = abs(sim.quantity)
        sim.entries = (held > 0 ? sim.entryPoints : []) + [SimPosition.Entry(time: Date(), price: price)]
        sim.avgCost = (sim.avgCost * held + price * shares) / (held + shares)
        sim.quantity += isBuy ? shares : -shares
        simPositions[symbol] = sim
        let usd = usdPerPriceUnit(symbol).flatMap { u in usdNok.map { shares * price * u * $0 } }
        say("\(symbol) what-if trade: \(action) \(Fmt.shares(shares)) @ \(Fmt.price(price, for: symbol))"
            + (usd.map { " (\(Fmt.nok($0, groupedFrom: 0)) NOK, \(size.label))" } ?? " (\(size.label))") + ", simulated, not sent to IB")
        // IB's preview of the same order, for its commissions and fees.
        let id = sim.id
        previewOrder(action, symbol: symbol, shares: shares, at: price) { [weak self] preview in
            guard let self, let fees = preview?.commission, self.simPositions[symbol]?.id == id else { return }
            if let old = self.simPositions[symbol]?.entryCommission {
                guard old.currency == fees.currency else { return }
                self.simPositions[symbol]?.entryCommission = OrderPreview.Commission(
                    min: old.min + fees.min, max: old.max + fees.max, currency: fees.currency)
            } else {
                self.simPositions[symbol]?.entryCommission = fees
            }
        }
    }

    /// Closes the whole what-if trade at `price` and says how it went: its P/L, and IB's estimate of
    /// the commissions in and out (the way in's twice).
    private func closeSim(_ symbol: String, at price: Double, why: String) {
        guard let sim = simPositions.removeValue(forKey: symbol) else { return }
        let pnl = simPnLNOK(sim, at: price)
        let fees = sim.entryCommission.flatMap(commissionNOK)
        var text = "\(symbol) what-if trade closed (\(why)) @ \(Fmt.price(price, for: symbol)): "
        text += pnl.map { "\(Fmt.nok($0, signed: true, groupedFrom: 0)) NOK" } ?? "P/L not known (no exchange rate)"
        if let fees {
            let low = Fmt.nok(fees.min * 2, groupedFrom: 0), high = Fmt.nok(fees.max * 2, groupedFrom: 0)
            text += ", less about \(low == high ? low : "\(low)–\(high)") NOK commissions in and out"
        }
        say(text)
    }
}
