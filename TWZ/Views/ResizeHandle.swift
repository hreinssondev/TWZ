//
//  ResizeHandle.swift
//  TWZ
//
//  Drag handle between two panes. Shows a resize cursor on hover, drags a size
//  in points (clamped to a range) and resets to the default on double-click.
//

import SwiftUI

struct ResizeHandle: View {
    enum Style {
        case grip   // fills a gap between panels and shows a small grip
        case line   // a 1pt divider line with a wider invisible hit area
    }

    /// `.vertical` resizes heights (row cursor), `.horizontal` resizes widths (column cursor).
    let resizes: Axis
    var style: Style = .grip
    var thickness: CGFloat = 6
    /// The size being dragged, as currently laid out.
    let current: CGFloat
    let range: ClosedRange<CGFloat>
    /// True when dragging right/down should shrink the size (the pane sits after the handle).
    var inverted = false
    let onChange: (CGFloat) -> Void
    let onReset: () -> Void

    @State private var dragStart: CGFloat?
    @State private var isHovering = false

    private static let lineHitSlop: CGFloat = 3

    var body: some View {
        let vertical = resizes == .vertical
        let active = dragStart != nil || isHovering
        ZStack {
            switch style {
            case .grip:
                Capsule()
                    .fill(Color.primary.opacity(active ? 0.35 : 0.15))
                    .frame(width: vertical ? 36 : 3, height: vertical ? 3 : 36)
            case .line:
                Rectangle()
                    .fill(active ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.12))
            }
        }
        .frame(width: vertical ? nil : thickness, height: vertical ? thickness : nil)
        .frame(maxWidth: vertical ? .infinity : nil, maxHeight: vertical ? nil : .infinity)
        .contentShape(Rectangle().inset(by: style == .line ? -Self.lineHitSlop : 0))
        .zIndex(1)
        .pointerStyle(vertical ? .rowResize : .columnResize)
        .onHover { isHovering = $0 }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    let start = dragStart ?? current
                    dragStart = start
                    let delta = vertical ? value.translation.height : value.translation.width
                    let size = start + (inverted ? -delta : delta)
                    onChange(min(range.upperBound, max(range.lowerBound, size)))
                }
                .onEnded { _ in dragStart = nil }
        )
        .onTapGesture(count: 2, perform: onReset)
    }
}
