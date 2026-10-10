//
//  IBSocket.swift
//  TWZ
//
//  Raw TCP transport for the TWS / IB Gateway API.
//  Every message is a 4-byte big-endian length prefix followed by
//  NUL-terminated ASCII fields.
//

import Foundation
import Network

final class IBSocket {
    enum Event {
        case ready
        case message([String])
        case closed(String?)
    }

    var onEvent: (Event) -> Void = { _ in }

    private var connection: NWConnection?
    private var buffer = Data()

    func connect(host: String, port: Int) {
        disconnect()
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else {
            onEvent(.closed("Invalid port \(port)"))
            return
        }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        connection = conn
        buffer.removeAll()

        conn.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self, self.connection === conn else { return }
                switch state {
                case .ready:
                    self.onEvent(.ready)
                    self.receive(on: conn)
                case .waiting(let error):
                    self.close(reason: "Cannot reach IB Gateway at \(host):\(port) (\(error.localizedDescription))")
                case .failed(let error):
                    self.close(reason: error.localizedDescription)
                default:
                    break
                }
            }
        }
        conn.start(queue: .main)
    }

    func disconnect() {
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        buffer.removeAll()
    }

    /// Sends bytes exactly as given (used for the "API\0" handshake prefix).
    func sendRaw(_ data: Data) {
        connection?.send(content: data, completion: .contentProcessed { _ in })
    }

    /// Sends a length-prefixed message built from NUL-terminated fields.
    func send(_ fields: [String]) {
        var payload = Data()
        for field in fields {
            payload.append(contentsOf: Array(field.utf8))
            payload.append(0)
        }
        sendRaw(Self.lengthPrefixed(payload))
    }

    static func lengthPrefixed(_ payload: Data) -> Data {
        var length = UInt32(payload.count).bigEndian
        var data = Data(bytes: &length, count: 4)
        data.append(payload)
        return data
    }

    private func close(reason: String?) {
        disconnect()
        onEvent(.closed(reason))
    }

    private func receive(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self, self.connection === conn else { return }
                if let data, !data.isEmpty {
                    self.buffer.append(data)
                    self.drainBuffer()
                }
                if let error {
                    self.close(reason: error.localizedDescription)
                } else if isComplete {
                    self.close(reason: "IB Gateway closed the connection (client ID already in use?)")
                } else {
                    self.receive(on: conn)
                }
            }
        }
    }

    private func drainBuffer() {
        while buffer.count >= 4 {
            let start = buffer.startIndex
            let length = buffer[start..<start + 4].reduce(0) { ($0 << 8) | Int($1) }
            guard buffer.count >= 4 + length else { return }
            let body = buffer[(start + 4)..<(start + 4 + length)]
            buffer.removeSubrange(start..<(start + 4 + length))

            var fields = body.split(separator: 0, omittingEmptySubsequences: false)
                .map { String(decoding: $0, as: UTF8.self) }
            if fields.last == "" { fields.removeLast() }
            onEvent(.message(fields))
        }
    }
}
