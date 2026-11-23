//
//  MenuBarPnL.swift
//  TWZ
//
//  The P/L in the menu bar, as a bare number in NOK: green above zero, red below. The real positions'
//  (open P/L at the last price, as the Positions column sums them); with none open, the what-if
//  trades' (see `SimTrades.swift`); 0 with neither. Updated every second; a click brings TWZ to the front.
//

import AppKit

@MainActor
final class MenuBarPnL: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private weak var broker: Broker?
    private var timer: Timer?

    init(broker: Broker) {
        self.broker = broker
        super.init()
        statusItem.button?.target = self
        statusItem.button?.action = #selector(showApp)
        update()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
    }

    @objc private func showApp() {
        NSApp.activate()
        NSApp.windows.first { $0.isVisible && $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
    }

    private func update() {
        guard let broker, let button = statusItem.button else { return }
        let real = broker.positions.values.filter { $0.quantity != 0 }
        let pnl: Double?, help: String
        if !real.isEmpty {
            pnl = Self.sum(real.map { p in
                broker.quote(p.symbol)?.last.flatMap { last in
                    broker.usdPerPriceUnit(p.symbol).flatMap { usd in broker.usdNok.map { (last - p.avgCost) * p.quantity * usd * $0 } }
                }
            })
            help = "P/L of the \(real.count) open position\(real.count == 1 ? "" : "s"), NOK"
        } else if !broker.simPositions.isEmpty {
            pnl = Self.sum(broker.simPositions.values.map { sim in broker.quote(sim.symbol)?.last.flatMap { broker.simPnLNOK(sim, at: $0) } })
            help = "SIM: P/L of the \(broker.simPositions.count) what-if trade\(broker.simPositions.count == 1 ? "" : "s"), NOK"
        } else {
            pnl = 0
            help = "No positions or what-if trades open"
        }
        let text = pnl.map { Fmt.nok($0, signed: true, groupedFrom: 0) } ?? "—"
        let rounded = (pnl ?? 0).rounded()
        let color: NSColor = rounded > 0 ? .systemGreen : rounded < 0 ? .systemRed : .secondaryLabelColor
        let title = NSAttributedString(string: text, attributes: [
            .foregroundColor: color,
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium),
        ])
        if button.attributedTitle != title { button.attributedTitle = title }
        if button.toolTip != help { button.toolTip = help }
    }

    /// nil while any of them has no quote (or rate) yet, so a partial sum never shows.
    private static func sum(_ values: [Double?]) -> Double? {
        values.reduce(Optional(0.0)) { total, v in total.flatMap { t in v.map { t + $0 } } }
    }
}
