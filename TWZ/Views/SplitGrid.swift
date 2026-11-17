//
//  SplitGrid.swift
//  TWZ
//
//  A chart grid of any size whose column and row lines are dragged at their crossings, and the
//  Cols / Rows / Zoom sliders that size it. Used by the main window's chart grid and the Charts window.
//

import SwiftUI

/// `columns` × `rows` cells filled in reading order from `items`. A grip at every crossing of four
/// cells moves that column line and row line together; double-clicking one goes back to equal shares.
/// One ForEach keyed by item, so a cell's view (and its state) moves with it when the order changes.
struct SplitGrid<Item: Identifiable, Cell: View>: View {
    let columns: Int
    let rows: Int
    let items: [Item]
    let gap: CGFloat
    /// Space around the grid, outside the outer cells.
    let inset: CGFloat
    @Binding var columnSplits: SplitStore
    @Binding var rowSplits: SplitStore
    let cell: (Item) -> Cell

    private static var minCellWidth: CGFloat { 80 }
    private static var minCellHeight: CGFloat { 60 }

    init(columns: Int, rows: Int, items: [Item], gap: CGFloat, inset: CGFloat = 0,
         columnSplits: Binding<SplitStore>, rowSplits: Binding<SplitStore>,
         @ViewBuilder cell: @escaping (Item) -> Cell) {
        self.columns = columns
        self.rows = rows
        self.items = items
        self.gap = gap
        self.inset = inset
        _columnSplits = columnSplits
        _rowSplits = rowSplits
        self.cell = cell
    }

