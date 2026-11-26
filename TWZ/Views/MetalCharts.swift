//
//  MetalCharts.swift
//  TWZ
//
//  The bulk of a chart drawn on the GPU with Metal: candles and wicks, volume, session shading, the grid, the forex
//  day lines, VWAP / SMA lines and a theme's background. Each frame the chart hands over plain lists of rectangles and
//  line segments (see `GPUBatch`) and the GPU draws them all at once, antialiased in its shader; Core Graphics, in the
//  layer above (`ChartLayer`), keeps the text, price boxes, order lines, hover and trade arrows.
//

import AppKit
import Metal
import QuartzCore
import SwiftUI

/// One frame's GPU shapes for a chart, in drawing order. Rectangles can shade top to bottom between two colors;
/// segments are straight lines of a width, cut square at their ends. Each run keeps the clip it was added under.
final class GPUBatch {
    struct Rect {
        var rect: SIMD4<Float>      // x, y, width, height in points, top-down
        var top: SIMD4<Float>       // sRGB color, straight alpha
        var bottom: SIMD4<Float>
    }

    struct Segment {
        var ends: SIMD4<Float>      // x0, y0, x1, y1
        var color: SIMD4<Float>
        var params: SIMD4<Float>    // width in points
    }

    enum Kind { case rects, segments }

    struct Command {
        var kind: Kind
        var start: Int
        var count: Int
        var clip: CGRect?
    }

    private(set) var rects: [Rect] = []
    private(set) var segments: [Segment] = []
    private(set) var commands: [Command] = []

    func add(rects new: [CGRect], top: SIMD4<Float>, bottom: SIMD4<Float>, clip: CGRect?) {
        let start = rects.count
        for r in new where r.width > 0 && r.height > 0 {
            rects.append(Rect(rect: SIMD4(Float(r.minX), Float(r.minY), Float(r.width), Float(r.height)), top: top, bottom: bottom))
        }
        note(.rects, from: start, count: rects.count - start, clip: clip)
    }

    func add(segments new: [(CGPoint, CGPoint)], color: SIMD4<Float>, width: CGFloat, clip: CGRect?) {
        let start = segments.count
        let params = SIMD4<Float>(Float(width), 0, 0, 0)
        for (a, b) in new {
            segments.append(Segment(ends: SIMD4(Float(a.x), Float(a.y), Float(b.x), Float(b.y)), color: color, params: params))
        }
        note(.segments, from: start, count: segments.count - start, clip: clip)
    }

    private func note(_ kind: Kind, from start: Int, count: Int, clip: CGRect?) {
        guard count > 0 else { return }
        if let last = commands.last, last.kind == kind, last.clip == clip, last.start + last.count == start {
            commands[commands.count - 1].count += count
        } else {
            commands.append(Command(kind: kind, start: start, count: count, clip: clip))
        }
    }

    /// A SwiftUI color as the app's dark windows show it, in sRGB; converted once each.
    private static var colors: [Color: SIMD4<Float>] = [:]

    static func rgba(_ color: Color) -> SIMD4<Float> {
        if let cached = colors[color] { return cached }
        if colors.count > 1_000 { colors.removeAll(keepingCapacity: true) }
        var made = SIMD4<Float>(0, 0, 0, 0)
        let resolve = {
            if let c = NSColor(color).usingColorSpace(.sRGB) {
                made = SIMD4(Float(c.redComponent), Float(c.greenComponent), Float(c.blueComponent), Float(c.alphaComponent))
            }
        }
        if let dark = NSAppearance(named: .darkAqua) { dark.performAsCurrentDrawingAppearance(resolve) } else { resolve() }
        colors[color] = made
        return made
    }
}

/// The chart's GPU layer, under its Core Graphics one.
final class ChartMetalLayer: CAMetalLayer {
    /// No fades: new sizes show at once.
    override func action(forKey event: String) -> (any CAAction)? { NSNull() }
}

