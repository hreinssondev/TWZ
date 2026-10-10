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
    var orderType: String       // LMT / MKT
    var limitPrice: Double?
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
        var needsPrice: Bool { self == .buy || self == .sell || self == .closeHalf || self == .closeAll }
    }

    enum Sizing: String, Codable, CaseIterable, Identifiable {
        case shares = "Shares"
        case dollars = "Dollars"
        var id: String { rawValue }
    }

    enum PriceType: String, Codable, CaseIterable, Identifiable {
        case limit = "Limit (bid/ask ± offset)"
        case market = "Market"
        var id: String { rawValue }
    }

    var id = UUID()
    var label: String
    var action: Action
    var sizing: Sizing = .shares
    var amount: Double = 100
    var priceType: PriceType = .limit
    var offset: Double = 0.02

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
        Hotkey(label: "Flatten All", action: .flattenAll, priceType: .market),
    ]
}

// MARK: - Market session

enum MarketSession {
    private static let eastern = TimeZone(identifier: "America/New_York")!

    /// True during regular US equity hours (09:30–16:00 ET, Mon–Fri).
    static func isRegularHours(_ date: Date = Date()) -> Bool {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = eastern
        let c = cal.dateComponents([.weekday, .hour, .minute], from: date)
        guard let weekday = c.weekday, (2...6).contains(weekday),
              let h = c.hour, let m = c.minute else { return false }
        let minutes = h * 60 + m
        return minutes >= 9 * 60 + 30 && minutes < 16 * 60
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

    static func shares(_ v: Double) -> String {
        v.formatted(.number.precision(.fractionLength(0...2)))
    }
}
