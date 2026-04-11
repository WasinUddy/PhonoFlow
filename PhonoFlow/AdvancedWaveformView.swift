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

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("WAVEFORM")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary.opacity(0.5))
                Spacer()
                HStack(spacing: 6) {
                    Circle()
                        .fill(theme.accent)
                        .frame(width: 6, height: 6)
                    Text("L")
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                        .foregroundStyle(.primary.opacity(0.45))

                    Circle()
                        .fill(theme.meterGreen)
                        .frame(width: 6, height: 6)
                    Text("R")
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                        .foregroundStyle(.primary.opacity(0.45))
                }
            }
            .padding(.bottom, 6)

            Canvas { context, size in
                let midY = size.height / 2
                let xStep = size.width / CGFloat(max(leftWaveform.count - 1, 1))

                // Draw grid lines
                context.opacity = 0.08
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
            .frame(height: 100)
            .background(Color.primary.opacity(0.03))
            .cornerRadius(6)
        }
    }
}
