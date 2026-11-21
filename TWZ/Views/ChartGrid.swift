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
//  bar's Reset, and the gainers skip it. The stock it showed leaves the grid meanwhile, so setting it
//  moves no other chart; later, a gainer that would have been in its cell goes to the next free cell,
//  and the rest move up one each. A list's load button makes the grid follow that list (its scanner and filters) in place
//  of the gainers, the same way, until Reset; charts set by hand let go of their stock. A stock shown twice (set by hand, and a gainer in its own cell) is on 5m in the second
//  chart to show it next to the first's 1m, or 1m next to anything else; both are highlighted while
//  either is selected (see `ChartPane`).
//  Every chart trades like any other (see `ChartPane`); clicking one selects it, so hotkeys and order
//  shortcuts go to its symbol. A chart that loses its cell to a smaller grid is emptied; if it was
//  selected, no chart is selected.
//  The account bar's timeframe switch (or ⌥1–6, ⌃1–6, ⇧1–6) sets every chart; a chart's own switch changes just that one,
//  until it gets a new gainer, Reset or the account bar's switch. The Zoom slider sets every chart's
//  default zoom, and Reset puts every chart's view back to it (as double-clicking a chart does).
//  Switching a chart's timeframe keeps its view, only the candles change: as much time on screen, the
//  right edge at the same time; or with Settings › Appearance's Keep the view off, each timeframe goes
//  back to its own zoom and place (see `Broker.loadChart`). Where a chart was left on a stock and timeframe, zoom and place, is kept
//  too, across relaunches: a chart coming back to them, after a list switched and back, say, picks up
//  there, until Reset, or a right-click or double-click on it (see `ChartViews`). Each list keeps its own
//  views, lit scale and zoom set by hand, so switching lists and back finds them as they were. A stock a chart wasn't
//  left on (a list loaded, a new gainer) keeps the chart's zoom and place as they are.
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
    static let scanKey = "mainGridScan"
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
    /// The symbols the grid follows: the top gainers, or the list loaded with a list's load button.
    private var gainers: [String] { broker.scans[MainGrid.scannerOwner]?.symbols ?? [] }
    private var scan: ScanSpec { workspace.gridScan ?? SecondaryCharts.gainersScan }

    var body: some View {
        SplitGrid(columns: columns, rows: rows, items: cells.compactMap(workspace.chart(id:)), gap: gap,
                  columnSplits: $columnSplits, rowSplits: $rowSplits) { chart in
            ChartPane(chart: chart)
        }
        .onAppear {
            workspace.syncGridScale(to: broker)
            broker.restoreChartViews(workspace.mainCharts, zoom: zoom)
            // A scale picked before the relaunch goes on.
            if let scale = broker.gridScale {
                for chart in workspace.mainCharts where !chart.adjustedByHand {
                    scale.apply(to: chart)
                    if let manual = workspace.manualZoom { chart.visibleBars = manual }
                }
            }
            workspace.arrangeMainGrid(columns: columns, rows: rows, gainers: gainers, broker: broker)
            broker.setScanner(scan, owner: MainGrid.scannerOwner)
            follow()
        }
        // A list's load button, or Reset: the grid's scanner follows.
        .onChange(of: workspace.gridScan) { broker.setScanner(scan, owner: MainGrid.scannerOwner) }
        .onChange(of: [columns, rows]) {
            workspace.arrangeMainGrid(columns: columns, rows: rows, gainers: gainers, broker: broker)
            follow()
        }
        .onChange(of: gainers) { follow() }
        // Reset gives the cells set by hand back to their gainers.
        .onChange(of: workspace.manualChartIDs) { follow() }
        .onChange(of: workspace.gainerResets) {
            follow()
            workspace.setMainTimeframe(timeframe, broker: broker)
            workspace.resetViews(of: workspace.mainCharts, zoom: zoom, broker: broker, timeframe: timeframe)
        }
        .onChange(of: zoom) { old, new in
            // A swipe has zoomed the charts already (see `Workspace.zoomGrid`).
            if workspace.swipedGridZoom == new {
                workspace.swipedGridZoom = nil
                return
            }
            workspace.setZoom(new, of: workspace.mainCharts, broker: broker, from: old)
        }
        .onChange(of: workspace.gridScale(workspace.activeScale)) { workspace.syncGridScale(to: broker) }
        .onChange(of: workspace.manualZoom) { workspace.syncGridScale(to: broker) }
        .onChange(of: timeframe) { _, new in workspace.setMainTimeframe(new, broker: broker) }
        .onChange(of: workspace.layoutLoads) {
            columnSplits = Self.splits("mainChartColumnSplits", legacyKey: "chartColumnSplit")
            rowSplits = Self.splits("mainChartRowSplits", legacyKey: "chartRowSplit")
        }
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
            handDisplaced[chart.id] = nil
        }
        if !shown.contains(selectedChartID) {
            selectedChartID = mainCells[0]
            isChartSelected = false
        }
    }

    /// Shows the top gainers in reading order, skipping the cells set by hand, which keep their own
    /// stock until Reset: the nth free cell shows gainer n.
    /// A chart whose stock is still wanted moves to its cell instead of reloading, and keeps its
    /// timeframe; the others load theirs on `timeframe`, or on the other of 1m / 5m where a chart set
    /// by hand already shows it. Past the scanner's last row, charts are emptied.
    func followGainers(_ gainers: [String], timeframe: Timeframe, broker: Broker) {
        guard !gainers.isEmpty else { return }
        var cells = mainCells
        let following = cells.indices.filter { !manualChartIDs.contains(cells[$0]) }
        let displaced = displacedGainers
        var ranks: [String] = []
        for symbol in gainers where !symbol.isEmpty && !ranks.contains(symbol) && !displaced.contains(symbol)
            && ranks.count < cells.count {
            ranks.append(symbol)
        }
        var wanted: [Int: String] = [:]
        for (rank, cell) in following.enumerated() { wanted[cell] = rank < ranks.count ? ranks[rank] : "" }

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
                load(symbol, timeframe: self.timeframe(showing: symbol, in: chart, otherwise: timeframe),
                     into: chart, broker: broker)
            }
        }
        // After a list switch, charts that kept their stock take this list's view of it.
        broker.adoptList(cells.compactMap(chart(id:)))
        notePlaces()
        showPendingFocus(broker: broker)
    }

    /// A list's load button: the grid follows the list's scanner in place of the gainers, until Reset,
    /// as many rows as it has cells; charts set by hand let go of their stock. The list's current
    /// `symbols` show right away, in reading order (a chart already showing one moves to its cell instead
    /// of reloading), until the grid's own scan of the list comes in.
    func loadList(_ symbols: [String], scan: ScanSpec, timeframe: Timeframe, broker: Broker) {
        // The grid's scanner switches first, so the gainers it still holds don't follow in meanwhile.
        let spec = ScanSpec(kind: scan.kind, filter: scan.filter, rows: ScannerKind.maxRowCount)
        // A double-click waiting for another list gives up (see `showChart`).
        if pendingFocus?.place.list != Self.listKey(spec) { pendingFocus = nil }
        gridScan = spec
        // The list's own views, lit scale and zoom set by hand, before its charts load.
        syncGridScale(to: broker)
        broker.setScanner(spec, owner: MainGrid.scannerOwner)
        manualChartIDs = []
        handDisplaced = [:]
        followGainers(symbols, timeframe: timeframe, broker: broker)
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

    /// ⇧-clicking a scale button in the top bar: the selected chart's view, saved under `slot`; false
    /// with no chart selected.
    func saveScale(_ slot: Int) -> Bool {
        guard isChartSelected, let chart = chart(id: selectedChartID), !chart.symbol.isEmpty else { return false }
        chartScales[slot] = ChartScale(of: chart)
        activeScale = slot
        manualZoom = nil
        return true
    }

    /// Every chart in the grid takes the view saved under `slot`, but those adjusted by hand when
    /// `sparingAdjusted` (see `ChartModel.adjustedByHand`), and so does every one loading a stock or
    /// timeframe from then on (see `activeScale`); false while none is.
    func applyScale(_ slot: Int, sparingAdjusted: Bool) -> Bool {
        guard let scale = gridScale(slot) else { return false }
        for chart in mainCells.compactMap(chart(id:)) where !chart.symbol.isEmpty && !(sparingAdjusted && chart.adjustedByHand) {
            scale.apply(to: chart)
        }
        activeScale = slot
        return true
    }

    /// Clicking scale button `slot` (`byClick`): lit, it goes off; otherwise the
    /// charts take it and it lights (see `applyScale`).
    /// Either way the scale's own zoom replaces the one set with the Zoom slider or ⇧-swipe
    /// (`manualZoom`). A click also resets the charts adjusted by hand (`ChartModel.adjustedByHand`, also
    /// those of stocks not on screen), and on the lit scale does that rather than turn it off while there's
    /// anything to reset; without `byClick` charts adjusted by hand stay as they are. Says which in the
    /// status line; beeps with nothing saved.
    func pickScale(_ slot: Int, byClick: Bool, broker: Broker) {
        let shown = mainCells.compactMap(chart(id:)).filter { !$0.symbol.isEmpty }
        let anyByHand = manualZoom != nil || shown.contains(where: \.adjustedByHand)
        if activeScale == slot, !byClick || !anyByHand {
            // Lit: off again, so charts keep their own views as stocks change.
            activeScale = nil
            broker.say("Scale \(slot) off: charts keep their own views")
            return
        }
        if gridScale(slot) != nil {
            manualZoom = nil
            if byClick { broker.forgetChartAdjustments(of: mainCharts) }
        }
        guard applyScale(slot, sparingAdjusted: !byClick) else {
            NSSound.beep()
            broker.say("Nothing saved as scale \(slot) yet: ⇧-click its number in the top bar to save the selected chart's view")
            return
        }
        let spared = byClick ? 0 : shown.filter(\.adjustedByHand).count
        broker.say("Scale \(slot) on every chart, also as lists change (pick it again to turn it off)"
                   + (spared > 0 ? "; \(spared) chart\(spared == 1 ? "" : "s") adjusted by hand kept as \(spared == 1 ? "it is" : "they are")" : ""))
    }

    /// ⇧-, ⌘-, ⌥- or ⌃-swipe on main chart `chart`: every main chart zooms by `factor` from the zoom on screen,
    /// the swiped chart's (or, with it keeping its own zoom, see `GridZoom`, that of a chart following the
    /// grid), not from the Zoom slider's: that can be another (a timeframe's own zoom, a view set's, a
    /// stock's kept view), and the charts jumped to it. As far as zooming one chart goes: in to 15 bars, out
    /// to all the bars the grid's charts have loaded (older ones load as the view reaches them), never
    /// jumping in from further out. The new zoom, for the Zoom slider.
    func zoomGrid(by factor: Double, from chart: ChartModel, sliderZoom: Double, broker: Broker) -> Double {
        let shown = mainCells.compactMap(self.chart(id:))
        let base = !GridZoom.resetsAdjusted && chart.adjustedByHand
            ? shown.first { !$0.adjustedByHand && !$0.symbol.isEmpty }?.visibleBars ?? sliderZoom
            : chart.visibleBars
        guard base > 0 else { return sliderZoom }
        let most = shown.map { Double($0.bars.count) }.max() ?? 0
        let zoom = min(max(ChartModel.maxVisibleBars, most, base), max(15, base * factor))
        setZoom(zoom, of: mainCharts, broker: broker, by: zoom / base)
        if zoom != sliderZoom { swipedGridZoom = zoom }
        return zoom
    }

    /// Tells the broker what main charts loading now go by: the grid's list (each keeps its own views),
    /// its lit scale and its zoom set by hand.
    func syncGridScale(to broker: Broker) {
        broker.viewList = gridListKey
        broker.gridScale = NumberButtons.areScales ? gridScale(activeScale) : nil
        broker.gridZoomOverride = manualZoom
    }

    /// ⇧-clicking a number with the numbers as view sets: every main chart's zoom and place on every
    /// timeframe, saved under `slot` (see `ViewSet`).
    func saveViewSet(_ slot: Int, broker: Broker) {
        broker.keepChartViews(of: mainCharts)
        viewSets[slot] = ViewSet(views: broker.mainChartViews,
                                 zooms: Dictionary(uniqueKeysWithValues: mainCharts.map { ($0.id, $0.zooms) }))
        activeViewSet = slot
        broker.say("View set \(slot) saved: every chart's zoom and place on every timeframe")
    }

    /// Clicking a number, or ⇧ and it, with the numbers as view sets: every main
    /// chart's zoom and place on every timeframe go back to those saved under `slot`, and it lights; lit,
    /// it goes off (the charts stay as they are). Beeps with nothing saved.
    func pickViewSet(_ slot: Int, broker: Broker) {
        if activeViewSet == slot {
            activeViewSet = nil
            broker.say("View set \(slot) off: charts keep their views as they are")
            return
        }
        guard let set = viewSets[slot] else {
            NSSound.beep()
            broker.say("Nothing saved as view set \(slot) yet: ⇧-click its number in the top bar to save every chart's zoom and place")
            return
        }
        putBack(set, broker: broker)
        activeViewSet = slot
        broker.say("View set \(slot): every chart's zoom and place on every timeframe as saved")
    }

    /// Every main chart's zoom and place on every timeframe as `set` has them.
    private func putBack(_ set: ViewSet, broker: Broker) {
        broker.replaceMainChartViews(with: set.views)
        for chart in mainCharts {
            chart.zooms = set.zooms[chart.id] ?? [:]
            broker.restoreView(of: chart)
        }
    }

    /// The charts back to the lit number as saved (no shortcut for now): a view set puts every chart's zoom and place back,
    /// a scale gives every chart its view, own zoom included (dropping the zoom set by hand and the charts
    /// adjusted by hand). False with no number lit.
    func reapplyNumber(broker: Broker) -> Bool {
        // The lit number, or with none lit (after Reset, say) the one last saved or picked, lit again.
        if NumberButtons.areScales {
            guard let slot = activeScale ?? lastScale, gridScale(slot) != nil else { return false }
            manualZoom = nil
            broker.forgetChartAdjustments(of: mainCharts)
            return applyScale(slot, sparingAdjusted: false)
        }
        guard let slot = activeViewSet ?? lastViewSet, let set = viewSets[slot] else { return false }
        putBack(set, broker: broker)
        activeViewSet = slot
        return true
    }

    /// The scale saved under button `slot`, if any.
    func gridScale(_ slot: Int?) -> ChartScale? {
        slot.flatMap { chartScales[$0] }
    }

    /// ⌥0: every other chart in the grid takes `source`'s view: as much time on screen (as many bars on
    /// its timeframe), its right edge at the same time (or as far past the latest bar, while `source`'s
    /// is there), and its prices moved and squeezed alike. A stock with fewer bars ends up as far back as
    /// it goes, and loads older ones.
    func matchViews(to source: ChartModel) {
        let bars = source.bars
        // The time of the last bar on screen, while scrolled back.
        let edge: Date? = source.scrollBack > 0 && !bars.isEmpty
            ? bars[min(bars.count - 1, max(0, Int((Double(bars.count) - source.scrollBack).rounded()) - 1))].time : nil
        for chart in mainCells.compactMap(chart(id:)) where chart !== source && !chart.symbol.isEmpty {
            let ratio = ChartScale.barRatio(from: source.timeframe, to: chart.timeframe)
            chart.visibleBars = min(max(ChartModel.maxVisibleBars, Double(chart.bars.count)), max(15, source.visibleBars * ratio))
            if let edge, let first = chart.bars.first {
                let i = CandleChart.barIndex(of: edge, in: chart.bars, barSeconds: chart.timeframe.barSeconds)
                    ?? (edge < first.time ? 0 : chart.bars.count - 1)
                chart.scrollBack = Double(chart.bars.count - 1 - i)
            } else {
                chart.scrollBack = source.scrollBack * ratio
            }
            chart.priceShift = source.priceShift
            chart.priceScale = source.priceScale
            chart.adjustedByHand = false
        }
    }

    /// The second chart of a stock: 5m next to 1m, 1m next to anything else.
    private static func timeframe(nextTo first: Timeframe) -> Timeframe {
        first == .m1 ? .m5 : .m1
    }
}

