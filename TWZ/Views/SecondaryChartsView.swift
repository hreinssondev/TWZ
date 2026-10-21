//
//  SecondaryChartsView.swift
//  TWZ
//
//  A 6×3 grid of 18 charts that follow the top gainers list.
//  Charts update every 1-2 seconds to reduce load. Clicking a chart
//  loads it into the main window's selected chart.
//

import SwiftUI

struct SecondaryChartsView: View {
    @Environment(Broker.self) private var broker
    @Environment(Workspace.self) private var workspace

    private static let columns = 6
    private static let rows = 3
    private static let gap: CGFloat = 4
    private static let refreshInterval: Duration = .seconds(2)

    @State private var lastGainers: [String] = []
    @AppStorage("secondaryChartsTimeframe") private var masterTimeframe: Timeframe = .m1
    @AppStorage("secondaryHeaderHeight") private var headerHeight: Double = 28
    @AppStorage("secondaryChartsPaused") private var isPaused: Bool = false
    @State private var isDraggingHeader = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            GeometryReader { geo in
                let gap = Self.gap
                let totalGap = gap * CGFloat(Self.columns - 1)
                let chartWidth = (geo.size.width - gap * 2 - totalGap) / CGFloat(Self.columns)
                let totalVerticalGap = gap * CGFloat(Self.rows - 1)
                let chartHeight = (geo.size.height - gap * 2 - totalVerticalGap) / CGFloat(Self.rows)

                VStack(spacing: gap) {
                    ForEach(0..<Self.rows, id: \.self) { row in
                        HStack(spacing: gap) {
                            ForEach(0..<Self.columns, id: \.self) { col in
                                let index = row * Self.columns + col
                                if index < workspace.secondaryCharts.count {
                                    SecondaryChartPane(chart: workspace.secondaryCharts[index])
                                        .frame(width: chartWidth, height: chartHeight)
                                }
                            }
                        }
                    }
                }
                .padding(gap)
            }
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.35))
        .onAppear {
            if !isPaused {
                broker.setScanner(ScanSpec(kind: .gainers, filter: ScannerFilter(minPrice: 0.1)), owner: "secondary-charts")
                syncWithGainers()
                applyMasterTimeframe(masterTimeframe)
            }
        }
        .task {
            while !Task.isCancelled {
                if !isPaused {
                    syncWithGainers()
                }
                try? await Task.sleep(for: Self.refreshInterval)
            }
        }
        .onChange(of: masterTimeframe) { _, new in
            applyMasterTimeframe(new)
        }
        .onChange(of: isPaused) { _, paused in
            if paused {
                // Unsubscribe from scanner to stop data flow
                broker.setScanner(nil, owner: "secondary-charts")
            } else {
                // Resubscribe and sync
                broker.setScanner(ScanSpec(kind: .gainers, filter: ScannerFilter(minPrice: 0.1)), owner: "secondary-charts")
                syncWithGainers()
            }
        }
    }

    private var header: some View {
        HStack {
            Text("All Charts").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
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
            .help(isPaused ? "Resume secondary window data updates" : "Pause secondary window data updates")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(height: headerHeight)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.2))
        .contentShape(Rectangle())
        .gesture(
            DragGesture()
                .onChanged { value in
                    isDraggingHeader = true
                    let newHeight = headerHeight + value.translation.height
                    headerHeight = max(24, min(newHeight, 100))
                }
                .onEnded { _ in
                    isDraggingHeader = false
                }
        )
    }

    private func applyMasterTimeframe(_ timeframe: Timeframe) {
        for chart in workspace.secondaryCharts {
            if chart.timeframe != timeframe {
                chart.timeframe = timeframe
                broker.loadChart(chart)
            }
        }
        workspace.saveSecondaryCharts()
    }

    private func syncWithGainers() {
        let gainers = broker.scans["secondary-charts"]?.symbols ?? []
        guard gainers != lastGainers else { return }
        lastGainers = gainers

        let top18 = Array(gainers.prefix(18))

        // Only load if we have data to show
        guard !top18.isEmpty else { return }

        // Batch loading: first row immediately, then staggered
        Task {
            // Batch 1: charts 0-5 (top row) - load immediately
            for index in 0..<min(6, top18.count) {
                let symbol = top18[index]
                let chart = workspace.secondaryCharts[index]
                if chart.symbol != symbol && !symbol.isEmpty {
                    workspace.load(symbol, into: chart, broker: broker)
                }
            }

            // Small delay before batch 2
            try? await Task.sleep(nanoseconds: 20_000_000) // 0.02s

            // Batch 2: charts 6-11
            for index in 6..<min(12, top18.count) {
                let symbol = top18[index]
                let chart = workspace.secondaryCharts[index]
                if chart.symbol != symbol && !symbol.isEmpty {
                    workspace.load(symbol, into: chart, broker: broker)
                }
            }

            // Small delay before batch 3
            try? await Task.sleep(nanoseconds: 20_000_000) // 0.02s

            // Batch 3: charts 12-17
            for index in 12..<min(18, top18.count) {
                let symbol = top18[index]
                let chart = workspace.secondaryCharts[index]
                if chart.symbol != symbol && !symbol.isEmpty {
                    workspace.load(symbol, into: chart, broker: broker)
                }
            }

            // Clear any extra charts if gainers list is shorter
            for index in top18.count..<workspace.secondaryCharts.count {
                let chart = workspace.secondaryCharts[index]
                if !chart.symbol.isEmpty {
                    workspace.load("", into: chart, broker: broker)
                }
            }
        }
    }
}

/// A simplified chart pane for the secondary window: clicking loads the symbol
/// into the main window's selected chart instead of selecting this pane.
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
            CandleChart(
                chart: chart,
                lines: [],
                onAltClick: nil,
                onControlClick: nil,
                controlClickColor: { _ in nil },
                controlHoverPnL: { _ in nil },
                whatIfPnL: { _ in nil },
                onCancelOrder: { _ in },
                onClick: { }
            )
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.12)))
        .simultaneousGesture(TapGesture().onEnded {
            workspace.loadIntoSelectedChart(chart.symbol, broker: broker)
        })
        .onAppear {
            symbolText = chart.symbol
            broker.setQuoteSymbols([chart.symbol], owner: "secondary-chart-\(chart.id)")
        }
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
