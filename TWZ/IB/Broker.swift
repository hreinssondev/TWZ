//
//  Broker.swift
//  TWZ
//
//  The UI's view of the trading engine. Holds a copy of what the views show (connection status,
//  account values, positions, orders, fills, quotes, scanner results, chart bars), updated from
//  the engine's snapshots, and passes every command straight on to the engine's own thread.
//

import Foundation
import Observation

@Observable
final class Broker {
    typealias ConnectionState = TradingEngine.ConnectionState
    typealias Protective = TradingEngine.Protective

    // MARK: Connection settings (persisted)

    var host: String { didSet { defaults.set(host, forKey: "ib.host") } }
    var port: Int { didSet { defaults.set(port, forKey: "ib.port") } }
    var clientId: Int { didSet { defaults.set(clientId, forKey: "ib.clientId") } }

    var isLivePort: Bool { port == 4001 || port == 7496 }

    // MARK: Published state (copied from the engine)

    private(set) var state: ConnectionState = .disconnected
    private(set) var statusText = "Disconnected"
    private(set) var lastMessage: String?
    private(set) var account = ""

    private(set) var netLiquidation: Double?
    private(set) var grossPositionValue: Double?
    private(set) var dailyPnL: Double?
    private(set) var unrealizedPnL: Double?
    private(set) var realizedPnL: Double?

    private(set) var positions: [String: Position] = [:]
    private(set) var orders: [Int: OrderRow] = [:]
    private(set) var fills: [String: Fill] = [:]
    /// Every quote, for code outside views. Views read `quote(_:)` instead, so a tick in one symbol
    /// doesn't redraw every view that shows some other symbol's quote.
    @ObservationIgnored private(set) var quotes: [String: Quote] = [:]
    @ObservationIgnored private var quoteBoxes: [String: QuoteBox] = [:]
    /// Symbols IB refused real-time data for this session, with IB's reason.
    private(set) var unavailableQuotes: [String: String] = [:]
    /// Latest scanner results per list panel.
    private(set) var scans: [String: ScanResult] = [:]
    /// Symbols with a tick-by-tick trade stream open (see `setFastCharts`).
    private(set) var tickTradeSymbols: Set<String> = []
    /// Fast charts' symbols IB's tick-by-tick limit left without a trade stream.
    private(set) var tickLimitedSymbols: Set<String> = []
    /// IB's shortable tick per symbol: above 2.5 easy to borrow, above 1.5 hard to borrow, else not shortable.
    private(set) var shortability: [String: Double] = [:]
    /// Shares IB has to lend per symbol, live (tick 89).
    private(set) var shortableShares: [String: Double] = [:]
    /// IB's borrow fees and rebates, from its short stock file (see the Borrow tab).
    let borrowRates = BorrowRates()
    /// Regular-session closes keyed "SYMBOL|yyyyMMdd", fetched for after-hours scanner rows.
    private(set) var sessionCloses: [String: Double] = [:]
    /// NOK per USD (IDEALPRO mid), used to size alt-click chart buys. Starts at the last saved
    /// rate; `usdNokIsLive` turns true once this connection has a quote.
    private(set) var usdNok: Double?
    private(set) var usdNokIsLive = false
    /// Orders placed by alt-clicking a chart; drawn as solid lines in the ⌥-click color (Settings).
    private(set) var chartOrderIds: Set<Int> = []
    /// Stop loss / take profit orders placed by ⌃-clicking a chart, by order id.
    private(set) var protectiveOrders: [Int: Protective] = [:]
    /// What placed each order this app sent ("Mid", "Mkt", "⌥-click", "SL", …), by order id.
    private(set) var orderSources: [Int: String] = [:]

    /// Live market value of all positions in USD (falls back to cost when no quote yet).
    var totalPositionValue: Double? {
        guard state == .connected else { return nil }
        if positions.isEmpty { return 0 }
        return positions.values.reduce(0) { sum, p in
            sum + abs(p.quantity) * (quote(p.symbol)?.last ?? p.avgCost)
        }
    }

