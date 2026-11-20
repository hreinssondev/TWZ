//
//  Models.swift
//  TWZ
//

import Foundation

nonisolated struct Bar: Equatable {
    var time: Date
    var open: Double
    var high: Double
    var low: Double
    var close: Double
    var volume: Double
    /// Trading session the bar starts in; worked out once so the chart can shade sessions cheaply.
    var phase: MarketSession.Phase
    /// Trading day the bar's VWAP accumulates into (see MarketSession.vwapDay).
    var vwapDay: Int

    init(time: Date, open: Double, high: Double, low: Double, close: Double, volume: Double) {
        self.time = time
        self.open = open
        self.high = high
        self.low = low
        self.close = close
        self.volume = volume
        phase = MarketSession.phase(time)
        vwapDay = MarketSession.vwapDay(time)
    }
}

nonisolated struct Quote: Equatable {
    var bid: Double?
    var ask: Double?
    var last: Double?
    var prevClose: Double?
    var volume: Double?

    var changePercent: Double? {
        guard let last, let prevClose, prevClose > 0 else { return nil }
        return (last - prevClose) / prevClose * 100
    }

    /// Bid/ask midpoint, else the last price.
    var mid: Double? {
        if let bid, let ask, bid > 0, ask > 0 { return (bid + ask) / 2 }
        return last
    }
}

nonisolated struct Position: Identifiable, Equatable {
    var symbol: String
    var quantity: Double
    var avgCost: Double
    var id: String { symbol }
}

nonisolated struct OrderRow: Identifiable, Equatable {
    var id: Int                 // IB order id
    var symbol: String
    var action: String          // BUY / SELL
    var quantity: Double
    var orderType: String       // IB order type (hotkeys send LMT; TWS orders may be anything)
    var limitPrice: Double?
    var auxPrice: Double?       // stop / trigger price on orders entered elsewhere
    var status: String
    var filled: Double = 0
    var avgFillPrice: Double = 0
    var updated = Date()
    /// USD/NOK when the order was placed (or first seen), so its NOK value doesn't move with the rate.
    var usdNok: Double?

    /// Share of the order filled so far, 0–1.
    var fillProgress: Double { quantity > 0 ? min(1, filled / quantity) : 0 }

    var isActive: Bool {
        ["PendingSubmit", "PreSubmitted", "Submitted", "ApiPending", "PendingCancel"].contains(status)
    }
}

nonisolated struct Fill: Identifiable, Equatable {
    var id: String              // execId
    var orderId: Int
    var symbol: String
    var side: String            // BOT / SLD
    var shares: Double
    var price: Double
    var time: Date
    /// USD/NOK when the fill came in, so its NOK value doesn't move with the rate.
    var usdNok: Double?
    /// Commissions and fees IB charged for the fill, in dollars, once its commission report is in.
    var commission: Double?
}

