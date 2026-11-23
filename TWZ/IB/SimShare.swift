//
//  SimShare.swift
//  TWZ
//
//  Lets TWZ-iOS (the iPhone app) see the what-if trades, which live only here: a connection on port
//  4010 gets them as JSON (`Broker.simPositions`) and is closed. Its widget asks on port 4011 for one
//  stock's quote: it sends the symbol and a newline, and gets {symbol, last, prevClose, changePercent}
//  (the stock's quote is kept coming from then on, so the next ask is answered at once); POSITIONS
//  instead of a symbol gets the open positions' P/L (the real ones, else the what-if trades'). Read-only,
//  and only from this Mac or Tailscale's addresses (100.64.0.0/10). Settings › Connection turns it off.
//

import Foundation
import Network

@MainActor
final class SimShare {
    static let shared = SimShare()
    static let port: UInt16 = 4010
    static let quotePort: UInt16 = 4011
    /// The widget's stocks, whose quotes are kept coming (the last few asked for).
    private var widgetSymbols: [String] = []
    private static let widgetQuoteOwner = "ios-widget"
    static let enabledKey = "shareSimWithIOS"
    static var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    weak var broker: Broker?
    private var listener: NWListener?
    private var quoteListener: NWListener?

    func start(broker: Broker) {
        self.broker = broker
        guard Self.isEnabled, listener == nil, let port = NWEndpoint.Port(rawValue: Self.port),
              let listener = try? NWListener(using: .tcp, on: port) else { return }
        listener.newConnectionHandler = { connection in
            MainActor.assumeIsolated { SimShare.shared.serve(connection) }
        }
        listener.start(queue: .main)
        self.listener = listener
        if let quotePort = NWEndpoint.Port(rawValue: Self.quotePort), let quotes = try? NWListener(using: .tcp, on: quotePort) {
            quotes.newConnectionHandler = { connection in
                MainActor.assumeIsolated { SimShare.shared.serveQuote(connection) }
            }
            quotes.start(queue: .main)
            quoteListener = quotes
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        quoteListener?.cancel()
        quoteListener = nil
        widgetSymbols = []
        broker?.setQuoteSymbols([], owner: Self.widgetQuoteOwner)
    }

    /// One stock's quote for the widget, once its symbol and a newline are in; a stock not quoted yet is
    /// asked for and answered once its quote comes (or after 3 s, without one).
    private func serveQuote(_ connection: NWConnection) {
        guard Self.allowed(connection.endpoint), broker != nil else { connection.cancel(); return }
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256) { data, _, _, _ in
            MainActor.assumeIsolated {
                let line = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let symbol = line.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                guard !symbol.isEmpty, symbol.count <= 12 || symbol.hasPrefix("LIVE "), let broker = SimShare.shared.broker else { connection.cancel(); return }
                if symbol == "POSITIONS" { return SimShare.shared.sendPositions(connection, broker: broker) }
                // The Live Activity's push token (see `LivePush`), or END when it's over.
                if symbol.hasPrefix("LIVE ") {
                    let token = String(symbol.dropFirst(5)).lowercased()
                    LivePush.shared.setToken(token == "end" ? nil : token)
                    return connection.send(content: Data("{}".utf8), contentContext: .finalMessage, isComplete: true,
                                           completion: .contentProcessed { _ in connection.cancel() })
                }
                SimShare.shared.keepQuoting(symbol)
                SimShare.shared.answer(connection, symbol: symbol, broker: broker, waited: 0)
            }
        }
    }

    /// The open positions, each with its P/L in NOK: the real ones while any are open, else the what-if
    /// trades (`isSim`); a P/L left out while its stock has no price yet. For the widget and the Live Activity.
    static func positionRows(_ broker: Broker) -> (isSim: Bool, rows: [(symbol: String, pnl: Double?)]) {
        let real = broker.positions.values.filter { $0.quantity != 0 }.sorted { $0.symbol < $1.symbol }
        if real.isEmpty {
            return (true, broker.simPositions.values.sorted { $0.symbol < $1.symbol }.map { sim in
                (sim.symbol, broker.quotes[sim.symbol]?.last.flatMap { broker.simPnLNOK(sim, at: $0) })
            })
        }
        return (false, real.map { p in
            let pnl = broker.quotes[p.symbol]?.last.flatMap { last in
                broker.usdPerPriceUnit(p.symbol).flatMap { usd in broker.usdNok.map { (last - p.avgCost) * p.quantity * usd * $0 } }
            }
            return (p.symbol, pnl)
        })
    }

    /// The positions widget's (see `positionRows`).
    private func sendPositions(_ connection: NWConnection, broker: Broker) {
        let (isSim, positions) = Self.positionRows(broker)
        let rows: [[String: Any]] = positions.map { row in
            var r: [String: Any] = ["symbol": row.symbol]
            if let pnl = row.pnl { r["pnl"] = pnl }
            return r
        }
        let reply: [String: Any] = ["isSim": isSim, "positions": rows, "time": Date().timeIntervalSince1970]
        let data = (try? JSONSerialization.data(withJSONObject: reply)) ?? Data("{}".utf8)
        connection.send(content: data, contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { _ in connection.cancel() })
    }

    private func keepQuoting(_ symbol: String) {
        guard widgetSymbols.first != symbol else { return }
        widgetSymbols.removeAll { $0 == symbol }
        widgetSymbols.insert(symbol, at: 0)
        widgetSymbols = Array(widgetSymbols.prefix(4))
        broker?.setQuoteSymbols(widgetSymbols, owner: Self.widgetQuoteOwner)
    }

    private func answer(_ connection: NWConnection, symbol: String, broker: Broker, waited: Double) {
        let quote = broker.quotes[symbol]
        if quote?.last == nil || quote?.prevClose == nil, waited < 3 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                MainActor.assumeIsolated { SimShare.shared.answer(connection, symbol: symbol, broker: broker, waited: waited + 0.25) }
            }
            return
        }
        var reply: [String: Any] = ["symbol": symbol, "time": Date().timeIntervalSince1970]
        if let last = quote?.last { reply["last"] = last }
        if let prevClose = quote?.prevClose { reply["prevClose"] = prevClose }
        if let change = quote?.changePercent { reply["changePercent"] = change }
        let data = (try? JSONSerialization.data(withJSONObject: reply)) ?? Data("{}".utf8)
        connection.send(content: data, contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { _ in connection.cancel() })
    }

    private func serve(_ connection: NWConnection) {
        guard Self.allowed(connection.endpoint), let broker else { connection.cancel(); return }
        let data = (try? JSONEncoder().encode(broker.simPositions)) ?? Data("{}".utf8)
        connection.start(queue: .main)
        connection.send(content: data, contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { _ in connection.cancel() })
    }

    /// This Mac, or a Tailscale address (100.64.0.0/10).
    nonisolated static func allowed(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        let v4: IPv4Address?
        switch host {
        case .ipv4(let address): v4 = address
        case .ipv6(let address):
            if address == .loopback { return true }
            v4 = address.asIPv4
        default: v4 = nil
        }
        guard let bytes = v4.map({ [UInt8]($0.rawValue) }), bytes.count == 4 else { return false }
        return bytes[0] == 127 || (bytes[0] == 100 && bytes[1] & 0xC0 == 64)
    }
}
