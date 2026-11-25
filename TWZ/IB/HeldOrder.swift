//
//  HeldOrder.swift
//  TWZ
//
//  ⇧ with a buy or sell shortcut (an order key's or a hotkey's own, see `TradingShortcuts`): the order is built
//  as it would be sent, size and price included, but held instead. Its chart shows it as a position at its
//  price (a line in the held color, hover P/L as if it had filled) and Positions lists it on top; the Send
//  order popup sends it as shown with ↩ (in SIM, KEYS off: a what-if trade of that size) or drops it with Esc.
//  Another ⇧ order replaces it.
//

import Foundation

nonisolated struct HeldOrder: Equatable, Sendable, Identifiable {
    var id = UUID()
    var symbol: String
    var action: String
    var quantity: Double
    /// nil: a market order.
    var limit: Double?
    /// A stop-limit's trigger.
    var stop: Double?
    /// IB's order type in place of the one `limit` / `stop` imply (MIDPRICE).
    var orderType: String?
    var tif: TimeInForce
    var outsideRth: Bool
    var exchange: String
    /// The quote it was priced off when there was no live one.
    var fallback: String?
    var summary: String?
    var source: String
    var why: String
    /// Where it shows: its limit, or a market order's ask (buy) / bid (sell) when it was held.
    var price: Double
    /// Held in SIM (KEYS off): ↩ makes it a what-if trade (see `Broker.sendHeld`).
    var sim = false
    /// The hotkey it came from, sized (a what-if trade is priced by it when sent).
    var hotkey: Hotkey
    var held = Date()

    /// Stands in for an order id on its chart line, so clicking the line drops it.
    static let lineId = -4

    var isBuy: Bool { action == "BUY" }
    var signedQuantity: Double { isBuy ? quantity : -quantity }

    /// P/L if it filled at `price` and closed at `exit`, in its price's currency.
    func pnl(at exit: Double) -> Double { (exit - price) * signedQuantity }

    /// "LMT", "MKT", "STP LMT" or "MIDPRICE".
    var typeLabel: String { orderType ?? (limit == nil ? "MKT" : stop != nil ? "STP LMT" : "LMT") }
}
