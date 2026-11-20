//
//  BarStore.swift
//  TWZ
//
//  The bar cache on disk (see `BarCache`), so bars already downloaded are there after a relaunch: each
//  series a file of its bars, written when a chart moves off it and for every chart when the app quits,
//  read back when a chart shows a series no longer in memory. A series not shown for two days (its
//  file not written since) is deleted at launch. Files are written and deleted on a queue of their own.
//

import Foundation

nonisolated final class BarStore: Sendable {
    static let shared = BarStore()
    /// Series not shown for this long are deleted at launch.
    static let maxAge: TimeInterval = 2 * 24 * 3600

    let directory: URL
    private let queue = DispatchQueue(label: "TWZ.BarStore", qos: .utility)

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        directory = base.appendingPathComponent("TWZ/Bars", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Writes `bars` as the series `name`, in the background.
    func save(_ bars: [Bar], name: String) {
        let url = directory.appendingPathComponent(name)
        queue.async {
            var values: [Double] = []
            values.reserveCapacity(bars.count * 6)
            for b in bars {
                values += [b.time.timeIntervalSince1970, b.open, b.high, b.low, b.close, b.volume]
            }
            let data = values.withUnsafeBufferPointer { Data(buffer: $0) }
            try? data.write(to: url, options: .atomic)
        }
    }

    /// The series `name` as last written, if it's on disk.
    func read(name: String) -> [Bar]? {
        let url = directory.appendingPathComponent(name)
        queue.sync {}                                     // a write still on its way lands first
        guard let data = try? Data(contentsOf: url), data.count >= 48, data.count % 48 == 0 else { return nil }
        let values = data.withUnsafeBytes { Array($0.bindMemory(to: Double.self)) }
        var bars: [Bar] = []
        bars.reserveCapacity(values.count / 6)
        for i in stride(from: 0, to: values.count, by: 6) {
            bars.append(Bar(time: Date(timeIntervalSince1970: values[i]), open: values[i + 1], high: values[i + 2],
                            low: values[i + 3], close: values[i + 4], volume: values[i + 5]))
        }
        return bars
    }

    /// Deletes the series not written for `maxAge`, in the background.
    func prune() {
        let directory = directory
        queue.async {
            let fm = FileManager.default
            let cutoff = Date().addingTimeInterval(-Self.maxAge)
            let files = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for url in files {
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                if (modified ?? .distantPast) < cutoff { try? fm.removeItem(at: url) }
            }
        }
    }

    /// Waits for the writes on their way (quitting).
    func flush() { queue.sync {} }

    /// Files and bytes on disk.
    func usage() -> (files: Int, bytes: Int) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let bytes = files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
        return (files.count, bytes)
    }
}
