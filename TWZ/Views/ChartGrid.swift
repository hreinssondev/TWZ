//
//  ChartGrid.swift
//  TWZ
//
//  The main window's chart grid, 2×2 up to 8×4, sized by the Cols / Rows sliders in the account bar.
//  Like the Charts window, every chart follows the top gainers (its own scanner) in reading order:
//  the first cell shows the top gainer, the next cell the second, and so on. When the ranking
//  reshuffles, a chart whose stock is still in the top N moves to its new cell and nothing reloads;
//  only charts whose stock dropped out load a new one. The selected chart follows too: the
//  selection moves with it, and stays on it if it gets a new stock.
//  A chart given a stock by hand (a list, its symbol field) keeps it and its cell until the account
//  bar's Reset, and the gainers flow around it. They leave its stock out, unless a gainer chart
//  already shows it: that one keeps it, and the chart set by hand, the second to show it, takes 5m
//  next to its 1m, or 1m next to anything else. Both are highlighted while either is selected
//  (see `ChartPane`).
//  Every chart trades like any other (see `ChartPane`); clicking one selects it, so hotkeys and order
//  shortcuts go to its symbol. A chart that loses its cell to a smaller grid is emptied; if it was
//  selected, no chart is selected.
//  The account bar's timeframe switch sets every chart; a chart's own switch changes just that one,
//  until it gets a new gainer, Reset or the account bar's switch. The Zoom slider sets every chart's
//  default zoom.
//  A grip at every crossing of four charts moves that column and row line together (see `SplitGrid`).
//

import SwiftUI

enum MainGrid {
    static let maxColumns = 8
    static let maxRows = 4
    static let columnsKey = "mainGridColumns"
    static let rowsKey = "mainGridRows"
    static let zoomKey = "mainGridZoom"
    static let timeframeKey = "mainGridTimeframe"
    static let pinsKey = "mainGridPins"
    static let scannerOwner = "main-gainers"

    /// The sliders' values, kept to the grid's range.
    static func columns(_ stored: Int) -> Int { min(max(stored, 2), maxColumns) }
    static func rows(_ stored: Int) -> Int { min(max(stored, 2), maxRows) }
}

struct ChartGrid: View {
    @Environment(Broker.self) private var broker
    @Environment(Workspace.self) private var workspace
    @AppStorage(MainGrid.columnsKey) private var storedColumns = 2
    @AppStorage(MainGrid.rowsKey) private var storedRows = 2
    @AppStorage(MainGrid.zoomKey) private var zoom: Double = ChartModel.initialVisibleBars
    @AppStorage(MainGrid.timeframeKey) private var timeframe: Timeframe = .m1
    @State private var columnSplits = Self.splits("mainChartColumnSplits", legacyKey: "chartColumnSplit")
    @State private var rowSplits = Self.splits("mainChartRowSplits", legacyKey: "chartRowSplit")

    let gap: CGFloat

    private var columns: Int { MainGrid.columns(storedColumns) }
    private var rows: Int { MainGrid.rows(storedRows) }
    private var gainers: [String] { broker.scans[MainGrid.scannerOwner]?.symbols ?? [] }

    var body: some View {
        SplitGrid(columns: columns, rows: rows, items: cells.compactMap(workspace.chart(id:)), gap: gap,
                  columnSplits: $columnSplits, rowSplits: $rowSplits) { chart in
            ChartPane(chart: chart)
        }
        .onAppear {
            workspace.setZoom(zoom, of: workspace.mainCharts)
            workspace.arrangeMainGrid(columns: columns, rows: rows, gainers: gainers, broker: broker)
            broker.setScanner(SecondaryCharts.gainersScan, owner: MainGrid.scannerOwner)
            follow()
        }
        .onChange(of: [columns, rows]) {
            workspace.arrangeMainGrid(columns: columns, rows: rows, gainers: gainers, broker: broker)
            follow()
        }
        .onChange(of: gainers) { follow() }
        // The gainers close up around a chart set by hand, and fill the cells Reset frees.
        .onChange(of: workspace.manualChartIDs) { follow() }
        .onChange(of: workspace.gainerResets) {
            follow()
            workspace.setMainTimeframe(timeframe, broker: broker)
        }
        .onChange(of: zoom) { _, new in workspace.setZoom(new, of: workspace.mainCharts) }
        .onChange(of: timeframe) { _, new in workspace.setMainTimeframe(new, broker: broker) }
        .onChange(of: workspace.mainGridPins) { workspace.saveMainGridPins() }
    }

