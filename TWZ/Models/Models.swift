//
//  Models.swift
//  TWZ
//

import Foundation

struct Bar: Equatable {
    var time: Date
    var open: Double
    var high: Double
    var low: Double
    var close: Double
    var volume: Double
}

struct Quote: Equatable {
    var bid: Double?
    var ask: Double?
    var last: Double?
    var prevClose: Double?
    var volume: Double?

    var changePercent: Double? {
        guard let last, let prevClose, prevClose > 0 else { return nil }
        return (last - prevClose) / prevClose * 100
    }
}

struct Position: Identifiable, Equatable {
    var symbol: String
    var quantity: Double
    var avgCost: Double
    var id: String { symbol }
}

struct OrderRow: Identifiable, Equatable {
    var id: Int                 // IB order id
    var symbol: String
    var action: String          // BUY / SELL
    var quantity: Double
    var orderType: String       // IB order type: LMT, MKT, STP, TRAIL, …
    var limitPrice: Double?
    var auxPrice: Double?       // stop / trigger price (or trailing amount for TRAIL)
    var status: String
    var filled: Double = 0
    var avgFillPrice: Double = 0
    var updated = Date()

    var isActive: Bool {
        ["PendingSubmit", "PreSubmitted", "Submitted", "ApiPending", "PendingCancel"].contains(status)
    }
}

struct Fill: Identifiable, Equatable {
    var id: String              // execId
    var orderId: Int
    var symbol: String
    var side: String            // BOT / SLD
    var shares: Double
    var price: Double
    var time: Date
}

enum Timeframe: String, CaseIterable, Codable, Identifiable {
    case m1 = "1m", m5 = "5m", m15 = "15m", h1 = "1h", d1 = "D"
    var id: String { rawValue }

    var barSize: String {
        switch self {
        case .m1: "1 min"
        case .m5: "5 mins"
        case .m15: "15 mins"
        case .h1: "1 hour"
        case .d1: "1 day"
        }
    }

    var duration: String {
        switch self {
        case .m1: "2 D"
        case .m5: "5 D"
        case .m15: "10 D"
        case .h1: "1 M"
        case .d1: "1 Y"
        }
    }

    var isIntraday: Bool { self != .d1 }
}

// MARK: - Hotkeys

/// IBKR order types a hotkey can send (stocks, SMART-routed).
enum OrderKind: String, Codable, CaseIterable, Identifiable {
    case market = "Market"
    case limit = "Limit"
    case stop = "Stop"
    case stopLimit = "Stop Limit"
    case trailingStop = "Trailing Stop"
    case trailingStopLimit = "Trailing Stop Limit"
    case marketIfTouched = "Market if Touched"
    case limitIfTouched = "Limit if Touched"
    case marketToLimit = "Market to Limit"
    case midprice = "Midprice"
    case relative = "Relative (Pegged to Primary)"
    case marketOnOpen = "Market on Open"
    case limitOnOpen = "Limit on Open"
    case marketOnClose = "Market on Close"
    case limitOnClose = "Limit on Close"
    var id: String { rawValue }

    /// Grouping for the picker.
    static let groups: [(String, [OrderKind])] = [
        ("Basic", [.market, .limit]),
        ("Stops", [.stop, .stopLimit, .trailingStop, .trailingStopLimit]),
        ("Touched", [.marketIfTouched, .limitIfTouched]),
        ("Market-based", [.marketToLimit, .midprice, .relative]),
        ("Auction", [.marketOnOpen, .limitOnOpen, .marketOnClose, .limitOnClose]),
    ]

    /// IB API `orderType` string.
    var ibType: String {
        switch self {
        case .market, .marketOnOpen: "MKT"
        case .limit, .limitOnOpen: "LMT"
        case .stop: "STP"
        case .stopLimit: "STP LMT"
        case .trailingStop: "TRAIL"
        case .trailingStopLimit: "TRAIL LIMIT"
        case .marketIfTouched: "MIT"
        case .limitIfTouched: "LIT"
        case .marketToLimit: "MTL"
        case .midprice: "MIDPRICE"
        case .relative: "REL"
        case .marketOnClose: "MOC"
        case .limitOnClose: "LOC"
        }
    }

    /// Short label for buttons and order rows.
    var short: String {
        switch self {
        case .marketOnOpen: "MOO"
        case .limitOnOpen: "LOO"
        default: ibType
        }
    }

