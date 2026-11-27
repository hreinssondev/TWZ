//
//  Appearance.swift
//  TWZ
//
//  Candle color themes, persisted via @AppStorage so charts redraw as soon as they change.
//

import SwiftUI
import AppKit

enum CandleTheme: String, CaseIterable, Identifiable {
    case teal = "Teal / Coral"
    case classic = "Green / Red"
    case spring = "Spring Green / Cherry"
    case emerald = "Emerald / Crimson"
    case lime = "Lime / Scarlet"
    case mint = "Mint / Rose"
    case forest = "Forest / Brick"
    case neon = "Neon Green / Neon Red"
    case olive = "Olive / Maroon"
    case pastel = "Pastel Green / Salmon"
    // Chart themes: the candles and the chart's own background, grid and labels (see `ChartScene`).
    case synthwave = "Synthwave"
    case terminal = "Retro Terminal"
    case deepSea = "Deep Sea"
    case volcano = "Volcano"
    case bubblegum = "Bubblegum"
    case aurora = "Northern Lights"
    case sunset = "Tropical Sunset"
    case casino = "Casino Night"
    case neonCity = "Neon City"
    case iceCream = "Ice Cream"
    var id: String { rawValue }

    /// The themes with only candle colors (⌃⇧1–9, 0), and the chart themes (⌃⇧Q–P).
    static var candleOnly: [CandleTheme] { allCases.filter { $0.scene == nil } }
    static var chartThemes: [CandleTheme] { allCases.filter { $0.scene != nil } }

    /// The top letter row, Q to P, by key code (where the keys sit, whatever the keyboard layout).
    private static let letterRow: [(keyCode: UInt16, letter: String)] = [
        (12, "Q"), (13, "W"), (14, "E"), (15, "R"), (17, "T"), (16, "Y"), (32, "U"), (34, "I"), (31, "O"), (35, "P"),
    ]

    /// ⌃⇧1–9 picks the candle themes in Settings' order, ⌃⇧0 the tenth; ⌃⇧Q … P the chart themes.
    static func forShortcut(keyCode: UInt16) -> CandleTheme? {
        if let i = letterRow.firstIndex(where: { $0.keyCode == keyCode }) {
            return i < chartThemes.count ? chartThemes[i] : nil
        }
        let n = keyCode == 29 || keyCode == 82 ? 10 : OrderKeys.number(keyCode: keyCode)
        guard let n, n <= candleOnly.count else { return nil }
        return candleOnly[n - 1]
    }

    /// "⌃⇧1" … "⌃⇧9", "⌃⇧0"; "⌃⇧Q" … "⌃⇧P".
    var shortcut: String {
        if let i = Self.chartThemes.firstIndex(of: self) { return "⌃⇧" + Self.letterRow[i].letter }
        let n = (Self.candleOnly.firstIndex(of: self) ?? 0) + 1
        return "⌃⇧\(n == 10 ? 0 : n)"
    }

    /// A chart theme's background (top to bottom), grid and label colors; nil keeps the app's own.
    var scene: ChartScene? {
        switch self {
        case .synthwave: ChartScene(top: 0x241047, bottom: 0x0B0420, grid: 0xB967FF, label: 0xC9B6FF)
        case .terminal: ChartScene(top: 0x04140B, bottom: 0x000000, grid: 0x33FF66, label: 0x7FD99A)
        case .deepSea: ChartScene(top: 0x0A2A47, bottom: 0x020C18, grid: 0x4FC3F7, label: 0x9CCFE8)
        case .volcano: ChartScene(top: 0x2A0E06, bottom: 0x0A0302, grid: 0xFF7043, label: 0xE0A890)
        case .bubblegum: ChartScene(top: 0x3A1840, bottom: 0x1A0820, grid: 0xFF9AD5, label: 0xF2C4E6)
        case .aurora: ChartScene(top: 0x0B2233, bottom: 0x050A14, grid: 0x6BFFB8, label: 0xA8D8D0)
        case .sunset: ChartScene(top: 0x3B1450, bottom: 0x140A24, grid: 0xFF9E64, label: 0xFFC6A8)
        case .casino: ChartScene(top: 0x0F4A2E, bottom: 0x05200F, grid: 0xFFD700, label: 0xD8C98A)
        case .neonCity: ChartScene(top: 0x10101F, bottom: 0x05050C, grid: 0x00F0FF, label: 0x8FE9F2)
        case .iceCream: ChartScene(top: 0x3A2620, bottom: 0x1E1310, grid: 0xF5E1C8, label: 0xE8D2BC)
        default: nil
        }
    }

