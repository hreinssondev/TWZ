//
//  Forex.swift
//  TWZ
//
//  Currency pairs on IBKR's IDEALPRO. A pair is written as IB's local symbol, "EUR.USD": bought and
//  sold in units of the base currency (EUR), priced in the quote currency (USD). Any other symbol is a
//  US stock. Forex has no trades, so the bid/ask mid stands in for the last price, charts show
//  midpoint bars, and it trades around the clock from Sunday 17:15 to Friday 17:00 ET.
//

import Foundation

nonisolated struct ForexPair: Hashable, Sendable {
    let base: String
    let quote: String

    var symbol: String { "\(base).\(quote)" }

    /// "EUR.USD": two three-letter currency codes around a dot (stocks never look like that; share
    /// classes come with a space, "BRK B").
    init?(_ symbol: String) {
        let u = Array(symbol.utf8)
        guard u.count == 7, u[3] == UInt8(ascii: "."),
              u[0..<3].allSatisfy(Self.isUpper), u[4..<7].allSatisfy(Self.isUpper) else { return nil }
        base = String(symbol.prefix(3))
        quote = String(symbol.suffix(3))
    }

    private static func isUpper(_ c: UInt8) -> Bool { c >= UInt8(ascii: "A") && c <= UInt8(ascii: "Z") }

    static func isForex(_ symbol: String) -> Bool { ForexPair(symbol) != nil }

    static func isCurrency(_ code: String) -> Bool { currencies.contains(code) }

    /// The Forex list: the majors, the main crosses and the Scandinavian pairs.
    static let listed = [
        "EUR.USD", "GBP.USD", "USD.JPY", "USD.CHF", "AUD.USD", "USD.CAD", "NZD.USD",
        "EUR.GBP", "EUR.JPY", "GBP.JPY", "EUR.CHF", "AUD.JPY", "EUR.AUD", "GBP.CHF", "CHF.JPY", "CAD.JPY",
        "USD.NOK", "EUR.NOK", "NOK.SEK", "USD.SEK", "EUR.SEK",
    ]

    /// Currencies a typed "EURUSD" or "EUR/USD" is read as a pair of, and a CFD on one as a forex pair.
    static let currencies: Set<String> = [
        "USD", "EUR", "GBP", "JPY", "CHF", "AUD", "CAD", "NZD", "NOK", "SEK", "DKK",
        "PLN", "HUF", "CZK", "MXN", "ZAR", "SGD", "HKD", "CNH", "TRY", "ILS",
    ]

    /// A symbol as typed: "eur/usd", "EURUSD" or "EUR.USD" become "EUR.USD"; anything else is just
    /// trimmed and uppercased.
    static func normalize(_ text: String) -> String {
        let s = text.trimmingCharacters(in: .whitespaces).uppercased()
        let letters = s.replacingOccurrences(of: "/", with: "").replacingOccurrences(of: ".", with: "")
        guard letters.count == 6, s.count == 6 || s.count == 7, letters.allSatisfy(\.isLetter) else { return s }
        let base = String(letters.prefix(3)), quote = String(letters.suffix(3))
        guard currencies.contains(base), currencies.contains(quote) else { return s }
        return "\(base).\(quote)"
    }

    /// Price decimals shown: 3 for yen pairs, 5 for the rest.
    var decimals: Int { quote == "JPY" ? 3 : 5 }
    /// One pip: 0.01 for yen pairs, 0.0001 for the rest.
    var pip: Double { quote == "JPY" ? 0.01 : 0.0001 }
    /// IDEALPRO's usual price step, half a pip, until IB's contract details give the pair's own.
    var defaultTick: Double { pip / 2 }

    /// IDEALPRO's smallest order: smaller ones are odd lots, filled away from IDEALPRO at worse prices.
    static let minimumUSD = 25_000.0

    /// The pair quoting `currency` against the dollar, the IB way round: "EUR.USD", "USD.JPY".
    static func dollarPair(for currency: String) -> String? {
        guard currency != "USD" else { return nil }
        return ["EUR", "GBP", "AUD", "NZD"].contains(currency) ? "\(currency).USD" : "USD.\(currency)"
    }

    /// Dollars one unit of `currency` is worth, from USD.NOK for kroner and otherwise from the mid of
    /// its dollar pair (`mid` looks one up); nil until that's quoted.
    static func usdPerUnit(of currency: String, usdNok: Double?, mid: (String) -> Double?) -> Double? {
        if currency == "USD" { return 1 }
        if currency == "NOK", let usdNok, usdNok > 0 { return 1 / usdNok }
        guard let pair = dollarPair(for: currency), let m = mid(pair), m > 0 else { return nil }
        return pair.hasPrefix("USD.") ? 1 / m : m
    }
}

/// What forex orders go to IB as (Settings › Trading): CFDs, the way IBKR's European accounts trade
/// currencies with leverage, or spot on IDEALPRO, leveraged only with IBKR's leveraged forex permission
/// (otherwise just conversions of currency held). Quotes and charts come from IDEALPRO either way.
/// Read on connecting.
nonisolated enum ForexOrders: String, CaseIterable, Identifiable {
    case cfd = "CFD"
    case spot = "Spot (IDEALPRO)"
    var id: String { rawValue }

    static let storageKey = "forexOrders"
    static let defaultValue = ForexOrders.cfd
}
