//
//  TradingEngine.swift
//  TWZ
//
//  Talks the TWS API socket protocol to IB Gateway: handshake, market data, tick-by-tick
//  trades and quotes, historical bars, market scanners, account/P&L, positions and orders.
//  Message layouts follow client protocol versions 157...178 (pre-protobuf).
//
//  Everything here runs on one serial queue at user-interactive priority, apart from the UI,
//  so orders, fills and market data never wait behind SwiftUI layout or chart drawing. State is
//  touched only on `queue`. The UI sees it through `Broker`: whatever changed goes over in a
//  snapshot at most once per display frame, and never faster than the main thread takes them.
//

import Foundation
import os

nonisolated final class TradingEngine: @unchecked Sendable {
    enum ConnectionState: Sendable { case disconnected, connecting, connected }

    let queue = DispatchQueue(label: "TWZ.engine", qos: .userInteractive)

    /// Receives snapshots on the main thread.
    var sink: (@MainActor (EngineSnapshot) -> Void)?

    // MARK: Published state (each change goes out in the next snapshot)

    private var state: ConnectionState = .disconnected { didSet { changed(.status) } }
    private var statusText = "Disconnected" { didSet { changed(.status) } }
    private var lastMessage: String? { didSet { changed(.status) } }
    private var account = "" { didSet { changed(.status) } }

    private var netLiquidation: Double? { didSet { changed(.status) } }
    private var grossPositionValue: Double? { didSet { changed(.status) } }
    private var dailyPnL: Double? { didSet { changed(.status) } }
    private var unrealizedPnL: Double? { didSet { changed(.status) } }
    private var realizedPnL: Double? { didSet { changed(.status) } }
    /// NOK per USD (IDEALPRO mid), used to size alt-click chart buys. Starts at the last saved
    /// rate; `usdNokIsLive` turns true once this connection has a quote.
    private var usdNok: Double? { didSet { changed(.status) } }
    private var usdNokIsLive = false { didSet { changed(.status) } }

    private var positions: [String: Position] = [:] { didSet { changed(.positions) } }
    private var orders: [Int: OrderRow] = [:] { didSet { changed(.orders) } }
    private var fills: [String: Fill] = [:] { didSet { changed(.fills) } }
    private var quotes: [String: Quote] = [:] { didSet { changed(.quotes) } }
    /// IB's shortable tick per symbol: above 2.5 easy to borrow, above 1.5 hard to borrow, else not shortable.
    private var shortability: [String: Double] = [:] { didSet { changed(.shortability) } }
    /// Shares IB has to lend per symbol (tick 89, also from generic tick 236).
    private var shortableShares: [String: Double] = [:] { didSet { changed(.shortability) } }
    /// Short sale restriction (SEC Rule 201: a fall of 10% below the prior close restricts short sales
    /// to above the best bid for the rest of that day and the next) worked out from IB's prices, with
    /// why: seen live today, or in the regular-session lows of chart symbols' daily bars (today and
    /// yesterday). Nasdaq's own list (`SSRList`) adds what this misses.
    private var ssr: [String: String] = [:] { didSet { changed(.shortability) } }
    /// The ET day `ssr` holds; a new day clears it and asks for the charts' daily bars again.
    private var ssrDay = MarketSession.dayKey()
    private var ssrRequested: Set<String> = []
    private var ssrSymbolByReq: [Int: String] = [:]
    /// Nasdaq's Rule 201 list (`SSRList`), handed over by the UI.
    private var nasdaqSSR: Set<String> = []
    /// What the last short sale under SSR was priced at, for `submit`'s status line.
    private var ssrRaise: String?
    /// Short sales under SSR kept a tick above the bid until they fill, by order id, with what to resend
    /// them with; and when each was last re-priced.
    private struct SSRChase {
        var symbol: String
        var tif: TimeInForce
        var outsideRth: Bool
        var exchange: String
    }
    private var ssrChase: [Int: SSRChase] = [:]
    private var ssrChaseSent: [Int: UInt64] = [:]
    private var ssrChaseRecheck: Set<String> = []
    /// Symbols IB refused real-time data for this session, with IB's reason.
    private var unavailableQuotes: [String: String] = [:] { didSet { changed(.unavailable) } }
    /// Latest scanner results per list panel.
    private var scans: [String: ScanResult] = [:] { didSet { changed(.scans) } }
    /// Regular-session closes keyed "SYMBOL|yyyyMMdd", fetched for after-hours scanner rows.
    private var sessionCloses: [String: Double] = [:] { didSet { changed(.closes) } }
    /// Orders placed by alt-clicking a chart; drawn as solid lines in the ⌥-click color (Settings).
    private var chartOrderIds: Set<Int> { didSet { changed(.chartOrders) } }
    /// Stop loss / take profit orders placed by ⌃-clicking a chart, by order id.
    private var protectiveOrders: [Int: Protective] { didSet { changed(.protective) } }
    /// What placed each order this app sent ("Mid", "Mkt", "⌥-click", "SL", …), by order id; shown
    /// with fills and round trips.
    private var orderSources: [Int: String] { didSet { changed(.orderSources) } }

    // MARK: Private

    private let defaults = UserDefaults.standard
    private let socket: IBSocket
    private var clientId = 1
    private var serverVersion = 0
    private var nextOrderId: Int?
    private var nextReqId = 900_000_000   // far above order ids so error routing is unambiguous
    private var apiReady = false
    private var session = 0                 // bumped on every reset; stale timers check it
    private var hasLiveQuote = false        // any quote ticked this session
    private var noDataCheckScheduled = false

    private var quoteOwners: [String: Set<String>] = [:]
    private var quoteReqBySymbol: [String: Int] = [:]
    private var quoteSymbolByReq: [Int: String] = [:]
    /// Quotes from SMART and, during the overnight session, from IBKR's OVERNIGHT venue;
    /// `quotes` combines them.
    private var smartQuotes: [String: Quote] = [:]
    private var overnightQuotes: [String: Quote] = [:]
    private var overnightReqBySymbol: [String: Int] = [:]
    private var overnightSymbolByReq: [Int: String] = [:]
    private var phase = MarketSession.phase()

    private var scanSpecs: [String: ScanSpec] = [:]
    private var scanReqByOwner: [String: Int] = [:]
    private var scanOwnerByReq: [Int: String] = [:]
    private var closeKeyByReq: [Int: String] = [:]
    private var closesRequested: Set<String> = []

    private var charts: [Int: ChartState] = [:]
    private var selectedChartId = 0
    /// The charts picked for tick-by-tick streams (⌘↩); the others keep IB's regular bar updates.
    private var fastChartIds: Set<Int> = []
    private var chartByReq: [Int: Int] = [:]
    private var reqByChart: [Int: Int] = [:]
    /// Intraday charts also load the overnight session (20:00–03:50 ET) from the OVERNIGHT venue,
    /// since SMART's extended-hours bars stop at 20:00. Bars are kept per chart id.
    private var overnightChartByReq: [Int: Int] = [:]
    private var overnightReqByChart: [Int: Int] = [:]
    /// Overnight requests sent outside the overnight session: history only, no live updates (nothing
    /// new comes from the venue until 20:00), so they don't hold one of IB's open requests.
    private var overnightHistoryReqs: Set<Int> = []
    private var overnightBars: [Int: [Bar]] = [:]

    /// Tick-by-tick streams for the chart symbols: every trade (which also builds the live candle)
    /// for the selected chart and the fast charts, and every bid/ask change for the selected chart
    /// only. The selected chart's come first when IB's limit is reached.
    private var tickReqByStream: [TickStream: Int] = [:] { didSet { changed(.tickStreams) } }
    private var tickStreamByReq: [Int: TickStream] = [:]
    /// Streams IB refused (no permission, venue unsupported); not asked for again this session.
    private var tickRefused: Set<TickStream> = []
    /// How many streams IB allows at once, learnt from its first refusal for being over the limit.
    private var tickLimit: Int?
    /// Selected or fast charts' symbols left without a trade stream by IB's limit.
    private var tickLimitedSymbols: Set<String> = [] { didSet { changed(.tickStreams) } }

    /// Orders already asked to cancel, so ⌥Z pressed again moves on to the next one.
    private var cancelsSent: Set<Int> = []
    /// Stop losses to place again once the take profit blocking them is cancelled, by its order id.
    private var stopsAwaitingCancel: [Int: (symbol: String, price: Double)] = [:]
    /// ⌘⌫ closes waiting for their symbol's orders to cancel: each order id with what it had filled
    /// when the cancel went out (see `closePosition`).
    private var closesAwaitingCancel: [String: [Int: Double]] = [:]
    /// Margin previews (what-if orders) waiting for IB's answer, by order id.
    private var marginPreviews: [Int: (Result<MarginPreview, PreviewFailure>) -> Void] = [:]
    /// Every what-if order id sent, so IB's messages about them never show up as orders.
    private var whatIfOrderIds: Set<Int> = []
    /// IB has sent every position / open order since connecting (positionEnd, openOrderEnd).
    private var positionsLoaded = false
    private var openOrdersLoaded = false
    private var fxReq: Int?
    private var fxBid: Double?
    private var fxAsk: Double?
    private var fxSaved = Date.distantPast

    private let accountSummaryReq = 1
    private let pnlReq = 2
    private let executionsReq = 3

    /// "Requested market data is not subscribed" and variants (354, 10089, 10091, 10168).
    private static let noMarketDataCodes: Set<Int> = [354, 10089, 10091, 10168]
    /// "Max number of tick-by-tick requests has been reached."
    private static let tickLimitCode = 10190

    private static let minClientVersion = 157
    private static let maxClientVersion = 178
    private static let unsetDouble = Double.greatestFiniteMagnitude

    // MARK: Snapshots

    private struct Dirty: OptionSet {
        let rawValue: Int
        static let status = Dirty(rawValue: 1 << 0)
        static let positions = Dirty(rawValue: 1 << 1)
        static let orders = Dirty(rawValue: 1 << 2)
        static let fills = Dirty(rawValue: 1 << 3)
        static let quotes = Dirty(rawValue: 1 << 4)
        static let unavailable = Dirty(rawValue: 1 << 5)
        static let scans = Dirty(rawValue: 1 << 6)
        static let closes = Dirty(rawValue: 1 << 7)
        static let chartOrders = Dirty(rawValue: 1 << 8)
        static let protective = Dirty(rawValue: 1 << 9)
        static let orderSources = Dirty(rawValue: 1 << 10)
        static let tickStreams = Dirty(rawValue: 1 << 11)
        static let shortability = Dirty(rawValue: 1 << 12)
    }

    /// One display frame at 120 Hz (ProMotion): the UI never gets more snapshots than it can show.
    private static let frameNanos: UInt64 = 8_333_333
    private var dirty: Dirty = []
    private var dirtyCharts: Set<Int> = []
    private var flushScheduled = false
    private var flushInFlight = false
    private var lastFlush: UInt64 = 0

    // MARK: Measurements

    private static let log = Logger(subsystem: "TWZ", category: "engine")
    /// When the UI handed over the order command being run, to log how long it took to reach the socket.
    private var commandStart: UInt64?
    private var messagesHandled = 0
    private var worstMainWait: UInt64 = 0
    private var mainPings = 0

    init() {
        socket = IBSocket(queue: queue)
        usdNok = defaults.object(forKey: "fx.usdNok") as? Double
        chartOrderIds = Set(defaults.array(forKey: "chartOrderIds") as? [Int] ?? [])
        protectiveOrders = defaults.data(forKey: "protectiveOrders")
            .flatMap { try? JSONDecoder().decode([Int: Protective].self, from: $0) } ?? [:]
        orderSources = Dictionary(uniqueKeysWithValues: (defaults.dictionary(forKey: "orderSources") as? [String: String] ?? [:])
            .compactMap { key, value in Int(key).map { ($0, value) } })
        socket.onEvent = { [weak self] event in self?.handle(event) }
        queue.async { self.watchMainThread() }
    }

    /// Runs `work` on the engine queue. `start` marks an order command, timed until it reaches the socket.
    func perform(start: UInt64? = nil, _ work: @escaping @Sendable (TradingEngine) -> Void) {
        queue.async {
            self.commandStart = start
            work(self)
            self.commandStart = nil
        }
    }

    /// Everything the UI shows, for its initial state. Call on the engine queue.
    func fullSnapshot() -> EngineSnapshot {
        dirty = [.status, .positions, .orders, .fills, .quotes, .unavailable, .scans, .closes, .chartOrders, .protective, .orderSources, .tickStreams, .shortability]
        return takeSnapshot()
    }

    private func changed(_ d: Dirty) {
        dirty.insert(d)
        scheduleFlush()
    }

    private func scheduleFlush() {
        guard !flushScheduled, !flushInFlight else { return }
        flushScheduled = true
        let due = lastFlush + Self.frameNanos
        let now = DispatchTime.now().uptimeNanoseconds
        queue.asyncAfter(deadline: due > now ? DispatchTime(uptimeNanoseconds: due) : .now()) { [self] in
            flushScheduled = false
            flush()
        }
    }

    /// Sends what changed to the UI. The next snapshot waits until the main thread has applied
    /// this one, so a busy UI gets fewer, fuller snapshots instead of a growing backlog.
    private func flush() {
        guard !dirty.isEmpty || !dirtyCharts.isEmpty else { return }
        let snapshot = takeSnapshot()
        flushInFlight = true
        lastFlush = DispatchTime.now().uptimeNanoseconds
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated { sink?(snapshot) }
            queue.async { [self] in
                flushInFlight = false
                if !dirty.isEmpty || !dirtyCharts.isEmpty { scheduleFlush() }
            }
        }
    }

    private func takeSnapshot() -> EngineSnapshot {
        var s = EngineSnapshot()
        if dirty.contains(.status) {
            s.status = EngineSnapshot.Status(
                state: state, statusText: statusText, lastMessage: lastMessage, account: account,
                netLiquidation: netLiquidation, grossPositionValue: grossPositionValue, dailyPnL: dailyPnL,
                unrealizedPnL: unrealizedPnL, realizedPnL: realizedPnL, usdNok: usdNok, usdNokIsLive: usdNokIsLive)
        }
        if dirty.contains(.positions) { s.positions = positions }
        if dirty.contains(.orders) { s.orders = orders }
        if dirty.contains(.fills) { s.fills = fills }
        if dirty.contains(.quotes) { s.quotes = quotes }
        if dirty.contains(.unavailable) { s.unavailableQuotes = unavailableQuotes }
        if dirty.contains(.scans) { s.scans = scans }
        if dirty.contains(.closes) { s.sessionCloses = sessionCloses }
        if dirty.contains(.chartOrders) { s.chartOrderIds = chartOrderIds }
        if dirty.contains(.protective) { s.protectiveOrders = protectiveOrders }
        if dirty.contains(.orderSources) { s.orderSources = orderSources }
        if dirty.contains(.tickStreams) {
            s.tickTradeSymbols = Set(tickReqByStream.keys.filter { $0.kind == .last }.map(\.symbol))
            s.tickLimitedSymbols = tickLimitedSymbols
        }
        if dirty.contains(.shortability) {
            s.shortability = shortability
            s.shortableShares = shortableShares
            s.ssr = ssr
        }
        for id in dirtyCharts {
            guard let c = charts[id] else { continue }
            var patch = EngineSnapshot.ChartPatch(id: id, generation: c.generation, isLoading: c.isLoading, error: c.error)
            if c.sendAll {
                patch.bars = c.bars
            } else if let from = c.changedFrom {
                var i = c.bars.endIndex
                while i > c.bars.startIndex, c.bars[i - 1].time >= from { i -= 1 }
                patch.tail = Array(c.bars[i...])
            }
            c.sendAll = false
            c.changedFrom = nil
            s.charts.append(patch)
        }
        dirty = []
        dirtyCharts.removeAll()
        return s
    }

    /// A chart's loading state or error changed (`all`: its whole series; `from`: bars from then on).
    private func chartChanged(_ c: ChartState, all: Bool = false, from time: Date? = nil) {
        if all { c.sendAll = true }
        if let time { c.changedFrom = min(c.changedFrom ?? time, time) }
        dirtyCharts.insert(c.id)
        scheduleFlush()
    }

    /// Pings the main thread twice a second and logs, every 10 s, the longest it took to answer
    /// (how long the UI was blocked) and how many IB messages the engine handled meanwhile.
    private func watchMainThread() {
        let sent = DispatchTime.now().uptimeNanoseconds
        DispatchQueue.main.async { [self] in
            let waited = DispatchTime.now().uptimeNanoseconds - sent
            queue.async { [self] in
                worstMainWait = max(worstMainWait, waited)
                if waited > 100_000_000 {
                    Self.log.notice("Main thread blocked \(waited / 1_000_000) ms")
                }
            }
        }
        mainPings += 1
        if mainPings % 20 == 0 {
            Self.log.debug("Last 10 s: \(self.messagesHandled) IB messages, main thread worst wait \(Double(self.worstMainWait) / 1e6, format: .fixed(precision: 1)) ms")
            messagesHandled = 0
            worstMainWait = 0
        }
        queue.asyncAfter(deadline: .now() + 0.5) { [self] in watchMainThread() }
    }

    // MARK: - Connection

    func connect(host: String, port: Int, clientId: Int) {
        guard state == .disconnected else { return }
        resetSession()
        self.clientId = clientId
        state = .connecting
        statusText = "Connecting to \(host):\(port)…"
        socket.connect(host: host, port: port)
    }

    func disconnect() {
        socket.disconnect()
        resetSession()
        state = .disconnected
        statusText = "Disconnected"
    }

    private func resetSession() {
        if apiReady { log("DISCONNECTED") }
        serverVersion = 0
        nextOrderId = nil
        apiReady = false
        account = ""
        session += 1
        hasLiveQuote = false
        noDataCheckScheduled = false
        unavailableQuotes.removeAll()
        shortability.removeAll()
        shortableShares.removeAll()
        quoteReqBySymbol.removeAll()
        quoteSymbolByReq.removeAll()
        overnightReqBySymbol.removeAll()
        overnightSymbolByReq.removeAll()
        overnightQuotes.removeAll()
        chartByReq.removeAll()
        reqByChart.removeAll()
        overnightChartByReq.removeAll()
        overnightReqByChart.removeAll()
        overnightHistoryReqs.removeAll()
        overnightBars.removeAll()
        tickReqByStream.removeAll()
        tickStreamByReq.removeAll()
        tickRefused.removeAll()
        tickLimit = nil
        tickLimitedSymbols.removeAll()
        stopsAwaitingCancel.removeAll()
        closesAwaitingCancel.removeAll()
        marginPreviews.removeAll()
        positionsLoaded = false
        openOrdersLoaded = false
        cancelsSent.removeAll()
        scanReqByOwner.removeAll()
        scanOwnerByReq.removeAll()
        closeKeyByReq.removeAll()
        closesRequested.removeAll()
        ssrRequested.removeAll()
        ssrChase.removeAll()
        ssrChaseSent.removeAll()
        ssrSymbolByReq.removeAll()
        scans.removeAll()
        fxReq = nil
        fxBid = nil
        fxAsk = nil
        usdNokIsLive = false
        netLiquidation = nil
        grossPositionValue = nil
        dailyPnL = nil
        unrealizedPnL = nil
        realizedPnL = nil
        positions.removeAll()
        orders.removeAll()
        fills.removeAll()
    }

    private func handle(_ event: IBSocket.Event) {
        switch event {
        case .ready:
            var hello = Data("API".utf8)
            hello.append(0)
            hello.append(IBSocket.lengthPrefixed(Data("v\(Self.minClientVersion)..\(Self.maxClientVersion)".utf8)))
            socket.sendRaw(hello)
        case .message(let fields):
            messagesHandled += 1
            if serverVersion == 0 {
                handshake(fields)
            } else {
                dispatch(fields)
            }
        case .closed(let reason):
            resetSession()
            state = .disconnected
            statusText = reason ?? "Disconnected"
            lastMessage = reason
        }
    }

    private func handshake(_ fields: [String]) {
        guard let version = fields.first.flatMap(Int.init) else { return }
        serverVersion = version
        guard version >= Self.minClientVersion else {
            socket.disconnect()
            handle(.closed("IB Gateway is too old (server version \(version)). Please update it."))
            return
        }
        send(71, 2, clientId, "")   // startApi
    }

    private func checkReady() {
        guard !apiReady, nextOrderId != nil, !account.isEmpty else { return }
        apiReady = true
        state = .connected
        statusText = "Connected"
        lastMessage = nil

        send(59, 1, 1)                                                             // reqMarketDataType: real-time only
        send(61, 1)                                                                // reqPositions
        send(62, 1, accountSummaryReq, "All", "NetLiquidation,GrossPositionValue")  // reqAccountSummary
        send(92, pnlReq, account, "")                                              // reqPnL
        send(16, 1)                                                                // reqAllOpenOrders
        send(7, 3, executionsReq, 0, "", "", "", "", "", "")                       // reqExecutions (today)

        phase = MarketSession.phase()
        syncQuoteSubscriptions()
        watchSessionPhase()
        subscribeUsdNok()
        for id in charts.keys.sorted() { requestChart(id) }
        syncTickByTick()
        for owner in scanSpecs.keys { startScan(owner) }
    }

    // MARK: - Market data

    /// Each UI component ("chart-0", "list-left", …) declares the symbols it needs quotes for.
    func setQuoteSymbols(_ symbols: [String], owner: String) {
        quoteOwners[owner] = Set(symbols.filter { !$0.isEmpty })
        syncQuoteSubscriptions()
    }

    private func syncQuoteSubscriptions() {
        var wanted = quoteOwners.values.reduce(into: Set<String>()) { $0.formUnion($1) }
        wanted.formUnion(positions.keys)
        guard apiReady else { return }
        for (symbol, reqId) in quoteReqBySymbol where !wanted.contains(symbol) {
            send(2, 2, reqId)                                                      // cancelMktData
            quoteReqBySymbol[symbol] = nil
            quoteSymbolByReq[reqId] = nil
            shortability[symbol] = nil
            shortableShares[symbol] = nil
        }
        for symbol in wanted where quoteReqBySymbol[symbol] == nil {
            subscribeQuote(symbol)
        }

        let overnightWanted = phase == .overnight ? wanted : []
        for (symbol, reqId) in overnightReqBySymbol where !overnightWanted.contains(symbol) {
            send(2, 2, reqId)                                                      // cancelMktData
            overnightReqBySymbol[symbol] = nil
            overnightSymbolByReq[reqId] = nil
            overnightQuotes[symbol] = nil
            updateQuote(symbol)
        }
        for symbol in overnightWanted where overnightReqBySymbol[symbol] == nil {
            subscribeOvernightQuote(symbol)
        }
    }

    /// Checks the session every 30 s and moves quotes and tick-by-tick streams onto or off the
    /// OVERNIGHT venue when it changes; as the overnight session starts, intraday charts without its
    /// bars (see `requestChart`) start loading them.
    private func watchSessionPhase() {
        let current = session
        queue.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, self.session == current, self.apiReady else { return }
            if MarketSession.dayKey() != self.ssrDay {
                self.ssrDay = MarketSession.dayKey()
                self.ssr.removeAll()
                self.ssrRequested.removeAll()
                for c in self.charts.values { self.requestSSRBars(c.symbol) }
            }
            let now = MarketSession.phase()
            if now != self.phase {
                self.phase = now
                self.syncQuoteSubscriptions()
                self.syncTickByTick()
                for symbol in Set(self.smartQuotes.keys).union(self.overnightQuotes.keys) {
                    self.updateQuote(symbol)
                }
                if now == .overnight {
                    for c in self.charts.values where self.overnightReqByChart[c.id] == nil
                        && !c.symbol.isEmpty && !c.isLoading && c.timeframe.isIntraday {
                        self.requestOvernightBars(c)
                    }
                }
            }
            self.watchSessionPhase()
        }
    }

    /// SMART, except during the overnight session, when SMART is frozen at the 20:00 close and
    /// the OVERNIGHT venue's bid/ask/last (where overnight orders go) take over where it has them.
    private func updateQuote(_ symbol: String) {
        var q = smartQuotes[symbol] ?? Quote()
        if phase == .overnight, let o = overnightQuotes[symbol] {
            q.bid = o.bid ?? q.bid
            q.ask = o.ask ?? q.ask
            q.last = o.last ?? q.last
        }
        let oldLast = quotes[symbol]?.last
        if quotes[symbol] != q { quotes[symbol] = q }
        if let last = q.last, last != oldLast { followLast(symbol, price: last, isTrade: oldLast != nil) }
    }

    /// Moves the live candle of every chart showing `symbol` to the latest price as soon as it's
    /// known, so the candle never trails the last price line (the market data feed can report a
    /// trade before the tick-by-tick stream, and charts past IB's tick-by-tick limit have no
    /// trade stream at all). A changed price (`isTrade`) in a new period starts its candle; the first
    /// quote after subscribing doesn't, as that trade may be from long before.
    private func followLast(_ symbol: String, price: Double, isTrade: Bool) {
        let now = Date()
        for c in charts.values where c.symbol == symbol && !c.isLoading {
            guard let i = c.bars.indices.last else { continue }
            let start: Date
            if let seconds = c.timeframe.barSeconds {
                start = Date(timeIntervalSince1970: (now.timeIntervalSince1970 / seconds).rounded(.down) * seconds)
            } else {
                guard phase == .regular else { continue }
                start = Self.easternCalendar.startOfDay(for: now)
            }
            var bar = c.bars[i]
            if bar.time < start, isTrade {
                c.bars.append(Bar(time: start, open: price, high: price, low: price, close: price, volume: 0))
                chartChanged(c, from: start)
                continue
            }
            guard bar.time == start, bar.close != price else { continue }
            bar.high = max(bar.high, price)
            bar.low = min(bar.low, price)
            bar.close = price
            c.bars[i] = bar
            chartChanged(c, from: start)
        }
    }

    private func scheduleNoDataCheck() {
        guard !noDataCheckScheduled else { return }
        noDataCheckScheduled = true
        let current = session
        queue.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.session == current, self.apiReady,
                  !self.hasLiveQuote, let symbol = self.unavailableQuotes.keys.sorted().first else { return }
            let reason = self.unavailableQuotes[symbol] ?? ""
            self.disconnect()
            self.statusText = "Offline · no real-time market data subscription"
            self.lastMessage = "\(symbol): \(reason)"
        }
    }

    private func subscribeQuote(_ symbol: String) {
        guard apiReady, quoteReqBySymbol[symbol] == nil else { return }
        let reqId = makeReqId()
        quoteReqBySymbol[symbol] = reqId
        quoteSymbolByReq[reqId] = symbol
        sendFields([1, 11, reqId] + contract(symbol) + [false, "236", false, false, ""])   // reqMktData, 236: shortable
    }

    private func subscribeOvernightQuote(_ symbol: String) {
        guard apiReady, overnightReqBySymbol[symbol] == nil else { return }
        let reqId = makeReqId()
        overnightReqBySymbol[symbol] = reqId
        overnightSymbolByReq[reqId] = symbol
        sendFields([1, 11, reqId] + contract(symbol, exchange: "OVERNIGHT") + [false, "", false, false, ""])
    }

    /// USD.NOK on IDEALPRO (free forex quotes) for sizing NOK-denominated chart orders.
    private func subscribeUsdNok() {
        guard apiReady, fxReq == nil else { return }
        let reqId = makeReqId()
        fxReq = reqId
        sendFields([1, 11, reqId, 0, "USD", "CASH", "", 0.0, "", "", "IDEALPRO", "", "NOK", "", "",
                    false, "", false, false, ""])                                  // reqMktData
    }

    /// Live bid/ask mid only; without both, the last saved live rate stays in use.
    private func fxTick(type: Int, price: Double) {
        guard price > 0 else { return }
        switch type {
        case 1, 66: fxBid = price
        case 2, 67: fxAsk = price
        default: return
        }
        guard let rate = fxBid.flatMap({ b in fxAsk.map { (b + $0) / 2 } }) else { return }
        if usdNok != rate { usdNok = rate }
        if !usdNokIsLive { usdNokIsLive = true }
        if fxSaved.timeIntervalSinceNow < -60 {                         // saved once a minute, not every tick
            fxSaved = Date()
            defaults.set(rate, forKey: "fx.usdNok")
        }
    }

    // MARK: - Tick-by-tick

    /// A tick-by-tick stream: "Last" is every trade IB's own charts count (it leaves out odd lots
    /// and off-exchange prints that would spike the candles); "BidAsk" every change of the best bid/ask.
    private struct TickStream: Hashable {
        enum Kind: String { case last = "Last", bidAsk = "BidAsk" }
        var symbol: String
        var kind: Kind
        var venue: String
    }

    func setSelectedChart(_ id: Int) {
        guard selectedChartId != id else { return }
        selectedChartId = id
        syncTickByTick()
    }

    func setFastCharts(_ ids: Set<Int>) {
        guard fastChartIds != ids else { return }
        fastChartIds = ids
        syncTickByTick()
    }

    /// Subscribes the streams in priority order: the selected chart's trades and bid/ask, fast or
    /// not, since it's the one traded; then the fast charts' trades (their bid/ask comes with the
    /// regular quotes). Past IB's limit the rest are left off, and those charts keep IB's regular
    /// bar updates, as do the charts that aren't fast.
    private func syncTickByTick() {
        guard apiReady else { return }
        let venue = phase == .overnight ? "OVERNIGHT" : "SMART"
        var wanted: [TickStream] = []
        if let selected = charts[selectedChartId]?.symbol, !selected.isEmpty {
            wanted = [TickStream(symbol: selected, kind: .last, venue: venue), TickStream(symbol: selected, kind: .bidAsk, venue: venue)]
        }
        for c in charts.values.sorted(by: { $0.id < $1.id }) where !c.symbol.isEmpty && fastChartIds.contains(c.id) {
            let stream = TickStream(symbol: c.symbol, kind: .last, venue: venue)
            if !wanted.contains(stream) { wanted.append(stream) }
        }
        wanted.removeAll { tickRefused.contains($0) }
        let limited = Set(wanted.dropFirst(tickLimit ?? wanted.count).filter { $0.kind == .last }.map(\.symbol))
        if let tickLimit { wanted = Array(wanted.prefix(tickLimit)) }
        if tickLimitedSymbols != limited { tickLimitedSymbols = limited }

        let keep = Set(wanted)
        for (stream, reqId) in tickReqByStream where !keep.contains(stream) {
            send(98, reqId)                                                        // cancelTickByTickData
            tickReqByStream[stream] = nil
            tickStreamByReq[reqId] = nil
        }
        for stream in wanted where tickReqByStream[stream] == nil {
            let reqId = makeReqId()
            tickReqByStream[stream] = reqId
            tickStreamByReq[reqId] = stream
            // reqTickByTickData: contract, tick type, number of ticks (0 = live only), ignoreSize
            sendFields([97, reqId] + contract(stream.symbol, exchange: stream.venue) + [stream.kind.rawValue, 0, false])
        }
        logTickStreams()
    }

    /// Which tick-by-tick streams are open, and IB's limit once known, in the system log.
    private func logTickStreams() {
        let open = tickReqByStream.keys
            .map { "\($0.symbol) \($0.kind.rawValue)\($0.venue == "OVERNIGHT" ? " (overnight)" : "")" }
            .sorted().joined(separator: ", ")
        Self.log.notice("Tick-by-tick: \(self.tickReqByStream.count) open [\(open, privacy: .public)], limit \(self.tickLimit.map(String.init) ?? "not reached", privacy: .public)")
    }

    private func isStreamingTrades(_ symbol: String) -> Bool {
        tickReqByStream.keys.contains { $0.symbol == symbol && $0.kind == .last }
    }

    private func tickByTick(_ f: [String]) {
        // reqId, tickType, time, then Last/AllLast: price, size, mask, exchange, conditions
        //                         or BidAsk: bid, ask, bidSize, askSize, mask
        guard let stream = tickStreamByReq[f.int(1)] else { return }
        hasLiveQuote = true
        let overnight = stream.venue == "OVERNIGHT"
        switch f.int(2) {
        case 1, 2:
            let price = f.double(4)
            guard price > 0, f.int(6) & 2 == 0 else { return }                     // bit 1: unreported (late) print
            if overnight { overnightQuotes[stream.symbol, default: Quote()].last = price }
            else { smartQuotes[stream.symbol, default: Quote()].last = price }
            updateQuote(stream.symbol)
            applyTrade(stream.symbol, price: price, size: max(0, f.double(5)),
                       time: Date(timeIntervalSince1970: f.double(3)))
        case 3:
            let bid = f.double(4), ask = f.double(5)
            func update(_ q: inout Quote) {
                q.bid = bid > 0 ? bid : nil
                q.ask = ask > 0 ? ask : nil
            }
            if overnight { update(&overnightQuotes[stream.symbol, default: Quote()]) }
            else { update(&smartQuotes[stream.symbol, default: Quote()]) }
            updateQuote(stream.symbol)
        default:
            break
        }
    }

    /// Folds a trade into the live candle of every loaded chart showing `symbol`, starting a new
    /// candle when the trade opens the next bar. Daily charts count regular-hours trades only.
    private func applyTrade(_ symbol: String, price: Double, size: Double, time: Date) {
        for c in charts.values where c.symbol == symbol && !c.isLoading {
            guard let lastIndex = c.bars.indices.last else { continue }
            let start: Date
            if let seconds = c.timeframe.barSeconds {
                start = Date(timeIntervalSince1970: (time.timeIntervalSince1970 / seconds).rounded(.down) * seconds)
            } else {
                guard phase == .regular else { continue }
                start = Self.easternCalendar.startOfDay(for: time)
            }
            let last = c.bars[lastIndex]
            if last.time == start {
                c.bars[lastIndex].high = max(last.high, price)
                c.bars[lastIndex].low = min(last.low, price)
                c.bars[lastIndex].close = price
                c.bars[lastIndex].volume += size
            } else if last.time < start {
                c.bars.append(Bar(time: start, open: price, high: price, low: price, close: price, volume: size))
            } else {
                continue   // a late print for an earlier bar; IB's own bar updates cover it
            }
            chartChanged(c, from: start)
        }
    }

    // MARK: - Scanners

    /// Each list panel declares the scanner it shows (nil to stop it).
    func setScanner(_ spec: ScanSpec?, owner: String) {
        guard scanSpecs[owner] != spec else { return }
        stopScan(owner)
        scanSpecs[owner] = spec
        scans[owner] = nil
        startScan(owner)
    }

    private func startScan(_ owner: String) {
        guard apiReady, let spec = scanSpecs[owner] else { return }
        let reqId = makeReqId()
        scanReqByOwner[owner] = reqId
        scanOwnerByReq[reqId] = owner
        let f = spec.filter
        // reqScannerSubscription (server ≥ 143: no version field)
        sendFields([
            22, reqId, spec.rows, "STK", "STK.US.MAJOR", spec.kind.scanCode,
            f.minPrice ?? Self.unsetDouble, f.maxPrice ?? Self.unsetDouble, f.minVolume ?? Int.unset,
            Self.unsetDouble, Self.unsetDouble,       // market cap above/below
            "", "", "", "", "", "",                   // moody/S&P ratings, maturity dates
            Self.unsetDouble, Self.unsetDouble,       // coupon rate above/below
            false, Int.unset, "", "ALL",              // excludeConvertible, avgOptionVolume, settingPairs, stockType
            "", "",                                   // filter options, subscription options
        ])
    }

    private func stopScan(_ owner: String) {
        guard let reqId = scanReqByOwner.removeValue(forKey: owner) else { return }
        scanOwnerByReq[reqId] = nil
        if apiReady { send(23, 1, reqId) }                                        // cancelScannerSubscription
    }

    private func requestSessionCloses(_ symbols: [String]) {
        guard MarketSession.phase() == .afterHours else { return }
        let day = MarketSession.dayKey()
        for symbol in symbols {
            let key = "\(symbol)|\(day)"
            guard closesRequested.insert(key).inserted else { continue }
            let reqId = makeReqId()
            closeKeyByReq[reqId] = key
            sendFields([20, reqId] + contract(symbol) + [false, "", "1 day", "1 D", 1, "TRADES", 1, false, ""])
        }
    }

    func setNasdaqSSR(_ symbols: Set<String>) {
        nasdaqSSR = symbols
    }

    /// Under the short sale restriction, by Nasdaq's list or IB's prices.
    private func isSSR(_ symbol: String) -> Bool {
        nasdaqSSR.contains(symbol) || ssr[symbol] != nil
    }

    /// The lowest price a short sale under SSR can fill at: a tick above the bid.
    private static func ssrFloor(_ bid: Double) -> Double {
        roundToTick(bid + (bid < 1 ? 0.0001 : 0.01))
    }

    /// Moves `symbol`'s chasing SSR short sales to a tick above the bid as it moves, at most every half
    /// second each (checked again then, so the last move isn't missed).
    private func chaseSSRSells(_ symbol: String) {
        guard let bid = quotes[symbol]?.bid, bid > 0 else { return }
        let floor = Self.ssrFloor(bid)
        let now = DispatchTime.now().uptimeNanoseconds
        var throttled = false
        for (id, chase) in ssrChase where chase.symbol == symbol {
            guard let o = orders[id], o.isActive else {
                ssrChase[id] = nil
                ssrChaseSent[id] = nil
                continue
            }
            guard o.limitPrice != floor, o.status != "PendingSubmit", o.status != "PendingCancel",
                  !cancelsSent.contains(id) else { continue }
            if let sent = ssrChaseSent[id], now - sent < 500_000_000 {
                throttled = true
                continue
            }
            ssrChaseSent[id] = now
            placeOrder(symbol: symbol, action: "SELL", quantity: o.quantity, limit: floor, tif: chase.tif,
                       outsideRth: chase.outsideRth, exchange: chase.exchange, modifying: id,
                       why: "SSR: following the bid, \(Fmt.price(floor))")
        }
        if throttled, ssrChaseRecheck.insert(symbol).inserted {
            queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.ssrChaseRecheck.remove(symbol)
                self?.chaseSSRSells(symbol)
            }
        }
    }

    /// A chart symbol's last few regular-session daily bars, for `ssr`: once a day per symbol.
    private func requestSSRBars(_ symbol: String) {
        guard apiReady, !symbol.isEmpty, ssrRequested.insert(symbol).inserted else { return }
        let reqId = makeReqId()
        ssrSymbolByReq[reqId] = symbol
        sendFields([20, reqId] + contract(symbol) + [false, "", "1 day", "5 D", 1, "TRADES", 1, false, ""])
    }

    /// Restricted if yesterday's low was 10% below the close before it, or today's below yesterday's close.
    private func ssrFromDailyBars(_ symbol: String, _ bars: [(day: String, low: Double, close: Double)]) {
        guard ssr[symbol] == nil else { return }
        let past = bars.filter { $0.day < ssrDay }
        if past.count >= 2 {
            let y = past[past.count - 1], before = past[past.count - 2]
            if before.close > 0, y.low <= before.close * 0.9 {
                ssr[symbol] = "Fell 10% below the prior close yesterday (low \(Fmt.price(y.low)) vs \(Fmt.price(before.close)))"
                return
            }
        }
        if let today = bars.last, today.day == ssrDay, let y = past.last, y.close > 0, today.low <= y.close * 0.9 {
            ssr[symbol] = "Fell 10% below yesterday's close today (low \(Fmt.price(today.low)) vs \(Fmt.price(y.close)))"
        }
    }

    // MARK: - Charts

    func registerCharts(_ specs: [ChartSpec]) {
        for spec in specs where charts[spec.id] == nil {
            charts[spec.id] = ChartState(spec)
        }
    }

    /// Loads a chart's bars after its symbol or timeframe changed. `generation` tags its snapshots,
    /// so the UI can drop any still on their way from what it showed before.
    func loadChart(_ spec: ChartSpec, generation: Int) {
        let c = charts[spec.id] ?? ChartState(spec)
        charts[spec.id] = c
        let symbolChanged = c.symbol != spec.symbol
        c.symbol = spec.symbol
        c.timeframe = spec.timeframe
        c.fullHistory = spec.fullHistory
        c.generation = generation
        requestChart(spec.id)
        if symbolChanged { syncTickByTick() }
    }

    /// The view reached the chart's oldest bar: asks for its full history, keeping the bars it shows
    /// until that's in. Skipped if the chart has loaded something else since (`generation`).
    func loadFullHistory(_ id: Int, generation: Int) {
        guard let c = charts[id], c.generation == generation, !c.fullHistory, !c.symbol.isEmpty, !c.isLoading else { return }
        c.fullHistory = true
        requestChart(id, keepingBars: true)
    }

    /// (Re)requests a chart's bars. `keepingBars`: the bars it has stay on screen, not loading,
    /// until the new ones replace them.
    private func requestChart(_ id: Int, keepingBars: Bool = false) {
        guard let c = charts[id] else { return }
        if let old = reqByChart.removeValue(forKey: id) {
            if apiReady { send(25, 1, old) }                                      // cancelHistoricalData
            chartByReq[old] = nil
        }
        if let old = overnightReqByChart.removeValue(forKey: id) {
            if apiReady { send(25, 1, old) }                                      // cancelHistoricalData
            overnightChartByReq[old] = nil
            overnightHistoryReqs.remove(old)
        }
        overnightBars[id] = nil
        if !keepingBars {
            c.bars = []
            c.error = nil
            c.isLoading = apiReady && !c.symbol.isEmpty
            chartChanged(c, all: true)
        }
        guard apiReady, !c.symbol.isEmpty, c.isLoading || keepingBars else { return }
        requestSSRBars(c.symbol)
        let reqId = makeReqId()
        chartByReq[reqId] = id
        reqByChart[id] = reqId
        let tf = c.timeframe
        // reqHistoricalData: endDateTime "" + keepUpToDate streams live bar updates.
        // Every chart starts with a short history and skips the OVERNIGHT venue outside the overnight
        // session: a fraction of the data to load for a grid of charts. Its full history loads once
        // its view reaches the oldest bar (`loadFullHistory`).
        sendFields([20, reqId] + contract(c.symbol) + [
            false, "", tf.barSize, c.duration, tf.isIntraday ? 0 : 1, "TRADES", 2, true, "",
        ])
        guard tf.isIntraday, c.fullHistory || phase == .overnight else { return }
        requestOvernightBars(c)
    }

    /// The chart's bars from the OVERNIGHT venue (20:00–03:50 ET), merged into its own as they come;
    /// live during the overnight session, history only outside it (see `overnightHistoryReqs`).
    private func requestOvernightBars(_ c: ChartState) {
        let reqId = makeReqId()
        let live = phase == .overnight
        overnightChartByReq[reqId] = c.id
        overnightReqByChart[c.id] = reqId
        if !live { overnightHistoryReqs.insert(reqId) }
        sendFields([20, reqId] + contract(c.symbol, exchange: "OVERNIGHT") + [
            false, "", c.timeframe.barSize, c.duration, 0, "TRADES", 2, live, "",
        ])
    }

    // MARK: - Orders

    @discardableResult
    /// Places a stock order and returns its id; `limit == nil` sends a market order. With a `stop`
    /// it's a stop-limit (STP LMT) that triggers when the last trade reaches the stop.
    /// Orders sharing an `ocaGroup` cancel each other: when one fills, the rest shrink by as much.
    /// Passing `modifying` an existing order id changes that order instead of placing a new one.
    /// A `whatIf` order is never placed: IB answers with the margin it would take (see `previewMargin`).
    private func placeOrder(symbol: String, action: String, quantity: Double, limit: Double?, stop: Double? = nil,
                            tif: TimeInForce = .day, outsideRth: Bool = true, exchange: String = "SMART",
                            ocaGroup: String = "", modifying: Int? = nil, whatIf: Bool = false, why: String) -> Int? {
        guard apiReady, let next = nextOrderId else {
            lastMessage = "Not connected"
            return nil
        }
        guard quantity > 0 else {
            lastMessage = "Order quantity must be > 0"
            return nil
        }
        var limit = limit, why = why, chases = false
        // Under the short sale restriction a short sale fills only above the best bid (sells closing a
        // long are exempt and stay as they are). One meant to fill now (a market order, or a limit no
        // higher than a tick above the bid) goes in a tick above the bid and follows the bid until it
        // fills (`chaseSSRSells`). Stop orders, and limits set higher, stay as they are.
        if !whatIf, modifying == nil, action == "SELL", stop == nil, isSSR(symbol),
           quantity > max(0, positions[symbol]?.quantity ?? 0),
           let bid = quotes[symbol]?.bid, bid > 0 {
            let floor = Self.ssrFloor(bid)
            if limit.map({ $0 <= floor }) ?? true {
                let note = "SSR: short a tick above the bid, following it, \(limit.map { Fmt.price($0) } ?? "MKT") → \(Fmt.price(floor))"
                limit = floor
                chases = true
                why += " — \(note)"
                ssrRaise = note
                lastMessage = "\(symbol): \(note)"
            }
        }
        let orderId = modifying ?? next
        if modifying == nil {
            nextOrderId = next + 1
            forgetTags(orderId)
        }

        let orderType = stop != nil && limit != nil ? "STP LMT" : (limit == nil ? "MKT" : "LMT")
        let triggerMethod = stop != nil ? 2 : 0                           // 2 = last trade
        var f: [Any] = [3, orderId]
        f += contract(symbol, exchange: exchange)
        f += ["", ""]                                                     // secIdType, secId
        f += [action, quantity, orderType, limit ?? Self.unsetDouble, stop ?? Self.unsetDouble,
              tif.rawValue, ocaGroup, account, "", 0, "TWZ"]
        f += [true, 0, false, false, 0, triggerMethod, outsideRth && limit != nil, false]  // transmit … hidden
        f += ["", 0.0, "", "", "", "", ""]                                // sharesAlloc, discretionary, GAT, GTD, FA
        if serverVersion < 177 { f += [""] }                              // faProfile
        f += ["", 0, "", -1, ocaGroup.isEmpty ? 0 : 2, "", "", false, Int.unset, Self.unsetDouble, false, false, Self.unsetDouble]
        f += [0, Self.unsetDouble, Self.unsetDouble, Self.unsetDouble, Self.unsetDouble, Self.unsetDouble]
        f += [false, Self.unsetDouble, Int.unset, "", Self.unsetDouble]   // override%, volatility, volType, deltaNeutral
        f += [false, Int.unset, Self.unsetDouble, Self.unsetDouble, Int.unset, Int.unset, Self.unsetDouble]
        f += ["", "", "", ""]                                             // scaleTable, activeStart/Stop, hedgeType
        f += [false, "", "", false]                                       // optOutSmart, clearing, notHeld
        f += [false, ""]                                                  // deltaNeutralContract, algoStrategy
        f += ["", whatIf, "", false, false, false]                        // algoId, whatIf, misc, solicited, randomize
        f += [0]                                                          // conditions
        f += ["", Self.unsetDouble, Self.unsetDouble, Self.unsetDouble, Self.unsetDouble, Self.unsetDouble, 0, ""]
        f += ["", "", Self.unsetDouble, "", "", "", "", false, false, false, Int.unset]
        if serverVersion >= 158 { f += [Int.unset] }                      // duration
        if serverVersion >= 160 { f += [Int.unset] }                      // postToAts
        if serverVersion >= 162 { f += [false] }                          // autoCancelParent
        if serverVersion >= 166 { f += [""] }                             // advancedErrorOverride
        if serverVersion >= 169 { f += [""] }                             // manualOrderTime
        sendFields(f)
        if whatIf {
            log("WHATIF #\(orderId) \(action) \(Fmt.shares(quantity)) \(symbol) \(orderType)"
                + (limit.map { " lmt \(Fmt.price($0))" } ?? "") + " — \(why)")
            return orderId
        }
        logLatency("Order #\(orderId)")
        log("SEND #\(orderId)\(modifying != nil ? " (modify)" : "") \(action) \(Fmt.shares(quantity)) \(symbol) \(orderType)"
            + (stop.map { " stp \(Fmt.price($0))" } ?? "") + (limit.map { " lmt \(Fmt.price($0))" } ?? "")
            + " \(tif.rawValue)\(outsideRth && limit != nil ? " outsideRTH" : "") \(exchange)"
            + (ocaGroup.isEmpty ? "" : " oca=\(ocaGroup)") + " — \(why)")

        var row = OrderRow(
            id: orderId, symbol: symbol, action: action, quantity: quantity,
            orderType: orderType, limitPrice: limit, auxPrice: stop, status: "PendingSubmit", usdNok: usdNok
        )
        if modifying != nil, let old = orders[orderId] {
            row.status = old.status
            row.filled = old.filled
            row.usdNok = old.usdNok ?? usdNok
        }
        orders[orderId] = row
        if chases { ssrChase[orderId] = SSRChase(symbol: symbol, tif: tif, outsideRth: outsideRth, exchange: exchange) }
        return orderId
    }

    /// Order log line (Settings › Connection); built only while logging is on.
    private func log(_ line: @autoclosure () -> String) {
        if OrderLog.shared.isEnabled { OrderLog.shared.write(line()) }
    }

    private func describe(_ o: OrderRow?) -> String {
        guard let o else { return "(unknown order)" }
        return "\(o.action) \(Fmt.shares(o.quantity)) \(o.symbol) \(o.orderType)"
            + (o.auxPrice.map { " stp \(Fmt.price($0))" } ?? "") + (o.limitPrice.map { " lmt \(Fmt.price($0))" } ?? "")
            + " [\(o.status)]"
    }

    /// How long the order command took from the UI to the socket (the first message it sent).
    private func logLatency(_ what: String) {
        guard let start = commandStart else { return }
        commandStart = nil
        let micros = (DispatchTime.now().uptimeNanoseconds - start) / 1_000
        Self.log.notice("\(what, privacy: .public) sent \(micros) µs after the UI handed it over")
    }

    func cancelOrder(_ orderId: Int, why: String) {
        guard apiReady else { return }
        if serverVersion >= 169 { send(4, 1, orderId, "") } else { send(4, 1, orderId) }
        logLatency("Cancel #\(orderId)")
        cancelsSent.insert(orderId)
        log("CANCEL #\(orderId) \(describe(orders[orderId])) — \(why)")
    }

    /// ⌥Z: cancels the most recently placed order that's still working.
    func cancelLastOrder() {
        guard apiReady else {
            lastMessage = "Not connected to IB Gateway"
            return
        }
        let working = orders.values.filter { $0.isActive && $0.id > 0 && !cancelsSent.contains($0.id) }
        guard let o = working.max(by: { $0.id < $1.id }) else {
            lastMessage = "No working orders to cancel"
            return
        }
        cancelOrder(o.id, why: "⌥Z cancel last order")
        lastMessage = "Cancelling \(o.action) \(Fmt.shares(o.quantity - o.filled)) \(o.symbol) #\(o.id)"
    }

    /// ⌥< and the Cancel Symbol hotkey: every working order in `symbol`, stop loss and take profit included.
    func cancelOrders(for rawSymbol: String) {
        let symbol = rawSymbol.uppercased()
        guard apiReady else {
            lastMessage = "Not connected to IB Gateway"
            return
        }
        stopsAwaitingCancel = stopsAwaitingCancel.filter { $0.value.symbol != symbol }
        let working = orders.values.filter { $0.isActive && $0.symbol == symbol }
        for o in working { cancelOrder(o.id, why: "cancel symbol orders") }
        lastMessage = working.isEmpty
            ? "No working orders in \(symbol)"
            : "Cancelling \(working.count) order\(working.count == 1 ? "" : "s") in \(symbol)"
    }

    func cancelAllOrders() {
        guard apiReady else { return }
        send(58, 1)                                                       // reqGlobalCancel
        logLatency("Cancel all")
        log("CANCEL ALL (global cancel)")
    }

    /// ⌘⌫: what closes the position (Market, priced by session as `orderPrice` does).
    private static let closeAllMarket = Hotkey(label: "⌘⌫ Close 100% MKT", action: .closeAll, orderType: .market)

    /// ⌘⌫: cancels every working order in `symbol`, stop loss and take profit included, then closes
    /// the whole position at market, so IB doesn't refuse the close over orders already working
    /// against the position. The close goes once IB confirms the cancels (2 s at most), and not at
    /// all if one of those orders filled meanwhile: the position may already be closed.
    func closePosition(_ rawSymbol: String) {
        let symbol = rawSymbol.uppercased()
        guard apiReady else {
            lastMessage = "Not connected to IB Gateway"
            return
        }
        guard let p = positions[symbol], p.quantity != 0 else {
            lastMessage = "No position in \(symbol)"
            return
        }
        stopsAwaitingCancel = stopsAwaitingCancel.filter { $0.value.symbol != symbol }
        let working = orders.values.filter { $0.isActive && $0.symbol == symbol }
        for o in working { cancelOrder(o.id, why: "⌘⌫ closing the position") }
        // Orders entered in TWS can't be cancelled from here, so there's no confirming those.
        let awaited = working.filter { $0.id > 0 }
        guard !awaited.isEmpty else { return close(p, fraction: 1, hotkey: Self.closeAllMarket) }
        closesAwaitingCancel[symbol] = Dictionary(uniqueKeysWithValues: awaited.map { ($0.id, $0.filled) })
        lastMessage = "\(symbol): cancelling \(working.count) order\(working.count == 1 ? "" : "s"), then closing"
        let current = session
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.session == current, self.closesAwaitingCancel[symbol] != nil else { return }
            self.log("CLOSE \(symbol): not every cancel confirmed after 2 s; closing anyway")
            self.finishClose(symbol)
        }
    }

    /// Order `id` is done: sends the ⌘⌫ close waiting on it once none of the orders it waits on is working.
    private func closeIfCancelled(after id: Int, symbol: String) {
        guard let awaited = closesAwaitingCancel[symbol], awaited[id] != nil,
              awaited.keys.allSatisfy({ orders[$0]?.isActive != true }) else { return }
        finishClose(symbol)
    }

    /// Sends a ⌘⌫ close once its symbol's orders are cancelled (see `closePosition`).
    private func finishClose(_ symbol: String) {
        guard let awaited = closesAwaitingCancel.removeValue(forKey: symbol) else { return }
        if awaited.contains(where: { (orders[$0.key]?.filled ?? 0) > $0.value }) {
            lastMessage = "\(symbol): an order filled while cancelling, so the close wasn't sent — check the position"
            return
        }
        guard let p = positions[symbol], p.quantity != 0 else {
            lastMessage = "No position in \(symbol)"
            return
        }
        close(p, fraction: 1, hotkey: Self.closeAllMarket)
    }

    // MARK: - Hotkeys

    func run(_ hotkey: Hotkey, symbol rawSymbol: String) {
        let symbol = rawSymbol.uppercased()
        guard apiReady else {
            lastMessage = "Not connected to IB Gateway"
            return
        }
        // No chart selected (or no symbol in it): only the account-wide actions have something to do.
        if symbol.isEmpty, hotkey.action != .cancelAll, hotkey.action != .flattenAll {
            lastMessage = "Select a chart with a symbol first"
            return
        }

        switch hotkey.action {
        case .cancelAll:
            cancelAllOrders()
        case .cancelSymbol:
            cancelOrders(for: symbol)
        case .flattenAll:
            for p in positions.values where p.quantity != 0 {
                close(p, fraction: 1, hotkey: hotkey)
            }
        case .closeHalf, .closeAll:
            guard let p = positions[symbol], p.quantity != 0 else {
                lastMessage = "No position in \(symbol)"
                return
            }
            close(p, fraction: hotkey.action == .closeHalf ? 0.5 : 1, hotkey: hotkey)
        case .buy, .sell:
            guard !symbol.isEmpty else {
                lastMessage = "Select a chart with a symbol first"
                return
            }
            let action = hotkey.action == .buy ? "BUY" : "SELL"
            let isBuy = action == "BUY", why = "hotkey \"\(hotkey.label)\""
            func send(_ quantity: Double, at price: HotkeyPrice, summary: String? = nil) {
                guard quantity >= 1 else {
                    lastMessage = "Size too small for \(symbol)"
                    return
                }
                submit(symbol: symbol, action: action, quantity: quantity, price: price, tif: hotkey.tif,
                       summary: summary, source: Self.source(hotkey, isBuy: isBuy), why: why)
            }
            switch hotkey.sizing {
            case .shares:
                guard let price = orderPrice(symbol: symbol, action: action, hotkey: hotkey) else { return }
                send(hotkey.amount.rounded(.down), at: price)
            case .dollars:
                guard let price = orderPrice(symbol: symbol, action: action, hotkey: hotkey) else { return }
                // Market orders size off the side of the spread they'll likely fill at.
                guard let ref = price.limit ?? quote(symbol, .cross, isBuy: isBuy)?.price else {
                    lastMessage = "No price for \(symbol) yet"
                    return
                }
                send((hotkey.amount / ref).rounded(.down), at: price)
            case .buyingPower:
                // Sized at the side of the spread it'll likely fill at, priced once IB has answered.
                guard let ref = quote(symbol, .cross, isBuy: isBuy) else {
                    lastMessage = "No price for \(symbol) yet"
                    return
                }
                sizeFromBuyingPower(hotkey.amount, symbol: symbol, action: action, at: ref.price, why: why) { [self] shares, note in
                    guard let price = orderPrice(symbol: symbol, action: action, hotkey: hotkey) else { return }
                    send(shares, at: price, summary: "\(action) \(Fmt.shares(shares)), \(note)")
                }
            }
        }
    }

    /// Shares a close of `fraction` of the position takes; all of it when that's under one share.
    private static func closeQuantity(_ p: Position, fraction: Double) -> Double {
        let quantity = (abs(p.quantity) * fraction).rounded(.down)
        return quantity < 1 ? abs(p.quantity) : quantity
    }

    private func close(_ p: Position, fraction: Double, hotkey: Hotkey) {
        let action = p.quantity > 0 ? "SELL" : "BUY"
        let quantity = Self.closeQuantity(p, fraction: fraction)
        guard let price = orderPrice(symbol: p.symbol, action: action, hotkey: hotkey) else { return }
        submit(symbol: p.symbol, action: action, quantity: quantity, price: price, tif: hotkey.tif,
               source: Self.source(hotkey, isBuy: action == "BUY"),
               why: "hotkey \"\(hotkey.label)\" closing \(Int(fraction * 100))% of \(Fmt.shares(p.quantity))")
    }

    /// A hotkey order's source label: "Mkt", or the quote its limit is priced off ("Mid", "Last", "Ask", …).
    private static func source(_ hotkey: Hotkey, isBuy: Bool) -> String {
        hotkey.orderType == .market ? "Mkt" : hotkey.priceReference.label(isBuy: isBuy)
    }

    /// Remembers what placed an order (kept across launches for the latest 500 orders).
    private func recordSource(_ source: String, for id: Int) {
        orderSources[id] = source
        if orderSources.count > 500 {
            let kept = Set(orderSources.keys.sorted().suffix(500))
            orderSources = orderSources.filter { kept.contains($0.key) }
        }
        defaults.set(Dictionary(uniqueKeysWithValues: orderSources.map { (String($0.key), $0.value) }),
                     forKey: "orderSources")
    }

    // MARK: - Chart orders

    /// Shares a NOK amount buys at `price`, converted at the USD.NOK rate.
    static func shares(forNOK nok: Double, at price: Double, usdNok: Double?) -> Double? {
        guard let usdNok, usdNok > 0, price > 0 else { return nil }
        return (nok / usdNok / price).rounded(.down)
    }

    /// What an alt-click order places, decided from the live last trade only (no fallback prices).
    enum ChartOrder {
        /// On the side that fills at the clicked price or better (a buy at or below the last trade,
        /// a sell at or above it): a limit at the clicked price.
        case limit(Double)
        /// On the other side: a stop-limit that triggers when the last trade reaches the clicked
        /// price and fills at that price or better.
        case stopLimit(Double)
        /// Can't place one; the reason.
        case unavailable(String)

        var price: Double? {
            switch self {
            case .limit(let p), .stopLimit(let p): p
            case .unavailable: nil
            }
        }

        /// "BUY 45 @ 10.00" or "SELL STP 45 @ 10.00".
        func label(_ action: String, shares: Double) -> String? {
            switch self {
            case .limit(let p): "\(action) \(Fmt.shares(shares)) @ \(Fmt.price(p))"
            case .stopLimit(let p): "\(action) STP \(Fmt.shares(shares)) @ \(Fmt.price(p))"
            case .unavailable: nil
            }
        }
    }

    private func chartOrder(symbol: String, action: String, clicked: Double) -> ChartOrder {
        let price = Self.roundToTick(clicked)
        guard let last = quotes[symbol]?.last, last > 0 else {
            return .unavailable("No live price for \(symbol) yet")
        }
        if action == "BUY" ? price <= last : price >= last { return .limit(price) }
        // IBKR's overnight venue takes plain limit orders only.
        if MarketSession.phase() == .overnight { return .unavailable("No stop orders overnight") }
        return .stopLimit(price)
    }

    /// Alt-click on a chart with no hotkey selected: a DAY buy for `nok` worth of `symbol` at the
    /// clicked price; a limit below the last trade, a stop-limit above it.
    func buyNOK(_ nok: Double, symbol rawSymbol: String, at clickedPrice: Double) {
        let symbol = rawSymbol.uppercased()
        guard chartOrderReady(symbol) else { return }
        let plan = chartOrder(symbol: symbol, action: "BUY", clicked: clickedPrice)
        if case .unavailable(let reason) = plan {
            lastMessage = "\(reason), so the order wasn't sent"
            return
        }
        guard let limit = plan.price, let quantity = Self.shares(forNOK: nok, at: limit, usdNok: usdNok) else {
            lastMessage = "No USD.NOK rate yet, so the order can't be sized"
            return
        }
        guard quantity >= 1, let label = plan.label("BUY", shares: quantity) else {
            lastMessage = "\(OrderAmount.format(nok)) NOK is less than one share of \(symbol) at \(Fmt.price(limit))"
            return
        }
        placeChartOrder(symbol: symbol, action: "BUY", quantity: quantity, plan: plan, tif: .day,
                        outsideRth: true, summary: "\(label) (\(OrderAmount.format(nok)) NOK)")
    }

    /// Alt-click on a chart with a hotkey selected: that hotkey's order at the clicked price instead
    /// of at its quote. Buy / Sell size as the hotkey does (dollars and % of buying power at the
    /// clicked price), Close 50% / 100% from the position; a limit or stop-limit as for `buyNOK`, on
    /// the order's side.
    func run(_ hotkey: Hotkey, symbol rawSymbol: String, at clickedPrice: Double) {
        let symbol = rawSymbol.uppercased()
        guard chartOrderReady(symbol) else { return }
        func place(_ action: String, _ quantity: Double, note: String? = nil) {
            guard quantity >= 1 else {
                lastMessage = "Size too small for \(symbol)"
                return
            }
            let plan = chartOrder(symbol: symbol, action: action, clicked: clickedPrice)
            guard let label = plan.label(action, shares: quantity) else {
                if case .unavailable(let reason) = plan { lastMessage = "\(reason), so the order wasn't sent" }
                return
            }
            placeChartOrder(symbol: symbol, action: action, quantity: quantity, plan: plan, tif: hotkey.tif,
                            outsideRth: hotkey.outsideRth, summary: "\(label) (\(note ?? hotkey.label))")
        }
        switch hotkey.action {
        case .buy, .sell:
            let action = hotkey.action == .buy ? "BUY" : "SELL"
            let price = Self.roundToTick(clickedPrice)
            guard price > 0 else { return }
            switch hotkey.sizing {
            case .shares: place(action, hotkey.amount.rounded(.down))
            case .dollars: place(action, (hotkey.amount / price).rounded(.down))
            case .buyingPower:
                sizeFromBuyingPower(hotkey.amount, symbol: symbol, action: action, at: price,
                                    why: "⌥-click \"\(hotkey.label)\"") { shares, note in
                    place(action, shares, note: note)
                }
            }
        case .closeHalf, .closeAll:
            guard let p = positions[symbol], p.quantity != 0 else {
                lastMessage = "No position in \(symbol)"
                return
            }
            place(p.quantity > 0 ? "SELL" : "BUY", Self.closeQuantity(p, fraction: hotkey.action == .closeHalf ? 0.5 : 1))
        case .cancelSymbol, .cancelAll, .flattenAll:
            lastMessage = "⌥-click: \"\(hotkey.label)\" doesn't place an order at a price"
        }
    }

    private func chartOrderReady(_ symbol: String) -> Bool {
        guard apiReady else {
            lastMessage = "Not connected to IB Gateway"
            return false
        }
        guard !symbol.isEmpty else {
            lastMessage = "Load a symbol into the chart first"
            return false
        }
        return true
    }

    /// Sends an alt-click order and marks it as one, for its line color.
    private func placeChartOrder(symbol: String, action: String, quantity: Double, plan: ChartOrder,
                                 tif: TimeInForce, outsideRth: Bool, summary: String) {
        guard let limit = plan.price else { return }
        var price = HotkeyPrice(limit: limit, outsideRth: outsideRth)
        if case .stopLimit(let stop) = plan { price.stop = stop }
        if MarketSession.phase() == .overnight { price.exchange = "OVERNIGHT" }
        guard let id = submit(symbol: symbol, action: action, quantity: quantity, price: price, tif: tif,
                              summary: summary, source: "⌥-click", why: "⌥-click \(summary)") else { return }
        chartOrderIds.insert(id)
        defaults.set(Array(chartOrderIds.sorted().suffix(500)), forKey: "chartOrderIds")
    }

    // MARK: - What-if sizing

    /// A ⌃-click what-if buy: `fraction` of the largest long IB's margin allows in the symbol right
    /// now, at the clicked price.
    struct WhatIfSize: Sendable {
        var price: Double
        var shares: Double
        /// The largest long IB's margin allows.
        var maxShares: Double
    }

    /// What IB's margin preview of an order says.
    struct MarginPreview {
        /// Equity with loan value over the initial margin before the order: the available funds.
        var available: Double
        /// Initial margin each share adds, plus the equity it costs (commission).
        var perShare: Double

        var maxShares: Double { perShare > 0 ? max(0, available / perShare).rounded(.down) : 0 }
    }

    struct PreviewFailure: Error {
        var reason: String
    }

    /// Sizes a ⌃-click what-if buy from IB's margin previews (see `marginLimit`). Takes a second or
    /// two; `completion` runs on the engine queue, and not at all if IB can't size it (`lastMessage` says why).
    /// `quiet` (the hover P/L's sizing) leaves `lastMessage` alone.
    func sizeWhatIf(symbol rawSymbol: String, at clickedPrice: Double, fraction: Double, quiet: Bool = false,
                    completion: @escaping @Sendable (WhatIfSize) -> Void) {
        let symbol = rawSymbol.uppercased()
        func say(_ message: String) { if !quiet { lastMessage = message } }
        let why = quiet ? "margin preview for the hover P/L" : "margin preview for a ⌃-click what-if"
        guard apiReady else {
            say("Not connected to IB Gateway")
            return
        }
        guard !symbol.isEmpty else {
            say("Load a symbol into the chart first")
            return
        }
        guard clickedPrice > 0 else {
            say("\(symbol) what-if: no price there")
            return
        }
        let price = Self.roundToTick(clickedPrice)
        say("\(symbol) what-if: asking IB for the margin…")
        marginLimit(symbol, action: "BUY", price: price, why: why) { result in
            let preview: MarginPreview
            switch result {
            case .success(let p): preview = p
            case .failure(let failure):
                say("\(symbol) what-if: \(failure.reason)")
                return
            }
            let shares = (preview.maxShares * fraction).rounded(.down)
            guard shares >= 1 else {
                say("\(symbol) what-if: no buying power left for a long")
                return
            }
            say("\(symbol) what-if: BUY \(Fmt.shares(shares)) @ \(Fmt.price(price)), "
                + "\(Int((fraction * 100).rounded()))% of the \(Fmt.shares(preview.maxShares)) IB's margin allows")
            completion(WhatIfSize(price: price, shares: shares, maxShares: preview.maxShares))
        }
    }

    /// Sizes a % of buying power hotkey order: `percent` of the largest new long (BUY) or short
    /// (SELL) IB's margin allows in `symbol` at `price`. `send` gets the shares and a note saying so
    /// a second or two later, on the engine queue, and isn't called when it can't be sized
    /// (`lastMessage` says why). Refused while a position on the other side is open: IB's preview of
    /// an order that first closes it doesn't give the margin a new position takes.
    private func sizeFromBuyingPower(_ percent: Double, symbol: String, action: String, at rawPrice: Double,
                                     why: String, send: @escaping (_ shares: Double, _ note: String) -> Void) {
        let isBuy = action == "BUY", side = isBuy ? "long" : "short"
        let pct = percent.formatted(.number.precision(.fractionLength(0...1))) + "%"
        guard percent > 0, percent <= 100 else {
            lastMessage = "\(pct) of buying power: use 1–100%"
            return
        }
        if let held = positions[symbol]?.quantity, held != 0, (held > 0) != isBuy {
            lastMessage = "\(symbol): \(held > 0 ? "long" : "short") \(Fmt.shares(abs(held))) — close it before a \(pct) of buying power \(isBuy ? "buy" : "sell")"
            return
        }
        let price = Self.roundToTick(rawPrice)
        guard price > 0 else { return }
        lastMessage = "\(symbol): asking IB for the buying power for a \(side)…"
        marginLimit(symbol, action: action, price: price, why: "margin preview for \(why)") { [self] result in
            let preview: MarginPreview
            switch result {
            case .success(let p): preview = p
            case .failure(let failure):
                lastMessage = "\(symbol) \(pct) of buying power: \(failure.reason), so the order wasn't sent"
                return
            }
            let shares = (preview.maxShares * percent / 100).rounded(.down)
            guard shares >= 1 else {
                lastMessage = "\(symbol): no buying power left for a \(side)"
                return
            }
            send(shares, "\(pct) of the \(Fmt.shares(preview.maxShares)) IB's margin allows at \(Fmt.price(price))")
        }
    }

    /// The largest new `action` (BUY: long, SELL: short) IB's margin allows in `symbol` at `price`,
    /// from its margin previews (what-if orders, never placed). One for a small order gives the
    /// available funds and margin per share; margin per share can rise with the position's size, so
    /// a second near the largest size allowed refines it. `reply` runs on the engine queue a second
    /// or two later.
    private func marginLimit(_ symbol: String, action: String, price: Double, why: String,
                             _ reply: @escaping (Result<MarginPreview, PreviewFailure>) -> Void) {
        previewMargin(symbol, action: action, shares: max(1, (1000 / price).rounded(.down)), price: price, why: why) { [self] first in
            guard case .success(let small) = first, small.maxShares >= 1 else { return reply(first) }
            previewMargin(symbol, action: action, shares: max(1, (small.maxShares * 0.95).rounded(.down)),
                          price: price, why: why) { second in
                // Without the second answer, the small order's margin per share is the best there is.
                reply(.success((try? second.get()) ?? small))
            }
        }
    }

    /// Asks IB what `action` (BUY / SELL) of `shares` at `price` would do to the account's margin,
    /// without placing the order.
    private func previewMargin(_ symbol: String, action: String, shares: Double, price: Double, why: String,
                               _ reply: @escaping (Result<MarginPreview, PreviewFailure>) -> Void) {
        guard let id = placeOrder(symbol: symbol, action: action, quantity: shares, limit: price,
                                  whatIf: true, why: why) else { return }
        whatIfOrderIds.insert(id)
        marginPreviews[id] = reply
        let current = session
        queue.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, self.session == current, let reply = self.marginPreviews.removeValue(forKey: id) else { return }
            reply(.failure(PreviewFailure(reason: "IB didn't answer the margin preview")))
        }
    }

    /// The margin figures in IB's openOrder answer to a what-if order, read field by field the way
    /// IB's OrderDecoder does, from the outsideRth flag just past permId on to the order state.
    private func marginPreview(_ f: [String]) -> Result<MarginPreview, PreviewFailure> {
        var i = 26
        func next() -> String { defer { i += 1 }; return f.str(i) }
        func skip(_ n: Int) { i += max(0, n) }
        skip(5)                                     // outsideRth, hidden, discretionaryAmt, goodAfterTime, sharesAllocation
        skip(serverVersion < 177 ? 4 : 3)           // faGroup, faMethod, faPercentage (, faProfile)
        skip(5)                                     // modelCode, goodTillDate, rule80A, percentOffset, settlingFirm
        skip(4)                                     // shortSaleSlot, designatedLocation, exemptCode, auctionStrategy
        skip(5)                                     // startingPrice, stockRefPrice, delta, stockRangeLower, stockRangeUpper
        skip(6)                                     // displaySize, blockOrder, sweepToFill, allOrNone, minQty, ocaType
        skip(5)                                     // eTradeOnly, firmQuoteOnly, nbboPriceCap, parentId, triggerMethod
        skip(2)                                     // volatility, volatilityType
        let deltaNeutralType = next()
        skip(1)                                     // deltaNeutralAuxPrice
        if !deltaNeutralType.isEmpty { skip(8) }    // conId, settlingFirm, clearing ×2, openClose, shortSale ×3
        skip(6)                                     // continuousUpdate, referencePriceType, trail ×2, basisPoints ×2
        skip(1)                                     // comboLegsDescrip
        skip((Int(next()) ?? 0) * 8)                // combo legs
        skip(Int(next()) ?? 0)                      // order combo leg prices
        skip((Int(next()) ?? 0) * 2)                // smart combo routing params
        skip(2)                                     // scaleInitLevelSize, scaleSubsLevelSize
        if let increment = Double(next()), increment > 0, increment < Self.unsetDouble { skip(7) }
        if !next().isEmpty { skip(1) }              // hedgeType, hedgeParam
        skip(4)                                     // optOutSmartRouting, clearingAccount, clearingIntent, notHeld
        if next() == "1" { skip(3) }                // delta-neutral contract
        if !next().isEmpty { skip((Int(next()) ?? 0) * 2) }   // algoStrategy, its params
        skip(1)                                     // solicited
        let whatIf = next()
        skip(1)                                     // status
        func value() -> Double? { Double(next()).flatMap { $0 < Self.unsetDouble / 2 ? $0 : nil } }
        let initBefore = value(), _ = value(), equityBefore = value()
        let initChange = value(), _ = value(), equityChange = value()
        guard whatIf == "1" || whatIf == "true", let initBefore, let equityBefore, let initChange, let equityChange else {
            log("WHATIF #\(f.str(1)) unreadable answer: \(f.joined(separator: "|"))")
            return .failure(PreviewFailure(reason: "couldn't read IB's margin preview"))
        }
        let shares = f.double(14)
        guard shares > 0, initChange - equityChange > 0 else {
            return .failure(PreviewFailure(reason: "IB's margin preview shows no margin for the order"))
        }
        log("WHATIF #\(f.str(1)) init margin \(Fmt.amount(initBefore)) + \(Fmt.amount(initChange)), "
            + "equity with loan \(Fmt.amount(equityBefore)) \(Fmt.amount(equityChange, signed: true))")
        return .success(MarginPreview(available: equityBefore - initBefore,
                                      perShare: (initChange - equityChange) / shares))
    }

    // MARK: - Stop loss / take profit

    /// A ⌃-click order that closes the position, and the OCA group pairing it with its counterpart.
    struct Protective: Codable, Equatable, Sendable {
        enum Kind: String, Codable, Sendable { case stopLoss, takeProfit }
        var symbol: String
        var kind: Kind
        var ocaGroup: String
    }

    /// What a ⌃-click at `price` places: a stop loss on the losing side of the position's average
    /// cost, a take profit on the winning side. nil without a position.
    static func protectiveKind(_ position: Position?, at price: Double) -> Protective.Kind? {
        guard let p = position, p.quantity != 0 else { return nil }
        return (p.quantity > 0) == (price < p.avgCost) ? .stopLoss : .takeProfit
    }

    /// True between the average cost and the last trade, where the order would fill as soon as it's placed.
    static func protectiveFillsNow(_ position: Position?, last: Double?, kind: Protective.Kind, at price: Double) -> Bool {
        guard let qty = position?.quantity, qty != 0, let last, last > 0 else { return false }
        let belowLast = price <= last, aboveLast = price >= last
        return kind == .stopLoss ? (qty > 0 ? aboveLast : belowLast) : (qty > 0 ? belowLast : aboveLast)
    }

    /// ⌃-click on a chart: a GTC order closing the whole position at the clicked price. A second
    /// click of the same kind moves the existing order. The stop loss and take profit share an
    /// OCA group, so when one fills the other is cancelled.
    func placeProtective(symbol rawSymbol: String, at clickedPrice: Double) {
        let symbol = rawSymbol.uppercased()
        guard apiReady else {
            lastMessage = "Not connected to IB Gateway"
            return
        }
        guard positions[symbol].map({ $0.quantity != 0 }) ?? false else {
            lastMessage = "No position in \(symbol) to put a stop loss or take profit on"
            return
        }
        guard let kind = Self.protectiveKind(positions[symbol], at: clickedPrice) else { return }
        let price = Self.roundToTick(clickedPrice)
        if Self.protectiveFillsNow(positions[symbol], last: quotes[symbol]?.last, kind: kind, at: price),
           let last = quotes[symbol]?.last {
            lastMessage = "\(symbol): a \(kind == .stopLoss ? "stop loss" : "take profit") at \(Fmt.price(price)) "
                + "would fill right away (last \(Fmt.price(last))), so it wasn't sent"
            return
        }
        placeProtective(kind, symbol: symbol, price: price, why: "⌃-click")
    }

    /// Stop loss: a stop-limit with the limit 1% (at least 2¢) past the stop, so it can fill
    /// outside regular hours too. Take profit: a limit.
    private func placeProtective(_ kind: Protective.Kind, symbol: String, price: Double, why: String) {
        guard let qty = positions[symbol]?.quantity, qty != 0 else { return }
        let action = qty > 0 ? "SELL" : "BUY"
        let active = activeProtective(symbol)
        let existing = active.first { $0.value.kind == kind }?.key
        let group = active.first?.value.ocaGroup ?? "TWZ-\(symbol)-\(Int(Date().timeIntervalSince1970))"
        let (limit, stop) = Self.protectivePrices(kind, action: action, price: price)
        guard let id = placeOrder(symbol: symbol, action: action, quantity: abs(qty), limit: limit, stop: stop,
                                  tif: .gtc, outsideRth: true, ocaGroup: group, modifying: existing,
                                  why: "\(kind == .stopLoss ? "stop loss" : "take profit") for \(Fmt.shares(qty)) held (\(why))")
        else { return }
        protectiveOrders[id] = Protective(symbol: symbol, kind: kind, ocaGroup: group)
        saveProtective()
        recordSource(kind == .stopLoss ? "SL" : "TP", for: id)
        var message = "\(symbol): \(kind == .stopLoss ? "stop loss" : "take profit") \(action) \(Fmt.shares(abs(qty))) @ \(Fmt.price(price))"
        if existing != nil { message += " (moved)" }
        if MarketSession.phase() == .overnight || MarketSession.phase() == .closed {
            message += "; works from 4:00 ET pre-market"
        }
        lastMessage = message
    }

    private static func protectivePrices(_ kind: Protective.Kind, action: String, price: Double)
        -> (limit: Double, stop: Double?) {
        guard kind == .stopLoss else { return (price, nil) }
        let cushion = max(0.02, price * 0.01)
        return (roundToTick(max(0.0001, action == "SELL" ? price - cushion : price + cushion)), price)
    }

    /// Working stop loss / take profit orders in `symbol`. An order only counts if it still looks
    /// like the one placed (same symbol and order type), so a reused id never passes for one.
    private func activeProtective(_ symbol: String) -> [Int: Protective] {
        protectiveOrders.filter { id, p in
            guard p.symbol == symbol, let o = orders[id], o.isActive, o.symbol == symbol else { return false }
            return o.orderType == (p.kind == .stopLoss ? "STP LMT" : "LMT")
        }
    }

    /// A new order under an id the app has tagged before (IB's id sequence was reset, or another
    /// client id used it) is a different order: drop the old stop loss / take profit / ⌥-click tags.
    private func forgetTags(_ orderId: Int) {
        if protectiveOrders[orderId] != nil {
            protectiveOrders[orderId] = nil
            saveProtective()
        }
        if chartOrderIds.contains(orderId) {
            chartOrderIds.remove(orderId)
            defaults.set(Array(chartOrderIds.sorted().suffix(500)), forKey: "chartOrderIds")
        }
    }

    /// Once IB has sent all positions and open orders: a stop loss or take profit whose position
    /// closed while the app wasn't watching (sold in TWS, say) would sit at IB as a lone SELL/BUY,
    /// then be picked up and resized by the next position in that symbol. Cancel those.
    private func cancelOrphanedProtective() {
        guard positionsLoaded, openOrdersLoaded else { return }
        let orphaned = Set(protectiveOrders.values.map(\.symbol)).filter { symbol in
            positions[symbol] == nil && !activeProtective(symbol).isEmpty
        }
        guard !orphaned.isEmpty else { return }
        log("LEFTOVER stop loss / take profit with no position in \(orphaned.sorted().joined(separator: ", ")); cancelling")
        for symbol in orphaned { syncProtective(symbol) }      // no position: cancels them
        lastMessage = "Cancelled leftover stop loss / take profit orders with no position: "
            + orphaned.sorted().joined(separator: ", ")
    }

    private func saveProtective() {
        let kept = Dictionary(uniqueKeysWithValues: protectiveOrders.sorted { $0.key < $1.key }.suffix(500).map { ($0.key, $0.value) })
        protectiveOrders = kept
        if let data = try? JSONEncoder().encode(kept) { defaults.set(data, forKey: "protectiveOrders") }
    }

    /// Keeps ⌃-click orders closing exactly the position: cancelled once it's gone or flipped,
    /// resized when it changes (unless partly filled, where the OCA group already shrinks them).
    private func syncProtective(_ symbol: String) {
        let qty = positions[symbol]?.quantity ?? 0
        var resized: [String] = []
        for (id, p) in activeProtective(symbol) {
            guard let o = orders[id] else { continue }
            guard (o.action == "SELL" && qty > 0) || (o.action == "BUY" && qty < 0) else {
                cancelOrder(id, why: "\(p.kind == .stopLoss ? "stop loss" : "take profit") no longer matches the position (\(Fmt.shares(qty)) held)")
                continue
            }
            guard o.filled == 0, o.quantity != abs(qty),
                  let price = p.kind == .stopLoss ? o.auxPrice : o.limitPrice else { continue }
            let (limit, stop) = Self.protectivePrices(p.kind, action: o.action, price: price)
            guard placeOrder(symbol: symbol, action: o.action, quantity: abs(qty), limit: limit, stop: stop,
                             tif: .gtc, outsideRth: true, ocaGroup: p.ocaGroup, modifying: id,
                             why: "resize \(p.kind == .stopLoss ? "stop loss" : "take profit") to the position (\(Fmt.shares(qty)) held)")
                    != nil else { continue }
            resized.append(p.kind == .stopLoss ? "stop loss" : "take profit")
        }
        if !resized.isEmpty {
            lastMessage = "\(symbol): \(resized.sorted().joined(separator: " and ")) resized to \(Fmt.shares(abs(qty))) shares"
        }
    }

    /// The stop loss wins: if IBKR rejects one because a take profit already covers the position,
    /// cancel the take profit and place the stop loss again.
    private func protectiveRejected(_ id: Int, _ text: String) {
        guard let p = protectiveOrders[id], let o = orders[id] else { return }
        switch p.kind {
        case .stopLoss:
            guard let price = o.auxPrice, let tp = activeProtective(p.symbol).first(where: { $0.value.kind == .takeProfit })?.key
            else { return }
            stopsAwaitingCancel[tp] = (p.symbol, price)
            cancelOrder(tp, why: "stop loss #\(id) rejected; cancelling the take profit to place it again")
            lastMessage = "\(p.symbol): stop loss rejected (\(text)); cancelling the take profit to place it"
        case .takeProfit:
            if activeProtective(p.symbol).contains(where: { $0.value.kind == .stopLoss }) {
                lastMessage = "\(p.symbol): take profit rejected (\(text)); the stop loss stays"
            }
        }
    }

    /// Places the order, replacing the symbol's other working orders (its stop loss and take profit
    /// stay), and says in the status line when it replaced any, was priced off a fallback or won't
    /// work until a later session, after `summary` when one is given.
    @discardableResult
    private func submit(symbol: String, action: String, quantity: Double, price: HotkeyPrice,
                        tif: TimeInForce, summary: String? = nil, source: String, why: String) -> Int? {
        guard apiReady, nextOrderId != nil else {
            lastMessage = "Not connected"
            return nil
        }
        let replaced = replaceableOrders(symbol)
        for o in replaced { cancelOrder(o.id, why: "replaced by a new \(symbol) order (\(why))") }
        let overnight = price.exchange == "OVERNIGHT"
        ssrRaise = nil
        guard let id = placeOrder(symbol: symbol, action: action, quantity: quantity, limit: price.limit,
                                  stop: price.stop, tif: overnight ? .day : tif, outsideRth: price.outsideRth,
                                  exchange: price.exchange, why: why) else { return nil }
        recordSource(source, for: id)
        var notes = summary.map { [$0] } ?? []
        if let ssrRaise { notes.append(ssrRaise) }
        if !replaced.isEmpty {
            notes.append("replaced \(replaced.count == 1 ? "the previous order" : "\(replaced.count) orders")")
        }
        if let source = price.fallback, let limit = price.limit {
            notes.append("no live quote, priced off \(source) → \(Fmt.price(limit))")
        }
        switch MarketSession.phase() {
        case .overnight: notes.append("routed to IBKR overnight")
        case .closed: notes.append("market closed — works from 4:00 ET pre-market")
        default: break
        }
        if !notes.isEmpty { lastMessage = "\(symbol): " + notes.joined(separator: "; ") }
        return id
    }

    /// Working orders in `symbol` a new order replaces: everything but its stop loss and take profit,
    /// and orders entered in TWS, which the API can't cancel.
    private func replaceableOrders(_ symbol: String) -> [OrderRow] {
        orders.values.filter { o in
            o.symbol == symbol && o.isActive && o.status != "PendingCancel" && o.id > 0
                && protectiveOrders[o.id] == nil && !cancelsSent.contains(o.id)
        }
    }

    /// The quote a price reference points at. When it's missing (market closed, no data yet) this
    /// falls back to the last trade, then the chart's last bar (never the previous close), and
    /// names the fallback so the caller can say so.
    private func quote(_ symbol: String, _ reference: PriceReference, isBuy: Bool)
        -> (price: Double, fallback: String?)? {
        func valid(_ v: Double?) -> Double? { v.flatMap { $0 > 0 ? $0 : nil } }
        let q = quotes[symbol]
        let live: Double?
        switch reference {
        case .cross: live = valid(isBuy ? q?.ask : q?.bid)
        case .bid: live = valid(q?.bid)
        case .ask: live = valid(q?.ask)
        case .mid: live = valid(q.flatMap { q in q.bid.flatMap { b in q.ask.map { a in (a + b) / 2 } } })
        case .last: live = valid(q?.last)
        }
        if let live { return (live, nil) }
        if let last = valid(q?.last) { return (last, "last \(Fmt.price(last))") }
        let chart = charts.values.sorted { $0.id < $1.id }.first { $0.symbol == symbol }
        if let bar = valid(chart?.bars.last?.close) {
            return (bar, "chart close \(Fmt.price(bar))")
        }
        return nil
    }

    /// `limit == nil` means a market order.
    private struct HotkeyPrice {
        var limit: Double?
        var outsideRth: Bool
        var exchange = "SMART"
        var fallback: String?
        /// Stop trigger for a stop-limit order.
        var stop: Double?
    }

    /// Market, by session: regular hours → MKT; pre-market / after hours → limit 0.5% through the
    /// ask (buys) or bid (sells); overnight / closed → limit at the bid (buys) or ask (sells).
    /// Limit: the chosen reference, plus the offset for buys or minus it for sells.
    /// During IBKR's overnight session limit orders go to the OVERNIGHT venue so they can fill.
    private func orderPrice(symbol: String, action: String, hotkey: Hotkey) -> HotkeyPrice? {
        let isBuy = action == "BUY"
        let sign = isBuy ? 1.0 : -1.0
        let phase = MarketSession.phase()
        func tick(_ p: Double) -> Double { Self.roundToTick(max(p, 0.0001)) }
        func missing() -> HotkeyPrice? {
            lastMessage = "No price for \(symbol) at all yet (no quote or chart) — can't price the order"
            return nil
        }

        var price: HotkeyPrice
        switch (hotkey.orderType, phase) {
        case (.market, .regular):
            return HotkeyPrice(limit: nil, outsideRth: false)
        case (.market, .preMarket), (.market, .afterHours):
            guard let ref = quote(symbol, .cross, isBuy: isBuy) else { return missing() }
            let cushion = max(0.01, ref.price * 0.005)
            price = HotkeyPrice(limit: tick(ref.price + sign * cushion), outsideRth: true, fallback: ref.fallback)
        case (.market, _):
            guard let ref = quote(symbol, isBuy ? .bid : .ask, isBuy: isBuy) else { return missing() }
            price = HotkeyPrice(limit: tick(ref.price), outsideRth: true, fallback: ref.fallback)
        case (.limit, _):
            guard let ref = quote(symbol, hotkey.priceReference, isBuy: isBuy) else { return missing() }
            price = HotkeyPrice(limit: tick(ref.price + sign * hotkey.offset), outsideRth: hotkey.outsideRth,
                                fallback: ref.fallback)
        }
        if phase == .overnight {
            price.exchange = "OVERNIGHT"
            price.outsideRth = true
        }
        return price
    }

    static func roundToTick(_ p: Double) -> Double {
        let scale = p < 1 ? 10_000.0 : 100.0
        return (p * scale).rounded() / scale
    }

    // MARK: - Incoming messages

    private func dispatch(_ f: [String]) {
        guard let msgId = f.first.flatMap(Int.init) else { return }
        switch msgId {
        case 1: tickPrice(f)
        case 2: tickSize(f)
        case 3: orderStatus(f)
        case 4: errorMessage(f)
        case 5: openOrder(f)
        case 9:
            nextOrderId = max(nextOrderId ?? 0, f.int(2))
            log("CONNECTED client \(clientId), next order id \(f.str(2))")
            checkReady()
        case 11: execDetails(f)
        case 15:
            account = f.str(2).split(separator: ",").first.map(String.init) ?? ""
            checkReady()
        case 17: historicalData(f)
        case 20: scannerData(f)
        case 45: tickGeneric(f)
        case 53:
            log("LOADED open orders (\(orders.values.filter(\.isActive).count) working)")
            openOrdersLoaded = true
            cancelOrphanedProtective()
        case 61: position(f)
        case 62:
            log("LOADED positions (\(positions.count))")
            positionsLoaded = true
            cancelOrphanedProtective()
        case 63: accountSummary(f)
        case 90: historicalDataUpdate(f)
        case 94: pnl(f)
        case 99: tickByTick(f)
        default: break
        }
    }

    private func tickPrice(_ f: [String]) {
        let reqId = f.int(2)
        if reqId == fxReq { return fxTick(type: f.int(3), price: f.double(4)) }
        let isOvernight = overnightSymbolByReq[reqId] != nil
        guard let symbol = quoteSymbolByReq[reqId] ?? overnightSymbolByReq[reqId] else { return }
        hasLiveQuote = true
        let price = f.double(4)
        var q = (isOvernight ? overnightQuotes[symbol] : smartQuotes[symbol]) ?? Quote()
        switch f.int(3) {
        case 1, 66: q.bid = price > 0 ? price : nil
        case 2, 67: q.ask = price > 0 ? price : nil
        case 4, 68: if price > 0 { q.last = price }
        case 9, 75: if price > 0 { q.prevClose = price }
        default: return
        }
        if isOvernight { overnightQuotes[symbol] = q } else { smartQuotes[symbol] = q }
        if !isOvernight, ssr[symbol] == nil, let last = q.last, let close = q.prevClose, close > 0, last <= close * 0.9 {
            ssr[symbol] = "Traded 10% below yesterday's close today (\(Fmt.price(last)) vs \(Fmt.price(close)))"
        }
        updateQuote(symbol)
        if !ssrChase.isEmpty { chaseSSRSells(symbol) }
    }

    /// Volume stays SMART's full-day figure; the overnight venue's own volume isn't shown.
    private func tickSize(_ f: [String]) {
        guard let symbol = quoteSymbolByReq[f.int(2)] else { return }
        hasLiveQuote = true
        switch f.int(3) {
        case 8, 74:
            smartQuotes[symbol, default: Quote()].volume = f.double(4)
            updateQuote(symbol)
        case 89:
            let shares = f.double(4)
            if shortableShares[symbol] != shares { shortableShares[symbol] = shares }
        default: break
        }
    }

    /// Tick 46, "Shortable" (generic tick 236 on the SMART quote).
    private func tickGeneric(_ f: [String]) {
        guard f.int(3) == 46, let symbol = quoteSymbolByReq[f.int(2)] else { return }
        let value = f.double(4)
        if shortability[symbol] != value { shortability[symbol] = value }
    }

    private func orderStatus(_ f: [String]) {
        // orderId, status, filled, remaining, avgFillPrice, permId, parentId, lastFillPrice, clientId, whyHeld, mktCapPrice
        if whatIfOrderIds.contains(f.int(1)) { return }
        let id = Self.orderKey(orderId: f.int(1), permId: f.int(6))
        guard var o = orders[id] else {
            log("STATUS #\(id) for an order not seen yet: \(f.str(2)), filled \(f.str(3)), client \(f.str(9))")
            return
        }
        let changed = o.status != f.str(2) || o.filled != f.double(3)
        o.status = f.str(2)
        o.filled = f.double(3)
        o.avgFillPrice = f.double(5)
        o.updated = Date()
        orders[id] = o
        if changed {
            let why = f.str(10)
            log("STATUS #\(id) \(o.action) \(o.symbol) \(o.status) filled \(Fmt.shares(o.filled))/\(Fmt.shares(o.quantity))"
                + (o.filled > 0 ? " avg \(Fmt.price(o.avgFillPrice))" : "")
                + (f.int(9) != clientId ? " (client \(f.str(9)))" : "") + (why.isEmpty ? "" : " held: \(why)"))
        }
        if !o.isActive, let stop = stopsAwaitingCancel.removeValue(forKey: id) {
            placeProtective(.stopLoss, symbol: stop.symbol, price: stop.price, why: "placed again after its take profit was cancelled")
        }
        if !o.isActive { closeIfCancelled(after: id, symbol: o.symbol) }
    }

    private func openOrder(_ f: [String]) {
        guard f.count > 25 else { return }
        if whatIfOrderIds.contains(f.int(1)) {
            marginPreviews.removeValue(forKey: f.int(1))?(marginPreview(f))
            return
        }
        let id = Self.orderKey(orderId: f.int(1), permId: f.int(25))
        let lmt = f.double(16)
        let aux = f.double(17)
        let before = orders[id]
        var o = orders[id] ?? OrderRow(
            id: id, symbol: f.str(3), action: f.str(13), quantity: 0,
            orderType: f.str(15), limitPrice: nil, status: "Submitted", usdNok: usdNok
        )
        o.symbol = f.str(3)
        o.action = f.str(13)
        o.quantity = f.double(14)
        o.orderType = f.str(15)
        o.limitPrice = (lmt > 0 && lmt < Self.unsetDouble) ? lmt : nil
        o.auxPrice = (aux > 0 && aux < Self.unsetDouble) ? aux : nil
        orders[id] = o
        if before == nil {
            log("OPEN #\(id) \(describe(o)) — first seen from IB (not sent by this session)")
        } else if let b = before, b.action != o.action || b.quantity != o.quantity || b.orderType != o.orderType
                    || b.limitPrice != o.limitPrice || b.auxPrice != o.auxPrice || b.symbol != o.symbol {
            log("OPEN #\(id) now \(describe(o)), was \(describe(b))")
        }
    }

    /// Orders entered manually in TWS have orderId 0; key those by negative permId.
    private static func orderKey(orderId: Int, permId: Int) -> Int {
        orderId != 0 ? orderId : -permId
    }

    private func execDetails(_ f: [String]) {
        guard f.count > 20 else { return }
        let id = f.str(14)
        let fill = Fill(
            id: id,
            orderId: f.int(2),
            symbol: f.str(4),
            side: f.str(18),
            shares: f.double(19),
            price: f.double(20),
            time: Self.parseExecTime(f.str(15)) ?? Date(),
            usdNok: fills[id]?.usdNok ?? usdNok
        )
        if fills[fill.id] == nil {
            log("FILL #\(fill.orderId) \(fill.side) \(Fmt.shares(fill.shares)) \(fill.symbol) @ \(Fmt.price(fill.price)) exec \(fill.id)")
        }
        fills[fill.id] = fill
    }

    private func errorMessage(_ f: [String]) {
        let reqId = f.int(2)
        let code = f.int(3)
        let text = f.str(4)

        // 2100-2199 are connectivity/farm status notices; 10167 = "displaying delayed data".
        if (2100...2199).contains(code) || code == 10167 || code == 399 { return }

        if reqId == fxReq {
            fxReq = nil
            lastMessage = "USD.NOK rate: \(text)" + (usdNok.map { " (using saved \(Fmt.price($0)))" } ?? "")
            return
        }

        // Over IB's tick-by-tick limit: remember how many it allows, so the selected chart keeps
        // its streams. Refused for another reason: that chart keeps IB's regular bar updates.
        if let stream = tickStreamByReq.removeValue(forKey: reqId) {
            tickReqByStream[stream] = nil
            if code == Self.tickLimitCode {
                if tickLimit == nil {
                    lastMessage = "IB's tick-by-tick limit reached: the selected chart streams every tick, "
                        + "fast charts past the limit keep IB's regular bar updates"
                }
                tickLimit = tickReqByStream.count
                if stream.kind == .last { tickLimitedSymbols.insert(stream.symbol) }
                logTickStreams()
            } else {
                Self.log.notice("Tick-by-tick refused for \(stream.symbol, privacy: .public) \(stream.kind.rawValue, privacy: .public): \(code) \(text, privacy: .public)")
                tickRefused.insert(stream)
                if stream.venue != "OVERNIGHT" { lastMessage = "\(stream.symbol) tick-by-tick: \(text)" }
            }
            return
        }

        // The overnight venue is extra: a symbol it can't serve just keeps its SMART data.
        if overnightSymbolByReq[reqId] != nil { return }
        if let id = overnightChartByReq.removeValue(forKey: reqId) {
            overnightReqByChart[id] = nil
            overnightHistoryReqs.remove(reqId)
            return
        }

        // Not subscribed for this symbol: leave it without a quote. The request stays mapped so it
        // isn't retried. If no quote at all comes through, go offline rather than run without data.
        if Self.noMarketDataCodes.contains(code), let symbol = quoteSymbolByReq[reqId] {
            unavailableQuotes[symbol] = text
            scheduleNoDataCheck()
            return
        }

        if closeKeyByReq.removeValue(forKey: reqId) != nil { return }
        if ssrSymbolByReq.removeValue(forKey: reqId) != nil { return }
        if let owner = scanOwnerByReq.removeValue(forKey: reqId) {
            scanReqByOwner[owner] = nil
            scans[owner, default: ScanResult()].error = text
            return
        }
        if let id = chartByReq[reqId], let c = charts[id] {
            // The full history failed behind the bars on screen: back to the short one, so they stay live.
            if c.fullHistory, !c.bars.isEmpty {
                Self.log.notice("Full history refused for \(c.symbol, privacy: .public): \(code) \(text, privacy: .public)")
                c.fullHistory = false
                requestChart(id, keepingBars: true)
                return
            }
            c.isLoading = false
            c.error = text
            chartChanged(c)
            return
        }
        if let symbol = quoteSymbolByReq[reqId] {
            lastMessage = "\(symbol): \(text)"
            return
        }
        if whatIfOrderIds.contains(reqId) {
            log("WHATIF #\(reqId) [\(code)] \(text)")
            marginPreviews.removeValue(forKey: reqId)?(.failure(PreviewFailure(reason: text)))
            return
        }
        if var o = orders[reqId] {
            if code == 202 { o.status = "Cancelled" }
            else if code == 201 || code == 10148 || (100...199).contains(code) || o.status == "PendingSubmit" {
                o.status = "Rejected"
            }
            orders[reqId] = o
            lastMessage = "Order \(o.symbol) #\(reqId): \(text)"
            log("ERROR #\(reqId) [\(code)] \(text) → \(describe(o))")
            if o.status == "Rejected" { protectiveRejected(reqId, text) }
            if !o.isActive { closeIfCancelled(after: reqId, symbol: o.symbol) }
            return
        }
        lastMessage = "[\(code)] \(text)"
    }

    private func historicalData(_ f: [String]) {
        // reqId, startDate, endDate, numBars, then 8 fields per bar
        let reqId = f.int(1)
        let count = f.int(4)
        if let key = closeKeyByReq.removeValue(forKey: reqId) {
            let closeIndex = 5 + (count - 1) * 8 + 4
            if count > 0, closeIndex < f.count { sessionCloses[key] = f.double(closeIndex) }
            return
        }
        if let symbol = ssrSymbolByReq.removeValue(forKey: reqId) {
            // Daily bars' dates are "yyyyMMdd".
            let days = stride(from: 5, to: min(f.count - 7, 5 + count * 8), by: 8)
                .map { (day: String(f[$0].prefix(8)), low: f.double($0 + 3), close: f.double($0 + 4)) }
            ssrFromDailyBars(symbol, days)
            return
        }
        var bars: [Bar] = []
        bars.reserveCapacity(count)
        var i = 5
        for _ in 0..<count {
            guard i + 7 < f.count, let time = Self.parseBarTime(f[i]) else { break }
            bars.append(Bar(time: time, open: f.double(i + 1), high: f.double(i + 2), low: f.double(i + 3),
                            close: f.double(i + 4), volume: max(0, f.double(i + 5))))
            i += 8
        }
        if let id = overnightChartByReq[reqId], let c = charts[id] {
            overnightBars[id] = bars
            // History only: the request is done; the overnight session's start asks again, live.
            if overnightHistoryReqs.remove(reqId) != nil {
                overnightChartByReq[reqId] = nil
                overnightReqByChart[id] = nil
            }
            if !c.isLoading, !c.bars.isEmpty {
                c.bars = Self.merge(c.bars, bars)
                chartChanged(c, all: true)
            }
            return
        }
        guard let id = chartByReq[reqId], let c = charts[id] else { return }
        c.bars = Self.merge(bars, overnightBars[id] ?? [])
        c.isLoading = false
        c.error = c.bars.isEmpty ? "No data" : nil
        chartChanged(c, all: true)
    }

    /// Both series in time order; where both have a bar for the same time, `primary`'s wins.
    private static func merge(_ primary: [Bar], _ extra: [Bar]) -> [Bar] {
        guard !extra.isEmpty else { return primary }
        var byTime = Dictionary(extra.map { ($0.time, $0) }, uniquingKeysWith: { _, new in new })
        for bar in primary { byTime[bar.time] = bar }
        return byTime.values.sorted { $0.time < $1.time }
    }

    private func scannerData(_ f: [String]) {
        // version, reqId, count, then per row: rank, conId (v3+), symbol, secType, lastTradeDate, strike,
        // right, exchange, currency, localSymbol, marketName, tradingClass, distance, benchmark, projection, legs (v2+)
        guard let owner = scanOwnerByReq[f.int(2)] else { return }
        let version = f.int(1)
        let symbolOffset = version >= 3 ? 2 : 1
        let stride = 14 + (version >= 3 ? 1 : 0) + (version >= 2 ? 1 : 0)
        var symbols: [String] = []
        var i = 4
        for _ in 0..<max(0, f.int(3)) {
            guard i + stride <= f.count else { break }
            let symbol = f[i + symbolOffset]
            if !symbol.isEmpty, !symbols.contains(symbol) { symbols.append(symbol) }
            i += stride
        }
        scans[owner] = ScanResult(symbols: symbols, updated: Date())
        if scanSpecs[owner]?.kind == .afterHours { requestSessionCloses(symbols) }
    }

    /// IB's own update of the current bar, every few seconds. Where trades stream tick by tick,
    /// the candle already holds them: IB's open stands, its high/low/volume only widen the
    /// candle, and the latest trade stays the close.
    private func historicalDataUpdate(_ f: [String]) {
        // reqId, barCount, date, open, close, high, low, average, volume
        guard let id = chartByReq[f.int(1)] ?? overnightChartByReq[f.int(1)], let c = charts[id], !c.isLoading,
              let time = Self.parseBarTime(f.str(3)) else { return }
        var bar = Bar(time: time, open: f.double(4), high: f.double(6), low: f.double(7),
                      close: f.double(5), volume: max(0, f.double(9)))
        guard let lastIndex = c.bars.indices.last else {
            c.bars.append(bar)
            chartChanged(c, from: time)
            return
        }
        if c.bars[lastIndex].time < time {
            c.bars.append(bar)
        } else if let i = c.bars[max(0, lastIndex - 2)...].lastIndex(where: { $0.time == time }) {
            // IB's bar update can be older than the trades and prices already folded in; keep those.
            let current = c.bars[i]
            if isStreamingTrades(c.symbol) {
                bar.high = max(bar.high, current.high)
                bar.low = min(bar.low, current.low)
                bar.volume = max(bar.volume, current.volume)
                if i == lastIndex { bar.close = current.close }
            } else if i == lastIndex {
                bar.high = max(bar.high, current.high)
                bar.low = min(bar.low, current.low)
                if let last = quotes[c.symbol]?.last { bar.close = last }
            }
            c.bars[i] = bar
        } else {
            return
        }
        chartChanged(c, from: time)
    }

    private func position(_ f: [String]) {
        // version, account, conId, symbol, secType, ltd, strike, right, mult, exch, currency, localSym, tradingClass, pos, avgCost
        guard f.str(2) == account, f.str(5) == "STK" else { return }
        let symbol = f.str(4)
        let qty = f.double(14)
        let old = positions[symbol]?.quantity ?? 0
        if old != qty { log("POSITION \(symbol) \(Fmt.shares(old)) → \(Fmt.shares(qty)) avg \(Fmt.price(f.double(15)))") }
        if qty == 0 {
            positions[symbol] = nil
        } else {
            positions[symbol] = Position(symbol: symbol, quantity: qty, avgCost: f.double(15))
        }
        syncQuoteSubscriptions()
        syncProtective(symbol)
    }

    private func accountSummary(_ f: [String]) {
        guard f.str(3) == account else { return }
        let value = Double(f.str(5))
        switch f.str(4) {
        case "NetLiquidation": netLiquidation = value
        case "GrossPositionValue": grossPositionValue = value
        default: break
        }
    }

    private func pnl(_ f: [String]) {
        func clean(_ v: Double) -> Double? { abs(v) >= Self.unsetDouble / 2 ? nil : v }
        dailyPnL = clean(f.double(2))
        unrealizedPnL = clean(f.double(3))
        realizedPnL = clean(f.double(4))
    }

    // MARK: - Encoding helpers

    private func makeReqId() -> Int {
        nextReqId += 1
        return nextReqId
    }

    private func contract(_ symbol: String, exchange: String = "SMART") -> [Any] {
        // conId, symbol, secType, lastTradeDate, strike, right, multiplier, exchange, primaryExch, currency, localSymbol, tradingClass
        [0, symbol, "STK", "", 0.0, "", "", exchange, "", "USD", "", ""]
    }

    private func send(_ fields: Any...) { sendFields(fields) }

    private func sendFields(_ fields: [Any]) {
        socket.send(fields.map { Self.encode($0) })
    }

    private static func encode(_ value: Any) -> String {
        switch value {
        case let b as Bool: return b ? "1" : "0"
        case let i as Int: return i == Int.unset ? "" : String(i)
        case let d as Double:
            if d == unsetDouble || !d.isFinite { return "" }
            return d == d.rounded() && abs(d) < 1e15 ? String(Int(d)) : String(d)
        case let s as String: return s
        default: return "\(value)"
        }
    }

    // MARK: - Date parsing

    private static let eastern = TimeZone(identifier: "America/New_York")!

    private static let easternCalendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = eastern
        return cal
    }()

    private static func parseBarTime(_ s: String) -> Date? {
        if s.count == 8 {   // daily bars: yyyyMMdd
            return dayFormatter.date(from: s)
        }
        if let epoch = Double(s) { return Date(timeIntervalSince1970: epoch) }
        return parseExecTime(s)
    }

    /// "20261010 09:31:05 America/New_York" or "20261010-13:31:05" (UTC).
    private static func parseExecTime(_ s: String) -> Date? {
        let parts = s.split(separator: " ")
        if parts.count >= 2 {
            let f = DateFormatter()
            f.dateFormat = "yyyyMMdd HH:mm:ss"
            f.timeZone = parts.count >= 3 ? TimeZone(identifier: String(parts[2])) ?? eastern : eastern
            return f.date(from: "\(parts[0]) \(parts[1])")
        }
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HH:mm:ss"
        f.timeZone = TimeZone(identifier: "UTC")
        return f.date(from: s)
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd"
        f.timeZone = eastern
        return f
    }()
}

