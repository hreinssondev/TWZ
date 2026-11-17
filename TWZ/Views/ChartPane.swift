//
//  ChartPane.swift
//  TWZ
//

import SwiftUI

extension Workspace {
    /// Loads a symbol into the selected chart (the last selected one while none is) and selects it.
    func loadIntoSelectedChart(_ symbol: String, broker: Broker) {
        loadByHand(symbol, into: selectedChart, broker: broker)
        isChartSelected = true
    }

    /// Double-clicking a position: selects the grid's chart showing its stock (the first, in reading
    /// order), or with none, loads the stock into the grid's last chart and selects that.
    func focusPosition(_ symbol: String, broker: Broker) {
        let s = symbol.uppercased()
        if selectChart(showing: s) { return }
        if let id = mainCells.last, let last = chart(id: id) {
            loadByHand(s, into: last, broker: broker)
            selectedChartID = id
        }
    }

    /// Double-clicking an order: selects the grid's chart showing its stock (the first, in reading
    /// order), or with none, loads the stock into the selected chart.
    func focusOrder(_ symbol: String, broker: Broker) {
        if !selectChart(showing: symbol.uppercased()) { loadIntoSelectedChart(symbol, broker: broker) }
    }

    /// Selects the grid's first chart showing `symbol`; false when none does.
    private func selectChart(showing symbol: String) -> Bool {
        guard let id = mainCells.first(where: { chart(id: $0)?.symbol == symbol }) else { return false }
        selectedChartID = id
        return true
    }

    /// Loads a symbol picked by hand: the main-window chart keeps it and its cell instead of following
    /// the gainers, until Reset. A chart that already shows it just keeps it; next to another chart
    /// showing it, it takes the other of 1m / 5m (see `timeframe(showing:in:otherwise:)`).
    func loadByHand(_ symbol: String, into chart: ChartModel, broker: Broker) {
        let s = symbol.trimmingCharacters(in: .whitespaces).uppercased()
        guard !s.isEmpty else { return }
        if chart.symbol != s {
            load(s, timeframe: timeframe(showing: s, in: chart, otherwise: chart.timeframe), into: chart, broker: broker)
        }
        manualChartIDs.insert(chart.id)
    }

    /// Every main-window chart follows the gainers again, on the account bar's timeframe.
    func resetToGainers() {
        manualChartIDs = []
        gainerResets += 1
    }

    /// Loads a symbol into a chart, on `timeframe` if given, and (re)subscribes its data.
    func load(_ symbol: String, timeframe: Timeframe? = nil, into chart: ChartModel, broker: Broker) {
        let s = symbol.trimmingCharacters(in: .whitespaces).uppercased()
        guard !s.isEmpty else { return }
        chart.symbol = s
        if let timeframe { chart.timeframe = timeframe }
        countLoad(of: chart)
        broker.setQuoteSymbols([s], owner: "chart-\(chart.id)")
        broker.loadChart(chart)
    }

    /// Empties a chart and drops its data: history, live bars and quotes.
    func clear(_ chart: ChartModel, broker: Broker) {
        guard !chart.symbol.isEmpty else { return }
        chart.symbol = ""
        broker.setQuoteSymbols([], owner: "chart-\(chart.id)")
        broker.loadChart(chart)
    }
}

/// A main-window chart: its symbol field, position, ⚡ while fast (⌘↩), a red S if shortable, SSR under
/// the short sale restriction and its own timeframe switch
/// over a chart that trades. Clicking it selects it; the selected chart is outlined, and so, a little
/// fainter, is any other chart showing the same stock, since hotkeys go to that stock either way.
struct ChartPane: View {
    @Environment(Broker.self) private var broker
    @Environment(Workspace.self) private var workspace
    let chart: ChartModel

    @AppStorage(SelectedOutline.widthKey) private var outlineWidth = SelectedOutline.defaultWidth
    @AppStorage(TimeframePickerStyle.storageKey) private var pickerStyle: TimeframePickerStyle = .minimal
    @State private var symbolText = ""
    @FocusState private var symbolFocused: Bool

