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
    case blueOrange = "Blue / Orange"
    case cyanPink = "Cyan / Pink"
    case mono = "Monochrome"
    case custom = "Custom"
    var id: String { rawValue }

    static let storageKey = "candleTheme"
    static let customUpKey = "candleUpColor"
    static let customDownKey = "candleDownColor"
    static let defaultUpHex = "26A699"
    static let defaultDownHex = "F05450"

    /// Up and down colors; `.custom` uses the hex colors picked in Settings.
    func colors(customUp: String, customDown: String) -> (up: Color, down: Color) {
        switch self {
        case .teal: (Color(red: 0.15, green: 0.65, blue: 0.60), Color(red: 0.94, green: 0.33, blue: 0.31))
        case .classic: (Color(red: 0.20, green: 0.75, blue: 0.35), Color(red: 0.90, green: 0.22, blue: 0.22))
        case .blueOrange: (Color(red: 0.25, green: 0.55, blue: 0.95), Color(red: 0.98, green: 0.55, blue: 0.15))
        case .cyanPink: (Color(red: 0.20, green: 0.80, blue: 0.90), Color(red: 0.95, green: 0.35, blue: 0.65))
        case .mono: (Color(white: 0.90), Color(white: 0.45))
        case .custom: (Color(hex: customUp) ?? Color(hex: Self.defaultUpHex)!,
                       Color(hex: customDown) ?? Color(hex: Self.defaultDownHex)!)
        }
    }
}

/// Every stored Appearance setting. Add new keys here so Settings' "Reset to Defaults" covers them.
enum AppearanceDefaults {
    static let keys = [
        CandleTheme.storageKey, CandleTheme.customUpKey, CandleTheme.customDownKey,
        LineColors.lastPriceKey, LineColors.avgCostKey, LineColors.altClickKey, LineColors.hoverKey,
        LineColors.stopLossKey, LineColors.takeProfitKey, LineColors.ordersKey, LineColors.showLastPriceLineKey,
        SelectedOutline.widthKey, TimeframePickerStyle.storageKey,
        Indicators.vwapKey, Indicators.fastSMAKey, Indicators.slowSMAKey, Indicators.tradesKey, Indicators.lineWidthKey,
        PriceAxis.fontSizeKey, PriceAxis.labelSpacingKey, PriceAxis.lastPriceOpacityKey,
    ] + LineDashes.keys

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
    var id: String { rawValue }

    static let storageKey = "timeframePickerStyle"
}

/// Thickness of the accent outline around the selected chart.
enum SelectedOutline {
    static let widthKey = "selectedChartOutlineWidth"
    static let defaultWidth = 1.5
    static let range = 0.5...4.0
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

/// Whether ⌥-clicking a chart places orders, switched in the top bar. Not an Appearance setting, so
/// "Reset to Defaults" leaves it.
enum AltClickOrders {
    static let enabledKey = "altClickOrdersEnabled"
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
    /// Off hides the last price line itself; its price box on the axis stays.
    static let showLastPriceLineKey = "showLastPriceLine"
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
    static let keys = [lastPriceKey, avgCostKey, altClickKey, hoverKey, stopLossKey, takeProfitKey, ordersKey, lastTradeKey]

    static let defaultLastPrice = true
    static let defaultAvgCost = false
    static let defaultAltClick = false
    static let defaultHover = true
    static let defaultStopLoss = false
    static let defaultTakeProfit = false
    static let defaultOrders = true
    static let defaultLastTrade = true
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
