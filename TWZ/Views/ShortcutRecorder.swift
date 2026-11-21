//
//  ShortcutRecorder.swift
//  TWZ
//
//  Records a hotkey's, an order key's or the Charts window's keyboard shortcut: click, then press the keys.
//  Esc cancels, Delete clears. Shortcuts the app or macOS already uses, or another hotkey, order key or the
//  Charts window has, are refused with the reason.
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
            shortcut = nil
            return stop()
        }
        let new = KeyShortcut(event)
        if let reason = new.reservedFor {
            problem = "\(reason). Try another."
            return
        }
        if let other = workspace.hotkeys.first(where: { owner != .hotkey($0.id) && $0.shortcut == new }) {
            problem = "\(new.display) is already \"\(other.label)\". Try another."
            return
        }
        if let other = workspace.orderKeys.first(where: { owner != .orderKey($0.id) && $0.shortcut?.numberRow == new.numberRow }) {
            problem = "\(new.display) is already the order key \"\(other.label)\". Try another."
            return
        }
        // ⌃ and a hotkey's or order key's shortcut sends its order as a what-if trade (see `TradingShortcuts`),
        // so a shortcut can't be another's with ⌃ added or taken off.
        if owner != .chartsWindow {
            var flipped = new
            flipped.control.toggle()
            let other = workspace.hotkeys.first(where: { owner != .hotkey($0.id) && $0.shortcut == flipped })?.label
                ?? workspace.orderKeys.first(where: { owner != .orderKey($0.id) && $0.shortcut?.numberRow == flipped.numberRow })?.label
            if let other {
                problem = new.control
                    ? "\(new.display) is \"\(other)\" as a what-if trade (⌃ and its shortcut). Try another."
                    : "⌃\(new.display) would be \"\(other)\"'s own shortcut, not this one's what-if trade. Try another."
                return
            }
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
