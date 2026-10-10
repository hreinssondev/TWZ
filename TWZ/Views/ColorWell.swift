//
//  ColorWell.swift
//  TWZ
//
//  Color swatches for Settings. Unlike SwiftUI's ColorPicker, the color panel they open writes
//  straight to the stored setting, so it keeps working after Settings is closed, until the panel
//  itself is closed or another swatch is clicked.
//

import AppKit
import Observation
import SwiftUI

/// Points the shared color panel at one stored "RRGGBB" setting at a time.
@Observable
final class ColorPanelTarget: NSObject {
    static let shared = ColorPanelTarget()

    /// The UserDefaults key the panel is editing; nil while the panel is closed.
    private(set) var key: String?

    private override init() {
        super.init()
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                               object: NSColorPanel.shared, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.key = nil }
        }
    }

    func edit(key: String, current: Color) {
        let panel = NSColorPanel.shared
        panel.setTarget(nil)                       // so setting its color doesn't write the previous key
        panel.showsAlpha = false
        panel.isContinuous = true
        panel.color = NSColor(current)
        self.key = key
        panel.setTarget(self)
        panel.setAction(#selector(colorChanged(_:)))
        panel.orderFront(nil)
    }

    @objc private func colorChanged(_ panel: NSColorPanel) {
        guard let key else { return }
        UserDefaults.standard.set(Color(nsColor: panel.color).hex, forKey: key)
    }
}

/// A labeled swatch that opens the color panel for the setting stored under `key`.
struct ColorWell: View {
    let title: String
    let key: String
    let color: Color

    var body: some View {
        let editing = ColorPanelTarget.shared.key == key
        LabeledContent(title) {
            Button {
                ColorPanelTarget.shared.edit(key: key, current: color)
            } label: {
                RoundedRectangle(cornerRadius: 4)
                    .fill(color)
                    .frame(width: 38, height: 18)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(editing ? Color.accentColor : Color.primary.opacity(0.25),
                                          lineWidth: editing ? 2 : 1)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}
