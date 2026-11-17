//
//  SecondaryChartsView.swift
//  TWZ
//
//  A grid of charts that follow the top gainers (their own scanner, 50 rows), laid out in rank order:
//  6×3 for the top 18, or a custom grid set by the Cols / Rows sliders (the "All Charts" / "Top N"
//  title toggles them). A slider change applies once the sliders have been left alone for a moment.
//  Each view also has its own Zoom slider: its charts' default zoom, applied as it moves.
//  A symbol keeps its chart while it stays in the top N (a reshuffle only moves the charts); only
//  charts whose symbol dropped out load a new one.
//  Clicking a chart loads its symbol into the main window's selected chart. With P on, or the
//  window closed, the scanner stops and every chart is emptied: no history, bar updates or quotes.
//  Hidden by its shortcut (see `ChartsWindowShortcut`), the window isn't closed: the charts stay live.
//

import SwiftUI

enum SecondaryCharts {
    static let maxColumns = 8
    static let maxRows = 4
    static let count = maxColumns * maxRows
    static let timeframeKey = "secondaryChartsTimeframe"
    static let pausedKey = "secondaryChartsPaused"
    static let layoutKey = "secondaryChartsLayout"
    static let columnsKey = "secondaryChartsColumns"
    static let rowsKey = "secondaryChartsRows"
    static let allZoomKey = "secondaryChartsAllZoom"
    static let customZoomKey = "secondaryChartsCustomZoom"
    static let scannerOwner = "secondary-charts"
    static let windowID = "secondary-charts"
    static let windowTitle = "Charts"
    /// The scanner gainer charts follow, here and in the main window's grid: enough rows for 8×4.
    static let gainersScan = ScanSpec(kind: .gainers, filter: ScannerFilter(minPrice: 0.1), rows: ScannerKind.maxRowCount)

    static func isWindow(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        return window.identifier?.rawValue.hasPrefix(windowID) == true || window.title == windowTitle
    }

    enum Layout: String {
        case all, custom
    }
}

