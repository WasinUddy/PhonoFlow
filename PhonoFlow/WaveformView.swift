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
    static let height: CGFloat      = 12
}

struct WaveformView: View {
    var peakLevel: Float
    @Binding var gain: Float
    var theme: ColorTheme = .midnight

    private var dimColor: Color { .primary.opacity(0.3) }
    private var subtleColor: Color { .primary.opacity(0.35) }
    private var midColor: Color { .primary.opacity(0.45) }
    private var unlitColor: Color { .primary.opacity(0.06) }

    var body: some View {
        VStack(spacing: 0) {
            meterBar
            meterScale
                .padding(.top, 4)
            gainSlider
                .padding(.top, 8)
        }
    }

    // MARK: - LED Meter

    private var meterBar: some View {
        GeometryReader { geo in
            let count = MeterLayout.segmentCount
            let gap   = MeterLayout.gap
            let segW  = (geo.size.width - gap * CGFloat(count - 1)) / CGFloat(count)

            Canvas { context, size in
                for i in 0..<count {
                    let fraction = Float(i) / Float(count - 1)
                    let x    = CGFloat(i) * (segW + gap)
                    let rect = CGRect(x: x, y: 0, width: segW, height: size.height)
                    let path = Path(roundedRect: rect, cornerRadius: MeterLayout.cornerRadius)

                    let lit = fraction <= peakLevel
                    context.fill(path, with: .color(segmentColor(at: fraction, lit: lit)))
                }
            }
        }
        .frame(height: MeterLayout.height)
    }

    private var meterScale: some View {
        HStack {
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

            Text(gainLabel)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(midColor)
                .frame(width: 50, alignment: .trailing)
        }
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
