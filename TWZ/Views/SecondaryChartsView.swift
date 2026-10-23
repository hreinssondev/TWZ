//
//  SecondaryChartsView.swift
//  TWZ
//
//  A grid of charts that follow the top gainers (their own scanner, 25 rows), laid out in rank order:
//  6×3 for the top 18, or a custom grid set by the Cols / Rows sliders (the "All Charts" / "Top N"
//  title toggles them). A slider change applies once the sliders have been left alone for a moment.
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
    static let scannerOwner = "secondary-charts"
    static let windowID = "secondary-charts"
    static let windowTitle = "Charts"

    static func isWindow(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        return window.identifier?.rawValue.hasPrefix(windowID) == true || window.title == windowTitle
    }

    enum Layout: String {
        case all, custom
    }
}

struct SecondaryChartsView: View {
    @Environment(Broker.self) private var broker
    @Environment(Workspace.self) private var workspace

    private static let gap: CGFloat = 4
    /// How long the sliders must be left alone before the grid takes their size and loads.
    private static let settleDelay: Duration = .seconds(2)

    @State private var lastGainers: [String] = []
    @AppStorage(SecondaryCharts.timeframeKey) private var masterTimeframe: Timeframe = .m1
    @AppStorage("secondaryHeaderHeight") private var headerHeight: Double = 28
    @AppStorage(SecondaryCharts.pausedKey) private var isPaused: Bool = false
    @AppStorage(SecondaryCharts.layoutKey) private var layout: SecondaryCharts.Layout = .all
    @AppStorage(SecondaryCharts.columnsKey) private var customColumns: Int = 5
    @AppStorage(SecondaryCharts.rowsKey) private var customRows: Int = 2
    /// The sliders' values until they settle into `customColumns` / `customRows`.
    @State private var pendingColumns: Int?
    @State private var pendingRows: Int?
    @State private var settleTask: Task<Void, Never>?
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
        // Charts still in the new top N stay put; the rest are emptied (smaller grid) or filled (larger).
        .onChange(of: count) {
            if !isPaused { lastGainers = []; syncWithGainers() }
        }
    }

    private var grid: some View {
        GeometryReader { geo in
            let gap = Self.gap
            let available = CGSize(width: geo.size.width - gap * 2 - gap * CGFloat(columns - 1),
                                   height: geo.size.height - gap * 2 - gap * CGFloat(rows - 1))
            let widths = columnFractions.map { CGFloat($0) * available.width }
            let heights = rowFractions.map { CGFloat($0) * available.height }
            let xs = Self.offsets(widths, gap: gap)
            let ys = Self.offsets(heights, gap: gap)

            ZStack(alignment: .topLeading) {
                // One ForEach keyed by chart, so a chart's view (and its state) moves with it when the ranking reshuffles.
                ForEach(Array(rankedCharts.prefix(count).enumerated()), id: \.element.id) { index, chart in
                    let column = index % columns, row = index / columns
                    SecondaryChartPane(chart: chart)
                        .frame(width: widths[column], height: heights[row])
                        .offset(x: xs[column], y: ys[row])
                }
                // A grip at every crossing of four charts: it moves that column line and row line together.
                ForEach(0..<max(0, rows - 1), id: \.self) { row in
                    ForEach(0..<max(0, columns - 1), id: \.self) { column in
                        let x = xs[column] + widths[column], y = ys[row] + heights[row]
                        CrossResizeHandle(
                            current: CGSize(width: x, height: y),
                            onChange: { point in
                                moveColumnLine(column, to: point.width - gap, available: available.width)
                                moveRowLine(row, to: point.height - gap, available: available.height)
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

    /// Each chart's left (or top) edge: the outer gap, the sizes before it and a gap between each.
    private static func offsets(_ sizes: [CGFloat], gap: CGFloat) -> [CGFloat] {
        var edge = gap
        return sizes.map { size in
            defer { edge += size + gap }
            return edge
        }
    }

    // MARK: Splits

    private static let minChartWidth: CGFloat = 80
    private static let minChartHeight: CGFloat = 60

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
        guard let new = Self.moveLine(columnFractions, index: column, to: edge, available: available, min: Self.minChartWidth) else { return }
        columnSplits[columns] = new
    }

    private func moveRowLine(_ row: Int, to edge: CGFloat, available: CGFloat) {
        guard let new = Self.moveLine(rowFractions, index: row, to: edge, available: available, min: Self.minChartHeight) else { return }
        rowSplits[rows] = new
    }

    /// `edge` is in points from the first chart's edge, gaps included; the line between `index` and
    /// `index + 1` moves there, clamped so neither chart gets smaller than `min`.
    private static func moveLine(_ fractions: [Double], index: Int, to edge: CGFloat, available: CGFloat, min: CGFloat) -> [Double]? {
        guard available > 0, index + 1 < fractions.count else { return nil }
        let gap = Self.gap
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
                layout = layout == .all ? .custom : .all
            } label: {
                Text(layout == .all ? "All Charts" : "Top \(count)")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(layout == .all ? "Show the custom grid set by the sliders" : "Show the top 18 gainers, 6×3")
            if layout == .custom {
                sizeSlider("Cols", value: pendingColumns ?? customColumns, max: SecondaryCharts.maxColumns) {
                    pendingColumns = $0
                }
                sizeSlider("Rows", value: pendingRows ?? customRows, max: SecondaryCharts.maxRows) {
                    pendingRows = $0
                }
            }
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

    private func sizeSlider(_ label: String, value: Int, max: Int, set: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(Color.secondary.opacity(0.7))
            Slider(
                value: Binding(get: { Double(value) }, set: { new in
                    set(Int(new.rounded()))
                    scheduleSettle()
                }),
                in: 1...Double(max),
                step: 1
            )
            .controlSize(.mini)
            .frame(width: 60)
            Text("\(value)")
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(Color.secondary.opacity(0.7))
                .frame(width: 10, alignment: .leading)
        }
    }

    /// Restarts the wait on every slider move; once it runs out, the grid takes the sliders' size.
    private func scheduleSettle() {
        settleTask?.cancel()
        settleTask = Task {
            try? await Task.sleep(for: Self.settleDelay)
            guard !Task.isCancelled else { return }
            if let pendingColumns { customColumns = pendingColumns }
            if let pendingRows { customRows = pendingRows }
            pendingColumns = nil
            pendingRows = nil
        }
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

    /// Fills the charts with the top N gainers (the grid's count); the other charts are emptied.
    /// A symbol still in the top N keeps its chart, so a
    /// reshuffle in the ranking reloads nothing (`rankedCharts` moves them); new symbols take the charts that dropped out.
    private func syncWithGainers() {
        let gainers = broker.scans[SecondaryCharts.scannerOwner]?.symbols ?? []
        guard !gainers.isEmpty, gainers != lastGainers else { return }
        lastGainers = gainers

        var top: [String] = []
        for symbol in gainers where !symbol.isEmpty && !top.contains(symbol) {
            top.append(symbol)
            if top.count == min(count, workspace.secondaryCharts.count) { break }
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

/// Column or row shares keyed by how many columns or rows there are, kept in the user defaults.
private struct SplitStore {
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
