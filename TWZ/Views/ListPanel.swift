//
//  ListPanel.swift
//  TWZ
//
//  Live IB scanner list (gainers, losers, after-hours gainers, most active by
//  dollar volume), or the Forex list (the main currency pairs in a fixed order, see `ForexPair`),
//  with each symbol's % change over the last 5 minutes and a green dot after the
//  symbols traded today. The load button beside the filters makes the chart grid follow the list, in
//  its order and as it changes, in place of the gainers until the account bar's Reset (see `ChartGrid`). The price columns' widths drag from their header's left edge (double-click
//  resets) and are kept per list; a list narrower than its columns clips them on the right. Clicking a row loads it into the selected chart, which keeps it until the
//  account bar's Reset (see `ChartGrid`). Prices refresh every
//  2 seconds rather than every tick, which keeps the UI free for the charts. A newspaper after a
//  symbol: news since the last close (hover for the headline).
//
//  The top bar's tabs switch the panel between its list and News (see `NewsTab`): the list's name,
//  then News. The list keeps scanning behind the News tab.
//

import SwiftUI

struct ListPanel: View {
    @Environment(Broker.self) private var broker
    @Environment(Workspace.self) private var workspace
    @Environment(\.sideColors) private var sideColors
    @AppStorage(Dimmed.opacityKey) private var dimmedOpacity = Dimmed.defaultOpacity