    static let storageKey = "candleTheme"
    static let customUpKey = "candleUpColor"
    static let customDownKey = "candleDownColor"
    static let defaultUpHex = "26A699"
    static let defaultDownHex = "F05450"

    /// Up and down colors (the custom ones are no longer picked: kept for the saved presets' keys).
    func colors(customUp: String, customDown: String) -> (up: Color, down: Color) {
        switch self {
        case .teal: (Color(red: 0.15, green: 0.65, blue: 0.60), Color(red: 0.94, green: 0.33, blue: 0.31))
        case .classic: (Color(red: 0.20, green: 0.75, blue: 0.35), Color(red: 0.90, green: 0.22, blue: 0.22))
        case .spring: (Color(red: 0.30, green: 0.95, blue: 0.55), Color(red: 0.85, green: 0.05, blue: 0.15))
        case .emerald: (Color(red: 0.00, green: 0.62, blue: 0.40), Color(red: 0.82, green: 0.10, blue: 0.22))
        case .lime: (Color(red: 0.55, green: 0.86, blue: 0.20), Color(red: 1.00, green: 0.22, blue: 0.14))
        case .mint: (Color(red: 0.45, green: 0.86, blue: 0.66), Color(red: 0.96, green: 0.46, blue: 0.52))
        case .forest: (Color(red: 0.14, green: 0.52, blue: 0.27), Color(red: 0.72, green: 0.24, blue: 0.18))
        case .neon: (Color(red: 0.00, green: 1.00, blue: 0.45), Color(red: 1.00, green: 0.10, blue: 0.32))
        case .olive: (Color(red: 0.50, green: 0.62, blue: 0.15), Color(red: 0.58, green: 0.10, blue: 0.13))
        case .pastel: (Color(red: 0.66, green: 0.90, blue: 0.56), Color(red: 0.98, green: 0.55, blue: 0.45))
        case .synthwave: (Color(rgb: 0x00F0FF), Color(rgb: 0xFF2E97))
        case .terminal: (Color(rgb: 0x33FF66), Color(rgb: 0xFFB000))
        case .deepSea: (Color(rgb: 0x3DF5D0), Color(rgb: 0xFF7A6B))
        case .volcano: (Color(rgb: 0xFFD54A), Color(rgb: 0xFF3D00))
        case .bubblegum: (Color(rgb: 0x7CFFCB), Color(rgb: 0xFF6EC7))
        case .aurora: (Color(rgb: 0x6BFFB8), Color(rgb: 0xD58BFF))
        case .sunset: (Color(rgb: 0xFFD166), Color(rgb: 0xFF4F79))
        case .casino: (Color(rgb: 0xFFD700), Color(rgb: 0xFF3B3B))
        case .neonCity: (Color(rgb: 0xFCEE0A), Color(rgb: 0xFF003C))
        case .iceCream: (Color(rgb: 0xA8F0DC), Color(rgb: 0xFFA8C5))
        }
    }
}

/// A chart theme's look behind the candles: a top-to-bottom background, the grid lines' color (shown only with
/// Settings' grid lines on) and the price and time labels'.
struct ChartScene {
    let top: Color
    let bottom: Color
    let grid: Color
    let label: Color

