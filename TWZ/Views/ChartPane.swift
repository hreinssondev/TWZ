//
//  ChartPane.swift
//  TWZ
//

import SwiftUI

extension Workspace {
    /// Loads a symbol into the selected chart (the last selected one while none is) and selects it.
    func loadIntoSelectedChart(_ symbol: String, broker: Broker) {
        load(symbol, into: selectedChart, broker: broker)
        isChartSelected = true
    }

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
    @AppStorage(AltClickOrders.enabledKey) private var altClickOrders = true
    @AppStorage(LineColors.avgCostKey) private var avgCostHex = ""
    @AppStorage(LineColors.altClickKey) private var altClickHex = ""
    @AppStorage(LineColors.stopLossKey) private var stopLossHex = ""
    @AppStorage(LineColors.takeProfitKey) private var takeProfitHex = ""
    @AppStorage(LineColors.ordersKey) private var ordersHex = ""
    @AppStorage(LineDashes.avgCostKey) private var avgCostDashed = LineDashes.defaultAvgCost
    @AppStorage(LineDashes.altClickKey) private var altClickDashed = LineDashes.defaultAltClick
    @AppStorage(LineDashes.stopLossKey) private var stopLossDashed = LineDashes.defaultStopLoss
    @AppStorage(LineDashes.takeProfitKey) private var takeProfitDashed = LineDashes.defaultTakeProfit
    @AppStorage(LineDashes.ordersKey) private var ordersDashed = LineDashes.defaultOrders
    @AppStorage(LineDashes.lastTradeKey) private var lastTradeDashed = LineDashes.defaultLastTrade
    @AppStorage(SelectedOutline.widthKey) private var outlineWidth = SelectedOutline.defaultWidth
    @AppStorage(TimeframePickerStyle.storageKey) private var pickerStyle: TimeframePickerStyle = .minimal
    @State private var symbolText = ""
    /// The closed round trip whose exit lines were cleared by a click or a new order.
    @State private var dismissedTrip: String?
    @FocusState private var symbolFocused: Bool

