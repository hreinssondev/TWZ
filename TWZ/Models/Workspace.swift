//
//  Workspace.swift
//  TWZ
//
//  UI state that survives relaunches: charts set by hand, scanner filters, hotkey configuration
//  and what-if buys.
//

import Foundation
import Observation

@Observable
final class ChartModel: Identifiable {
    let id: Int
    var symbol: String
    /// Switching keeps the view, only the candles change (as much time on screen, the right edge at the
    /// same time), or with Settings' Keep the view off, goes to the timeframe's own (see `Broker.loadChart`).
    var timeframe: Timeframe
    var bars: [Bar] = []
    var isLoading = false
    var error: String?

    // Viewport: how many bars fit on screen and how far we've scrolled back from the latest bar.
    var visibleBars: Double
    var scrollBack: Double = 0
    /// Vertical drag, as a fraction of the auto-fitted price range (positive = moved down).
    var priceShift: Double = 0
    /// ⌃⌥-swipe vertical zoom: the auto-fitted price range times this (above 1 = zoomed out).
    var priceScale: Double = 1
    /// When the chart last loaded a symbol, counted across charts: of two main-window charts showing
    /// the same stock, the lower one showed it first (see `Workspace.timeframe(showing:in:otherwise:)`).
    @ObservationIgnored var loadOrder = 0

    init(id: Int, symbol: String, timeframe: Timeframe) {
        self.id = id
        self.symbol = symbol
        self.timeframe = timeframe
        defaultVisibleBars = Self.initialVisibleBars
        visibleBars = Self.initialVisibleBars
    }

    /// Bars on screen at the default zoom (double-click goes back to it); each grid's Zoom slider sets it.
    var defaultVisibleBars: Double
    /// Bars on screen on the timeframes the chart was switched away from, with Settings' Keep the view
    /// when switching timeframe off: switching back zooms it as it was left (those not in it, at the
    /// default zoom). Reset clears it.
    @ObservationIgnored var zooms: [Timeframe: Double] = [:]
    /// After a timeframe switch while scrolled back: the time of the candle that was right-most, made the
    /// right-most one again once the new timeframe's bars are in (see `Broker.apply`). Panning drops it.
    @ObservationIgnored var pendingEdge: Date?
    /// Zoomed, panned or its prices moved by hand on what it shows: a lit scale that charts
    /// take as they load leaves it as it is (see `ChartViews`). A click on a scale's number,
    /// Reset, or a right-click / double-click on it clears it.
    @ObservationIgnored var adjustedByHand = false
    /// The Charts window's charts (see `Workspace.secondaryCharts`) have ids from this on.
    static let chartsWindowFirstID = 100
    var inChartsWindow: Bool { id >= Self.chartsWindowFirstID }

    /// The view's place: how far back from the latest bar, and moved and zoomed up or down.
    struct Place: Codable {
        var scrollBack = 0.0
        var priceShift = 0.0
        var priceScale = 1.0
    }

    var place: Place {
        get { Place(scrollBack: scrollBack, priceShift: priceShift, priceScale: priceScale) }
        set {
            scrollBack = newValue.scrollBack
            priceShift = newValue.priceShift
            priceScale = newValue.priceScale
        }
    }
    static let initialVisibleBars: Double = 240
    /// The furthest out the Zoom sliders and gestures go (a full extended-hours day of 1m bars fits).
    static let maxVisibleBars: Double = 1200
}

/// A pretend buy at the clicked price, placed by ⌃-clicking a chart with no position open: 80% of the
/// largest long IB's margin allows in the symbol at that moment. Only a margin preview goes to IB,
/// never an order; hovering the chart shows what it would have made or lost. ⌃-clicking its line,
/// double-clicking anywhere on its chart, ⌘A, ⌘⌫ or ⌘⇧⌫ removes it.
nonisolated struct WhatIf: Codable {
    static let buyingPowerFraction = 0.8
    /// Stands in for an order id on the what-if line, so double-clicking the line removes it.
    static let lineId = -1

    var price: Double
    var shares: Double
    /// When it was made: tells it apart from a later one in the same symbol.
    var time: Date?
    /// IB's preview of the buy, a second or two after it's made (see `Broker.previewOrder`).
    var preview: OrderPreview?

    /// P/L if sold at `exit`.
    func pnl(at exit: Double) -> Double { (exit - price) * shares }
}