    init(top: UInt32, bottom: UInt32, grid: UInt32, label: UInt32) {
        self.top = Color(rgb: top)
        self.bottom = Color(rgb: bottom)
        self.grid = Color(rgb: grid)
        self.label = Color(rgb: label)
    }

    var background: Gradient { Gradient(colors: [top, bottom]) }
}

/// Buy / sell, long / short and gain / loss colors outside the candles (lists, Orders / Positions /
/// Round trips, P/L, position badges, fill bars, trade arrows, buy / sell lines), from Settings' App
/// colors: the candles' up and down colors (the default), plain green and red, or colors of their own.
struct SideColors: Equatable {
    enum Source: String, CaseIterable, Identifiable {
        case candles = "Candle colors"
        case greenRed = "Green / Red"
        case custom = "Own colors"
        var id: String { rawValue }
    }

    static let sourceKey = "sideColorsSource"
    /// "RRGGBB" for `.custom`; empty until picked, which shows the candle color.
    static let customUpKey = "sideColorsUp"
    static let customDownKey = "sideColorsDown"

    var up: Color = .green
    var down: Color = .red

    func of(_ isUp: Bool) -> Color { isUp ? up : down }
}

private struct SideColorsKey: EnvironmentKey {
    static let defaultValue = SideColors()
}

extension EnvironmentValues {
    var sideColors: SideColors {
        get { self[SideColorsKey.self] }
        set { self[SideColorsKey.self] = newValue }
    }
}

/// Gives a window's views the side colors Settings picks.
struct SideColorsFromSettings: ViewModifier {
    @AppStorage(SideColors.sourceKey) private var source: SideColors.Source = .candles
    @AppStorage(SideColors.customUpKey) private var sideUp = ""
    @AppStorage(SideColors.customDownKey) private var sideDown = ""
    @AppStorage(CandleTheme.storageKey) private var theme: CandleTheme = .teal
    @AppStorage(CandleTheme.customUpKey) private var customUp = CandleTheme.defaultUpHex
    @AppStorage(CandleTheme.customDownKey) private var customDown = CandleTheme.defaultDownHex

    func body(content: Content) -> some View {
        let candles = theme.colors(customUp: customUp, customDown: customDown)
        let colors = switch source {
        case .candles: SideColors(up: candles.up, down: candles.down)
        case .greenRed: SideColors()
        case .custom: SideColors(up: Color(hex: sideUp) ?? candles.up, down: Color(hex: sideDown) ?? candles.down)
        }
        content.environment(\.sideColors, colors)
    }
}

/// Settings › Appearance › App colors: the windows' background, "RRGGBB"; empty is the system's dark gray.
enum AppBackground {
    static let key = "appBackgroundColor"

    /// The system's dark gray, as it is in the app's dark windows (for the swatch and the color panel to start at).
    static var defaultColor: Color {
        var color = NSColor.windowBackgroundColor
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
            color = NSColor.windowBackgroundColor.usingColorSpace(.sRGB) ?? color
        }
        return Color(nsColor: color)
    }
}

private struct AppBackgroundKey: EnvironmentKey {
    static let defaultValue = Color(nsColor: .windowBackgroundColor)
}

extension EnvironmentValues {
    /// The windows' background (see `AppBackground`), for what floats over the window to match it.
    var appBackground: Color {
        get { self[AppBackgroundKey.self] }
        set { self[AppBackgroundKey.self] = newValue }
    }
}

/// Gives a window the background Settings picks, and its views the color.
struct AppBackgroundFromSettings: ViewModifier {
    @AppStorage(AppBackground.key) private var hex = ""

    func body(content: Content) -> some View {
        let color = Color(hex: hex)
        content
            .background(WindowBackground(color: color.map { NSColor($0) }))
            .environment(\.appBackground, color ?? Color(nsColor: .windowBackgroundColor))
    }
}

