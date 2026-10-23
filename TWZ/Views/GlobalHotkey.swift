//
//  GlobalHotkey.swift
//  TWZ
//
//  A system-wide keyboard shortcut (a Carbon hot key: fires while other apps are in front, and
//  needs no Accessibility access). Used to show and hide the Charts window from anywhere.
//

import AppKit
import Carbon.HIToolbox
import Observation
import SwiftUI

@Observable
final class GlobalHotkey {
    static let shared = GlobalHotkey()

    /// Why the shortcut couldn't be registered (another app may have it); nil when it works.
    private(set) var failure: String?

    @ObservationIgnored private var ref: EventHotKeyRef?
    @ObservationIgnored private var action: (() -> Void)?
    @ObservationIgnored private var handlerInstalled = false

    /// Replaces the shortcut; nil removes it.
    func register(_ shortcut: KeyShortcut?, action: @escaping () -> Void) {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        failure = nil
        self.action = action
        guard let shortcut else { return }
        installHandler()

        var modifiers: UInt32 = 0
        if shortcut.command { modifiers |= UInt32(cmdKey) }
        if shortcut.option { modifiers |= UInt32(optionKey) }
        if shortcut.control { modifiers |= UInt32(controlKey) }
        if shortcut.shift { modifiers |= UInt32(shiftKey) }
        let id = EventHotKeyID(signature: OSType(0x5457_5A31), id: 1)          // "TWZ1"
        let status = RegisterEventHotKey(UInt32(shortcut.keyCode), modifiers, id,
                                         GetApplicationEventTarget(), 0, &ref)
        if status != noErr {
            ref = nil
            failure = "\(shortcut.display) can't be used everywhere (another app may have it). Try another."
        }
    }

    private func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            MainActor.assumeIsolated { GlobalHotkey.shared.action?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

/// Keeps the Charts window shortcut (Settings ▸ Trading) registered. Pressed with the Charts window
/// in front, it hides the whole app, so the app used before comes back; otherwise it brings the app
/// and the Charts window to the front, opening the window if it isn't open. Hiding doesn't close the
/// window, so its charts stay live and come back instantly.
struct ChartsWindowShortcut: ViewModifier {
    @Environment(Workspace.self) private var workspace
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onChange(of: workspace.chartsWindowShortcut, initial: true) { _, shortcut in
            GlobalHotkey.shared.register(shortcut) { [openWindow] in
                // A key without ⌘, ⌥ or ⌃ is still typed while one of the app's text fields is being edited.
                if let shortcut, shortcut.isPlain, NSApp.isActive,
                   let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.isEditable {
                    editor.insertText(shortcut.typed, replacementRange: editor.selectedRange())
                    return
                }
                if NSApp.isActive, let key = NSApp.keyWindow, SecondaryCharts.isWindow(key) {
                    NSApp.hide(nil)
                    return
                }
                if NSApp.isHidden { NSApp.unhide(nil) }
                NSApp.activate()
                if let window = NSApp.windows.first(where: { SecondaryCharts.isWindow($0) && ($0.isVisible || $0.isMiniaturized) }) {
                    if window.isMiniaturized { window.deminiaturize(nil) }
                    window.makeKeyAndOrderFront(nil)
                } else {
                    openWindow(id: SecondaryCharts.windowID)
                }
            }
        }
    }
}
