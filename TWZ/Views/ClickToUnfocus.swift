//
//  ClickToUnfocus.swift
//  TWZ
//
//  In the main window, clicking anywhere outside the text field being edited (a chart, a list,
//  a button) ends the editing, as SwiftUI won't on clicks that land on non-focusable views.
//  Sheets and popovers keep the standard behavior.
//

import AppKit
import SwiftUI

struct ClickToUnfocus: ViewModifier {
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard monitor == nil else { return }
                monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
                    guard let window = event.window, window === NSApp.mainWindow,
                          let editor = window.firstResponder as? NSTextView, editor.isFieldEditor,
                          let field = editor.delegate as? NSTextField else { return event }
                    let point = field.convert(event.locationInWindow, from: nil)
                    if !field.bounds.contains(point) { window.makeFirstResponder(nil) }
                    return event
                }
            }
            .onDisappear {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
            }
    }
}
