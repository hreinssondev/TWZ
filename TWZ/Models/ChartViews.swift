//
//  ChartViews.swift
//  TWZ
//
//  Where charts were left on each stock and timeframe: the zoom and the view's place (how far back
//  from the latest bar, moved and zoomed up or down), kept as a chart moves to another stock or
//  timeframe, and for every chart when the app quits. A chart of the same window coming back to that
//  stock and timeframe, whichever of its charts it is (switching lists and back, or after a relaunch),
//  picks up as it was left (see `Broker.loadChart`); a stock it wasn't left on keeps the chart's view
//  as it is (on another timeframe, the latest bars). Saved across relaunches; the top bar's Reset
//  forgets the main window's, and right-click or double-click on a chart puts that one back to the
//  default zoom at the latest bars, which is what's kept for it from then on.
//

import Foundation

struct ChartViews: Codable {
    struct Key: Hashable, Codable {
        var bars: BarCache.Key
        var inChartsWindow: Bool
    }

    struct View: Codable {
        /// Bars on screen.
        var zoom: Double?
        var place: ChartModel.Place
        var kept: Int
        /// Adjusted by hand: it beats a lit scale (see `ChartModel.adjustedByHand`).
        var manual: Bool?
    }

    /// Views kept at most; past that, the one kept longest ago goes.
    static let capacity = 1000
    static let storageKey = "chartViews"

    private var views: [Key: View] = [:]
    private var keeps = 0

    mutating func keep(zoom: Double, place: ChartModel.Place, manual: Bool, for key: Key) {
        guard !key.bars.symbol.isEmpty else { return }
        keeps += 1
        views[key] = View(zoom: zoom, place: place, kept: keeps, manual: manual ? true : nil)
        if views.count > Self.capacity, let oldest = views.min(by: { $0.value.kept < $1.value.kept })?.key {
            views[oldest] = nil
        }
    }

    func view(for key: Key) -> View? { views[key] }

    /// A click on a scale's number: no view of the window counts as adjusted by hand any more.
    mutating func forgetManual(inChartsWindow: Bool) {
        for key in views.keys where key.inChartsWindow == inChartsWindow { views[key]?.manual = nil }
    }

    /// Reset: the window's charts start over at the latest bars.
    mutating func forget(inChartsWindow: Bool) {
        views = views.filter { $0.key.inChartsWindow != inChartsWindow }
    }

    static func saved() -> ChartViews {
        UserDefaults.standard.data(forKey: storageKey).flatMap { try? JSONDecoder().decode(ChartViews.self, from: $0) } ?? ChartViews()
    }

    func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: Self.storageKey)
    }
}
