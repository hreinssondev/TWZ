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

    func fill(_ path: Path, with shading: Shading) { fill(path.cgPath, with: shading) }

    /// A rounded rectangle as a Core Graphics path (SwiftUI's builds slowly), its corners no rounder than it allows.
    static func roundedRect(_ rect: CGRect, radius: CGFloat) -> CGPath {
        let r = max(0, min(radius, rect.width / 2, rect.height / 2))
        guard rect.width > 0, rect.height > 0 else { return CGPath(rect: rect, transform: nil) }
        return CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
    }

    func fill(_ path: CGPath, with shading: Shading) {
        inState {
            switch shading {
            case .color(let color):
                cg.addPath(path)
                cg.setFillColor(Self.cgColor(color))
                cg.fillPath()
            case .linearGradient(let gradient, let start, let end):
                cg.addPath(path)
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
        stroke(path.cgPath, with: shading, style: StrokeStyle(lineWidth: lineWidth))
    }

    func stroke(_ path: Path, with shading: Shading, style: StrokeStyle) { stroke(path.cgPath, with: shading, style: style) }

    func stroke(_ path: CGPath, with shading: Shading, lineWidth: CGFloat = 1) {
        stroke(path, with: shading, style: StrokeStyle(lineWidth: lineWidth))
    }

    func stroke(_ path: CGPath, with shading: Shading, style: StrokeStyle) {
        guard case .color(let color) = shading else { return }
        inState {
            cg.addPath(path)
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

    /// A SwiftUI color as the app's dark windows show it, in sRGB; converted once each (a conversion looks up the
    /// color's HDR headroom in its color profile every time, which added up over a grid's worth of lines and boxes).
    private static var colors: [Color: CGColor] = [:]

    private static func cgColor(_ color: Color) -> CGColor {
        if let cached = colors[color] { return cached }
        if colors.count > 1_000 { colors.removeAll(keepingCapacity: true) }
        let ns = NSColor(color)
        let made = ns.usingColorSpace(.sRGB)?.cgColor ?? ns.cgColor
        colors[color] = made
        return made
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
    var drawChart: ((inout ChartPainter, CGSize) -> Void)? {
        get { chartLayer.drawChart }
        set { chartLayer.drawChart = newValue }
    }
    private let chartLayer = ChartLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        // Hosts a plain layer (set before `wantsLayer`): unlike a view's own layer it draws off the main thread and in
        // 8-bit color as asked (see `ChartLayer`).
        layer = chartLayer
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override var needsDisplay: Bool {
        get { super.needsDisplay }
        set {
            super.needsDisplay = newValue
            if newValue { chartLayer.setNeedsDisplay() }
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        chartLayer.contentsScale = window?.backingScaleFactor ?? 2
        chartLayer.setNeedsDisplay()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        chartLayer.setNeedsDisplay()
    }
}

/// The chart's layer: its drawing recorded on the main thread and rasterized on a background one, into 8-bit color
/// (a view's own layer on an HDR-capable screen draws in 16-bit floats, twice the memory to fill).
final class ChartLayer: CALayer {
    var drawChart: ((inout ChartPainter, CGSize) -> Void)?
    private static let dark = NSAppearance(named: .darkAqua)

    override init() {
        super.init()
        drawsAsynchronously = true
        contentsFormat = .RGBA8Uint
        isOpaque = false
        needsDisplayOnBoundsChange = true
        contentsScale = NSScreen.main?.backingScaleFactor ?? 2
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// No fades: new contents and sizes show at once.
    override func action(forKey event: String) -> (any CAAction)? { NSNull() }

    override func draw(in cg: CGContext) {
        guard let drawChart else { return }
        let started = FrameMeter.shared.chartBegan()
        let size = bounds.size
        // A layer's context runs bottom-up; the chart draws top-down.
        cg.translateBy(x: 0, y: size.height)
        cg.scaleBy(x: 1, y: -1)
        // Anything observable read while drawing (the chart's zoom, place and bars, prices, fills, settings) redraws
        // it on change.
        withObservationTracking {
            let draw = {
                var painter = ChartPainter(cg)
                drawChart(&painter, size)
            }
            if let dark = Self.dark { dark.performAsCurrentDrawingAppearance(draw) } else { draw() }
        } onChange: { [weak self] in
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.setNeedsDisplay() }
            } else {
                DispatchQueue.main.async { self?.setNeedsDisplay() }
            }
        }
        FrameMeter.shared.chartEnded(started)
    }
}

/// The settings a chart draws with, read once for every chart and read again only when a setting changes: a chart
/// drawn outside SwiftUI would otherwise read each from the defaults on every frame. Observable, so a chart redraws
/// when one changes.
@Observable
final class ChartSettings {
    static let shared = ChartSettings()

    struct Values: Equatable {
        var candleTheme: CandleTheme
        var customUp: String
        var customDown: String
        var hoverHex: String
        var lastPriceHex: String
        var lastPriceDashed: Bool
        var showLastPriceLine: Bool
        var showGrid: Bool
        var volumeOpacity: Double
        var hoverDashed: Bool
        var lastPriceDots: Bool
        var hoverDots: Bool
        var showVWAP: Bool
        var showFastSMA: Bool
        var showSlowSMA: Bool
        var showTrades: Bool
        var indicatorWidth: Double
        var axisFontSize: Double
        var labelSpacing: Double
        var lastPriceOpacity: Double
        var rightPaddingBars: Double

        static func read() -> Values {
            let d = UserDefaults.standard
            func bool(_ key: String, _ fallback: Bool) -> Bool { d.object(forKey: key) as? Bool ?? fallback }
            func double(_ key: String, _ fallback: Double) -> Double { d.object(forKey: key) as? Double ?? fallback }
            func string(_ key: String, _ fallback: String) -> String { d.string(forKey: key) ?? fallback }
            return Values(
                candleTheme: d.string(forKey: CandleTheme.storageKey).flatMap(CandleTheme.init(rawValue:)) ?? .teal,
                customUp: string(CandleTheme.customUpKey, CandleTheme.defaultUpHex),
                customDown: string(CandleTheme.customDownKey, CandleTheme.defaultDownHex),
                hoverHex: string(LineColors.hoverKey, ""),
                lastPriceHex: string(LineColors.lastPriceKey, ""),
                lastPriceDashed: bool(LineDashes.lastPriceKey, LineDashes.defaultLastPrice),
                showLastPriceLine: bool(LineColors.showLastPriceLineKey, true),
                showGrid: bool(LineColors.showGridKey, false),
                volumeOpacity: double(VolumeBars.opacityKey, VolumeBars.defaultOpacity),
                hoverDashed: bool(LineDashes.hoverKey, LineDashes.defaultHover),
                lastPriceDots: bool(LineDashes.dotsKey(LineDashes.lastPriceKey), LineDashes.defaultDots(LineDashes.lastPriceKey)),
                hoverDots: bool(LineDashes.dotsKey(LineDashes.hoverKey), LineDashes.defaultDots(LineDashes.hoverKey)),
                showVWAP: bool(Indicators.vwapKey, true),
                showFastSMA: bool(Indicators.fastSMAKey, true),
                showSlowSMA: bool(Indicators.slowSMAKey, true),
                showTrades: bool(Indicators.tradesKey, false),
                indicatorWidth: double(Indicators.lineWidthKey, Indicators.defaultLineWidth),
                axisFontSize: double(PriceAxis.fontSizeKey, PriceAxis.defaultFontSize),
                labelSpacing: double(PriceAxis.labelSpacingKey, PriceAxis.defaultLabelSpacing),
                lastPriceOpacity: double(PriceAxis.lastPriceOpacityKey, PriceAxis.defaultLastPriceOpacity),
                rightPaddingBars: double(RightSpace.key, RightSpace.defaultBars))
        }
    }

    private(set) var values = Values.read()
    @ObservationIgnored private var observer: (any NSObjectProtocol)?

    private init() {
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let new = Values.read()
                if new != self.values { self.values = new }
            }
        }
    }
}
