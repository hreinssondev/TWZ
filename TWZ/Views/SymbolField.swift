//
//  SymbolField.swift
//  TWZ
//
//  A chart's symbol box that only a click on it starts editing: AppKit otherwise hands the focus to the
//  window's first text field on its own (the window becoming key, a sheet closing, Tab, a field ending
//  its editing), and keys meant for the selected chart went into it. Return submits; the text keeps to
//  `text` while not being edited, and `isFocused` follows the editing (set false, it ends it).
//

import AppKit
import SwiftUI

struct SymbolField: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    var onSubmit: () -> Void

    func makeNSView(context: Context) -> ClickOnlyTextField {
        let field = ClickOnlyTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13, weight: .bold)
        field.placeholderString = "Symbol"
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.lineBreakMode = .byClipping
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.delegate = context.coordinator
        field.stringValue = text
        field.onFocus = { [weak coordinator = context.coordinator] in coordinator?.parent.isFocused = true }
        return field
    }

    func updateNSView(_ field: ClickOnlyTextField, context: Context) {
        context.coordinator.parent = self
        let editing = field.currentEditor() != nil
        if !editing, field.stringValue != text { field.stringValue = text }
        if !isFocused, editing { field.window?.makeFirstResponder(nil) }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SymbolField
        init(_ parent: SymbolField) { self.parent = parent }

        func controlTextDidChange(_ note: Notification) {
            if let field = note.object as? NSTextField { parent.text = field.stringValue }
        }

        func controlTextDidEndEditing(_ note: Notification) {
            if parent.isFocused { parent.isFocused = false }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.text = textView.string
                parent.onSubmit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                // Esc leaves the box, dropping the edit.
                parent.isFocused = false
                return true
            default:
                return false
            }
        }
    }
}

/// Takes the focus only from a mouse click inside it.
final class ClickOnlyTextField: NSTextField {
    var onFocus: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        guard let event = NSApp.currentEvent, event.type == .leftMouseDown, event.window === window,
              bounds.contains(convert(event.locationInWindow, from: nil)) else { return false }
        let became = super.becomeFirstResponder()
        if became { onFocus?() }
        return became
    }
}
