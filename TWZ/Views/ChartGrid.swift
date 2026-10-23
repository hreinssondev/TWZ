//
//  ChartGrid.swift
//  TWZ
//
//  The main window's chart grid, 2×2 up to 8×4, sized by the Cols / Rows sliders in the account bar.
//  The four charts keep the top-left 2×2; every other cell is a compact gainer chart.
//  Every chart follows the top gainers (its own scanner) in reading order: the first cell shows the
//  top gainer, the next cell the second, and so on. A gainer chart that already shows a symbol moves
//  to that symbol's cell instead of reloading; the four charts load theirs.
//  Two kinds of chart keep their symbol and cell instead: one given a symbol by hand (a list, its
//  symbol field) until the account bar's Reset, and the selected one, so a hotkey never goes to a
//  symbol that changed under it. Reset also puts the selected chart back on the gainers.
//  Clicking any chart selects it, so hotkeys and order shortcuts go to its symbol. A gainer chart
//  that loses its cell to a smaller grid is emptied; if it was selected, no chart is selected.
//  The Zoom slider sets every chart's default zoom; the gainer charts take the Charts window's timeframe.
//  A grip at every crossing of four charts moves that column and row line together (see `SplitGrid`).
//

import SwiftUI

enum MainGrid {
    static let maxColumns = 8
    static let maxRows = 4
    static let columnsKey = "mainGridColumns"
    static let rowsKey = "mainGridRows"
    static let zoomKey = "mainGridZoom"
    static let scannerOwner = "main-gainers"
    /// Gainer charts for the largest grid: every cell but the four charts'.
    static let gainerCount = maxColumns * maxRows - 4
    /// Gainer chart ids start here; the four charts' are 0–3.
    static let firstGainerID = 200
}

struct ChartGrid: View {
    @Environment(Broker.self) private var broker
    @Environment(Workspace.self) private var workspace
    @AppStorage(MainGrid.columnsKey) private var storedColumns = 2
    @AppStorage(MainGrid.rowsKey) private var storedRows = 2
    @AppStorage(MainGrid.zoomKey) private var zoom: Double = ChartModel.compactDefaultVisibleBars
    @AppStorage(SecondaryCharts.timeframeKey) private var gainerTimeframe: Timeframe = .m1
    /// The chart id in each cell, in reading order, laid out for `arrangedColumns` columns.
    @State private var cellCharts: [Int] = []
    @State private var arrangedColumns = 0
    /// The first gainers since launch fill the selected chart too: it's selected by default, not by choice.
    @State private var hasFollowed = false
    @State private var columnSplits = Self.splits("mainChartColumnSplits", legacyKey: "chartColumnSplit")
    @State private var rowSplits = Self.splits("mainChartRowSplits", legacyKey: "chartRowSplit")

    let gap: CGFloat

    private var columns: Int { min(max(storedColumns, 2), MainGrid.maxColumns) }
    private var rows: Int { min(max(storedRows, 2), MainGrid.maxRows) }

    var body: some View {
        SplitGrid(columns: columns, rows: rows, items: currentCells.compactMap(workspace.chart(id:)), gap: gap,
                  columnSplits: $columnSplits, rowSplits: $rowSplits) { chart in
            if chart.isCompact {
                SecondaryChartPane(chart: chart, selectable: true)
            } else {
                ChartPane(chart: chart)
            }
        }
        .onAppear {
            workspace.setZoom(zoom, of: zoomedCharts)
            arrangeCells()
            broker.setScanner(SecondaryCharts.gainersScan, owner: MainGrid.scannerOwner)
            follow()
        }
        .onChange(of: [columns, rows]) {
            arrangeCells()
            follow()
        }
        .onChange(of: broker.scans[MainGrid.scannerOwner]?.symbols) { follow() }
        .onChange(of: workspace.manualChartIDs) { follow() }
        // The chart left behind follows again.
        .onChange(of: heldSelection) { follow() }
        .onChange(of: workspace.gainerResets) { follow(holdingSelected: false) }
        .onChange(of: zoom) { _, new in workspace.setZoom(new, of: zoomedCharts) }
        .onChange(of: gainerTimeframe) { _, new in
            workspace.setTimeframe(new, of: workspace.mainGainerCharts, broker: broker)
        }
    }