    /// Limit price derived from bid/ask ± limit offset (or from the trigger for STP LMT / LIT).
    var usesLimitOffset: Bool { [.limit, .stopLimit, .limitIfTouched, .limitOnOpen, .limitOnClose].contains(self) }
    /// Stop / touch trigger derived from bid/ask ± trigger offset.
    var usesTrigger: Bool { [.stop, .stopLimit, .marketIfTouched, .limitIfTouched].contains(self) }
    var isTrailing: Bool { self == .trailingStop || self == .trailingStopLimit }
    /// Auction orders have a fixed time in force.
    var fixedTIF: TimeInForce? {
        switch self {
        case .marketOnOpen, .limitOnOpen: .opening
        case .marketOnClose, .limitOnClose: .day
        default: nil
        }
    }
    /// Types that can work in pre-market / after-hours sessions.
    var allowsOutsideRth: Bool {
        [.limit, .stop, .stopLimit, .trailingStop, .trailingStopLimit, .marketIfTouched, .limitIfTouched].contains(self)
    }
    /// IB's Adaptive algo works with market and limit orders only.
    var supportsAdaptive: Bool { self == .market || self == .limit }
}

enum TimeInForce: String, Codable, CaseIterable, Identifiable {
    case day = "DAY"
    case gtc = "GTC"
    case ioc = "IOC"
    case opening = "OPG"
    var id: String { rawValue }
    static let selectable: [TimeInForce] = [.day, .gtc, .ioc]
}

enum AdaptivePriority: String, Codable, CaseIterable, Identifiable {
    case off = "Off"
    case patient = "Patient"
    case normal = "Normal"
    case urgent = "Urgent"
    var id: String { rawValue }
}

struct Hotkey: Codable, Identifiable, Equatable {
    enum Action: String, Codable, CaseIterable, Identifiable {
        case buy = "Buy"
        case sell = "Sell"
        case closeHalf = "Close 50%"
        case closeAll = "Close 100%"
        case cancelSymbol = "Cancel Symbol Orders"
        case cancelAll = "Cancel All Orders"
        case flattenAll = "Flatten All"
        var id: String { rawValue }

        var needsSize: Bool { self == .buy || self == .sell }
        var placesOrder: Bool { self != .cancelSymbol && self != .cancelAll }
    }

    enum Sizing: String, Codable, CaseIterable, Identifiable {
        case shares = "Shares"
        case dollars = "Dollars"
        var id: String { rawValue }
    }

    enum TrailUnit: String, Codable, CaseIterable, Identifiable {
        case amount = "$"
        case percent = "%"
        var id: String { rawValue }
    }

    var id = UUID()
    var label: String
    var action: Action
    var sizing: Sizing = .shares
    var amount: Double = 100
    var orderType: OrderKind = .limit
    /// Limit: buys ask + offset, sells bid − offset. Stop limit / LIT: limit beyond the trigger by this much.
    /// Relative: the peg offset.
    var offset: Double = 0.02
    /// Stop: buys ask + offset, sells bid − offset. Touched: buys bid − offset, sells ask + offset.
    var triggerOffset: Double = 0.10
    var trailAmount: Double = 1
    var trailUnit: TrailUnit = .percent
    var tif: TimeInForce = .day
    var outsideRth = true
    var adaptive: AdaptivePriority = .off

    init(label: String, action: Action, sizing: Sizing = .shares, amount: Double = 100,
         orderType: OrderKind = .limit, offset: Double = 0.02) {
        self.label = label
        self.action = action
        self.sizing = sizing
        self.amount = amount
        self.orderType = orderType
        self.offset = offset
    }

    private enum CodingKeys: String, CodingKey {
        case id, label, action, sizing, amount, orderType, offset, triggerOffset
        case trailAmount, trailUnit, tif, outsideRth, adaptive
        case priceType   // legacy: "Market" or "Limit (bid/ask ± offset)"
    }