/// What IB's preview of an order (a what-if, never placed) says it would take.
nonisolated struct OrderPreview: Codable, Equatable, Sendable {
    /// Initial and maintenance margin the order adds, in the account's currency (NOK).
    var initMarginChange: Double
    var maintMarginChange: Double?
    var commission: Commission?

    /// Commissions and fees: IB's estimate is a range (`min` = `max` when it's sure).
    struct Commission: Codable, Equatable, Sendable {
        var min: Double
        var max: Double
        var currency: String
    }
}

/// A main-window chart given a stock by hand, as saved: its cell and what it shows.
nonisolated struct MainGridPin: Codable, Equatable {
    var column: Int
    var row: Int
    var symbol: String
    var timeframe: Timeframe
    /// The gainer the chart showed before it was set by hand, kept off the grid meanwhile (see
    /// `Workspace.handDisplaced`).
    var displaced: String?
}

/// Where a stock was last shown in the main grid: the list the grid followed (see
/// `Workspace.gridListKey`) and its cell in reading order. Double-clicking a position, order or round
/// trip whose stock no chart shows goes back there (see `Workspace.showChart`).
nonisolated struct GridPlace: Codable, Equatable {
    var list: String
    var cell: Int
    /// When it last moved, counted across stocks: past `capacity`, the one that moved longest ago goes.
    var kept: Int

    static let storageKey = "gridPlaces"
    static let capacity = 500
}

@Observable
final class Workspace {
    /// The main window's charts, one for each cell of the largest grid (see `ChartGrid`).
    let mainCharts: [ChartModel]
    let secondaryCharts: [ChartModel]
    /// The main-window chart in each cell, in reading order, laid out for `mainColumns` columns.
    var mainCells: [Int]
    var mainColumns: Int
    /// The selected chart's id: a main-window chart; the last one selected while none is
    /// (see `isChartSelected`).
    var selectedChartID = 0 { didSet { isChartSelected = true } }
    /// False after clicking empty space in the Orders or Positions column: no chart is selected, so
    /// hotkeys and order shortcuts have no symbol to act on until a chart is selected again.
    var isChartSelected = true

    var hotkeys: [Hotkey] { didSet { save() } }
    /// Settings › Order Keys: keyboard shortcuts that send an order without a hotkey button (see `OrderKeys`). Saved.
    var orderKeys: [Hotkey] { didSet { save() } }

    /// Adds `new` to the modifier sets that press the 1–9 buy (or `selling`) order keys, or puts it in place of
    /// `replacing`. Nil once done; else why not (nothing changes): no ⌘, ⌥ or ⌃, the other side's, one of these already,
    /// ⌘⇧ (macOS's screenshots), or a number with it taken (timeframes, what-if trades, another order key, the extra
    /// Reset or Charts window shortcut). A hotkey button on one of them overrides that order key (see `hotkeyOverriding`).
    func setNumberModifiers(_ new: ModifierSet, selling: Bool, replacing: ModifierSet? = nil) -> String? {
        let sets = selling ? sellModifierSets : buyModifierSets
        let others = selling ? buyModifierSets : sellModifierSets
        guard new.command || new.option || new.control else { return "Hold ⌘, ⌥ or ⌃ (⇧ too if you like), then ↩" }
        if others.contains(new) { return "\(new.display) is the \(selling ? "buy" : "sell") keys' already" }
        if new == replacing { return nil }
        if sets.contains(new) { return "\(new.display) is one of them already" }
        if new == ModifierSet(command: true, shift: true) { return "⌘⇧3, 4 and 5 are macOS's screenshots" }
        for digit in 1...9 {
            let s = new.shortcut(digit: digit)
            if let reason = s.reservedFor { return "\(s.display): \(reason)" }
            if let key = orderKeys.first(where: { !isNumberKey($0) && $0.shortcut?.numberRow == s }) {
                return "\(s.display) is already the order key \"\(key.label)\""
            }
            if resetShortcut == s { return "\(s.display) is the extra Reset shortcut" }
            if chartsWindowShortcut == s { return "\(s.display) shows and hides the Charts window" }
        }
        var updated = sets
        if let replacing, let i = updated.firstIndex(of: replacing) { updated[i] = new } else { updated.append(new) }
        if selling { sellModifierSets = updated } else { buyModifierSets = updated }
        return nil
    }

