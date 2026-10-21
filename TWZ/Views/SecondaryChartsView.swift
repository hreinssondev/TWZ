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

    var body: some View {
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
        .background(Color(nsColor: .textBackgroundColor).opacity(0.35))
        .onAppear {
            syncWithGainers()
        }
        .task {
            while !Task.isCancelled {
                syncWithGainers()
                try? await Task.sleep(for: Self.refreshInterval)
            }
        }
    }

    private func syncWithGainers() {
        let gainers = broker.scans["list-left"]?.symbols ?? []
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

    @AppStorage(TimeframePickerStyle.storageKey) private var pickerStyle: TimeframePickerStyle = .minimal
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

    private var timeframe: Binding<Timeframe> {
        Binding(
            get: { chart.timeframe },
            set: { chart.timeframe = $0; broker.loadChart(chart); workspace.saveChart(chart) }
        )
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

            Spacer(minLength: 4)

            switch pickerStyle {
            case .segmented:
                Picker("", selection: timeframe) {
                    ForEach(Timeframe.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.mini)
                .frame(width: 170)
            case .minimal:
                TimeframePicker(selection: timeframe)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
    }
}
