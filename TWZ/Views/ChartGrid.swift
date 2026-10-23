//
//  ChartGrid.swift
//  TWZ
//
//  The 2×2 chart grid. The point where the four charts meet is a drag handle:
//  dragging it moves the column split and the row split together, resizing all
//  four charts at once. Double-click resets to equal quarters.
//

import SwiftUI

struct ChartGrid: View {
    @Environment(Workspace.self) private var workspace
    @AppStorage("chartColumnSplit") private var columnSplit: Double = 0.5   // left column's share
    @AppStorage("chartRowSplit") private var rowSplit: Double = 0.5         // top row's share

    let gap: CGFloat

    private static let minChartWidth: CGFloat = 200
    private static let minChartHeight: CGFloat = 100

    var body: some View {
        GeometryReader { geo in
            let available = CGSize(width: geo.size.width - gap, height: geo.size.height - gap)
            let widthRange = Self.range(min: Self.minChartWidth, total: available.width)
            let heightRange = Self.range(min: Self.minChartHeight, total: available.height)
            let leftWidth = clamp(available.width * columnSplit, widthRange)
            let topHeight = clamp(available.height * rowSplit, heightRange)

            VStack(spacing: gap) {
                HStack(spacing: gap) {
                    ChartPane(chart: workspace.charts[0]).frame(width: leftWidth)
                    ChartPane(chart: workspace.charts[1])
                }
                .frame(height: topHeight)
                HStack(spacing: gap) {
                    ChartPane(chart: workspace.charts[2]).frame(width: leftWidth)
                    ChartPane(chart: workspace.charts[3])
                }
            }
            .overlay(alignment: .topLeading) {
                CrossResizeHandle(
                    current: CGSize(width: leftWidth, height: topHeight),
                    onChange: { size in
                        columnSplit = clamp(size.width, widthRange) / available.width
                        rowSplit = clamp(size.height, heightRange) / available.height
                    },
                    onReset: { columnSplit = 0.5; rowSplit = 0.5 }
                )
                .position(x: leftWidth + gap / 2, y: topHeight + gap / 2)
            }
        }
    }

    private static func range(min: CGFloat, total: CGFloat) -> ClosedRange<CGFloat> {
        min...Swift.max(min, total - min)
    }

    private func clamp(_ value: CGFloat, _ range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(range.upperBound, Swift.max(range.lowerBound, value))
    }
}

/// A small grip at the crossing of two gaps that drags a width and a height together.
struct CrossResizeHandle: View {
    let current: CGSize
    let onChange: (CGSize) -> Void
    let onReset: () -> Void

    @State private var dragStart: CGSize?
    @State private var isHovering = false

    private static let hitSize: CGFloat = 18

    var body: some View {
        let active = dragStart != nil || isHovering
        Circle()
            .fill(Color.primary.opacity(active ? 0.45 : 0.2))
            .frame(width: active ? 10 : 7, height: active ? 10 : 7)
            .frame(width: Self.hitSize, height: Self.hitSize)
            .contentShape(Rectangle())
            .pointerStyle(.frameResize(position: .topLeading, directions: .all))
            .onHover { isHovering = $0 }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = dragStart ?? current
                        dragStart = start
                        onChange(CGSize(width: start.width + value.translation.width,
                                        height: start.height + value.translation.height))
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .onTapGesture(count: 2, perform: onReset)
            .animation(.easeOut(duration: 0.1), value: active)
    }
}