    /// Takes `set` off the modifier sets that press the 1–9 buy (or `selling`) order keys.
    func removeNumberModifiers(_ set: ModifierSet, selling: Bool) {
        if selling { sellModifierSets.removeAll { $0 == set } } else { buyModifierSets.removeAll { $0 == set } }
    }

    /// One of the 1–9 buy or sell order keys: kept on a number with that side's own modifiers (`buyModifiers`,
    /// `sellModifiers`), pressed with any of its side's sets (`buyModifierSets`, `sellModifierSets`).
    func isNumberKey(_ key: Hotkey) -> Bool {
        guard let s = key.shortcut, OrderKeys.number(keyCode: s.keyCode) != nil else { return false }
        let m = ModifierSet(of: s)
        return m == buyModifiers || m == sellModifiers
    }

    /// The shortcuts that press `key`: a number key's with each of its side's modifier sets (none with none left),
    /// any other's its own.
    func triggers(of key: Hotkey) -> [KeyShortcut] {
        guard let s = key.shortcut else { return [] }
        guard isNumberKey(key), let digit = OrderKeys.number(keyCode: s.keyCode) else { return [s] }
        let sets = ModifierSet(of: s) == buyModifiers ? buyModifierSets : sellModifierSets
        return sets.map { $0.shortcut(digit: digit) }
    }

    /// The hotkey button `shortcut` presses (a keypad digit as the number row's), if any. One given an order key's
    /// shortcut overrides that order key while it has it: the order key is left as it is, so it works again once the
    /// button's shortcut changes or the button goes.
    func hotkeyOverriding(_ shortcut: KeyShortcut) -> Hotkey? {
        let pressed = shortcut.numberRow
        return hotkeys.first { $0.shortcut?.numberRow == pressed }
    }