/// One trade in a symbol, from flat back to flat, built from the day's fills.
nonisolated struct RoundTrip: Identifiable, Equatable {
    var id: String              // first fill's execId, plus the part of it when a fill flips the position
    var symbol: String
    var isLong: Bool
    var start: Date
    var lastFill: Date
    /// USD/NOK at the trip's first fill, so its NOK value doesn't move with the rate.
    var usdNok: Double?
    var buyShares = 0.0, buyValue = 0.0
    var sellShares = 0.0, sellValue = 0.0
    /// Shares still held; 0 once the trip is closed.
    var openShares = 0.0
    /// Shares held from before today's fills, whose entry price is unknown.
    var carried = 0.0
    /// Orders whose fills opened / closed the trip, in fill order.
    var entryOrderIds: [Int] = []
    var exitOrderIds: [Int] = []
    /// The fills that make up the trip (a fill that flips the position is in both trips).
    var fillIds: [String] = []
    /// Commissions and fees IB reported for those fills, in dollars (a fill that flips the position
    /// split between the trips by shares); fills whose report isn't in yet add nothing.
    var commissions = 0.0
    /// The orders that opened or added to the trip, and those closing it, in fill order, an order split
    /// into several fills once (keys from `orderKey`).
    var entryOrders: [String] = []
    var exitOrders: [String] = []

    var isOpen: Bool { abs(openShares) > 1e-9 }
    /// Orders that opened or added to the trip, long or short, not those closing it.
    var orderCount: Int { entryOrders.count }
    var entryShares: Double { (isLong ? buyShares : sellShares) + abs(carried) }
    var entryPrice: Double? { Self.average(isLong ? buyValue : sellValue, isLong ? buyShares : sellShares) }
    var exitPrice: Double? { Self.average(isLong ? sellValue : buyValue, isLong ? sellShares : buyShares) }

    /// Closed: proceeds minus cost, commissions and fees. Open: also values the shares still held at `last`.
    /// In dollars, the prices' currency converted at `usdPerUnit` (a forex pair's quote currency; 1 for
    /// stocks). nil when part of the trip was opened before today, or an open trip has no last price.
    func pnl(last: Double?, usdPerUnit: Double = 1) -> Double? {
        guard carried == 0 else { return nil }
        guard isOpen else { return (sellValue - buyValue) * usdPerUnit - commissions }
        return last.map { (sellValue - buyValue + openShares * $0) * usdPerUnit - commissions }
    }

    /// The order a fill came from: its id, or for orders entered in TWS (which IB reports without one)
    /// its side and second, as the Orders panel groups them.
    static func orderKey(_ fill: Fill) -> String {
        fill.orderId != 0 ? "\(fill.orderId)" : "\(fill.side) \(Int(fill.time.timeIntervalSince1970.rounded(.down)))"
    }

    private static func average(_ value: Double, _ shares: Double) -> Double? {
        shares > 0 ? value / shares : nil
    }

    /// Round trips, newest activity first. `positions` give each symbol's current holding, so shares
    /// held before the first fill (net of today's fills) are known.
    static func build(fills: [Fill], positions: [String: Position]) -> [RoundTrip] {
        var trips: [RoundTrip] = []
        for (symbol, symbolFills) in Dictionary(grouping: fills, by: \.symbol) {
            let sorted = symbolFills.sorted { ($0.time, $0.id) < ($1.time, $1.id) }
            let net = sorted.reduce(0) { $0 + ($1.side == "BOT" ? $1.shares : -$1.shares) }
            var qty = (positions[symbol]?.quantity ?? 0) - net
            if abs(qty) < 1e-9 { qty = 0 }
            var trip: RoundTrip?
            if qty != 0, let first = sorted.first {
                trip = RoundTrip(id: first.id + "#carried", symbol: symbol, isLong: qty > 0, start: first.time,
                                 lastFill: first.time, usdNok: first.usdNok, openShares: qty, carried: qty)
            }
            for fill in sorted {
                var remaining = fill.side == "BOT" ? fill.shares : -fill.shares
                var part = 0
                while abs(remaining) > 1e-9 {
                    if trip == nil {
                        trip = RoundTrip(id: part == 0 ? fill.id : "\(fill.id)#\(part)", symbol: symbol,
                                         isLong: remaining > 0, start: fill.time, lastFill: fill.time, usdNok: fill.usdNok)
                    }
                    // Up to the whole fill adds to the trip; a fill against it closes at most what's held.
                    let opening = qty == 0 || (qty > 0) == (remaining > 0)
                    let step = opening ? remaining : (remaining > 0 ? min(remaining, -qty) : max(remaining, -qty))
                    if !trip!.fillIds.contains(fill.id) { trip!.fillIds.append(fill.id) }
                    if let commission = fill.commission, fill.shares > 0 { trip!.commissions += commission * abs(step) / fill.shares }
                    let order = orderKey(fill)
                    if (step > 0) == trip!.isLong {
                        if !trip!.entryOrderIds.contains(fill.orderId) { trip!.entryOrderIds.append(fill.orderId) }
                        if !trip!.entryOrders.contains(order) { trip!.entryOrders.append(order) }
                    } else {
                        if !trip!.exitOrderIds.contains(fill.orderId) { trip!.exitOrderIds.append(fill.orderId) }
                        if !trip!.exitOrders.contains(order) { trip!.exitOrders.append(order) }
                    }
                    if step > 0 {
                        trip!.buyShares += step
                        trip!.buyValue += step * fill.price
                    } else {
                        trip!.sellShares -= step
                        trip!.sellValue -= step * fill.price
                    }
                    qty += step
                    if abs(qty) < 1e-9 { qty = 0 }
                    remaining -= step
                    trip!.openShares = qty
                    trip!.lastFill = fill.time
                    if qty == 0 {
                        trips.append(trip!)
                        trip = nil
                        part += 1
                    }
                }
            }
            if let trip { trips.append(trip) }
        }
        return trips.sorted { ($0.lastFill, $0.id) > ($1.lastFill, $1.id) }
    }
}

