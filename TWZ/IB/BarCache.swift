//
//  BarCache.swift
//  TWZ
//
//  A chart's bars, on every timeframe, kept in memory when it moves off them, to another
//  timeframe or stock, so a chart coming back to them shows them at once instead of Loading…, while
//  IB's fresh bars load behind them (see `Broker.loadChart`). Nothing is downloaded for it: only bars a
//  chart already showed are kept, as far back as a chart first loads (`Key.span`). A chart
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

        var isKept: Bool { !symbol.isEmpty }

        /// How far back from its newest bar a series is kept: about what a chart first loads
        /// (`Timeframe.compactDuration`), but a day of 5m.
        var span: TimeInterval {
            let day: TimeInterval = 24 * 3600
            switch timeframe {
            case .m1, .m5: return day
            case .m15: return 5 * day
            case .h1: return 10 * day
            case .d1: return 183 * day
            }
        }
    }

    /// Series kept at most, some 60 stocks on every timeframe: 10–25 MB of bars when full (64 bytes a bar).
    static let capacity = 300

    private var series: [Key: (bars: [Bar], kept: Int)] = [:]
    private var keeps = 0

    /// The series kept, their bars, and those bars' size in bytes.
    struct Usage {
        var series = 0
        var bars = 0
        var bytes = 0
    }

    var usage: Usage {
        let bars = series.values.reduce(0) { $0 + $1.bars.count }
        return Usage(series: series.count, bars: bars, bytes: bars * MemoryLayout<Bar>.stride)
    }

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
