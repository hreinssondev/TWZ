//
//  BarCache.swift
//  TWZ
//
//  1m, 5m and 1h bars kept in memory when a chart moves off them, to another
//  timeframe or stock, so a chart coming back to them shows them at once instead of Loading…, while
//  IB's fresh bars load behind them (see `Broker.loadChart`). Nothing is downloaded for it: only bars a
//  chart already showed are kept, the last day of them (of 1h, the 10 days it loads). A chart
//  showing the same bars live gives them instead, and going from 1m to 5m in the same stock, its live
//  1m bars bring the kept 5m bars up to date, or make them the first time. Up to `capacity` series;
//  past that, the one kept longest ago goes.
//

import Foundation

struct BarCache {
    /// What a chart's bars are of.
    struct Key: Hashable {
        var symbol: String
        var timeframe: Timeframe

        /// 1m, 5m and 1h bars are kept.
        var isKept: Bool {
            guard !symbol.isEmpty else { return false }
            switch timeframe {
            case .m1, .m5, .h1: return true
            case .m15, .d1: return false
            }
        }

        /// How far back from its newest bar a series is kept.
        var span: TimeInterval { timeframe == .h1 ? 10 * 24 * 3600 : 24 * 3600 }
    }

    /// Series kept at most: some 10–20 MB of bars when full (about 64 bytes a bar).
    static let capacity = 200

    private var series: [Key: (bars: [Bar], kept: Int)] = [:]
    private var keeps = 0

    /// Keeps the last of the bars a chart showed for `key` (see `Key.span`), if they're kept at all.
    mutating func keep(_ bars: [Bar], for key: Key) {
        guard key.isKept, let newest = bars.last?.time, let oldest = bars.first?.time else { return }
        let from = newest.addingTimeInterval(-key.span)
        keeps += 1
        // Shared with the chart's own until either changes, unless older bars are cut off.
        series[key] = (oldest >= from ? bars : Array(bars.drop { $0.time < from }), keeps)
        if series.count > Self.capacity, let oldestKept = series.min(by: { $0.value.kept < $1.value.kept })?.key {
            series[oldestKept] = nil
        }
    }

    /// The bars a chart about to show `key` starts with (none: it loads as usual): `live`, another
    /// chart's showing them now; or those kept, made up to date from the 1m bars it showed
    /// (`previous`) when it goes from 1m to 5m in the same stock.
    func bars(for key: Key, previous: Key, previousBars: [Bar], live: [Bar]?) -> [Bar] {
        guard key.isKept, previous != key else { return [] }
        if let live, !live.isEmpty { return live }
        let kept = series[key]?.bars ?? []
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
