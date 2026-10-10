//
//  ListPanel.swift
//  TWZ
//
//  Selectable symbol list. Clicking a row loads it into the selected chart.
//  Scanner lists (gainers, losers, most active…) will be added as more sources.
//

import SwiftUI

struct ListPanel: View {
    @Environment(Broker.self) private var broker
    @Environment(Workspace.self) private var workspace

    let panelId: String
    @AppStorage private var listName: String
    @State private var newSymbol = ""

    init(panelId: String, defaultList: String) {
        self.panelId = panelId
        _listName = AppStorage(wrappedValue: defaultList, "list.\(panelId)")
    }

    private var symbols: [String] { workspace.symbols(in: listName) }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $listName) {
                ForEach(Workspace.watchlistNames, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .controlSize(.small)
            .padding(6)

            columnHeader
            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(symbols, id: \.self) { symbol in
                        row(symbol)
                    }
                }
            }

            Divider()
            TextField("Add symbol", text: $newSymbol)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .padding(6)
                .onSubmit {
                    workspace.add(newSymbol, to: listName)
                    newSymbol = ""
                }
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.12)))
        .onAppear { broker.setQuoteSymbols(symbols, owner: panelId) }
        .onChange(of: symbols) { _, new in broker.setQuoteSymbols(new, owner: panelId) }
    }

    private var columnHeader: some View {
        HStack(spacing: 4) {
            Text("Symbol").frame(maxWidth: .infinity, alignment: .leading)
            Text("Last").frame(width: 58, alignment: .trailing)
            Text("%Chg").frame(width: 52, alignment: .trailing)
            Text("Vol").frame(width: 50, alignment: .trailing)
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.bottom, 3)
    }

    private func row(_ symbol: String) -> some View {
        let q = broker.quotes[symbol]
        let change = q?.changePercent
        let isCharted = workspace.selectedChart.symbol == symbol
        return HStack(spacing: 4) {
            Text(symbol).fontWeight(.semibold).frame(maxWidth: .infinity, alignment: .leading)
            Text(Fmt.price(q?.last)).frame(width: 58, alignment: .trailing)
            Text(Fmt.percent(change))
                .foregroundStyle(change == nil ? Color.secondary : (change! >= 0 ? Color.green : Color.red))
                .frame(width: 52, alignment: .trailing)
            Text(Fmt.volume(q?.volume)).foregroundStyle(.secondary).frame(width: 50, alignment: .trailing)
        }
        .font(.system(size: 11).monospacedDigit())
        .lineLimit(1)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(isCharted ? Color.accentColor.opacity(0.18) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            workspace.load(symbol, into: workspace.selectedChart, broker: broker)
        }
        .contextMenu {
            ForEach(workspace.charts) { chart in
                Button("Load into Chart \(chart.id + 1)") {
                    workspace.load(symbol, into: chart, broker: broker)
                }
            }
            Divider()
            Button("Remove \(symbol)", role: .destructive) {
                workspace.remove(symbol, from: listName)
            }
        }
    }
}