    var body: some View {
        GeometryReader { geo in
            let available = CGSize(width: geo.size.width - inset * 2 - gap * CGFloat(columns - 1),
                                   height: geo.size.height - inset * 2 - gap * CGFloat(rows - 1))
            let widths = columnFractions.map { CGFloat($0) * available.width }
            let heights = rowFractions.map { CGFloat($0) * available.height }
            let xs = offsets(widths)
            let ys = offsets(heights)

            ZStack(alignment: .topLeading) {
                ForEach(Array(items.prefix(columns * rows).enumerated()), id: \.element.id) { index, item in
                    let column = index % columns, row = index / columns
                    cell(item)
                        .frame(width: widths[column], height: heights[row])
                        .offset(x: xs[column], y: ys[row])
                }
                ForEach(0..<max(0, rows - 1), id: \.self) { row in
                    ForEach(0..<max(0, columns - 1), id: \.self) { column in
                        let x = xs[column] + widths[column], y = ys[row] + heights[row]
                        CrossResizeHandle(
                            current: CGSize(width: x, height: y),
                            onChange: { point in
                                moveColumnLine(column, to: point.width - inset, available: available.width)
                                moveRowLine(row, to: point.height - inset, available: available.height)
                            },
                            onReset: resetSplits
                        )
                        .position(x: x + gap / 2, y: y + gap / 2)
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
    }

    /// Each cell's left (or top) edge: the inset, the sizes before it and a gap between each.
    private func offsets(_ sizes: [CGFloat]) -> [CGFloat] {
        var edge = inset
        return sizes.map { size in
            defer { edge += size + gap }
            return edge
        }
    }

    /// Each column's share of the width, saved per column count; equal until a grip is dragged.
    private var columnFractions: [Double] { Self.fractions(columnSplits[columns], count: columns) }
    private var rowFractions: [Double] { Self.fractions(rowSplits[rows], count: rows) }

    private static func fractions(_ saved: [Double]?, count: Int) -> [Double] {
        if let saved, saved.count == count { return saved }
        return Array(repeating: 1 / Double(count), count: count)
    }

    /// Moves the line after `column` so its left edge sits `edge` points in, taking the width from
    /// the column on its other side only.
    private func moveColumnLine(_ column: Int, to edge: CGFloat, available: CGFloat) {
        guard let new = moveLine(columnFractions, index: column, to: edge, available: available, min: Self.minCellWidth) else { return }
        columnSplits[columns] = new
    }

    private func moveRowLine(_ row: Int, to edge: CGFloat, available: CGFloat) {
        guard let new = moveLine(rowFractions, index: row, to: edge, available: available, min: Self.minCellHeight) else { return }
        rowSplits[rows] = new
    }

    /// `edge` is in points from the first cell's edge, gaps included; the line between `index` and
    /// `index + 1` moves there, clamped so neither cell gets smaller than `min`.
    private func moveLine(_ fractions: [Double], index: Int, to edge: CGFloat, available: CGFloat, min: CGFloat) -> [Double]? {
        guard available > 0, index + 1 < fractions.count else { return nil }
        let before = fractions[..<index].reduce(0, +)
        let pair = fractions[index] + fractions[index + 1]
        let minShare = Double(min / available)
        guard pair >= minShare * 2 else { return nil }
        let share = Double((edge - gap * CGFloat(index)) / available) - before
        var new = fractions
        new[index] = Swift.min(pair - minShare, Swift.max(minShare, share))
        new[index + 1] = pair - new[index]
        return new
    }

    private func resetSplits() {
        columnSplits[columns] = nil
        rowSplits[rows] = nil
    }
}

/// Column or row shares keyed by how many columns or rows there are, kept in the user defaults.
struct SplitStore {
    let key: String
    private var values: [Int: [Double]]

    init(key: String) {
        self.key = key
        let saved = UserDefaults.standard.dictionary(forKey: key) as? [String: [Double]] ?? [:]
        values = Dictionary(uniqueKeysWithValues: saved.compactMap { k, v in Int(k).map { ($0, v) } })
    }

    subscript(count: Int) -> [Double]? {
        get { values[count] }
        set {
            values[count] = newValue
            UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: values.map { (String($0), $1) }), forKey: key)
        }
    }
}

/// A chart grid's Cols / Rows / Zoom / Space sliders. Cols and Rows take effect once the sliders have been
/// left alone for a moment (the grid reloads charts as it changes size); Zoom applies as it moves.
struct GridSliders: View {
    /// How long the sliders must be left alone before the grid takes their size and loads.
    private static let settleDelay: Duration = .seconds(2)

    @Binding var columns: Int
    @Binding var rows: Int
    /// Bars on screen at the charts' default zoom.
    @Binding var zoom: Double
    let columnRange: ClosedRange<Int>
    let rowRange: ClosedRange<Int>
    /// Off: the Zoom slider only.
    var showsSize = true
    var zoomHelp = "Bars on screen at the default zoom; double-clicking a chart goes back to it"

    /// Shared by every chart, in both windows.
    @AppStorage(RightSpace.key) private var rightSpace = RightSpace.defaultBars

    /// The sliders' values until they settle into `columns` / `rows`.
    @State private var pendingColumns: Int?
    @State private var pendingRows: Int?
    @State private var settleTask: Task<Void, Never>?

    var body: some View {
        HStack {
            if showsSize {
                sizeSlider("c", value: pendingColumns ?? columns, range: columnRange) { pendingColumns = $0 }
                sizeSlider("r", value: pendingRows ?? rows, range: rowRange) { pendingRows = $0 }
            }
            zoomSlider
            spaceSlider
        }
    }

    private var spaceSlider: some View {
        HStack(spacing: 4) {
            Text("Space")
                .font(.system(size: 10))
                .foregroundStyle(Color.secondary.opacity(0.7))
            // Rounds to whole bars itself, for the same reason as Zoom.
            MiniSlider(value: Binding(get: { rightSpace }, set: { rightSpace = $0.rounded() }),
                       range: RightSpace.range)
                .frame(width: 60)
            Text("\(Int(rightSpace))")
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(Color.secondary.opacity(0.7))
                .frame(width: 16, alignment: .leading)
        }
        .help("Empty bars between the latest candle and the price axis, on every chart")
    }

    private var zoomSlider: some View {
        HStack(spacing: 4) {
            Text("Zoom")
                .font(.system(size: 10))
                .foregroundStyle(Color.secondary.opacity(0.7))
            // Runs zoomed out → in, i.e. from the most bars to the fewest, in 10s.
            MiniSlider(value: Binding(get: { -zoom }, set: { zoom = -($0 / 10).rounded() * 10 }),
                       range: -ChartModel.maxVisibleBars...(-30))
                .frame(width: 90)
            Text("\(Int(zoom))")
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(Color.secondary.opacity(0.7))
                .frame(width: 26, alignment: .leading)
        }
        .help(zoomHelp)
    }

    private func sizeSlider(_ label: String, value: Int, range: ClosedRange<Int>, set: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(Color.secondary.opacity(0.7))
            MiniSlider(
                value: Binding(get: { Double(value) }, set: { new in
                    let rounded = Int(new.rounded())
                    guard rounded != value else { return }
                    set(rounded)
                    scheduleSettle()
                }),
                range: Double(range.lowerBound)...Double(range.upperBound)
            )
            .frame(width: 60)
            Text("\(value)")
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(Color.secondary.opacity(0.7))
                .frame(width: 10, alignment: .leading)
        }
    }

    /// Restarts the wait on every slider move to a new size; once it runs out, the grid takes the sliders' size.
    private func scheduleSettle() {
        settleTask?.cancel()
        settleTask = Task {
            try? await Task.sleep(for: Self.settleDelay)
            guard !Task.isCancelled else { return }
            if let pendingColumns { columns = pendingColumns }
            if let pendingRows { rows = pendingRows }
            pendingColumns = nil
            pendingRows = nil
        }
    }
}

/// A flat slider in the grays of the chips beside it: a thin track, filled up to a small knob that
/// grows a little while hovered or dragged. Clicking the track jumps there; the binding rounds.
struct MiniSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>

    @State private var isHovering = false
    @State private var isDragging = false

    private static let knobSize: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            let travel = max(1, geo.size.width - Self.knobSize)
            let span = range.upperBound - range.lowerBound
            let fraction = span > 0 ? (min(max(value, range.lowerBound), range.upperBound) - range.lowerBound) / span : 0
            let knobX = Self.knobSize / 2 + travel * fraction
            let active = isHovering || isDragging
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12)).frame(height: 2)
                Capsule().fill(Color.secondary.opacity(active ? 0.9 : 0.7)).frame(width: knobX, height: 2)
                Circle()
                    .fill(active ? Color.primary.opacity(0.85) : Color.secondary)
                    .frame(width: active ? Self.knobSize + 2 : Self.knobSize, height: active ? Self.knobSize + 2 : Self.knobSize)
                    .position(x: knobX, y: geo.size.height / 2)
            }
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        isDragging = true
                        let f = min(max((drag.location.x - Self.knobSize / 2) / travel, 0), 1)
                        value = range.lowerBound + f * span
                    }
                    .onEnded { _ in isDragging = false }
            )
            .animation(.easeOut(duration: 0.1), value: active)
        }
        .frame(height: 14)
    }
}
