//
//  SecondaryChartsView.swift
//  TWZ
//
//  A grid of charts that follow a list, the top gainers unless picked otherwise (their own scanner, 50 rows; the
//  header's menu, or ⌘⇧ and a list's letter with this window in front, as in the main window, switches it
//  here only), laid out in rank order:
//  6×3 for the top 18, or a custom grid set by the Cols / Rows sliders (the "All Charts" / "Top N"
//  title toggles them). A slider change applies once the sliders have been left alone for a moment.
//  Each view also has its own Zoom slider: its charts' default zoom, applied as it moves; a ⇧-, ⌘- or ⌥-swipe
//  on a chart moves it too, as in the main window (⌃-swipe: the price axis).
//  A symbol keeps its chart while it stays in the top N (a reshuffle only moves the charts); only
//  charts whose symbol dropped out load a new one.
//  A symbol typed into a chart's field stays in that chart and cell, the stock it replaced leaving
//  the charts meanwhile (so nothing else moves) and the gainers filling the other cells around it, until the top bar's Reset, the field emptied, or a smaller grid without that cell.
//  ⌘R (or another of the main window's Reset keys) with this window in front resets it alone: the top gainers,
//  no charts kept by hand, every chart's view back to the Zoom slider's.
//  Clicking a chart selects it, as in the main window: hotkeys, order keys and the other trading shortcuts go to
//  its stock, it streams tick by tick (⌘↩ keeps it fast), and its header shows the position, ⚡, S, SSR, buying
//  power and its own timeframe switch. ⌥1–6 (⌃, ⇧ too) with this window in front sets every chart's timeframe here. With P on, or the
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
    static let listKey = "secondaryChartsList"
    static let windowID = "secondary-charts"
    static let windowTitle = "Charts"
    /// The scanner gainer charts follow, here and in the main window's grid: enough rows for 8×4.
    static let gainersScan = ScanSpec(kind: .gainers, filter: ScannerFilter(minPrice: 0.1), rows: ScannerKind.maxRowCount)

    /// The Charts window's scan of `kind`: as many rows as the gainers'.
    static func scan(_ kind: ScannerKind) -> ScanSpec {
        kind == .gainers ? gainersScan : ScanSpec(kind: kind, filter: kind.defaultFilter, rows: ScannerKind.maxRowCount)
    }

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

    /// ⇧-, ⌘- or ⌥-swipe on Charts window chart `chart`: every chart there zooms by `factor` from the zoom on
    /// screen, as `zoomGrid` does for the main charts. The new zoom, for the window's Zoom slider.
    func zoomChartsWindow(by factor: Double, from chart: ChartModel, sliderZoom: Double, broker: Broker) -> Double {
        let shown = secondaryCharts.filter { !$0.symbol.isEmpty }
        let base = !GridZoom.resetsAdjusted && chart.adjustedByHand
            ? shown.first { !$0.adjustedByHand }?.visibleBars ?? sliderZoom
            : chart.visibleBars
        guard base > 0 else { return sliderZoom }
        let most = shown.map { Double($0.bars.count) }.max() ?? 0
        let zoom = min(max(ChartModel.maxVisibleBars, most, base), max(15, base * factor))
        setZoom(zoom, of: secondaryCharts, broker: broker, by: zoom / base)
        if zoom != sliderZoom { swipedChartsWindowZoom = zoom }
        return zoom
    }

    /// Sets the charts' default zoom and zooms them to it. The zooms they were left at on other stocks
    /// and timeframes stay (see `ChartViews`); Reset forgets those.
    /// From `oldZoom` (the grid's zoom moved: ⇧-swipe, the Zoom slider) with Settings' "⇧-swipe zooms
    /// charts adjusted by hand to the same zoom" off, charts adjusted by hand keep their own zoom and
    /// change it by as much (see `GridZoom`), or by `factor` when given (a swipe, see `zoomGrid`).
    func setZoom(_ zoom: Double, of charts: [ChartModel], broker: Broker, from oldZoom: Double? = nil, by factor: Double? = nil) {
        let relative = GridZoom.resetsAdjusted ? nil : factor ?? oldZoom.flatMap { old in old > 0 ? zoom / old : nil }
        for chart in charts {
            if let relative, chart.adjustedByHand {
                chart.defaultVisibleBars = zoom
                chart.visibleBars = min(max(ChartModel.maxVisibleBars, Double(chart.bars.count)), max(15, chart.visibleBars * relative))
                continue
            }
            if chart.defaultVisibleBars != zoom || chart.visibleBars != zoom {
                chart.defaultVisibleBars = zoom
                chart.visibleBars = zoom
            }
        }
    }

    /// Puts the charts' view back to `zoom`, as double-clicking one does: latest bars at the right
    /// edge, price range fitted to the bars again. Given a `timeframe` (the top bar's Reset), only on it:
    /// charts on another one, and the views kept on others, stay as they are.
    func resetViews(of charts: [ChartModel], zoom: Double, broker: Broker, timeframe: Timeframe? = nil) {
        let charts = charts.filter { chart in timeframe.map { chart.timeframe == $0 } ?? true }
        setZoom(zoom, of: charts, broker: broker)
        broker.forgetChartViews(of: charts, timeframe: timeframe)
        for chart in charts {
            chart.adjustedByHand = false
            if let timeframe { chart.zooms[timeframe] = nil } else { chart.zooms = [:] }
        }
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
                let items = self.items
                SplitGrid(columns: columns, rows: rows, items: items,
                          gap: Self.gap, inset: Self.gap,
                          columnSplits: $columnSplits, rowSplits: $rowSplits) { chart in
                    SecondaryChartPane(chart: chart, cell: items.firstIndex { $0.id == chart.id })
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
        // A chart set by hand whose cell is gone lets go of its stock.
        .onChange(of: count) {
            workspace.secondaryPins = workspace.secondaryPins.filter { $0.value < count }
            if !isPaused { lastGainers = []; syncWithGainers() }
        }
        // A chart set or let go by hand, or Reset: the gainers fill the cells around the ones set by hand.
        .onChange(of: workspace.secondaryPins) {
            if !isPaused { lastGainers = []; syncWithGainers() }
        }
        // Another list: the charts still in its top N stay, the rest load its stocks.
        .onChange(of: workspace.chartsWindowList) {
            if !isPaused { start() }
        }
        .onChange(of: workspace.chartsWindowResets) {
            workspace.resetViews(of: workspace.secondaryCharts, zoom: layout == .all ? allZoom : customZoom, broker: broker)
        }
        .onChange(of: layout) { applyZoom() }
        .onChange(of: allZoom) { zoomMoved(to: $1) }
        .onChange(of: customZoom) { zoomMoved(to: $1) }
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
            .help(layout == .all ? "Show the custom grid set by the sliders" : "Show the top 18, 6×3")
            Picker("", selection: Binding(get: { workspace.chartsWindowList }, set: { workspace.chartsWindowList = $0 })) {
                ForEach(ScannerKind.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            .help("The list these charts follow (the main window's stay on theirs). With this window in front: "
                  + ScannerKind.shortcutHelp.replacingOccurrences(of: "shows the list and loads it into the chart grid", with: "switches it"))
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

    /// The Zoom slider moved, or a swipe moved it (that zoomed the charts already, see `zoomChartsWindow`).
    private func zoomMoved(to zoom: Double) {
        if workspace.swipedChartsWindowZoom == zoom {
            workspace.swipedChartsWindowZoom = nil
            return
        }
        applyZoom()
    }

    /// Sets every chart's default zoom for the current view and zooms them to it.
    private func applyZoom() {
        workspace.setZoom(layout == .all ? allZoom : customZoom, of: workspace.secondaryCharts, broker: broker)
    }

    private func start() {
        lastGainers = []
        broker.setScanner(SecondaryCharts.scan(workspace.chartsWindowList), owner: SecondaryCharts.scannerOwner)
        syncWithGainers()
    }

    /// Stops the scanner and empties every chart, cancelling their data.
    private func stop() {
        // A chart here was selected: the main window's last one is again.
        if ChartModel.isChartsWindow(workspace.selectedChartID) {
            workspace.selectedChartID = workspace.lastMainChartID
            workspace.isChartSelected = false
        }
        broker.setScanner(nil, owner: SecondaryCharts.scannerOwner)
        lastGainers = []
        workspace.secondaryPins = [:]
        workspace.secondaryDisplaced = [:]
        for chart in workspace.secondaryCharts { workspace.clear(chart, broker: broker) }
    }

    /// Fills the charts not set by hand with the top gainers, as many as there are cells left around
    /// the ones set by hand; the other charts are emptied.
    private func syncWithGainers() {
        let pins = workspace.secondaryPins
        // Less the stocks the charts set by hand replaced.
        let displaced = Set(pins.keys.compactMap { workspace.secondaryDisplaced[$0] })
        let gainers = (broker.scans[SecondaryCharts.scannerOwner]?.symbols ?? []).filter { !displaced.contains($0) }
        guard !gainers.isEmpty, gainers != lastGainers else { return }
        lastGainers = gainers
        workspace.fill(workspace.secondaryCharts.filter { pins[$0.id] == nil },
                       withTop: count - pins.values.filter { $0 < count }.count, of: gainers, broker: broker)
    }

    /// The charts in grid order: one set by hand in its own cell, the others in gainer rank order around them.
    private var items: [ChartModel] {
        let pins = workspace.secondaryPins
        let pinned = Dictionary(pins.map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        var rest = workspace.ranked(workspace.secondaryCharts.filter { pins[$0.id] == nil }, by: lastGainers)[...]
        return (0..<workspace.secondaryCharts.count).compactMap { cell in
            if let id = pinned[cell], let chart = workspace.secondaryCharts.first(where: { $0.id == id }) { return chart }
            return rest.popFirst()
        }
    }
}

/// A Charts window chart pane: clicking it selects it, as a main-window chart (see `ChartPane`).
/// ⌃-click, the what-if, its lines and hover P/L work as on the main charts.
struct SecondaryChartPane: View {
    @Environment(Broker.self) private var broker
    @Environment(\.sideColors) private var sideColors
    @Environment(Workspace.self) private var workspace
    let chart: ChartModel
    /// Its place in the grid, which a symbol typed into it keeps.
    var cell: Int?

    @AppStorage(SecondaryCharts.layoutKey) private var layout: SecondaryCharts.Layout = .all
    @AppStorage(SecondaryCharts.allZoomKey) private var allZoom: Double = ChartModel.initialVisibleBars
    @AppStorage(SecondaryCharts.customZoomKey) private var customZoom: Double = ChartModel.initialVisibleBars
    @State private var symbolText = ""
    /// The symbol box is being edited: only a click on it starts that (see `SymbolField`).
    @State private var symbolFocused = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            TradingChart(chart: chart, onTrade: { workspace.selectedChartID = chart.id }) { factor in
                // Every chart in this window, from the zoom on screen; the header's Zoom slider follows.
                if layout == .all {
                    allZoom = workspace.zoomChartsWindow(by: factor, from: chart, sliderZoom: allZoom, broker: broker)
                } else {
                    customZoom = workspace.zoomChartsWindow(by: factor, from: chart, sliderZoom: customZoom, broker: broker)
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay { ChartOutline(chart: chart) }
        .simultaneousGesture(TapGesture().onEnded { workspace.selectedChartID = chart.id })
        // The header's buying and short selling power, kept current while selected (as every main chart's is;
        // a whole grid of them here would ask IB too often).
        .task(id: workspace.selectedChartID == chart.id ? chart.symbol : "") {
            guard workspace.selectedChartID == chart.id, !chart.symbol.isEmpty else { return }
            while !Task.isCancelled {
                broker.refreshMarginSize(symbol: chart.symbol)
                try? await Task.sleep(for: .seconds(5))
            }
        }
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
            SymbolField(text: $symbolText, isFocused: $symbolFocused) {
                // Typed by hand: the chart keeps it and its cell; an emptied field gives it back to the gainers.
                let symbol = ForexPair.normalize(symbolText)
                if symbol.isEmpty {
                    workspace.secondaryDisplaced[chart.id] = nil
                    workspace.secondaryPins[chart.id] = nil
                } else {
                    // The stock it showed while following the gainers leaves the charts, so nothing else moves.
                    if workspace.secondaryPins[chart.id] == nil, !chart.symbol.isEmpty {
                        workspace.secondaryDisplaced[chart.id] = chart.symbol
                    }
                    if symbol != chart.symbol { workspace.load(symbol, into: chart, broker: broker) }
                    if let cell { workspace.secondaryPins[chart.id] = cell }
                }
                symbolText = chart.symbol
                symbolFocused = false
            }
            .frame(width: 70)
            ChartHeaderInfo(chart: chart)
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(broker.positionTint(chart.symbol, colors: sideColors))
    }
}