    /// Position value in NOK, the account's base currency like equity and P/L: the live USD value
    /// at USD.NOK, or IB's own (less frequently updated) gross position value without a rate.
    var totalPositionValueNOK: Double? {
        guard let usd = totalPositionValue else { return nil }
        guard let usdNok else { return grossPositionValue }
        return usd * usdNok
    }

    // MARK: Private

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private let engine = TradingEngine()
    @ObservationIgnored private var charts: [ChartModel] = []
    /// Bumped on every chart load, so bars still on their way from the previous load are dropped.
    @ObservationIgnored private var chartGeneration: [Int: Int] = [:]
    /// Last prices sampled by `recentChange(_:)`, oldest first, per symbol.
    @ObservationIgnored private var priceSamples: [String: [(time: Date, price: Double)]] = [:]

    static let recentChangeWindow: TimeInterval = 5 * 60
    private static let priceSampleInterval: TimeInterval = 4
    /// A symbol not sampled for this long (dropped off the lists, or the Mac slept) starts over.
    private static let priceSampleGap: TimeInterval = 30

    init() {
        host = defaults.string(forKey: "ib.host") ?? "127.0.0.1"
        port = defaults.object(forKey: "ib.port") as? Int ?? 4002          // paper gateway by default
        clientId = defaults.object(forKey: "ib.clientId") as? Int ?? 1
        let engine = engine
        apply(engine.queue.sync { engine.fullSnapshot() })
        engine.sink = { [weak self] snapshot in self?.apply(snapshot) }
    }

    // MARK: - Commands

    func connect() {
        let (host, port, clientId) = (host, port, clientId)
        engine.perform { $0.connect(host: host, port: port, clientId: clientId) }
    }

    func disconnect() {
        engine.perform { $0.disconnect() }
    }

    /// Each UI component ("chart-0", "list-left", …) declares the symbols it needs quotes for.
    func setQuoteSymbols(_ symbols: [String], owner: String) {
        engine.perform { $0.setQuoteSymbols(symbols, owner: owner) }
    }

    /// Each list panel declares the scanner it shows (nil to stop it).
    func setScanner(_ spec: ScanSpec?, owner: String) {
        engine.perform { $0.setScanner(spec, owner: owner) }
    }

    func registerCharts(_ charts: [ChartModel]) {
        self.charts = charts
        let specs = charts.map { ChartSpec(id: $0.id, symbol: $0.symbol, timeframe: $0.timeframe, fullHistory: $0.hasFullHistory) }
        engine.perform { $0.registerCharts(specs) }
    }

    /// These charts get tick-by-tick trades, as does the selected one; the others keep IB's regular bar updates.
    func setFastCharts(_ ids: Set<Int>) {
        engine.perform { $0.setFastCharts(ids) }
    }

    /// The selected chart's symbol gets tick-by-tick trades and bid/ask, fast or not, before any other.
    func setSelectedChart(_ id: Int) {
        engine.perform { $0.setSelectedChart(id) }
    }

    func loadChart(_ chart: ChartModel) {
        let generation = (chartGeneration[chart.id] ?? 0) + 1
        chartGeneration[chart.id] = generation
        chart.bars = []
        chart.error = nil
        chart.scrollBack = 0
        chart.priceShift = 0
        chart.priceScale = 1
        chart.isLoading = state == .connected && !chart.symbol.isEmpty
        chart.hasFullHistory = false
        let spec = ChartSpec(id: chart.id, symbol: chart.symbol, timeframe: chart.timeframe)
        engine.perform { $0.loadChart(spec, generation: generation) }
    }

    /// The view reached the chart's oldest bar: loads the full history (`Timeframe.duration`, with
    /// the overnight session) behind the short one it started with. The bars on screen stay until
    /// it's in, and the view stays where it is. Once per load.
    func loadFullHistory(_ chart: ChartModel) {
        guard state == .connected, !chart.hasFullHistory, !chart.isLoading, !chart.symbol.isEmpty, !chart.bars.isEmpty else { return }
        chart.hasFullHistory = true
        let (id, generation) = (chart.id, chartGeneration[chart.id] ?? 0)
        engine.perform { $0.loadFullHistory(id, generation: generation) }
    }

    /// `why` goes in the order log, e.g. "Orders panel ✕".
    func cancelOrder(_ orderId: Int, why: String) {
        order { $0.cancelOrder(orderId, why: why) }
    }

