//
//  ContentView.swift
//  TWZ
//
//  ┌──── ●●● account bar (in the title bar) ──────┐
//  │  chart 1  │  chart 2  ┃  list A  ┃  list B  │
//  │ ──────────●────────── ┃          ┃          │
//  │  chart 3  │  chart 4  ┃          ┃          │
//  ╞═══ handle ════════════╡┃━━━━━ handle ━━━━━━━┥
//  │  hotkeys (6×2) │ NOK  ┃  orders  ┃ positions│
//  └───────────────────────┴───────────────────────┘
//
//  Every ┃/═/━ separator is a drag handle (resize cursor on hover, double-click resets):
//  charts ↕ hotkeys, left column ↔ right column, list A ↔ list B, lists ↕ orders, and
//  the Orders / Positions columns ↕ round trips. The account bar's Cols / Rows sliders size
//  the chart grid, whose charts follow the top gainers (see `ChartGrid`); a ● where four charts meet
//  drags that column and row line together. The button beside a list's filters makes lists A and B
//  one list across their space (Top Gainers by default; it keeps its own scanner choice), or splits
//  them again, and moves the right column as far right as their columns fit in full (dragged further,
//  lists clip their price columns, and each list's column header edges drag those widths). The hotkey buttons keep a
//  fixed size while there's
//  room (the free space around them changes); dragged shorter, they and the amount box shrink,
//  and dragged on down the hotkey row collapses, giving the charts the space (drag up to bring it back).
//  Collapsed, it shows at its smallest over the bottom of the charts while the pointer is at the
//  window's bottom edge below them, or on the row itself.
//

import SwiftUI

struct ContentView: View {
    @Environment(Broker.self) private var broker
    @Environment(Workspace.self) private var workspace
    /// 0 = the hotkey row is collapsed.
    @AppStorage("bottomRowHeight") private var bottomHeight: Double = 190
    @AppStorage("sideWidth") private var storedSideWidth: Double = 0      // 0 = default (a third)
    @AppStorage("listSplit") private var listSplit: Double = 0.5          // left list's share of the lists
    @AppStorage(ListPanel.singleKey) private var singleList = false
    @AppStorage("ordersHeight") private var ordersHeight: Double = 190
    /// The collapsed hotkey row is showing over the charts (see `peekHotkeys`).
    @State private var hotkeysPeek = false
    @State private var hotkeysPeekHide: Task<Void, Never>?

    private static let gap: CGFloat = 6
    private static let minTopHeight: CGFloat = 240
    private static let minChartsWidth: CGFloat = 520
    /// A list this narrow shows its symbols and clips the price columns on the right.
    private static let minListWidth: CGFloat = 100
    /// Where the one-list / two-lists button puts the right column: as narrow as it goes with every
    /// list column and Orders / Positions column in full. Dragging goes further, to `minListWidth`.
    private static let snapListWidth: CGFloat = 240
    private static let snapSingleListSide: CGFloat = 386
    private static let minListsHeight: CGFloat = 160
    private static let minOrdersHeight: CGFloat = 80