    /// Every chart in the grid takes the Zoom slider's default zoom.
    private var zoomedCharts: [ChartModel] { workspace.charts + workspace.mainGainerCharts }

    /// The selected chart, which keeps its symbol and cell.
    private var heldSelection: Int? { workspace.isChartSelected ? workspace.selectedChartID : nil }

    private var currentCells: [Int] {
        arrangedColumns == columns && cellCharts.count == columns * rows ? cellCharts : arranged()
    }

    /// The cells for the grid's size: the four charts in the top-left 2×2; a gainer chart keeps its
    /// column and row while that cell's still there; the other cells take unused gainer charts.
    private func arranged() -> [Int] {
        let placed: [Int?] = (0..<columns * rows).map { index in
            let column = index % columns, row = index / columns
            if column < 2 && row < 2 { return row * 2 + column }
            guard column < arrangedColumns else { return nil }
            let old = row * arrangedColumns + column
            return old < cellCharts.count && cellCharts[old] >= MainGrid.firstGainerID ? cellCharts[old] : nil
        }
        var unused = workspace.mainGainerCharts.map(\.id).filter { !placed.contains($0) }[...]
        return placed.compactMap { $0 ?? unused.popFirst() }
    }

    /// Fits the cells to the grid's size. Gainer charts left without a cell are emptied and follow
    /// again; if the selected chart was one of them, no chart is selected.
    private func arrangeCells() {
        cellCharts = arranged()
        arrangedColumns = columns
        let shown = Set(cellCharts)
        for chart in workspace.mainGainerCharts where !shown.contains(chart.id) {
            workspace.clear(chart, broker: broker)
            workspace.manualChartIDs.remove(chart.id)
        }
        if !shown.contains(workspace.selectedChartID) {
            workspace.selectedChartID = 0
            workspace.isChartSelected = false
        }
    }

    /// Shows the top gainers in reading order in every chart that follows them: all but the charts
    /// set by hand and the selected one (`holdingSelected` off: after Reset). Their symbols are left
    /// out, so no symbol shows twice. Past the scanner's last row, gainer charts are emptied and the
    /// four charts keep what they show.
    private func follow(holdingSelected: Bool = true) {
        let gainers = broker.scans[MainGrid.scannerOwner]?.symbols ?? []
        guard !gainers.isEmpty else { return }
        var cells = currentCells
        var held = workspace.manualChartIDs
        if holdingSelected, hasFollowed, let selected = heldSelection { held.insert(selected) }
        hasFollowed = true
        let following = cells.indices.filter { !held.contains(cells[$0]) }
        let heldSymbols = Set(cells.filter(held.contains).compactMap { workspace.chart(id: $0)?.symbol })

        var queue: [String] = []
        for symbol in gainers where !symbol.isEmpty && !heldSymbols.contains(symbol) && !queue.contains(symbol) {
            queue.append(symbol)
        }
        var wanted: [Int: String] = [:]
        for (n, cell) in following.enumerated() { wanted[cell] = n < queue.count ? queue[n] : "" }

        // Gainer charts in following cells: one already showing a cell's symbol moves there; the rest
        // fill the remaining cells and load theirs.
        var pool = following.map { cells[$0] }.filter { $0 >= MainGrid.firstGainerID }
        var unfilled: [Int] = []
        for cell in following where cells[cell] >= MainGrid.firstGainerID {
            let symbol = wanted[cell] ?? ""
            if !symbol.isEmpty, let k = pool.firstIndex(where: { workspace.chart(id: $0)?.symbol == symbol }) {
                cells[cell] = pool.remove(at: k)
            } else {
                unfilled.append(cell)
            }
        }
        for cell in unfilled {
            let id = pool.removeFirst()
            cells[cell] = id
            guard let chart = workspace.chart(id: id), let symbol = wanted[cell], chart.symbol != symbol else { continue }
            if symbol.isEmpty { workspace.clear(chart, broker: broker) } else { workspace.load(symbol, into: chart, broker: broker) }
        }
        cellCharts = cells
        arrangedColumns = columns

        for cell in following where cells[cell] < MainGrid.firstGainerID {
            guard let chart = workspace.chart(id: cells[cell]), let symbol = wanted[cell],
                  !symbol.isEmpty, chart.symbol != symbol else { continue }
            workspace.load(symbol, into: chart, broker: broker)
        }
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