/// The Metal device, queue and shaders every chart shares; nil without Metal (the charts then draw it all with Core
/// Graphics).
final class MetalCharts {
    static let shared = MetalCharts()

    let device: any MTLDevice
    private let queue: any MTLCommandQueue
    private let rectPipeline: any MTLRenderPipelineState
    private let segmentPipeline: any MTLRenderPipelineState

    private struct Uniforms {
        var size: SIMD2<Float>      // points
        var scale: Float            // pixels a point
        var flip: Float             // 1: the layer shows its contents upside down, so draw them so
    }

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: Self.source, options: nil),
              let rectVertex = library.makeFunction(name: "rect_vertex"),
              let segmentVertex = library.makeFunction(name: "segment_vertex"),
              let fragment = library.makeFunction(name: "shape_fragment")
        else { return nil }
        func pipeline(_ vertex: any MTLFunction) -> (any MTLRenderPipelineState)? {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = vertex
            d.fragmentFunction = fragment
            let color = d.colorAttachments[0]!
            color.pixelFormat = .bgra8Unorm
            color.isBlendingEnabled = true
            color.rgbBlendOperation = .add
            color.alphaBlendOperation = .add
            color.sourceRGBBlendFactor = .one
            color.sourceAlphaBlendFactor = .one
            color.destinationRGBBlendFactor = .oneMinusSourceAlpha
            color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            return try? device.makeRenderPipelineState(descriptor: d)
        }
        guard let rects = pipeline(rectVertex), let segments = pipeline(segmentVertex) else { return nil }
        self.device = device
        self.queue = queue
        rectPipeline = rects
        segmentPipeline = segments
    }

    func configure(_ layer: CAMetalLayer) {
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.isOpaque = false
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        layer.maximumDrawableCount = 3
        layer.presentsWithTransaction = false
    }

    /// Draws `batch` into `layer`, `size` points at `scale` pixels a point; an empty batch clears it.
    func render(_ batch: GPUBatch, into layer: CAMetalLayer, size: CGSize, scale: CGFloat) {
        guard size.width >= 1, size.height >= 1 else { return }
        let pixels = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        if layer.drawableSize != pixels { layer.drawableSize = pixels }
        guard let drawable = layer.nextDrawable(), let buffer = queue.makeCommandBuffer() else { return }
        encode(batch, into: drawable.texture, size: size, scale: scale, flip: layer.contentsAreFlipped(), buffer: buffer)
        buffer.present(drawable)
        buffer.commit()
    }

    /// Draws `batch` into `texture` (`size` points at `scale` pixels a point), cleared first.
    func encode(_ batch: GPUBatch, into texture: any MTLTexture, size: CGSize, scale: CGFloat, flip: Bool, buffer: any MTLCommandBuffer) {
        let pixels = CGSize(width: texture.width, height: texture.height)
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }

        var uniforms = Uniforms(size: SIMD2(Float(size.width), Float(size.height)), scale: Float(scale), flip: flip ? 1 : 0)
        let rectStride = MemoryLayout<GPUBatch.Rect>.stride, segmentStride = MemoryLayout<GPUBatch.Segment>.stride
        let rectBuffer = batch.rects.isEmpty ? nil
            : device.makeBuffer(bytes: batch.rects, length: rectStride * batch.rects.count, options: .storageModeShared)
        let segmentBuffer = batch.segments.isEmpty ? nil
            : device.makeBuffer(bytes: batch.segments, length: segmentStride * batch.segments.count, options: .storageModeShared)
        let width = Int(pixels.width), height = Int(pixels.height)

        for command in batch.commands {
            var scissor = MTLScissorRect(x: 0, y: 0, width: width, height: height)
            if let clip = command.clip {
                let minX = max(0, min(width, Int((clip.minX * scale).rounded(.down))))
                let maxX = max(minX, min(width, Int((clip.maxX * scale).rounded(.up))))
                var minY = max(0, min(height, Int((clip.minY * scale).rounded(.down))))
                var maxY = max(minY, min(height, Int((clip.maxY * scale).rounded(.up))))
                if flip { (minY, maxY) = (height - maxY, height - minY) }
                scissor = MTLScissorRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            }
            guard scissor.width > 0, scissor.height > 0 else { continue }
            encoder.setScissorRect(scissor)
            switch command.kind {
            case .rects:
                guard let rectBuffer else { continue }
                encoder.setRenderPipelineState(rectPipeline)
                encoder.setVertexBuffer(rectBuffer, offset: command.start * rectStride, index: 0)
            case .segments:
                guard let segmentBuffer else { continue }
                encoder.setRenderPipelineState(segmentPipeline)
                encoder.setVertexBuffer(segmentBuffer, offset: command.start * segmentStride, index: 0)
            }
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: command.count)
        }
        encoder.endEncoding()
    }

    /// Every shape is a quad grown a pixel each way; the fragment shader fades its edges by how far inside them the
    /// pixel is, so shapes and thin lines move smoothly by fractions of a pixel, as Core Graphics draws them.
    private static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms { float2 size; float scale; float flip; };
    struct RectInstance { float4 rect; float4 top; float4 bottom; };
    struct SegmentInstance { float4 ends; float4 color; float4 params; };
    struct Out {
        float4 position [[position]];
        float4 color;
        float2 local;       // pixels from the shape's center, along its sides
        float2 halfSize;    // half its size in pixels
    };

    static float2 corner(uint vid) {
        return float2((vid == 1 || vid == 2 || vid == 4) ? 1.0 : 0.0, (vid == 2 || vid == 4 || vid == 5) ? 1.0 : 0.0);
    }

    static float4 place(float2 p, constant Uniforms& u) {
        float2 ndc = float2(p.x / u.size.x * 2.0 - 1.0, 1.0 - p.y / u.size.y * 2.0);
        if (u.flip > 0.5) ndc.y = -ndc.y;
        return float4(ndc, 0.0, 1.0);
    }

    vertex Out rect_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                           const device RectInstance* instances [[buffer(0)]], constant Uniforms& u [[buffer(1)]]) {
        RectInstance r = instances[iid];
        float pad = 1.0 / u.scale;
        float2 origin = r.rect.xy, size = r.rect.zw;
        float2 p = mix(origin - pad, origin + size + pad, corner(vid));
        Out o;
        o.position = place(p, u);
        o.color = mix(r.top, r.bottom, clamp((p.y - origin.y) / max(size.y, 1e-6), 0.0, 1.0));
        o.local = (p - (origin + size * 0.5)) * u.scale;
        o.halfSize = size * 0.5 * u.scale;
        return o;
    }

    vertex Out segment_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                              const device SegmentInstance* instances [[buffer(0)]], constant Uniforms& u [[buffer(1)]]) {
        SegmentInstance s = instances[iid];
        float2 a = s.ends.xy, b = s.ends.zw;
        float2 d = b - a;
        float len = length(d);
        float2 dir = len > 1e-6 ? d / len : float2(0.0, 1.0);
        float2 normal = float2(-dir.y, dir.x);
        float pad = 1.0 / u.scale;
        float width = s.params.x;
        float2 c = corner(vid);
        float along = mix(-pad, len + pad, c.x);
        float across = mix(-(width * 0.5 + pad), width * 0.5 + pad, c.y);
        Out o;
        o.position = place(a + dir * along + normal * across, u);
        o.color = s.color;
        o.local = float2(along - len * 0.5, across) * u.scale;
        o.halfSize = float2(len * 0.5, width * 0.5) * u.scale;
        return o;
    }

    fragment float4 shape_fragment(Out in [[stage_in]]) {
        float2 coverage = clamp(in.halfSize - abs(in.local) + 0.5, 0.0, 1.0);
        float alpha = in.color.a * coverage.x * coverage.y;
        return float4(in.color.rgb * alpha, alpha);
    }
    """
}
