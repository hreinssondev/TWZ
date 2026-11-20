//
//  BarCache.swift
//  TWZ
//
//  The last day of 1m and 5m bars of the stocks the chart grids follow (the main grid's list and the
//  Charts window's top gainers), kept in memory when a chart moves off them, so coming back shows them
//  at once instead of Loading…, while IB's fresh bars load behind them (see `Broker.loadChart`).
//  Going from 1m to 5m in the same stock, its live 1m bars also bring the kept 5m bars up to date, or
//  make them the first time. A stock off both lists drops its bars the next time a chart moves.
//

import Foundation

struct BarCache {
    /// What a chart's bars are of.
    struct Key: Hashable {
        var symbol: String
        var timeframe: Timeframe

        /// Only 1m and 5m bars are kept.
        var isKept: Bool { !symbol.isEmpty && (timeframe == .m1 || timeframe == .m5) }
    }

    /// How far back from its newest bar a series is kept.
    static let span: TimeInterval = 24 * 3600

    private var series: [Key: [Bar]] = [:]

    /// Keeps the last day of the bars a chart showed for `key`, if it's a followed stock's 1m or 5m, and
    /// drops the bars of stocks no longer followed.
    mutating func keep(_ bars: [Bar], for key: Key, followed: Set<String>) {
        series = series.filter { followed.contains($0.key.symbol) }
        guard key.isKept, followed.contains(key.symbol), let newest = bars.last?.time else { return }
        let from = newest.addingTimeInterval(-Self.span)
        series[key] = Array(bars.drop { $0.time < from })
    }

    /// The bars a chart about to show `key` starts with (none: it loads as usual): those kept, made up
    /// to date from the 1m bars it showed (`previous`) when it goes from 1m to 5m in the same stock.
    func bars(for key: Key, previous: Key, previousBars: [Bar], followed: Set<String>) -> [Bar] {
        guard key.isKept, followed.contains(key.symbol), previous != key else { return [] }
        let kept = series[key] ?? []
        guard key.timeframe == .m5, previous == Key(symbol: key.symbol, timeframe: .m1), !previousBars.isEmpty else { return kept }
        return Self.fiveMinute(previousBars, after: kept)
    }

    /// 5m bars made from 1m bars, after the 5m bars `kept` from before them: from the first 5 minutes
    /// the 1m bars cover on, the made ones take over (a first 5 minutes they cover only partly stays
    /// the kept bar, if there is one).
    static func fiveMinute(_ minutes: [Bar], after kept: [Bar]) -> [Bar] {
        var made: [Bar] = []
        for m in minutes {
            let start = Date(timeIntervalSince1970: (m.time.timeIntervalSince1970 / 300).rounded(.down) * 300)
            if let last = made.last, last.time == start {
                made[made.count - 1].high = max(last.high, m.high)
                made[made.count - 1].low = min(last.low, m.low)
                made[made.count - 1].close = m.close
                made[made.count - 1].volume += m.volume
            } else {
                made.append(Bar(time: start, open: m.open, high: m.high, low: m.low, close: m.close, volume: m.volume))
            }
        }
        if let first = minutes.first, let bucket = made.first, first.time != bucket.time,
           kept.contains(where: { $0.time == bucket.time }) {
            made.removeFirst()
        }
        guard let from = made.first?.time else { return kept }
        return kept.filter { $0.time < from } + made
    }
}
