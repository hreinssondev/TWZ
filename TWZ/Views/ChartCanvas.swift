//
//  ChartCanvas.swift
//  TWZ
//
//  The view a chart is shown in, the painter it's drawn with and the settings it's drawn from. The drawing itself
//  is done off the main thread, every chart at once (see `ChartRenderer`).
//

import AppKit
import Observation
import SwiftUI

/// What `CandleChart` draws with: the parts of SwiftUI's `GraphicsContext` it uses, on a Core Graphics context.
/// A copy keeps its own clip, as a `GraphicsContext` does.
nonisolated struct ChartPainter {
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

    /// A SwiftUI color as the app's dark windows show it, in sRGB; converted once each (a conversion looks up the
    /// color's HDR headroom in its color profile every time, which added up over a grid's worth of lines and boxes).
    /// Charts draw on several threads at once (see `ChartRenderLoop`).
    nonisolated(unsafe) private static var colors: [Color: CGColor] = [:]
    private static let colorsLock = NSLock()

    private static func cgColor(_ color: Color) -> CGColor {
        if let cached = colorsLock.withLock({ colors[color] }) { return cached }
        let ns = NSColor(color)
        let made = ns.usingColorSpace(.sRGB)?.cgColor ?? ns.cgColor
        colorsLock.withLock {
            if colors.count > 1_000 { colors.removeAll(keepingCapacity: true) }
            colors[color] = made
        }
        return made
    }
}

/// The AppKit view a chart is shown in (see `CandleChart`). It takes no clicks: SwiftUI's gestures over it do.
struct ChartCanvas: NSViewRepresentable {
    /// The chart's frame at this size, copied on the main thread (see `ChartFrame`).
    let frame: (CGSize) -> ChartFrame?

    func makeNSView(context: Context) -> ChartCanvasView { ChartCanvasView() }

    func updateNSView(_ view: ChartCanvasView, context: Context) {
        view.makeFrame = frame
        view.setNeedsRender()
    }
}

/// Shows a chart drawn by its window's `ChartRenderLoop`: its layer's contents are the last surface drawn. It
/// draws again as soon as anything it drew from changes (the chart's zoom and place, its bars, the prices: anything
/// observable read while copying its frame), with SwiftUI only involved when the chart view itself changes (its
/// lines, the hover, settings).
final class ChartCanvasView: NSView {
    var makeFrame: ((CGSize) -> ChartFrame?)?
    /// Up to three: one shown, one drawing, one spare for when the window server still holds the one shown before.
    private var surfaces: [ChartSurface] = []
    private var shown: ChartSurface?

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer = CALayer()
        wantsLayer = true
        layer?.isOpaque = false
        layer?.contentsGravity = .topLeft
        layer?.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {}

    func setNeedsRender() {
        guard let window else { return }
        ChartRenderLoop.of(window).setNeedsRender(self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        setNeedsRender()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        setNeedsRender()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        setNeedsRender()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        setNeedsRender()
    }

    /// At the render loop's tick: this chart's frame copied, with a surface to draw it into; nil while there's
    /// nothing to show (out of a window, hidden, no size) or no surface free yet (then it tries again next tick).
    func prepareRender() -> ChartRenderJob? {
        guard let window, let makeFrame, !isHiddenOrHasHiddenAncestor else { return nil }
        let size = bounds.size
        let scale = window.backingScaleFactor
        let width = Int((size.width * scale).rounded(.up)), height = Int((size.height * scale).rounded(.up))
        guard width > 0, height > 0 else { return nil }
        if surfaces.first.map({ $0.pixelWidth != width || $0.pixelHeight != height }) == true {
            surfaces.removeAll { $0 !== shown && !$0.busy }
        }
        let target = surfaces.first { $0 !== shown && !$0.busy && !$0.surface.isInUse
                                      && $0.pixelWidth == width && $0.pixelHeight == height }
            ?? (surfaces.count < 3 ? ChartSurface(pixelWidth: width, pixelHeight: height).map { surfaces.append($0); return $0 } : nil)
        guard let target else {
            DispatchQueue.main.async { [weak self] in self?.setNeedsRender() }
            return nil
        }
        // Anything observable read while copying (the chart's zoom, place and bars, prices, fills, settings) draws it
        // again on change.
        var frame: ChartFrame?
        withObservationTracking {
            frame = makeFrame(size)
        } onChange: { [weak self] in
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.setNeedsRender() }
            } else {
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.setNeedsRender() } }
            }
        }
        guard let frame else { return nil }
        target.busy = true
        guard let layer else { return nil }
        return ChartRenderJob(frame: frame, size: size, scale: scale, target: target, layer: layer)
    }

    /// The job's surface shown (by the render loop, from its thread).
    func presented(_ job: ChartRenderJob) {
        job.target.busy = false
        shown = job.target
        surfaces.removeAll { $0 !== shown && !$0.busy && ($0.pixelWidth != job.target.pixelWidth || $0.pixelHeight != job.target.pixelHeight) }
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
