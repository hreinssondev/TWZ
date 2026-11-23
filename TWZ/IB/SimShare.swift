//
//  SimShare.swift
//  TWZ
//
//  Lets TWZ-iOS (the iPhone app) see the what-if trades, which live only here: a connection on port
//  4010 gets them as JSON (`Broker.simPositions`) and is closed. Read-only, and only from this Mac or
//  Tailscale's addresses (100.64.0.0/10). Settings › Connection turns it off.
//

import Foundation
import Network

@MainActor
final class SimShare {
    static let shared = SimShare()
    static let port: UInt16 = 4010
    static let enabledKey = "shareSimWithIOS"
    static var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    weak var broker: Broker?
    private var listener: NWListener?

    func start(broker: Broker) {
        self.broker = broker
        guard Self.isEnabled, listener == nil, let port = NWEndpoint.Port(rawValue: Self.port),
              let listener = try? NWListener(using: .tcp, on: port) else { return }
        listener.newConnectionHandler = { connection in
            MainActor.assumeIsolated { SimShare.shared.serve(connection) }
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
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
