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

/// Counts chart redraws. A frame is every chart drawn in one pass of the main run loop (a zoom of the whole
/// grid redraws them all together); it ends once the pass is over. Records nothing while the meter is off.
final class FrameMeter {
    static let shared = FrameMeter()
    static let enabledKey = "showFrameMeter"

    struct Frame {
        let end: CFTimeInterval
        /// From the first chart's drawing to the last one's: the main thread's time for the frame's charts.
        let span: CFTimeInterval
        let charts: Int
    }

    struct Snapshot {
        var fps = 0
        var averageMs = 0.0
        var slowestMs = 0.0
        var charts = 0
        var inputPerSecond = 0
        /// Frames whose charts took longer than one refresh of the screen.
        var overBudget = 0
    }

    private(set) var isOn = UserDefaults.standard.bool(forKey: enabledKey)
    private var frames: [Frame] = []
    private var inputs: [CFTimeInterval] = []
    private var frameStart: CFTimeInterval?
    private var lastEnd: CFTimeInterval = 0
    private var chartsInFrame = 0

    private init() {
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let on = UserDefaults.standard.bool(forKey: Self.enabledKey)
                if on != self.isOn { self.isOn = on; self.frames = []; self.inputs = [] }
            }
        }
    }

    /// At the start of a chart's drawing: its start time, nil while the meter is off.
    func chartBegan() -> CFTimeInterval? {
        guard isOn else { return nil }
        let now = CACurrentMediaTime()
        if frameStart == nil {
            frameStart = now
            DispatchQueue.main.async { self.closeFrame() }
        }
        return now
    }

    func chartEnded(_ start: CFTimeInterval?) {
        guard start != nil else { return }
        lastEnd = CACurrentMediaTime()
        chartsInFrame += 1
    }

    /// A scroll, swipe, pinch or drag step.
    func input() {
        guard isOn else { return }
        inputs.append(CACurrentMediaTime())
    }

    private func closeFrame() {
        guard let start = frameStart else { return }
        frames.append(Frame(end: lastEnd, span: max(0, lastEnd - start), charts: chartsInFrame))
        frameStart = nil
        chartsInFrame = 0
        prune(now: CACurrentMediaTime())
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
/// second / the screen's refresh rate, the average and slowest frame's chart drawing in ms, input events a second.
struct FrameMeterBadge: View {
    @AppStorage(FrameMeter.enabledKey) private var on = false
    @State private var screenHz = NSScreen.main?.maximumFramesPerSecond ?? 60

    var body: some View {
        if on {
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                let s = FrameMeter.shared.snapshot(refreshRate: screenHz)
                let budget = 1000 / Double(max(1, screenHz))
                HStack(spacing: 4) {
                    Text("\(s.fps)")
                        .foregroundStyle(s.fps >= screenHz - 5 ? Color.green : s.fps >= screenHz / 2 ? Color.yellow : Color.primary.opacity(0.8))
                    Text("/ \(screenHz) fps").foregroundStyle(Color.secondary.opacity(0.7))
                    Text("\(ms(s.averageMs)) / \(ms(s.slowestMs)) ms")
                        .foregroundStyle(s.slowestMs > budget ? Color.orange : Color.primary.opacity(0.8))
                    Text("in \(s.inputPerSecond)/s").foregroundStyle(Color.secondary.opacity(0.7))
                }
                .font(.system(size: 10).monospacedDigit())
                .offset(y: 1)
                .fixedSize()
                .help("Frame meter (Settings › Appearance › Performance), the last second: chart frames per second / the screen's refresh rate; "
                      + "the main thread's time to draw a frame's charts, average / slowest (orange: over one refresh's \(ms(budget)) ms"
                      + (s.overBudget > 0 ? ", \(s.overBudget) frames over" : "") + "; \(s.charts) charts a frame); "
                      + "scroll, swipe, pinch and drag events per second. Zoom or pan to read it.")
                .background(ScreenRate(hz: $screenHz))
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
