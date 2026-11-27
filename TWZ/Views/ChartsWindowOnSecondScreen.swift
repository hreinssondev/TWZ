//
//  ChartsWindowOnSecondScreen.swift
//  TWZ
//
//  At launch, with two screens or more: the Charts window opens with the main window, on the screen the main window
//  isn't on (the first such), filling it; one already there keeps its size and place. One screen: as before.
//

import AppKit
import SwiftUI

struct ChartsWindowOnSecondScreen: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    /// Once a launch: the main window coming back (a new one, say) doesn't move it again.
    @MainActor private static var done = false

    func body(content: Content) -> some View {
        content.task {
            guard !Self.done else { return }
            Self.done = true
            guard NSScreen.screens.count >= 2 else { return }
            let win = ChartsWin.first
            if !NSApp.windows.contains(where: { ChartsWin.of($0) == win && $0.isVisible }) {
                openWindow(id: win.windowID)
            }
            // The window shows a moment after it's asked for.
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(150))
                guard let charts = NSApp.windows.first(where: { ChartsWin.of($0) == win && $0.isVisible }) else { continue }
                let main = NSApp.windows.first { ChartsWin.of($0) == nil && $0.isVisible && $0.canBecomeMain }
                let mainScreen = main?.screen ?? NSScreen.screens[0]
                guard let other = NSScreen.screens.first(where: { $0 != mainScreen }) else { return }
                if charts.screen != other { charts.setFrame(other.visibleFrame, display: true) }
                main?.makeKeyAndOrderFront(nil)
                return
            }
        }
    }
}
