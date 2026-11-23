//
//  LivePush.swift
//  TWZ
//
//  Keeps TWZ-iOS's positions Live Activity (lock screen, Dynamic Island) current: the iPhone app hands
//  over the activity's push token (on the widget port, see `SimShare`), and every few seconds the open
//  positions' P/L goes to it through Apple's push service, when it moved. Signed with the APNs key put in
//  TWZ's own Application Support/TWZ/APNs (AuthKey_<key id>.p8); never in the repo. Nothing without one.
//

import CryptoKit
import Foundation

@MainActor
final class LivePush {
    static let shared = LivePush()

    private static let teamID = "8FB39RNRQQ"
    private static let topic = "dev.hreinsson.TWZ-iOS.push-type.liveactivity"
    private static let tokenKey = "livePushToken"
    /// Xcode-installed builds get pushes from Apple's sandbox.
    private static let host = "https://api.sandbox.push.apple.com"
    /// The fastest it sends, and how far the P/L moves (NOK) before it does.
    private static let interval: TimeInterval = 5
    private static let minimumMove = 1.0

    weak var broker: Broker?
    private var timer: Timer?
    private var token: String? = UserDefaults.standard.string(forKey: LivePush.tokenKey)
    private var lastSent: (total: Double?, rows: [String], at: Date)?
    private var jwt: (value: String, made: Date)?

    func start(broker: Broker) {
        self.broker = broker
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { _ in
            MainActor.assumeIsolated { LivePush.shared.tick() }
        }
    }

    /// The Live Activity's push token, from the iPhone app; nil when it ended.
    func setToken(_ token: String?) {
        self.token = token
        UserDefaults.standard.set(token, forKey: Self.tokenKey)
        lastSent = nil
        tick()
    }

    /// The positions' P/L to the Live Activity, when it moved (and at least every 5 minutes, so it isn't stale).
    private func tick() {
        guard let token, let broker else { return }
        let (isSim, rows) = SimShare.positionRows(broker)
        let total = rows.isEmpty ? nil : rows.reduce(Optional(0.0)) { t, row in t.flatMap { a in row.pnl.map { a + $0 } } }
        let symbols = rows.map(\.symbol)
        if let last = lastSent, last.rows == symbols, Date().timeIntervalSince(last.at) < 300,
           abs((last.total ?? .nan) - (total ?? .nan)) < Self.minimumMove || (last.total == nil && total == nil) { return }
        lastSent = (total, symbols, Date())
        let now = Date().timeIntervalSince1970
        var state: [String: Any] = [
            "isSim": isSim,
            "rows": rows.prefix(4).map { row -> [String: Any] in
                var r: [String: Any] = ["symbol": row.symbol]
                if let pnl = row.pnl { r["pnl"] = pnl }
                return r
            },
            "updated": now,
        ]
        if let total { state["total"] = total }
        let body: [String: Any] = ["aps": ["timestamp": Int(now), "event": "update", "content-state": state,
                                           "stale-date": Int(now + 600)]]
        send(body, to: token)
    }

    private func send(_ body: [String: Any], to token: String) {
        guard let jwt = makeJWT(), let url = URL(string: "\(Self.host)/3/device/\(token)"),
              let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue("bearer \(jwt)", forHTTPHeaderField: "authorization")
        request.setValue("liveactivity", forHTTPHeaderField: "apns-push-type")
        request.setValue(Self.topic, forHTTPHeaderField: "apns-topic")
        request.setValue("10", forHTTPHeaderField: "apns-priority")
        URLSession.shared.dataTask(with: request) { data, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status != 200 else { return }
            let reason = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            Task { @MainActor in
                OrderLog.shared.write("LIVE ACTIVITY push \(status) \(reason)")
                // The activity ended or its token is no good: stop until the app hands over a new one.
                if status == 410 || reason.contains("BadDeviceToken") { LivePush.shared.setToken(nil) }
            }
        }.resume()
    }

    /// The provider token APNs wants: ES256 over the key in Application Support/TWZ/APNs, made again
    /// every 50 minutes (APNs takes one for up to an hour).
    private func makeJWT() -> String? {
        if let jwt, Date().timeIntervalSince(jwt.made) < 50 * 60 { return jwt.value }
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TWZ/APNs", isDirectory: true)
        guard let file = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))?
                .first(where: { $0.lastPathComponent.hasPrefix("AuthKey_") && $0.pathExtension == "p8" }),
              let pem = try? String(contentsOf: file, encoding: .utf8),
              let key = try? P256.Signing.PrivateKey(pemRepresentation: pem) else { return nil }
        let keyID = file.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "AuthKey_", with: "")
        func base64URL(_ data: Data) -> String {
            data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let header = base64URL(Data(#"{"alg":"ES256","kid":"\#(keyID)"}"#.utf8))
        let claims = base64URL(Data(#"{"iss":"\#(Self.teamID)","iat":\#(Int(Date().timeIntervalSince1970))}"#.utf8))
        guard let signature = try? key.signature(for: Data("\(header).\(claims)".utf8)) else { return nil }
        let value = "\(header).\(claims).\(base64URL(signature.rawRepresentation))"
        jwt = (value, Date())
        return value
    }
}
