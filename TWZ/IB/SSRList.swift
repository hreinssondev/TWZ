//
//  SSRList.swift
//  TWZ
//
//  Nasdaq's daily Rule 201 list: every Nasdaq-listed stock under the short sale restriction today,
//  those carried over from yesterday (stamped 9:30 AM) and those triggered today as it happens.
//  It covers Nasdaq-listed stocks only; the engine works out the rest from IB's prices (see
//  `TradingEngine.ssr`). Reloaded every 5 minutes.
//

import Foundation
import Observation

@Observable
final class SSRList {
    /// Symbol → when it was triggered, as Nasdaq writes it ("11/12/2026 9:30:08 AM", ET).
    private(set) var triggers: [String: String] = [:] { didSet { onChange?(Set(triggers.keys)) } }
    /// Told the restricted symbols whenever the list changes (the engine prices short sales by it).
    @ObservationIgnored var onChange: ((Set<String>) -> Void)?

    private static let refresh: Duration = .seconds(5 * 60)

    /// Keeps the list loaded while the app runs.
    func keepLoaded() async {
        while !Task.isCancelled {
            await load()
            try? await Task.sleep(for: Self.refresh)
        }
    }

    private func load() async {
        let day = MarketSession.dayKey()
        guard let url = URL(string: "https://www.nasdaqtrader.com/dynamic/symdir/shorthalts/shorthalts\(day).txt"),
              let (data, response) = try? await URLSession.shared.data(from: url) else { return }
        // No file on days without trading: nothing is restricted.
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            if !triggers.isEmpty { triggers = [:] }
            return
        }
        let parsed = await Task.detached { Self.parse(data) }.value
        if triggers != parsed { triggers = parsed }
    }

    /// "Symbol,Security Name,Market Category,Trigger Time", one row per stock (names may be quoted
    /// and hold commas, so the symbol is the first field and the time the last), then a timestamp line.
    private nonisolated static func parse(_ data: Data) -> [String: String] {
        guard let text = String(data: data, encoding: .utf8) else { return [:] }
        var triggers: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline).dropFirst() {
            guard let first = line.firstIndex(of: ","), let last = line.lastIndex(of: ","), first < last else { continue }
            triggers[String(line[..<first])] = String(line[line.index(after: last)...])
        }
        return triggers
    }
}
