//
//  BorrowTab.swift
//  TWZ
//
//  The Borrow tab beside Round trips: whether the selected chart's stock can be shorted, how many
//  shares IB has to lend (live, else from IB's short stock file), the borrow fee and rebate, and what
//  borrowing a number of shares costs a day. IB's API can't borrow ahead: IB borrows the shares when a
//  sell with no position (a short sale) fills, and charges the fee each day the position stays short.
//

import SwiftUI

struct BorrowTab: View {
    @Environment(Broker.self) private var broker
    @Environment(Workspace.self) private var workspace
    @AppStorage(OrderAmount.storageKey) private var orderNOK = OrderAmount.initial
    /// Shares typed for the cost estimate; empty uses the order amount's shares.
    @State private var sharesText = ""

    private var symbol: String { workspace.targetSymbol }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if symbol.isEmpty {
                note("Select a chart to see its borrow")
            } else {
                content
            }
        }
        .onChange(of: symbol) { sharesText = "" }
    }

    /// Keeps IB's borrow rates loaded (the Orders panel runs it, for the tab's label too). IB updates
    /// its file about every 15 minutes; `refreshIfStale` loads it no more often.
    static func keepRatesLoaded(_ broker: Broker) async {
        while !Task.isCancelled {
            broker.borrowRates.refreshIfStale()
            try? await Task.sleep(for: .seconds(60))
        }
    }

    @ViewBuilder private var content: some View {
        let rates = broker.borrowRates
        let rate = rates.rates[symbol]
        let level = broker.shortability[symbol]
        let last = broker.quote(symbol)?.last
        let defaultShares = last.flatMap { broker.shares(forNOK: orderNOK, at: $0) }
        let shares = Double(sharesText.replacingOccurrences(of: ",", with: "")) ?? defaultShares

        HStack(spacing: 4) {
            Text(symbol).fontWeight(.semibold)
            if let rate { Text(rate.name.capitalized).foregroundStyle(.secondary) }
            Spacer(minLength: 2)
            ShortStatus(level: level)
        }
        .borrowRow()

        row("Available") {
            if let live = broker.shortableShares[symbol] {
                Text(Fmt.shares(live))
            } else if let available = rate?.available {
                let capped = rate?.availableIsCapped == true ? "> " : ""
                Text("\(capped)\(Fmt.shares(available)) \(Text("file").foregroundStyle(.secondary))")
            } else {
                Text(rate == nil && !rates.rates.isEmpty ? "0" : "—")
            }
        }
        row("Fee") { Text(yearly(rate?.feeRate)) }
        row("Rebate") { Text(yearly(rate?.rebateRate)) }
        row("Shares") {
            TextField(defaultShares.map { Fmt.shares($0) } ?? "Shares", text: $sharesText)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .frame(width: 80)
        }
        row("Cost / day") {
            // IB's USD borrow fees are annual on a 360-day year, charged every calendar day short.
            if let shares, let last, let fee = rate?.feeRate {
                let value = shares * last
                Text("\(Fmt.money(value * fee / 100 / 360)) \(Text("of \(Fmt.money(value))").foregroundStyle(.secondary))")
            } else {
                Text("—")
            }
        }

        note(level.map { $0 <= 1.5 } == true
             ? "IB has no shares to lend now, so a short sale won't fill. IB finds more through the day; watch Available."
             : "IB borrows the shares when a sell with no position (a short sale) fills; the fee is charged each day the position stays short.")
        HStack(spacing: 4) {
            if let error = rates.error {
                Text(error).foregroundStyle(.red)
            } else if let time = rates.fileTime {
                Text("IB file \(time) ET")
            }
            Spacer(minLength: 2)
            if rates.isLoading {
                ProgressView().controlSize(.mini)
            } else {
                Button("Refresh") { rates.refresh() }
                    .buttonStyle(.borderless)
                    .help("Load IB's borrow fees again (IB updates them about every 15 minutes)")
            }
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .borrowRow()
    }

    private func row<Value: View>(_ label: String, @ViewBuilder value: () -> Value) -> some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 2)
            value()
        }
        .borrowRow()
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func yearly(_ percent: Double?) -> String {
        percent.map { $0.formatted(.number.precision(.fractionLength(2))) + "% / yr" } ?? "—"
    }
}

/// The chart header's red S, spelled out: IB's shortable tick, live. Also on the Borrow tab's label.
struct ShortStatus: View {
    let level: Double?

    var body: some View {
        Group {
            switch level {
            case let l? where l > 2.5: Text("Shortable").foregroundStyle(.red)
            case let l? where l > 1.5: Text("Hard to borrow").foregroundStyle(.orange)
            case .some: Text("Not shortable").foregroundStyle(.secondary)
            case nil: Text("—").foregroundStyle(.secondary)
            }
        }
        .fontWeight(.semibold)
        .help("IB's live shortable status: shortable (1,000+ shares to lend), hard to borrow "
              + "(only if IB can locate shares) or not shortable")
    }
}

/// Shares IB has to lend, compact ("1.2M"): live, else from IB's short stock file (">10M" where it caps the figure).
@MainActor func lendableShares(_ symbol: String, broker: Broker) -> String? {
    if let live = broker.shortableShares[symbol] { return live.formatted(.number.notation(.compactName)) }
    guard let rate = broker.borrowRates.rates[symbol], let available = rate.available else { return nil }
    return (rate.availableIsCapped ? ">" : "") + available.formatted(.number.notation(.compactName))
}

private extension View {
    func borrowRow() -> some View {
        padding(.horizontal, 6).padding(.vertical, 3).lineLimit(1)
            .overlay(alignment: .bottom) { Divider().opacity(0.4) }
    }
}
