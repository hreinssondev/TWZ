//
//  TieredCommissions.swift
//  TWZ
//
//  What a fill's commissions and fees would have been on IBKR Pro Tiered, shown beside what IB
//  charged: the paper account charges Fixed whatever the live account is set to. A glimpse only;
//  nothing else uses it.
//
//  Per fill, from IB's US stock pricing (Tiered, November 2026):
//  - IBKR commission: $0.0035 a share up to 300 000 shares in the month, then $0.0020 to 3M,
//    $0.0015 to 20M, $0.0010 to 100M, $0.0005 beyond; per order at least $0.35, at most 1% of its value.
//  - Pass-through fees: NYSE 0.000175 and FINRA 0.00056 of that commission.
//  - Clearing (NSCC, DTC): $0.00020 a share.
//  - Exchange fee, by the venue IB reports and whether the fill added liquidity or removed it.
//  - Regulatory fees (SEC on sales, FINRA TAF and CAT), the same on either plan: what IB charged
//    for the fill less Fixed's own $0.005 a share ($1.00 at least per order), so IB's numbers.
//  The month's volume carries over days: each ET day's shares are kept per account, and on first
//  use in a month the days before today are read from the order logs (kept a week).
//

import Foundation

nonisolated enum TieredCommissions {
    /// Each fill's commissions and fees on Tiered, in dollars, by execId; only fills IB has sent a
    /// commission report for (the regulatory fees come from it).
    static func estimate(fills: [Fill], monthSharesBefore: Double) -> [String: Double] {
        struct Order { var shares = 0.0, value = 0.0, base = 0.0, commission = 0.0, fixed = 0.0 }
        var month = monthSharesBefore
        var orders: [String: Order] = [:]
        var estimates: [String: Double] = [:]
        for f in fills.sorted(by: { ($0.time, $0.id) < ($1.time, $1.id) }) where f.shares > 0 {
            let key = f.symbol + " " + RoundTrip.orderKey(f)
            var o = orders[key] ?? Order()
            o.base += baseCommission(shares: f.shares, monthSharesBefore: month)
            month += f.shares
            o.shares += f.shares
            o.value += f.shares * f.price
            // The order's minimum and maximum, then this fill's part of it.
            let commission = min(max(o.base, minPerOrder), maxShareOfValue * o.value)
            let ibkr = commission - o.commission
            // The paper account's Fixed charge leaves out Fixed's 1% maximum (sub-$0.50 stocks show it).
            let fixed = max(1.0, 0.005 * o.shares)
            let fixedPart = fixed - o.fixed
            o.commission = commission
            o.fixed = fixed
            orders[key] = o
            guard let charged = f.commission else { continue }
            let regulatory = max(0, charged - fixedPart)
            estimates[f.id] = ibkr * (1 + passThroughShare) + clearingPerShare * f.shares
                + exchangeFee(venue: f.exchange, liquidity: f.liquidity, price: f.price, shares: f.shares) + regulatory
        }
        return estimates
    }

    private static let tiers: [(upTo: Double, rate: Double)] = [
        (300_000, 0.0035), (3_000_000, 0.0020), (20_000_000, 0.0015), (100_000_000, 0.0010), (.infinity, 0.0005),
    ]
    private static let minPerOrder = 0.35
    private static let maxShareOfValue = 0.01
    private static let passThroughShare = 0.000175 + 0.00056
    private static let clearingPerShare = 0.00020

    /// The commission for `shares` at the month's tier rates, splitting at a tier break.
    private static func baseCommission(shares: Double, monthSharesBefore: Double) -> Double {
        var left = shares, at = monthSharesBefore, total = 0.0
        for tier in tiers where left > 0 && at < tier.upTo {
            let n = min(left, tier.upTo - at)
            total += n * tier.rate
            left -= n
            at += n
        }
        return total
    }

    /// The venue's fee (negative: a rebate). `liquidity` is IB's: 1 added, 2 removed, 3 routed out;
    /// unknown counts as removed. Under $1.00 removing costs 0.30% of the value and adding earns nothing.
    private static func exchangeFee(venue: String, liquidity: Int, price: Double, shares: Double) -> Double {
        let added = liquidity == 1
        if price < 1 { return added ? 0 : 0.003 * price * shares }
        let perShare = switch venue {
        case "IEX": 0.0009
        case "T24X": added ? -0.00295 : 0.00295
        case "ARCA": added ? -0.0020 : 0.0030
        default: added ? -0.0016 : 0.0030   // BATS, Direct Edge and most others
        }
        return perShare * shares
    }

    // MARK: - Month's volume

    private static func storeKey(_ account: String) -> String { "tieredMonthShares.\(account)" }
    private static func seededKey(_ account: String) -> String { "tieredMonthShares.seeded.\(account)" }

    /// Shares filled in the month before ET day `day` ("yyyyMMdd").
    static func monthShares(before day: String, account: String) -> Double {
        let days = UserDefaults.standard.dictionary(forKey: storeKey(account)) as? [String: Double] ?? [:]
        return days.filter { $0.key.prefix(6) == day.prefix(6) && $0.key < day }.values.reduce(0, +)
    }

    /// Keeps each ET day's shares from `fills` (the day's so far), dropping earlier months; on the
    /// month's first use, adds the days before from the order logs.
    static func record(_ fills: [Fill], account: String) {
        guard !account.isEmpty, let first = fills.map(\.time).min() else { return }
        let defaults = UserDefaults.standard
        let firstDay = MarketSession.dayKey(first)
        let month = String(firstDay.prefix(6))
        var days = (defaults.dictionary(forKey: storeKey(account)) as? [String: Double] ?? [:])
            .filter { $0.key.prefix(6) == month }
        if defaults.string(forKey: seededKey(account)) != month {
            for (day, shares) in sharesInOrderLogs(month: month, before: firstDay) { days[day] = max(days[day] ?? 0, shares) }
            defaults.set(month, forKey: seededKey(account))
        }
        for (day, dayFills) in Dictionary(grouping: fills, by: { MarketSession.dayKey($0.time) }) where day.prefix(6) == month {
            days[day] = max(days[day] ?? 0, dayFills.reduce(0) { $0 + $1.shares })
        }
        if days != defaults.dictionary(forKey: storeKey(account)) as? [String: Double] {
            defaults.set(days, forKey: storeKey(account))
        }
    }

    /// Shares per ET day from the order logs' FILL lines, each execution once.
    private static func sharesInOrderLogs(month: String, before day: String) -> [String: Double] {
        let fm = FileManager.default
        let directory = OrderLog.shared.directory
        guard let files = try? fm.contentsOfDirectory(atPath: directory.path) else { return [:] }
        let dateFormat = DateFormatter()
        dateFormat.locale = Locale(identifier: "en_US_POSIX")
        dateFormat.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        // "12:18:36.991  FILL #2423 BOT 100 SVRE @ 0,9651 exec 00025b49.6b01738a.01.01"
        let fill = #/^(\S+)  FILL #\S+ (?:BOT|SLD) (.+?) \S+ @ \S+ exec (\S+)$/#
        var seen = Set<String>()
        var days: [String: Double] = [:]
        for file in files where file.hasPrefix("orders-") && file.hasSuffix(".log") {
            let date = file.dropFirst("orders-".count).dropLast(".log".count)
            guard let text = try? String(contentsOf: directory.appendingPathComponent(file), encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") where line.contains("  FILL #") {
                guard let m = try? fill.wholeMatch(in: line), !seen.contains(String(m.3)),
                      let time = dateFormat.date(from: "\(date) \(m.1)"), let shares = parseShares(m.2) else { continue }
                let lineDay = MarketSession.dayKey(time)
                guard lineDay.prefix(6) == month, lineDay < day else { continue }
                seen.insert(String(m.3))
                days[lineDay, default: 0] += shares
            }
        }
        return days
    }

    /// A share count as `Fmt.shares` writes it in any locale ("2 016", "2,016", "12,5").
    private static func parseShares(_ text: Substring) -> Double? {
        let s = text.filter { $0.isNumber || $0 == "," || $0 == "." }
        // Up to two decimals after the last separator; anything else is grouping.
        if let sep = s.lastIndex(where: { $0 == "," || $0 == "." }), s.distance(from: sep, to: s.endIndex) <= 3 {
            return Double(s[..<sep].filter(\.isNumber) + "." + s[s.index(after: sep)...])
        }
        return Double(s.filter(\.isNumber))
    }
}