    /// The order key `shortcut` presses, if any (a keypad digit as the number row's): a number with any of the
    /// buy or sell keys' modifier sets presses that side's order key on it (see `isNumberKey`).
    func orderKey(for shortcut: KeyShortcut) -> Hotkey? {
        let pressed = shortcut.numberRow
        if let digit = OrderKeys.number(keyCode: pressed.keyCode) {
            let m = ModifierSet(of: pressed)
            for (own, sets) in [(buyModifiers, buyModifierSets), (sellModifiers, sellModifierSets)] where sets.contains(m) {
                let s = own.shortcut(digit: digit)
                if let key = orderKeys.first(where: { $0.shortcut?.numberRow == s }) { return key }
            }
        }
        return orderKeys.first { !isNumberKey($0) && $0.shortcut?.numberRow == pressed }
    }
    /// KEYS ON: the order shortcuts (order keys, hotkeys' own, ⌘⇧↩, ⌘⌫) go to IB; off, SIM, they trade what-if
    /// positions (see `TradingShortcuts`). ⌘ and the Globe (fn) key switch it; Positions and the charts show both
    /// either way. Not saved: SIM at launch, or KEYS ON once IB's positions are in with a real one open.
    var orderShortcutsOn = false
    /// KEYS ON or SIM has been settled since launch, by IB's positions coming in or by ⌘🌐. Not saved.
    var launchModeChosen = false
    /// The hotkey ⌘A sends; picked by clicking a hotkey button.
    var selectedHotkeyID: UUID? {
        didSet { defaults.set(selectedHotkeyID?.uuidString, forKey: "selectedHotkey") }
    }
    var selectedHotkey: Hotkey? { hotkeys.first { $0.id == selectedHotkeyID } }
    /// The hotkey panel's order (see `OrderPad`). Saved.
    var orderPad = OrderPad() {
        didSet { defaults.set(try? JSONEncoder().encode(orderPad), forKey: OrderPad.storageKey) }
    }
    /// What ⌘⇧↩ sends: the selected hotkey button, or with none selected, the order pad's order.
    /// What ⌘⇧↩ sends: the selected hotkey button, or with none the order pad's order, bought; ⌥⌘⇧↩ (`selling`)
    /// sells the pad's order (a selected hotkey button sends its own either way).
    func activeHotkey(selling: Bool = false) -> Hotkey { selectedHotkey ?? orderPad.hotkey(selling ? .sell : .buy) }
    /// Scanner filters per list panel and scanner, keyed "panelId|scanner".
    var scanFilters: [String: ScannerFilter] { didSet { save() } }
    /// What-if buys by symbol.
    var whatIfs: [String: WhatIf] { didSet { save() } }
    /// The main charts that get tick-by-tick trades (⌘↩ toggles the selected one); four at first.
    /// The selected chart gets trades and bid/ask either way (see `TradingEngine.syncTickByTick`).
    var fastChartIDs: Set<Int> { didSet { save() } }
    /// System-wide shortcut that shows and hides the Charts window (see `ChartsWindowShortcut`).
    var chartsWindowShortcut: KeyShortcut? { didSet { save() } }
    /// The modifier keys of the 1–9 order keys: buying (⌘ by default) and selling (⌥⌘), see `setNumberModifiers`. Saved.
    var buyModifiers: ModifierSet = .buy { didSet { save() } }
    var sellModifiers: ModifierSet = .sell { didSet { save() } }
    /// The modifier sets that press the 1–9 buy / sell order keys, any of them (⌘ and Hyper both buying, say); none:
    /// the side's number keys don't work. Saved.
    var buyModifierSets: [ModifierSet] = [.buy] { didSet { save() } }
    var sellModifierSets: [ModifierSet] = [.sell] { didSet { save() } }
    /// One more shortcut for the top bar's Reset, as ⌘R / ⇧R / ⌥R / ⌃R / ⌘⇧R (Settings › Order Keys). Saved.
    var resetShortcut: KeyShortcut? { didSet { save() } }
    /// Main-window charts given a stock by hand (a list, a symbol field): they keep it and their cell
    /// instead of following the gainers, until Reset (see `ChartGrid`). Saved with their stock
    /// (see `mainGridPins`).
    var manualChartIDs: Set<Int> = []
    /// Charts window charts given a stock by hand (their symbol field), by chart id, with the cell each
    /// keeps: the gainers fill the other cells around them, until the top bar's Reset, an emptied field,
    /// or a smaller grid without that cell (see `SecondaryChartsView`).
    var secondaryPins: [Int: Int] = [:]
    /// The stock a main-window chart following the gainers showed when it was given one by hand, by chart
    /// id: it leaves the grid while that chart keeps its own stock, so no other chart moves (see
    /// `followGainers`). Reset, or the chart letting go, brings it back.
    var handDisplaced: [Int: String] = [:]
    /// The same for the Charts window's charts set by hand (see `secondaryPins`).
    var secondaryDisplaced: [Int: String] = [:]

    /// The stocks kept off the main grid: those the charts still set by hand replaced.
    var displacedGainers: Set<String> { Set(manualChartIDs.compactMap { handDisplaced[$0] }) }
    /// Round trips double-clicked in the Round trips tab, by symbol: their fills' arrows and entry / exit
    /// lines show on the symbol's charts until the row, or one of those charts, is double-clicked.
    var shownTrips: [String: String] = [:]
    /// Filled orders double-clicked in the Orders list, by symbol: their fills (exec ids), whose arrows
    /// and average fill price show on the symbol's charts in place of a shown round trip, until the
    /// row, or one of those charts, is double-clicked.
    var shownOrderFills: [String: Set<String>] = [:]
    /// What each list panel on screen shows, by panel id (the lists keep it up to date).
    var shownLists: [String: ScannerKind] = [:]
    /// Where the main grid last showed each stock, by symbol (see `GridPlace`, `notePlaces`). Saved.
    @ObservationIgnored var gridPlaces: [String: GridPlace] = [:] {
        didSet { defaults.set(try? JSONEncoder().encode(gridPlaces), forKey: GridPlace.storageKey) }
    }
    /// The places kept so far (see `GridPlace.kept`).
    @ObservationIgnored var placeKeeps = 0
    /// A double-click on a stock shown on another list, waiting for that list's rows (see `showChart`).
    @ObservationIgnored var pendingFocus: PendingFocus?

