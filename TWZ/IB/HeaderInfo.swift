//
//  HeaderInfo.swift
//  TWZ
//
//  What a chart's header shows apart from live prices (see `ChartHeaderInfo`), worked out in one place so a
//  header can be drawn from a copy (Settings › Appearance › Performance): from its stock's own box, which
//  changes only with that stock (`headerBox`), or from one taken once (the Charts window's frozen headers).
//

import Foundation
import Observation

/// A chart header's values for one stock: its position and what-if trade, tick-by-tick state, shortability
/// and the buying and short selling power, as text.
struct HeaderInfo: Equatable {
    struct Power: Equatable {
        var text: String
        var help: String
    }

    var position: Position?
    /// Orders that opened or added to the open round trip.
    var openTripOrders = 0
    var sim: SimPosition?
    var tickLimited = false
    var tradesStreaming = false
    var shortable: Double?
    var longPower: Power?
    var shortPower: Power?
}

/// One stock's header values, observed on their own.
@Observable
final class HeaderInfoBox {
    var info: HeaderInfo
    init(_ info: HeaderInfo) { self.info = info }
}

extension Broker {
    /// `symbol`'s header values from the broker's state. Read in a view's body, it makes the view observe
    /// every stock's fills, positions and margin; `headerBox` doesn't.
    func headerInfo(_ symbol: String, fills symbolFills: [Fill]? = nil) -> HeaderInfo {
        var info = HeaderInfo()
        guard !symbol.isEmpty else { return info }
        if let p = positions[symbol] {
            info.position = p
            let fills = symbolFills ?? self.fills.values.filter { $0.symbol == symbol }
            info.openTripOrders = RoundTrip.build(fills: fills, positions: positions).first(where: \.isOpen)?.orderCount ?? 0
        }
        info.sim = simPositions[symbol]
        info.tickLimited = tickLimitedSymbols.contains(symbol)
        info.tradesStreaming = tickTradeSymbols.contains(symbol)
        info.shortable = shortability[symbol]
        info.longPower = power(symbol, .long)
        info.shortPower = power(symbol, .short)
        return info
    }

    /// The most a new long (buying power) or short (short selling power) can be worth in NOK now (see
    /// `marginPowerNOK`); none against the position: no buying power while short, nor short selling power while long.
    private func power(_ symbol: String, _ side: MarginSide) -> HeaderInfo.Power? {
        let held = positions[symbol]?.quantity ?? 0
        guard side == .long ? held >= 0 : held <= 0, let nok = marginPowerNOK(symbol, side),
              let shares = maxNewShares(symbol, side), let size = marginSize(symbol, side) else { return nil }
        let units = ForexPair(symbol).map { " \($0.base)" } ?? " shares"
        let lendLimited = side == .short && shares < (size.maxShares ?? 0)
        let text = Fmt.nok(nok, groupedFrom: 0)
        return HeaderInfo.Power(
            text: text,
            help: (side == .long ? "Buying power: IB's margin allows a long" : "Short selling power: IB's margin allows a short")
                + " of up to \(Fmt.shares(shares))\(units)\(lendLimited ? " (the shares IB has to lend)" : "") "
                + "at \(Fmt.price(size.price, for: symbol)), \(text) NOK (asked again each minute, and after a position changes)")
    }

    /// `symbol`'s header values, kept current by `refreshHeaderBoxes`: a view reading its `info` redraws only
    /// when they change.
    func headerBox(_ symbol: String) -> HeaderInfoBox {
        if let box = headerBoxes[symbol] { return box }
        let box = HeaderInfoBox(headerInfo(symbol))
        headerBoxes[symbol] = box
        return box
    }

    /// Brings every box up to date, assigning only those whose values changed; boxes of stocks no longer
    /// charted are dropped (made again when needed).
    func refreshHeaderBoxes() {
        guard !headerBoxes.isEmpty else { return }
        let charted = chartedSymbols
        let fillsBySymbol = Dictionary(grouping: fills.values, by: \.symbol)
        for (symbol, box) in headerBoxes {
            guard charted.contains(symbol) else {
                headerBoxes[symbol] = nil
                continue
            }
            let info = headerInfo(symbol, fills: fillsBySymbol[symbol] ?? [])
            if box.info != info { box.info = info }
        }
    }
}
