//
//  ColoredView.swift
//  TWZ
//
//  The Colored list (⌘⇧C, in the main window and the Charts windows): only the tickers given a color (⌥⇧ and a
//  color's letter, see `StockColor`), two charts each side by side: the ticker's chart on the grid's timeframe, and
//  right of it a close-up on 5m. Forex pairs take the left side of the grid, stocks the right (a column of pairs
//  at a time, from the right); each side in order down a column, then down the next. In the grid as the sliders have it: when the pairs don't all fit, every ticker gets
//  its chart and none a close-up.
//  The charts zoom and pan together, and so do the close-ups, apart from them. The close-ups start at the zoom
//  the Charts window's forex charts have (see `Workspace.closeUpStartZoom`); the Zoom slider and Reset leave them
//  at theirs.
//

import SwiftUI

/// The Colored list's top bar button (main window and Charts windows): its charts outlined in their tickers' colors, or
/// not. Saved; other lists keep their colors either way.
struct ColoredColorsButton: View {
    static let hidesKey = "coloredHidesColors"
    @AppStorage(Self.hidesKey) private var hides = false

    var body: some View {
        ForexListButton(title: "Colors", lit: !hides,
                        help: hides ? "Outline the charts here in their tickers' colors again" : "Hide the tickers' colors here (the charts keep them on the other lists)") {
            hides.toggle()
        }
    }
}

/// A cell of the Colored list's grid: its ticker, as its chart or its 5m close-up.
struct ColoredCell: Equatable {
    var symbol: String
    var closeUp: Bool
}

enum ColoredLayout {
    static let closeUpTimeframe = Timeframe.m5

    /// What each cell of a grid with `rowColumns` (cells in each row, top first) shows; nil: nothing.
    static func plan(forex: [String], stocks: [String], rowColumns: [Int]) -> [ColoredCell?] {
        let starts = rowColumns.indices.map { rowColumns[..<$0].reduce(0, +) }
        var cells = [ColoredCell?](repeating: nil, count: rowColumns.reduce(0, +))
        // Each pair: (row, pair from the row's left, pairs in the row).
        let pairs = rowColumns.indices.flatMap { row in (0..<rowColumns[row] / 2).map { (row: row, pair: $0, of: rowColumns[row] / 2) } }
        if forex.count + stocks.count <= pairs.count {
            // Stocks in the rightmost pairs, a column of pairs at a time, top down; pairs on the rest, in reading order.
            let rightmost = pairs.indices.sorted {
                let a = pairs[$0], b = pairs[$1]
                return (a.of - a.pair, a.row) < (b.of - b.pair, b.row)
            }
            let stockPairs = Set(rightmost.prefix(stocks.count))
            var stockQueue = stocks[...], forexQueue = forex[...]
            // Each side fills a column of pairs top to bottom, then the next column.
            let columnOrder = pairs.indices.sorted { (pairs[$0].pair, pairs[$0].row) < (pairs[$1].pair, pairs[$1].row) }
            for i in columnOrder {
                let p = pairs[i]
                guard let symbol = stockPairs.contains(i) ? stockQueue.popFirst() : forexQueue.popFirst() else { continue }
                let cell = starts[p.row] + p.pair * 2
                cells[cell] = ColoredCell(symbol: symbol, closeUp: false)
                cells[cell + 1] = ColoredCell(symbol: symbol, closeUp: true)
            }
            return cells
        }
        // No room for the close-ups: the charts alone, stocks in the rightmost cells.
        let n = cells.count
        let s = min(stocks.count, max(n - forex.count, n / 2))
        let places = rowColumns.indices.flatMap { row in (0..<rowColumns[row]).map { (row: row, column: $0, of: rowColumns[row]) } }
        let rightmost = places.indices.sorted {
            let a = places[$0], b = places[$1]
            return (a.of - a.column, a.row) < (b.of - b.column, b.row)
        }
        let stockCells = Set(rightmost.prefix(s))
        var stockQueue = stocks.prefix(s)[...], forexQueue = forex[...]
        // Each side fills a column top to bottom, then the next column.
        let columnOrder = places.indices.sorted { (places[$0].column, places[$0].row) < (places[$1].column, places[$1].row) }
        for i in columnOrder {
            guard let symbol = stockCells.contains(i) ? stockQueue.popFirst() : forexQueue.popFirst() else { continue }
            cells[i] = ColoredCell(symbol: symbol, closeUp: false)
        }
        return cells
    }
}