/// A chart as the engine keeps it: what it shows and its bars, plus what changed since the last
/// snapshot. A class so trades update the bars in place.
nonisolated private final class ChartState {
    let id: Int
    var symbol: String
    var timeframe: Timeframe
    /// The full history, with the overnight session, rather than the short one every load starts
    /// with (see `requestChart`).
    var fullHistory: Bool
    var generation = 0
    var bars: [Bar] = []
    var isLoading = false
    var error: String?
    /// The whole series goes in the next snapshot.
    var sendAll = false
    /// Bars from this time on go in the next snapshot.
    var changedFrom: Date?

    init(_ spec: ChartSpec) {
        id = spec.id
        symbol = spec.symbol
        timeframe = spec.timeframe
        fullHistory = spec.fullHistory
    }

    /// How far back its history goes.
    var duration: String { fullHistory ? timeframe.duration : timeframe.compactDuration }
}

/// What a chart shows, as the UI passes it to the engine.
nonisolated struct ChartSpec: Sendable {
    var id: Int
    var symbol: String
    var timeframe: Timeframe
    var fullHistory = false
}

/// What changed in the engine since the last snapshot; nil fields didn't change.
nonisolated struct EngineSnapshot: Sendable {
    struct Status: Equatable, Sendable {
        var state: TradingEngine.ConnectionState
        var statusText: String
        var lastMessage: String?
        var account: String
        var netLiquidation: Double?
        var grossPositionValue: Double?
        var dailyPnL: Double?
        var unrealizedPnL: Double?
        var realizedPnL: Double?
        var usdNok: Double?
        var usdNokIsLive: Bool
    }

    struct ChartPatch: Sendable {
        var id: Int
        var generation: Int
        /// The whole series, after a load or a merge.
        var bars: [Bar]?
        /// Bars added or changed since the last snapshot, oldest first.
        var tail: [Bar] = []
        var isLoading: Bool
        var error: String?
    }

    var status: Status?
    var positions: [String: Position]?
    var orders: [Int: OrderRow]?
    var fills: [String: Fill]?
    var quotes: [String: Quote]?
    var unavailableQuotes: [String: String]?
    var scans: [String: ScanResult]?
    var sessionCloses: [String: Double]?
    var chartOrderIds: Set<Int>?
    var protectiveOrders: [Int: TradingEngine.Protective]?
    var orderSources: [Int: String]?
    /// Symbols with a tick-by-tick trade stream open.
    var tickTradeSymbols: Set<String>?
    /// Fast charts' symbols IB's tick-by-tick limit left without a trade stream.
    var tickLimitedSymbols: Set<String>?
    /// IB's shortable tick per symbol (see `TradingEngine.shortability`).
    var shortability: [String: Double]?
    var shortableShares: [String: Double]?
    /// Short sale restriction worked out from IB's prices, with why (see `TradingEngine.ssr`).
    var ssr: [String: String]?
    var charts: [ChartPatch] = []
}

nonisolated private extension Int {
    static let unset = Int(Int32.max)
}

nonisolated private extension Array where Element == String {
    func str(_ i: Int) -> String { i < count ? self[i] : "" }
    func int(_ i: Int) -> Int { Int(str(i)) ?? Int(Double(str(i)) ?? 0) }
    func double(_ i: Int) -> Double { Double(str(i)) ?? 0 }
}