    struct PendingFocus {
        var symbol: String
        var place: GridPlace
        /// Given up after this, should the list's rows not come in.
        var until: Date
    }
    /// ⌘⇧ + a list's letter (see `ScannerKind.forShortcut`): the list to show and load into the chart grid,
    /// taken up by the list panels (see `ListPanel`). A new one each press, so the same key works again.
    var listShortcut: ListShortcut?

    struct ListShortcut: Equatable {
        var kind: ScannerKind
        var id = UUID()
    }
    /// Counts the account bar's Resets: every main-window chart follows the grid's list again, on the
    /// top bar's timeframe.
    var gainerResets = 0
    /// The list the main-window charts follow in place of the top gainers, from a list's load button
    /// or ⌘⇧ shortcut, until another list loads; Reset keeps it (nil: the gainers). Saved.
    var gridScan: ScanSpec? {
        didSet {
            defaults.set(gridScan.flatMap { try? JSONEncoder().encode($0) }, forKey: MainGrid.scanKey)
            // Each list keeps its own lit scale and zoom set by hand: the one left keeps them, the one
            // loaded gets its own back.
            let old = Self.listKey(oldValue), new = gridListKey
            guard old != new else { return }
            listScaleStates[old] = ListScaleState(activeScale: activeScale, manualZoom: manualZoom)
            let state = listScaleStates[new]
            activeScale = state?.activeScale.flatMap { chartScales[$0] != nil ? $0 : nil }
            manualZoom = state?.manualZoom
        }
    }
    /// The main grid's list, by which charts' views, the lit scale and the zoom set by hand are kept.
    var gridListKey: String { Self.listKey(gridScan) }
    static func listKey(_ scan: ScanSpec?) -> String { (scan?.kind ?? .gainers).rawValue }

    /// A list's lit scale and zoom set by hand while another list is loaded (see `gridScan`). Saved.
    struct ListScaleState: Codable {
        var activeScale: Int?
        var manualZoom: Double?
    }
    var listScaleStates: [String: ListScaleState] = [:] {
        didSet { defaults.set(try? JSONEncoder().encode(listScaleStates), forKey: "listScaleStates") }
    }
    /// The top bar's saved view sets by number (see `ViewSet`), and the one last saved or picked. Saved.
    var viewSets: [Int: ViewSet] = [:] {
        didSet { defaults.set(try? JSONEncoder().encode(viewSets), forKey: ViewSet.storageKey) }
    }
    var activeViewSet: Int? {
        didSet {
            defaults.set(activeViewSet, forKey: ViewSet.activeKey)
            if let activeViewSet { lastViewSet = activeViewSet }
        }
    }
    /// The view set last saved or picked, lit or not (`reapplyNumber` goes back to it).
    var lastViewSet: Int?
    /// The top bar's saved scales by number (see `ChartScale`). Saved.
    var chartScales: [Int: ChartScale] = [:] {
        didSet { defaults.set(try? JSONEncoder().encode(chartScales), forKey: ChartScale.storageKey) }
    }
    /// The scale last saved or picked, lit in the top bar: while it is, every main chart loading another
    /// stock takes it (see `Broker.gridScale`). Clicking it again, or Reset, turns it off. Saved.
    var activeScale: Int? {
        didSet {
            defaults.set(activeScale, forKey: ChartScale.activeKey)
            if let activeScale { lastScale = activeScale }
        }
    }
    /// The scale last saved or picked, lit or not (`reapplyNumber` goes back to it).
    var lastScale: Int?
    /// The top bar's Zoom slider as last moved by hand (dragged, or ⇧- / ⌘- / ⌥- / ⌃-swipe on a chart): it trumps the
    /// lit scale's zoom, on the charts now and on those loading another stock, until a scale is
    /// picked (its number clicked) or saved, or Reset. Saved.
    var manualZoom: Double? {
        didSet { defaults.set(manualZoom, forKey: ChartScale.manualZoomKey) }
    }
    /// The grid's zoom a swipe has just put the main charts at (see `zoomGrid`), so the Zoom slider
    /// following it doesn't zoom them again.
    @ObservationIgnored var swipedGridZoom: Double?
    /// Colors given to stocks with ⌥⇧ and a color's letter, by symbol (see `StockColor`). Saved, so a
    /// stock that leaves the charts has its color again when it comes back. Set with `setColor`.
    private(set) var stockColors: [String: StockColor] {
        didSet { defaults.set(stockColors.mapValues(\.rawValue), forKey: StockColor.storageKey) }
    }

