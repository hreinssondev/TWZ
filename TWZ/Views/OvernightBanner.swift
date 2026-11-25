//
//  OvernightBanner.swift
//  TWZ
//
//  The overnight check's banner over the charts (see `OvernightCheck`): from some minutes before the
//  close until the close, while stock positions are open, or at once from Settings › Trading's Check
//  now. It asks IB for fresh margin figures as it comes up and every 30 seconds after.
//

import SwiftUI

struct OvernightBanner: View {
    @Environment(Broker.self) private var broker
    @AppStorage(OvernightCheck.enabledKey) private var enabled = OvernightCheck.defaultEnabled
    @AppStorage(OvernightCheck.minutesKey) private var minutes = OvernightCheck.defaultMinutes

    /// The close it's showing for (for Check now outside the window: the time it was asked).
    @State private var shownFor: Date?
    /// Asked for by Check now: stays until ×, with or without positions.
    @State private var manual = false
    @State private var dismissedFor: Date?
    @State private var askedAt: Date?
    @State private var trimmedAt: Date?

    static let checkNow = Notification.Name("TWZOvernightCheckNow")
    private static let refreshEvery: TimeInterval = 30

    var body: some View {
        Group {
            if let close = shownFor { banner(close) }
        }
        .task(id: enabled) {
            while !Task.isCancelled {
                tick()
                try? await Task.sleep(for: .seconds(5))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Self.checkNow)) { _ in
            manual = true
            show(MarketSession.regularClose().flatMap { $0 > Date() ? $0 : nil } ?? Date())
        }
    }

    /// Shows the banner in the minutes before the close, hides it at the close, and asks for fresh
    /// figures every `refreshEvery` while it shows.
    private func tick() {
        let now = Date()
        if let close = shownFor {
            if !manual, now >= close || OvernightCheck.stockPositions(broker.positions).isEmpty { shownFor = nil; return }
            if now.timeIntervalSince(askedAt ?? .distantPast) >= Self.refreshEvery { ask() }
            return
        }
        guard enabled, let close = MarketSession.regularClose(on: now), dismissedFor != close,
              now >= close.addingTimeInterval(-Double(minutes) * 60), now < close,
              !OvernightCheck.stockPositions(broker.positions).isEmpty else { return }
        show(close)
    }

    private func show(_ close: Date) {
        shownFor = close
        trimmedAt = nil
        ask()
    }

    private func ask() {
        askedAt = Date()
        broker.refreshAccountSummary()
    }

    @ViewBuilder
    private func banner(_ close: Date) -> some View {
        let result = OvernightCheck.evaluate(broker)
        let fresh = broker.margin.updated.map { $0 >= (askedAt ?? .distantPast).addingTimeInterval(-1) } ?? false
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "moon.stars.fill").foregroundStyle(.indigo)
                Text("Overnight check").bold()
                if close > Date() {
                    Text("· close at \(close, format: .dateTime.hour().minute()) (in \(close, style: .relative))")
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                if !fresh { ProgressView().controlSize(.mini) }
                if let updated = broker.margin.updated {
                    Text("IB \(updated, format: .dateTime.hour().minute().second())").foregroundStyle(.tertiary)
                }
                Button {
                    dismissedFor = shownFor
                    shownFor = nil
                    manual = false
                } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Hide it until the next close")
            }
            content(result)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(width: 420, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .windowBackgroundColor)).shadow(color: .black.opacity(0.4), radius: 10))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder((result?.fits ?? true ? Color.green : Color.orange).opacity(0.6)))
    }

    @ViewBuilder
    private func content(_ result: OvernightCheck.Result?) -> some View {
        let stocks = OvernightCheck.stockPositions(broker.positions)
        if broker.state != .connected {
            Text("Not connected to IB Gateway").foregroundStyle(.orange)
        } else if let result {
            if result.fits {
                Label("\(stocks.isEmpty ? "The account fits" : "Your positions fit") the margin after the close: \(Self.amount(result.room)) to spare.",
                      systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Text("Short \(Self.amount(-result.room)) of the margin IB asks for after the close. To hold overnight:")
                    .foregroundStyle(.orange)
                if result.trims.isEmpty {
                    Text("No stock position to trim (IB's figures cover options and forex too).").foregroundStyle(.secondary)
                } else {
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 2) {
                        ForEach(result.trims) { t in
                            GridRow {
                                Text(t.symbol).bold()
                                Text("\(Fmt.shares(t.held)) → \(Fmt.shares(t.keeps))").monospacedDigit()
                                Text("\(t.held > 0 ? "sell" : "buy back") \(Fmt.shares(t.shares))")
                                    .foregroundStyle(t.held > 0 ? .red : .green)
                            }
                        }
                    }
                    HStack {
                        Button(trimmedAt == nil ? "Trim (sends to IB)" : "Trim again") {
                            broker.trimForOvernight(Dictionary(uniqueKeysWithValues: result.trims.map { ($0.symbol, $0.shares) }))
                            trimmedAt = Date()
                            Task {
                                try? await Task.sleep(for: .seconds(5))
                                ask()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                        .controlSize(.small)
                        Text("Limits a cent across the spread; each stock cut by the same share, plus \(Int(OvernightCheck.reserve * 100))% of the overnight margin to spare.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } else {
            Text("Waiting for IB's margin figures…").foregroundStyle(.secondary)
        }
    }

    /// An amount in the account's base currency, no decimals.
    private static func amount(_ v: Double) -> String {
        v.formatted(.number.precision(.fractionLength(0)))
    }
}