/// Sets its window's background color; nil puts the system's back.
private struct WindowBackground: NSViewRepresentable {
    let color: NSColor?

    final class Passthrough: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override var mouseDownCanMoveWindow: Bool { true }
    }

    func makeNSView(context: Context) -> NSView { Passthrough() }

    func updateNSView(_ view: NSView, context: Context) {
        // The window isn't there yet on the first pass.
        DispatchQueue.main.async {
            view.window?.backgroundColor = color ?? .windowBackgroundColor
        }
    }
}

/// Settings › Appearance's timeframe switch: on (the default), a chart switching timeframe keeps its view,
/// only the candles change; off, each timeframe keeps its own zoom and place to go back to (see
/// `Broker.loadChart`).
enum TimeframeSwitch {
    static let keepViewKey = "keepViewOnTimeframeSwitch"
    static let defaultKeepView = true

    static var keepsView: Bool { UserDefaults.standard.object(forKey: keepViewKey) as? Bool ?? defaultKeepView }
}

/// What the order numbers are, switched with ⌘⇧M or the order pad's $ and % buttons: dollars, $1,000 a step
/// (1–9 are $1,000–$9,000), or a percent of the buying power IB's margin allows in the stock, 20% a step up to
/// 80% (1–4 are 20%, 40%, 60%, 80%; 5–9 have no size and send nothing). The order pad's numbers, and the
/// order keys and hotkeys sized in steps (by default ⌘1–9 buys, ⌥⌘1–9 sells), go by it; the top bar's KEYS badge
/// shows it, KEYS $ or KEYS %. Saved.
nonisolated enum SizeMode: String {
    case dollars, percent
    static let storageKey = "sizeMode"
    /// The most steps there are of the buying power (4 × 20% = 80%).
    static let maxPercentSteps = 4.0

    static var current: SizeMode {
        UserDefaults.standard.string(forKey: storageKey).flatMap(SizeMode.init(rawValue:)) ?? .percent
    }

    /// `steps` in this mode: dollars, or a percent of the buying power; nil past 80%.
    func amount(steps: Double) -> Double? {
        guard steps > 0 else { return nil }
        if self == .dollars { return steps * 1_000 }
        return steps <= Self.maxPercentSteps ? steps * 20 : nil
    }

    /// "$3,000", "60%", or "—" with no size.
    func text(steps: Double) -> String {
        guard let amount = amount(steps: steps) else { return "—" }
        let n = amount.formatted(.number.precision(.fractionLength(0...2)))
        return self == .dollars ? "$" + n : n + "%"
    }

    /// The badge's sign: "$" or "%".
    var sign: String { self == .dollars ? "$" : "%" }
}

/// Settings › Appearance: what the top bar's number buttons hold. Off (the default), view sets: every
/// chart's zoom and place on every timeframe (see `ViewSet`); on, scales: one chart's view, given to
/// every chart (see `ChartScale`).
enum NumberButtons {
    static let scalesKey = "numberButtonsAreScales"
    static let defaultScales = false

    static var areScales: Bool { UserDefaults.standard.object(forKey: scalesKey) as? Bool ?? defaultScales }
}

/// Settings › Appearance: on (the default), moving the grid's zoom (⇧-, ⌘- or ⌥-swipe, the Zoom slider) puts charts
/// adjusted by hand at that zoom too, like the rest; off, they zoom in or out by as much, from their own
/// zoom (see `Workspace.setZoom`).
enum GridZoom {
    static let resetsAdjustedKey = "gridZoomResetsAdjusted"
    static let defaultResetsAdjusted = true

    static var resetsAdjusted: Bool {
        UserDefaults.standard.object(forKey: resetsAdjustedKey) as? Bool ?? defaultResetsAdjusted
    }
}

