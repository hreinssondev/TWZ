//
//  StockColors.swift
//  TWZ
//
//  Colors given to stocks from the keyboard: ⌥⇧ and a color's letter colors the selected chart's
//  stock, ⌥⇧⌫ takes its color off (see `TradingShortcuts`). Every chart showing the stock is
//  outlined in its color, as thick as the selection outline in its place while it's selected, a third
//  of that otherwise.
//  One stock per color: giving a color to another stock takes it from the first. Kept per stock, also
//  while it's off the charts and across relaunches.
//

import SwiftUI

nonisolated enum StockColor: String, CaseIterable, Sendable {
    case red, green, blue, yellow, orange, purple, magenta, white, khaki, pink, brown, turquoise

    static let storageKey = "stockColors"

    /// The letter giving it with ⌥⇧: its first, but for pink's I, brown's N and turquoise's F
    /// (B is blue's, P purple's).
    var key: String {
        switch self {
        case .pink: "i"
        case .brown: "n"
        case .turquoise: "f"
        default: String(rawValue.prefix(1))
        }
    }

    /// The color whose letter is `key` (lowercase).
    init?(key: String) {
        guard let color = Self.allCases.first(where: { $0.key == key }) else { return nil }
        self = color
    }

    var color: Color {
        switch self {
        case .red: .red
        case .green: .green
        case .blue: .blue
        case .yellow: .yellow
        case .orange: .orange
        case .purple: .purple
        case .magenta: Color(red: 1, green: 0, blue: 1)
        case .white: .white
        case .khaki: Color(red: 0.76, green: 0.69, blue: 0.57)
        case .pink: Color(red: 1, green: 0.6, blue: 0.8)
        case .brown: Color(red: 0.6, green: 0.4, blue: 0.2)
        case .turquoise: Color(red: 0.25, green: 0.88, blue: 0.82)
        }
    }
}