nonisolated enum Timeframe: String, CaseIterable, Codable, Identifiable {
    case m1 = "1m", m5 = "5m", m15 = "15m", m30 = "30m", h1 = "1h", d1 = "D"
    var id: String { rawValue }

    var barSize: String {
        switch self {
        case .m1: "1 min"
        case .m5: "5 mins"
        case .m15: "15 mins"
        case .m30: "30 mins"
        case .h1: "1 hour"
        case .d1: "1 day"
        }
    }

    var duration: String {
        switch self {
        case .m1: "5 D"
        case .m5: "10 D"
        case .m15: "10 D"
        case .m30: "1 M"
        case .h1: "1 M"
        case .d1: "1 Y"
        }
    }

    /// The shorter history every chart load starts with (see `Broker.loadOlderBars`).
    var compactDuration: String {
        switch self {
        case .m1: "1 D"
        case .m5: "2 D"
        case .m15: "5 D"
        case .m30: "10 D"
        case .h1: "10 D"
        case .d1: "6 M"
        }
    }

    /// Each page of bars before the oldest, once the full history is in (see `TradingEngine.loadOlderBars`).
    var olderPage: String {
        switch self {
        case .m1: "1 D"
        case .m5: "5 D"
        case .m15: "10 D"
        case .m30: "1 M"
        case .h1: "1 M"
        case .d1: "1 Y"
        }
    }

    var isIntraday: Bool { self != .d1 }

    /// Bar length in seconds; nil for daily bars, which follow the ET trading day.
    var barSeconds: Double? {
        switch self {
        case .m1: 60
        case .m5: 300
        case .m15: 900
        case .m30: 1800
        case .h1: 3600
        case .d1: nil
        }
    }
}

// MARK: - Hotkeys

/// The quote a hotkey's limit price is based on, before the offset is applied.
nonisolated enum PriceReference: String, Codable, CaseIterable, Identifiable {
    case cross = "Bid/Ask"   // buys at the ask, sells at the bid (crosses the spread)
    case bid = "Bid"
    case ask = "Ask"
    case mid = "Mid"
    case last = "Last"
    var id: String { rawValue }

    /// Short label for buttons: "Ask"/"Bid" for cross depends on side.
    func label(isBuy: Bool) -> String {
        self == .cross ? (isBuy ? "Ask" : "Bid") : rawValue
    }
}

nonisolated enum OrderType: String, Codable, CaseIterable, Identifiable {
    case market = "Market"
    case limit = "Limit"
    /// IBKR's MIDPRICE order in regular hours: it follows the midpoint as the quote moves, never past
    /// the ask (buys) / bid (sells) ± offset. Outside regular hours, a limit at the mid ± offset.
    case midprice = "Midprice"
    var id: String { rawValue }
}

nonisolated enum TimeInForce: String, Codable, CaseIterable, Identifiable {
    case day = "DAY"
    case gtc = "GTC"
    case ioc = "IOC"
    var id: String { rawValue }
}

/// A key plus modifiers that fires a hotkey. Matched by the physical key (`keyCode`) and modifiers;
/// `key` is only for display.
nonisolated struct KeyShortcut: Codable, Hashable {
    var keyCode: UInt16
    var key: String
    var command = false
    var option = false
    var control = false
    var shift = false
    /// F1–F20: never typed into a text field, so they fire while one is being edited too.
    var isFunctionKey = false

    /// No ⌘, ⌥ or ⌃, and not an F-key: a key that types something.
    var isPlain: Bool { !command && !option && !control && !isFunctionKey }

    /// What the key types (lowercase unless ⇧ is part of it).
    var typed: String { shift ? key.uppercased() : key.lowercased() }

    /// "⌃⌥⇧⌘K", in the order macOS menus use.
    var display: String {
        (control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "") + (command ? "⌘" : "") + key
    }

    static func == (a: KeyShortcut, b: KeyShortcut) -> Bool {
        a.keyCode == b.keyCode && a.command == b.command && a.option == b.option
            && a.control == b.control && a.shift == b.shift
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(keyCode)
        hasher.combine([command, option, control, shift])
    }
}

