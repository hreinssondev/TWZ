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
    @AppStorage(LineColors.avgCostKey) private var avgCostHex = ""
    @AppStorage(LineColors.altClickKey) private var altClickHex = ""
    @AppStorage(SelectedOutline.widthKey) private var outlineWidth = SelectedOutline.defaultWidth
    @AppStorage(TimeframePickerStyle.storageKey) private var pickerStyle: TimeframePickerStyle = .minimal
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
                },
                onControlClick: { price in
                    workspace.selectedChartIndex = chart.id
                    broker.placeProtective(symbol: chart.symbol, at: price)
                },
                controlClickColor: { price in
                    guard let kind = broker.protectiveKind(symbol: chart.symbol, at: price),
                          !broker.protectiveFillsNow(symbol: chart.symbol, kind: kind, at: price) else { return nil }
                    return kind == .stopLoss ? .red : .green
                },
                onCancelOrder: { id in broker.cancelOrder(id) }
            )
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: isSelected ? outlineWidth : 1)
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

    private var timeframe: Binding<Timeframe> {
        Binding(
            get: { chart.timeframe },
            set: { chart.timeframe = $0; broker.loadChart(chart); workspace.saveCharts() }
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

            if let p = broker.positions[chart.symbol] {
                Text("\(p.quantity > 0 ? "LONG" : "SHORT") \(Fmt.shares(abs(p.quantity)))")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill((p.quantity > 0 ? Color.green : Color.red).opacity(0.25)))
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

    private var priceLines: [PriceLine] {
        var lines: [PriceLine] = []
        if let p = broker.positions[chart.symbol] {
            // Avg cost: solid line, number only on the axis.
            lines.append(PriceLine(price: p.avgCost, color: LineColors.resolve(avgCostHex, default: LineColors.defaultAvgCost),
                                   label: "", dashed: false))
        }
        for o in broker.orders.values where o.isActive && o.symbol == chart.symbol {
            let side = "\(o.action == "BUY" ? "B" : "S") \(Fmt.shares(o.quantity - o.filled))"
            if let p = broker.protectiveOrders[o.id] {
                // Placed by ⌃-clicking the chart: a solid red stop loss (at its stop) or green take profit.
                let isStop = p.kind == .stopLoss
                if let price = isStop ? o.auxPrice : o.limitPrice {
                    lines.append(PriceLine(price: price, color: isStop ? .red : .green,
                                           label: "\(isStop ? "SL" : "TP") \(side)", dashed: false, orderId: o.id))
                }
                continue
            }
            if broker.chartOrderIds.contains(o.id) {
                // Placed by ⌥-clicking the chart: one solid line (a stop-limit's stop equals its limit).
                if let price = o.auxPrice ?? o.limitPrice {
                    let label = o.orderType.hasPrefix("STP") ? "STP \(side)" : side
                    lines.append(PriceLine(price: price, color: LineColors.resolve(altClickHex, default: LineColors.defaultAltClick),
                                           label: label, dashed: false, orderId: o.id))
                }
                continue
            }
            if let lmt = o.limitPrice {
                lines.append(PriceLine(price: lmt, color: o.action == "BUY" ? .blue : .orange, label: side, orderId: o.id))
            }
            // Stop / trigger price (TRAIL's aux is a distance, not a price).
            if let aux = o.auxPrice, !o.orderType.hasPrefix("TRAIL"), o.orderType != "REL" {
                lines.append(PriceLine(price: aux, color: .purple, label: "\(o.orderType) \(side)", orderId: o.id))
            }
        }
        return lines
    }
}

/// Quiet monochrome timeframe switch: plain labels, the selected one brighter on a faint chip.
private struct TimeframePicker: View {
    @Binding var selection: Timeframe

    var body: some View {
        HStack(spacing: 1) {
            ForEach(Timeframe.allCases) { tf in
                let selected = tf == selection
                Button {
                    selection = tf
                } label: {
                    Text(tf.rawValue)
                        .font(.system(size: 10, weight: selected ? .semibold : .regular).monospacedDigit())
                        .foregroundStyle(selected ? Color.primary : Color.secondary.opacity(0.7))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(selected ? 0.12 : 0)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
