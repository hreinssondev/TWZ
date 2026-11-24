//
//  News.swift
//  TWZ
//
//  Headlines from IB's free news providers: Briefing.com's market columns (BRFG) and analyst up- and
//  downgrades (BRFUPDN), and Dow Jones' newsletters (DJNL). Paid feeds are left out, even ones the
//  account has. The News tab shows them (see `NewsTab`); the lists mark stocks with news since the
//  last close.
//

import Foundation

nonisolated enum News {
    /// The free providers, as IB names them.
    static let providers = ["BRFG", "BRFUPDN", "DJNL"]
    /// The providers with a feed of all their news (BRFUPDN only has its stocks').
    static let broadtapes = ["BRFG", "DJNL"]
    /// The feed key of all news (`TradingEngine.news`), rather than one stock's.
    static let allFeed = "*"

    static func providerName(_ code: String) -> String {
        switch code {
        case "BRFG": "Briefing"
        case "BRFUPDN": "Analysts"
        case "DJNL": "Dow Jones"
        default: code
        }
    }

    /// IB's headline without its language tag ("{A:800015:L:en}") or the "!" some start with.
    static func cleanHeadline(_ raw: String) -> String {
        var s = Substring(raw)
        if s.hasPrefix("{"), let end = s.firstIndex(of: "}") { s = s[s.index(after: end)...] }
        while s.hasPrefix("!") { s = s.dropFirst() }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// The last regular-session close before today (ET): the weekday before's 16:00. Holidays aren't
    /// skipped, so after one the window is a day short.
    static func lastClose(before date: Date = Date()) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        var day = cal.startOfDay(for: date)
        repeat {
            day = cal.date(byAdding: .day, value: -1, to: day)!
        } while cal.isDateInWeekend(day)
        return cal.date(bySettingHour: 16, minute: 0, second: 0, of: day)!
    }

    /// An article's HTML as plain paragraphs, and the first link in it (Dow Jones' newsletters are a
    /// link to the full text).
    static func plainText(fromHTML html: String) -> (text: String, link: URL?) {
        var link: URL?
        let ns = html as NSString
        if let match = try? NSRegularExpression(pattern: #"href\s*=\s*["']?([^"'\s>]+)"#, options: .caseInsensitive)
            .firstMatch(in: html, range: NSRange(location: 0, length: ns.length)) {
            link = URL(string: ns.substring(with: match.range(at: 1)))
        }
        var s = html
        s = s.replacingOccurrences(of: #"<!--.*?-->"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?i)<br\s*/?>"#, with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?i)</(p|div|li|h[1-6]|tr)>"#, with: "\n\n", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?i)<li[^>]*>"#, with: "• ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        s = decodeEntities(s)
        s = s.replacingOccurrences(of: #"[ \t\u00A0]+"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #" *\n *"#, with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return (s.trimmingCharacters(in: .whitespacesAndNewlines), link)
    }

    private static let entities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
        "mdash": "—", "ndash": "–", "rsquo": "’", "lsquo": "‘", "rdquo": "”", "ldquo": "“", "hellip": "…",
    ]

    private static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        var rest = Substring(s)
        while let amp = rest.firstIndex(of: "&") {
            out += rest[..<amp]
            let after = rest[rest.index(after: amp)...]
            if let semi = after.prefix(10).firstIndex(of: ";") {
                let name = after[..<semi]
                var decoded: String?
                if name.hasPrefix("#x") || name.hasPrefix("#X") {
                    decoded = UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
                } else if name.hasPrefix("#") {
                    decoded = UInt32(name.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
                } else {
                    decoded = entities[String(name)]
                }
                if let decoded {
                    out += decoded
                    rest = after[after.index(after: semi)...]
                    continue
                }
            }
            out += "&"
            rest = after
        }
        return out + rest
    }
}

/// One headline.
nonisolated struct NewsItem: Identifiable, Equatable, Sendable {
    /// IB's article id ("BRFG$1fe0997a").
    let id: String
    let provider: String
    let time: Date
    let headline: String
}

/// An article as IB sent it: text (HTML, made plain), or a PDF.
nonisolated struct NewsArticle: Equatable, Sendable {
    var text: String?
    var link: URL?
    var pdf: Data?
    var error: String?
}