    /// The workspace's cells, or while those are still laid out for the old size, the new size's.
    private var cells: [Int] {
        workspace.mainColumns == columns && workspace.mainCells.count == columns * rows
            ? workspace.mainCells : workspace.arrangedMainCells(columns: columns, rows: rows, gainers: gainers)
    }

    private func follow() {
        workspace.followGainers(gainers, timeframe: timeframe, broker: broker)
    }

    /// The column or row shares, starting from the 2×2 grid's split from before the grid could grow.
    private static func splits(_ key: String, legacyKey: String) -> SplitStore {
        var store = SplitStore(key: key)
        if store[2] == nil, let share = UserDefaults.standard.object(forKey: legacyKey) as? Double {
            store[2] = [share, 1 - share]
        }
        return store
    }
}

/// The main window's grid (see `ChartGrid`).
extension Workspace {
    /// The cells for a `columns` × `rows` grid. A chart set by hand keeps its column and row while
    /// that cell's still there; the other charts fill the free cells best-ranked first, so those whose
    /// stock is still in the new top N stay; any cells left take charts that weren't shown.
    func arrangedMainCells(columns: Int, rows: Int, gainers: [String]) -> [Int] {
        var cells = [Int?](repeating: nil, count: columns * rows)
        for (index, id) in mainCells.enumerated() where manualChartIDs.contains(id) {
            let column = index % mainColumns, row = index / mainColumns
            if column < columns, row < rows { cells[row * columns + column] = id }
        }
        let following = ranked(mainCells.filter { !manualChartIDs.contains($0) }.compactMap(chart(id:)), by: gainers)
        let unshown = mainCharts.filter { !mainCells.contains($0.id) }
        var spare = (following + unshown).map(\.id)[...]
        return cells.compactMap { $0 ?? spare.popFirst() }
    }

    /// Fits the grid to its sliders. Charts left without a cell are emptied and let go of a stock set
    /// by hand; if the selected chart was one of them, no chart is selected.
    func arrangeMainGrid(columns: Int, rows: Int, gainers: [String], broker: Broker) {
        mainCells = arrangedMainCells(columns: columns, rows: rows, gainers: gainers)
        mainColumns = columns
        let shown = Set(mainCells)
        for chart in mainCharts where !shown.contains(chart.id) {
            clear(chart, broker: broker)
            manualChartIDs.remove(chart.id)
        }
        if !shown.contains(selectedChartID) {
            selectedChartID = mainCells[0]
            isChartSelected = false
        }
    }

