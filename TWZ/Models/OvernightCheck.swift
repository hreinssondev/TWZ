//
//  OvernightCheck.swift
//  TWZ
//
//  The overnight check: some minutes before the close (7 by default, Settings › Trading) a banner over
//  the charts says whether the open stock positions fit the margin IB asks for once the market closes,
//  from IB's look-ahead figures (what the account needs after the next margin change), and if not, how
//  many shares of each to sell or buy back so they do. Its Trim button sends those orders.
//

import Foundation

/// IB's margin figures from the account summary, in the account's base currency. The look-ahead ones
/// are what applies after the next margin change: for an account with more leverage intraday, the close.
nonisolated struct AccountMargin: Equatable, Sendable {
    var availableFunds: Double?
    var excessLiquidity: Double?
    var lookAheadAvailableFunds: Double?
    var lookAheadExcessLiquidity: Double?
    var lookAheadInitMargin: Double?
    var lookAheadMaintMargin: Double?
    /// When IB last sent one of them.
    var updated: Date?
}

enum OvernightCheck {
    static let enabledKey = "overnightCheckOn"
    static let defaultEnabled = true
    static let minutesKey = "overnightCheckMinutes"
    static let defaultMinutes = 7
    /// Room kept on top of the shortfall when trimming, as a share of the overnight margin, so a move
    /// or a margin change overnight doesn't tip it over again.
    static let reserve = 0.10

    struct Trim: Identifiable, Equatable {
        var symbol: String
        /// Shares held: negative for a short.
        var held: Double
        /// Shares to sell (a long) or buy back (a short).
        var shares: Double
        var id: String { symbol }
        var keeps: Double { held > 0 ? held - shares : held + shares }
    }

    struct Result: Equatable {
        /// The look-ahead available funds or excess liquidity, whichever is lower: below 0, short by that much.
        var room: Double
        var trims: [Trim]
        var fits: Bool { room >= 0 }
    }

    /// The positions it trims: stocks (no forex pairs, which trade on past the close, nor options).
    static func stockPositions(_ positions: [String: Position]) -> [Position] {
        positions.values.filter { (p: Position) -> Bool in
            guard p.quantity != 0, !ForexPair.isForex(p.symbol), !OptionContract.isOption(p.symbol) else { return false }
            return OptionCombo.underlying(of: p.symbol) == nil
        }
        .sorted { $0.symbol < $1.symbol }
    }

    /// What the account looks like after the close, and the trims that would make it fit: every stock
    /// position cut by the same share. The overnight margin a stock position takes is reckoned as its
    /// share of every position's value times IB's look-ahead initial margin; cutting them all by
    /// (shortfall + reserve) / their margin frees that much. nil without IB's figures.
    @MainActor
    static func evaluate(_ broker: Broker) -> Result? {
        let m = broker.margin
        guard let available = m.lookAheadAvailableFunds ?? m.availableFunds else { return nil }
        let room = min(available, m.lookAheadExcessLiquidity ?? m.excessLiquidity ?? available)
        guard room < 0 else { return Result(room: room, trims: []) }
        let stocks = stockPositions(broker.positions)
        guard let overnightMargin = m.lookAheadInitMargin, overnightMargin > 0, !stocks.isEmpty else {
            return Result(room: room, trims: [])
        }
        func value(_ p: Position) -> Double {
            let price = broker.quotes[p.symbol]?.last ?? p.avgCost
            return abs(p.quantity) * price * (broker.usdPerPriceUnit(p.symbol) ?? 1)
        }
        let all = broker.positions.values.filter { $0.quantity != 0 }.map(value).reduce(0, +)
        let stockValue = stocks.map(value).reduce(0, +)
        let share = all > 0 ? stockValue / all : 1
        let cut = min(1, (-room + reserve * overnightMargin) / max(overnightMargin * share, 1))
        let trims = stocks.map { p in
            Trim(symbol: p.symbol, held: p.quantity, shares: min(abs(p.quantity), (abs(p.quantity) * cut).rounded(.up)))
        }
        return Result(room: room, trims: trims.filter { $0.shares >= 1 })
    }
}