/// Settings › Appearance › Chart views: on (the default), a chart's view moved by hand (dragged, swiped, pinched,
/// ⌃-scaled or reset) moves every other chart in its window alike, as ⌥0 does (see `Workspace.matchViews`);
/// the other window's charts stay as they are; with ⇧, ⌘ or ⌥ held (a swipe begun with them, Swiping on), only that
/// chart moves. Off, only that chart moves.
enum ViewSync {
    static let key = "viewSyncInWindow"
    static let defaultOn = true
}

/// Settings › Appearance › Swiping: off (the default), a trackpad swipe pans and zooms the chart under the
/// pointer and ⇧-, ⌘- or ⌥-swipe zooms every chart (the grid's zoom); on, the other way round (see
/// `ScrollCatcher`). The mouse wheel and ⌃-swipe stay as they are.
enum Swiping {
    static let zoomsAllKey = "swipeZoomsAllCharts"
    static let defaultZoomsAll = false

    static var zoomsAll: Bool { UserDefaults.standard.object(forKey: zoomsAllKey) as? Bool ?? defaultZoomsAll }

    /// A trackpad swipe that goes sideways only pans from then on, until the fingers lift (and through its momentum).
    static let locksPanKey = "swipeLocksPan"
    static let defaultLocksPan = false

    static var locksPan: Bool { UserDefaults.standard.object(forKey: locksPanKey) as? Bool ?? defaultLocksPan }
}

/// Settings › Appearance › Performance: three ways the chart headers do less work, each on by default; all
/// three off is how the headers worked before (see `ChartHeaderInfo`).
enum HeaderPerformance {
    /// The Charts window's headers are drawn once (again a few seconds later, as their data comes in) and
    /// then only while the chart is selected or has a position or what-if trade open.
    static let freezeKey = "headersFrozenInChartsWindow"
    /// A header measures its width once and builds the one layout that fits, rather than trying each.
    static let layoutKey = "headerLayoutByWidth"
    /// A header redraws only for changes in its own stock, not in any stock's fills, positions or margin.
    static let perStockKey = "headerRedrawsPerStock"
    static let defaultOn = true
}

/// Every stored Appearance setting. Add new keys here so Settings' "Reset to Defaults" covers them.
enum AppearanceDefaults {
    static let keys = [
        CandleTheme.storageKey, CandleTheme.customUpKey, CandleTheme.customDownKey, AppBackground.key,
        LineColors.lastPriceKey, LineColors.avgCostKey, LineColors.altClickKey, LineColors.hoverKey,
        LineColors.stopLossKey, LineColors.takeProfitKey, LineColors.ordersKey, LineColors.closedTradeKey,
        LineColors.trendKey, TrendLines.widthKey, TrendLines.priceBoxKey, LineColors.showLastPriceLineKey,
        LineColors.showLastTradeLinesKey, LineColors.showGridKey, VolumeBars.opacityKey,
        SideColors.sourceKey, SideColors.customUpKey, SideColors.customDownKey, Dimmed.opacityKey,
        SelectedOutline.widthKey, TimeframePickerStyle.storageKey, AccountBarPosition.storageKey,
        Indicators.vwapKey, Indicators.fastSMAKey, Indicators.slowSMAKey, Indicators.tradesKey, Indicators.lineWidthKey,
        PriceAxis.fontSizeKey, PriceAxis.labelSpacingKey, PriceAxis.lastPriceOpacityKey,
        TimeframeSwitch.keepViewKey, GridZoom.resetsAdjustedKey, NumberButtons.scalesKey,
        HeaderPerformance.freezeKey, HeaderPerformance.layoutKey, HeaderPerformance.perStockKey,
        Swiping.zoomsAllKey, Swiping.locksPanKey, ViewSync.key, ZoomAnchor.keepsLatestKey,
    ] + LineDashes.keys + LineDashes.dotsKeys

    /// Removing the stored values makes every @AppStorage fall back to its default.
    static func reset() {
        keys.forEach(UserDefaults.standard.removeObject(forKey:))
    }
}