    /// Shows the top gainers in reading order in every cell but those set by hand. A chart whose
    /// stock is still wanted moves to its cell instead of reloading, and keeps its timeframe; the
    /// others load theirs on `timeframe`. A stock a chart set by hand shows is left out, unless a
    /// gainer chart already shows it too: that one keeps it. Past the scanner's last row, charts are
    /// emptied.
    func followGainers(_ gainers: [String], timeframe: Timeframe, broker: Broker) {
        guard !gainers.isEmpty else { return }
        var cells = mainCells
        let following = cells.indices.filter { !manualChartIDs.contains(cells[$0]) }
        let byHand = Set(cells.filter(manualChartIDs.contains).compactMap { chart(id: $0)?.symbol })
        let shown = Set(following.compactMap { chart(id: cells[$0])?.symbol })
        var queue: [String] = []
        for symbol in gainers where !symbol.isEmpty && !queue.contains(symbol) && queue.count < following.count
            && (!byHand.contains(symbol) || shown.contains(symbol)) {
            queue.append(symbol)
        }
        var wanted: [Int: String] = [:]
        for (n, cell) in following.enumerated() { wanted[cell] = n < queue.count ? queue[n] : "" }

        // A chart already showing a cell's stock moves there; of two (after Reset), the selected one,
        // or else the one on the grid's timeframe. The rest fill the remaining cells.
        var pool = following.map { cells[$0] }
        var unfilled: [Int] = []
        for cell in following {
            guard let symbol = wanted[cell], !symbol.isEmpty else {
                unfilled.append(cell)
                continue
            }
            let showing = pool.indices.filter { chart(id: pool[$0])?.symbol == symbol }
            if let k = showing.first(where: { pool[$0] == selectedChartID })
                ?? showing.first(where: { chart(id: pool[$0])?.timeframe == timeframe }) ?? showing.first {
                cells[cell] = pool.remove(at: k)
            } else {
                unfilled.append(cell)
            }
        }
        for cell in unfilled { cells[cell] = pool.removeFirst() }
        if cells != mainCells { mainCells = cells }

        for cell in unfilled {
            guard let chart = chart(id: cells[cell]), let symbol = wanted[cell] else { continue }
            if symbol.isEmpty {
                clear(chart, broker: broker)
            } else {
                load(symbol, timeframe: timeframe, into: chart, broker: broker)
            }
        }
    }

    /// The timeframe for `chart` about to show `symbol`: where another chart in the grid already
    /// shows it, 5m next to its 1m and 1m next to anything else; otherwise `otherwise`.
    func timeframe(showing symbol: String, in chart: ChartModel, otherwise: Timeframe) -> Timeframe {
        let first = mainCells.compactMap(self.chart(id:))
            .filter { $0.id != chart.id && $0.symbol == symbol }
            .min { $0.loadOrder < $1.loadOrder }
        return first.map { Self.timeframe(nextTo: $0.timeframe) } ?? otherwise
    }

    /// The account bar's timeframe: every chart takes it, whatever its own switch was set to, but a
    /// chart showing the same stock as one that showed it first takes the other of 1m / 5m.
    func setMainTimeframe(_ timeframe: Timeframe, broker: Broker) {
        var shown: Set<String> = []
        for chart in mainCells.compactMap(chart(id:)).sorted(by: { $0.loadOrder < $1.loadOrder }) {
            let isSecond = !chart.symbol.isEmpty && !shown.insert(chart.symbol).inserted
            setTimeframe(isSecond ? Self.timeframe(nextTo: timeframe) : timeframe, of: [chart], broker: broker)
        }
        setTimeframe(timeframe, of: mainCharts.filter { !mainCells.contains($0.id) }, broker: broker)
    }

    /// The second chart of a stock: 5m next to 1m, 1m next to anything else.
    private static func timeframe(nextTo first: Timeframe) -> Timeframe {
        first == .m1 ? .m5 : .m1
    }
}

/// A small grip at the crossing of two gaps that drags a width and a height together.
struct CrossResizeHandle: View {
    let current: CGSize
    let onChange: (CGSize) -> Void
    let onReset: () -> Void

    @State private var dragStart: CGSize?
    @State private var isHovering = false

    private static let hitSize: CGFloat = 18

    var body: some View {
        let active = dragStart != nil || isHovering
        Circle()
            .fill(Color.primary.opacity(active ? 0.45 : 0.2))
            .frame(width: active ? 10 : 7, height: active ? 10 : 7)
            .frame(width: Self.hitSize, height: Self.hitSize)
            .contentShape(Rectangle())
            .pointerStyle(.frameResize(position: .topLeading, directions: .all))
            .onHover { isHovering = $0 }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = dragStart ?? current
                        dragStart = start
                        onChange(CGSize(width: start.width + value.translation.width,
                                        height: start.height + value.translation.height))
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .onTapGesture(count: 2, perform: onReset)
            .animation(.easeOut(duration: 0.1), value: active)
    }
}