    /// Horizontal trend lines' prices by symbol, ⌘-clicked on its charts (see `TrendLines`). Saved.
    var trendLines: [String: [Double]] {
        didSet { defaults.set(trendLines, forKey: TrendLines.storageKey) }
    }

    /// Gives `symbol` a color, or takes its color off (nil). A color marks one stock: the stock that
    /// had it before loses it, on the charts or not.
    func setColor(_ color: StockColor?, of symbol: String) {
        var colors = color.map { color in stockColors.filter { $0.value != color } } ?? stockColors
        colors[symbol] = color
        stockColors = colors
    }
    /// Saved layouts, in the order saved (see `Layouts`).
    var layouts: [SavedLayout] {
        didSet { defaults.set(try? JSONEncoder().encode(layouts), forKey: Layouts.storageKey) }
    }
    /// The Settings sheet is open (shown from the main window, so it stays open while the account bar
    /// moves between top and bottom).
    var showsSettings = false
    /// Counts layouts loaded, so views holding layout state of their own (the grid's lines) reload it.
    var layoutLoads = 0
    /// Settings a layout load just changed whose change handler should let it be once (see `loadLayout`).
    @ObservationIgnored var layoutSkips: Set<String> = []

    var selectedChart: ChartModel { chart(id: selectedChartID) ?? mainCharts[0] }

    /// A main-window chart.
    func chart(id: Int) -> ChartModel? {
        mainCharts.first { $0.id == id }
    }
    /// The symbol orders go to: the selected chart's, or "" with no chart selected (nothing is sent).
    var targetSymbol: String { isChartSelected ? selectedChart.symbol : "" }

    @ObservationIgnored private let defaults = UserDefaults.standard
    /// Symbol loads so far (see `ChartModel.loadOrder`).
    @ObservationIgnored private var loads = 0

