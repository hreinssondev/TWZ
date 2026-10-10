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
    /// Trading session the bar starts in; worked out once so the chart can shade sessions cheaply.
    var phase: MarketSession.Phase

    init(time: Date, open: Double, high: Double, low: Double, close: Double, volume: Double) {
        self.time = time
        self.open = open
        self.high = high
        self.low = low
        self.close = close
        self.volume = volume
        phase = MarketSession.phase(time)
    }
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
    var orderType: String       // IB order type (hotkeys send LMT; TWS orders may be anything)
    var limitPrice: Double?
    var auxPrice: Double?       // stop / trigger price on orders entered elsewhere
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

/// The quote a hotkey's limit price is based on, before the offset is applied.
enum PriceReference: String, Codable, CaseIterable, Identifiable {
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

enum OrderType: String, Codable, CaseIterable, Identifiable {
    case market = "Market"
    case limit = "Limit"
    var id: String { rawValue }
}

enum TimeInForce: String, Codable, CaseIterable, Identifiable {
    case day = "DAY"
    case gtc = "GTC"
    case ioc = "IOC"
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

        /// Button color when the hotkey has no color of its own.
        var defaultColor: HotkeyColor {
            switch self {
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
        var id: String { rawValue }
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
        case id, label, action, sizing, amount, orderType, priceReference, offset, tif, outsideRth, color
        case priceType   // legacy: "Market" or "Limit (bid/ask ± offset)"
    }

    /// Tolerant decoding so hotkeys saved by older versions keep working (unknown keys are ignored).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        label = try c.decode(String.self, forKey: .label)
        action = try c.decode(Action.self, forKey: .action)
        sizing = try c.decodeIfPresent(Sizing.self, forKey: .sizing) ?? .shares
        amount = try c.decodeIfPresent(Double.self, forKey: .amount) ?? 100
        // Older versions stored other IB order types here (Stop, Trailing Stop, …); those become Limit.
        let storedType = (try? c.decodeIfPresent(String.self, forKey: .orderType))
            ?? (try? c.decodeIfPresent(String.self, forKey: .priceType))
        orderType = storedType == "Market" ? .market : .limit
        priceReference = (try? c.decodeIfPresent(PriceReference.self, forKey: .priceReference)) ?? .cross
        offset = try c.decodeIfPresent(Double.self, forKey: .offset) ?? 0.02
        tif = (try? c.decodeIfPresent(TimeInForce.self, forKey: .tif)) ?? .day
        outsideRth = try c.decodeIfPresent(Bool.self, forKey: .outsideRth) ?? true
        color = try? c.decodeIfPresent(HotkeyColor.self, forKey: .color)
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
    }

    /// What a hotkey for these settings is called automatically, e.g. "Buy 100" or "Sell 1000$".
    static func autoLabel(action: Action, sizing: Sizing, amount: Double) -> String {
        switch action {
        case .buy, .sell:
            let n = amount.formatted(.number.grouping(.never).precision(.fractionLength(0...2)))
            return "\(action.rawValue) \(n)\(sizing == .dollars ? "$" : "")"
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
        if (action == .buy || action == .sell), sizing == .dollars, amount >= 1_000,
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
    /// Money with no currency symbol, e.g. "1,234,567.89" or "+1,234.56".
    static func amount(_ v: Double?, signed: Bool = false) -> String {
        guard let v else { return "—" }
        let s = abs(v).formatted(.number.precision(.fractionLength(2)))
        if signed { return (v < 0 ? "-" : "+") + s }
        return (v < 0 ? "-" : "") + s
    }

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

// MARK: - Chart order amount

/// NOK amount for alt-click chart buys, set in the order entry box next to the hotkeys.
enum OrderAmount {
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