/// Five slots, each a saved snapshot of every Appearance setting (the keys in AppearanceDefaults).
enum AppearancePresets {
    static let slots = 1...5

    static func key(_ slot: Int) -> String { "appearancePreset\(slot)" }

    /// The current settings saved into `slot`; only values changed from their defaults are stored.
    static func save(_ slot: Int) {
        var values: [String: Any] = [:]
        for k in AppearanceDefaults.keys {
            if let v = UserDefaults.standard.object(forKey: k) { values[k] = v }
        }
        guard let data = try? PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0) else { return }
        UserDefaults.standard.set(data, forKey: key(slot))
    }

    /// Applies `slot`'s settings; anything the preset doesn't hold goes back to its default.
    static func load(_ slot: Int) {
        guard let data = UserDefaults.standard.data(forKey: key(slot)),
              let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return }
        for k in AppearanceDefaults.keys {
            if let v = values[k] {
                UserDefaults.standard.set(v, forKey: k)
            } else {
                UserDefaults.standard.removeObject(forKey: k)
            }
        }
    }

    /// The first time presets exist, the settings in use become preset 1.
    static func seedIfNeeded() {
        if UserDefaults.standard.data(forKey: key(1)) == nil { save(1) }
    }
}

/// How each chart's timeframe switch looks: quiet monochrome labels (default) or the system segmented control.
enum TimeframePickerStyle: String, CaseIterable, Identifiable {
    case segmented = "Segmented"
    case minimal = "Minimal"
    /// Always the "15m ⌄" menu, however wide the chart (other styles turn into it only when there's no room).
    case menu = "Menu"
    var id: String { rawValue }

    static let storageKey = "timeframePickerStyle"
    static let defaultStyle: TimeframePickerStyle = .menu

    /// Once: the menu on every chart, whatever style was set before (Settings can pick another again).
    static func switchToMenuOnce() {
        let defaults = UserDefaults.standard, done = "timeframePickerStyleMenuOnce"
        guard !defaults.bool(forKey: done) else { return }
        defaults.set(TimeframePickerStyle.menu.rawValue, forKey: storageKey)
        defaults.set(true, forKey: done)
    }
}

/// Where the account bar sits: at the top, in the title bar beside the window buttons (default), or at
/// the very bottom of the window, with the window buttons hidden (⌘W, ⌘M and ⌃⌘F still work).
enum AccountBarPosition: String, CaseIterable, Identifiable {
    case top = "Top"
    case bottom = "Bottom"
    var id: String { rawValue }

    static let storageKey = "accountBarPosition"
}

/// Thickness of the outline around the selected chart, stored as a third of it: the line a stock with
/// a color is outlined in while not selected (see `StockColor`). Settings' slider shows the selected one.
enum SelectedOutline {
    static let widthKey = "selectedChartOutlineWidth"
    static let defaultWidth = 1.5
    static let range = 0.5...4.0
    /// The selected chart's outline, in the accent color or the stock's, is this many times the stored width.
    static let selectedMultiple = 3.0
}

/// Which indicator lines the charts draw, and how thick.
enum Indicators {
    static let vwapKey = "showVWAP"
    static let fastSMAKey = "showSMA9"
    static let slowSMAKey = "showSMA21"
    /// Arrows at the day's fills: green ▲ under buys, red ▼ over sells.
    static let tradesKey = "showTrades"
    static let lineWidthKey = "indicatorLineWidth"
    static let defaultLineWidth = 1.25
    static let lineWidthRange = 0.5...4.0
}

/// What the chart's hover P/L sizes its pretend trade at the last price by, with no position or what-if
/// open: a percent of the largest long IB's margin allows (above the last price) or short (below it), or the
/// shares a NOK amount buys.
enum HoverPnLSize: String, CaseIterable, Identifiable {
    case buyingPower = "Buying power"
    case nok = "NOK amount"

