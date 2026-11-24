//
//  Confetti.swift
//  TWZ
//
//  Confetti over every screen when a LIVE trade opens (Settings › Trading), in the style of
//  Raycast's: a cannon in each bottom corner fires up and in, and the pieces flutter down. One
//  borderless, transparent window per screen, above every app; clicks and keys go straight through
//  it, and it never takes focus, so it's never in the way of the next order.
//

import AppKit
import SwiftUI

enum Confetti {
    static let enabledKey = "confettiOnLiveEntries"
    static let defaultEnabled = true

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? defaultEnabled
    }

    /// A burst on every screen; one fired while the last is still falling adds to it.
    @MainActor static func fire() { ConfettiOverlay.shared.fire() }
}

/// The windows the confetti falls in: shown for a burst, ordered out once it's over.
@MainActor
final class ConfettiOverlay {
    static let shared = ConfettiOverlay()

    private let show = ConfettiShow()
    private var windows: [NSWindow] = []
    private var hideTask: Task<Void, Never>?

    func fire() {
        let now = Date()
        show.bursts.removeAll { now.timeIntervalSince($0.start) > ConfettiBurst.duration }
        show.bursts.append(ConfettiBurst(start: now))
        orderFront()
        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(ConfettiBurst.duration))
            guard !Task.isCancelled, let self else { return }
            self.show.bursts.removeAll()
            for window in self.windows { window.orderOut(nil) }
        }
    }

    /// One window per screen, made again when the screens changed.
    private func orderFront() {
        let screens = NSScreen.screens
        if windows.count != screens.count || zip(windows, screens).contains(where: { $0.frame != $1.frame }) {
            for window in windows { window.close() }
            windows = screens.map(makeWindow)
        }
        for window in windows { window.orderFrontRegardless() }
    }

    private func makeWindow(on screen: NSScreen) -> NSWindow {
        let panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isExcludedFromWindowsMenu = true
        panel.animationBehavior = .none
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let host = NSHostingView(rootView: ConfettiView(show: show))
        host.sizingOptions = []
        panel.contentView = host
        panel.setFrame(screen.frame, display: false)
        return panel
    }
}

@Observable
final class ConfettiShow {
    var bursts: [ConfettiBurst] = []
}

/// Both cannons' pieces, each on a path worked out from the time since it was fired (no state to step).
struct ConfettiBurst {
    /// From the first shot until the last pieces have faded.
    static let duration: TimeInterval = 4.6
    private static let fadeTime: TimeInterval = 0.6
    private static let piecesPerCannon = 190

    let start: Date
    let pieces: [ConfettiPiece]

    init(start: Date) {
        self.start = start
        pieces = (0..<Self.piecesPerCannon * 2).map { ConfettiPiece(fromRight: $0 % 2 == 1) }
    }

    func draw(in context: GraphicsContext, size: CGSize, at time: TimeInterval) {
        let fade = min(1, (Self.duration - time) / Self.fadeTime)
        guard fade > 0 else { return }
        for piece in pieces { piece.draw(in: context, size: size, at: time - piece.delay, opacity: fade) }
    }
}

/// One piece of confetti. Lengths are in screen heights (and per second), so every screen gets the
/// same show; the pieces themselves are in points.
struct ConfettiPiece {
    private enum Shape { case square, ribbon, dot }

    private static let gravity = 1.0
    private static let palette: [(hue: Double, saturation: Double)] = [
        (0.99, 0.78), (0.06, 0.85), (0.13, 0.85), (0.36, 0.70), (0.53, 0.80), (0.60, 0.75), (0.74, 0.65), (0.88, 0.60),
    ]

    let fromRight: Bool
    /// Shots are spread over the first quarter second, so the burst comes out as a stream.
    let delay: TimeInterval
    private let vx: Double, vy: Double
    /// Air drag: how fast it slows down; gravity over it is how fast it falls in the end.
    private let drag: Double
    private let sway: Double, swayRate: Double, swayPhase: Double
    private let angle: Double, spin: Double
    private let flipRate: Double, flipPhase: Double
    private let shape: Shape
    private let width: Double, height: Double
    private let front: Color, back: Color

    init(fromRight: Bool) {
        self.fromRight = fromRight
        delay = .random(in: 0...0.25)
        let speed = Double.random(in: 1.5...3.0)
        let elevation = Double.random(in: 50...78) * .pi / 180
        vx = speed * cos(elevation)
        vy = -speed * sin(elevation)
        drag = .random(in: 1.4...1.9)
        sway = .random(in: 0.01...0.035)
        swayRate = .random(in: 3...7)
        swayPhase = .random(in: 0...(2 * .pi))
        angle = .random(in: 0...(2 * .pi))
        spin = .random(in: -7...7)
        flipRate = .random(in: 5...13)
        flipPhase = .random(in: 0...(2 * .pi))
        switch Double.random(in: 0..<1) {
        case ..<0.6:
            shape = .square
            width = .random(in: 9...13)
            height = width * .random(in: 0.55...0.8)
        case ..<0.85:
            shape = .ribbon
            width = .random(in: 14...20)
            height = .random(in: 4...5.5)
        default:
            shape = .dot
            width = .random(in: 6...9)
            height = width
        }
        let tint = Self.palette.randomElement()!
        front = Color(hue: tint.hue, saturation: tint.saturation, brightness: 1)
        back = Color(hue: tint.hue, saturation: tint.saturation, brightness: 0.72)
    }

    /// `time`: since this piece was fired.
    func draw(in context: GraphicsContext, size: CGSize, at time: TimeInterval, opacity: Double) {
        guard time > 0 else { return }
        let h = size.height
        // Velocity eases from the shot towards falling at gravity / drag (linear drag, solved exactly).
        let eased = 1 - exp(-drag * time)
        let terminal = Self.gravity / drag
        // Wider screens than a laptop's get a longer throw, so the cannons still meet in the middle.
        let reach = max(1, size.width / h / 1.6)
        let across = (vx / drag * reach + sway * sin(swayRate * time + swayPhase)) * eased * h
        let x = fromRight ? size.width - across : across
        let y = (1.01 + terminal * time + (vy - terminal) / drag * eased) * h
        guard y < h + 30, x > -30, x < size.width + 30 else { return }

        var c = context
        c.opacity = opacity
        c.translateBy(x: x, y: y)
        c.rotate(by: .radians(angle + spin * time))
        // Tumbling in 3D: seen edge-on, then from its other, darker side.
        let flip = cos(flipRate * time + flipPhase)
        if shape != .dot { c.scaleBy(x: 1, y: max(0.1, abs(flip))) }
        let rect = CGRect(x: -width / 2, y: -height / 2, width: width, height: height)
        let path = shape == .dot ? Path(ellipseIn: rect) : Path(rect)
        c.fill(path, with: .color(flip >= 0 || shape == .dot ? front : back))
    }
}

struct ConfettiView: View {
    let show: ConfettiShow

    var body: some View {
        TimelineView(.animation(paused: show.bursts.isEmpty)) { timeline in
            Canvas { context, size in
                for burst in show.bursts {
                    let time = timeline.date.timeIntervalSince(burst.start)
                    if time >= 0 { burst.draw(in: context, size: size, at: time) }
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}
