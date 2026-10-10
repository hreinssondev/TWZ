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

    enum OrderPrice {
        case market
        case limit(Double)
    }

    // MARK: Connection settings (persisted)

    var host: String { didSet { defaults.set(host, forKey: "ib.host") } }
    var port: Int { didSet { defaults.set(port, forKey: "ib.port") } }
    var clientId: Int { didSet { defaults.set(clientId, forKey: "ib.clientId") } }
    var allowDelayedData: Bool { didSet { defaults.set(allowDelayedData, forKey: "ib.delayed") } }

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
    /// Latest scanner results per list panel.
    private(set) var scans: [String: ScanResult] = [:]
    /// Regular-session closes keyed "SYMBOL|yyyyMMdd", fetched for after-hours scanner rows.
    private(set) var sessionCloses: [String: Double] = [:]

    /// Live market value of all positions (falls back to cost when no quote yet).
    var totalPositionValue: Double? {
        guard state == .connected else { return nil }
        if positions.isEmpty { return 0 }
        return positions.values.reduce(0) { sum, p in
            sum + abs(p.quantity) * (quotes[p.symbol]?.last ?? p.avgCost)
        }
    }

    // MARK: Private

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private let socket = IBSocket()
    @ObservationIgnored private var serverVersion = 0
    @ObservationIgnored private var nextOrderId: Int?
    @ObservationIgnored private var nextReqId = 900_000_000   // far above order ids so error routing is unambiguous
    @ObservationIgnored private var apiReady = false

    @ObservationIgnored private var quoteOwners: [String: Set<String>] = [:]
    @ObservationIgnored private var quoteReqBySymbol: [String: Int] = [:]
    @ObservationIgnored private var quoteSymbolByReq: [Int: String] = [:]

    @ObservationIgnored private var scanSpecs: [String: ScanSpec] = [:]
    @ObservationIgnored private var scanReqByOwner: [String: Int] = [:]
    @ObservationIgnored private var scanOwnerByReq: [Int: String] = [:]
    @ObservationIgnored private var closeKeyByReq: [Int: String] = [:]
    @ObservationIgnored private var closesRequested: Set<String> = []

    @ObservationIgnored private var charts: [ChartModel] = []
    @ObservationIgnored private var chartByReq: [Int: ChartModel] = [:]
    @ObservationIgnored private var reqByChart: [Int: Int] = [:]
    @ObservationIgnored private var pendingBars: [Int: [Bar]] = [:]

    @ObservationIgnored private let accountSummaryReq = 1
    @ObservationIgnored private let pnlReq = 2
    @ObservationIgnored private let executionsReq = 3

    private static let minClientVersion = 157
    private static let maxClientVersion = 178
    nonisolated private static let unsetDouble = Double.greatestFiniteMagnitude

    init() {
        host = defaults.string(forKey: "ib.host") ?? "127.0.0.1"
        port = defaults.object(forKey: "ib.port") as? Int ?? 4002          // paper gateway by default
        clientId = defaults.object(forKey: "ib.clientId") as? Int ?? 1
        allowDelayedData = defaults.object(forKey: "ib.delayed") as? Bool ?? true
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
        quoteReqBySymbol.removeAll()
        quoteSymbolByReq.removeAll()
        chartByReq.removeAll()
        reqByChart.removeAll()
        pendingBars.removeAll()
        scanReqByOwner.removeAll()
        scanOwnerByReq.removeAll()
        closeKeyByReq.removeAll()
        closesRequested.removeAll()
        scans.removeAll()
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

        send(59, 1, allowDelayedData ? 3 : 1)                                      // reqMarketDataType
        send(61, 1)                                                                // reqPositions
        send(62, 1, accountSummaryReq, "All", "NetLiquidation,GrossPositionValue")  // reqAccountSummary
        send(92, pnlReq, account, "")                                              // reqPnL
        send(16, 1)                                                                // reqAllOpenOrders
        send(7, 3, executionsReq, 0, "", "", "", "", "", "")                       // reqExecutions (today)

        for symbol in quoteOwners.values.reduce(into: Set<String>(), { $0.formUnion($1) }) {
            subscribeQuote(symbol)
        }
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
    }

    private func subscribeQuote(_ symbol: String) {
        guard apiReady, quoteReqBySymbol[symbol] == nil else { return }
        let reqId = makeReqId()
        quoteReqBySymbol[symbol] = reqId
        quoteSymbolByReq[reqId] = symbol
        sendFields([1, 11, reqId] + contract(symbol) + [false, "", false, false, ""])   // reqMktData
    }

    // MARK: - Scanners

    /// Each list panel declares the scanner it shows (nil for a watchlist).
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
        chart.bars = []
        chart.error = nil
        chart.scrollBack = 0
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
    }

    // MARK: - Orders

    @discardableResult
    func placeOrder(symbol: String, action: String, quantity: Double, price: OrderPrice) -> Bool {
        guard apiReady, let orderId = nextOrderId else {
            lastMessage = "Not connected"
            return false
        }
        guard quantity > 0 else {
            lastMessage = "Order quantity must be > 0"
            return false
        }
        nextOrderId = orderId + 1

        var orderType = "MKT"
        var limit: Double?
        var outsideRth = false
        switch price {
        case .market:
            break
        case .limit(let p):
            orderType = "LMT"
            limit = p
            outsideRth = true   // lets limit orders work pre-market and after hours
        }

        var f: [Any] = [3, orderId]
        f += contract(symbol)
        f += ["", ""]                                                     // secIdType, secId
        f += [action, quantity, orderType, limit ?? Self.unsetDouble, Self.unsetDouble, "DAY", "", account, "", 0, "TWZ"]
        f += [true, 0, false, false, 0, 0, outsideRth, false]             // transmit … hidden
        f += ["", 0.0, "", "", "", "", ""]                                // sharesAlloc, discretionary, GAT, GTD, FA
        if serverVersion < 177 { f += [""] }                              // faProfile
        f += ["", 0, "", -1, 0, "", "", false, Int.unset, Self.unsetDouble, false, false, Self.unsetDouble]
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

        orders[orderId] = OrderRow(
            id: orderId, symbol: symbol, action: action, quantity: quantity,
            orderType: orderType, limitPrice: limit, status: "PendingSubmit"
        )
        return true
    }

    func cancelOrder(_ orderId: Int) {
        guard apiReady else { return }
        if serverVersion >= 169 { send(4, 1, orderId, "") } else { send(4, 1, orderId) }
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
            for o in orders.values where o.isActive && o.symbol == symbol { cancelOrder(o.id) }
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
                guard let ref = referencePrice(symbol: symbol, action: action), ref > 0 else {
                    lastMessage = "No price for \(symbol) yet"
                    return
                }
                quantity = (hotkey.amount / ref).rounded(.down)
            }
            guard quantity >= 1 else {
                lastMessage = "Size too small for \(symbol)"
                return
            }
            placeOrder(symbol: symbol, action: action, quantity: quantity, price: price)
        }
    }

    private func close(_ p: Position, fraction: Double, hotkey: Hotkey) {
        let action = p.quantity > 0 ? "SELL" : "BUY"
        var quantity = (abs(p.quantity) * fraction).rounded(.down)
        if quantity < 1 { quantity = abs(p.quantity) }
        guard let price = orderPrice(symbol: p.symbol, action: action, hotkey: hotkey) else { return }
        placeOrder(symbol: p.symbol, action: action, quantity: quantity, price: price)
    }

    /// Buys reference the ask, sells the bid; falls back to last.
    private func referencePrice(symbol: String, action: String) -> Double? {
        let q = quotes[symbol]
        return (action == "BUY" ? q?.ask : q?.bid) ?? q?.last
    }

    private func orderPrice(symbol: String, action: String, hotkey: Hotkey) -> OrderPrice? {
        // Market orders don't execute outside regular hours, so convert them to marketable limits.
        if hotkey.priceType == .market && MarketSession.isRegularHours() { return .market }
        guard let ref = referencePrice(symbol: symbol, action: action), ref > 0 else {
            lastMessage = "No bid/ask for \(symbol) yet — can't price a limit order"
            return nil
        }
        var offset = hotkey.offset
        if hotkey.priceType == .market { offset = max(offset, ref * 0.005) }
        let raw = action == "BUY" ? ref + offset : ref - offset
        return .limit(Self.roundToTick(max(raw, 0.0001)))
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
        guard let symbol = quoteSymbolByReq[f.int(2)] else { return }
        let price = f.double(4)
        var q = quotes[symbol] ?? Quote()
        switch f.int(3) {
        case 1, 66: q.bid = price > 0 ? price : nil
        case 2, 67: q.ask = price > 0 ? price : nil
        case 4, 68: if price > 0 { q.last = price }
        case 9, 75: if price > 0 { q.prevClose = price }
        default: return
        }
        quotes[symbol] = q
    }

    private func tickSize(_ f: [String]) {
        guard let symbol = quoteSymbolByReq[f.int(2)] else { return }
        switch f.int(3) {
        case 8, 74: quotes[symbol, default: Quote()].volume = f.double(4)
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
    }

    private func openOrder(_ f: [String]) {
        guard f.count > 25 else { return }
        let id = Self.orderKey(orderId: f.int(1), permId: f.int(25))
        let lmt = f.double(16)
        var o = orders[id] ?? OrderRow(
            id: id, symbol: f.str(3), action: f.str(13), quantity: 0,
            orderType: f.str(15), limitPrice: nil, status: "Submitted"
        )
        o.symbol = f.str(3)
        o.action = f.str(13)
        o.quantity = f.double(14)
        o.orderType = f.str(15)
        o.limitPrice = (lmt > 0 && lmt < Self.unsetDouble) ? lmt : nil
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
        guard let chart = chartByReq[reqId] else { return }
        var bars: [Bar] = []
        bars.reserveCapacity(count)
        var i = 5
        for _ in 0..<count {
            guard i + 7 < f.count, let time = Self.parseBarTime(f[i]) else { break }
            bars.append(Bar(time: time, open: f.double(i + 1), high: f.double(i + 2), low: f.double(i + 3),
                            close: f.double(i + 4), volume: max(0, f.double(i + 5))))
            i += 8
        }
        pendingBars[reqId] = nil
        chart.bars = bars
        chart.isLoading = false
        chart.error = bars.isEmpty ? "No data" : nil
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
        guard let chart = chartByReq[f.int(1)], !chart.isLoading,
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

    private func contract(_ symbol: String) -> [Any] {
        // conId, symbol, secType, lastTradeDate, strike, right, multiplier, exchange, primaryExch, currency, localSymbol, tradingClass
        [0, symbol, "STK", "", 0.0, "", "", "SMART", "", "USD", "", ""]
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