    var id: String { rawValue }

    static let storageKey = "hoverPnLSize"
    static let percentKey = "hoverPnLBuyingPowerPercent"
    static let defaultPercent = 80.0
    static let amountKey = "hoverPnLAmountNOK"
    static let defaultAmount = 50_000.0

    /// The buying power share, 1–100%.
    static var fraction: Double {
        let percent = UserDefaults.standard.object(forKey: percentKey) as? Double ?? defaultPercent
        return min(100, max(1, percent)) / 100
    }
}

/// How faint the right-hand panels draw what's done or partial: filled orders, round trips and their
/// header, a list's recent change while its window isn't full yet.
enum Dimmed {
    static let opacityKey = "dimmedOpacity"
    static let defaultOpacity = 0.45
    static let opacityRange = 0.1...1.0
}

/// The volume bars along the bottom of each chart, in the candles' colors at this opacity (0 hides them).
enum VolumeBars {
    static let opacityKey = "volumeBarOpacity"
    static let defaultOpacity = 0.35
    static let opacityRange = 0.0...1.0
}

/// The price axis: label size, how closely labels are packed, and the last price box's opacity.
enum PriceAxis {
    static let fontSizeKey = "axisPriceFontSize"
    static let defaultFontSize = 10.0
    static let fontSizeRange = 8.0...16.0
    /// Target points between price labels; less space means more, finer-stepped labels.
    static let labelSpacingKey = "axisPriceLabelSpacing"
    static let defaultLabelSpacing = 45.0
    static let labelSpacingRange = 20.0...120.0
    static let lastPriceOpacityKey = "lastPriceBoxOpacity"
    static let defaultLastPriceOpacity = 1.0
    static let lastPriceOpacityRange = 0.1...1.0

    /// At the slider's minimum the box is gone: just the price.
    static func hidesLastPriceBox(_ opacity: Double) -> Bool {
        opacity <= lastPriceOpacityRange.lowerBound + 1e-9
    }
}

/// Chart line colors picked in Settings, stored as "RRGGBB"; empty means the default.
enum LineColors {
    static let lastPriceKey = "lastPriceLineColor"
    static let avgCostKey = "avgCostLineColor"
    static let altClickKey = "altClickOrderColor"
    static let hoverKey = "hoverPriceColor"
    static let stopLossKey = "stopLossLineColor"
    static let takeProfitKey = "takeProfitLineColor"
    static let ordersKey = "orderLineColor"
    /// The exit line a chart shows once its symbol's round trip closes; empty means the
    /// side colors' down color.
    static let closedTradeKey = "closedTradeLineColor"
    /// Off hides the last price line itself; its price box on the axis stays.
    static let showLastPriceLineKey = "showLastPriceLine"
    /// Off: of the Exit / Avg lines a chart shows once its symbol's round trip closes, just the exit
    /// line, for 7 s.
    static let showLastTradeLinesKey = "showLastTradeLines"
    /// On shows the chart's grid lines (off by default; the price and time labels show either way).
    static let showGridKey = "showChartGridLines"
    /// ⌘⇧-click trend lines (see `TrendLines`).
    static let trendKey = "trendLineColor"
    static let defaultTrend = Color(white: 0.4)
    static let defaultLastPrice = Color(red: 0.30, green: 0.50, blue: 0.95)
    static let defaultAvgCost = Color.blue
    static let defaultAltClick = Color.white
    static let defaultHover = Color.gray
    static let defaultStopLoss = Color.red
    static let defaultTakeProfit = Color.green
    static let defaultOrders = Color.orange

    static func resolve(_ hex: String, default fallback: Color) -> Color {
        Color(hex: hex) ?? fallback
    }
}

