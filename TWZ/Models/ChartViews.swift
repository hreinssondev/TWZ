//
//  ChartViews.swift
//  TWZ
//
//  Where charts were left on each stock and timeframe: the zoom and the view's place (how far back
//  from the latest bar, moved and zoomed up or down), kept as a chart moves to another stock or
//  timeframe. A chart of the same window coming back to that stock and timeframe, whichever of its
//  charts it is (switching lists and back, say), picks up as it was left (see `Broker.loadChart`).
//  A window's Zoom slider drops its zooms, Reset all of it.
//

struct ChartViews {
    struct Key: Hashable {
        var bars: BarCache.Key
        var inChartsWindow: Bool
    }

    struct View {
        /// Bars on screen; nil once the window's Zoom slider set every chart's zoom.
        var zoom: Double?
        var place: ChartModel.Place
        var kept: Int
    }

    /// Views kept at most; past that, the one kept longest ago goes.
    static let capacity = 1000

    private var views: [Key: View] = [:]
    private var keeps = 0

    mutating func keep(zoom: Double, place: ChartModel.Place, for key: Key) {
        guard !key.bars.symbol.isEmpty else { return }
        keeps += 1
        views[key] = View(zoom: zoom, place: place, kept: keeps)
        if views.count > Self.capacity, let oldest = views.min(by: { $0.value.kept < $1.value.kept })?.key {
            views[oldest] = nil
        }
    }

    func view(for key: Key) -> View? { views[key] }

    /// The window's Zoom slider set its charts' zoom: their places stay.
    mutating func forgetZooms(inChartsWindow: Bool) {
        for key in views.keys where key.inChartsWindow == inChartsWindow { views[key]?.zoom = nil }
    }

    /// Reset: the window's charts start over at the latest bars.
    mutating func forget(inChartsWindow: Bool) {
        views = views.filter { $0.key.inChartsWindow != inChartsWindow }
    }
}
