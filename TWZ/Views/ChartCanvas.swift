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
    /// The frame's GPU shapes (see `MetalCharts`): the bulk calls below go there when it's set.
    let gpu: GPUBatch?
    private var clips: [Path] = []
    /// The clips' bounds, the GPU's clip.
    private var clipRect: CGRect?

    init(_ cg: CGContext, gpu: GPUBatch? = nil) {
        self.cg = cg
        self.gpu = gpu
    }

    // MARK: The bulk of a chart: on the GPU when there's one, else Core Graphics.

    func fillRects(_ rects: [CGRect], color: Color) {
        guard !rects.isEmpty else { return }
        if let gpu {
            let c = GPUBatch.rgba(color)
            gpu.add(rects: rects, top: c, bottom: c, clip: clipRect)
            return
        }
        let path = CGMutablePath()
        path.addRects(rects)
        inState {
            cg.addPath(path)
            cg.setFillColor(Self.cgColor(color))
            cg.fillPath()
        }
    }

    /// A rectangle shaded from `top` to `bottom`.
    func fillVerticalGradient(_ rect: CGRect, top: Color, bottom: Color) {
        if let gpu {
            gpu.add(rects: [rect], top: GPUBatch.rgba(top), bottom: GPUBatch.rgba(bottom), clip: clipRect)
            return
        }
        fill(Path(rect), with: .linearGradient(Gradient(colors: [top, bottom]),
                                               startPoint: CGPoint(x: rect.minX, y: rect.minY), endPoint: CGPoint(x: rect.minX, y: rect.maxY)))
    }

    /// Straight lines, cut square at their ends.
    func strokeSegments(_ segments: [(CGPoint, CGPoint)], color: Color, width: CGFloat) {
        guard !segments.isEmpty else { return }
        if let gpu {
            gpu.add(segments: segments, color: GPUBatch.rgba(color), width: width, clip: clipRect)
            return
        }
        let path = CGMutablePath()
        for (a, b) in segments {
            path.move(to: a)
            path.addLine(to: b)
        }
        inState {
            cg.addPath(path)
            cg.setStrokeColor(Self.cgColor(color))
            cg.setLineWidth(width)
            cg.strokePath()
        }
    }

    // MARK: Everything else: Core Graphics.

    enum Shading {
        case color(Color)
        case linearGradient(Gradient, startPoint: CGPoint, endPoint: CGPoint)
    }

    mutating func clip(to path: Path) {
        clips.append(path)
        let bounds = path.boundingRect
        clipRect = clipRect.map { $0.intersection(bounds) } ?? bounds
    }

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
    private let container = ChartContainerLayer()
    /// The GPU's layer, under the chart's Core Graphics one (none without Metal).
    private let metalLayer: ChartMetalLayer? = MetalCharts.shared.map { metal in
        let layer = ChartMetalLayer()
        metal.configure(layer)
        return layer
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        // Hosts plain layers (set before `wantsLayer`): the GPU's, and over it one that, unlike a view's own layer,
        // draws off the main thread and in 8-bit color as asked (see `ChartLayer`).
        if let metalLayer { container.addSublayer(metalLayer) }
        container.addSublayer(chartLayer)
        chartLayer.metalLayer = metalLayer
        layer = container
        wantsLayer = true
    }

    override func layout() {
        super.layout()
        container.setNeedsLayout()
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
        let scale = window?.backingScaleFactor ?? 2
        chartLayer.contentsScale = scale
        metalLayer?.contentsScale = scale
        chartLayer.setNeedsDisplay()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        container.setNeedsLayout()
        chartLayer.setNeedsDisplay()
    }
}

/// Holds the chart's two layers, each the size of the view.
final class ChartContainerLayer: CALayer {
    override func action(forKey event: String) -> (any CAAction)? { NSNull() }

    override func layoutSublayers() {
        super.layoutSublayers()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for sublayer in sublayers ?? [] where sublayer.frame != bounds { sublayer.frame = bounds }
        CATransaction.commit()
    }
}

/// The chart's layer: its drawing recorded on the main thread and rasterized on a background one, into 8-bit color
/// (a view's own layer on an HDR-capable screen draws in 16-bit floats, twice the memory to fill).
final class ChartLayer: CALayer {
    var drawChart: ((inout ChartPainter, CGSize) -> Void)?
    /// The GPU's layer under this one: the bulk of the chart goes there (see `MetalCharts`).
    weak var metalLayer: CAMetalLayer?
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
        // The chart draws top-down. Hosted by a flipped view the layer is flipped already (its context runs top-down);
        // otherwise a layer's context runs bottom-up.
        if !contentsAreFlipped() {
            cg.translateBy(x: 0, y: size.height)
            cg.scaleBy(x: 1, y: -1)
        }
        // Anything observable read while drawing (the chart's zoom, place and bars, prices, fills, settings) redraws
        // it on change.
        let batch = metalLayer != nil ? GPUBatch() : nil
        withObservationTracking {
            let draw = {
                var painter = ChartPainter(cg, gpu: batch)
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
        if let batch, let metalLayer {
            MetalCharts.shared?.render(batch, into: metalLayer, size: size, scale: metalLayer.contentsScale)
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