extension Workspace {
    /// The tickers given a color, pairs first, each in the colors' order.
    var coloredSymbols: [String] {
        let byColor = StockColor.allCases.compactMap { color in stockColors.first { $0.value == color }?.key }
        // Where ⌘ and the arrow keys put them; ones not moved yet after those, in the colors' order.
        let rank = Dictionary(coloredOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let all = byColor.enumerated().sorted { (rank[$0.element] ?? .max, $0.offset) < (rank[$1.element] ?? .max, $1.offset) }.map(\.element)
        return all.filter(ForexPair.isForex) + all.filter { !ForexPair.isForex($0) }
    }

    /// ⌘ and an arrow key on the Colored list: `symbol` swaps places with the ticker above or below it (`step` ±1), or
    /// beside it in the next column (± the grid's `rows`), among the pairs or the stocks, as it's one. False when
    /// there's no ticker there.
    func moveColored(_ symbol: String, by step: Int) -> Bool {
        let all = coloredSymbols
        let forex = ForexPair.isForex(symbol)
        var side = all.filter { ForexPair.isForex($0) == forex }
        guard let i = side.firstIndex(of: symbol), side.indices.contains(i + step) else { return false }
        side.swapAt(i, i + step)
        let other = all.filter { ForexPair.isForex($0) != forex }
        coloredOrder = forex ? side + other : other + side
        return true
    }

    /// The zoom the close-ups start at: the first Charts window's forex charts' (on Forex or Forex + Active), else
    /// the close-ups' last, else `fallback`.
    func closeUpStartZoom(fallback: Double) -> Double {
        let forex = chartsWindow(.first).charts.first { ForexPair.isForex($0.symbol) && !closeUpChartIDs.contains($0.id) && !$0.bars.isEmpty }
        return forex?.visibleBars ?? closeUpZoom ?? fallback
    }

    /// Lays `charts` (in cell order) out to `plan` (see `ColoredLayout`): a chart already showing a cell's ticker
    /// on its timeframe moves there, the others load theirs; charts left over are emptied. The charts in their new
    /// cell order.
    func layOutColored(_ charts: [ChartModel], plan: [ColoredCell?], timeframe: Timeframe, broker: Broker) -> [ChartModel] {
        var pool = charts
        var placed = [ChartModel?](repeating: nil, count: charts.count)
        func tf(of cell: ColoredCell) -> Timeframe { cell.closeUp ? ColoredLayout.closeUpTimeframe : timeframe }
        // Already showing it: stays as it is.
        for (i, cell) in plan.enumerated() where i < placed.count {
            guard let cell, let k = pool.firstIndex(where: {
                $0.symbol == cell.symbol && $0.timeframe == tf(of: cell) && closeUpChartIDs.contains($0.id) == cell.closeUp
            }) else { continue }
            placed[i] = pool.remove(at: k)
        }
        var loaded: [(ChartModel, ColoredCell)] = []
        for (i, cell) in plan.enumerated() where i < placed.count && placed[i] == nil {
            guard let cell else { continue }
            // The same ticker on another timeframe, else an empty chart, else any.
            let k = pool.firstIndex { $0.symbol == cell.symbol } ?? pool.firstIndex { $0.symbol.isEmpty } ?? 0
            guard k < pool.count else { break }
            let chart = pool.remove(at: k)
            placed[i] = chart
            loaded.append((chart, cell))
        }
        for i in placed.indices where placed[i] == nil && !pool.isEmpty {
            let chart = pool.removeFirst()
            clear(chart, broker: broker)
            closeUpChartIDs.remove(chart.id)
            placed[i] = chart
        }
        let zoom = closeUpZoom
        for (chart, cell) in loaded {
            if cell.closeUp { closeUpChartIDs.insert(chart.id) } else { closeUpChartIDs.remove(chart.id) }
            if chart.symbol != cell.symbol {
                load(cell.symbol, timeframe: tf(of: cell), into: chart, broker: broker)
            } else if chart.timeframe != tf(of: cell) {
                setTimeframe(tf(of: cell), of: [chart], broker: broker)
            }
            if cell.closeUp, let zoom { setZoom(zoom, of: [chart], broker: broker) }
        }
        return placed.compactMap { $0 }
    }

    /// Leaving the Colored list: its close-ups among `charts` are emptied and go back to `timeframe`, for the next
    /// list to fill as it does the others (only the Colored list shows a ticker twice).
    func leaveColored(_ charts: [ChartModel], timeframe: Timeframe, broker: Broker) {
        let closeUps = charts.filter { closeUpChartIDs.contains($0.id) }
        for chart in closeUps {
            closeUpChartIDs.remove(chart.id)
            clear(chart, broker: broker)
        }
        setTimeframe(timeframe, of: closeUps, broker: broker)
    }

    /// The charts in `charts` the grid's timeframe, Zoom slider and Reset set: on the Colored list, not the close-ups.
    func gridCharts(_ charts: [ChartModel], list: ScannerKind?) -> [ChartModel] {
        list == .colored ? charts.filter { !closeUpChartIDs.contains($0.id) } : charts
    }

    /// The main grid on the Colored list: its cells laid out to the colored tickers (see `ColoredLayout`).
    func followColored(timeframe: Timeframe, broker: Broker) {
        let symbols = coloredSymbols
        let plan = ColoredLayout.plan(forex: symbols.filter(ForexPair.isForex), stocks: symbols.filter { !ForexPair.isForex($0) },
                                      rowColumns: MainGrid.rowColumns(columns: mainColumns, rows: mainRows))
        let cells = layOutColored(mainCells.compactMap(chart(id:)), plan: plan, timeframe: timeframe, broker: broker).map(\.id)
        if cells != mainCells { mainCells = cells }
    }
}
