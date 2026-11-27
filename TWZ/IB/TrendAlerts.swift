//
//  TrendAlerts.swift
//  TWZ
//
//  Trend line alerts: when a stock's last price reaches one of its trend lines (⌘⇧-click, see `TrendLines`),
//  coming from either side, a sound, a message in the floating message tab and a notification. A line alerts
//  once, and again after the price has moved `TrendLines.rearmShare` away from it. The trend lines' stocks
//  keep a quote stream while they have lines, so they alert off the charts too. Settings › Appearance turns
//  the alerts off.
//

import AppKit
import UserNotifications

extension Broker {
    static let trendQuoteOwner = "trend-lines"

    /// The trend lines to watch (`Workspace.trendLines`), on every change.
    func setTrendLines(_ lines: [String: [Double]]) {
        trendAlertLines = lines.filter { !$0.value.isEmpty }
        trendAlertLast = trendAlertLast.filter { trendAlertLines[$0.key] != nil }
        trendAlertsFired = trendAlertsFired.reduce(into: [:]) { kept, entry in
            let still = entry.value.intersection(trendAlertLines[entry.key] ?? [])
            if !still.isEmpty { kept[entry.key] = still }
        }
        setQuoteSymbols(trendAlertLines.keys.sorted(), owner: Self.trendQuoteOwner)
        if !trendAlertLines.isEmpty { TrendAlertNotifier.shared.prepare() }
    }

    /// On every quote update: the lines the last price has reached since the previous one.
    func checkTrendAlerts() {
        guard UserDefaults.standard.object(forKey: TrendLines.alertKey) as? Bool ?? TrendLines.defaultAlert else {
            trendAlertLast = [:]
            return
        }
        for (symbol, prices) in trendAlertLines {
            guard let last = quotes[symbol]?.last, last > 0 else { continue }
            let previous = trendAlertLast[symbol]
            guard previous != last else { continue }
            trendAlertLast[symbol] = last
            var fired = trendAlertsFired[symbol] ?? []
            for price in prices {
                if fired.contains(price) {
                    if abs(last - price) >= price * TrendLines.rearmShare { fired.remove(price) }
                    continue
                }
                guard let previous else { continue }
                if (previous < price && last >= price) || (previous > price && last <= price) {
                    fired.insert(price)
                    alertTrendLine(symbol: symbol, price: price, rising: last > previous)
                }
            }
            trendAlertsFired[symbol] = fired.isEmpty ? nil : fired
        }
    }

    private func alertTrendLine(symbol: String, price: Double, rising: Bool) {
        let line = Fmt.price(price, for: symbol)
        logMessage("\(symbol) reached its trend line at \(line) \(rising ? "↑" : "↓")")
        // At half volume.
        if let sound = NSSound(named: "Glass") {
            sound.volume = 0.5
            sound.play()
        }
        TrendAlertNotifier.shared.post(title: "\(symbol) at \(line)",
                                       body: "\(rising ? "Rose" : "Fell") to its trend line at \(line)")
        onTrendAlert?(symbol, price)
    }
}

/// Posts the alerts as notifications, shown as banners even while TWZ is in front.
final class TrendAlertNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = TrendAlertNotifier()
    private var prepared = false

    /// Asks once for permission to show notifications.
    func prepare() {
        guard !prepared else { return }
        prepared = true
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(title: String, body: String) {
        prepare()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        // The sound is played by the app (see `alertTrendLine`).
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}
