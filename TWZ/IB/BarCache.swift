//
//  BarCache.swift
//  TWZ
//
//  A chart's bars, on every timeframe, kept in memory when it moves off them, to another
//  timeframe or stock, so a chart coming back to them shows them at once instead of Loading…, while
//  IB's fresh bars load behind them (see `Broker.loadChart`); older ones than those fresh bars reach
//  stay in front of them, so a view zoomed far out doesn't load them again. Nothing is downloaded for
//  it: all the bars a chart showed are kept, older ones it loaded included, and on disk too (see
//  `BarStore`), so they're there after a relaunch, for two days. A chart showing the same bars live
//  gives them instead, and going from 1m to 5m in the same stock, its live 1m bars bring the kept 5m
//  bars up to date, or make them the first time. In memory up to `maxBars`; past that, the series
//  kept longest ago goes (it stays on disk).
//

import Foundation

struct BarCache {
    /// What a chart's bars are of.
    struct Key: Hashable, Codable {
        var symbol: String
        var timeframe: Timeframe

        var isKept: Bool { !symbol.isEmpty }

        /// Its file on disk (see `BarStore`).
        var fileName: String { "\(symbol.replacingOccurrences(of: "/", with: "-"))_\(timeframe.rawValue).bars" }
    }

    /// Bars kept in memory at most, about 190 MB (64 bytes a bar).
    static let maxBars = 3_000_000

    private var series: [Key: (bars: [Bar], kept: Int)] = [:]
    private var keeps = 0
    private var totalBars = 0
    private let store = BarStore.shared

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

    /// Keeps the bars a chart showed for `key`, in memory (shared with the chart's own until either
    /// changes) and on disk.
    mutating func keep(_ bars: [Bar], for key: Key) {
        guard key.isKept, !bars.isEmpty else { return }
        put(bars, for: key)
        store.save(bars, name: key.fileName)
    }

    private mutating func put(_ bars: [Bar], for key: Key) {
        keeps += 1
        totalBars += bars.count - (series[key]?.bars.count ?? 0)
        series[key] = (bars, keeps)
        while totalBars > Self.maxBars, series.count > 1,
              let oldest = series.min(by: { $0.value.kept < $1.value.kept })?.key {
            totalBars -= series.removeValue(forKey: oldest)?.bars.count ?? 0
        }
    }

    /// The bars a chart about to show `key` starts with (none: it loads as usual): `live`, another
    /// chart's showing them now; or those kept, made up to date from the 1m bars it showed
    /// (`previous`) when it goes from 1m to 5m in the same stock.
    mutating func bars(for key: Key, previous: Key, previousBars: [Bar], live: [Bar]?) -> [Bar] {
        guard key.isKept, previous != key else { return [] }
        if let live, !live.isEmpty { return live }
        // Not in memory: from disk, as last kept (after a relaunch, say).
        if series[key] == nil, let disk = store.read(name: key.fileName) { put(disk, for: key) }
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
