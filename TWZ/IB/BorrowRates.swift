//
//  BorrowRates.swift
//  TWZ
//
//  IB's short stock file: for every US stock it lends, the borrow fee, the rebate and the shares
//  it has to lend. IB publishes it on its FTP server (user "shortstock", no password) and updates it
//  about every 15 minutes; the API itself has no borrow fee. Loaded when the Borrow tab shows.
//

import Foundation
import Observation

nonisolated struct BorrowRate: Equatable, Sendable {
    var name: String
    /// Annual borrow fee and rebate, in percent; nil where IB lists "NA".
    var feeRate: Double?
    var rebateRate: Double?
    /// Shares IB has to lend; IB caps the figure (">10000000"), marked by `availableIsCapped`.
    var available: Double?
    var availableIsCapped = false
}

@Observable
final class BorrowRates {
    private(set) var rates: [String: BorrowRate] = [:]
    /// The file's own timestamp, e.g. "2026.11.13 06:17:54".
    private(set) var fileTime: String?
    private(set) var isLoading = false
    private(set) var error: String?
    @ObservationIgnored private var loaded: Date?

    private static let url = URL(string: "ftp://shortstock:@ftp2.interactivebrokers.com/usa.txt")!
    private static let maxAge: TimeInterval = 15 * 60

    /// Loads the file unless this copy is under 15 minutes old.
    func refreshIfStale() {
        if let loaded, Date().timeIntervalSince(loaded) < Self.maxAge { return }
        refresh()
    }

    func refresh() {
        guard !isLoading else { return }
        isLoading = true
        Task {
            defer { isLoading = false }
            do {
                // FTP is deprecated in URLSession but still works, and it's the only place IB publishes this.
                let (data, _) = try await URLSession.shared.data(from: Self.url)
                let parsed = await Task.detached { Self.parse(data) }.value
                guard !parsed.rates.isEmpty else { throw URLError(.cannotParseResponse) }
                rates = parsed.rates
                fileTime = parsed.time
                loaded = Date()
                error = nil
            } catch {
                self.error = "Couldn't load IB's borrow rates (\(error.localizedDescription))"
            }
        }
    }

    /// "#BOF|2026.11.13|06:17:54", then "#SYM|CUR|NAME|CON|ISIN|REBATERATE|FEERATE|AVAILABLE|…" and
    /// one row per stock.
    private nonisolated static func parse(_ data: Data) -> (rates: [String: BorrowRate], time: String?) {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return ([:], nil) }
        var rates: [String: BorrowRate] = [:]
        var time: String?
        var column: [String: Int] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let f = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            if f.first == "#BOF" {
                time = f.dropFirst().prefix(2).joined(separator: " ")
                continue
            }
            if f.first == "#SYM" {
                for (i, name) in f.enumerated() { column[name.replacingOccurrences(of: "#", with: "")] = i }
                continue
            }
            guard !column.isEmpty, let sym = f.first, !sym.hasPrefix("#") else { continue }
            func field(_ name: String) -> String { column[name].flatMap { $0 < f.count ? f[$0] : nil } ?? "" }
            let available = field("AVAILABLE")
            rates[sym] = BorrowRate(
                name: field("NAME").replacingOccurrences(of: "&amp;", with: "&"),
                feeRate: Double(field("FEERATE")),
                rebateRate: Double(field("REBATERATE")),
                available: Double(available.trimmingCharacters(in: CharacterSet(charactersIn: "> "))),
                availableIsCapped: available.hasPrefix(">"))
        }
        return (rates, time)
    }
}
