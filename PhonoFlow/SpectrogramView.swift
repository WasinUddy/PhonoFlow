//
//  SpectrogramView.swift
//  PhonoFlow
//
//  Real-time frequency-over-time visualization using FFT analysis.
//

import SwiftUI
import Accelerate

struct SpectrogramView: View {
    var spectrogramData: [[Float]]
    var theme: ColorTheme
    private let historyLength = 100

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("SPECTROGRAM")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary.opacity(0.5))
                Spacer()
                HStack(spacing: 8) {
                    Text("0 Hz")
                    Text("→")
                        .foregroundStyle(.primary.opacity(0.3))
                    Text("22 kHz")
                }
                .font(.system(size: 8, weight: .medium, design: .monospaced))
                .foregroundStyle(.primary.opacity(0.4))
            }
            .padding(.bottom, 6)

            Canvas { context, size in
                guard !spectrogramData.isEmpty else {
                    // Draw placeholder when no data
                    var text = context.resolve(Text("No signal").font(.system(size: 11, weight: .medium)))
                    text.shading = .color(.primary.opacity(0.3))
                    context.draw(text, at: CGPoint(x: size.width / 2, y: size.height / 2))
                    return
                }

                let colWidth = max(size.width / CGFloat(spectrogramData.count), 1)
                let spectrumSize = spectrogramData.first?.count ?? 128
                let rowHeight = size.height / CGFloat(spectrumSize)

                for (col, spectrum) in spectrogramData.enumerated() {
                    for (row, magnitude) in spectrum.enumerated() {
                        let x = CGFloat(col) * colWidth
                        let y = size.height - CGFloat(row + 1) * rowHeight
                        let rect = CGRect(x: x, y: y, width: colWidth + 1, height: rowHeight + 1)

                        let color = spectrogramColor(magnitude: magnitude)
                        context.fill(Path(rect), with: .color(color))
                    }
                }
            }
            .frame(height: 90)
            .background(Color.primary.opacity(0.03))
            .cornerRadius(6)
        }
    }

    private func spectrogramColor(magnitude: Float) -> Color {
        // Map magnitude (0.0 to 1.0) to color gradient
        let clamped = min(max(magnitude, 0), 1)

        if clamped < 0.2 {
            return Color(red: 0, green: 0, blue: Double(clamped * 2.5))
        } else if clamped < 0.5 {
            let t = (clamped - 0.2) / 0.3
            return Color(red: 0, green: Double(t), blue: 1)
        } else if clamped < 0.8 {
            let t = (clamped - 0.5) / 0.3
            return Color(red: Double(t), green: 1, blue: 1 - Double(t))
        } else {
            let t = (clamped - 0.8) / 0.2
            return Color(red: 1, green: 1 - Double(t * 0.5), blue: 0)
        }
    }
}