nonisolated struct Hotkey: Codable, Identifiable, Equatable {
    enum Action: String, Codable, CaseIterable, Identifiable {
        /// Buys while the trade mode is LONG, sells (short) while it's SHORT (see `TradeMode`). Saved as
        /// "Open" by the version before.
        case mode = "Mode"
        case buy = "Buy"
        case sell = "Sell"
        case closeHalf = "Close 50%"
        case closeAll = "Close 100%"
        case cancelSymbol = "Cancel Symbol Orders"
        case cancelAll = "Cancel All Orders"
        case flattenAll = "Flatten All"
        var id: String { rawValue }

        var needsSize: Bool { self == .mode || self == .buy || self == .sell }
        var placesOrder: Bool { self != .cancelSymbol && self != .cancelAll }

        /// Button color when the hotkey has no color of its own.
        var defaultColor: HotkeyColor {
            switch self {
            case .mode: .blue          // shown green while LONG, red while SHORT (see `HotkeyPanel`)
            case .buy: .green
            case .sell: .red
            case .closeHalf, .closeAll: .orange
            case .cancelSymbol, .cancelAll: .gray
            case .flattenAll: .purple
            }
        }
    }

    enum Sizing: String, Codable, CaseIterable, Identifiable {
        case shares = "Shares"
        case dollars = "Dollars"
        /// A percent of the most shares IB's margin allows in the stock: a new long for buys, a new
        /// short for sells (see `TradingEngine.sizeFromBuyingPower`).
        case buyingPower = "% Buying power"
        var id: String { rawValue }

        /// After the amount in labels: "100", "1000$", "80% BP".
        var suffix: String {
            switch self {
            case .shares: ""
            case .dollars: "$"
            case .buyingPower: "% BP"
            }
        }
    }

    var id = UUID()
    var label: String
    var action: Action
    var sizing: Sizing = .shares
    var amount: Double = 100
    var orderType: OrderType = .limit
    /// Limit price = reference + offset for buys, reference − offset for sells.
    var priceReference: PriceReference = .cross
    var offset: Double = 0.02
    var tif: TimeInForce = .day
    var outsideRth = true
    /// Button color; nil follows the action's default.
    var color: HotkeyColor?
    /// Sends this hotkey from anywhere in the main window, whichever hotkey is selected.
    var shortcut: KeyShortcut?

    init(label: String, action: Action, sizing: Sizing = .shares, amount: Double = 100,
         orderType: OrderType = .limit, priceReference: PriceReference = .cross, offset: Double = 0.02) {
        self.label = label
        self.action = action
        self.sizing = sizing
        self.amount = amount
        self.orderType = orderType
        self.priceReference = priceReference
        self.offset = offset
    }

    private enum CodingKeys: String, CodingKey {
        case id, label, action, sizing, amount, orderType, priceReference, offset, tif, outsideRth, color, shortcut
        case priceType   // legacy: "Market" or "Limit (bid/ask ± offset)"
    }

    /// Tolerant decoding so hotkeys saved by older versions keep working (unknown keys are ignored).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        label = try c.decode(String.self, forKey: .label)
        // "Open" is what the mode action was called at first; its automatic labels follow.
        let rawAction = try c.decode(String.self, forKey: .action)
        guard let action = Action(rawValue: rawAction == "Open" ? Action.mode.rawValue : rawAction) else {
            throw DecodingError.dataCorruptedError(forKey: .action, in: c, debugDescription: "Unknown hotkey action \(rawAction)")
        }
        self.action = action
        if rawAction == "Open", label.hasPrefix("Open") { label = Action.mode.rawValue + label.dropFirst(4) }
        sizing = try c.decodeIfPresent(Sizing.self, forKey: .sizing) ?? .shares
        amount = try c.decodeIfPresent(Double.self, forKey: .amount) ?? 100
        // Older versions stored other IB order types here (Stop, Trailing Stop, …); those become Limit.
        let storedType = (try? c.decodeIfPresent(String.self, forKey: .orderType))
            ?? (try? c.decodeIfPresent(String.self, forKey: .priceType))
        orderType = storedType == "Market" ? .market : storedType == "Midprice" ? .midprice : .limit
        priceReference = (try? c.decodeIfPresent(PriceReference.self, forKey: .priceReference)) ?? .cross
        offset = try c.decodeIfPresent(Double.self, forKey: .offset) ?? 0.02
        tif = (try? c.decodeIfPresent(TimeInForce.self, forKey: .tif)) ?? .day
        outsideRth = try c.decodeIfPresent(Bool.self, forKey: .outsideRth) ?? true
        color = try? c.decodeIfPresent(HotkeyColor.self, forKey: .color)
        shortcut = try? c.decodeIfPresent(KeyShortcut.self, forKey: .shortcut)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(label, forKey: .label)
        try c.encode(action, forKey: .action)
        try c.encode(sizing, forKey: .sizing)
        try c.encode(amount, forKey: .amount)
        try c.encode(orderType, forKey: .orderType)
        try c.encode(priceReference, forKey: .priceReference)
        try c.encode(offset, forKey: .offset)
        try c.encode(tif, forKey: .tif)
        try c.encode(outsideRth, forKey: .outsideRth)
        try c.encodeIfPresent(color, forKey: .color)
        try c.encodeIfPresent(shortcut, forKey: .shortcut)
    }

    /// What a hotkey for these settings is called automatically, e.g. "Buy 100", "Sell 1000$" or "Buy 80% BP".
    static func autoLabel(action: Action, sizing: Sizing, amount: Double) -> String {
        switch action {
        case .mode, .buy, .sell:
            let n = amount.formatted(.number.grouping(.never).precision(.fractionLength(0...2)))
            return "\(action.rawValue) \(n)\(sizing.suffix)"
        case .closeHalf, .closeAll: return action.rawValue
        case .cancelSymbol: return "Cancel Symbol"
        case .cancelAll: return "Cancel All"
        case .flattenAll: return "Flatten All"
        }
    }

    /// Labels that count as automatic for these settings (including the older "$1K" style),
    /// so they follow amount/action changes; anything else is a custom label and is kept.
    static func isAutoLabel(_ label: String, action: Action, sizing: Sizing, amount: Double) -> Bool {
        if label.trimmingCharacters(in: .whitespaces).isEmpty { return true }
        if label == autoLabel(action: action, sizing: sizing, amount: amount) { return true }
        if (action == .mode || action == .buy || action == .sell), sizing == .dollars, amount >= 1_000,
           amount.truncatingRemainder(dividingBy: 1_000) == 0 {
            return label == "\(action.rawValue) $\(Int(amount / 1_000))K"
        }
        return false
    }

    private static func make(_ action: Action, sizing: Sizing = .shares, amount: Double = 100,
                             orderType: OrderType = .limit) -> Hotkey {
        Hotkey(label: autoLabel(action: action, sizing: sizing, amount: amount),
               action: action, sizing: sizing, amount: amount, orderType: orderType)
    }

    /// Most buttons the two-row grid takes.
    static let maxCount = 24

    /// Grid columns for `count` buttons in two rows; with an odd count the top row has the extra one.
    static func columns(for count: Int) -> Int { max(1, (count + 1) / 2) }

    static let defaults: [Hotkey] = [
        make(.buy, amount: 100),
        make(.buy, amount: 500),
        make(.buy, sizing: .dollars, amount: 1_000),
        make(.buy, sizing: .dollars, amount: 5_000),
        make(.closeHalf),
        make(.closeAll),
        make(.sell, amount: 100),
        make(.sell, amount: 500),
        make(.sell, sizing: .dollars, amount: 1_000),
        make(.sell, sizing: .dollars, amount: 5_000),
        make(.cancelAll),
        make(.flattenAll, orderType: .market),
    ]
}