    init() {
        // Main charts start empty and fill from the gainers scanner, but for those set by hand,
        // which come back in their cells with their stock.
        let mainTimeframe = defaults.string(forKey: MainGrid.timeframeKey).flatMap(Timeframe.init(rawValue:)) ?? .m1
        mainCharts = (0..<MainGrid.maxColumns * MainGrid.maxRows).map { i in
            ChartModel(id: i, symbol: "", timeframe: mainTimeframe)
        }
        let columns = MainGrid.columns(defaults.object(forKey: MainGrid.columnsKey) as? Int ?? 2)
        let rows = MainGrid.rows(defaults.object(forKey: MainGrid.rowsKey) as? Int ?? 2)
        mainColumns = columns
        mainCells = Array(0..<columns * rows)

        // Secondary charts start empty: the window fills them from the gainers scanner while it's
        // open and not paused, so nothing loads for them at launch.
        let secondaryTimeframe = defaults.string(forKey: SecondaryCharts.timeframeKey)
            .flatMap(Timeframe.init(rawValue:)) ?? .m1
        secondaryCharts = (0..<SecondaryCharts.count).map { i in
            ChartModel(id: ChartModel.chartsWindowFirstID + i, symbol: "", timeframe: secondaryTimeframe)
        }

        if let data = defaults.data(forKey: "hotkeys"),
           let keys = try? JSONDecoder().decode([Hotkey].self, from: data) {
            // A shortcut recorded before the app took it for itself (⌘⌫) is dropped: the hotkey's unassigned.
            hotkeys = keys.map { key in
                var key = key
                if key.shortcut?.reservedFor != nil { key.shortcut = nil }
                return key
            }
        } else {
            hotkeys = Hotkey.defaults
        }
        // Order keys saved before the $ / % switch: the number keys become the steps ones (see `OrderKeys.migrated`).
        let savedKeys = defaults.data(forKey: OrderKeys.storageKey).flatMap { try? JSONDecoder().decode([Hotkey].self, from: $0) }
        if let savedKeys, defaults.integer(forKey: OrderKeys.versionKey) < OrderKeys.version {
            let migrated = OrderKeys.migrated(savedKeys)
            orderKeys = migrated
            if let data = try? JSONEncoder().encode(migrated) { defaults.set(data, forKey: OrderKeys.storageKey) }
        } else {
            orderKeys = savedKeys ?? OrderKeys.defaults()
        }
        defaults.set(OrderKeys.version, forKey: OrderKeys.versionKey)

        selectedHotkeyID = defaults.string(forKey: "selectedHotkey").flatMap(UUID.init(uuidString:))
        orderPad = defaults.data(forKey: OrderPad.storageKey).flatMap { try? JSONDecoder().decode(OrderPad.self, from: $0) } ?? OrderPad()
        defaults.removeObject(forKey: "positionsShowSim")  // the old Positions header switch
        // The $ / % switch was the order pad's own before ⌘⇧M: it starts as the pad was.
        if defaults.string(forKey: SizeMode.storageKey) == nil {
            struct LegacyPad: Decodable { var buyingPower: Bool? }
            let percent = defaults.data(forKey: OrderPad.storageKey)
                .flatMap { try? JSONDecoder().decode(LegacyPad.self, from: $0) }?.buyingPower ?? true
            defaults.set((percent ? SizeMode.percent : .dollars).rawValue, forKey: SizeMode.storageKey)
        }

        if let data = defaults.data(forKey: "scanFilters"),
           let filters = try? JSONDecoder().decode([String: ScannerFilter].self, from: data) {
            scanFilters = filters
        } else {
            scanFilters = [:]
        }

        if let data = defaults.data(forKey: "whatIfs"),
           let saved = try? JSONDecoder().decode([String: WhatIf].self, from: data) {
            whatIfs = saved
        } else {
            whatIfs = [:]
        }

        fastChartIDs = Set(defaults.array(forKey: "fastChartIDs") as? [Int] ?? Array(0..<4))

        stockColors = (defaults.dictionary(forKey: StockColor.storageKey) as? [String: String] ?? [:])
            .compactMapValues(StockColor.init(rawValue:))
        trendLines = defaults.dictionary(forKey: TrendLines.storageKey) as? [String: [Double]] ?? [:]

        layouts = defaults.data(forKey: Layouts.storageKey)
            .flatMap { try? JSONDecoder().decode([SavedLayout].self, from: $0) } ?? []

        gridScan = defaults.data(forKey: MainGrid.scanKey).flatMap { try? JSONDecoder().decode(ScanSpec.self, from: $0) }
        chartScales = defaults.data(forKey: ChartScale.storageKey)
            .flatMap { try? JSONDecoder().decode([Int: ChartScale].self, from: $0) } ?? [:]
        activeScale = (defaults.object(forKey: ChartScale.activeKey) as? Int).flatMap { chartScales[$0] != nil ? $0 : nil }
        lastScale = activeScale
        manualZoom = defaults.object(forKey: ChartScale.manualZoomKey) as? Double
        viewSets = defaults.data(forKey: ViewSet.storageKey)
            .flatMap { try? JSONDecoder().decode([Int: ViewSet].self, from: $0) } ?? [:]
        activeViewSet = (defaults.object(forKey: ViewSet.activeKey) as? Int).flatMap { viewSets[$0] != nil ? $0 : nil }
        lastViewSet = activeViewSet
        gridPlaces = defaults.data(forKey: GridPlace.storageKey)
            .flatMap { try? JSONDecoder().decode([String: GridPlace].self, from: $0) } ?? [:]
        placeKeeps = gridPlaces.values.map(\.kept).max() ?? 0
        listScaleStates = defaults.data(forKey: "listScaleStates")
            .flatMap { try? JSONDecoder().decode([String: ListScaleState].self, from: $0) } ?? [:]

        chartsWindowShortcut = defaults.data(forKey: "chartsWindowShortcut")
            .flatMap { try? JSONDecoder().decode(KeyShortcut.self, from: $0) }
        resetShortcut = defaults.data(forKey: "resetShortcut")
            .flatMap { try? JSONDecoder().decode(KeyShortcut.self, from: $0) }
        buyModifiers = defaults.data(forKey: "buyModifiers").flatMap { try? JSONDecoder().decode(ModifierSet.self, from: $0) } ?? .buy
        sellModifiers = defaults.data(forKey: "sellModifiers").flatMap { try? JSONDecoder().decode(ModifierSet.self, from: $0) } ?? .sell
        buyModifierSets = defaults.data(forKey: "buyModifierSets").flatMap { try? JSONDecoder().decode([ModifierSet].self, from: $0) } ?? [buyModifiers]
        sellModifierSets = defaults.data(forKey: "sellModifierSets").flatMap { try? JSONDecoder().decode([ModifierSet].self, from: $0) } ?? [sellModifiers]

        let pins = defaults.data(forKey: MainGrid.pinsKey)
            .flatMap { try? JSONDecoder().decode([MainGridPin].self, from: $0) } ?? []
        for pin in pins where pin.column < columns && pin.row < rows {
            let chart = mainCharts[mainCells[pin.row * columns + pin.column]]
            chart.symbol = pin.symbol
            chart.timeframe = pin.timeframe
            countLoad(of: chart)
            manualChartIDs.insert(chart.id)
            handDisplaced[chart.id] = pin.displaced
        }
    }