/// Gainer charts: the Charts window's and the main window's.
extension Workspace {
    /// `charts` in gainer rank order, empty ones last. Only their place in a grid follows the ranking:
    /// a chart keeps its symbol and data, so a reshuffle reloads nothing.
    func ranked(_ charts: [ChartModel], by gainers: [String]) -> [ChartModel] {
        let rank = Dictionary(gainers.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return charts.enumerated().sorted { a, b in
            let ra = rank[a.element.symbol] ?? .max, rb = rank[b.element.symbol] ?? .max
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element)
    }

    /// Fills `charts` with the top `count` gainers; the other charts are emptied. A symbol still in
    /// the top `count` keeps its chart, so a reshuffle in the ranking reloads nothing (`ranked` moves
    /// them); new symbols take the charts that dropped out.
    func fill(_ charts: [ChartModel], withTop count: Int, of gainers: [String], broker: Broker) {
        var top: [String] = []
        for symbol in gainers where !symbol.isEmpty && !top.contains(symbol) {
            guard top.count < min(count, charts.count) else { break }
            top.append(symbol)
        }
        let shown = Set(charts.map(\.symbol))
        var incoming = top.filter { !shown.contains($0) }[...]
        for chart in charts where !top.contains(chart.symbol) {
            if let symbol = incoming.popFirst() {
                load(symbol, into: chart, broker: broker)
            } else {
                clear(chart, broker: broker)
            }
        }
    }

    /// Sets the charts' default zoom and zooms them to it.
    func setZoom(_ zoom: Double, of charts: [ChartModel]) {
        for chart in charts where chart.defaultVisibleBars != zoom || chart.visibleBars != zoom {
            chart.defaultVisibleBars = zoom
            chart.visibleBars = zoom
        }
    }

    /// Puts the charts' view back to `zoom`, as double-clicking one does: latest bars at the right
    /// edge, price range fitted to the bars again.
    func resetViews(of charts: [ChartModel], zoom: Double) {
        setZoom(zoom, of: charts)
        for chart in charts where chart.scrollBack != 0 || chart.priceShift != 0 || chart.priceScale != 1 {
            chart.scrollBack = 0
            chart.priceShift = 0
            chart.priceScale = 1
        }
    }

    func setTimeframe(_ timeframe: Timeframe, of charts: [ChartModel], broker: Broker) {
        for chart in charts where chart.timeframe != timeframe {
            chart.timeframe = timeframe
            if !chart.symbol.isEmpty { broker.loadChart(chart) }
        }
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
    @AppStorage(SecondaryCharts.columnsKey) private var customColumns: Int = 5
    @AppStorage(SecondaryCharts.rowsKey) private var customRows: Int = 2
    /// Bars on screen at the default zoom, one for All Charts and one for the custom grid.
    @AppStorage(SecondaryCharts.allZoomKey) private var allZoom: Double = ChartModel.initialVisibleBars
    @AppStorage(SecondaryCharts.customZoomKey) private var customZoom: Double = ChartModel.initialVisibleBars
    @State private var columnSplits = SplitStore(key: "secondaryChartsColumnSplits")
    @State private var rowSplits = SplitStore(key: "secondaryChartsRowSplits")

    private var columns: Int { layout == .all ? 6 : customColumns }
    private var rows: Int { layout == .all ? 3 : customRows }
    private var count: Int { columns * rows }
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
                SplitGrid(columns: columns, rows: rows,
                          items: workspace.ranked(workspace.secondaryCharts, by: lastGainers),
                          gap: Self.gap, inset: Self.gap,
                          columnSplits: $columnSplits, rowSplits: $rowSplits) { chart in
                    SecondaryChartPane(chart: chart)
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.35))
        .onAppear {
            applyZoom()
            if !isPaused { start() }
        }
        // On close only: hiding the window (ordering it out) keeps the charts live.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
            if SecondaryCharts.isWindow(note.object as? NSWindow) { stop() }
        }
        // Fills the charts as soon as the scanner answers, e.g. right after P is turned off.
        .onChange(of: broker.scans[SecondaryCharts.scannerOwner]?.symbols) {
            if !isPaused { syncWithGainers() }
        }
        .onChange(of: masterTimeframe) { _, new in
            workspace.setTimeframe(new, of: workspace.secondaryCharts, broker: broker)
        }
        .onChange(of: isPaused) { _, paused in
            if paused { stop() } else { start() }
        }
        // Charts still in the new top N stay put; the rest are emptied (smaller grid) or filled (larger).
        .onChange(of: count) {
            if !isPaused { lastGainers = []; syncWithGainers() }
        }
        .onChange(of: layout) { applyZoom() }
        .onChange(of: allZoom) { applyZoom() }
        .onChange(of: customZoom) { applyZoom() }
    }

    private var header: some View {
        HStack {
            Button {
                layout = layout == .all ? .custom : .all
            } label: {
                Text(layout == .all ? "All Charts" : "Top \(count)")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(layout == .all ? "Show the custom grid set by the sliders" : "Show the top 18 gainers, 6×3")
            GridSliders(columns: $customColumns, rows: $customRows, zoom: layout == .all ? $allZoom : $customZoom,
                        columnRange: 1...SecondaryCharts.maxColumns, rowRange: 1...SecondaryCharts.maxRows,
                        showsSize: layout == .custom)
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
        // The height drag sits behind the controls so it never takes a slider's drag.
        .background(
            Color(nsColor: .textBackgroundColor).opacity(0.2)
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
        )
    }

    /// Sets every chart's default zoom for the current view and zooms them to it.
    private func applyZoom() {
        workspace.setZoom(layout == .all ? allZoom : customZoom, of: workspace.secondaryCharts)
    }

    private func start() {
        lastGainers = []
        broker.setScanner(SecondaryCharts.gainersScan, owner: SecondaryCharts.scannerOwner)
        syncWithGainers()
    }

    /// Stops the scanner and empties every chart, cancelling their data.
    private func stop() {
        broker.setScanner(nil, owner: SecondaryCharts.scannerOwner)
        lastGainers = []
        for chart in workspace.secondaryCharts { workspace.clear(chart, broker: broker) }
    }

    /// Fills the charts with the top N gainers (the grid's count); the other charts are emptied.
    private func syncWithGainers() {
        let gainers = broker.scans[SecondaryCharts.scannerOwner]?.symbols ?? []
        guard !gainers.isEmpty, gainers != lastGainers else { return }
        lastGainers = gainers
        workspace.fill(workspace.secondaryCharts, withTop: count, of: gainers, broker: broker)
    }
}

/// A Charts window chart pane: clicking it loads its symbol into the main window's selected chart.
/// ⌃-click, the what-if, its lines and hover P/L work as on the main charts; ⌥-click orders are left off.
struct SecondaryChartPane: View {
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
        .background(broker.positionTint(chart.symbol))
    }
}
