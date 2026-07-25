//
//  WaveformView.swift
//  PhonoFlow
//
//  Created by Wasin Silakong on 26/3/2569 BE.
//

import SwiftUI

private enum MeterLayout {
    static let segmentCount = 48
    static let gap: CGFloat = 1.5
    static let cornerRadius: CGFloat = 1.5
    static let height: CGFloat = 10
    static let channelLabelWidth: CGFloat = 10
    static let channelSpacing: CGFloat = 4

    static var meterLeadingInset: CGFloat {
        channelLabelWidth + channelSpacing
    }
}

struct WaveformView: View {
    var leftLevel: Float
    var rightLevel: Float
    @Binding var gain: Float
    @Binding var isAutoGainEnabled: Bool
    var theme: ColorTheme = .midnight
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    private var dimColor: Color {
        .primary.opacity(colorSchemeContrast == .increased ? 0.9 : 0.64)
    }

    private var subtleColor: Color {
        .primary.opacity(colorSchemeContrast == .increased ? 0.92 : 0.7)
    }

    private var midColor: Color {
        .primary.opacity(colorSchemeContrast == .increased ? 1 : 0.78)
    }

    private var unlitColor: Color {
        .primary.opacity(colorSchemeContrast == .increased ? 0.2 : 0.1)
    }

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
        return decibelsToMeterFraction(20 * log10(level))
    }

    private func decibelsToMeterFraction(_ decibels: Float) -> Float {
        max(
            0,
            min(
                1,
                (decibels - Self.meterMinDB) / (Self.meterMaxDB - Self.meterMinDB)
            )
        )
    }

    private func channelMeter(level: Float, label: String) -> some View {
        HStack(spacing: MeterLayout.channelSpacing) {
            Text(label)
                .font(.caption2.monospaced().weight(.semibold))
                .foregroundStyle(dimColor)
                .frame(width: MeterLayout.channelLabelWidth)
                .accessibilityHidden(true)

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
                .accessibilityHidden(true)
            }
            .frame(height: MeterLayout.height)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label == "L" ? "Left channel level" : "Right channel level")
        .accessibilityValue(levelAccessibilityValue(level))
    }

    private var meterScale: some View {
        GeometryReader { geometry in
            let meterWidth = max(geometry.size.width - MeterLayout.meterLeadingInset, 0)

            Canvas { context, _ in
                let ticks: [(label: String, decibels: Float)] = [
                    ("-\u{221E}", Self.meterMinDB),
                    ("-30", -30),
                    ("-20", -20),
                    ("-10", -10),
                    ("-3", -3),
                    ("0 dB", Self.meterMaxDB),
                ]

                for tick in ticks {
                    let fraction = CGFloat(decibelsToMeterFraction(tick.decibels))
                    let x = MeterLayout.meterLeadingInset + meterWidth * fraction
                    let anchor: UnitPoint =
                        if fraction == 0 {
                            .topLeading
                        } else if fraction == 1 {
                            .topTrailing
                        } else {
                            .top
                        }
                    let label = context.resolve(
                        Text(tick.label)
                            .font(.caption2.monospaced().weight(.medium))
                            .foregroundStyle(dimColor)
                    )
                    context.draw(label, at: CGPoint(x: x, y: 0), anchor: anchor)
                }
            }
        }
        .frame(height: 14)
        .accessibilityHidden(true)
    }

    // MARK: - Gain Slider

    private var gainSlider: some View {
        HStack(spacing: 6) {
            Image(systemName: "speaker.wave.1")
                .font(.system(size: 9))
                .foregroundStyle(subtleColor)
                .accessibilityHidden(true)

            Slider(value: $gain, in: 0...4, step: 0.05)
                .tint(theme.sliderTint)
                .disabled(isAutoGainEnabled)
                .accessibilityLabel("Input gain")
                .accessibilityValue(gainLabel)
                .accessibilityHint(
                    isAutoGainEnabled
                        ? "Automatic gain is enabled. Disable it to adjust input gain manually."
                        : "Adjusts the input gain from silence to twelve decibels."
                )

            Text(gainLabel)
                .font(.caption2.monospaced().weight(.medium))
                .foregroundStyle(midColor)
                .frame(width: 50, alignment: .trailing)
                .accessibilityHidden(true)

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
        .accessibilityLabel(isAutoGainEnabled ? "Disable automatic gain" : "Enable automatic gain")
        .accessibilityValue(isAutoGainEnabled ? "On" : "Off")
        .accessibilityHint("Automatic gain targets minus six decibels.")
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
        if fraction > MeterThresholds.peak { return AppColors.meterPeakRed }
        if fraction > MeterThresholds.warning { return AppColors.meterWarningYellow }
        return theme.meterGreen
    }

    private func levelAccessibilityValue(_ level: Float) -> String {
        guard level > 0.000_01 else { return "Silent" }
        let decibels = max(20 * log10(level), -80)
        if level >= 0.99 {
            return String(format: "%.1f decibels, clipping", decibels)
        }
        return String(format: "%.1f decibels", decibels)
    }
}
