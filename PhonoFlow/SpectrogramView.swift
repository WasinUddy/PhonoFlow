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
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    private let minFreq: Double = 20
    private let maxFreq: Double = 20000
    private let frequencyAxisWidth: CGFloat = 32

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
                Text(sampleRateLabel)
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.58))
                    .accessibilityHidden(true)
                Text("•")
                    .font(.system(size: 8))
                    .foregroundStyle(.white.opacity(0.35))
                    .accessibilityHidden(true)
                Text("\u{2190} TIME")
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.58))
                    .accessibilityHidden(true)
            }
            .padding(.bottom, 6)

            HStack(spacing: 0) {
                frequencyAxis
                    .frame(width: frequencyAxisWidth)

                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(red: 0.012, green: 0.016, blue: 0.027))

                    if let image = spectrogramImage {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .interpolation(.medium)
                            .antialiased(false)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    } else {
                        ContentUnavailableView {
                            Label("No Signal", systemImage: "waveform.slash")
                        } description: {
                            Text("Waiting for spectrum data")
                        }
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.56))
                    }

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
                                context.stroke(
                                    line,
                                    with: .color(
                                        .white.opacity(
                                            colorSchemeContrast == .increased ? 0.28 : 0.12
                                        )),
                                    lineWidth: colorSchemeContrast == .increased ? 1 : 0.5
                                )
                            }
                        }
                    }
                    .allowsHitTesting(false)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(theme.accent.opacity(0.34), lineWidth: 1)
                        .allowsHitTesting(false)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Live spectrogram")
                .accessibilityValue(
                    spectrogramImage == nil
                        ? "No spectrum data"
                        : "Frequency history from 20 hertz to 20000 hertz at \(sampleRateLabel)"
                )
                .accessibilityIdentifier("visualization.spectrogram")
            }
            .frame(height: 180)

            intensityLegend
                .padding(.top, 4)
                .padding(.leading, frequencyAxisWidth)
                .accessibilityHidden(true)
        }
    }

    // MARK: - Frequency Axis

    private var frequencyAxis: some View {
        GeometryReader { geo in
            let height = geo.size.height
            let labelWidth = max(0, geo.size.width - 4)
            let labelHeight: CGFloat = 10
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
                    let rawY = height - height * CGFloat(logPos)
                    let y = min(
                        max(rawY, labelHeight / 2),
                        height - labelHeight / 2
                    )

                    Text(label)
                        .font(.system(size: 7, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.58))
                        .frame(
                            width: labelWidth,
                            height: labelHeight,
                            alignment: .trailing
                        )
                        .position(x: labelWidth / 2, y: y)
                }
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: - Intensity Legend

    private var intensityLegend: some View {
        HStack(spacing: 4) {
            Text("Quiet")
                .font(.system(size: 7, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.52))

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
                .foregroundStyle(.white.opacity(0.52))

            Spacer()

            Text("Hz")
                .font(.system(size: 7, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.52))
        }
    }

    private var sampleRateLabel: String {
        sampleRate >= 1_000
            ? String(format: "%.1f kHz", sampleRate / 1_000)
            : String(format: "%.0f Hz", sampleRate)
    }
}
