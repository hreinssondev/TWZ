//
//  ChartsAxisText.swift
//  TWZ
//
//  Three sliders in a Charts window's top bar for its charts' axis text (not the price boxes): how bright the labels are,
//  their size, and their detail (how closely the price and time labels are packed). Each window keeps its own; until a
//  slider is moved, its charts go by Settings' price axis, as the main window's do. Right-click: back to Settings'.
//

import SwiftUI

enum ChartsAxisText {
    static let brightnessKey = "chartsAxisTextBrightness"
    static let sizeKey = "chartsAxisTextSize"
    static let spacingKey = "chartsAxisTextSpacing"
    static let brightnessRange = 0.15...1.0
    static let sizeRange = 7.0...14.0
    /// Where the brightness slider sits before it's moved: about Settings' gray.
    static let defaultBrightness = 0.55

    /// A window's own axis text; nil: Settings'.
    struct Look: Equatable {
        var brightness: Double?
        var size: Double?
        var spacing: Double?
    }
}

struct ChartsAxisTextSliders: View {
    let win: ChartsWin
    @AppStorage private var brightness: Double
    @AppStorage private var size: Double
    @AppStorage private var spacing: Double
    @AppStorage(PriceAxis.fontSizeKey) private var settingsSize = PriceAxis.defaultFontSize
    @AppStorage(PriceAxis.labelSpacingKey) private var settingsSpacing = PriceAxis.defaultLabelSpacing

    private static let sliderWidth: CGFloat = 64

    init(win: ChartsWin) {
        self.win = win
        _brightness = AppStorage(wrappedValue: ChartsAxisText.defaultBrightness, win.key(ChartsAxisText.brightnessKey))
        _size = AppStorage(wrappedValue: PriceAxis.defaultFontSize, win.key(ChartsAxisText.sizeKey))
        _spacing = AppStorage(wrappedValue: PriceAxis.defaultLabelSpacing, win.key(ChartsAxisText.spacingKey))
    }

    private func isSet(_ key: String) -> Bool { UserDefaults.standard.object(forKey: win.key(key)) != nil }

    var body: some View {
        // Unset, a slider shows what the charts go by: Settings' size and spacing.
        let shownSize = isSet(ChartsAxisText.sizeKey) ? size : settingsSize
        let shownSpacing = isSet(ChartsAxisText.spacingKey) ? spacing : settingsSpacing
        HStack(spacing: 4) {
            MiniSlider(label: "Text", valueText: "\(Int((brightness * 100).rounded()))%",
                       value: Binding(get: { brightness }, set: { brightness = ($0 * 20).rounded() / 20 }),
                       range: ChartsAxisText.brightnessRange)
                .frame(width: Self.sliderWidth)
                .help("How bright the axis labels are on these charts (not the price boxes). Right-click: back to Settings'")
            MiniSlider(label: "Size", valueText: "\(Int(shownSize))",
                       value: Binding(get: { shownSize }, set: { size = $0.rounded() }),
                       range: ChartsAxisText.sizeRange)
                .frame(width: Self.sliderWidth)
                .help("The axis labels' size on these charts. Right-click: back to Settings'")
            // More detail: less room between labels, so more of them.
            MiniSlider(label: "Detail", valueText: "\(Int((PriceAxis.labelSpacingRange.upperBound + PriceAxis.labelSpacingRange.lowerBound - shownSpacing).rounded()))",
                       value: Binding(get: { -shownSpacing }, set: { spacing = (-$0 / 5).rounded() * 5 }),
                       range: -PriceAxis.labelSpacingRange.upperBound ... -PriceAxis.labelSpacingRange.lowerBound)
                .frame(width: Self.sliderWidth)
                .help("How many price and time labels the axes show on these charts. Right-click: back to Settings'")
        }
        .contextMenu {
            Button("Axis text as in Settings") {
                for key in [ChartsAxisText.brightnessKey, ChartsAxisText.sizeKey, ChartsAxisText.spacingKey] {
                    UserDefaults.standard.removeObject(forKey: win.key(key))
                }
            }
        }
    }
}
