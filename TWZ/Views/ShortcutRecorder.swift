//
//  ShortcutRecorder.swift
//  TWZ
//
//  Records a hotkey's keyboard shortcut: click, then press the keys. Esc cancels, Delete clears.
//  Shortcuts the app or macOS already uses, or another hotkey has, are refused with the reason.
//

import AppKit
import SwiftUI

struct ShortcutRecorder: View {
    @Environment(Workspace.self) private var workspace
    @Binding var hotkey: Hotkey
    @State private var monitor: Any?
    @State private var problem: String?

    /// True while any recorder is waiting for keys; TradingShortcuts then lets every key through.
    static var isRecording = false

    var body: some View {
        LabeledContent("Keyboard shortcut") {
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 6) {
                    Button(monitor != nil ? "Press keys…" : (hotkey.shortcut?.display ?? "Record")) {
                        monitor == nil ? start() : stop()
                    }
                    .help(monitor != nil ? "Esc cancels · Delete clears" : "Click, then press the shortcut")
                    if hotkey.shortcut != nil, monitor == nil {
                        Button {
                            hotkey.shortcut = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Remove the shortcut")
                    }
                }
                if let problem {
                    Text(problem).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .onDisappear(perform: stop)
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
            hotkey.shortcut = nil
            return stop()
        }
        let shortcut = KeyShortcut(event)
        if let reason = shortcut.reservedFor {
            problem = "\(reason). Try another."
            return
        }
        if let other = workspace.hotkeys.first(where: { $0.id != hotkey.id && $0.shortcut == shortcut }) {
            problem = "\(shortcut.display) is already \"\(other.label)\". Try another."
            return
        }
        problem = nil
        hotkey.shortcut = shortcut
        stop()
    }
}
