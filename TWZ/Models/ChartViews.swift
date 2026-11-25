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
//  forgets the main window's on the top bar's timeframe, and right-click or double-click on a chart puts that one back to the
//  default zoom at the latest bars, which is what's kept for it from then on.
//  In the main grid each list keeps its own (see `Key.list`): a stock with none kept in the list switched to starts at
//  the default view (the Zoom slider's, at the latest bars, or the list's lit scale), not the view of the list left.
//

import Foundation

/// What one of the top bar's numbers holds with Settings' "Top bar numbers are scales" off: every main
/// chart's zoom and place on every timeframe, as they were when saved (⇧-click), put back when picked:
/// the views kept per stock, timeframe and list (see `ChartViews`), each chart's own one included, and
/// each chart's zoom per timeframe (`ChartModel.zooms`).
struct ViewSet: Codable {
    var views: [ChartViews.Key: ChartViews.View]
    var zooms: [Int: [Timeframe: Double]]

    static let storageKey = "viewSets"
    static let activeKey = "activeViewSet"
}

struct ChartViews: Codable {
    struct Key: Hashable, Codable {
        var bars: BarCache.Key
        var inChartsWindow: Bool
        /// The main grid's list it was left in (see `Workspace.gridListKey`): each list keeps its own.
        /// nil in the Charts window, and for views kept before lists kept their own.
        var list: String?
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

    /// The view kept for `key`, or one kept for its stock and timeframe before lists kept their own.
    func view(for key: Key) -> View? {
        views[key] ?? (key.list == nil ? nil : views[Key(bars: key.bars, inChartsWindow: key.inChartsWindow, list: nil)])
    }

    /// A click on a scale's number: no view of the window's `list` counts as adjusted by hand any more.
    mutating func forgetManual(inChartsWindow: Bool, list: String?) {
        for key in views.keys where key.inChartsWindow == inChartsWindow && (key.list == list || key.list == nil) {
            views[key]?.manual = nil
        }
    }

    /// Reset: the window's charts start over at the latest bars, on `timeframe` only if given.
    mutating func forget(inChartsWindow: Bool, timeframe: Timeframe? = nil) {
        views = views.filter { key, _ in
            key.inChartsWindow != inChartsWindow || (timeframe.map { key.bars.timeframe != $0 } ?? false)
        }
    }

    /// The window's views (a view set's, see `ViewSet`).
    func entries(inChartsWindow: Bool) -> [Key: View] {
        views.filter { $0.key.inChartsWindow == inChartsWindow }
    }

    /// The window's views become `entries` (picking a view set).
    mutating func replace(inChartsWindow: Bool, with entries: [Key: View]) {
        views = views.filter { $0.key.inChartsWindow != inChartsWindow }.merging(entries) { _, new in new }
    }

    static func saved() -> ChartViews {
        UserDefaults.standard.data(forKey: storageKey).flatMap { try? JSONDecoder().decode(ChartViews.self, from: $0) } ?? ChartViews()
    }

    func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: Self.storageKey)
    }
}