    var body: some View {
        VStack(spacing: 0) {
            AccountBar()
                .task { await broker.ssrList.keepLoaded() }
            Divider()
            GeometryReader { geo in
                let gap = Self.gap
                let inner = CGSize(width: geo.size.width - gap * 2, height: geo.size.height - gap * 2)

                let minBottom = HotkeyPanel.minHeight
                let maxBottom = max(minBottom, inner.height - gap - Self.minTopHeight)
                let rowHeight = bottomHeight <= 0 ? 0 : clamp(bottomHeight, minBottom...maxBottom)

                let minSide = Self.minListWidth * 2 + gap
                let maxSide = max(minSide, inner.width - gap - Self.minChartsWidth)
                let sideWidth = clamp(storedSideWidth > 0 ? storedSideWidth : (inner.width - gap) / 3, minSide...maxSide)

                let listsWidth = sideWidth - gap
                let leftListRange = Self.minListWidth...max(Self.minListWidth, listsWidth - Self.minListWidth)
                let leftListWidth = clamp(listsWidth * listSplit, leftListRange)

                let maxOrders = max(Self.minOrdersHeight, inner.height - gap - Self.minListsHeight)
                let ordersRange = Self.minOrdersHeight...maxOrders
                let ordersPanelHeight = clamp(ordersHeight, ordersRange)

                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        ChartGrid(gap: gap)
                            // The hotkey row shows messages; collapsed, they float over the charts, and
                            // the row itself shows there while peeking. It stays laid out while hidden,
                            // so an editor or popover opened from it stays open.
                            .overlay(alignment: .bottom) {
                                if rowHeight <= 0 {
                                    ZStack(alignment: .bottom) {
                                        if !hotkeysPeek { FloatingMessages().padding(.horizontal, 6).padding(.bottom, 8) }
                                        HotkeyPanel()
                                            .frame(height: minBottom)
                                            .background(RoundedRectangle(cornerRadius: 6)
                                                .fill(Color(nsColor: .windowBackgroundColor))
                                                .shadow(color: .black.opacity(0.35), radius: 8))
                                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.12)))
                                            .onHover(perform: peekHotkeys)
                                            .opacity(hotkeysPeek ? 1 : 0)
                                            .offset(y: hotkeysPeek ? 0 : 8)
                                            .allowsHitTesting(hotkeysPeek)
                                            .animation(.easeOut(duration: 0.15), value: hotkeysPeek)
                                    }
                                }
                            }
                        ResizeHandle(resizes: .vertical, thickness: gap, current: rowHeight,
                                     range: minBottom...maxBottom, inverted: true, collapsible: true,
                                     onChange: { bottomHeight = $0 }, onReset: { bottomHeight = 190 })
                        if rowHeight > 0 {
                            HotkeyPanel()
                                .frame(height: rowHeight)
                        }
                    }
                    ResizeHandle(resizes: .horizontal, thickness: gap, current: sideWidth,
                                 range: minSide...maxSide, inverted: true,
                                 onChange: { storedSideWidth = $0 }, onReset: { storedSideWidth = 0 })
                    VStack(spacing: 0) {
                        HStack(spacing: 0) {
                            if singleList {
                                ListPanel(panelId: "list-single", defaultScanner: .gainers)
                            } else {
                                ListPanel(panelId: "list-left", defaultScanner: .gainers)
                                    .frame(width: leftListWidth)
                                ResizeHandle(resizes: .horizontal, thickness: gap, current: leftListWidth,
                                             range: leftListRange,
                                             onChange: { listSplit = $0 / listsWidth }, onReset: { listSplit = 0.5 })
                                ListPanel(panelId: "list-right", defaultScanner: .dollarVolume)
                            }
                        }
                        ResizeHandle(resizes: .vertical, thickness: gap, current: ordersPanelHeight,
                                     range: ordersRange, inverted: true,
                                     onChange: { ordersHeight = $0 }, onReset: { ordersHeight = 190 })
                        OrdersPanel()
                            .frame(height: ordersPanelHeight)
                    }
                    .frame(width: sideWidth)
                }
                .padding(gap)
                // The window's bottom edge below the charts (the row's drag handle and the margin under it).
                .overlay(alignment: .bottomLeading) {
                    HoverTracker(onHover: peekHotkeys)
                        .frame(width: inner.width - sideWidth, height: gap * 2)
                }
            }
        }
        // The title bar is hidden; the account bar takes its place, next to the window controls.
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 1200, minHeight: 760)
        // Switching between one list and two moves the right column as far right as it goes for that.
        .onChange(of: singleList) { _, single in storedSideWidth = Self.snapSideWidth(singleList: single) }
    }

    /// Shows the collapsed hotkey row while the pointer is at the bottom edge or on the row; hides it a
    /// moment after the pointer leaves both, so moving from one to the other doesn't flicker, and not
    /// while a popover or sheet (the hotkey customizer or editor) is open over the window.
    private func peekHotkeys(_ hovering: Bool) {
        hotkeysPeekHide?.cancel()
        if hovering {
            hotkeysPeek = true
        } else {
            hotkeysPeekHide = Task {
                repeat {
                    try? await Task.sleep(for: .milliseconds(300))
                } while !Task.isCancelled && Self.hasDialogOpen
                if !Task.isCancelled { hotkeysPeek = false }
            }
        }
    }

    private static var hasDialogOpen: Bool {
        guard let window = NSApp.mainWindow else { return false }
        return window.attachedSheet != nil || !(window.childWindows ?? []).isEmpty
    }

    /// Where switching between one list and two puts the right column.
    private static func snapSideWidth(singleList: Bool) -> CGFloat {
        singleList ? snapSingleListSide : snapListWidth * 2 + gap
    }

    private func clamp(_ value: Double, _ range: ClosedRange<CGFloat>) -> CGFloat {
        min(range.upperBound, max(range.lowerBound, value))
    }
}

/// Reports the pointer entering and leaving its area without taking any clicks, so what's under it
/// (a drag handle) still works.
private struct HoverTracker: NSViewRepresentable {
    let onHover: (Bool) -> Void

    func makeNSView(context: Context) -> Tracker { Tracker(onHover: onHover) }
    func updateNSView(_ view: Tracker, context: Context) { view.onHover = onHover }

    final class Tracker: NSView {
        var onHover: (Bool) -> Void

        init(onHover: @escaping (Bool) -> Void) {
            self.onHover = onHover
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                           owner: self))
        }

        override func mouseEntered(with event: NSEvent) { onHover(true) }
        override func mouseExited(with event: NSEvent) { onHover(false) }
    }
}