    let panelId: String
    @AppStorage private var scanner: ScannerKind
    @AppStorage private var tab: ListTab
    @AppStorage private var newsScope: NewsScope
    @AppStorage(MainGrid.timeframeKey) private var gridTimeframe: Timeframe = .m1
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
        _tab = AppStorage(wrappedValue: .list, "listTab.\(panelId)")
        _newsScope = AppStorage(wrappedValue: .stock, "newsScope.\(panelId)")
        _lastWidth = AppStorage(wrappedValue: Self.defaultWidths.last, "listColumn.last.\(panelId)")
        _changeWidth = AppStorage(wrappedValue: Self.defaultWidths.change, "listColumn.change.\(panelId)")
        _recentWidth = AppStorage(wrappedValue: Self.defaultWidths.recent, "listColumn.recent.\(panelId)")
    }

    private var scanSpec: ScanSpec {
        ScanSpec(kind: scanner, filter: workspace.scanFilter(panel: panelId, scanner))
    }

    private var symbols: [String] {
        switch scanner {
        case .colored: workspace.coloredSymbols
        case .alerts: workspace.alertSymbols
        default: broker.scans[panelId]?.symbols ?? []
        }
    }
    /// Symbols with a fill today.
    private var tradedSymbols: Set<String> { Set(broker.fills.values.map(\.symbol)) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                if tab == .list {
                    Picker("", selection: $scanner) {
                        ForEach(ScannerKind.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .help(ScannerKind.shortcutHelp)
                } else {
                    tabLabel(scanner.rawValue, isOpen: false) { tab = .list }
                }
                tabLabel("News", isOpen: tab == .news) { tab = .news }
                    .help("Headlines from IB's free news (Briefing.com, Dow Jones newsletters)")
                Spacer(minLength: 0)
                if tab == .list {
                    Button {
                        showFilter.toggle()
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                    .buttonStyle(.borderless)
                    .disabled(scanner == .forex || scanner.isWorkspaceList)
                    .help(scanner == .forex || scanner.isWorkspaceList ? "The \(scanner.rawValue) list has no filters" : "Scanner filters")
                    .popover(isPresented: $showFilter, arrowEdge: .bottom) {
                        ScanFilterEditor(filter: workspace.scanFilter(panel: panelId, scanner), defaults: scanner.defaultFilter) { filter in
                            workspace.setScanFilter(filter, panel: panelId, scanner)
                            showFilter = false
                        }
                    }

                    Button {
                        workspace.loadList(symbols, scan: scanSpec, timeframe: gridTimeframe, broker: broker)
                    } label: {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 10))
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(symbols.isEmpty)
                    .help("The chart grid follows this list, top first, as it changes (until Reset)")
                } else {
                    tabLabel(workspace.targetSymbol.isEmpty ? "Chart" : workspace.targetSymbol, isOpen: newsScope == .stock) {
                        newsScope = .stock
                    }
                    .help("The selected chart's news")
                    tabLabel("All", isOpen: newsScope == .all) { newsScope = .all }
                        .help("Every headline, as it comes")
                }
            }
            .frame(height: 20)
            .padding(6)

            if tab == .list {
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
            } else {
                Divider()
                NewsTab(scope: newsScope)
            }
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.12)))
        .onAppear {
            syncNews()
            workspace.shownLists[panelId] = scanner
            broker.setScanner(scanSpec, owner: panelId)
            broker.setQuoteSymbols(symbols, owner: panelId)
        }
        // Gone while the lists are merged into one, or split again (see `ContentView`): no scanner
        // or quotes meanwhile.
        .onDisappear {
            workspace.shownLists[panelId] = nil
            broker.setScanner(nil, owner: panelId)
            broker.setQuoteSymbols([], owner: panelId)
            broker.setNews(owner: panelId, symbol: nil, all: false)
        }
        .onChange(of: tab) { syncNews() }
        .onChange(of: newsScope) { syncNews() }
        .onChange(of: workspace.targetSymbol) { syncNews() }
        .onChange(of: scanSpec) { _, new in broker.setScanner(new, owner: panelId) }
        .onChange(of: scanner) { _, new in workspace.shownLists[panelId] = new }
        .onChange(of: workspace.listShortcut) { _, request in takeUp(request) }
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

    /// ⌘⇧ + a list's letter: a list already showing it loads into the chart grid, as its load button
    /// does; with none, the left list (the one list while they're merged) switches to it and loads.
    private func takeUp(_ request: Workspace.ListShortcut?) {
        guard let kind = request?.kind else { return }
        let shown = workspace.shownLists
        let target = shown.filter { $0.value == kind }.keys.sorted().first
            ?? (shown["list-single"] != nil ? "list-single" : "list-left")
        guard target == panelId else { return }
        let spec = ScanSpec(kind: kind, filter: workspace.scanFilter(panel: panelId, kind))
        // A list just switched has no rows of its own yet: the grid follows its own scan of the list, which
        // starts at the list's last rows if it was shown before (see `TradingEngine.setScanner`).
        let rows = scanner == kind ? symbols : []
        scanner = kind
        workspace.loadList(rows, scan: spec, timeframe: gridTimeframe, broker: broker)
    }

    /// The engine streams the news this panel's News tab shows; none while the list is shown.
    private func syncNews() {
        guard tab == .news else { return broker.setNews(owner: panelId, symbol: nil, all: false) }
        broker.setNews(owner: panelId, symbol: newsScope == .stock ? workspace.targetSymbol : nil, all: newsScope == .all)
    }

    /// One of the top bar's tabs, bold while open.
    private func tabLabel(_ title: String, isOpen: Bool, open: @escaping () -> Void) -> some View {
        Text(title)
            .font(.system(size: 11, weight: isOpen ? .semibold : .regular))
            .foregroundStyle(isOpen ? Color.primary : Color.secondary)
            .lineLimit(1)
            .padding(.horizontal, 3)
            .contentShape(Rectangle())
            .onTapGesture(perform: open)
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
            Text(scanner == .forex ? "Mid" : "Last").frame(width: lastWidth, alignment: .trailing)
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
        } else if scan?.isLastSession == true, let updated = scan?.updated {
            text = "Not current: last session's list (\(updated.formatted(date: .abbreviated, time: .shortened)))"
        } else if let updated = scan?.updated {
            let session = scanner == .forex
                ? (MarketSession.forexIsOpen() ? "Forex open" : "Forex closed until \(MarketSession.forexReopening())")
                : MarketSession.phase().rawValue
            text = "\(session) · \(updated.formatted(date: .omitted, time: .standard))"
        } else {
            text = "Scanning…"
        }
        let color = scan?.error != nil ? Color.red : scan?.isLastSession == true ? Color.orange : Color.secondary
        return MessageLabel(text: text, color: color)
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

    private func changeColor(_ change: Double?) -> Color {
        guard let change else { return .secondary }
        return sideColors.of(change >= 0)
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
                if let item = broker.listNews[symbol] {
                    Image(systemName: "newspaper.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(Color.accentColor)
                        .help("News \(NewsTab.time(item.time)): \(item.headline)")
                }
            }
            .frame(minWidth: Self.minSymbolWidth, maxWidth: .infinity, alignment: .leading)
            Text(Fmt.price(values?.last, for: symbol)).frame(width: lastWidth, alignment: .trailing)
            Text(Fmt.percent(change))
                .foregroundStyle(changeColor(change))
                .frame(width: changeWidth, alignment: .trailing)
            Text(Fmt.percent(values?.recent))
                .foregroundStyle(changeColor(values?.recent))
                .opacity(values?.recentIsPartial == true ? dimmedOpacity : 1)
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

/// What a list panel shows: its list, or News (see `NewsTab`).
enum ListTab: String { case list, news }

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

extension ScannerKind {
    /// ⌘⇧ + a letter shows that list and loads it into the chart grid (see `TradingShortcuts`): S
    /// Most Active $, L Top Losers, H AH Gainers, A Top Gainers, F Forex, D Forex + Active, C Colored, X Alerts.
    static func forShortcut(_ key: String) -> ScannerKind? {
        switch key {
        case "s": .dollarVolume
        case "l": .losers
        case "h": .afterHours
        case "a": .gainers
        case "f": .forex
        case "d": .forexActive
        case "c": .colored
        case "x": .alerts
        default: nil
        }
    }

    static let shortcutHelp = "⌘⇧S Most Active $ · ⌘⇧L Top Losers · ⌘⇧H AH Gainers · ⌘⇧A Top Gainers · ⌘⇧F Forex · ⌘⇧D Forex + Active · ⌘⇧C Colored · ⌘⇧X Alerts: "
        + "shows the list and loads it into the chart grid"
}