    private var isSelected: Bool { workspace.isChartSelected && workspace.selectedChartIndex == chart.id }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            CandleChart(
                chart: chart, lines: priceLines,
                // Switched off in the top bar: no handler, so ⌥ neither tints the price tag nor places orders.
                onAltClick: altClickOrders ? { price in
                    workspace.selectedChartIndex = chart.id
                    broker.buyNOK(OrderAmount.clamp(orderNOK), symbol: chart.symbol, at: price)
                } : nil,
                onControlClick: { price in
                    workspace.selectedChartIndex = chart.id
                    if hasPosition {
                        broker.placeProtective(symbol: chart.symbol, at: price)
                    } else {
                        // No position: a what-if buy at the last price (the clicked one until a quote comes in).
                        let last = broker.quote(chart.symbol)?.last ?? price
                        if last > 0 { workspace.whatIfs[chart.symbol] = WhatIf(price: last) }
                    }
                },
                controlClickColor: { price in
                    guard hasPosition else { return Self.whatIfColor }
                    guard let kind = broker.protectiveKind(symbol: chart.symbol, at: price),
                          !broker.protectiveFillsNow(symbol: chart.symbol, kind: kind, at: price) else { return nil }
                    return protectiveColor(kind)
                },
                controlHoverPnL: { price in
                    guard let p = broker.positions[chart.symbol], p.quantity != 0 else { return nil }
                    return (price - p.avgCost) * p.quantity
                },
                whatIfPnL: { price in workspace.whatIfs[chart.symbol]?.pnl(at: price) },
                onCancelOrder: { id in
                    if id == WhatIf.lineId {
                        workspace.whatIfs[chart.symbol] = nil
                    } else {
                        broker.cancelOrder(id, why: "chart: double-clicked the order line")
                    }
                },
                onClick: { dismissedTrip = closedTrip?.id ?? dismissedTrip }
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
        // A new order in the symbol clears the last trade's exit lines.
        .onChange(of: symbolOrders) { old, new in
            if old.symbol == new.symbol, !new.ids.isSubset(of: old.ids) {
                dismissedTrip = closedTrip?.id ?? dismissedTrip
            }
        }
        // Leaving the field without pressing Return drops the edit.
        .onChange(of: symbolFocused) { _, focused in
            if !focused { symbolText = chart.symbol }
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

    private struct SymbolOrders: Equatable {
        var symbol: String
        var ids: Set<Int>
    }

    private var symbolOrders: SymbolOrders {
        SymbolOrders(symbol: chart.symbol,
                     ids: Set(broker.orders.values.filter { $0.symbol == chart.symbol }.map(\.id)))
    }

    /// The symbol's latest round trip once it's closed, until a click on the chart or a new order.
    private var closedTrip: RoundTrip? {
        let fills = broker.fills.values.filter { $0.symbol == chart.symbol }
        guard let trip = RoundTrip.build(fills: fills, positions: broker.positions).first,
              !trip.isOpen, trip.id != dismissedTrip else { return nil }
        return trip
    }

    private static let whatIfColor = Color.pink

    private var hasPosition: Bool { broker.positions[chart.symbol].map { $0.quantity != 0 } ?? false }

    private func protectiveColor(_ kind: Broker.Protective.Kind) -> Color {
        kind == .stopLoss
            ? LineColors.resolve(stopLossHex, default: LineColors.defaultStopLoss)
            : LineColors.resolve(takeProfitHex, default: LineColors.defaultTakeProfit)
    }

    /// Line colors and solid / dashed come from Settings.
    private var priceLines: [PriceLine] {
        var lines: [PriceLine] = []
        if let trip = closedTrip {
            // Just exited: red at the average exit, green at the average entry (unknown for shares held
            // from before today).
            if let exit = trip.exitPrice {
                lines.append(PriceLine(price: exit, color: .red, label: "Exit", dashed: lastTradeDashed))
            }
            if trip.carried == 0, let entry = trip.entryPrice {
                lines.append(PriceLine(price: entry, color: .green, label: "Avg", dashed: lastTradeDashed))
            }
        }
        if let p = broker.positions[chart.symbol] {
            // Avg cost: number only on the axis (just left of it when the last price box would cover it).
            lines.append(PriceLine(price: p.avgCost, color: LineColors.resolve(avgCostHex, default: LineColors.defaultAvgCost),
                                   label: "", dashed: avgCostDashed, movesAsideForLastPrice: true))
        }
        if let whatIf = workspace.whatIfs[chart.symbol] {
            // ⌃-clicked with no position: "W" at the pretend buy's price; double-click removes it.
            lines.append(PriceLine(price: whatIf.price, color: Self.whatIfColor, label: "W", orderId: WhatIf.lineId))
        }
        for o in broker.orders.values where o.isActive && o.symbol == chart.symbol {
            let side = o.action == "BUY" ? "B" : "S"
            if let p = broker.protectiveOrders[o.id] {
                // Placed by ⌃-clicking the chart: a stop loss (at its stop) or take profit line, just the
                // price on the axis.
                let isStop = p.kind == .stopLoss
                if let price = isStop ? o.auxPrice : o.limitPrice {
                    lines.append(PriceLine(price: price, color: protectiveColor(p.kind),
                                           label: "", dashed: isStop ? stopLossDashed : takeProfitDashed, orderId: o.id))
                }
                continue
            }
            if broker.chartOrderIds.contains(o.id) {
                // Placed by ⌥-clicking the chart: one line (a stop-limit's stop equals its limit), just the
                // price on the axis.
                if let price = o.auxPrice ?? o.limitPrice {
                    lines.append(PriceLine(price: price, color: LineColors.resolve(altClickHex, default: LineColors.defaultAltClick),
                                           label: "", dashed: altClickDashed, orderId: o.id))
                }
                continue
            }
            // Other orders: the side, no share count, on the axis.
            if let lmt = o.limitPrice {
                lines.append(PriceLine(price: lmt, color: LineColors.resolve(ordersHex, default: LineColors.defaultOrders),
                                       label: side, dashed: ordersDashed, orderId: o.id))
            }
            // Stop / trigger price (TRAIL's aux is a distance, not a price).
            if let aux = o.auxPrice, !o.orderType.hasPrefix("TRAIL"), o.orderType != "REL" {
                lines.append(PriceLine(price: aux, color: .purple, label: "\(o.orderType) \(side)",
                                       dashed: ordersDashed, orderId: o.id))
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
