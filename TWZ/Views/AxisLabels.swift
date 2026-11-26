//
//  AxisLabels.swift
//  TWZ
//
//  The charts' price and time labels, drawn with Core Text from laid-out lines kept between frames: the same few
//  dozen prices and times come back frame after frame while zooming or panning, and a SwiftUI Text drawn into a
//  Canvas is laid out afresh every time (the largest part of a chart's drawing).
//

import AppKit
import CoreText
import SwiftUI

enum AxisLabels {
    enum Anchor { case leading, center }

    struct Item {
        let text: String
        let point: CGPoint
        let anchor: Anchor
    }

    private struct Key: Hashable {
        let text: String
        let size: CGFloat
        let color: UInt32
    }

    private struct Line {
        let line: CTLine
        let width: CGFloat
        let ascent: CGFloat
        let descent: CGFloat
    }

    private static var lines: [Key: Line] = [:]
    private static var fonts: [CGFloat: NSFont] = [:]

    /// SwiftUI's secondary text color in the app's dark windows.
    static let secondary: NSColor = {
        var color = NSColor.secondaryLabelColor
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
            color = NSColor.secondaryLabelColor.usingColorSpace(.sRGB) ?? color
        }
        return color
    }()

    /// `items` in the monospaced-digit system font at `size`: a leading anchor starts the text at the point, centered
    /// on it vertically; a center anchor centers it there both ways (as `GraphicsContext.draw(_:at:anchor:)`).
    static func draw(_ items: [Item], size: CGFloat, color: NSColor, in ctx: GraphicsContext) {
        guard !items.isEmpty else { return }
        let rgb = color.usingColorSpace(.sRGB) ?? color
        func byte(_ x: CGFloat) -> UInt32 { UInt32((min(1, max(0, x)) * 255).rounded()) }
        let colorKey = byte(rgb.redComponent) << 24 | byte(rgb.greenComponent) << 16 | byte(rgb.blueComponent) << 8 | byte(rgb.alphaComponent)
        let font = fonts[size] ?? {
            let f = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular)
            fonts[size] = f
            return f
        }()
        if lines.count > 4_000 { lines.removeAll(keepingCapacity: true) }
        ctx.withCGContext { cg in
            // The context runs top-down; flipped text draws upright in it.
            cg.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            for item in items {
                let key = Key(text: item.text, size: size, color: colorKey)
                let line = lines[key] ?? {
                    let attributed = NSAttributedString(string: item.text, attributes: [
                        .font: font,
                        NSAttributedString.Key(kCTForegroundColorAttributeName as String): rgb.cgColor,
                    ])
                    let ct = CTLineCreateWithAttributedString(attributed)
                    var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
                    let width = CGFloat(CTLineGetTypographicBounds(ct, &ascent, &descent, &leading))
                    let made = Line(line: ct, width: width, ascent: ascent, descent: descent)
                    lines[key] = made
                    return made
                }()
                let x = item.anchor == .leading ? item.point.x : item.point.x - line.width / 2
                cg.textPosition = CGPoint(x: x, y: item.point.y + (line.ascent - line.descent) / 2)
                CTLineDraw(line.line, cg)
            }
        }
    }
}