    private var isSelected: Bool { workspace.isChartSelected && workspace.selectedChartID == chart.id }
    /// Shows the selected chart's stock (in another chart).
    private var showsTarget: Bool { !chart.symbol.isEmpty && chart.symbol == workspace.targetSymbol }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            TradingChart(chart: chart, allowsAltClick: true) { workspace.selectedChartID = chart.id }
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(isSelected ? Color.accentColor : showsTarget ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.12),
                              lineWidth: isSelected || showsTarget ? outlineWidth : 1)
        )
        .simultaneousGesture(TapGesture().onEnded { workspace.selectedChartID = chart.id })
        .onAppear {
            symbolText = chart.symbol
            broker.setQuoteSymbols([chart.symbol], owner: "chart-\(chart.id)")
        }
        .onChange(of: chart.symbol) { _, new in
            if !symbolFocused { symbolText = new }
        }
        // Leaving the field without pressing Return drops the edit.
        .onChange(of: symbolFocused) { _, focused in
            if !focused { symbolText = chart.symbol }
        }
    }

    private var timeframe: Binding<Timeframe> {
        Binding(
            get: { chart.timeframe },
            set: { chart.timeframe = $0; broker.loadChart(chart) }
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
                    workspace.loadByHand(symbolText, into: chart, broker: broker)
                    symbolText = chart.symbol
                    symbolFocused = false
                }

            if let p = broker.positions[chart.symbol] {
                Text("\(p.quantity > 0 ? "LONG" : "SHORT") \(Fmt.shares(abs(p.quantity)))")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill((p.quantity > 0 ? Color.green : Color.red).opacity(0.25)))
            }

            // Tick-by-tick: a fast chart (⌘↩, filled ⚡) streams its trades; the selected chart its
            // trades and bid/ask (outlined ⚡ unless also fast). Lit while trades stream, dim offline
            // or refused; a red circle instead once IB's limit leaves it out.
            let isFast = workspace.fastChartIDs.contains(chart.id)
            if isFast || chart.id == workspace.selectedChartID {
                if broker.tickLimitedSymbols.contains(chart.symbol) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 7, height: 7)
                        .help("IB's tick-by-tick limit reached: this chart keeps IB's regular bar updates; "
                              + "selecting it puts it first, ⌘↩ on another fast chart frees a stream")
                } else {
                    let streaming = broker.tickTradeSymbols.contains(chart.symbol)
                    Image(systemName: isFast ? "bolt.fill" : "bolt")
                        .font(.system(size: 9))
                        .foregroundStyle(streaming ? Color.yellow : Color.secondary.opacity(0.5))
                        .help(!streaming
                              ? "Tick-by-tick not streaming (not connected, or IB refused it for this symbol)"
                              : isFast
                              ? "Tick-by-tick: every trade streams (and bid/ask while selected); ⌘↩ turns it off for this chart"
                              : "Selected: every trade and bid/ask streams tick by tick; ⌘↩ keeps its trades streaming once deselected")
                }
            }

            // Shortable (IB's tick 46): red S, faint while hard to borrow; none when it can't be shorted.
            if let shortable = broker.shortability[chart.symbol], shortable > 1.5 {
                Text("S")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.red.opacity(shortable > 2.5 ? 1 : 0.45))
                    .help(shortable > 2.5 ? "Shortable: at least 1,000 shares available to borrow"
                                          : "Hard to borrow: shortable only if IB can locate shares")
            }

            // Short sale restriction (SEC Rule 201), from Nasdaq's list or IB's prices.
            if let reason = broker.ssrReason(chart.symbol) {
                Text("SSR")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(Color.orange)
                    .help("Short sale restriction: short sales fill only above the best bid until the end of "
                          + "the next trading day. \(reason).")
            }

            Spacer(minLength: 4)

            // A chart too narrow for the switch (a big grid) gets a menu showing its timeframe.
            ViewThatFits(in: .horizontal) {
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
                timeframeMenu
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
    }

    private var timeframeMenu: some View {
        Menu {
            Picker("", selection: timeframe) {
                ForEach(Timeframe.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Text(chart.timeframe.rawValue)
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

/// A candle chart that trades: ⌃-click places a stop loss / take profit (or, with no position, a
/// what-if buy), ⌥-click places the selected hotkey's order (or the ⌥-click buy) at the clicked price
/// where allowed, and the position, orders and what-if are drawn as lines
/// (double-click one to cancel it). Shared by the main charts and the Charts window.
struct TradingChart: View {
    @Environment(Broker.self) private var broker
    @Environment(Workspace.self) private var workspace
    let chart: ChartModel
    /// ⌥-click orders; also switched off in the top bar.
    let allowsAltClick: Bool
    /// Called before an order or what-if from a click, e.g. to select the chart.
    var onTrade: () -> Void = {}

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
    /// The closed round trip whose exit lines were cleared by a click or a new order.
    @State private var dismissedTrip: String?

    var body: some View {
        CandleChart(
            chart: chart, lines: priceLines,
            // Switched off in the top bar: no handler, so ⌥ neither tints the price tag nor places orders.
            // The selected hotkey's order at the clicked price, or with none selected (the ⌥-click
            // buy box is), a buy for its NOK amount.
            onAltClick: allowsAltClick && altClickOrders ? { price in
                onTrade()
                if let hotkey = workspace.selectedHotkey {
                    broker.run(hotkey, symbol: chart.symbol, at: price)
                } else {
                    broker.buyNOK(OrderAmount.clamp(orderNOK), symbol: chart.symbol, at: price)
                }
            } : nil,
            onControlClick: { price in
                guard !chart.symbol.isEmpty else { return }
                onTrade()
                if hasPosition {
                    broker.placeProtective(symbol: chart.symbol, at: price)
                } else {
                    // No position: a what-if buy at the clicked price, sized from IB's margin preview.
                    let symbol = chart.symbol
                    broker.sizeWhatIf(symbol: symbol, at: price, fraction: WhatIf.buyingPowerFraction) { size in
                        workspace.whatIfs[symbol] = WhatIf(price: size.price, shares: size.shares)
                    }
                }
            },
            onControlClickLine: { id in
                // ⌃-clicking the what-if line removes it; other lines leave the click to place as usual.
                guard id == WhatIf.lineId else { return false }
                workspace.whatIfs[chart.symbol] = nil
                return true
            },
            controlClickColor: { price in
                guard hasPosition else { return Self.whatIfColor }
                guard let kind = broker.protectiveKind(symbol: chart.symbol, at: price),
                      !broker.protectiveFillsNow(symbol: chart.symbol, kind: kind, at: price) else { return nil }
                return protectiveColor(kind)
            },
            hoverPnL: { price in
                // The open position's if it closed there, else the what-if line's, else a pretend buy
                // at the last price, sized like a ⌃-click what-if.
                if let p = broker.positions[chart.symbol], p.quantity != 0 { return (price - p.avgCost) * p.quantity }
                if let whatIf = workspace.whatIfs[chart.symbol] { return whatIf.pnl(at: price) }
                guard let size = broker.hoverSizes[chart.symbol], let last = broker.quote(chart.symbol)?.last else { return nil }
                return (price - last) * size.shares
            },
            onHover: { broker.refreshHoverSize(symbol: chart.symbol) },
            onCancelOrder: { id in
                if id == WhatIf.lineId {
                    workspace.whatIfs[chart.symbol] = nil
                } else {
                    broker.cancelOrder(id, why: "chart: clicked the order line")
                }
            },
            onClick: { dismissedTrip = closedTrip?.id ?? dismissedTrip }
        )
        // A new order in the symbol clears the last trade's exit lines.
        .onChange(of: symbolOrders) { old, new in
            if old.symbol == new.symbol, !new.ids.isSubset(of: old.ids) {
                dismissedTrip = closedTrip?.id ?? dismissedTrip
            }
        }
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

    /// Hot pink: the system pink reads as red next to the stop loss line.
    private static let whatIfColor = Color(red: 1.0, green: 0.25, blue: 0.8)

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
            // ⌃-clicked with no position: a line at the pretend buy's price with, on the axis, what it's
            // worth in NOK (80% of what IB's margin allows; "W" until the rate is in), just left of the
            // axis where the last price box would cover it; a click on it removes it.
            let valueNOK = broker.usdNok.map { whatIf.shares * whatIf.price * $0 }
            lines.append(PriceLine(price: whatIf.price, color: Self.whatIfColor, label: "W", orderId: WhatIf.lineId,
                                   movesAsideForLastPrice: true, axisText: valueNOK.map(OrderAmount.format) ?? "W",
                                   cancelsOnClick: true))
        }
        for o in broker.orders.values where o.isActive && o.symbol == chart.symbol {
            let side = o.action == "BUY" ? "B" : "S"
            if let p = broker.protectiveOrders[o.id] {
                // Placed by ⌃-clicking the chart: a stop loss (at its stop) or take profit line, just the
                // price in its box (in the chart beside the axis, as for every order); a click cancels it.
                let isStop = p.kind == .stopLoss
                if let price = isStop ? o.auxPrice : o.limitPrice {
                    lines.append(PriceLine(price: price, color: protectiveColor(p.kind),
                                           label: "", dashed: isStop ? stopLossDashed : takeProfitDashed, orderId: o.id,
                                           cancelsOnClick: true))
                }
                continue
            }
            if broker.chartOrderIds.contains(o.id) {
                // Placed by ⌥-clicking the chart: one line (a stop-limit's stop equals its limit), just the
                // price in its box.
                if let price = o.auxPrice ?? o.limitPrice {
                    lines.append(PriceLine(price: price, color: LineColors.resolve(altClickHex, default: LineColors.defaultAltClick),
                                           label: "", dashed: altClickDashed, orderId: o.id))
                }
                continue
            }
            // Other orders: the side, no share count, in the box.
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
struct TimeframePicker: View {
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