    /// ⌥Z: cancels the most recently placed order that's still working.
    func cancelLastOrder() {
        order { $0.cancelLastOrder() }
    }

    /// ⌥< and the Cancel Symbol hotkey: every working order in `symbol`, stop loss and take profit included.
    func cancelOrders(for symbol: String) {
        order { $0.cancelOrders(for: symbol) }
    }

    func cancelAllOrders() {
        order { $0.cancelAllOrders() }
    }

    func run(_ hotkey: Hotkey, symbol: String) {
        order { $0.run(hotkey, symbol: symbol) }
    }

    /// Alt-click on a chart: a DAY buy for `nok` worth of `symbol` at the clicked price.
    func buyNOK(_ nok: Double, symbol: String, at clickedPrice: Double) {
        order { $0.buyNOK(nok, symbol: symbol, at: clickedPrice) }
    }

    /// ⌃-click on a chart: a GTC stop loss or take profit closing the whole position at the clicked price.
    func placeProtective(symbol: String, at clickedPrice: Double) {
        order { $0.placeProtective(symbol: symbol, at: clickedPrice) }
    }

    /// ⌃-click on a chart with no position: sizes a what-if buy at the clicked price from IB's margin
    /// preview, `fraction` of the largest long allowed. `completion` gets it a second or two later,
    /// or never if IB can't size it (`lastMessage` says why).
    func sizeWhatIf(symbol: String, at price: Double, fraction: Double,
                    completion: @escaping @MainActor @Sendable (TradingEngine.WhatIfSize) -> Void) {
        engine.perform { engine in
            engine.sizeWhatIf(symbol: symbol, at: price, fraction: fraction) { size in
                Task { @MainActor in completion(size) }
            }
        }
    }

    /// Order commands are timed from here until they reach the socket.
    private func order(_ work: @escaping @Sendable (TradingEngine) -> Void) {
        engine.perform(start: DispatchTime.now().uptimeNanoseconds, work)
    }

    // MARK: - Queries (on the UI's copy)

    /// Regular-session close to measure after-hours moves against (today's 16:00 close).
    func sessionClose(_ symbol: String) -> Double? {
        sessionCloses["\(symbol)|\(MarketSession.dayKey())"]
    }

    /// Shares a NOK amount buys at `price`, converted at the current USD.NOK rate.
    func shares(forNOK nok: Double, at price: Double) -> Double? {
        TradingEngine.shares(forNOK: nok, at: price, usdNok: usdNok)
    }

    /// What a ⌃-click at `price` places: a stop loss on the losing side of the position's average
    /// cost, a take profit on the winning side. nil without a position.
    func protectiveKind(symbol: String, at price: Double) -> Protective.Kind? {
        TradingEngine.protectiveKind(positions[symbol.uppercased()], at: price)
    }

    /// True between the average cost and the last trade, where the order would fill as soon as it's placed.
    func protectiveFillsNow(symbol rawSymbol: String, kind: Protective.Kind, at price: Double) -> Bool {
        let symbol = rawSymbol.uppercased()
        return TradingEngine.protectiveFillsNow(positions[symbol], last: quotes[symbol]?.last, kind: kind, at: price)
    }

    /// One symbol's quote; a view reading it is redrawn only when that symbol's quote changes.
    func quote(_ symbol: String) -> Quote? {
        if let box = quoteBoxes[symbol] { return box.quote }
        let box = QuoteBox(quote: quotes[symbol])
        quoteBoxes[symbol] = box
        return box.quote
    }

