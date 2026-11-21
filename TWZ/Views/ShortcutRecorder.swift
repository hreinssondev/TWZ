//
//  ShortcutRecorder.swift
//  TWZ
//
//  Records a hotkey's, an order key's or the Charts window's keyboard shortcut: click, then press the keys.
//  Esc cancels, Delete clears. Shortcuts the app or macOS already uses, or another hotkey, order key or the
//  Charts window has, are refused with the reason; but a hotkey button may take an order key's, overriding it
//  while it has it (see `Workspace.hotkeyOverriding`).
//

import AppKit
import SwiftUI

struct ShortcutRecorder: View {
    @Environment(Workspace.self) private var workspace
    var title = "Keyboard shortcut"
    @Binding var shortcut: KeyShortcut?
    let owner: Owner
    @State private var monitor: Any?
    @State private var problem: String?

    /// True while any recorder is waiting for keys; TradingShortcuts then lets every key through.
    static var isRecording = false

    /// What the shortcut is for, so its own current shortcut isn't counted as taken.
    enum Owner: Equatable {
        case hotkey(UUID)
        case orderKey(UUID)
        case chartsWindow
        case reset
    }

    var body: some View {
        LabeledContent(title) {
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 6) {
                    Button(monitor != nil ? "Press keys…" : (shortcut?.display ?? "Record")) {
                        monitor == nil ? start() : stop()
                    }
                    .help(monitor != nil ? "Esc cancels · Delete clears" : "Click, then press the shortcut")
                    if shortcut != nil, monitor == nil {
                        Button {
                            shortcut = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Remove the shortcut")
                    }
                }
                if let problem {
                    Text(problem).font(.caption).foregroundStyle(.red)
                } else if isHotkey, let shortcut, monitor == nil,
                          let key = workspace.orderKeys.first(where: { $0.shortcut?.numberRow == shortcut.numberRow }) {
                    Text("Overrides the order key \"\(key.label)\" while this button has it; that one works again once this changes or the button goes.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .onDisappear(perform: stop)
    }

    private var isHotkey: Bool {
        if case .hotkey = owner { return true }
        return false
    }

    private func start() {
        problem = nil
        Self.isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            record(event)
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        Self.isRecording = false
    }

    private func record(_ event: NSEvent) {
        let plain = event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
        if plain, event.keyCode == 53 { return stop() }                           // Esc
        if plain, event.keyCode == 51 || event.keyCode == 117 {                  // Delete
            shortcut = nil
            return stop()
        }
        let new = KeyShortcut(event)
        if let reason = new.reservedFor {
            problem = "\(reason). Try another."
            return
        }
        if let other = workspace.hotkeys.first(where: { owner != .hotkey($0.id) && $0.shortcut?.numberRow == new.numberRow }) {
            problem = "\(new.display) is already the \"\(other.label)\" button's. Try another."
            return
        }
        // A hotkey button may take an order key's shortcut: it overrides the order key while it has it (see
        // `Workspace.hotkeyOverriding`); anything else may not.
        if !isHotkey, let other = workspace.orderKeys.first(where: { owner != .orderKey($0.id) && $0.shortcut?.numberRow == new.numberRow }) {
            problem = "\(new.display) is already the order key \"\(other.label)\". Try another."
            return
        }
        if owner != .reset, workspace.resetShortcut == new {
            problem = "\(new.display) already resets the chart grid. Try another."
            return
        }
        if owner != .chartsWindow, workspace.chartsWindowShortcut == new {
            problem = "\(new.display) shows and hides the Charts window. Try another."
            return
        }
        problem = nil
        shortcut = new
        stop()
    }
}

/// Records the modifier keys the 1–9 order keys are pressed with (see `Workspace.setNumberModifiers`): click,
/// hold the modifiers (⌘, ⌥, ⌃, ⇧), shown as they're held, then ↩ saves them; Esc cancels. A set that can't be
/// used is refused with the reason.
struct ModifierRecorder: View {
    let title: String
    let current: ModifierSet
    /// Saves the set: nil once saved, else why not.
    let save: (ModifierSet) -> String?
    @State private var monitor: Any?
    @State private var held = ModifierSet()
    @State private var problem: String?

    var body: some View {
        LabeledContent(title) {
            VStack(alignment: .trailing, spacing: 2) {
                Button(monitor == nil ? current.display + " 1–9" : held.isEmpty ? "Hold the keys, then ↩" : held.display + " … ↩") {
                    monitor == nil ? start() : stop()
                }
                .monospacedDigit()
                .help(monitor != nil ? "Hold the modifier keys, then press ↩ · Esc cancels" : "Click, hold the modifier keys, then press ↩")
                if let problem {
                    Text(problem).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        problem = nil
        held = ModifierSet()
        ShortcutRecorder.isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { event in
            let set = ModifierSet(event.modifierFlags)
            if event.type == .flagsChanged {
                held = set
                return event
            }
            if event.keyCode == 53 { stop() }                                   // Esc
            else if event.keyCode == 36 || event.keyCode == 76 {               // Return or keypad Enter
                if let reason = save(set) { problem = reason } else { stop() }
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        held = ModifierSet()
        ShortcutRecorder.isRecording = false
    }
}

extension ModifierSet {
    init(_ flags: NSEvent.ModifierFlags) {
        self.init(command: flags.contains(.command), option: flags.contains(.option),
                  control: flags.contains(.control), shift: flags.contains(.shift))
    }
}
