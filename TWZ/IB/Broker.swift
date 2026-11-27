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
    /// A live port and a live account (IB's paper account ids start with D).
    var isLiveAccount: Bool { isLivePort && !account.isEmpty && !account.hasPrefix("D") }

    // MARK: Published state (copied from the engine)

    private(set) var state: ConnectionState = .disconnected
    private(set) var statusText = "Disconnected"
    private(set) var lastMessage: String?
    /// The latest status and error messages, oldest first (at most 50), for the floating message tab.
    private(set) var messageHistory: [LoggedMessage] = []
    private(set) var account = ""

    private(set) var netLiquidation: Double?
    private(set) var grossPositionValue: Double?
    /// IB's margin figures, now and after the next margin change (the close), for the overnight check.
    private(set) var margin = AccountMargin()
    private(set) var dailyPnL: Double?
    private(set) var unrealizedPnL: Double?
    private(set) var realizedPnL: Double?

    private(set) var positions: [String: Position] = [:]
    /// IB has sent every position since connecting (see `TradingShortcuts`: LIVE at launch with one open).
    private(set) var positionsLoaded = false
    private(set) var orders: [Int: OrderRow] = [:]
    private(set) var fills: [String: Fill] = [:]
    /// Every quote, for code outside views. Views read `quote(_:)` instead, so a tick in one symbol
    /// doesn't redraw every view that shows some other symbol's quote.
    @ObservationIgnored private(set) var quotes: [String: Quote] = [:]
    @ObservationIgnored private var quoteBoxes: [String: QuoteBox] = [:]
    /// The charts' quotes: every snapshot's, while `quoteBoxes` (what SwiftUI shows) follow at `uiRefreshInterval`.
    @ObservationIgnored private var liveQuoteBoxes: [String: QuoteBox] = [:]
    /// What SwiftUI shows from the live feed (quotes, the chart headers) is brought up to date at most this often:
    /// each update is a pass over every view in every window, and prices stream up to 120 times a second, which
    /// left the main thread too little time to move the charts at the screen's rate. The charts follow every
    /// price on their own (see `liveQuote`, `ChartRenderLoop`); orders, fills and positions aren't held back.
    static let uiRefreshInterval: TimeInterval = 1.0 / 15
    @ObservationIgnored private var pacedRefreshPending = false
    @ObservationIgnored private var lastPacedRefresh: TimeInterval = 0
    @ObservationIgnored private var headerBoxesStale = false
    /// The latest status's account values, applied at the next paced refresh (see `uiRefreshInterval`).
    @ObservationIgnored private var pendingAccount: EngineSnapshot.Status?
    /// Symbols IB refused real-time data for this session, with IB's reason.
    private(set) var unavailableQuotes: [String: String] = [:]
    /// Headlines from IB's free providers, newest first, by feed: a stock's symbol, or `News.allFeed`.
    private(set) var news: [String: [NewsItem]] = [:]
    /// The lists' stocks with a headline since the last close: their newest one.
    private(set) var listNews: [String: NewsItem] = [:]
    /// Articles asked for with `loadNewsArticle`, by article id.
    private(set) var newsArticles: [String: NewsArticle] = [:]
    /// Why the News tab has nothing (IB refused the feed).
    private(set) var newsError: String?
    /// Option chains by underlying: expiries and strikes (see `loadOptionChain`).
    private(set) var optionChains: [String: OptionChainInfo] = [:]
    /// The options listed for an underlying's expiry, by `TradingEngine.seriesKey` (see `loadOptionSeries`).
    private(set) var optionSeries: [String: [ListedOption]] = [:]
    /// Option positions by option symbol, their average cost per share. Apart from `positions`.
    private(set) var optionPositions: [String: Position] = [:]
    /// Why an underlying's options didn't load, by underlying.
    private(set) var optionErrors: [String: String] = [:]
    /// The Options window's underlying's implied and historical volatility.
    private(set) var underlyingVols: [String: UnderlyingVol] = [:]
    /// Latest scanner results per list panel, as shown: with Hide restricted stocks on, without the
    /// stocks in `restricted` (see `filterScans`).
    private(set) var scans: [String: ScanResult] = [:]
    /// The scanner lists as IB sends them.
    @ObservationIgnored private var rawScans: [String: ScanResult] = [:]
    /// Stocks IB won't let this account open a position in (closing-only, no KID, a compliance
    /// restriction), with IB's reason. Found from what-if buys and refused orders.
    private(set) var restricted: [String: String] = [:]
    /// Settings' Hide restricted stocks: the lists' stocks are checked with what-if buys, and the
    /// restricted ones are left out of the lists and the charts that follow them.
    var hideRestricted: Bool {
        didSet {
            defaults.set(hideRestricted, forKey: RestrictedStocks.hideKey)
            let on = hideRestricted
            engine.perform { $0.setChecksRestrictions(on) }
            filterScans()
        }
    }
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
    /// Short sale restriction worked out from IB's prices, with why (see `TradingEngine.ssr`).
    private(set) var ssr: [String: String] = [:]
    /// Nasdaq's Rule 201 list, for Nasdaq-listed stocks.
    let ssrList = SSRList()

    /// Why `symbol` is under the short sale restriction (SSR), or nil if it isn't.
    func ssrReason(_ symbol: String) -> String? {
        if let time = ssrList.triggers[symbol] { return "On Nasdaq's Rule 201 list, triggered \(time) ET" }
        return ssr[symbol]
    }
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
    /// What-if trades: simulated positions by symbol, never sent to IB (see `SimTrades.swift`). Saved.
    var simPositions: [String: SimPosition] = SimPosition.saved() {
        didSet {
            simPositionsChanged(from: oldValue)
            refreshHeaderBoxes()
        }
    }
    /// The largest new long and new short IB's margin allows per symbol at about the last price, for
    /// the chart header's buying and short selling power and the hover P/L's pretend buy (see
    /// `refreshMarginSize`).
    private(set) var marginSizes: [MarginKey: MarginSize] = [:] { didSet { refreshHeaderBoxes() } }
    /// Each charted stock's header values, observed on their own (see `headerBox`).
    @ObservationIgnored var headerBoxes: [String: HeaderInfoBox] = [:]
    @ObservationIgnored private var marginSizeAsked: [MarginKey: Date] = [:]

    /// A new long (a buy) or a new short (a sell).
    enum MarginSide { case long, short }

    struct MarginKey: Hashable {
        var symbol: String
        var side: MarginSide
    }
    /// When a position last opened, changed or closed: that moves the buying power, so a size asked
    /// before then is stale.
    @ObservationIgnored private var positionsChanged = Date.distantPast
    private static let marginSizeLifetime: TimeInterval = 60

    struct MarginSize {
        var price: Double
        /// The largest long IB's margin allows at `price`; nil when IB couldn't size one (a
        /// restricted stock, say), so it isn't asked again until this goes stale.
        var maxShares: Double?
        /// When IB was asked.
        var time: Date
    }

    /// Live market value of all positions in USD (falls back to cost when no quote yet); nil until
    /// every forex position's currency has a dollar rate.
    var totalPositionValue: Double? {
        guard state == .connected else { return nil }
        var sum = 0.0
        for p in positions.values {
            guard let usd = usdPerPriceUnit(p.symbol) else { return nil }
            sum += abs(p.quantity) * (quote(p.symbol)?.last ?? p.avgCost) * usd
        }
        return sum
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
    /// Trend lines that alert, by symbol: `Workspace.trendLines` (see `setTrendLines`).
    @ObservationIgnored var trendAlertLines: [String: [Double]] = [:]
    /// Each trend line symbol's last price at the previous check, to see the price cross a line.
    @ObservationIgnored var trendAlertLast: [String: Double] = [:]
    /// The lines that have alerted, until the price moves `TrendLines.rearmShare` away from them.
    @ObservationIgnored var trendAlertsFired: [String: Set<Double>] = [:]
    @ObservationIgnored private let engine = TradingEngine()
    @ObservationIgnored private var charts: [ChartModel] = []
    /// Bumped on every chart load, so bars still on their way from the previous load are dropped.
    @ObservationIgnored private var chartGeneration: [Int: Int] = [:]
    /// What each chart's bars are of: the symbol and timeframe it last loaded.
    @ObservationIgnored private var loadedBars: [Int: BarCache.Key] = [:]
    @ObservationIgnored private var barCache = BarCache()
    @ObservationIgnored private var chartViews = ChartViews.saved()
    /// The top bar's scale while one is lit (see `Workspace.activeScale`): every main chart loading a
    /// stock takes it, in place of where it was left (a timeframe switch keeps the chart's view).
    @ObservationIgnored var gridScale: ChartScale?
    /// The main grid's list (see `Workspace.gridListKey`): views are kept per list, and the list each
    /// chart's view belongs to.
    @ObservationIgnored var viewList: String?
    @ObservationIgnored private var loadedLists: [Int: String] = [:]
    /// Each Charts window's lit scale (see `ChartsWindowState.activeScale`): every chart there loading a stock takes it.
    @ObservationIgnored var chartsWindowScales: [ChartsWin: ChartScale] = [:]
    /// The zoom set by hand, trumping `gridScale`'s (see `Workspace.manualZoom`).
    @ObservationIgnored var gridZoomOverride: Double?
    @ObservationIgnored private var chartViewsSave: Task<Void, Never>?

    /// Reset: these charts' window forgets where its charts were left (see `ChartViews`), on `timeframe`
    /// only if given; the main window only in the grid's list, the other lists keeping theirs.
    func forgetChartViews(of charts: [ChartModel], timeframe: Timeframe? = nil) {
        for window in Set(charts.map(\.windowIndex)) {
            chartViews.forget(window: window, list: window > 0 ? nil : viewList, timeframe: timeframe)
        }
        chartViewsChanged()
    }

    /// Keeps where these charts are now, as they'd be kept moving off what they show (saving a view set).
    func keepChartViews(of charts: [ChartModel]) {
        for chart in charts where !chart.symbol.isEmpty {
            let key = loadedBars[chart.id] ?? .init(symbol: chart.symbol, timeframe: chart.timeframe)
            let list = chart.inChartsWindow ? nil : loadedLists[chart.id] ?? viewList
            chartViews.keep(zoom: chart.visibleBars, place: chart.place, manual: chart.adjustedByHand,
                            for: .init(bars: key, window: chart.windowIndex, list: list))
        }
        chartViewsChanged()
    }

    /// The main window's kept views (saving a view set).
    var mainChartViews: [ChartViews.Key: ChartViews.View] { chartViews.entries(window: 0) }

    /// A Charts window's kept views (saving its view set).
    func chartsWindowViews(_ win: ChartsWin) -> [ChartViews.Key: ChartViews.View] { chartViews.entries(window: win.rawValue) }

    /// A Charts window's kept views become a view set's.
    func replaceChartsWindowViews(_ win: ChartsWin, with views: [ChartViews.Key: ChartViews.View]) {
        chartViews.replace(window: win.rawValue, with: views)
        chartViewsChanged()
    }

    /// The main window's kept views become a view set's.
    func replaceMainChartViews(with views: [ChartViews.Key: ChartViews.View]) {
        chartViews.replace(window: 0, with: views)
        chartViewsChanged()
    }

    /// The chart goes where it was left on what it shows, if anywhere (picking a view set).
    func restoreView(of chart: ChartModel) {
        guard !chart.symbol.isEmpty else { return }
        let key = loadedBars[chart.id] ?? .init(symbol: chart.symbol, timeframe: chart.timeframe)
        let list = chart.inChartsWindow ? nil : loadedLists[chart.id] ?? viewList
        guard let view = chartViews.view(for: .init(bars: key, window: chart.windowIndex, list: list)) else { return }
        if let zoom = view.zoom { chart.visibleBars = zoom }
        chart.place = view.place
        chart.adjustedByHand = view.manual == true
    }

    /// At launch: the charts' default zoom, and each zoomed and placed where it was left on what it shows
    /// (at the default zoom where it wasn't).
    func restoreChartViews(_ charts: [ChartModel], zoom: Double) {
        for chart in charts {
            chart.defaultVisibleBars = zoom
            let list = chart.inChartsWindow ? nil : viewList
            if let list { loadedLists[chart.id] = list }
            let view = chartViews.view(for: .init(bars: .init(symbol: chart.symbol, timeframe: chart.timeframe),
                                                  window: chart.windowIndex, list: list))
            chart.visibleBars = view?.zoom ?? zoom
            chart.place = view?.place ?? ChartModel.Place()
            chart.adjustedByHand = view?.manual == true
        }
    }

    /// After the grid switched lists: a chart that kept its stock (in both lists) keeps its view under the
    /// list it was in, and takes the one it was left at in this list, if any (else the default view: a list
    /// doesn't take another's); one not adjusted by hand then takes the lit scale. Charts that loaded a stock have done so already.
    func adoptList(_ charts: [ChartModel]) {
        guard let list = viewList else { return }
        var changed = false
        for chart in charts where !chart.inChartsWindow && !chart.symbol.isEmpty {
            let old = loadedLists[chart.id] ?? list
            guard old != list else { continue }
            let bars = loadedBars[chart.id] ?? .init(symbol: chart.symbol, timeframe: chart.timeframe)
            chartViews.keep(zoom: chart.visibleBars, place: chart.place, manual: chart.adjustedByHand,
                            for: .init(bars: bars, window: 0, list: old))
            let view = chartViews.view(for: .init(bars: bars, window: 0, list: list))
            if let view {
                if let zoom = view.zoom { chart.visibleBars = zoom }
                chart.place = view.place
            } else {
                chart.visibleBars = chart.defaultVisibleBars
                chart.place = ChartModel.Place()
            }
            chart.adjustedByHand = view?.manual == true
            if !chart.adjustedByHand, let gridScale {
                gridScale.apply(to: chart)
                if let gridZoomOverride { chart.visibleBars = gridZoomOverride }
            }
            loadedLists[chart.id] = list
            changed = true
        }
        if changed { chartViewsChanged() }
    }

    /// A click on a scale's number: no view of these charts' window, in the grid's current list, counts as
    /// adjusted by hand any more.
    func forgetChartAdjustments(of charts: [ChartModel]) {
        for chart in charts { chart.adjustedByHand = false }
        for window in Set(charts.map(\.windowIndex)) {
            chartViews.forgetManual(window: window, list: window > 0 ? nil : viewList)
        }
        chartViewsChanged()
    }

    /// Quitting: keeps where every chart is, and the bars they show (see `BarStore`), then saves it all.
    func saveChartViews() {
        for chart in charts where !chart.symbol.isEmpty && !chart.isLoading {
            barCache.keep(chart.bars, for: loadedBars[chart.id] ?? .init(symbol: chart.symbol, timeframe: chart.timeframe))
        }
        BarStore.shared.flush()
        for chart in charts where !chart.symbol.isEmpty {
            let key = loadedBars[chart.id] ?? .init(symbol: chart.symbol, timeframe: chart.timeframe)
            let list = chart.inChartsWindow ? nil : loadedLists[chart.id] ?? viewList
            chartViews.keep(zoom: chart.visibleBars, place: chart.place, manual: chart.adjustedByHand,
                            for: .init(bars: key, window: chart.windowIndex, list: list))
        }
        chartViewsSave?.cancel()
        chartViews.save()
    }

    /// Saves the views a couple of seconds after they change, once for a burst (a whole grid switching).
    private func chartViewsChanged() {
        chartViewsSave?.cancel()
        chartViewsSave = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            self.chartViews.save()
        }
    }

    /// What the bars kept for coming back to a timeframe or stock take (Settings › Trading shows it).
    var barCacheUsage: BarCache.Usage { barCache.usage }
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
        hideRestricted = defaults.bool(forKey: RestrictedStocks.hideKey)
        let engine = engine
        apply(engine.queue.sync { engine.fullSnapshot() })
        engine.sink = { [weak self] snapshot in self?.apply(snapshot) }
        ssrList.onChange = { symbols in engine.perform { $0.setNasdaqSSR(symbols) } }
        let checks = hideRestricted
        engine.perform { $0.setChecksRestrictions(checks) }
        setQuoteSymbols(Array(simPositions.keys), owner: Self.simQuoteOwner)
        BarStore.shared.prune()
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

    /// A list panel's News tab shows `symbol`'s news, or all news; nil and false when it's closed.
    func setNews(owner: String, symbol: String?, all: Bool) {
        engine.perform { $0.setNews(owner: owner, symbol: symbol, all: all) }
    }

    func loadNewsArticle(_ item: NewsItem) {
        let (provider, id) = (item.provider, item.id)
        engine.perform { $0.requestNewsArticle(provider: provider, id: id) }
    }

    /// Each list panel declares the scanner it shows (nil to stop it).
    func setScanner(_ spec: ScanSpec?, owner: String) {
        engine.perform { $0.setScanner(spec, owner: owner) }
    }

    /// A list showing the Forex list: by each pair's 5-day range (see `TradingEngine.setForexByRange`) or in its fixed order.
    func setForexByRange(_ on: Bool, owner: String) {
        engine.perform { $0.setForexByRange(on, owner: owner) }
    }

    func registerCharts(_ charts: [ChartModel]) {
        self.charts = charts
        var specs: [ChartSpec] = []
        for chart in charts {
            let key = BarCache.Key(symbol: chart.symbol, timeframe: chart.timeframe)
            loadedBars[chart.id] = key
            var spec = ChartSpec(id: chart.id, symbol: chart.symbol, timeframe: chart.timeframe)
            // At launch, the bars kept on disk (see `BarCache`) show at once and stay behind the fresh ones, older
            // ones included (see `TradingEngine.checkReady`), so a view zoomed far out doesn't load them again.
            if chart.bars.isEmpty, !chart.isLoading {
                let seed = barCache.stored(key)
                if !seed.isEmpty {
                    chart.bars = seed
                    spec.bars = seed
                    spec.fullHistory = Self.needsFullHistory(seed, key: key, chart: chart)
                }
            }
            specs.append(spec)
        }
        engine.perform { $0.registerCharts(specs) }
    }

    /// Whether a chart starting from bars kept from before (`seed`) asks for the full history rather than the short one.
    /// Kept from a while ago (from disk, after a relaunch): the full history, so the fresh bars reach back to them and the
    /// older ones stay (see `TradingEngine.historicalData`). Kept with the overnight session in them (from a full
    /// history): the full history again, which has it, so it doesn't show and then vanish when the short one comes in.
    /// A view that shows back to the oldest of them (zoomed out): it would ask for the full history as soon as it draws
    /// (see `OlderBars`), cancelling the short one, so it asks for it at once: one request to IB instead of two, which
    /// with a grid of charts switching together is what keeps IB from holding them all back (its pacing).
    static func needsFullHistory(_ seed: [Bar], key: BarCache.Key, chart: ChartModel) -> Bool {
        guard !seed.isEmpty else { return false }
        if let newest = seed.last?.time, newest < Date().addingTimeInterval(-6 * 3600) { return true }
        let count = Double(seed.count)
        if chart.scrollBack + chart.visibleBars >= count || chart.visibleBars >= count { return true }
        return key.timeframe.isIntraday && !ForexPair.isForex(key.symbol) && seed.contains { $0.phase == .overnight }
    }

    /// These charts get tick-by-tick trades, as does the selected one; the others keep IB's regular bar updates.
    func setFastCharts(_ ids: Set<Int>) {
        engine.perform { $0.setFastCharts(ids) }
    }

    /// The selected chart's symbol gets tick-by-tick trades and bid/ask, fast or not, before any other.
    func setSelectedChart(_ id: Int) {
        engine.perform { $0.setSelectedChart(id) }
    }

    /// ⌥⇧R: the chart's bars thrown away and loaded fresh from IB, its view back to the default (latest bars,
    /// default zoom, prices fitted), for a chart gone wrong. Only this chart; nothing else moves.
    func reloadChart(_ chart: ChartModel) {
        chart.adjustedByHand = false
        chart.scrollBack = 0
        chart.visibleBars = chart.defaultVisibleBars
        chart.priceShift = 0
        chart.priceScale = 1
        chart.pendingEdge = nil
        guard !chart.symbol.isEmpty else { return }
        let id = chart.id
        engine.perform { $0.reloadChart(id) }
    }

    /// Loads the chart's symbol and timeframe. Its bars kept from before,
    /// or another chart's showing them, show at once, fresh ones replacing them when they're in; the
    /// bars it showed are kept (see `BarCache`).
    func loadChart(_ chart: ChartModel) {
        let generation = (chartGeneration[chart.id] ?? 0) + 1
        chartGeneration[chart.id] = generation
        let key = BarCache.Key(symbol: chart.symbol, timeframe: chart.timeframe)
        let previous = loadedBars.updateValue(key, forKey: chart.id) ?? key
        let shown = chart.isLoading ? [] : chart.bars
        if previous != key { barCache.keep(shown, for: previous) }
        let live = charts.first { $0 !== chart && loadedBars[$0.id] == key && !$0.isLoading && !$0.bars.isEmpty }?.bars
        let seed = barCache.bars(for: key, previous: previous, previousBars: shown, live: live)
        chart.bars = seed
        chart.error = nil
        // Views are kept per list in the main grid: the one it leaves under the list it was in.
        let list = chart.inChartsWindow ? nil : viewList
        let previousList = chart.inChartsWindow ? nil : loadedLists[chart.id] ?? viewList
        if let list { loadedLists[chart.id] = list }
        // Where it was left on the stock and timeframe it leaves is kept (see `ChartViews`).
        let window = chart.inChartsWindow
        if previous != key {
            chartViews.keep(zoom: chart.visibleBars, place: chart.place, manual: chart.adjustedByHand,
                            for: .init(bars: previous, window: chart.windowIndex, list: previousList))
            chartViewsChanged()
        }
        chart.pendingEdge = nil
        let keepsView = TimeframeSwitch.keepsView
        // Settings' Keep the view off: each timeframe its own zoom, the one left kept for coming back.
        if !keepsView, previous.timeframe != key.timeframe {
            chart.zooms[previous.timeframe] = chart.visibleBars
            chart.visibleBars = chart.zooms.removeValue(forKey: key.timeframe) ?? chart.defaultVisibleBars
        }
        if previous != key, previous.symbol == key.symbol, keepsView {
            // Another timeframe of the same stock: the same view, only the candles change. As much time on
            // screen, the right edge at the same time (the end of the right-most candle; or as far past the
            // latest bar), prices as they were; where that time is on the new timeframe is known once its
            // bars are (see `apply`).
            let ratio = ChartScale.barRatio(from: previous.timeframe, to: key.timeframe)
            chart.visibleBars = min(max(ChartModel.maxVisibleBars, Double(seed.count)), max(15, chart.visibleBars * ratio))
            if chart.scrollBack > 0, !shown.isEmpty {
                let last = min(shown.count - 1, max(0, Int((Double(shown.count) - chart.scrollBack).rounded()) - 1))
                let edge = shown[last].time.addingTimeInterval((previous.timeframe.barSeconds ?? 1) - 1)
                chart.pendingEdge = edge
                chart.scrollBack = seed.isEmpty ? chart.scrollBack * ratio
                    : Self.scrollBack(showing: edge, in: seed, timeframe: key.timeframe)
            } else {
                chart.scrollBack *= ratio
            }
        } else if previous != key {
            // Another stock, or with Keep the view off another timeframe: where a chart of its window was
            // left on it, if anywhere (else the view stays as it is, at the latest bars on another
            // timeframe; in the main grid, coming from another list, the default view: a list doesn't take
            // another's); then a lit scale, but not over a view adjusted by hand.
            let view = chartViews.view(for: .init(bars: key, window: chart.windowIndex, list: list))
            chart.adjustedByHand = view?.manual == true
            if let view {
                if let zoom = view.zoom { chart.visibleBars = zoom }
                chart.place = view.place
            } else if !window, previousList != list {
                chart.visibleBars = chart.defaultVisibleBars
                chart.place = ChartModel.Place()
            } else if previous.timeframe != key.timeframe {
                chart.place = ChartModel.Place()
            }
            if !window, !chart.adjustedByHand, let gridScale {
                gridScale.apply(to: chart)
                if let gridZoomOverride { chart.visibleBars = gridZoomOverride }
            }
            if window, !chart.adjustedByHand, let scale = ChartsWin.of(chartID: chart.id).flatMap({ chartsWindowScales[$0] }) {
                scale.apply(to: chart)
            }
        }
        chart.isLoading = seed.isEmpty && state == .connected && !chart.symbol.isEmpty
        var spec = ChartSpec(id: chart.id, symbol: chart.symbol, timeframe: chart.timeframe, bars: seed)
        if Self.needsFullHistory(seed, key: key, chart: chart) { spec.fullHistory = true }
        engine.perform { $0.loadChart(spec, generation: generation) }
    }

    /// How far back from the latest of `bars` the bar holding `edge` is: to keep it the right-most one.
    static func scrollBack(showing edge: Date, in bars: [Bar], timeframe: Timeframe) -> Double {
        guard let first = bars.first else { return 0 }
        let i = CandleChart.barIndex(of: edge, in: bars, barSeconds: timeframe.barSeconds) ?? (edge < first.time ? 0 : bars.count - 1)
        return Double(bars.count - 1 - i)
    }

    /// The view reached the chart's oldest bar: loads its full history (`Timeframe.duration`, with the
    /// overnight session) behind the short one it started with, then a page before it each time
    /// again (see `TradingEngine.loadOlderBars`). The bars on screen stay, and the view stays where it is.
    func loadOlderBars(_ chart: ChartModel) {
        guard state == .connected, !chart.isLoading, !chart.symbol.isEmpty, !chart.bars.isEmpty else { return }
        let (id, generation) = (chart.id, chartGeneration[chart.id] ?? 0)
        engine.perform { $0.loadOlderBars(id, generation: generation) }
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
        removeSimProtective(symbol.uppercased())
        order { $0.cancelOrders(for: symbol) }
    }

    /// ⌘⌫: cancels every order in `symbol`, stop loss and take profit included, then closes the whole
    /// position at market (with KEYS ON; SIM closes the what-if trade, see `closeSimAtMarket`).
    func closePosition(_ symbol: String) {
        order { $0.closePosition(symbol) }
    }

    /// Asks IB for fresh margin figures (the account summary) now, for the overnight check.
    func refreshAccountSummary() {
        engine.perform { $0.refreshAccountSummary() }
    }

    /// The overnight check's Trim: sells (or buys back) that many shares of each position at IB,
    /// KEYS ON or SIM alike (see `TradingEngine.trimForOvernight`).
    func trimForOvernight(_ trims: [String: Double]) {
        order { $0.trimForOvernight(trims) }
    }

    /// Shows `message` in the status line and the message history, as the engine's own messages show.
    func say(_ message: String) {
        engine.perform { $0.say(message) }
    }

    /// The largest new `action` (BUY: long, SELL: short) IB's margin allows in `symbol` at `price`,
    /// asked now: `completion` gets the price asked at and the shares (nil when IB can't size it) a
    /// second or two later, or never while not connected.
    func askMaxNew(_ action: String, symbol: String, at price: Double,
                   completion: @escaping @MainActor @Sendable (_ price: Double, _ shares: Double?) -> Void) {
        engine.perform { engine in
            engine.maxNew(action, symbol: symbol, at: price) { price, shares in
                Task { @MainActor in completion(price, shares) }
            }
        }
    }

    func cancelAllOrders() {
        order { $0.cancelAllOrders() }
    }

    /// A hotkey's or order key's order, with KEYS ON (SIM, KEYS off, trades it as a what-if trade: see `runSim`).
    func run(_ hotkey: Hotkey, symbol: String) {
        guard let hotkey = resolved(hotkey) else { return }
        order { $0.run(hotkey, symbol: symbol) }
    }

    /// A hotkey sized in steps in dollars or a percent of the buying power, as `SizeMode` is now; nil, saying
    /// so, when it has no size in it (5–9 in %).
    func resolved(_ hotkey: Hotkey) -> Hotkey? {
        if let resolved = hotkey.resolved { return resolved }
        say("\(hotkey.shortcut.map { $0.display + " " } ?? "")\(hotkey.action.rawValue): no size at \(Fmt.shares(hotkey.amount)) in % (1–4 are 20–80%; ⌘⇧M for $), so nothing was sent")
        return nil
    }

    /// Alt-click on a chart with a hotkey selected: that hotkey's order at the clicked price.
    func run(_ hotkey: Hotkey, symbol: String, at clickedPrice: Double) {
        guard let hotkey = resolved(hotkey) else { return }
        order { $0.run(hotkey, symbol: symbol, at: clickedPrice) }
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

    func marginSize(_ symbol: String, _ side: MarginSide) -> MarginSize? {
        marginSizes[MarginKey(symbol: symbol, side: side)]
    }

    /// Asks IB's margin preview, quietly, for the largest new long and / or short in `symbol` at the
    /// last price, unless the one in `marginSizes` is still fresh: under a minute old, asked within
    /// 5% of the last price and since the positions last changed. Not against the position (a long
    /// while short, a short while long): IB's preview of that order closes it first. No short of a
    /// stock IB says can't be shorted.
    func refreshMarginSize(symbol: String, sides: [MarginSide] = [.long, .short]) {
        guard state == .connected, !symbol.isEmpty, let last = quote(symbol)?.last, last > 0 else { return }
        let held = positions[symbol]?.quantity ?? 0, now = Date()
        for side in sides {
            if side == .long ? held < 0 : held > 0 { continue }
            if side == .short, Self.cantShort(shortability[symbol], symbol) { continue }
            let key = MarginKey(symbol: symbol, side: side)
            if let size = marginSizes[key], now.timeIntervalSince(size.time) < Self.marginSizeLifetime,
               size.time > positionsChanged, abs(last / size.price - 1) < 0.05 { continue }
            // IB answers in a second or two, or never (no completion): ask again after 15 s.
            if let asked = marginSizeAsked[key], now.timeIntervalSince(asked) < 15 { continue }
            marginSizeAsked[key] = now
            let answered: @MainActor @Sendable (Double, Double?) -> Void = { [weak self] price, shares in
                self?.marginSizes[key] = MarginSize(price: price, maxShares: shares, time: now)
                self?.marginSizeAsked[key] = nil
            }
            let action = side == .long ? "BUY" : "SELL"
            engine.perform { engine in
                engine.maxNew(action, symbol: symbol, at: last) { price, shares in
                    Task { @MainActor in answered(price, shares) }
                }
            }
        }
    }

    /// IB's preview of one order, never placed: the margin it would take and its commissions and
    /// fees. `completion` gets it a second or two later (nil when IB can't preview it), or never
    /// while not connected.
    func previewOrder(_ action: String, symbol: String, shares: Double, at price: Double,
                      completion: @escaping @MainActor @Sendable (OrderPreview?) -> Void) {
        engine.perform { engine in
            engine.previewOrder(action, symbol: symbol, shares: shares, at: price) { preview in
                Task { @MainActor in completion(preview) }
            }
        }
    }

    /// IB's shortable tick says the stock can't be shorted (see `shortability`).
    private static func cantShort(_ level: Double?, _ symbol: String) -> Bool {
        !ForexPair.isForex(symbol) && (level.map { $0 <= 1.5 } ?? false)
    }

    /// The most shares (a forex pair's base units) a new long or short in `symbol` can be now: IB's
    /// margin preview's (see `refreshMarginSize`), a short's also no more than the shares IB has to
    /// lend. nil before IB answers, when it can't size one, or for a short of a stock that can't be shorted.
    func maxNewShares(_ symbol: String, _ side: MarginSide) -> Double? {
        guard var shares = marginSize(symbol, side)?.maxShares else { return nil }
        if side == .short {
            if Self.cantShort(shortability[symbol], symbol) { return nil }
            if let lendable = shortableShares[symbol], lendable > 0 { shares = min(shares, lendable) }
        }
        return shares
    }

    /// The most a new long or short in `symbol` can be worth in NOK now (see `maxNewShares`), at
    /// the price IB was asked at: the amount moves little with the price. nil while not connected too.
    func marginPowerNOK(_ symbol: String, _ side: MarginSide) -> Double? {
        guard state == .connected, let shares = maxNewShares(symbol, side), let size = marginSize(symbol, side),
              let usd = usdPerPriceUnit(symbol), let usdNok else { return nil }
        return shares * size.price * usd * usdNok
    }

    // MARK: - Options

    /// Loads an underlying's option expiries and strikes, once a day (see `optionChains`).
    func loadOptionChain(_ underlying: String) {
        engine.perform { $0.loadOptionChain(underlying) }
    }

    /// Loads the options listed for one expiry (see `optionSeries`).
    func loadOptionSeries(_ underlying: String, expiry: String) {
        engine.perform { $0.loadOptionSeries(underlying, expiry: expiry) }
    }

    /// The options listed for an underlying's expiry; nil until loaded.
    func listedOptions(_ underlying: String, expiry: String) -> [ListedOption]? {
        optionSeries[TradingEngine.seriesKey(underlying, expiry)]
    }

    /// The Options window's underlying (nil: the window closed), whose volatility is streamed.
    func setVolUnderlying(_ symbol: String?) {
        engine.perform { $0.setVolUnderlying(symbol) }
    }

    /// Sends one option order: a limit for the day.
    func placeOption(_ symbol: String, action: String, contracts: Double, limit: Double) {
        order { $0.placeOption(symbol, action: action, contracts: contracts, limit: limit) }
    }

    /// Sends options as one combo order: `units` of `legs` at `limit` a unit (a credit negative).
    func placeOptionCombo(underlying: String, legs: [ComboLegSpec], units: Double, limit: Double) {
        order { $0.placeOptionCombo(underlying: underlying, legs: legs, units: units, limit: limit) }
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

    /// Shares (a forex pair's base currency units) a NOK amount buys of `symbol` at `price`, at the
    /// current rates.
    func shares(forNOK nok: Double, of symbol: String, at price: Double) -> Double? {
        TradingEngine.shares(forNOK: nok, at: price, usdNok: usdNok, usdPerUnit: usdPerPriceUnit(symbol))
    }

    /// Dollars per unit of the currency `symbol` is priced in: 1 for a stock; for a forex pair, its
    /// quote currency's rate from the live quotes, nil until that's quoted. Prices times shares times
    /// this are dollars.
    func usdPerPriceUnit(_ symbol: String) -> Double? {
        if OptionContract.isOption(symbol) || OptionCombo.underlying(of: symbol) != nil { return OptionContract.multiplier }
        guard let pair = ForexPair(symbol) else { return 1 }
        return ForexPair.usdPerUnit(of: pair.quote, usdNok: usdNok) { quotes[$0]?.mid }
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

    /// One symbol's quote; a view reading it is redrawn only when that symbol's quote changes, at most
    /// `uiRefreshInterval` apart.
    func quote(_ symbol: String) -> Quote? {
        if let box = quoteBoxes[symbol] { return box.quote }
        let box = QuoteBox(quote: quotes[symbol])
        quoteBoxes[symbol] = box
        return box.quote
    }

    /// One symbol's quote as of the latest snapshot, for the charts (they redraw on their own, not through SwiftUI).
    func liveQuote(_ symbol: String) -> Quote? {
        if let box = liveQuoteBoxes[symbol] { return box.quote }
        let box = QuoteBox(quote: quotes[symbol])
        liveQuoteBoxes[symbol] = box
        return box.quote
    }

    /// The chart headers' values brought up to date, at most `uiRefreshInterval` apart.
    func refreshHeaderBoxes() {
        headerBoxesStale = true
        schedulePacedRefresh()
    }

    private func schedulePacedRefresh() {
        guard !pacedRefreshPending else { return }
        pacedRefreshPending = true
        let wait = max(0, lastPacedRefresh + Self.uiRefreshInterval - ProcessInfo.processInfo.systemUptime)
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pacedRefreshPending = false
                self.lastPacedRefresh = ProcessInfo.processInfo.systemUptime
                if let st = self.pendingAccount {
                    self.pendingAccount = nil
                    self.update(\.netLiquidation, st.netLiquidation)
                    self.update(\.grossPositionValue, st.grossPositionValue)
                    self.update(\.margin, st.margin)
                    self.update(\.dailyPnL, st.dailyPnL)
                    self.update(\.unrealizedPnL, st.unrealizedPnL)
                    self.update(\.realizedPnL, st.realizedPnL)
                    self.update(\.usdNok, st.usdNok)
                    self.update(\.usdNokIsLive, st.usdNokIsLive)
                    self.headerBoxesStale = true
                }
                for (symbol, box) in self.quoteBoxes where box.quote != self.quotes[symbol] { box.quote = self.quotes[symbol] }
                if self.headerBoxesStale {
                    self.headerBoxesStale = false
                    self.refreshHeaderBoxesNow()
                }
            }
        }
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
            if let message = st.lastMessage, message != lastMessage {
                messageHistory.append(LoggedMessage(time: Date(), text: message))
                if messageHistory.count > 50 { messageHistory.removeFirst(messageHistory.count - 50) }
            }
            update(\.lastMessage, st.lastMessage)
            update(\.account, st.account)
            // The account's values and USD.NOK (which streams, moving every NOK value shown) at the UI's pace.
            pendingAccount = st
            schedulePacedRefresh()
        }
        if let v = s.positions, v != positions {
            positions = v
            positionsChanged = Date()
        }
        if let v = s.positionsLoaded { update(\.positionsLoaded, v) }
        if let v = s.entries, !v.isEmpty, isLiveAccount, Confetti.isEnabled { Confetti.fire() }
        if let v = s.orders { update(\.orders, v) }
        if let v = s.fills { update(\.fills, v) }
        if let v = s.quotes {
            quotes = v
            for (symbol, box) in liveQuoteBoxes where box.quote != v[symbol] { box.quote = v[symbol] }
            schedulePacedRefresh()
            if !simPositions.isEmpty { checkSimExits() }
            if !trendAlertLines.isEmpty { checkTrendAlerts() }
        }
        if let v = s.unavailableQuotes { update(\.unavailableQuotes, v) }
        if let v = s.news { update(\.news, v) }
        if let v = s.listNews { update(\.listNews, v) }
        if let v = s.newsArticles { update(\.newsArticles, v) }
        if let v = s.newsError { update(\.newsError, v) }
        if let v = s.optionChains { update(\.optionChains, v) }
        if let v = s.optionSeries { update(\.optionSeries, v) }
        if let v = s.optionPositions { update(\.optionPositions, v) }
        if let v = s.optionErrors { update(\.optionErrors, v) }
        if let v = s.underlyingVols { update(\.underlyingVols, v) }
        if let v = s.scans { rawScans = v }
        if let v = s.restricted { update(\.restricted, v) }
        if s.scans != nil || s.restricted != nil || s.positions != nil || s.orders != nil { filterScans() }
        if let v = s.tickTradeSymbols { update(\.tickTradeSymbols, v) }
        if let v = s.tickLimitedSymbols { update(\.tickLimitedSymbols, v) }
        if let v = s.shortability { update(\.shortability, v) }
        if let v = s.shortableShares { update(\.shortableShares, v) }
        if let v = s.ssr { update(\.ssr, v) }
        if let v = s.sessionCloses { update(\.sessionCloses, v) }
        if let v = s.chartOrderIds { update(\.chartOrderIds, v) }
        if let v = s.protectiveOrders { update(\.protectiveOrders, v) }
        if let v = s.orderSources { update(\.orderSources, v) }
        for patch in s.charts {
            guard patch.generation == chartGeneration[patch.id] ?? 0,
                  let chart = charts.first(where: { $0.id == patch.id }) else { continue }
            if let bars = patch.bars {
                chart.bars = bars
                // A timeframe switch's right-most candle, once the new timeframe's bars are in.
                if let edge = chart.pendingEdge, !bars.isEmpty {
                    chart.scrollBack = Self.scrollBack(showing: edge, in: bars, timeframe: chart.timeframe)
                    chart.pendingEdge = nil
                }
            }
            for bar in patch.tail { Self.upsert(bar, into: chart) }
            if chart.isLoading != patch.isLoading { chart.isLoading = patch.isLoading }
            if chart.error != patch.error { chart.error = patch.error }
        }
        if s.status != nil || s.positions != nil || s.fills != nil || s.tickTradeSymbols != nil
            || s.tickLimitedSymbols != nil || s.shortability != nil {
            refreshHeaderBoxes()
        }
    }

    /// Adds a message of the app's own to the floating message tab.
    func logMessage(_ text: String) {
        messageHistory.append(LoggedMessage(time: Date(), text: text))
        if messageHistory.count > 50 { messageHistory.removeFirst(messageHistory.count - 50) }
    }

    /// The stocks the registered charts show.
    var chartedSymbols: Set<String> { Set(charts.map(\.symbol)) }

    /// A real position open, in any symbol.
    var hasLivePositions: Bool { positions.values.contains { $0.quantity != 0 } }

    /// The scanner lists without the restricted stocks while Hide restricted stocks is on, but for
    /// those with a position or a working order, which stay in view.
    private func filterScans() {
        guard hideRestricted, !restricted.isEmpty else { return update(\.scans, rawScans) }
        let kept = Set(positions.values.filter { $0.quantity != 0 }.map(\.symbol))
            .union(orders.values.filter(\.isActive).map(\.symbol))
        update(\.scans, rawScans.mapValues { scan in
            var scan = scan
            scan.symbols.removeAll { restricted[$0] != nil && !kept.contains($0) }
            return scan
        })
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

/// A status or error message and when it came.
struct LoggedMessage: Identifiable, Equatable {
    let id = UUID()
    var time: Date
    var text: String
}
