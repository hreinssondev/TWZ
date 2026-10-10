//
//  MessageLabel.swift
//  TWZ
//
//  A one-line status or error message. Click it to read the whole message in a popover.
//

import AppKit
import SwiftUI

struct MessageLabel: View {
    let text: String
    var color: Color = .secondary
    var size: CGFloat = 10
    @State private var showingFull = false

    var body: some View {
        Button {
            showingFull = true
        } label: {
            Text(text)
                .font(.system(size: size))
                .foregroundStyle(color)
                .lineLimit(1)
                .truncationMode(.tail)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .help("Click to show the full message")
        .popover(isPresented: $showingFull, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text(text)
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                    .controlSize(.small)
                }
            }
            .padding(12)
            .frame(width: 360)
        }
    }
}
