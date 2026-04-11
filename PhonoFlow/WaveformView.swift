//
//  WaveformView.swift
//  PhonoFlow
//
//  Created by Wasin Silakong on 26/3/2569 BE.
//

import SwiftUI

private enum MeterLayout {
    static let segmentCount = 48
    static let gap: CGFloat         = 1.5
    static let cornerRadius: CGFloat = 1.5
    static let height: CGFloat      = 10
}

struct WaveformView: View {
    var leftLevel: Float
    var rightLevel: Float
    @Binding var gain: Float
    @Binding var isAutoGainEnabled: Bool
    var theme: ColorTheme = .midnight

    private var dimColor: Color { .primary.opacity(0.3) }
    private var subtleColor: Color { .primary.opacity(0.35) }
    private var midColor: Color { .primary.opacity(0.45) }
    private var unlitColor: Color { .primary.opacity(0.06) }

    var body: some View {
        VStack(spacing: 0) {
            dualMeterBars
            meterScale
                .padding(.top, 3)
            gainSlider
                .padding(.top, 6)
        }
    }

    // MARK: - Dual LED Meters

    private var dualMeterBars: some View {
        VStack(spacing: 3) {
            channelMeter(level: leftLevel, label: "L")
            channelMeter(level: rightLevel, label: "R")
        }
    }

    // Convert linear level (0-1) to dB-scaled meter fraction (0-1)
    // Maps -40 dB to 0 dB onto the full meter range
    private static let meterMinDB: Float = -40
    private static let meterMaxDB: Float = 0

    private func levelToMeterFraction(_ level: Float) -> Float {
        guard level > 0.00001 else { return 0 }
        let db = 20 * log10(level)
        return max(0, min(1, (db - Self.meterMinDB) / (Self.meterMaxDB - Self.meterMinDB)))
    }

    private func channelMeter(level: Float, label: String) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                .foregroundStyle(dimColor)
                .frame(width: 10)

            GeometryReader { geo in
                let count = MeterLayout.segmentCount
                let gap = MeterLayout.gap
                let segW = (geo.size.width - gap * CGFloat(count - 1)) / CGFloat(count)
                let meterFraction = levelToMeterFraction(level)

                Canvas { context, size in
                    for i in 0..<count {
                        let fraction = Float(i) / Float(count - 1)
                        let x = CGFloat(i) * (segW + gap)
                        let rect = CGRect(x: x, y: 0, width: segW, height: size.height)
                        let path = Path(roundedRect: rect, cornerRadius: MeterLayout.cornerRadius)

                        let lit = fraction <= meterFraction
                        context.fill(path, with: .color(segmentColor(at: fraction, lit: lit)))
                    }
                }
            }
            .frame(height: MeterLayout.height)
        }
    }

    private var meterScale: some View {
        HStack {
            Spacer().frame(width: 14)
            Text("-\u{221E}")
            Spacer()
            Text("-30")
            Spacer()
            Text("-20")
            Spacer()
            Text("-10")
            Spacer()
            Text("-3")
            Spacer()
            Text("0 dB")
        }
        .font(.system(size: 7, weight: .medium, design: .monospaced))
        .foregroundStyle(dimColor)
    }

    // MARK: - Gain Slider

    private var gainSlider: some View {
        HStack(spacing: 6) {
            Image(systemName: "speaker.wave.1")
                .font(.system(size: 9))
                .foregroundStyle(subtleColor)

            Slider(value: $gain, in: 0...4, step: 0.05)
                .tint(theme.sliderTint)
                .disabled(isAutoGainEnabled)

            Text(gainLabel)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(midColor)
                .frame(width: 50, alignment: .trailing)

            autoGainButton
        }
    }

    private var autoGainButton: some View {
        Button(action: { isAutoGainEnabled.toggle() }) {
            Image(systemName: isAutoGainEnabled ? "wand.and.stars" : "wand.and.stars.inverse")
                .font(.system(size: 10))
                .foregroundStyle(isAutoGainEnabled ? theme.sliderTint : subtleColor)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isAutoGainEnabled ? "Disable Auto-Gain" : "Enable Auto-Gain (normalizes to -6dB)")
    }

    private var gainLabel: String {
        if gain < 0.001 { return "-\u{221E} dB" }
        let dB = 20 * log10(gain)
        let sign = dB >= 0 ? "+" : ""
        return String(format: "%@%.1f dB", sign, dB)
    }

    // MARK: - Helpers

    private func segmentColor(at fraction: Float, lit: Bool) -> Color {
        if !lit { return unlitColor }
        if fraction > MeterThresholds.peak    { return AppColors.meterPeakRed }
        if fraction > MeterThresholds.warning { return AppColors.meterWarningYellow }
        return theme.meterGreen
    }
}
