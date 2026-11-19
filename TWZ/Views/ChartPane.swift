//
//  ChartPane.swift
//  TWZ
//

import SwiftUI

extension Broker {
    /// A chart header's tint: the up color while long the stock, the down color while short, none while flat.
    func positionTint(_ symbol: String, colors: SideColors) -> Color {
        guard let quantity = positions[symbol]?.quantity, quantity != 0 else { return .clear }
        return colors.of(quantity > 0).opacity(0.3)
    }
}

extension Workspace {
    /// Loads a symbol into the selected chart (the last selected one while none is) and selects it.
    func loadIntoSelectedChart(_ symbol: String, broker: Broker) {
        loadByHand(symbol, into: selectedChart, broker: broker)
        isChartSelected = true
    }

    /// Double-clicking a position: selects its stock's chart (see `showChart`).
    func focusPosition(_ symbol: String, broker: Broker) {
        showChart(symbol.uppercased(), broker: broker)
    }

    /// Double-clicking an order: selects its stock's chart (see `showChart`).
    func focusOrder(_ symbol: String, broker: Broker) {
        showChart(symbol.uppercased(), broker: broker)
    }

    /// Double-clicking a round trip: shows its arrows and entry / exit lines on its stock's chart (see
    /// `showChart`). Double-clicking it again, or the chart, hides them.
    func showTrip(_ trip: RoundTrip, broker: Broker) {
        if shownTrips[trip.symbol] == trip.id {
            shownTrips[trip.symbol] = nil
            return
        }
        shownTrips[trip.symbol] = trip.id
        shownOrderFills[trip.symbol] = nil
        showChart(trip.symbol, broker: broker)
    }

    /// Double-clicking a filled order: shows its fills' arrows and a line at their average price, as
    /// `showTrip` does for a round trip. Double-clicking it again, or the chart, hides them.
    func showFills(_ fillIds: Set<String>, symbol: String, broker: Broker) {
        if shownOrderFills[symbol] == fillIds {
            shownOrderFills[symbol] = nil
            return
        }
        shownOrderFills[symbol] = fillIds
        shownTrips[symbol] = nil
        showChart(symbol, broker: broker)
    }

    /// Selects the grid's chart showing `symbol` (the first, in reading order), or with none, loads it
    /// into the grid's 6th chart in reading order (the last, in a smaller grid) and selects that.
    private func showChart(_ symbol: String, broker: Broker) {
        if selectChart(showing: symbol) { return }
        if let id = mainCells.count >= 6 ? mainCells[5] : mainCells.last, let chart = chart(id: id) {
            loadByHand(symbol, into: chart, broker: broker)
            selectedChartID = id
        }
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
        let s = ForexPair.normalize(symbol)
        guard !s.isEmpty else { return }
        // A chart following the gainers: the stock it showed leaves the grid while it keeps this one, so
        // no other chart moves.
        if !manualChartIDs.contains(chart.id), !chart.symbol.isEmpty, mainCharts.contains(where: { $0.id == chart.id }) {
            handDisplaced[chart.id] = chart.symbol
        }
        if chart.symbol != s {
            load(s, timeframe: timeframe(showing: s, in: chart, otherwise: chart.timeframe), into: chart, broker: broker)
        }
        manualChartIDs.insert(chart.id)
    }

    /// Every main-window chart follows the gainers again (also after a list's load button), on the
    /// account bar's timeframe.
    func resetToGainers() {
        manualChartIDs = []
        handDisplaced = [:]
        secondaryPins = [:]
        secondaryDisplaced = [:]
        gridScan = nil
        gainerResets += 1
    }

