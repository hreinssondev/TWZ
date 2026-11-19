//
//  StockColors.swift
//  TWZ
//
//  Colors given to stocks from the keyboard: ⌘⇧ and a color's letter colors the selected chart's
//  stock, ⌘⇧⌫ takes its color off (see `TradingShortcuts`). Every chart showing the stock is
//  outlined in its color, as thick as the selection outline in its place while it's selected, a third
//  of that otherwise.
//  Kept per stock across relaunches.
//

import SwiftUI

nonisolated enum StockColor: String, CaseIterable, Sendable {
    case red, green, blue, yellow, orange, purple, magenta, white, black, pink

    static let storageKey = "stockColors"

    /// The letter giving it with ⌘⇧: its first, but for black's K and pink's I (B is blue's, P purple's).
    var key: String {
        switch self {
        case .black: "k"
        case .pink: "i"
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
        case .black: .black
        case .pink: Color(red: 1, green: 0.6, blue: 0.8)
        }
    }
}