/// Horizontal trend lines: ⌘⇧-click a chart for one at that price, double-click it to remove it. Kept per
/// stock (see `Workspace.trendLines`), drawn on intraday charts from where today starts (the previous day's end) to
/// the axis, on daily ones across the chart, in Settings' color, style and width. The price reaching one alerts
/// (see `Broker.checkTrendAlerts`).
enum TrendLines {
    static let storageKey = "trendLines"
    static let widthKey = "trendLineWidth"
    static let defaultWidth = 0.5
    static let widthRange = 0.25...3.0
    /// On: a sound, a message and a notification when a stock's price reaches one of its trend lines.
    static let alertKey = "trendLineAlerts"
    static let defaultAlert = true
    /// After an alert, the line alerts again once the price has moved this share of it away (0.5%).
    static let rearmShare = 0.005
    /// The price in a box on the axis.
    static let priceBoxKey = "trendLinePriceBox"
    static let defaultPriceBox = true
    /// Stand in for order ids on the lines (below the what-if and SIM ones), so double-clicking one removes it.
    static func lineId(_ index: Int) -> Int { -100 - index }
    static func index(ofLineId id: Int) -> Int? { id <= -100 ? -100 - id : nil }
}

/// Whether each chart line is dashed (true) or solid, picked in Settings.
enum LineDashes {
    static let lastPriceKey = "lastPriceLineDashed"
    static let avgCostKey = "avgCostLineDashed"
    static let altClickKey = "altClickLineDashed"
    static let hoverKey = "hoverLineDashed"
    static let stopLossKey = "stopLossLineDashed"
    static let takeProfitKey = "takeProfitLineDashed"
    static let ordersKey = "orderLineDashed"
    static let lastTradeKey = "lastTradeLineDashed"
    static let trendKey = "trendLineDashed"
    static let keys = [lastPriceKey, avgCostKey, altClickKey, hoverKey, stopLossKey, takeProfitKey, ordersKey, lastTradeKey, trendKey]

    static let defaultLastPrice = true
    static let defaultAvgCost = false
    static let defaultAltClick = false
    static let defaultHover = true
    static let defaultStopLoss = false
    static let defaultTakeProfit = false
    static let defaultOrders = true
    static let defaultLastTrade = true
    static let defaultTrend = false

    /// Whether a dashed line is drawn in small dots rather than longer dashes, stored beside its
    /// dashed key; unset, the line's default below.
    static func dotsKey(_ dashedKey: String) -> String { dashedKey + "Dots" }
    static var dotsKeys: [String] { keys.map(dotsKey) }
    static func defaultDots(_ dashedKey: String) -> Bool {
        [avgCostKey, altClickKey, stopLossKey, takeProfitKey, ordersKey, lastTradeKey].contains(dashedKey)
    }
}

/// Preset colors a hotkey button can use instead of its action's default.
nonisolated enum HotkeyColor: String, Codable, CaseIterable, Identifiable {
    case green, red, orange, yellow, mint, teal, blue, indigo, purple, pink, brown, gray
    var id: String { rawValue }

    var color: Color {
        switch self {
        case .green: .green
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .mint: .mint
        case .teal: .teal
        case .blue: .blue
        case .indigo: .indigo
        case .purple: .purple
        case .pink: .pink
        case .brown: .brown
        case .gray: .gray
        }
    }
}

extension Color {
    /// 0xRRGGBB.
    init(rgb v: UInt32) {
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    /// "RRGGBB" (with or without "#").
    init?(hex: String) {
        let s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    /// Light enough to need dark text on it.
    var isLight: Bool {
        guard let c = NSColor(self).usingColorSpace(.sRGB) else { return false }
        return 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent > 0.7
    }

    var hex: String {
        guard let c = NSColor(self).usingColorSpace(.sRGB) else { return "000000" }
        func byte(_ x: CGFloat) -> Int { Int((min(1, max(0, x)) * 255).rounded()) }
        return String(format: "%02X%02X%02X", byte(c.redComponent), byte(c.greenComponent), byte(c.blueComponent))
    }
}
