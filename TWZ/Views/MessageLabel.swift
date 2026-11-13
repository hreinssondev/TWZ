//
//  MessageLabel.swift
//  TWZ
//
//  A one-line status or error message. Click it to read the whole message in a popover.
//  `FloatingMessages`: the same, floating over the charts while the hotkey row is collapsed (and
//  with it the line that shows messages); its popover also lists the latest messages.
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

/// The latest message in a bar as wide as the charts, floating at their bottom, for when the hotkey
/// row (whose header shows it) is collapsed. Each message shows for 10 seconds, or until the list
/// opened by clicking it (the whole message and the ones before it) closes; × hides it sooner.
struct FloatingMessages: View {
    @Environment(Broker.self) private var broker
    @State private var showingAll = false
    /// The message hidden by × or after its 10 seconds.
    @State private var dismissed: UUID?
    /// The message whose 10 seconds ran out while its list was open.
    @State private var expired: UUID?

    private static let shownFor: TimeInterval = 10

    var body: some View {
        // Counted from the message's arrival, so collapsing the row later doesn't bring back an old one.
        if let latest = broker.messageHistory.last, latest.id != dismissed,
           Date().timeIntervalSince(latest.time) < Self.shownFor || expired == latest.id {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.bubble")
                    .foregroundStyle(.orange)
                Text(latest.text)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 6)
                Text(latest.time, format: .dateTime.hour().minute().second())
                    .foregroundStyle(.secondary)
                Button {
                    dismissed = latest.id
                } label: {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Hide until the next message")
            }
            .font(.system(size: 11))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.orange.opacity(0.4)))
            .shadow(color: .black.opacity(0.3), radius: 4, y: 1)
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .onTapGesture { showingAll = true }
            .pointerStyle(.link)
            .help("Click to show the whole message and the ones before it")
            .popover(isPresented: $showingAll, arrowEdge: .top) { history }
            .task(id: latest.id) {
                let left = Self.shownFor - Date().timeIntervalSince(latest.time)
                if left > 0 { try? await Task.sleep(for: .seconds(left)) }
                guard !Task.isCancelled else { return }
                if showingAll { expired = latest.id } else { dismissed = latest.id }
            }
            .onChange(of: showingAll) { _, open in
                if !open, let expired { dismissed = expired }
            }
        }
    }

    /// Newest first, each selectable, with a button to copy them all.
    private var history: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(broker.messageHistory.reversed()) { m in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(m.time, format: .dateTime.hour().minute().second())
                                .font(.system(size: 10).monospacedDigit())
                                .foregroundStyle(.secondary)
                            Text(m.text)
                                .font(.system(size: 12))
                                .foregroundStyle(m.id == broker.messageHistory.last?.id ? Color.orange : Color.primary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Divider()
                    }
                }
            }
            .frame(maxHeight: 360)
            HStack {
                Spacer()
                Button("Copy All") {
                    let text = broker.messageHistory.reversed()
                        .map { "\($0.time.formatted(.dateTime.hour().minute().second()))  \($0.text)" }
                        .joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                .controlSize(.small)
            }
        }
        .padding(12)
        .frame(width: 420)
    }
}