    /// % change in the last price over the past `recentChangeWindow` (5 minutes). Samples the price
    /// as it goes, so callers poll it every few seconds; until a symbol has a full window of samples
    /// the change is measured from its first one and `isPartial` is true.
    func recentChange(_ symbol: String) -> (percent: Double, isPartial: Bool)? {
        guard state == .connected, let last = quotes[symbol]?.last, last > 0 else {
            priceSamples[symbol] = nil
            return nil
        }
        let now = Date()
        var samples = priceSamples[symbol] ?? []
        if let latest = samples.last, now.timeIntervalSince(latest.time) > Self.priceSampleGap {
            samples = []
        }
        if samples.last.map({ now.timeIntervalSince($0.time) >= Self.priceSampleInterval }) ?? true {
            samples.append((now, last))
        }
        // Keep the newest sample at or before the window's start, to measure from.
        let cutoff = now.addingTimeInterval(-Self.recentChangeWindow)
        if let i = samples.lastIndex(where: { $0.time <= cutoff }), i > 0 {
            samples.removeFirst(i)
        }
        priceSamples[symbol] = samples
        guard let base = samples.first, base.time < now else { return nil }
        return ((last - base.price) / base.price * 100, base.time > cutoff)
    }

    /// The distinct sources of these orders, e.g. "Mid" or "Mid/Last"; nil if none are known
    /// (orders placed in TWS, or before sources were recorded).
    func sourceLabel(_ orderIds: [Int]) -> String? {
        var labels: [String] = []
        for id in orderIds {
            if let label = orderSources[id], !labels.contains(label) { labels.append(label) }
        }
        return labels.isEmpty ? nil : labels.joined(separator: "/")
    }

    // MARK: - Snapshots

    /// Copies what changed; values that stayed the same aren't reassigned, so views reading them
    /// aren't redrawn for nothing.
    private func apply(_ s: EngineSnapshot) {
        if let st = s.status {
            update(\.state, st.state)
            update(\.statusText, st.statusText)
            update(\.lastMessage, st.lastMessage)
            update(\.account, st.account)
            update(\.netLiquidation, st.netLiquidation)
            update(\.grossPositionValue, st.grossPositionValue)
            update(\.dailyPnL, st.dailyPnL)
            update(\.unrealizedPnL, st.unrealizedPnL)
            update(\.realizedPnL, st.realizedPnL)
            update(\.usdNok, st.usdNok)
            update(\.usdNokIsLive, st.usdNokIsLive)
        }
        if let v = s.positions { update(\.positions, v) }
        if let v = s.orders { update(\.orders, v) }
        if let v = s.fills { update(\.fills, v) }
        if let v = s.quotes {
            quotes = v
            for (symbol, box) in quoteBoxes where box.quote != v[symbol] { box.quote = v[symbol] }
        }
        if let v = s.unavailableQuotes { update(\.unavailableQuotes, v) }
        if let v = s.scans { update(\.scans, v) }
        if let v = s.tickTradeSymbols { update(\.tickTradeSymbols, v) }
        if let v = s.tickLimitedSymbols { update(\.tickLimitedSymbols, v) }
        if let v = s.shortability { update(\.shortability, v) }
        if let v = s.shortableShares { update(\.shortableShares, v) }
        if let v = s.sessionCloses { update(\.sessionCloses, v) }
        if let v = s.chartOrderIds { update(\.chartOrderIds, v) }
        if let v = s.protectiveOrders { update(\.protectiveOrders, v) }
        if let v = s.orderSources { update(\.orderSources, v) }
        for patch in s.charts {
            guard patch.generation == chartGeneration[patch.id] ?? 0,
                  let chart = charts.first(where: { $0.id == patch.id }) else { continue }
            if let bars = patch.bars { chart.bars = bars }
            for bar in patch.tail { Self.upsert(bar, into: chart) }
            if chart.isLoading != patch.isLoading { chart.isLoading = patch.isLoading }
            if chart.error != patch.error { chart.error = patch.error }
        }
    }

    private func update<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<Broker, T>, _ value: T) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }

    /// Replaces the bar with the same time, or inserts it in time order (almost always at the end).
    private static func upsert(_ bar: Bar, into chart: ChartModel) {
        guard let i = chart.bars.lastIndex(where: { $0.time <= bar.time }) else {
            chart.bars.insert(bar, at: 0)
            return
        }
        if chart.bars[i].time == bar.time {
            chart.bars[i] = bar
        } else {
            chart.bars.insert(bar, at: i + 1)
        }
    }
}

/// One symbol's quote, observed on its own (see `Broker.quote(_:)`).
@Observable
fileprivate final class QuoteBox {
    var quote: Quote?
    init(quote: Quote?) { self.quote = quote }
}
