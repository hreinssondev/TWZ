//
//  ChartGrid.swift
//  TWZ
//
//  The main window's chart grid, 2×2 up to 8×4, sized by the Cols / Rows sliders in the account bar.
//  The four charts keep the top-left 2×2; every other cell is a gainer chart that works as in the
//  Charts window: it follows the top gainers (its own scanner, running only while there are such
//  cells), in rank order. Clicking any chart selects it, so hotkeys and order shortcuts go to its
//  symbol; while a gainer chart is selected, the gainer charts hold their symbols and places (the
//  scanner's updates wait), so the selected symbol never changes under a hotkey. A grid change or
//  the scanner stopping leaves no chart selected instead. The Zoom slider sets every chart's
//  default zoom; the gainer charts take the Charts window's timeframe.
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
}

struct ChartGrid: View {
    @Environment(Broker.self) private var broker
    @Environment(Workspace.self) private var workspace
    @AppStorage(MainGrid.columnsKey) private var storedColumns = 2
    @AppStorage(MainGrid.rowsKey) private var storedRows = 2
    @AppStorage(MainGrid.zoomKey) private var zoom: Double = ChartModel.compactDefaultVisibleBars
    @AppStorage(SecondaryCharts.timeframeKey) private var gainerTimeframe: Timeframe = .m1
    @State private var lastGainers: [String] = []
    @State private var columnSplits = Self.splits("mainChartColumnSplits", legacyKey: "chartColumnSplit")
    @State private var rowSplits = Self.splits("mainChartRowSplits", legacyKey: "chartRowSplit")

    let gap: CGFloat

    private var columns: Int { min(max(storedColumns, 2), MainGrid.maxColumns) }
    private var rows: Int { min(max(storedRows, 2), MainGrid.maxRows) }
    private var gainerCount: Int { columns * rows - 4 }

    var body: some View {
        SplitGrid(columns: columns, rows: rows, items: cells, gap: gap,
                  columnSplits: $columnSplits, rowSplits: $rowSplits) { chart in
            if chart.isCompact {
                SecondaryChartPane(chart: chart, selectable: true)
            } else {
                ChartPane(chart: chart)
            }
        }
        .onAppear {
            workspace.setZoom(zoom, of: zoomedCharts)
            if gainerCount > 0 { start() }
        }
        .onChange(of: gainerCount) { old, new in
            deselectGainerChart()
            if new == 0 {
                stop()
            } else if old == 0 {
                start()
            } else {
                // Charts still in the new top N stay put; the rest are emptied or filled.
                lastGainers = []
                syncWithGainers()
            }
        }
        .onChange(of: broker.scans[MainGrid.scannerOwner]?.symbols) {
            if gainerCount > 0 { syncWithGainers() }
        }
        // Selecting one of the four charts again lets the scanner's waiting update through.
        .onChange(of: isHolding) { _, holding in
            if !holding, gainerCount > 0 { syncWithGainers() }
        }
        .onChange(of: zoom) { _, new in workspace.setZoom(new, of: zoomedCharts) }
        .onChange(of: gainerTimeframe) { _, new in
            workspace.setTimeframe(new, of: workspace.mainGainerCharts, broker: broker)
        }
    }

    /// A gainer chart is selected (or was the last one selected): the gainer charts hold still.
    private var isHolding: Bool { workspace.selectedChart.isCompact }

    /// Leaves no chart selected if a gainer chart is, as it may lose its cell or symbol.
    private func deselectGainerChart() {
        guard isHolding else { return }
        workspace.selectedChartID = 0
        workspace.isChartSelected = false
    }

    /// Every chart in the grid takes the Zoom slider's default zoom.
    private var zoomedCharts: [ChartModel] { workspace.charts + workspace.mainGainerCharts }

    /// The charts in reading order: the four charts in the top-left 2×2, the gainer charts by rank in
    /// the other cells.
    private var cells: [ChartModel] {
        var gainers = workspace.ranked(workspace.mainGainerCharts, by: lastGainers)[...]
        return (0..<columns * rows).compactMap { index in
            let column = index % columns, row = index / columns
            return column < 2 && row < 2 ? workspace.charts[row * 2 + column] : gainers.popFirst()
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

    private func start() {
        lastGainers = []
        broker.setScanner(SecondaryCharts.gainersScan, owner: MainGrid.scannerOwner)
        syncWithGainers()
    }

    /// Stops the scanner and empties the gainer charts, cancelling their data.
    private func stop() {
        broker.setScanner(nil, owner: MainGrid.scannerOwner)
        lastGainers = []
        for chart in workspace.mainGainerCharts { workspace.clear(chart, broker: broker) }
    }

    private func syncWithGainers() {
        guard !isHolding else { return }
        let gainers = broker.scans[MainGrid.scannerOwner]?.symbols ?? []
        guard !gainers.isEmpty, gainers != lastGainers else { return }
        lastGainers = gainers
        workspace.fill(workspace.mainGainerCharts, withTop: gainerCount, of: gainers, broker: broker)
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