// MARK: - Scanners

nonisolated enum ScannerKind: String, CaseIterable, Codable, Identifiable {
    case gainers = "Top Gainers"
    case losers = "Top Losers"
    case afterHours = "AH Gainers"
    case dollarVolume = "Most Active $"
    /// Not an IB scan: the engine ranks `ForexPair.listed` itself, by % change.
    case forex = "Forex"
    var id: String { rawValue }

    /// Rows a list panel's scanner returns; a chart grid's asks for IB's maximum, 50, to fill 8×4.
    static let rowCount = 25
    static let maxRowCount = 50

    /// IB scan codes. The % change scans rank on last vs. prior close, and IB's last
    /// includes extended-hours trades, so gainers/losers track pre-market moves before the open.
    var scanCode: String {
        switch self {
        case .gainers: "TOP_PERC_GAIN"
        case .losers: "TOP_PERC_LOSE"
        case .afterHours: "TOP_AFTER_HOURS_PERC_GAIN"
        case .dollarVolume: "MOST_ACTIVE_USD"
        case .forex: ""
        }
    }

    /// Filter used until the user sets one; gainers reach down to $0.10 to catch low-priced runners.
    var defaultFilter: ScannerFilter {
        self == .gainers ? ScannerFilter(minPrice: 0.1) : ScannerFilter()
    }
}

