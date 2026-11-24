//
//  NewsTab.swift
//  TWZ
//
//  A list panel's News tab (beside its list; the panel's top bar switches): headlines from IB's free
//  providers (see `News`), for the selected chart's stock or all news, newest first. Those from
//  before the last close are dimmed. Clicking a headline opens its article.
//

import AppKit
import SwiftUI

/// Whose news the tab shows.
enum NewsScope: String {
    /// The selected chart's stock.
    case stock
    /// Everything the providers send (Briefing.com's columns and Dow Jones' newsletters).
    case all
}

struct NewsTab: View {
    @Environment(Broker.self) private var broker
    @Environment(Workspace.self) private var workspace
    @AppStorage(Dimmed.opacityKey) private var dimmedOpacity = Dimmed.defaultOpacity
    let scope: NewsScope
    @State private var opened: String?

    var body: some View {
        let feed = scope == .all ? News.allFeed : workspace.targetSymbol
        Group {
            if broker.state != .connected {
                note("Not connected")
            } else if feed.isEmpty {
                note("Select a chart to see its news")
            } else if ForexPair.isForex(feed) {
                note("No news for forex pairs")
            } else if let items = broker.news[feed], !items.isEmpty {
                let lastClose = News.lastClose()
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(items) { row($0, old: $0.time < lastClose) }
                    }
                }
            } else if let error = broker.newsError {
                note(error)
            } else {
                note(scope == .all ? "Waiting for headlines…" : "No headlines for \(feed)")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func row(_ item: NewsItem, old: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Text(Self.time(item.time))
                Text(News.providerName(item.provider))
                Spacer(minLength: 0)
            }
            .font(.system(size: 10).monospacedDigit())
            .foregroundStyle(.secondary)
            Text(item.headline)
                .font(.system(size: 11))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .opacity(old ? dimmedOpacity : 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(opened == item.id ? Color.accentColor.opacity(0.18) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            opened = item.id
            broker.loadNewsArticle(item)
        }
        .popover(isPresented: Binding(get: { opened == item.id }, set: { if !$0, opened == item.id { opened = nil } }),
                 arrowEdge: .leading) {
            NewsArticleView(item: item).environment(broker)
        }
        .help("Click to read")
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
    }

    /// "14:32" today, "21 Nov" before.
    static func time(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
            : date.formatted(.dateTime.day().month(.abbreviated))
    }
}

/// An article, in the popover a headline opens.
private struct NewsArticleView: View {
    @Environment(Broker.self) private var broker
    let item: NewsItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.headline)
                .font(.system(size: 13, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text("\(News.providerName(item.provider)) · \(item.time.formatted(date: .abbreviated, time: .shortened))")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Divider()
            if let article = broker.newsArticles[item.id] {
                if let error = article.error {
                    Text(error).font(.system(size: 12)).foregroundStyle(.red)
                } else if let pdf = article.pdf {
                    Button("Open the PDF") { Self.open(pdf, id: item.id) }
                } else {
                    let text = Text(article.text ?? "")
                        .font(.system(size: 12))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ViewThatFits(in: .vertical) {
                        text
                        ScrollView { text }
                    }
                    if let link = article.link {
                        Link("Read the full article", destination: link).font(.system(size: 12))
                    }
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .padding(12)
        .frame(width: 420)
        .frame(maxHeight: 520)
    }

    private static func open(_ pdf: Data, id: String) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(id.replacingOccurrences(of: "/", with: "-") + ".pdf")
        guard (try? pdf.write(to: url)) != nil else { return }
        NSWorkspace.shared.open(url)
    }
}
