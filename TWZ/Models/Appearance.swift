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
        SelectedOutline.widthKey, TimeframePickerStyle.storageKey, TopBar.positionColorKey,
        Indicators.vwapKey, Indicators.fastSMAKey, Indicators.slowSMAKey, Indicators.lineWidthKey,
    ]

    /// Removing the stored values makes every @AppStorage fall back to its default.
    static func reset() {
        keys.forEach(UserDefaults.standard.removeObject(forKey:))
    }
}

/// How each chart's timeframe switch looks: quiet monochrome labels (default) or the system segmented control.
enum TimeframePickerStyle: String, CaseIterable, Identifiable {
    case segmented = "Segmented"
    case minimal = "Minimal"
    var id: String { rawValue }

    static let storageKey = "timeframePickerStyle"
}

/// Tint of a chart's top bar while a position is open in its symbol, stored as "RRGGBB"; empty means the default.
enum TopBar {
    static let positionColorKey = "positionTopBarColor"
    static let defaultPositionColor = Color.green
    /// Applied over the picked color so the symbol and timeframe labels stay readable.
    static let opacity = 0.35
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
    static let lineWidthKey = "indicatorLineWidth"
    static let defaultLineWidth = 1.25
    static let lineWidthRange = 0.5...4.0
}

/// Chart line colors picked in Settings, stored as "RRGGBB"; empty means the default.
enum LineColors {
    static let lastPriceKey = "lastPriceLineColor"
    static let avgCostKey = "avgCostLineColor"
    static let altClickKey = "altClickOrderColor"
    static let hoverKey = "hoverPriceColor"
    static let defaultLastPrice = Color(red: 0.30, green: 0.50, blue: 0.95)
    static let defaultAvgCost = Color.blue
    static let defaultAltClick = Color.purple
    static let defaultHover = Color.gray

    static func resolve(_ hex: String, default fallback: Color) -> Color {
        Color(hex: hex) ?? fallback
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
    /// "RRGGBB" (with or without "#").
    init?(hex: String) {
        let s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    var hex: String {
        guard let c = NSColor(self).usingColorSpace(.sRGB) else { return "000000" }
        func byte(_ x: CGFloat) -> Int { Int((min(1, max(0, x)) * 255).rounded()) }
        return String(format: "%02X%02X%02X", byte(c.redComponent), byte(c.greenComponent), byte(c.blueComponent))
    }
}
