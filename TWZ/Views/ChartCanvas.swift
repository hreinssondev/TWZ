//
//  ChartCanvas.swift
//  TWZ
//
//  The charts drawn by an AppKit view rather than a SwiftUI Canvas. A Canvas redraws through SwiftUI's view update,
//  which for a full grid zooming on every frame cost about 3 ms a frame on its own, more than the drawing: too much
//  for a 240 Hz screen (4.2 ms a frame). This view redraws itself as soon as anything it drew from changes (the
//  chart's zoom and place, its bars, the prices: anything observable it read while drawing), with SwiftUI only
//  involved when the chart view itself changes (its lines, the hover, settings).
//

import AppKit
import Observation
import SwiftUI

/// What `CandleChart` draws with: the parts of SwiftUI's `GraphicsContext` it uses, on a Core Graphics context.
/// A copy keeps its own clip, as a `GraphicsContext` does.
struct ChartPainter {
    let cg: CGContext
    private var clips: [Path] = []

    init(_ cg: CGContext) { self.cg = cg }

    enum Shading {
        case color(Color)
        case linearGradient(Gradient, startPoint: CGPoint, endPoint: CGPoint)
    }

    mutating func clip(to path: Path) { clips.append(path) }

    func fill(_ path: Path, with shading: Shading) {
        inState {
            switch shading {
            case .color(let color):
                cg.addPath(path.cgPath)
                cg.setFillColor(Self.cgColor(color))
                cg.fillPath()
            case .linearGradient(let gradient, let start, let end):
                cg.addPath(path.cgPath)
                cg.clip()
                let colors = gradient.stops.map { Self.cgColor($0.color) } as CFArray
                var locations = gradient.stops.map { CGFloat($0.location) }
                if let made = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: &locations) {
                    cg.drawLinearGradient(made, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
                }
            }
        }
    }

    func stroke(_ path: Path, with shading: Shading, lineWidth: CGFloat = 1) {
        stroke(path, with: shading, style: StrokeStyle(lineWidth: lineWidth))
    }

    func stroke(_ path: Path, with shading: Shading, style: StrokeStyle) {
        guard case .color(let color) = shading else { return }
        inState {
            cg.addPath(path.cgPath)
            cg.setStrokeColor(Self.cgColor(color))
            cg.setLineWidth(style.lineWidth)
            cg.setLineCap(style.lineCap)
            cg.setLineJoin(style.lineJoin)
            cg.setMiterLimit(style.miterLimit)
            if !style.dash.isEmpty { cg.setLineDash(phase: style.dashPhase, lengths: style.dash) }
            cg.strokePath()
        }
    }

    /// Raw Core Graphics drawing inside this painter's clip.
    func withCGContext(content: (CGContext) -> Void) {
        inState { content(cg) }
    }

    private func inState(_ body: () -> Void) {
        cg.saveGState()
        for clip in clips {
            cg.addPath(clip.cgPath)
            cg.clip()
        }
        body()
        cg.restoreGState()
    }

    /// A SwiftUI color as the app's dark windows show it.
    private static func cgColor(_ color: Color) -> CGColor {
        NSColor(color).cgColor
    }
}

/// The AppKit view a chart draws into (see `CandleChart`). It takes no clicks: SwiftUI's gestures over it do.
struct ChartCanvas: NSViewRepresentable {
    let draw: (inout ChartPainter, CGSize) -> Void

    func makeNSView(context: Context) -> ChartCanvasView { ChartCanvasView() }

    func updateNSView(_ view: ChartCanvasView, context: Context) {
        view.drawChart = draw
        view.needsDisplay = true
    }
}

final class ChartCanvasView: NSView {
    var drawChart: ((inout ChartPainter, CGSize) -> Void)?
    private static let dark = NSAppearance(named: .darkAqua)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        // Rasterized off the main thread; the main thread only records what to draw.
        layer?.drawsAsynchronously = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let drawChart, let cg = NSGraphicsContext.current?.cgContext else { return }
        let started = FrameMeter.shared.chartBegan()
        let size = bounds.size
        // Anything observable read while drawing (the chart's zoom, place and bars, prices, fills) redraws it on change.
        withObservationTracking {
            let draw = {
                var painter = ChartPainter(cg)
                drawChart(&painter, size)
            }
            if let dark = Self.dark { dark.performAsCurrentDrawingAppearance(draw) } else { draw() }
        } onChange: { [weak self] in
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.needsDisplay = true }
            } else {
                DispatchQueue.main.async { self?.needsDisplay = true }
            }
        }
        FrameMeter.shared.chartEnded(started)
    }
}