    /// Tolerant decoding so hotkeys saved by older versions keep working.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        label = try c.decode(String.self, forKey: .label)
        action = try c.decode(Action.self, forKey: .action)
        sizing = try c.decodeIfPresent(Sizing.self, forKey: .sizing) ?? .shares
        amount = try c.decodeIfPresent(Double.self, forKey: .amount) ?? 100
        if let kind = try? c.decodeIfPresent(OrderKind.self, forKey: .orderType) {
            orderType = kind
        } else if let legacy = try? c.decodeIfPresent(String.self, forKey: .priceType) {
            orderType = legacy == "Market" ? .market : .limit
        }
        offset = try c.decodeIfPresent(Double.self, forKey: .offset) ?? 0.02
        triggerOffset = try c.decodeIfPresent(Double.self, forKey: .triggerOffset) ?? 0.10
        trailAmount = try c.decodeIfPresent(Double.self, forKey: .trailAmount) ?? 1
        trailUnit = (try? c.decodeIfPresent(TrailUnit.self, forKey: .trailUnit)) ?? .percent
        tif = (try? c.decodeIfPresent(TimeInForce.self, forKey: .tif)) ?? .day
        outsideRth = try c.decodeIfPresent(Bool.self, forKey: .outsideRth) ?? true
        adaptive = (try? c.decodeIfPresent(AdaptivePriority.self, forKey: .adaptive)) ?? .off
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(label, forKey: .label)
        try c.encode(action, forKey: .action)
        try c.encode(sizing, forKey: .sizing)
        try c.encode(amount, forKey: .amount)
        try c.encode(orderType, forKey: .orderType)
        try c.encode(offset, forKey: .offset)
        try c.encode(triggerOffset, forKey: .triggerOffset)
        try c.encode(trailAmount, forKey: .trailAmount)
        try c.encode(trailUnit, forKey: .trailUnit)
        try c.encode(tif, forKey: .tif)
        try c.encode(outsideRth, forKey: .outsideRth)
        try c.encode(adaptive, forKey: .adaptive)
    }

    static let defaults: [Hotkey] = [
        Hotkey(label: "Buy 100", action: .buy, amount: 100),
        Hotkey(label: "Buy 500", action: .buy, amount: 500),
        Hotkey(label: "Buy $1K", action: .buy, sizing: .dollars, amount: 1_000),
        Hotkey(label: "Buy $5K", action: .buy, sizing: .dollars, amount: 5_000),
        Hotkey(label: "Close 50%", action: .closeHalf),
        Hotkey(label: "Close 100%", action: .closeAll),
        Hotkey(label: "Sell 100", action: .sell, amount: 100),
        Hotkey(label: "Sell 500", action: .sell, amount: 500),
        Hotkey(label: "Sell $1K", action: .sell, sizing: .dollars, amount: 1_000),
        Hotkey(label: "Sell $5K", action: .sell, sizing: .dollars, amount: 5_000),
        Hotkey(label: "Cancel All", action: .cancelAll),
        Hotkey(label: "Flatten All", action: .flattenAll, orderType: .market),
    ]
}

// MARK: - Scanners

enum ScannerKind: String, CaseIterable, Identifiable {
    case gainers = "Top Gainers"
    case losers = "Top Losers"
    case afterHours = "AH Gainers"
    case dollarVolume = "Most Active $"
    var id: String { rawValue }

    static let rowCount = 25

    /// IB scan codes. The % change scans rank on last vs. prior close, and IB's last
    /// includes extended-hours trades, so gainers/losers track pre-market moves before the open.
    var scanCode: String {
        switch self {
        case .gainers: "TOP_PERC_GAIN"
        case .losers: "TOP_PERC_LOSE"
        case .afterHours: "TOP_AFTER_HOURS_PERC_GAIN"
        case .dollarVolume: "MOST_ACTIVE_USD"
        }
    }
}

struct ScannerFilter: Codable, Equatable {
    var minPrice: Double? = 1
    var maxPrice: Double?
    var minVolume: Int? = 100_000
}

struct ScanSpec: Equatable {
    var kind: ScannerKind
    var filter: ScannerFilter
}

struct ScanResult: Equatable {
    var symbols: [String] = []
    var error: String?
    var updated: Date?
}

// MARK: - Market session

enum MarketSession {
    private static let eastern = TimeZone(identifier: "America/New_York")!

    enum Phase: String {
        case preMarket = "Pre-market"
        case regular = "Regular hours"
        case afterHours = "After hours"
        case closed = "Closed"
    }

    /// US equity session: pre 04:00–09:30, regular 09:30–16:00, after 16:00–20:00 ET, Mon–Fri.
    static func phase(_ date: Date = Date()) -> Phase {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = eastern
        let c = cal.dateComponents([.weekday, .hour, .minute], from: date)
        guard let weekday = c.weekday, (2...6).contains(weekday),
              let h = c.hour, let m = c.minute else { return .closed }
        switch h * 60 + m {
        case 4 * 60..<(9 * 60 + 30): return .preMarket
        case (9 * 60 + 30)..<(16 * 60): return .regular
        case (16 * 60)..<(20 * 60): return .afterHours
        default: return .closed
        }
    }

    /// True during regular US equity hours (09:30–16:00 ET, Mon–Fri).
    static func isRegularHours(_ date: Date = Date()) -> Bool {
        phase(date) == .regular
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

enum Fmt {
    static func price(_ v: Double?) -> String {
        guard let v else { return "—" }
        return v.formatted(.number.precision(.fractionLength(v < 1 ? 4 : 2)))
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

    static func volume(_ v: Double?) -> String {
        guard let v else { return "—" }
        switch v {
        case 1_000_000_000...: return (v / 1_000_000_000).formatted(.number.precision(.fractionLength(2))) + "B"
        case 1_000_000...: return (v / 1_000_000).formatted(.number.precision(.fractionLength(2))) + "M"
        case 1_000...: return (v / 1_000).formatted(.number.precision(.fractionLength(1))) + "K"
        default: return v.formatted(.number.precision(.fractionLength(0)))
        }
    }

    static func dollars(_ v: Double?) -> String {
        guard let v else { return "—" }
        return "$" + volume(v)
    }

    static func shares(_ v: Double) -> String {
        v.formatted(.number.precision(.fractionLength(0...2)))
    }
}