// MARK: - The close

extension MarketSession {
    private static let newYork = TimeZone(identifier: "America/New_York")!

    /// The regular session's close on `date`'s New York day: 16:00 ET, or 13:00 ET on NYSE's early
    /// closes (July 3, the day after Thanksgiving, Christmas Eve); nil on weekends and NYSE holidays.
    static func regularClose(on date: Date = Date()) -> Date? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = newYork
        let c = cal.dateComponents([.year, .month, .day, .weekday], from: date)
        guard let y = c.year, let month = c.month, let day = c.day, let weekday = c.weekday,
              (2...6).contains(weekday), !isHoliday(year: y, month: month, day: day, cal) else { return nil }
        let early = (month == 7 && day == 3) || (month == 12 && day == 24)
            || (month == 11 && day == nthWeekday(4, 5, month: 11, year: y, cal) + 1)
        return cal.date(bySettingHour: early ? 13 : 16, minute: 0, second: 0, of: date)
    }

    /// NYSE's full-day holidays, a Saturday's moved to the Friday before (not New Year's) and a
    /// Sunday's to the Monday after.
    private static func isHoliday(year y: Int, month: Int, day: Int, _ cal: Calendar) -> Bool {
        func weekday(_ m: Int, _ d: Int) -> Int {
            cal.component(.weekday, from: cal.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!)
        }
        func observed(_ m: Int, _ d: Int, movesBack: Bool = true) -> (Int, Int)? {
            switch weekday(m, d) {
            case 7: movesBack ? (m, d - 1) : nil
            case 1: (m, d + 1)
            default: (m, d)
            }
        }
        let easter = easterSunday(y)
        let goodFriday = cal.date(byAdding: .day, value: -2,
                                  to: cal.date(from: DateComponents(year: y, month: easter.month, day: easter.day, hour: 12))!)!
        let lastMondayOfMay = 31 - (weekday(5, 31) + 5) % 7
        let days: [(Int, Int)?] = [
            observed(1, 1, movesBack: false),
            (1, nthWeekday(3, 2, month: 1, year: y, cal)),              // Martin Luther King Jr. Day
            (2, nthWeekday(3, 2, month: 2, year: y, cal)),              // Presidents' Day
            (cal.component(.month, from: goodFriday), cal.component(.day, from: goodFriday)),
            (5, lastMondayOfMay),                                       // Memorial Day
            observed(6, 19),                                            // Juneteenth
            observed(7, 4),
            (9, nthWeekday(1, 2, month: 9, year: y, cal)),              // Labor Day
            (11, nthWeekday(4, 5, month: 11, year: y, cal)),            // Thanksgiving
            observed(12, 25),
        ]
        return days.contains { $0.map { $0 == (month, day) } ?? false }
    }

    /// The day of the month of its `n`th `weekday` (1 Sunday … 7 Saturday).
    private static func nthWeekday(_ n: Int, _ weekday: Int, month: Int, year: Int, _ cal: Calendar) -> Int {
        let first = cal.component(.weekday, from: cal.date(from: DateComponents(year: year, month: month, day: 1, hour: 12))!)
        return 1 + (weekday - first + 7) % 7 + 7 * (n - 1)
    }

    /// Easter Sunday (the Gregorian computus).
    private static func easterSunday(_ y: Int) -> (month: Int, day: Int) {
        let a = y % 19, b = y / 100, c = y % 100, d = b / 4, e = b % 4, f = (b + 8) / 25, g = (b - f + 1) / 3
        let h = (19 * a + b - d - g + 15) % 30, i = c / 4, k = c % 4
        let l = (32 + 2 * e + 2 * i - h - k) % 7, m = (a + 11 * h + 22 * l) / 451
        return ((h + l - 7 * m + 114) / 31, (h + l - 7 * m + 114) % 31 + 1)
    }
}
