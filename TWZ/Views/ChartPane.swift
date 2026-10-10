//
//  ChartPane.swift
//  TWZ
//

import SwiftUI

extension Workspace {
    /// Loads a symbol into a chart and (re)subscribes its data.
    func load(_ symbol: String, into chart: ChartModel, broker: Broker) {
        let s = symbol.trimmingCharacters(in: .whitespaces).uppercased()
        guard !s.isEmpty else { return }
        chart.symbol = s
        broker.setQuoteSymbols([s], owner: "chart-\(chart.id)")
        broker.loadChart(chart)
        saveCharts()
    }
}

struct ChartPane: View {
    @Environment(Broker.self) private var broker
    @Environment(Workspace.self) private var workspace
    let chart: ChartModel

    @AppStorage(OrderAmount.storageKey) private var orderNOK = OrderAmount.initial
    @State private var symbolText = ""
    @FocusState private var symbolFocused: Bool

    private var isSelected: Bool { workspace.selectedChartIndex == chart.id }
    private var quote: Quote? { broker.quotes[chart.symbol] }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            CandleChart(
                chart: chart, lastPrice: quote?.last, lines: priceLines,
                onAltClick: { price in
                    workspace.selectedChartIndex = chart.id
                    broker.buyNOK(OrderAmount.clamp(orderNOK), symbol: chart.symbol, at: price)
                }
            )
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: isSelected ? 2 : 1)
        )
        .simultaneousGesture(TapGesture().onEnded { workspace.selectedChartIndex = chart.id })
        .onAppear {
            symbolText = chart.symbol
            broker.setQuoteSymbols([chart.symbol], owner: "chart-\(chart.id)")
        }
        .onChange(of: chart.symbol) { _, new in
            if !symbolFocused { symbolText = new }
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

            Picker("", selection: Binding(
                get: { chart.timeframe },
                set: { chart.timeframe = $0; broker.loadChart(chart); workspace.saveCharts() }
            )) {
                ForEach(Timeframe.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.mini)
            .frame(width: 170)

            Spacer(minLength: 4)

            if let p = broker.positions[chart.symbol] {
                Text("\(p.quantity > 0 ? "LONG" : "SHORT") \(Fmt.shares(abs(p.quantity)))")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill((p.quantity > 0 ? Color.green : Color.red).opacity(0.25)))
            }

            if let q = quote {
                Text(Fmt.price(q.last))
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                Text(Fmt.percent(q.changePercent))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle((q.changePercent ?? 0) >= 0 ? .green : .red)
                Text("\(Fmt.price(q.bid)) × \(Fmt.price(q.ask))")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
    }

    private var priceLines: [PriceLine] {
        var lines: [PriceLine] = []
        if let p = broker.positions[chart.symbol] {
            // Avg cost: soft blue, number only on the axis.
            lines.append(PriceLine(price: p.avgCost, color: Color(red: 0.30, green: 0.50, blue: 0.95), label: ""))
        }
        for o in broker.orders.values where o.isActive && o.symbol == chart.symbol {
            let side = "\(o.action == "BUY" ? "B" : "S") \(Fmt.shares(o.quantity - o.filled))"
            if broker.chartOrderIds.contains(o.id) {
                // Placed by ⌥-clicking the chart: one solid line (a stop-limit's stop equals its limit).
                if let price = o.auxPrice ?? o.limitPrice {
                    let label = o.orderType.hasPrefix("STP") ? "STP \(side)" : side
                    lines.append(PriceLine(price: price, color: .purple, label: label, dashed: false))
                }
                continue
            }
            if let lmt = o.limitPrice {
                lines.append(PriceLine(price: lmt, color: o.action == "BUY" ? .blue : .orange, label: side))
            }
            // Stop / trigger price (TRAIL's aux is a distance, not a price).
            if let aux = o.auxPrice, !o.orderType.hasPrefix("TRAIL"), o.orderType != "REL" {
                lines.append(PriceLine(price: aux, color: .purple, label: "\(o.orderType) \(side)"))
            }
        }
        return lines
    }
}
