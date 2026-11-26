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

    /// Why a shortcut couldn't be registered (another app may have it), by its id; none when it works.
    private(set) var failures: [Int: String] = [:]

    @ObservationIgnored private var refs: [Int: EventHotKeyRef] = [:]
    @ObservationIgnored private var actions: [Int: () -> Void] = [:]
    @ObservationIgnored private var handlerInstalled = false

    /// Why the shortcut with `id` couldn't be registered.
    func failure(_ id: Int = 1) -> String? { failures[id] }

    /// Replaces the shortcut with `id` (each Charts window has its own); nil removes it.
    func register(_ shortcut: KeyShortcut?, id: Int = 1, action: @escaping () -> Void) {
        if let ref = refs.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
        failures[id] = nil
        actions[id] = action
        guard let shortcut else { return }
        installHandler()

        var modifiers: UInt32 = 0
        if shortcut.command { modifiers |= UInt32(cmdKey) }
        if shortcut.option { modifiers |= UInt32(optionKey) }
        if shortcut.control { modifiers |= UInt32(controlKey) }
        if shortcut.shift { modifiers |= UInt32(shiftKey) }
        let hotKeyID = EventHotKeyID(signature: OSType(0x5457_5A31), id: UInt32(id))          // "TWZ1"
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(shortcut.keyCode), modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            refs[id] = ref
        } else {
            failures[id] = "\(shortcut.display) can't be used everywhere (another app may have it). Try another."
        }
    }

    private func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = Int(hotKeyID.id)
            MainActor.assumeIsolated { GlobalHotkey.shared.actions[id]?() }
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
        content
            .onChange(of: workspace.chartsWindow(.first).shortcut, initial: true) { _, shortcut in register(shortcut, for: .first) }
            .onChange(of: workspace.chartsWindow(.second).shortcut, initial: true) { _, shortcut in register(shortcut, for: .second) }
    }

    private func register(_ shortcut: KeyShortcut?, for win: ChartsWin) {
        GlobalHotkey.shared.register(shortcut, id: win.rawValue) { [openWindow] in
            // A key without ⌘, ⌥ or ⌃ is still typed while one of the app's text fields is being edited.
            if let shortcut, shortcut.isPlain, NSApp.isActive,
               let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.isEditable {
                editor.insertText(shortcut.typed, replacementRange: editor.selectedRange())
                return
            }
            if NSApp.isActive, let key = NSApp.keyWindow, ChartsWin.of(key) == win {
                NSApp.hide(nil)
                return
            }
            if NSApp.isHidden { NSApp.unhide(nil) }
            NSApp.activate()
            if let window = NSApp.windows.first(where: { ChartsWin.of($0) == win && ($0.isVisible || $0.isMiniaturized) }) {
                if window.isMiniaturized { window.deminiaturize(nil) }
                window.makeKeyAndOrderFront(nil)
            } else {
                openWindow(id: win.windowID)
            }
        }
    }
}
