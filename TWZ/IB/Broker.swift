//
//  Broker.swift
//  TWZ
//
//  Talks the TWS API socket protocol to IB Gateway: handshake, market data,
//  historical bars, market scanners, account/P&L, positions and orders.
//  Message layouts follow client protocol versions 157...178 (pre-protobuf).
//

import Foundation
import Observation

@Observable
final class Broker {
    enum ConnectionState { case disconnected, connecting, connected }

    // MARK: Connection settings (persisted)

    var host: String { didSet { defaults.set(host, forKey: "ib.host") } }
    var port: Int { didSet { defaults.set(port, forKey: "ib.port") } }
    var clientId: Int { didSet { defaults.set(clientId, forKey: "ib.clientId") } }

    var isLivePort: Bool { port == 4001 || port == 7496 }

    // MARK: Published state

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
    private(set) var quotes: [String: Quote] = [:]
    /// Symbols IB refused real-time data for this session, with IB's reason.
    private(set) var unavailableQuotes: [String: String] = [:]
    /// Latest scanner results per list panel.
    private(set) var scans: [String: ScanResult] = [:]
    /// Regular-session closes keyed "SYMBOL|yyyyMMdd", fetched for after-hours scanner rows.
    private(set) var sessionCloses: [String: Double] = [:]
    /// NOK per USD (IDEALPRO mid), used to size alt-click chart buys. Starts at the last saved
    /// rate; `usdNokIsLive` turns true once this connection has a quote.
    private(set) var usdNok: Double?
    private(set) var usdNokIsLive = false
    /// Orders placed by alt-clicking a chart; drawn as solid lines in the ⌥-click color (Settings).
    private(set) var chartOrderIds: Set<Int>
    /// Stop loss / take profit orders placed by ⌃-clicking a chart, by order id.
    private(set) var protectiveOrders: [Int: Protective]

