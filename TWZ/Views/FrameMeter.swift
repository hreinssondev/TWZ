//
//  FrameMeter.swift
//  TWZ
//
//  Settings › Appearance › Performance › Frame meter: how fast the charts redraw while zooming or panning,
//  against the screen's refresh rate, in the top bar.
//

import AppKit
import QuartzCore
import SwiftUI

/// Counts the frames of charts shown (see `ChartRenderLoop`; a zoom of the whole grid draws them all in one).
/// Records nothing while the meter is off.
final class FrameMeter {
    static let shared = FrameMeter()
    static let enabledKey = "showFrameMeter"
    /// On until turned off in Settings.
    static let defaultOn = true
    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? defaultOn }

    struct Frame {
        let end: CFTimeInterval
        /// From copying the frame's charts to showing them, drawn on every core.
        let span: CFTimeInterval
        let charts: Int
    }

    struct Snapshot: Equatable {
        var fps = 0
        var averageMs = 0.0
        var slowestMs = 0.0
        var charts = 0
        var inputPerSecond = 0
        /// Frames whose charts took longer than one refresh of the screen.
        var overBudget = 0
    }

    private(set) var isOn = FrameMeter.enabled
    private var frames: [Frame] = []
    private var inputs: [CFTimeInterval] = []

    private init() {
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let on = Self.enabled
                if on != self.isOn { self.isOn = on; self.frames = []; self.inputs = [] }
            }
        }
    }

    /// A frame shown: `span` from copying its charts to showing them, drawn on every core (see `ChartRenderLoop`).
    func record(span: CFTimeInterval, charts: Int) {
        guard isOn else { return }
        let now = CACurrentMediaTime()
        frames.append(Frame(end: now, span: span, charts: charts))
        prune(now: now)
    }

    /// A scroll, swipe, pinch or drag step.
    func input() {
        guard isOn else { return }
        inputs.append(CACurrentMediaTime())
    }

    private func prune(now: CFTimeInterval) {
        let since = now - 1
        if let i = frames.firstIndex(where: { $0.end >= since }) { frames.removeFirst(i) } else { frames = [] }
        if let i = inputs.firstIndex(where: { $0 >= since }) { inputs.removeFirst(i) } else { inputs = [] }
    }

    /// The last second.
    func snapshot(refreshRate: Int) -> Snapshot {
        prune(now: CACurrentMediaTime())
        guard !frames.isEmpty else { return Snapshot(inputPerSecond: inputs.count) }
        let spans = frames.map(\.span)
        let budget = 1 / Double(max(1, refreshRate))
        return Snapshot(fps: frames.count,
                        averageMs: spans.reduce(0, +) / Double(spans.count) * 1000,
                        slowestMs: (spans.max() ?? 0) * 1000,
                        charts: Int((Double(frames.map(\.charts).reduce(0, +)) / Double(frames.count)).rounded()),
                        inputPerSecond: inputs.count,
                        overBudget: spans.filter { $0 > budget }.count)
    }
}

/// The meter in the top bar (the main window's and the Charts windows'), while it's on in Settings: frames per
/// second, on its own; the screen's rate, drawing times and input rate are in its tooltip.
struct FrameMeterBadge: View {
    @AppStorage(FrameMeter.enabledKey) private var on = FrameMeter.defaultOn
    @State private var screenHz = NSScreen.main?.maximumFramesPerSecond ?? 60
    @State private var s = FrameMeter.Snapshot()

    var body: some View {
        if on {
            let budget = 1000 / Double(max(1, screenHz))
            Text("\(s.fps)")
                .foregroundStyle(s.fps >= screenHz - 5 ? Color.green : s.fps >= screenHz / 2 ? Color.yellow : Color.primary.opacity(0.8))
                .font(.system(size: 10).monospacedDigit())
                .offset(y: 1)
                .fixedSize()
                .help("Frame meter (Settings › Appearance › Performance), the last second: chart frames per second / the screen's refresh rate; "
                      + "the time to draw a frame's charts (on every core), average / slowest (over one refresh's \(ms(budget)) ms"
                      + (s.overBudget > 0 ? ": \(s.overBudget) frames" : "") + "; \(s.charts) charts a frame); "
                      + "scroll, swipe, pinch and drag events per second. Zoom or pan to read it.\n\n"
                      + "Last second: \(s.fps) / \(screenHz) fps, \(ms(s.averageMs)) / \(ms(s.slowestMs)) ms drawing, \(s.inputPerSecond) input events/s.")
                .background(ScreenRate(hz: $screenHz))
                // Read twice a second by a plain timer: a TimelineView kept SwiftUI updating both windows at every
                // refresh of the screen, which took more of the main thread than anything else.
                .task {
                    while !Task.isCancelled {
                        let new = FrameMeter.shared.snapshot(refreshRate: screenHz)
                        if new != s { s = new }
                        try? await Task.sleep(for: .milliseconds(500))
                    }
                }
        }
    }

    private func ms(_ v: Double) -> String { v.formatted(.number.precision(.fractionLength(1))) }
}

/// The refresh rate of the screen its window is on.
private struct ScreenRate: NSViewRepresentable {
    @Binding var hz: Int

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            if let rate = view.window?.screen?.maximumFramesPerSecond, rate != hz { hz = rate }
        }
    }
}