/// A chart view saved under one of the top bar's scale buttons: its zoom, how far back from the latest
/// bar (so it's as useful later), and its prices moved and squeezed, on its timeframe; a chart on
/// another one takes as much time (see `Workspace.applyScale`).
struct ChartScale: Codable, Equatable {
    var timeframe: Timeframe
    var visibleBars: Double
    var scrollBack: Double
    var priceShift: Double
    var priceScale: Double

    static let storageKey = "chartScales"
    static let activeKey = "activeChartScale"
    static let manualZoomKey = "manualGridZoom"
    static let slots = [1, 2, 3, 4, 5]

    /// The scale a 1–5 key picks with ⇧ (number row or keypad).
    static func slot(keyCode: UInt16) -> Int? {
        [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 83: 1, 84: 2, 85: 3, 86: 4, 87: 5][keyCode]
    }

    init(of chart: ChartModel) {
        timeframe = chart.timeframe
        visibleBars = chart.visibleBars
        scrollBack = chart.scrollBack
        priceShift = chart.priceShift
        priceScale = chart.priceScale
    }

    func apply(to chart: ChartModel) {
        let ratio = Self.barRatio(from: timeframe, to: chart.timeframe)
        chart.visibleBars = min(max(ChartModel.maxVisibleBars, Double(chart.bars.count)), max(15, visibleBars * ratio))
        chart.scrollBack = scrollBack * ratio
        chart.priceShift = priceShift
        chart.priceScale = priceScale
    }

    /// Bars of one timeframe in the other's; daily bars count as they are.
    static func barRatio(from: Timeframe, to: Timeframe) -> Double {
        from.barSeconds.flatMap { s in to.barSeconds.map { s / $0 } } ?? 1
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
