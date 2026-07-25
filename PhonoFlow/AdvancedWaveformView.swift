//
//  AdvancedWaveformView.swift
//  PhonoFlow
//
//  Oscilloscope-style real-time waveform display.
//

import SwiftUI

struct AdvancedWaveformView: View {
    var leftWaveform: [Float]
    var rightWaveform: [Float]
    var theme: ColorTheme
    @State private var showInfo = false
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                vizInfoButton(
                    title: "WAVEFORM",
                    showInfo: $showInfo,
                    tips: [
                        "Tall waves = loud, flat line = silence",
                        "Flat ceiling at top/bottom = clipping (lower gain)",
                        "Compare L vs R — uneven = cartridge misalignment",
                        "Wiggly line during silence = surface noise or rumble",
                    ]
                )
                Spacer()
                HStack(spacing: 6) {
                    Circle()
                        .fill(theme.accent)
                        .frame(width: 6, height: 6)
                    Text("L")
                        .font(.caption2.monospaced().weight(.medium))
                        .foregroundStyle(
                            .primary.opacity(colorSchemeContrast == .increased ? 0.95 : 0.72)
                        )

                    Circle()
                        .fill(theme.meterGreen)
                        .frame(width: 6, height: 6)
                    Text("R")
                        .font(.caption2.monospaced().weight(.medium))
                        .foregroundStyle(
                            .primary.opacity(colorSchemeContrast == .increased ? 0.95 : 0.72)
                        )
                }
                .accessibilityHidden(true)
            }
            .padding(.bottom, 6)

            Canvas { context, size in
                let midY = size.height / 2
                let xStep = size.width / CGFloat(max(leftWaveform.count - 1, 1))

                // Draw grid lines
                context.opacity = colorSchemeContrast == .increased ? 0.28 : 0.14
                for i in [0.25, 0.5, 0.75] {
                    var line = Path()
                    let y = size.height * i
                    line.move(to: CGPoint(x: 0, y: y))
                    line.addLine(to: CGPoint(x: size.width, y: y))
                    context.stroke(line, with: .color(.primary), lineWidth: 0.5)
                }

                context.opacity = 1.0

                // Draw right channel (behind)
                if rightWaveform.count > 1 {
                    var pathR = Path()
                    for (index, sample) in rightWaveform.enumerated() {
                        let x = CGFloat(index) * xStep
                        let y = midY - CGFloat(sample) * (size.height / 2 * 0.85)
                        if index == 0 {
                            pathR.move(to: CGPoint(x: x, y: y))
                        } else {
                            pathR.addLine(to: CGPoint(x: x, y: y))
                        }
                    }
                    context.stroke(pathR, with: .color(theme.meterGreen.opacity(0.6)), lineWidth: 1.2)
                }

                // Draw left channel (front)
                if leftWaveform.count > 1 {
                    var pathL = Path()
                    for (index, sample) in leftWaveform.enumerated() {
                        let x = CGFloat(index) * xStep
                        let y = midY - CGFloat(sample) * (size.height / 2 * 0.85)
                        if index == 0 {
                            pathL.move(to: CGPoint(x: x, y: y))
                        } else {
                            pathL.addLine(to: CGPoint(x: x, y: y))
                        }
                    }
                    context.stroke(pathL, with: .color(theme.accent), lineWidth: 1.5)
                }
            }
            .frame(height: 112)
            .background(
                Color.primary.opacity(colorSchemeContrast == .increased ? 0.09 : 0.045)
            )
            .cornerRadius(6)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Live stereo waveform")
            .accessibilityValue(waveformAccessibilityValue)
            .accessibilityIdentifier("visualization.waveform")
        }
    }

    private var waveformAccessibilityValue: String {
        let leftPeak = leftWaveform.lazy.map { abs($0) }.max() ?? 0
        let rightPeak = rightWaveform.lazy.map { abs($0) }.max() ?? 0

        guard max(leftPeak, rightPeak) > 0.000_01 else {
            return "No signal"
        }

        let leftValue = decibelLabel(leftPeak)
        let rightValue = decibelLabel(rightPeak)
        let clipping =
            leftPeak >= 0.99 || rightPeak >= 0.99
            ? ", clipping detected"
            : ""
        return "Left peak \(leftValue), right peak \(rightValue)\(clipping)"
    }

    private func decibelLabel(_ level: Float) -> String {
        String(format: "%.1f decibels", max(20 * log10(max(level, 0.000_1)), -80))
    }
}
