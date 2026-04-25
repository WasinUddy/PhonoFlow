//
//  SpectrogramView.swift
//  PhonoFlow
//
//  Real-time frequency-over-time spectrogram with logarithmic Y-axis.
//

import SwiftUI

struct SpectrogramView: View {
    var spectrogramImage: CGImage?
    var sampleRate: Double
    var theme: ColorTheme
    @State private var showInfo = false

    private let minFreq: Double = 20
    private let maxFreq: Double = 20000

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                vizInfoButton(
                    title: "SPECTROGRAM",
                    showInfo: $showInfo,
                    tips: [
                        "Bright band at bottom (20-100 Hz) = turntable rumble",
                        "Darkness above 8-10 kHz = worn stylus",
                        "Vertical bright lines = clicks/pops (dust or scratches)",
                        "Persistent horizontal line = resonance or feedback",
                        "Faint haze above 5 kHz = surface noise",
                    ]
                )
                Spacer()
                Text("\u{2190} TIME")
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .foregroundStyle(.primary.opacity(0.3))
            }
            .padding(.bottom, 6)

            HStack(spacing: 0) {
                frequencyAxis
                    .frame(width: 32)

                ZStack {
                    // Background
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.primary.opacity(0.03))

                    if let image = spectrogramImage {
                        // .medium gives smooth visuals without the heavy per-frame
                        // Lanczos pass that .high triggers every redraw at 20+ fps.
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .interpolation(.medium)
                            .antialiased(false)
                            .cornerRadius(6)
                    } else {
                        Text("No signal")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.primary.opacity(0.3))
                    }

                    // Frequency grid overlay
                    Canvas { context, size in
                        let logMin = log10(minFreq)
                        let logRange = log10(maxFreq) - logMin
                        let gridFreqs: [Double] = [50, 100, 200, 500, 1000, 2000, 5000, 10000]

                        for freq in gridFreqs {
                            let logPos = (log10(freq) - logMin) / logRange
                            let y = size.height - size.height * CGFloat(logPos)
                            if y > 2, y < size.height - 2 {
                                var line = Path()
                                line.move(to: CGPoint(x: 0, y: y))
                                line.addLine(to: CGPoint(x: size.width, y: y))
                                context.stroke(line, with: .color(.white.opacity(0.12)), lineWidth: 0.5)
                            }
                        }
                    }
                    .allowsHitTesting(false)
                }
            }
            .frame(height: 180)

            intensityLegend
                .padding(.top, 4)
        }
    }

    // MARK: - Frequency Axis

    private var frequencyAxis: some View {
        GeometryReader { geo in
            let height = geo.size.height
            let logMin = log10(minFreq)
            let logRange = log10(maxFreq) - logMin

            let labels: [(String, Double)] = [
                ("20k", 20000),
                ("10k", 10000),
                ("5k", 5000),
                ("2k", 2000),
                ("1k", 1000),
                ("500", 500),
                ("200", 200),
                ("100", 100),
                ("50", 50),
                ("20", 20),
            ]

            ZStack(alignment: .trailing) {
                ForEach(labels, id: \.0) { label, freq in
                    let logPos = (log10(freq) - logMin) / logRange
                    let y = height - height * CGFloat(logPos)

                    if y >= 4, y <= height - 4 {
                        Text(label)
                            .font(.system(size: 7, weight: .medium, design: .monospaced))
                            .foregroundStyle(.primary.opacity(0.45))
                            .position(x: 14, y: y)
                    }
                }
            }
        }
    }

    // MARK: - Intensity Legend

    private var intensityLegend: some View {
        HStack(spacing: 4) {
            Text("Quiet")
                .font(.system(size: 7, weight: .medium, design: .monospaced))
                .foregroundStyle(.primary.opacity(0.35))

            LinearGradient(
                colors: [
                    Color(red: 0, green: 0, blue: 0),
                    Color(red: 0, green: 0, blue: 0.4),
                    Color(red: 0, green: 0, blue: 1),
                    Color(red: 0, green: 1, blue: 1),
                    Color(red: 0, green: 1, blue: 0.7),
                    Color(red: 0, green: 1, blue: 0),
                    Color(red: 1, green: 1, blue: 0),
                    Color(red: 1, green: 0.5, blue: 0),
                    Color(red: 1, green: 0, blue: 0),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: 100, height: 6)
            .cornerRadius(2)

            Text("Loud")
                .font(.system(size: 7, weight: .medium, design: .monospaced))
                .foregroundStyle(.primary.opacity(0.35))

            Spacer()

            Text("Hz")
                .font(.system(size: 7, weight: .medium, design: .monospaced))
                .foregroundStyle(.primary.opacity(0.35))
        }
    }
}
