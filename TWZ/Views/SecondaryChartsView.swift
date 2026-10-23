//
//  SecondaryChartsView.swift
//  TWZ
//
//  A grid of charts that follow the top gainers (their own scanner, 25 rows), laid out in rank order:
//  6×3 for the top 18, or 5×2 for the top 10 (the "All Charts" / "Top 10" title toggles them).
//  A symbol keeps its chart while it stays in the top N (a reshuffle only moves the charts); only
//  charts whose symbol dropped out load a new one.
//  Clicking a chart loads its symbol into the main window's selected chart. With P on, or the
//  window closed, the scanner stops and every chart is emptied: no history, bar updates or quotes.
//  Hidden by its shortcut (see `ChartsWindowShortcut`), the window isn't closed: the charts stay live.
//

import SwiftUI

enum SecondaryCharts {
    static let count = 18
    static let timeframeKey = "secondaryChartsTimeframe"
    static let pausedKey = "secondaryChartsPaused"
    static let layoutKey = "secondaryChartsLayout"
    static let scannerOwner = "secondary-charts"
    static let windowID = "secondary-charts"
    static let windowTitle = "Charts"

    static func isWindow(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        return window.identifier?.rawValue.hasPrefix(windowID) == true || window.title == windowTitle
    }

    enum Layout: String {
        case all, top10

        var columns: Int { self == .all ? 6 : 5 }
        var rows: Int { self == .all ? 3 : 2 }
        var count: Int { columns * rows }
        var title: String { self == .all ? "All Charts" : "Top 10" }
    }
}

struct SecondaryChartsView: View {
    @Environment(Broker.self) private var broker
    @Environment(Workspace.self) private var workspace

    private static let gap: CGFloat = 4