nonisolated struct ScannerFilter: Codable, Hashable {
    var minPrice: Double? = 1
    var maxPrice: Double?
    var minVolume: Int? = 100_000
}

nonisolated struct ScanSpec: Codable, Equatable {
    var kind: ScannerKind
    var filter: ScannerFilter
    var rows = ScannerKind.rowCount
}

nonisolated struct ScanResult: Equatable {
    var symbols: [String] = []
    var error: String?
    var updated: Date?
}

/// Settings › Trading's Hide restricted stocks (see `Broker.hideRestricted`). Off by default.
enum RestrictedStocks {
    static let hideKey = "hideRestrictedStocks"
}

// MARK: - Market session

nonisolated enum MarketSession {
    private static let eastern = TimeZone(identifier: "America/New_York")!

    enum Phase: String {
        case preMarket = "Pre-market"
        case regular = "Regular hours"
        case afterHours = "After hours"
        case overnight = "Overnight"
        case closed = "Closed"
    }

    /// US equity session: pre 04:00–09:30, regular 09:30–16:00, after 16:00–20:00 ET, Mon–Fri;
    /// IBKR's overnight session runs 20:00–03:50 ET from Sunday evening to Friday morning.
    static func phase(_ date: Date = Date()) -> Phase {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = eastern
        let c = cal.dateComponents([.weekday, .hour, .minute], from: date)
        guard let weekday = c.weekday, let h = c.hour, let m = c.minute else { return .closed }
        let minutes = h * 60 + m
        let isWeekday = (2...6).contains(weekday)                         // Mon–Fri
        if minutes >= 20 * 60, (1...5).contains(weekday) { return .overnight }   // Sun–Thu evening
        if minutes < 3 * 60 + 50, isWeekday { return .overnight }               // Mon–Fri early morning
        guard isWeekday else { return .closed }
        switch minutes {
        case 4 * 60..<(9 * 60 + 30): return .preMarket
        case (9 * 60 + 30)..<(16 * 60): return .regular
        case (16 * 60)..<(20 * 60): return .afterHours
        default: return .closed
        }
    }

    /// What's left of the extended trading day (04:00–20:00 ET) from `date` on, session by session;
    /// empty outside pre-market, regular and after hours.
    static func restOfDay(from date: Date) -> [(start: Date, end: Date, phase: Phase)] {
        guard [.preMarket, .regular, .afterHours].contains(phase(date)) else { return [] }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = eastern
        func at(_ h: Int, _ m: Int) -> Date? { cal.date(bySettingHour: h, minute: m, second: 0, of: date) }
        guard let pre = at(4, 0), let open = at(9, 30), let close = at(16, 0), let end = at(20, 0) else { return [] }
        return [(pre, open, Phase.preMarket), (open, close, .regular), (close, end, .afterHours)]
            .compactMap { s, e, p in max(s, date) < e ? (max(s, date), e, p) : nil }
    }

    /// IDEALPRO forex hours: Sunday 17:15 ET to Friday 17:00 ET, closed 17:00–17:15 ET in between.
    static func forexIsOpen(_ date: Date = Date()) -> Bool {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = eastern
        let c = cal.dateComponents([.weekday, .hour, .minute], from: date)
        guard let weekday = c.weekday, let h = c.hour, let m = c.minute else { return false }
        let minutes = h * 60 + m, close = 17 * 60, reopen = 17 * 60 + 15
        switch weekday {
        case 7: return false                                    // Saturday
        case 1: return minutes >= reopen                        // Sunday evening
        case 6: return minutes < close                          // Friday
        default: return minutes < close || minutes >= reopen
        }
    }

    /// When a closed IDEALPRO opens again: "17:15 ET" after a weekday's close, else "Sunday 17:15 ET".
    static func forexReopening(_ date: Date = Date()) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = eastern
        return (2...5).contains(cal.component(.weekday, from: date)) ? "17:15 ET" : "Sunday 17:15 ET"
    }

    /// True during regular US equity hours (09:30–16:00 ET, Mon–Fri).
    static func isRegularHours(_ date: Date = Date()) -> Bool {
        phase(date) == .regular
    }

    /// Day number for VWAP: days run 04:00–04:00 ET, so VWAP resets as pre-market opens and the
    /// evening and overnight sessions continue the day before.
    static func vwapDay(_ date: Date) -> Int {
        let local = date.timeIntervalSince1970 + Double(eastern.secondsFromGMT(for: date)) - 4 * 3600
        return Int((local / 86400).rounded(.down))
    }

    /// ET calendar day, "yyyyMMdd".
    static func dayKey(_ date: Date = Date()) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = eastern
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