    /// Loads a symbol into a chart, on `timeframe` if given, and (re)subscribes its data.
    func load(_ symbol: String, timeframe: Timeframe? = nil, into chart: ChartModel, broker: Broker) {
        let s = ForexPair.normalize(symbol)
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

/// A main-window chart: its symbol field, position (the header green while long, red while short), ⚡ while
/// fast (⌘↩), a red S if shortable, SSR under the short sale restriction, its short selling and buying
/// power in NOK and its own timeframe switch over a chart that trades. Clicking it selects it; the selected chart is outlined,
/// and so, a little fainter, is any other chart showing the same stock, since hotkeys go to that stock
/// either way. A stock given a color (⌥⇧ and its letter) is outlined in it instead, thick while selected.
struct ChartPane: View {
    @Environment(Broker.self) private var broker
    @Environment(Workspace.self) private var workspace
    @Environment(\.sideColors) private var sideColors
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
        .overlay { outline }
        .simultaneousGesture(TapGesture().onEnded { workspace.selectedChartID = chart.id })
        .onAppear {
            symbolText = chart.symbol
            broker.setQuoteSymbols([chart.symbol], owner: "chart-\(chart.id)")
        }
        .onChange(of: chart.symbol) { _, new in
            if !symbolFocused { symbolText = new }
        }
        // Keeps the header's buying and short selling power current: IB is asked only once they're
        // stale (see `Broker.refreshMarginSize`).
        .task(id: chart.symbol) {
            while !Task.isCancelled {
                broker.refreshMarginSize(symbol: chart.symbol)
                try? await Task.sleep(for: .seconds(5))
            }
        }
        // Leaving the field without pressing Return drops the edit.
        .onChange(of: symbolFocused) { _, focused in
            if !focused { symbolText = chart.symbol }
        }
    }

    /// The thick selection outline (fainter on another chart of the same stock), else the plain border.
    /// A stock with a color is outlined in it instead: as thick while selected, a third of that otherwise.
    private var outline: some View {
        let selected = isSelected || showsTarget
        let fade = isSelected || !showsTarget ? 1 : 0.6
        let thick = outlineWidth * SelectedOutline.selectedMultiple
        let color: Color, width: Double
        if let mark = workspace.stockColors[chart.symbol]?.color {
            (color, width) = (mark.opacity(fade), selected ? thick : outlineWidth)
        } else if selected {
            (color, width) = (Color.accentColor.opacity(fade), thick)
        } else {
            (color, width) = (Color.primary.opacity(0.12), 1)
        }
        return RoundedRectangle(cornerRadius: 4)
            .strokeBorder(color, lineWidth: width)
            .allowsHitTesting(false)
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

            // "2 LONG 23 322 +452": the orders that opened or added to the open round trip (an order in
            // several fills counts once), the market value in NOK (at cost until there's a quote), and the
            // P/L in NOK once there's a quote; without a USD.NOK rate, shares and the P/L in dollars. A
            // forex pair's values convert at its currency's dollar rate (none shown until that's in).
            if let p = broker.positions[chart.symbol] {
                let fills = broker.fills.values.filter { $0.symbol == chart.symbol }
                let orders = RoundTrip.build(fills: fills, positions: broker.positions).first(where: \.isOpen)?.orderCount ?? 0
                let last = broker.quote(p.symbol)?.last
                let usd = broker.usdPerPriceUnit(p.symbol)
                let valueNOK = usd.flatMap { usd in broker.usdNok.map { abs(p.quantity) * (last ?? p.avgCost) * usd * $0 } }
                let pnl = last.flatMap { last in usd.map { (last - p.avgCost) * p.quantity * $0 } }
                HStack(spacing: 4) {
                    Text("\(orders > 0 ? "\(orders) " : "")\(p.quantity > 0 ? "LONG" : "SHORT") \(valueNOK.map { Fmt.nok($0, groupedFrom: 0) } ?? Fmt.shares(abs(p.quantity)))")
                    if let pnl {
                        Text(broker.usdNok.map { Fmt.nok(pnl * $0, signed: true, groupedFrom: 0) } ?? Fmt.amount(pnl, signed: true))
                            .foregroundStyle(sideColors.of(pnl >= 0))
                    }
                }
                .help("\(orders > 0 ? "\(orders) order\(orders == 1 ? "" : "s") opened or added to it, " : "")"
                      + (ForexPair(p.symbol).map { "\(Fmt.shares(abs(p.quantity))) \($0.base)" } ?? "\(Fmt.shares(abs(p.quantity))) shares"))
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Capsule().fill(sideColors.of(p.quantity > 0).opacity(0.25)))
            }

            // A what-if trade (simulated, see `SimTrades.swift`): "SIM LONG 23 322 +452", its value and
            // P/L in NOK like a position's, outlined in the what-if color.
            if let sim = broker.simPositions[chart.symbol] {
                let last = broker.quote(sim.symbol)?.last
                let usd = broker.usdPerPriceUnit(sim.symbol)
                let valueNOK = usd.flatMap { usd in broker.usdNok.map { abs(sim.quantity) * (last ?? sim.avgCost) * usd * $0 } }
                let pnl = last.flatMap { broker.simPnLNOK(sim, at: $0) }
                HStack(spacing: 4) {
                    Text("SIM \(sim.isLong ? "LONG" : "SHORT") \(valueNOK.map { Fmt.nok($0, groupedFrom: 0) } ?? Fmt.shares(abs(sim.quantity)))")
                    if let pnl {
                        Text(Fmt.nok(pnl, signed: true, groupedFrom: 0)).foregroundStyle(sideColors.of(pnl >= 0))
                    }
                }
                .help("What-if trade, simulated and never sent to IB: \(Fmt.shares(abs(sim.quantity))) @ "
                      + "\(Fmt.price(sim.avgCost, for: sim.symbol)). ⌃-click the chart for its stop loss or take profit; ⌘⌫ closes it.")
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .padding(.horizontal, 5).padding(.vertical, 1)
                .overlay(Capsule().strokeBorder(TradingChart.whatIfColor.opacity(0.8)))
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

            // The short selling and buying power, then the timeframe switch. A chart too narrow for them
            // (a big grid) gets a menu showing its timeframe instead of the switch, then drops the
            // short selling power, then the buying power.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 4) { marginPower(.short); marginPower(.long); timeframeSwitch }
                HStack(spacing: 4) { marginPower(.short); marginPower(.long); timeframeMenu }
                HStack(spacing: 4) { marginPower(.long); timeframeMenu }
                timeframeMenu
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(broker.positionTint(chart.symbol, colors: sideColors))
    }

    /// The most a new long (buying power) or short (short selling power) in the stock can be worth
    /// in NOK now, by IB's margin (see `Broker.marginPowerNOK`), styled as an unselected timeframe.
    /// None against the position: no buying power while short, no short selling power while long.
    @ViewBuilder private func marginPower(_ side: Broker.MarginSide) -> some View {
        let held = broker.positions[chart.symbol]?.quantity ?? 0
        if side == .long ? held >= 0 : held <= 0, let nok = broker.marginPowerNOK(chart.symbol, side),
           let shares = broker.maxNewShares(chart.symbol, side), let size = broker.marginSize(chart.symbol, side) {
            let units = ForexPair(chart.symbol).map { " \($0.base)" } ?? " shares"
            let lendLimited = side == .short && shares < (size.maxShares ?? 0)
            Text(Fmt.nok(nok, groupedFrom: 0))
                .font(.system(size: 10, weight: .regular).monospacedDigit())
                .foregroundStyle(Color.secondary.opacity(0.7))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .help((side == .long ? "Buying power: IB's margin allows a long" : "Short selling power: IB's margin allows a short")
                      + " of up to \(Fmt.shares(shares))\(units)\(lendLimited ? " (the shares IB has to lend)" : "") "
                      + "at \(Fmt.price(size.price, for: chart.symbol)), \(Fmt.nok(nok, groupedFrom: 0)) NOK "
                      + "(asked again each minute, and after a position changes)")
        }
    }

    @ViewBuilder private var timeframeSwitch: some View {
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
    @Environment(\.sideColors) private var sideColors
    let chart: ChartModel
    /// ⌥-click orders; also switched off in the top bar.
    let allowsAltClick: Bool
    /// Called before an order or what-if from a click, e.g. to select the chart.
    var onTrade: () -> Void = {}

    @AppStorage(OrderAmount.storageKey) private var orderNOK = OrderAmount.initial
    @AppStorage(AltClickOrders.enabledKey) private var altClickOrders = true
    @AppStorage(DollarClickOrders.enabledKey) private var dollarClicks = false
    @AppStorage(DollarClickOrders.amountKey) private var dollarClickAmount = DollarClickOrders.defaultAmount
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
    @AppStorage(LineDashes.dotsKey(LineDashes.avgCostKey)) private var avgCostDots = LineDashes.defaultDots(LineDashes.avgCostKey)
    @AppStorage(LineDashes.dotsKey(LineDashes.altClickKey)) private var altClickDots = LineDashes.defaultDots(LineDashes.altClickKey)
    @AppStorage(LineDashes.dotsKey(LineDashes.stopLossKey)) private var stopLossDots = LineDashes.defaultDots(LineDashes.stopLossKey)
    @AppStorage(LineDashes.dotsKey(LineDashes.takeProfitKey)) private var takeProfitDots = LineDashes.defaultDots(LineDashes.takeProfitKey)
    @AppStorage(LineDashes.dotsKey(LineDashes.ordersKey)) private var ordersDots = LineDashes.defaultDots(LineDashes.ordersKey)
    @AppStorage(LineDashes.dotsKey(LineDashes.lastTradeKey)) private var lastTradeDots = LineDashes.defaultDots(LineDashes.lastTradeKey)
    @AppStorage(LineColors.closedTradeKey) private var closedTradeHex = ""
    @AppStorage(LineColors.showLastTradeLinesKey) private var showLastTradeLines = true
    @AppStorage(HoverPnLSize.storageKey) private var hoverSizing: HoverPnLSize = .buyingPower
    @AppStorage(HoverPnLSize.amountKey) private var hoverAmountNOK = HoverPnLSize.defaultAmount
    /// The closed round trip whose exit lines were cleared by a click or a new order.
    @State private var dismissedTrip: String?
    /// With Settings' last trade lines off: the round trip whose exit line shows for its first 7 s.
    @State private var flashingExitTrip: String?
    private static let exitFlashSeconds = 7.0

    var body: some View {
        CandleChart(
            chart: chart, lines: priceLines,
            // Switched off in the top bar: no handler, so ⌥ neither tints the price tag nor places orders.
            // The selected hotkey's order at the clicked price, or with none selected (the ⌥-click
            // buy box is), a buy for its NOK amount.
            onAltClick: allowsAltClick && altClickOrders ? { price in
                onTrade()
                if dollarClicks {
                    broker.placeDollars(dollarClickAmount, action: "BUY", symbol: chart.symbol, at: price)
                } else if let hotkey = workspace.selectedHotkey {
                    broker.run(hotkey, symbol: chart.symbol, at: price)
                } else {
                    broker.buyNOK(OrderAmount.clamp(orderNOK), symbol: chart.symbol, at: price)
                }
            } : nil,
            // Dollar clicks: ⌘-click sells the same amount ⌥-click buys.
            onCommandClick: allowsAltClick && altClickOrders && dollarClicks ? { price in
                onTrade()
                broker.placeDollars(dollarClickAmount, action: "SELL", symbol: chart.symbol, at: price)
            } : nil,
            altClickTint: dollarClicks ? sideColors.up : .white,
            commandClickTint: sideColors.down,
            tintsHoverLine: dollarClicks,
            onControlClick: { price in
                guard !chart.symbol.isEmpty else { return }
                onTrade()
                if hasPosition {
                    broker.placeProtective(symbol: chart.symbol, at: price)
                } else if broker.simPositions[chart.symbol] != nil {
                    // A what-if trade: its simulated stop loss or take profit.
                    broker.placeSimProtective(symbol: chart.symbol, at: price)
                } else {
                    // No position: a what-if buy at the clicked price, sized from IB's margin preview.
                    let symbol = chart.symbol
                    broker.sizeWhatIf(symbol: symbol, at: price, fraction: WhatIf.buyingPowerFraction) { size in
                        let whatIf = WhatIf(price: size.price, shares: size.shares, time: Date())
                        workspace.whatIfs[symbol] = whatIf
                        // IB's preview of exactly that buy, for its commissions and margin in the Orders panel.
                        broker.previewOrder("BUY", symbol: symbol, shares: size.shares, at: size.price) { preview in
                            guard workspace.whatIfs[symbol]?.time == whatIf.time else { return }
                            workspace.whatIfs[symbol]?.preview = preview
                        }
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
                if !hasPosition, broker.simPositions[chart.symbol] != nil {
                    return broker.simProtectiveKind(chart.symbol, at: price).map(protectiveColor)
                }
                guard hasPosition else { return Self.whatIfColor }
                guard let kind = broker.protectiveKind(symbol: chart.symbol, at: price),
                      !broker.protectiveFillsNow(symbol: chart.symbol, kind: kind, at: price) else { return nil }
                return protectiveColor(kind)
            },
            hoverPnL: { price in
                // The open position's if it closed there, else the what-if line's, else a pretend buy
                // at the last price, sized as Settings says: by buying power or a NOK amount. In dollars
                // (a forex pair's at its currency's dollar rate).
                guard let usd = broker.usdPerPriceUnit(chart.symbol) else { return nil }
                if let p = broker.positions[chart.symbol], p.quantity != 0 { return (price - p.avgCost) * p.quantity * usd }
                if let sim = broker.simPositions[chart.symbol] { return sim.pnl(at: price) * usd }
                if let whatIf = workspace.whatIfs[chart.symbol] { return whatIf.pnl(at: price) * usd }
                guard let last = broker.quote(chart.symbol)?.last else { return nil }
                if hoverSizing == .nok {
                    return broker.shares(forNOK: hoverAmountNOK, of: chart.symbol, at: last).map { (price - last) * $0 * usd }
                }
                return broker.marginSize(chart.symbol, .long)?.maxShares.map { (price - last) * ($0 * HoverPnLSize.fraction).rounded(.down) * usd }
            },
            onHover: { if hoverSizing == .buyingPower { broker.refreshMarginSize(symbol: chart.symbol, sides: [.long]) } },
            onCancelOrder: { id in
                if id == WhatIf.lineId {
                    workspace.whatIfs[chart.symbol] = nil
                } else if id == SimPosition.stopLossLineId || id == SimPosition.takeProfitLineId {
                    broker.removeSimProtective(chart.symbol, stopLoss: id == SimPosition.stopLossLineId,
                                               takeProfit: id == SimPosition.takeProfitLineId)
                } else {
                    broker.cancelOrder(id, why: "chart: clicked the order line")
                }
            },
            onClick: { dismissedTrip = closedTrip?.id ?? dismissedTrip },
            // Hides the round trip shown from the Round trips tab.
            // Takes a ⌃-click what-if off, the view staying as it is; without one the view resets. Hides
            // the round trip shown from the Round trips tab either way.
            onDoubleClick: {
                workspace.shownTrips[chart.symbol] = nil
                workspace.shownOrderFills[chart.symbol] = nil
                return workspace.whatIfs.removeValue(forKey: chart.symbol) != nil
            },
            shownFillIds: Set(shownTrip?.fillIds ?? []).union(workspace.shownOrderFills[chart.symbol] ?? [])
        )
        // With the last trade lines off, a round trip that just closed (in the last 30 s, so not one
        // from before the chart showed the symbol) shows its exit line for 7 s.
        .onChange(of: closedTrip?.id) { _, id in
            guard !showLastTradeLines, let id, let trip = closedTrip, Date().timeIntervalSince(trip.lastFill) < 30 else { return }
            flashingExitTrip = id
            Task {
                try? await Task.sleep(for: .seconds(Self.exitFlashSeconds))
                if flashingExitTrip == id { flashingExitTrip = nil }
            }
        }
        // A new order in the symbol clears the last trade's exit lines.
        .onChange(of: symbolOrders) { old, new in
            if old.symbol == new.symbol, !new.ids.isSubset(of: old.ids) {
                dismissedTrip = closedTrip?.id ?? dismissedTrip
            }
        }
        // A trip shown from the Round trips tab, or an order's fills from the Orders list, scrolls into
        // view once the chart has bars.
        .onChange(of: TripReveal(tripId: shownTrip?.id, orderFillIds: workspace.shownOrderFills[chart.symbol],
                                 hasBars: !chart.bars.isEmpty), initial: true) {
            if let shownTrip {
                reveal(from: shownTrip.start, to: shownTrip.lastFill)
            } else if let first = shownOrderFills.map(\.time).min(), let last = shownOrderFills.map(\.time).max() {
                reveal(from: first, to: last)
            }
        }
    }

    private struct TripReveal: Equatable {
        var tripId: String?
        var orderFillIds: Set<String>?
        var hasBars: Bool
    }

    /// Scrolls just enough to bring the first and last fills, at `start` and `end`, on screen (the first
    /// if both don't fit).
    private func reveal(from start: Date, to end: Date) {
        let bars = chart.bars
        guard !bars.isEmpty else { return }
        let seconds = chart.timeframe.barSeconds
        let first = CandleChart.barIndex(of: start, in: bars, barSeconds: seconds) ?? 0
        let last = CandleChart.barIndex(of: end, in: bars, barSeconds: seconds) ?? bars.count - 1
        let margin = 3.0
        let right = Double(bars.count) - chart.scrollBack
        if Double(last) + 1 + margin > right {
            chart.scrollBack = max(0, Double(bars.count) - Double(last) - 1 - margin)
        }
        if Double(first) - margin < Double(bars.count) - chart.scrollBack - chart.visibleBars {
            chart.scrollBack = max(0, Double(bars.count) - Double(first) + margin - chart.visibleBars)
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

    /// The round trip double-clicked in the Round trips tab, if it's in this chart's symbol.
    private var shownTrip: RoundTrip? {
        guard let id = workspace.shownTrips[chart.symbol] else { return nil }
        let fills = broker.fills.values.filter { $0.symbol == chart.symbol }
        return RoundTrip.build(fills: fills, positions: broker.positions).first { $0.id == id }
    }

    /// The fills of the order double-clicked in the Orders list, if it's in this chart's symbol.
    private var shownOrderFills: [Fill] {
        guard let ids = workspace.shownOrderFills[chart.symbol] else { return [] }
        return broker.fills.values.filter { ids.contains($0.id) }
    }

    /// The symbol's latest round trip once it's closed, until a click on the chart or a new order.
    private var closedTrip: RoundTrip? {
        let fills = broker.fills.values.filter { $0.symbol == chart.symbol }
        guard let trip = RoundTrip.build(fills: fills, positions: broker.positions).first,
              !trip.isOpen, trip.id != dismissedTrip else { return nil }
        return trip
    }

    /// The just-closed round trip whose exit line shows: with nothing shown from the Round
    /// trips tab or the Orders list, and with Settings' last trade lines off only for its first 7 s.
    private var exitingTrip: RoundTrip? {
        guard workspace.shownTrips[chart.symbol] == nil, workspace.shownOrderFills[chart.symbol] == nil,
              let trip = closedTrip, showLastTradeLines || flashingExitTrip == trip.id else { return nil }
        return trip
    }

    private var closedTradeColor: Color { LineColors.resolve(closedTradeHex, default: sideColors.down) }

    /// Hot pink: the system pink reads as red next to the stop loss line.
    static let whatIfColor = Color(red: 1.0, green: 0.25, blue: 0.8)

    private var hasPosition: Bool { broker.positions[chart.symbol].map { $0.quantity != 0 } ?? false }

    private func protectiveColor(_ kind: Broker.Protective.Kind) -> Color {
        kind == .stopLoss
            ? LineColors.resolve(stopLossHex, default: LineColors.defaultStopLoss)
            : LineColors.resolve(takeProfitHex, default: LineColors.defaultTakeProfit)
    }

    /// Line colors and solid / dashes / dots come from Settings.
    private var priceLines: [PriceLine] {
        var lines: [PriceLine] = []
        if let trip = shownTrip {
            // Shown from the Round trips tab: small dots, green at the average entry (unknown for shares
            // held from before today), red at the average exit.
            if trip.carried == 0, let entry = trip.entryPrice {
                lines.append(PriceLine(price: entry, color: sideColors.up, label: "Entry", dotted: true))
            }
            if let exit = trip.exitPrice {
                lines.append(PriceLine(price: exit, color: sideColors.down, label: "Exit", dotted: true))
            }
        } else if let fill = shownOrderFills.first {
            // Shown from the Orders list: small dots at the order's average fill price, green for a buy,
            // red for a sell.
            let shares = shownOrderFills.reduce(0) { $0 + $1.shares }
            if shares > 0 {
                let price = shownOrderFills.reduce(0) { $0 + $1.price * $1.shares } / shares
                let isBuy = fill.side == "BOT"
                lines.append(PriceLine(price: price, color: sideColors.of(isBuy), label: isBuy ? "Buy" : "Sell", dotted: true))
            }
        } else if let trip = exitingTrip {
            // Just exited: the closed trade color (Settings) at the average exit, from the latest candle to
            // the axis as order lines are, and green at the average entry (unknown for shares held from
            // before today).
            // With Settings' last trade lines off, only the exit line, for its first 7 s.
            if let exit = trip.exitPrice {
                lines.append(PriceLine(price: exit, color: closedTradeColor, label: "", dashed: lastTradeDashed,
                                       dotted: lastTradeDashed && lastTradeDots, drawnLikeOrder: true))
            }
            if showLastTradeLines, trip.carried == 0, let entry = trip.entryPrice {
                lines.append(PriceLine(price: entry, color: sideColors.up, label: "Avg", dashed: lastTradeDashed,
                                       dotted: lastTradeDashed && lastTradeDots))
            }
        }
        if let p = broker.positions[chart.symbol] {
            // Avg cost: number only on the axis (just left of it when the last price box would cover it).
            lines.append(PriceLine(price: p.avgCost, color: LineColors.resolve(avgCostHex, default: LineColors.defaultAvgCost),
                                   label: "", dashed: avgCostDashed, dotted: avgCostDashed && avgCostDots, movesAsideForLastPrice: true))
        }
        if let sim = broker.simPositions[chart.symbol] {
            // A what-if trade: its average price in the what-if color, SIM beside it, and its simulated stop
            // loss and take profit in their colors, dotted; a click on one takes it off.
            lines.append(PriceLine(price: sim.avgCost, color: Self.whatIfColor, label: "SIM", movesAsideForLastPrice: true))
            if let stop = sim.stopLoss {
                lines.append(PriceLine(price: stop, color: protectiveColor(.stopLoss), label: "SIM", dotted: true,
                                       orderId: SimPosition.stopLossLineId, cancelsOnClick: true))
            }
            if let target = sim.takeProfit {
                lines.append(PriceLine(price: target, color: protectiveColor(.takeProfit), label: "SIM", dotted: true,
                                       orderId: SimPosition.takeProfitLineId, cancelsOnClick: true))
            }
        }
        if let whatIf = workspace.whatIfs[chart.symbol] {
            // ⌃-clicked with no position: a line at the pretend buy's price, the price on the axis (just
            // left of it where the last price box would cover it) and, in the chart beside it, what it's
            // worth in NOK (80% of what IB's margin allows; "W" until the rate is in); a click on it removes it.
            let valueNOK = broker.usdPerPriceUnit(chart.symbol).flatMap { usd in broker.usdNok.map { whatIf.shares * whatIf.price * usd * $0 } }
            lines.append(PriceLine(price: whatIf.price, color: Self.whatIfColor, label: "", orderId: WhatIf.lineId,
                                   movesAsideForLastPrice: true, chartText: valueNOK.map(OrderAmount.format) ?? "W",
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
                                           label: "", dashed: isStop ? stopLossDashed : takeProfitDashed,
                                           dotted: isStop ? stopLossDashed && stopLossDots : takeProfitDashed && takeProfitDots, orderId: o.id,
                                           cancelsOnClick: true, fillProgress: o.fillProgress))
                }
                continue
            }
            if broker.chartOrderIds.contains(o.id) {
                // Placed by ⌥-clicking the chart: one line (a stop-limit's stop equals its limit), just the
                // price in its box.
                if let price = o.auxPrice ?? o.limitPrice {
                    lines.append(PriceLine(price: price, color: LineColors.resolve(altClickHex, default: LineColors.defaultAltClick),
                                           label: "", dashed: altClickDashed, dotted: altClickDashed && altClickDots, orderId: o.id,
                                           fillProgress: o.fillProgress))
                }
                continue
            }
            // Other orders: the side, no share count, in the box. A market order (⌘⌫'s close during
            // regular hours, say) has no price: "MKT" at the last price, following it until it fills.
            if let lmt = o.limitPrice {
                lines.append(PriceLine(price: lmt, color: LineColors.resolve(ordersHex, default: LineColors.defaultOrders),
                                       label: side, dashed: ordersDashed, dotted: ordersDashed && ordersDots, orderId: o.id,
                                       fillProgress: o.fillProgress))
            } else if o.orderType == "MKT" {
                lines.append(PriceLine(price: o.avgFillPrice, color: LineColors.resolve(ordersHex, default: LineColors.defaultOrders),
                                       label: "\(side) MKT", dashed: ordersDashed, dotted: ordersDashed && ordersDots,
                                       orderId: o.id, fillProgress: o.fillProgress, followsLastPrice: true))
            }
            // Stop / trigger price (TRAIL's aux is a distance, not a price).
            if let aux = o.auxPrice, !o.orderType.hasPrefix("TRAIL"), o.orderType != "REL" {
                lines.append(PriceLine(price: aux, color: .purple, label: "\(o.orderType) \(side)",
                                       dashed: ordersDashed, dotted: ordersDashed && ordersDots, orderId: o.id, fillProgress: o.fillProgress))
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
