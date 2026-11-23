 //
//  OrderLog.swift
//  TWZ
//
//  Plain-text log of every order the app sends, changes or cancels and why, plus what IB says
//  back (status, fills, errors, positions, orders from other clients). One file per day in
//  Application Support/TWZ/Order Logs, kept for a week.
//
//  The engine only hands over a finished line once the order is already on the socket; the time
//  is formatted and the file written on a low-priority queue, never on the engine thread.
//  Turned off in Settings, a write costs one lock check.
//

import Foundation
import os

nonisolated final class OrderLog: @unchecked Sendable {
    static let shared = OrderLog()
    static let enabledKey = "orderLogEnabled"
    static let keptDays = 7

    let directory: URL
    private let queue = DispatchQueue(label: "TWZ.orderlog", qos: .utility)
    private let enabled: OSAllocatedUnfairLock<Bool>
    // Touched only on `queue`.
    private var handle: FileHandle?
    private var day = ""

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = support.appendingPathComponent("TWZ/Order Logs", isDirectory: true)
        enabled = OSAllocatedUnfairLock(initialState: UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true)
    }

    var isEnabled: Bool {
        get { enabled.withLock { $0 } }
        set { enabled.withLock { $0 = newValue } }
    }

    /// Appends `line`, stamped with the current time. Safe from any thread.
    func write(_ line: String) {
        guard isEnabled else { return }
        let time = Date()
        queue.async { self.append(line, at: time) }
    }

    private static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let timeFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private func append(_ line: String, at time: Date) {
        let today = Self.dayFormat.string(from: time)
        if today != day || handle == nil { open(today) }
        guard let handle, let data = "\(Self.timeFormat.string(from: time))  \(line)\n".data(using: .utf8) else { return }
        try? handle.write(contentsOf: data)
    }

    private func open(_ today: String) {
        try? handle?.close()
        handle = nil
        day = today
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("orders-\(today).log")
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
        pruneOldFiles()
    }

    private func pruneOldFiles() {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-Double(Self.keptDays) * 86_400)
        let files = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files where file.lastPathComponent.hasPrefix("orders-") {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff { try? fm.removeItem(at: file) }
        }
    }
}
