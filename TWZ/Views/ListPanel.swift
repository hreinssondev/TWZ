//
//  ListPanel.swift
//  TWZ
//
//  Live IB scanner list (gainers, losers, after-hours gainers, most active by
//  dollar volume), with each symbol's % change over the last 5 minutes and a green dot after the
//  symbols traded today. The price columns' widths drag from their header's left edge (double-click
//  resets) and are kept per list; a list narrower than its columns clips them on the right. Clicking a row loads it into the selected chart, which keeps it until the
//  account bar's Reset (see `ChartGrid`). Prices refresh every
//  2 seconds rather than every tick, which keeps the UI free for the charts.
//

import SwiftUI

struct ListPanel: View {
    @Environment(Broker.self) private var broker
    @Environment(Workspace.self) private var workspace

    let panelId: String
    @AppStorage private var scanner: ScannerKind
    /// One list across the lists' space instead of two (see `ContentView`); the button beside the
    /// filters switches.
    @AppStorage(ListPanel.singleKey) private var isSingle = false
    @State private var showFilter = false
    @AppStorage private var lastWidth: Double
    @AppStorage private var changeWidth: Double
    @AppStorage private var recentWidth: Double

    private static let defaultWidths = (last: 58.0, change: 52.0, recent: 50.0)
    private static let columnWidthRange: ClosedRange<CGFloat> = 20...160
    /// Room for a symbol before the price columns are pushed out of the list.
    private static let minSymbolWidth: CGFloat = 44

    static let singleKey = "singleList"
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
        _lastWidth = AppStorage(wrappedValue: Self.defaultWidths.last, "listColumn.last.\(panelId)")
        _changeWidth = AppStorage(wrappedValue: Self.defaultWidths.change, "listColumn.change.\(panelId)")
        _recentWidth = AppStorage(wrappedValue: Self.defaultWidths.recent, "listColumn.recent.\(panelId)")
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

                Button {
                    isSingle.toggle()
                } label: {
                    // A small dot, brighter while the lists are one.
                    Circle()
                        .fill(isSingle ? Color.primary.opacity(0.8) : Color.secondary.opacity(0.6))
                        .frame(width: 6, height: 6)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isSingle ? "Split into two lists" : "One list across both")
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
        // Gone while the lists are merged into one, or split again (see `ContentView`): no scanner
        // or quotes meanwhile.
        .onDisappear {
            broker.setScanner(nil, owner: panelId)
            broker.setQuoteSymbols([], owner: panelId)
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
            Text("Symbol").frame(minWidth: Self.minSymbolWidth, maxWidth: .infinity, alignment: .leading)
            Text("Last").frame(width: lastWidth, alignment: .trailing)
                .overlay(alignment: .leading) { columnHandle($lastWidth, default: Self.defaultWidths.last) }
            Text(scanner == .afterHours ? "AH %" : "%Chg").frame(width: changeWidth, alignment: .trailing)
                .overlay(alignment: .leading) { columnHandle($changeWidth, default: Self.defaultWidths.change) }
            Text("5m %").frame(width: recentWidth, alignment: .trailing)
                .help("Change over the last 5 minutes (dimmed until 5 minutes of prices have been seen)")
                .overlay(alignment: .leading) { columnHandle($recentWidth, default: Self.defaultWidths.recent) }
        }
        .lineLimit(1)
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .padding(.horizontal, 8)
        .padding(.bottom, 3)
    }

    /// A divider in the gap before a price column; dragging it left widens the column.
    private func columnHandle(_ width: Binding<Double>, default defaultWidth: Double) -> some View {
        ResizeHandle(resizes: .horizontal, style: .line, thickness: 1, current: width.wrappedValue,
                     range: Self.columnWidthRange, inverted: true,
                     onChange: { width.wrappedValue = $0 }, onReset: { width.wrappedValue = defaultWidth })
            .offset(x: -2.5)
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
            .frame(minWidth: Self.minSymbolWidth, maxWidth: .infinity, alignment: .leading)
            Text(Fmt.price(values?.last)).frame(width: lastWidth, alignment: .trailing)
            Text(Fmt.percent(change))
                .foregroundStyle(Self.changeColor(change))
                .frame(width: changeWidth, alignment: .trailing)
            Text(Fmt.percent(values?.recent))
                .foregroundStyle(Self.changeColor(values?.recent))
                .opacity(values?.recentIsPartial == true ? 0.5 : 1)
                .frame(width: recentWidth, alignment: .trailing)
        }
        .font(.system(size: 11).monospacedDigit())
        .lineLimit(1)
        // Narrower than its columns, the list keeps the symbol and clips on the right.
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(isCharted ? Color.accentColor.opacity(0.18) : Color.clear)
        .help(unavailable.map { "No real-time data: \($0)" } ?? "")
        .contentShape(Rectangle())
        .onTapGesture {
            workspace.loadIntoSelectedChart(symbol, broker: broker)
        }
        .contextMenu {
            // The grid's charts in reading order.
            ForEach(Array(workspace.mainCells.compactMap(workspace.chart(id:)).enumerated()), id: \.element.id) { index, chart in
                Button("Load into Chart \(index + 1)") {
                    workspace.loadByHand(symbol, into: chart, broker: broker)
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
