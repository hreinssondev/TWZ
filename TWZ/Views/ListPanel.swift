//
//  ListPanel.swift
//  TWZ
//
//  Live IB scanner list (gainers, losers, after-hours gainers, most active by
//  dollar volume), with each symbol's % change over the last 5 minutes and a green dot after the
//  symbols traded today. Clicking a row loads it into the selected chart. Prices refresh every
//  2 seconds rather than every tick, which keeps the UI free for the charts.
//

import SwiftUI

struct ListPanel: View {
    @Environment(Broker.self) private var broker
    @Environment(Workspace.self) private var workspace

    let panelId: String
    @AppStorage private var scanner: ScannerKind
    @State private var showFilter = false
    /// Row values as of the last refresh, by symbol.
    @State private var rowValues: [String: RowValues] = [:]

    static let refreshInterval: Duration = .seconds(2)

    private struct RowValues: Equatable {
        var last: Double?
        var change: Double?
        /// % change over the last 5 minutes; `recentIsPartial` while less history than that is held.
        var recent: Double?
        var recentIsPartial = false
    }

    init(panelId: String, defaultScanner: ScannerKind) {
        self.panelId = panelId
        _scanner = AppStorage(wrappedValue: defaultScanner, "scanner.\(panelId)")
    }

    private var scanSpec: ScanSpec {
        ScanSpec(kind: scanner, filter: workspace.scanFilter(panel: panelId, scanner))
    }

    private var symbols: [String] { broker.scans[panelId]?.symbols ?? [] }
    /// Symbols with a fill today.
    private var tradedSymbols: Set<String> { Set(broker.fills.values.map(\.symbol)) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Picker("", selection: $scanner) {
                    ForEach(ScannerKind.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .controlSize(.small)

                Button {
                    showFilter.toggle()
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
                .buttonStyle(.borderless)
                .help("Scanner filters")
                .popover(isPresented: $showFilter, arrowEdge: .bottom) {
                    ScanFilterEditor(filter: workspace.scanFilter(panel: panelId, scanner), defaults: scanner.defaultFilter) { filter in
                        workspace.setScanFilter(filter, panel: panelId, scanner)
                        showFilter = false
                    }
                }
            }
            .padding(6)

            columnHeader
            Divider()

            ScrollView {
                let traded = tradedSymbols
                LazyVStack(spacing: 0) {
                    ForEach(symbols, id: \.self) { symbol in
                        row(symbol, traded: traded.contains(symbol))
                    }
                }
            }

            Divider()
            scanStatus
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.12)))
        .onAppear {
            broker.setScanner(scanSpec, owner: panelId)
            broker.setQuoteSymbols(symbols, owner: panelId)
        }
        .onChange(of: scanSpec) { _, new in broker.setScanner(new, owner: panelId) }
        .onChange(of: symbols) { _, new in
            broker.setQuoteSymbols(new, owner: panelId)
            refreshRows()
        }
        // Quotes read here, outside `body`, don't redraw the list on every tick.
        .task(id: scanner) {
            while !Task.isCancelled {
                refreshRows()
                try? await Task.sleep(for: Self.refreshInterval)
            }
        }
    }

    private func refreshRows() {
        var values: [String: RowValues] = [:]
        for symbol in symbols {
            let q = broker.quote(symbol)
            let recent = broker.recentChange(symbol)
            values[symbol] = RowValues(
                last: q?.last,
                change: changePercent(symbol, q),
                recent: recent?.percent,
                recentIsPartial: recent?.isPartial ?? false)
        }
        if values != rowValues { rowValues = values }
    }

    private var columnHeader: some View {
        HStack(spacing: 4) {
            Text("Symbol").frame(maxWidth: .infinity, alignment: .leading)
            Text("Last").frame(width: 58, alignment: .trailing)
            Text(scanner == .afterHours ? "AH %" : "%Chg").frame(width: 52, alignment: .trailing)
            Text("5m %").frame(width: 50, alignment: .trailing)
                .help("Change over the last 5 minutes (dimmed until 5 minutes of prices have been seen)")
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.bottom, 3)
    }

    private var scanStatus: some View {
        let scan = broker.scans[panelId]
        let text: String
        if broker.state != .connected {
            text = "Not connected"
        } else if let error = scan?.error {
            text = error
        } else if let updated = scan?.updated {
            text = "\(MarketSession.phase().rawValue) · \(updated.formatted(date: .omitted, time: .standard))"
        } else {
            text = "Scanning…"
        }
        return MessageLabel(text: text, color: scan?.error == nil ? Color.secondary : Color.red)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
    }

    /// After hours, the AH scanner measures change from today's regular-session close.
    private func changePercent(_ symbol: String, _ q: Quote?) -> Double? {
        if scanner == .afterHours, MarketSession.phase() == .afterHours,
           let last = q?.last, let close = broker.sessionClose(symbol), close > 0 {
            return (last - close) / close * 100
        }
        return q?.changePercent
    }

    private static func changeColor(_ change: Double?) -> Color {
        guard let change else { return .secondary }
        return change >= 0 ? .green : .red
    }

    private func row(_ symbol: String, traded: Bool) -> some View {
        let values = rowValues[symbol]
        let change = values?.change
        let isCharted = workspace.targetSymbol == symbol
        let unavailable = broker.unavailableQuotes[symbol]
        return HStack(spacing: 4) {
            HStack(spacing: 3) {
                Text(symbol).fontWeight(.semibold)
                    .foregroundStyle(unavailable == nil ? Color.primary : Color.secondary)
                if traded {
                    Circle().fill(Color.green).frame(width: 5, height: 5)
                        .help("Traded today")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(Fmt.price(values?.last)).frame(width: 58, alignment: .trailing)
            Text(Fmt.percent(change))
                .foregroundStyle(Self.changeColor(change))
                .frame(width: 52, alignment: .trailing)
            Text(Fmt.percent(values?.recent))
                .foregroundStyle(Self.changeColor(values?.recent))
                .opacity(values?.recentIsPartial == true ? 0.5 : 1)
                .frame(width: 50, alignment: .trailing)
        }
        .font(.system(size: 11).monospacedDigit())
        .lineLimit(1)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(isCharted ? Color.accentColor.opacity(0.18) : Color.clear)
        .help(unavailable.map { "No real-time data: \($0)" } ?? "")
        .contentShape(Rectangle())
        .onTapGesture {
            workspace.loadIntoSelectedChart(symbol, broker: broker)
        }
        .contextMenu {
            ForEach(workspace.charts) { chart in
                Button("Load into Chart \(chart.id + 1)") {
                    workspace.load(symbol, into: chart, broker: broker)
                }
            }
        }
    }
}

/// Price/volume filter for a scanner; applied on "Apply" so typing doesn't resubscribe.
private struct ScanFilterEditor: View {
    @State var filter: ScannerFilter
    let defaults: ScannerFilter
    let onApply: (ScannerFilter) -> Void

    var body: some View {
        Form {
            TextField("Min price", value: $filter.minPrice, format: .number, prompt: Text("Any"))
            TextField("Max price", value: $filter.maxPrice, format: .number, prompt: Text("Any"))
            TextField("Min volume", value: $filter.minVolume, format: .number, prompt: Text("Any"))
            HStack {
                Button("Reset") { filter = defaults }
                Spacer()
                Button("Apply") { onApply(filter) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .controlSize(.small)
        .frame(width: 210)
        .padding(12)
    }
}