    @State private var lastGainers: [String] = []
    @AppStorage(SecondaryCharts.timeframeKey) private var masterTimeframe: Timeframe = .m1
    @AppStorage("secondaryHeaderHeight") private var headerHeight: Double = 28
    @AppStorage(SecondaryCharts.pausedKey) private var isPaused: Bool = false
    @AppStorage(SecondaryCharts.layoutKey) private var layout: SecondaryCharts.Layout = .all
    @State private var dragStartHeight: Double?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if isPaused {
                Text("Paused")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                grid
            }
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.35))
        .onAppear { if !isPaused { start() } }
        // On close only: hiding the window (ordering it out) keeps the charts live.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
            if SecondaryCharts.isWindow(note.object as? NSWindow) { stop() }
        }
        // Fills the charts as soon as the scanner answers, e.g. right after P is turned off.
        .onChange(of: broker.scans[SecondaryCharts.scannerOwner]?.symbols) {
            if !isPaused { syncWithGainers() }
        }
        .onChange(of: masterTimeframe) { _, new in
            applyMasterTimeframe(new)
        }
        .onChange(of: isPaused) { _, paused in
            if paused { stop() } else { start() }
        }
        // Charts still in the new top N stay put; the rest are emptied (10) or filled (18).
        .onChange(of: layout) {
            if !isPaused { lastGainers = []; syncWithGainers() }
        }
    }

    private var grid: some View {
        GeometryReader { geo in
            let gap = Self.gap
            let totalGap = gap * CGFloat(layout.columns - 1)
            let chartWidth = (geo.size.width - gap * 2 - totalGap) / CGFloat(layout.columns)
            let totalVerticalGap = gap * CGFloat(layout.rows - 1)
            let chartHeight = (geo.size.height - gap * 2 - totalVerticalGap) / CGFloat(layout.rows)

            // One ForEach keyed by chart, so a chart's view (and its state) moves with it when the ranking reshuffles.
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(chartWidth), spacing: gap), count: layout.columns), spacing: gap) {
                ForEach(rankedCharts.prefix(layout.count), id: \.id) { chart in
                    SecondaryChartPane(chart: chart)
                        .frame(width: chartWidth, height: chartHeight)
                }
            }
            .padding(gap)
        }
    }

    /// The charts in gainer rank order, empty ones last. Only their place in the grid follows the
    /// ranking: a chart keeps its symbol and data, so a reshuffle reloads nothing.
    private var rankedCharts: [ChartModel] {
        let rank = Dictionary(lastGainers.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return workspace.secondaryCharts.enumerated().sorted { a, b in
            let ra = rank[a.element.symbol] ?? .max, rb = rank[b.element.symbol] ?? .max
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element)
    }

    private var header: some View {
        HStack {
            Button {
                layout = layout == .all ? .top10 : .all
            } label: {
                Text(layout.title).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(layout == .all ? "Show the top 10 gainers, 5×2" : "Show the top 18 gainers, 6×3")
            // A failed scanner isn't retried, so the charts would sit on its last list without this.
            if !isPaused, let error = broker.scans[SecondaryCharts.scannerOwner]?.error {
                Text(error).font(.system(size: 11)).foregroundStyle(.red).lineLimit(1).help(error)
            }
            Spacer()
            TimeframePicker(selection: Binding(
                get: { masterTimeframe },
                set: { masterTimeframe = $0 }
            ))
            Button {
                isPaused.toggle()
            } label: {
                Text("P")
                    .font(.system(size: 10, weight: .regular).monospacedDigit())
                    .foregroundStyle(isPaused ? Color.primary : Color.secondary.opacity(0.7))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(isPaused ? 0.12 : 0)))
            }
            .buttonStyle(.plain)
            .help(isPaused ? "Turn the charts back on" : "Turn the charts off: no scanner, history or quotes until P is off again")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(height: headerHeight)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.2))
        .contentShape(Rectangle())
        .gesture(
            DragGesture()
                .onChanged { value in
                    let start = dragStartHeight ?? headerHeight
                    dragStartHeight = start
                    headerHeight = max(24, min(start + value.translation.height, 100))
                }
                .onEnded { _ in dragStartHeight = nil }
        )
    }

    private func applyMasterTimeframe(_ timeframe: Timeframe) {
        for chart in workspace.secondaryCharts where chart.timeframe != timeframe {
            chart.timeframe = timeframe
            if !chart.symbol.isEmpty { broker.loadChart(chart) }
        }
    }

    private func start() {
        lastGainers = []
        broker.setScanner(ScanSpec(kind: .gainers, filter: ScannerFilter(minPrice: 0.1)), owner: SecondaryCharts.scannerOwner)
        syncWithGainers()
    }

    /// Stops the scanner and empties every chart, cancelling their data.
    private func stop() {
        broker.setScanner(nil, owner: SecondaryCharts.scannerOwner)
        lastGainers = []
        for chart in workspace.secondaryCharts { workspace.clear(chart, broker: broker) }
    }

    /// Fills the charts with the top N gainers (the layout's count); the other charts are emptied.
    /// A symbol still in the top N keeps its chart, so a
    /// reshuffle in the ranking reloads nothing (`rankedCharts` moves them); new symbols take the charts that dropped out.
    private func syncWithGainers() {
        let gainers = broker.scans[SecondaryCharts.scannerOwner]?.symbols ?? []
        guard !gainers.isEmpty, gainers != lastGainers else { return }
        lastGainers = gainers

        var top: [String] = []
        for symbol in gainers where !symbol.isEmpty && !top.contains(symbol) {
            top.append(symbol)
            if top.count == min(layout.count, workspace.secondaryCharts.count) { break }
        }
        let shown = Set(workspace.secondaryCharts.map(\.symbol))
        var incoming = top.filter { !shown.contains($0) }[...]
        for chart in workspace.secondaryCharts where !top.contains(chart.symbol) {
            if let symbol = incoming.popFirst() {
                workspace.load(symbol, into: chart, broker: broker)
            } else {
                workspace.clear(chart, broker: broker)
            }
        }
    }
}

/// A chart pane for the secondary window: clicking loads the symbol into the main window's
/// selected chart instead of selecting this pane. ⌃-click, the what-if, its lines and ⌘ P/L work
/// as on the main charts; ⌥-click orders are left off.
private struct SecondaryChartPane: View {
    @Environment(Broker.self) private var broker
    @Environment(Workspace.self) private var workspace
    let chart: ChartModel

    @State private var symbolText = ""
    @FocusState private var symbolFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            TradingChart(chart: chart, allowsAltClick: false)
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.12)))
        .simultaneousGesture(TapGesture().onEnded {
            if !chart.symbol.isEmpty { workspace.loadIntoSelectedChart(chart.symbol, broker: broker) }
        })
        .onAppear { symbolText = chart.symbol }
        .onChange(of: chart.symbol) { _, new in
            if !symbolFocused { symbolText = new }
        }
        .onChange(of: symbolFocused) { _, focused in
            if !focused { symbolText = chart.symbol }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            TextField("Symbol", text: $symbolText)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .bold))
                .frame(width: 70)
                .focused($symbolFocused)
                .onSubmit {
                    workspace.load(symbolText, into: chart, broker: broker)
                    symbolText = chart.symbol
                    symbolFocused = false
                }
            Spacer()
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
    }
}