    /// Live market value of all positions in USD (falls back to cost when no quote yet).
    var totalPositionValue: Double? {
        guard state == .connected else { return nil }
        if positions.isEmpty { return 0 }
        return positions.values.reduce(0) { sum, p in
            sum + abs(p.quantity) * (quotes[p.symbol]?.last ?? p.avgCost)
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
    @ObservationIgnored private let socket = IBSocket()
    @ObservationIgnored private var serverVersion = 0
    @ObservationIgnored private var nextOrderId: Int?
    @ObservationIgnored private var nextReqId = 900_000_000   // far above order ids so error routing is unambiguous
    @ObservationIgnored private var apiReady = false
    @ObservationIgnored private var session = 0                 // bumped on every reset; stale timers check it
    @ObservationIgnored private var hasLiveQuote = false        // any quote ticked this session
    @ObservationIgnored private var noDataCheckScheduled = false

    @ObservationIgnored private var quoteOwners: [String: Set<String>] = [:]
    @ObservationIgnored private var quoteReqBySymbol: [String: Int] = [:]
    @ObservationIgnored private var quoteSymbolByReq: [Int: String] = [:]
    /// Quotes from SMART and, during the overnight session, from IBKR's OVERNIGHT venue;
    /// `quotes` combines them.
    @ObservationIgnored private var smartQuotes: [String: Quote] = [:]
    @ObservationIgnored private var overnightQuotes: [String: Quote] = [:]
    @ObservationIgnored private var overnightReqBySymbol: [String: Int] = [:]
    @ObservationIgnored private var overnightSymbolByReq: [Int: String] = [:]
    @ObservationIgnored private var phase = MarketSession.phase()

    @ObservationIgnored private var scanSpecs: [String: ScanSpec] = [:]
    @ObservationIgnored private var scanReqByOwner: [String: Int] = [:]
    @ObservationIgnored private var scanOwnerByReq: [Int: String] = [:]
    @ObservationIgnored private var closeKeyByReq: [Int: String] = [:]
    @ObservationIgnored private var closesRequested: Set<String> = []

    @ObservationIgnored private var charts: [ChartModel] = []
    @ObservationIgnored private var chartByReq: [Int: ChartModel] = [:]
    @ObservationIgnored private var reqByChart: [Int: Int] = [:]
    @ObservationIgnored private var pendingBars: [Int: [Bar]] = [:]
    /// Intraday charts also load the overnight session (20:00–03:50 ET) from the OVERNIGHT venue,
    /// since SMART's extended-hours bars stop at 20:00. Bars are kept per chart id.
    @ObservationIgnored private var overnightChartByReq: [Int: ChartModel] = [:]
    @ObservationIgnored private var overnightReqByChart: [Int: Int] = [:]
    @ObservationIgnored private var overnightBars: [Int: [Bar]] = [:]

    /// Stop losses to place again once the take profit blocking them is cancelled, by its order id.
    /// Orders already asked to cancel, so ⌥Z pressed again moves on to the next one.
    @ObservationIgnored private var cancelsSent: Set<Int> = []
    @ObservationIgnored private var stopsAwaitingCancel: [Int: (symbol: String, price: Double)] = [:]
    @ObservationIgnored private var fxReq: Int?
    @ObservationIgnored private var fxBid: Double?
    @ObservationIgnored private var fxAsk: Double?

    @ObservationIgnored private let accountSummaryReq = 1
    @ObservationIgnored private let pnlReq = 2
    @ObservationIgnored private let executionsReq = 3

    /// "Requested market data is not subscribed" and variants (354, 10089, 10091, 10168).
    private static let noMarketDataCodes: Set<Int> = [354, 10089, 10091, 10168]

    private static let minClientVersion = 157
    private static let maxClientVersion = 178
    nonisolated private static let unsetDouble = Double.greatestFiniteMagnitude

    init() {
        host = defaults.string(forKey: "ib.host") ?? "127.0.0.1"
        port = defaults.object(forKey: "ib.port") as? Int ?? 4002          // paper gateway by default
        clientId = defaults.object(forKey: "ib.clientId") as? Int ?? 1
        usdNok = defaults.object(forKey: "fx.usdNok") as? Double
        chartOrderIds = Set(defaults.array(forKey: "chartOrderIds") as? [Int] ?? [])
        protectiveOrders = defaults.data(forKey: "protectiveOrders")
            .flatMap { try? JSONDecoder().decode([Int: Protective].self, from: $0) } ?? [:]
        socket.onEvent = { [weak self] event in self?.handle(event) }
    }

    // MARK: - Connection

    func connect() {
        guard state == .disconnected else { return }
        resetSession()
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
        serverVersion = 0
        nextOrderId = nil
        apiReady = false
        account = ""
        session += 1
        hasLiveQuote = false
        noDataCheckScheduled = false
        unavailableQuotes.removeAll()
        quoteReqBySymbol.removeAll()
        quoteSymbolByReq.removeAll()
        overnightReqBySymbol.removeAll()
        overnightSymbolByReq.removeAll()
        overnightQuotes.removeAll()
        chartByReq.removeAll()
        reqByChart.removeAll()
        pendingBars.removeAll()
        overnightChartByReq.removeAll()
        overnightReqByChart.removeAll()
        overnightBars.removeAll()
        stopsAwaitingCancel.removeAll()
        cancelsSent.removeAll()
        scanReqByOwner.removeAll()
        scanOwnerByReq.removeAll()
        closeKeyByReq.removeAll()
        closesRequested.removeAll()
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
        statusText = "Connected · \(account)"
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
        for chart in charts { loadChart(chart) }
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

    /// Checks the session every 30 s and moves quotes onto or off the OVERNIGHT venue when it changes.
    private func watchSessionPhase() {
        let current = session
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, self.session == current, self.apiReady else { return }
            let now = MarketSession.phase()
            if now != self.phase {
                self.phase = now
                self.syncQuoteSubscriptions()
                for symbol in Set(self.smartQuotes.keys).union(self.overnightQuotes.keys) {
                    self.updateQuote(symbol)
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
        if quotes[symbol] != q { quotes[symbol] = q }
    }

    private func scheduleNoDataCheck() {
        guard !noDataCheckScheduled else { return }
        noDataCheckScheduled = true
        let current = session
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
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
        sendFields([1, 11, reqId] + contract(symbol) + [false, "", false, false, ""])   // reqMktData
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
        usdNok = rate
        usdNokIsLive = true
        defaults.set(rate, forKey: "fx.usdNok")
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

    /// Regular-session close to measure after-hours moves against (today's 16:00 close).
    func sessionClose(_ symbol: String) -> Double? {
        sessionCloses["\(symbol)|\(MarketSession.dayKey())"]
    }

    private func startScan(_ owner: String) {
        guard apiReady, let spec = scanSpecs[owner] else { return }
        let reqId = makeReqId()
        scanReqByOwner[owner] = reqId
        scanOwnerByReq[reqId] = owner
        let f = spec.filter
        // reqScannerSubscription (server ≥ 143: no version field)
        sendFields([
            22, reqId, ScannerKind.rowCount, "STK", "STK.US.MAJOR", spec.kind.scanCode,
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

    func registerCharts(_ charts: [ChartModel]) {
        self.charts = charts
    }

    func loadChart(_ chart: ChartModel) {
        if let old = reqByChart[chart.id] {
            if apiReady { send(25, 1, old) }                                      // cancelHistoricalData
            chartByReq[old] = nil
            pendingBars[old] = nil
            reqByChart[chart.id] = nil
        }
        if let old = overnightReqByChart.removeValue(forKey: chart.id) {
            if apiReady { send(25, 1, old) }                                      // cancelHistoricalData
            overnightChartByReq[old] = nil
        }
        overnightBars[chart.id] = nil
        chart.bars = []
        chart.error = nil
        chart.scrollBack = 0
        chart.priceShift = 0
        guard apiReady, !chart.symbol.isEmpty else {
            chart.isLoading = false
            return
        }
        chart.isLoading = true
        let reqId = makeReqId()
        chartByReq[reqId] = chart
        reqByChart[chart.id] = reqId
        pendingBars[reqId] = []
        let tf = chart.timeframe
        // reqHistoricalData: endDateTime "" + keepUpToDate streams live bar updates.
        sendFields([20, reqId] + contract(chart.symbol) + [
            false, "", tf.barSize, tf.duration, tf.isIntraday ? 0 : 1, "TRADES", 2, true, "",
        ])
        guard tf.isIntraday else { return }
        let overnightReq = makeReqId()
        overnightChartByReq[overnightReq] = chart
        overnightReqByChart[chart.id] = overnightReq
        sendFields([20, overnightReq] + contract(chart.symbol, exchange: "OVERNIGHT") + [
            false, "", tf.barSize, tf.duration, 0, "TRADES", 2, true, "",
        ])
    }

    // MARK: - Orders

    @discardableResult
    /// Places a stock order and returns its id; `limit == nil` sends a market order. With a `stop`
    /// it's a stop-limit (STP LMT) that triggers when the last trade reaches the stop.
    /// Orders sharing an `ocaGroup` cancel each other: when one fills, the rest shrink by as much.
    /// Passing `modifying` an existing order id changes that order instead of placing a new one.
    func placeOrder(symbol: String, action: String, quantity: Double, limit: Double?, stop: Double? = nil,
                    tif: TimeInForce = .day, outsideRth: Bool = true, exchange: String = "SMART",
                    ocaGroup: String = "", modifying: Int? = nil) -> Int? {
        guard apiReady, let next = nextOrderId else {
            lastMessage = "Not connected"
            return nil
        }
        guard quantity > 0 else {
            lastMessage = "Order quantity must be > 0"
            return nil
        }
        let orderId = modifying ?? next
        if modifying == nil { nextOrderId = next + 1 }

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
        f += ["", false, "", false, false, false]                         // algoId, whatIf, misc, solicited, randomize
        f += [0]                                                          // conditions
        f += ["", Self.unsetDouble, Self.unsetDouble, Self.unsetDouble, Self.unsetDouble, Self.unsetDouble, 0, ""]
        f += ["", "", Self.unsetDouble, "", "", "", "", false, false, false, Int.unset]
        if serverVersion >= 158 { f += [Int.unset] }                      // duration
        if serverVersion >= 160 { f += [Int.unset] }                      // postToAts
        if serverVersion >= 162 { f += [false] }                          // autoCancelParent
        if serverVersion >= 166 { f += [""] }                             // advancedErrorOverride
        if serverVersion >= 169 { f += [""] }                             // manualOrderTime
        sendFields(f)

        var row = OrderRow(
            id: orderId, symbol: symbol, action: action, quantity: quantity,
            orderType: orderType, limitPrice: limit, auxPrice: stop, status: "PendingSubmit"
        )
        if modifying != nil, let old = orders[orderId] {
            row.status = old.status
            row.filled = old.filled
        }
        orders[orderId] = row
        return orderId
    }

    func cancelOrder(_ orderId: Int) {
        guard apiReady else { return }
        if serverVersion >= 169 { send(4, 1, orderId, "") } else { send(4, 1, orderId) }
        cancelsSent.insert(orderId)
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
        cancelOrder(o.id)
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
        for o in working { cancelOrder(o.id) }
        lastMessage = working.isEmpty
            ? "No working orders in \(symbol)"
            : "Cancelling \(working.count) order\(working.count == 1 ? "" : "s") in \(symbol)"
    }

    func cancelAllOrders() {
        guard apiReady else { return }
        send(58, 1)                                                       // reqGlobalCancel
    }

    // MARK: - Hotkeys

    func run(_ hotkey: Hotkey, symbol rawSymbol: String) {
        let symbol = rawSymbol.uppercased()
        guard apiReady else {
            lastMessage = "Not connected to IB Gateway"
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
            guard let price = orderPrice(symbol: symbol, action: action, hotkey: hotkey) else { return }
            let quantity: Double
            switch hotkey.sizing {
            case .shares:
                quantity = hotkey.amount.rounded(.down)
            case .dollars:
                // Market orders size off the side of the spread they'll likely fill at.
                guard let ref = price.limit ?? quote(symbol, .cross, isBuy: action == "BUY")?.price else {
                    lastMessage = "No price for \(symbol) yet"
                    return
                }
                quantity = (hotkey.amount / ref).rounded(.down)
            }
            guard quantity >= 1 else {
                lastMessage = "Size too small for \(symbol)"
                return
            }
            submit(symbol: symbol, action: action, quantity: quantity, price: price, tif: hotkey.tif)
        }
    }

    private func close(_ p: Position, fraction: Double, hotkey: Hotkey) {
        let action = p.quantity > 0 ? "SELL" : "BUY"
        var quantity = (abs(p.quantity) * fraction).rounded(.down)
        if quantity < 1 { quantity = abs(p.quantity) }
        guard let price = orderPrice(symbol: p.symbol, action: action, hotkey: hotkey) else { return }
        submit(symbol: p.symbol, action: action, quantity: quantity, price: price, tif: hotkey.tif)
    }

    // MARK: - Chart orders

    /// Shares a NOK amount buys at `price`, converted at the current USD.NOK rate.
    func shares(forNOK nok: Double, at price: Double) -> Double? {
        guard let usdNok, usdNok > 0, price > 0 else { return nil }
        return (nok / usdNok / price).rounded(.down)
    }

    /// What an alt-click buy places, decided from the live last trade only (no fallback prices).
    enum ChartBuy {
        /// At or below the last trade: a limit at the clicked price.
        case limit(Double)
        /// Above it: a stop-limit that triggers when the last trade reaches the clicked price and
        /// buys at that price or better.
        case stopLimit(Double)
        /// Can't place one; the reason.
        case unavailable(String)

        var price: Double? {
            switch self {
            case .limit(let p), .stopLimit(let p): p
            case .unavailable: nil
            }
        }

        /// "BUY 45 @ 10.00" or "BUY STP 45 @ 10.00".
        func label(shares: Double) -> String? {
            switch self {
            case .limit(let p): "BUY \(Fmt.shares(shares)) @ \(Fmt.price(p))"
            case .stopLimit(let p): "BUY STP \(Fmt.shares(shares)) @ \(Fmt.price(p))"
            case .unavailable: nil
            }
        }
    }

    func chartBuy(symbol rawSymbol: String, clicked: Double) -> ChartBuy {
        let symbol = rawSymbol.uppercased()
        let price = Self.roundToTick(clicked)
        guard let last = quotes[symbol]?.last, last > 0 else {
            return .unavailable("No live price for \(symbol) yet")
        }
        guard price > last else { return .limit(price) }
        // IBKR's overnight venue takes plain limit orders only.
        if MarketSession.phase() == .overnight { return .unavailable("No stop orders overnight") }
        return .stopLimit(price)
    }

    /// Alt-click on a chart: a DAY buy for `nok` worth of `symbol` at the clicked price; a limit
    /// below the last trade, a stop-limit above it.
    func buyNOK(_ nok: Double, symbol rawSymbol: String, at clickedPrice: Double) {
        let symbol = rawSymbol.uppercased()
        guard apiReady else {
            lastMessage = "Not connected to IB Gateway"
            return
        }
        guard !symbol.isEmpty else {
            lastMessage = "Load a symbol into the chart first"
            return
        }
        let plan = chartBuy(symbol: symbol, clicked: clickedPrice)
        if case .unavailable(let reason) = plan {
            lastMessage = "\(reason), so the order wasn't sent"
            return
        }
        guard let limit = plan.price, let quantity = shares(forNOK: nok, at: limit) else {
            lastMessage = "No USD.NOK rate yet, so the order can't be sized"
            return
        }
        guard quantity >= 1, let label = plan.label(shares: quantity) else {
            lastMessage = "\(OrderAmount.format(nok)) NOK is less than one share of \(symbol) at \(Fmt.price(limit))"
            return
        }
        var price = HotkeyPrice(limit: limit, outsideRth: true)
        if case .stopLimit(let stop) = plan { price.stop = stop }
        if MarketSession.phase() == .overnight { price.exchange = "OVERNIGHT" }
        let summary = "\(label) (\(OrderAmount.format(nok)) NOK)"
        guard let id = submit(symbol: symbol, action: "BUY", quantity: quantity, price: price, tif: .day,
                              summary: summary) else { return }
        chartOrderIds.insert(id)
        defaults.set(Array(chartOrderIds.sorted().suffix(500)), forKey: "chartOrderIds")
    }

    // MARK: - Stop loss / take profit

    /// A ⌃-click order that closes the position, and the OCA group pairing it with its counterpart.
    struct Protective: Codable, Equatable {
        enum Kind: String, Codable { case stopLoss, takeProfit }
        var symbol: String
        var kind: Kind
        var ocaGroup: String
    }

    /// What a ⌃-click at `price` places: a stop loss on the losing side of the position's average
    /// cost, a take profit on the winning side. nil without a position.
    func protectiveKind(symbol rawSymbol: String, at price: Double) -> Protective.Kind? {
        let symbol = rawSymbol.uppercased()
        guard let p = positions[symbol], p.quantity != 0 else { return nil }
        return (p.quantity > 0) == (price < p.avgCost) ? .stopLoss : .takeProfit
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
        guard let kind = protectiveKind(symbol: symbol, at: clickedPrice) else { return }
        let price = Self.roundToTick(clickedPrice)
        if protectiveFillsNow(symbol: symbol, kind: kind, at: price), let last = quotes[symbol]?.last {
            lastMessage = "\(symbol): a \(kind == .stopLoss ? "stop loss" : "take profit") at \(Fmt.price(price)) "
                + "would fill right away (last \(Fmt.price(last))), so it wasn't sent"
            return
        }
        placeProtective(kind, symbol: symbol, price: price)
    }

    /// True between the average cost and the last trade, where the order would fill as soon as it's placed.
    func protectiveFillsNow(symbol rawSymbol: String, kind: Protective.Kind, at price: Double) -> Bool {
        let symbol = rawSymbol.uppercased()
        guard let qty = positions[symbol]?.quantity, qty != 0,
              let last = quotes[symbol]?.last, last > 0 else { return false }
        let belowLast = price <= last, aboveLast = price >= last
        return kind == .stopLoss ? (qty > 0 ? aboveLast : belowLast) : (qty > 0 ? belowLast : aboveLast)
    }

    /// Stop loss: a stop-limit with the limit 1% (at least 2¢) past the stop, so it can fill
    /// outside regular hours too. Take profit: a limit.
    private func placeProtective(_ kind: Protective.Kind, symbol: String, price: Double) {
        guard let qty = positions[symbol]?.quantity, qty != 0 else { return }
        let action = qty > 0 ? "SELL" : "BUY"
        let active = activeProtective(symbol)
        let existing = active.first { $0.value.kind == kind }?.key
        let group = active.first?.value.ocaGroup ?? "TWZ-\(symbol)-\(Int(Date().timeIntervalSince1970))"
        let (limit, stop) = Self.protectivePrices(kind, action: action, price: price)
        guard let id = placeOrder(symbol: symbol, action: action, quantity: abs(qty), limit: limit, stop: stop,
                                  tif: .gtc, outsideRth: true, ocaGroup: group, modifying: existing) else { return }
        protectiveOrders[id] = Protective(symbol: symbol, kind: kind, ocaGroup: group)
        saveProtective()
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

    private func activeProtective(_ symbol: String) -> [Int: Protective] {
        protectiveOrders.filter { $0.value.symbol == symbol && (orders[$0.key]?.isActive ?? false) }
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
        for (id, p) in activeProtective(symbol) {
            guard let o = orders[id] else { continue }
            guard (o.action == "SELL" && qty > 0) || (o.action == "BUY" && qty < 0) else {
                cancelOrder(id)
                continue
            }
            guard o.filled == 0, o.quantity != abs(qty),
                  let price = p.kind == .stopLoss ? o.auxPrice : o.limitPrice else { continue }
            let (limit, stop) = Self.protectivePrices(p.kind, action: o.action, price: price)
            placeOrder(symbol: symbol, action: o.action, quantity: abs(qty), limit: limit, stop: stop,
                       tif: .gtc, outsideRth: true, ocaGroup: p.ocaGroup, modifying: id)
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
            cancelOrder(tp)
            lastMessage = "\(p.symbol): stop loss rejected (\(text)); cancelling the take profit to place it"
        case .takeProfit:
            if activeProtective(p.symbol).contains(where: { $0.value.kind == .stopLoss }) {
                lastMessage = "\(p.symbol): take profit rejected (\(text)); the stop loss stays"
            }
        }
    }

    /// Places the order and says in the status line when it was priced off a fallback or
    /// won't work until a later session, after `summary` when one is given.
    @discardableResult
    private func submit(symbol: String, action: String, quantity: Double, price: HotkeyPrice,
                        tif: TimeInForce, summary: String? = nil) -> Int? {
        let overnight = price.exchange == "OVERNIGHT"
        guard let id = placeOrder(symbol: symbol, action: action, quantity: quantity, limit: price.limit,
                                  stop: price.stop, tif: overnight ? .day : tif, outsideRth: price.outsideRth,
                                  exchange: price.exchange) else { return nil }
        var notes = summary.map { [$0] } ?? []
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
        if let bar = valid(charts.first(where: { $0.symbol == symbol })?.bars.last?.close) {
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
            checkReady()
        case 11: execDetails(f)
        case 15:
            account = f.str(2).split(separator: ",").first.map(String.init) ?? ""
            checkReady()
        case 17: historicalData(f)
        case 20: scannerData(f)
        case 61: position(f)
        case 63: accountSummary(f)
        case 90: historicalDataUpdate(f)
        case 94: pnl(f)
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
        updateQuote(symbol)
    }

    /// Volume stays SMART's full-day figure; the overnight venue's own volume isn't shown.
    private func tickSize(_ f: [String]) {
        guard let symbol = quoteSymbolByReq[f.int(2)] else { return }
        hasLiveQuote = true
        switch f.int(3) {
        case 8, 74:
            smartQuotes[symbol, default: Quote()].volume = f.double(4)
            updateQuote(symbol)
        default: break
        }
    }

    private func orderStatus(_ f: [String]) {
        // orderId, status, filled, remaining, avgFillPrice, permId, parentId, lastFillPrice, clientId, whyHeld, mktCapPrice
        let id = Self.orderKey(orderId: f.int(1), permId: f.int(6))
        guard var o = orders[id] else { return }
        o.status = f.str(2)
        o.filled = f.double(3)
        o.avgFillPrice = f.double(5)
        o.updated = Date()
        orders[id] = o
        if !o.isActive, let stop = stopsAwaitingCancel.removeValue(forKey: id) {
            placeProtective(.stopLoss, symbol: stop.symbol, price: stop.price)
        }
    }

    private func openOrder(_ f: [String]) {
        guard f.count > 25 else { return }
        let id = Self.orderKey(orderId: f.int(1), permId: f.int(25))
        let lmt = f.double(16)
        let aux = f.double(17)
        var o = orders[id] ?? OrderRow(
            id: id, symbol: f.str(3), action: f.str(13), quantity: 0,
            orderType: f.str(15), limitPrice: nil, status: "Submitted"
        )
        o.symbol = f.str(3)
        o.action = f.str(13)
        o.quantity = f.double(14)
        o.orderType = f.str(15)
        o.limitPrice = (lmt > 0 && lmt < Self.unsetDouble) ? lmt : nil
        o.auxPrice = (aux > 0 && aux < Self.unsetDouble) ? aux : nil
        orders[id] = o
    }

    /// Orders entered manually in TWS have orderId 0; key those by negative permId.
    private static func orderKey(orderId: Int, permId: Int) -> Int {
        orderId != 0 ? orderId : -permId
    }

    private func execDetails(_ f: [String]) {
        guard f.count > 20 else { return }
        let fill = Fill(
            id: f.str(14),
            orderId: f.int(2),
            symbol: f.str(4),
            side: f.str(18),
            shares: f.double(19),
            price: f.double(20),
            time: Self.parseExecTime(f.str(15)) ?? Date()
        )
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

        // The overnight venue is extra: a symbol it can't serve just keeps its SMART data.
        if overnightSymbolByReq[reqId] != nil { return }
        if let chart = overnightChartByReq.removeValue(forKey: reqId) {
            overnightReqByChart[chart.id] = nil
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
        if let owner = scanOwnerByReq.removeValue(forKey: reqId) {
            scanReqByOwner[owner] = nil
            scans[owner, default: ScanResult()].error = text
            return
        }
        if let chart = chartByReq[reqId] {
            chart.isLoading = false
            chart.error = text
            return
        }
        if let symbol = quoteSymbolByReq[reqId] {
            lastMessage = "\(symbol): \(text)"
            return
        }
        if var o = orders[reqId] {
            if code == 202 { o.status = "Cancelled" }
            else if code == 201 || code == 10148 || (100...199).contains(code) || o.status == "PendingSubmit" {
                o.status = "Rejected"
            }
            orders[reqId] = o
            lastMessage = "Order \(o.symbol) #\(reqId): \(text)"
            if o.status == "Rejected" { protectiveRejected(reqId, text) }
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
        var bars: [Bar] = []
        bars.reserveCapacity(count)
        var i = 5
        for _ in 0..<count {
            guard i + 7 < f.count, let time = Self.parseBarTime(f[i]) else { break }
            bars.append(Bar(time: time, open: f.double(i + 1), high: f.double(i + 2), low: f.double(i + 3),
                            close: f.double(i + 4), volume: max(0, f.double(i + 5))))
            i += 8
        }
        if let chart = overnightChartByReq[reqId] {
            overnightBars[chart.id] = bars
            if !chart.isLoading, !chart.bars.isEmpty { chart.bars = Self.merge(chart.bars, bars) }
            return
        }
        guard let chart = chartByReq[reqId] else { return }
        pendingBars[reqId] = nil
        chart.bars = Self.merge(bars, overnightBars[chart.id] ?? [])
        chart.isLoading = false
        chart.error = chart.bars.isEmpty ? "No data" : nil
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

    private func historicalDataUpdate(_ f: [String]) {
        // reqId, barCount, date, open, close, high, low, average, volume
        guard let chart = chartByReq[f.int(1)] ?? overnightChartByReq[f.int(1)], !chart.isLoading,
              let time = Self.parseBarTime(f.str(3)) else { return }
        let bar = Bar(time: time, open: f.double(4), high: f.double(6), low: f.double(7),
                      close: f.double(5), volume: max(0, f.double(9)))
        if let last = chart.bars.last, last.time == time {
            chart.bars[chart.bars.count - 1] = bar
        } else if chart.bars.last.map({ $0.time < time }) ?? true {
            chart.bars.append(bar)
        }
    }

    private func position(_ f: [String]) {
        // version, account, conId, symbol, secType, ltd, strike, right, mult, exch, currency, localSym, tradingClass, pos, avgCost
        guard f.str(2) == account, f.str(5) == "STK" else { return }
        let symbol = f.str(4)
        let qty = f.double(14)
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

    nonisolated private static func encode(_ value: Any) -> String {
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

private extension Int {
    nonisolated static let unset = Int(Int32.max)
}

private extension Array where Element == String {
    func str(_ i: Int) -> String { i < count ? self[i] : "" }
    func int(_ i: Int) -> Int { Int(str(i)) ?? Int(Double(str(i)) ?? 0) }
    func double(_ i: Int) -> Double { Double(str(i)) ?? 0 }
}
