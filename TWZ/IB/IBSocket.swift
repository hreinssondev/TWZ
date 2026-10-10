//
//  IBSocket.swift
//  TWZ
//
//  Raw TCP transport for the TWS / IB Gateway API.
//  Every message is a 4-byte big-endian length prefix followed by
//  NUL-terminated ASCII fields.
//
//  Runs on the queue it's given (the trading engine's): connection events and
//  messages arrive there, and send/connect/disconnect must be called from it.
//

import Foundation
import Network

nonisolated final class IBSocket: @unchecked Sendable {   // used only on its queue
    enum Event {
        case ready
        case message([String])
        case closed(String?)
    }

    var onEvent: (Event) -> Void = { _ in }

    private let queue: DispatchQueue
    private var connection: NWConnection?
    private var buffer = Data()
    /// Bytes at the front of `buffer` already handled; dropped in one go rather than per message.
    private var readOffset = 0
    private var drainScheduled = false

    /// Messages handled per turn on the queue. Between turns, commands waiting on the queue
    /// (an order from a hotkey) run, so a burst of market data never holds them up for long.
    private static let batchSize = 16

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    func connect(host: String, port: Int) {
        disconnect()
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else {
            onEvent(.closed("Invalid port \(port)"))
            return
        }
        let params = NWParameters.tcp
        params.serviceClass = .responsiveData
        if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true          // orders go out at once, not batched with later writes
        }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: params)
        connection = conn
        buffer.removeAll()
        readOffset = 0

        conn.stateUpdateHandler = { [weak self] state in
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
        conn.start(queue: queue)
    }

    func disconnect() {
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        buffer.removeAll()
        readOffset = 0
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
            guard let self, self.connection === conn else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.drainBuffer()
            }
            // A message handler may have closed the connection.
            guard self.connection === conn else { return }
            if let error {
                self.close(reason: error.localizedDescription)
            } else if isComplete {
                self.close(reason: "IB Gateway closed the connection (client ID already in use?)")
            } else {
                self.receive(on: conn)
            }
        }
    }

    private func drainBuffer() {
        drainScheduled = false
        var handled = 0
        while buffer.count - readOffset >= 4 {
            let start = buffer.startIndex + readOffset
            let length = buffer[start..<start + 4].reduce(0) { ($0 << 8) | Int($1) }
            guard buffer.count - readOffset >= 4 + length else { break }
            if handled == Self.batchSize {
                drainScheduled = true
                queue.async { [weak self] in
                    guard let self, self.drainScheduled else { return }
                    self.drainBuffer()
                }
                break
            }
            let body = buffer[(start + 4)..<(start + 4 + length)]
            readOffset += 4 + length
            handled += 1

            var fields = body.split(separator: 0, omittingEmptySubsequences: false)
                .map { String(decoding: $0, as: UTF8.self) }
            if fields.last == "" { fields.removeLast() }
            onEvent(.message(fields))
            if connection == nil { return }
        }
        if readOffset == buffer.count || readOffset > 1 << 16 {
            buffer.removeSubrange(buffer.startIndex..<buffer.startIndex + readOffset)
            readOffset = 0
        }
    }
}