    func scanFilter(panel: String, _ kind: ScannerKind) -> ScannerFilter {
        scanFilters["\(panel)|\(kind.rawValue)"] ?? kind.defaultFilter
    }

    func setScanFilter(_ filter: ScannerFilter, panel: String, _ kind: ScannerKind) {
        scanFilters["\(panel)|\(kind.rawValue)"] = filter
    }

    /// A chart is about to load a symbol: from now on it's the latest to show it.
    func countLoad(of chart: ChartModel) {
        loads += 1
        chart.loadOrder = loads
    }

    /// The charts set by hand, with their cell and stock.
    var mainGridPins: [MainGridPin] {
        mainCells.enumerated().compactMap { index, id in
            guard manualChartIDs.contains(id), let chart = chart(id: id), !chart.symbol.isEmpty else { return nil }
            return MainGridPin(column: index % mainColumns, row: index / mainColumns,
                               symbol: chart.symbol, timeframe: chart.timeframe, displaced: handDisplaced[id])
        }
    }

    func saveMainGridPins() {
        defaults.set(try? JSONEncoder().encode(mainGridPins), forKey: MainGrid.pinsKey)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(hotkeys) { defaults.set(data, forKey: "hotkeys") }
        if let data = try? JSONEncoder().encode(orderKeys) { defaults.set(data, forKey: OrderKeys.storageKey) }
        if let data = try? JSONEncoder().encode(scanFilters) { defaults.set(data, forKey: "scanFilters") }
        if let data = try? JSONEncoder().encode(whatIfs) { defaults.set(data, forKey: "whatIfs") }
        defaults.set(fastChartIDs.sorted(), forKey: "fastChartIDs")
        defaults.set(chartsWindowShortcut.flatMap { try? JSONEncoder().encode($0) }, forKey: "chartsWindowShortcut")
        defaults.set(resetShortcut.flatMap { try? JSONEncoder().encode($0) }, forKey: "resetShortcut")
        defaults.set(try? JSONEncoder().encode(buyModifiers), forKey: "buyModifiers")
        defaults.set(try? JSONEncoder().encode(sellModifiers), forKey: "sellModifiers")
        defaults.set(try? JSONEncoder().encode(buyModifierSets), forKey: "buyModifierSets")
        defaults.set(try? JSONEncoder().encode(sellModifierSets), forKey: "sellModifierSets")
    }
}