// MARK: - Formatting

nonisolated enum Fmt {
    /// Money with no currency symbol, e.g. "1,234,567.89" or "+1,234.56".
    static func amount(_ v: Double?, signed: Bool = false) -> String {
        guard let v else { return "—" }
        let s = abs(v).formatted(.number.precision(.fractionLength(2)))
        if signed { return (v < 0 ? "-" : "+") + s }
        return (v < 0 ? "-" : "") + s
    }

    /// Whole kroner, e.g. "12346" (or "+12346" signed), grouped by thousands ("12 346") from
    /// `groupedFrom` kroner up.
    static func nok(_ v: Double, signed: Bool = false, groupedFrom: Int = .max) -> String {
        let kr = Int(v.rounded())
        let sign = kr < 0 ? "-" : signed ? "+" : ""
        return sign + (abs(kr) >= groupedFrom ? abs(kr).formatted(.number.locale(Locale(identifier: "nb_NO"))) : String(abs(kr)))
    }

    static func price(_ v: Double?) -> String {
        guard let v else { return "—" }
        return v.formatted(.number.precision(.fractionLength(v < 1 ? 4 : 2)))
    }

    /// A price at `symbol`'s precision: a forex pair's 5 decimals (3 for yen pairs), else as `price(_:)`.
    static func price(_ v: Double?, for symbol: String) -> String {
        guard let pair = ForexPair(symbol) else { return price(v) }
        guard let v else { return "—" }
        return v.formatted(.number.precision(.fractionLength(pair.decimals)).grouping(.never))
    }

    static func money(_ v: Double?, signed: Bool = false) -> String {
        guard let v else { return "—" }
        let s = abs(v).formatted(.number.precision(.fractionLength(2)))
        if signed { return (v < 0 ? "-$" : "+$") + s }
        return (v < 0 ? "-$" : "$") + s
    }

    static func percent(_ v: Double?) -> String {
        guard let v else { return "—" }
        return (v >= 0 ? "+" : "") + v.formatted(.number.precision(.fractionLength(2))) + "%"
    }

    /// Grouped by thousands from `groupedFrom` shares up.
    static func shares(_ v: Double, groupedFrom: Int = 0) -> String {
        v.formatted(.number.precision(.fractionLength(0...2)).grouping(abs(v) < Double(groupedFrom) ? .never : .automatic))
    }
}

// MARK: - Chart order amount

/// NOK amount for alt-click chart buys, set in the order entry box next to the hotkeys.
nonisolated enum OrderAmount {
    static let storageKey = "orderAmountNOK"
    static let initial = 50_000.0
    static let minimum = 500.0
    static let maximum = 300_000.0
    static let step = 5_000.0

    static func clamp(_ nok: Double) -> Double {
        min(maximum, max(minimum, nok.rounded()))
    }

    /// One arrow-key step up or down, snapping to the next multiple of 5 000 NOK.
    static func stepped(_ nok: Double, up: Bool) -> Double {
        let steps = up ? (nok / step).rounded(.down) + 1 : (nok / step).rounded(.up) - 1
        return clamp(steps * step)
    }

    /// "50 000": digits only, for the field.
    static func format(_ nok: Double) -> String {
        Int(nok).formatted(.number.grouping(.automatic))
    }

    /// Reads a typed amount, ignoring grouping separators and any "NOK"/"kr" suffix.
    static func parse(_ text: String) -> Double? {
        let digits = text.filter(\.isASCII).filter(\.isNumber)
        return digits.isEmpty ? nil : Double(digits)
    }
}
