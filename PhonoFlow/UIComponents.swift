//
//  UIComponents.swift
//  PhonoFlow
//
//  Reusable UI components and styles
//

import SwiftUI

// MARK: - Surfaces

/// A macOS 26 Liquid Glass surface for controls and navigation chrome.
///
/// Rapidly changing plots should use ``SolidVisualizationSurface`` instead so
/// the system doesn't continuously re-composite glass behind live pixels.
struct LiquidGlassSection<Content: View>: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var tint: Color?
    @ViewBuilder let content: () -> Content

    init(tint: Color? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.tint = tint
        self.content = content
    }

    var body: some View {
        if reduceTransparency {
            sectionContent
                .background(
                    Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(.primary.opacity(0.12), lineWidth: 1)
                }
        } else {
            sectionContent
                .glassEffect(
                    .regular.tint(tint),
                    in: .rect(cornerRadius: 16)
                )
        }
    }

    private var sectionContent: some View {
        content()
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// An opaque, high-contrast canvas for live meters and visualizations.
struct SolidVisualizationSurface<Content: View>: View {
    var accent: Color
    @ViewBuilder let content: () -> Content
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    init(accent: Color, @ViewBuilder content: @escaping () -> Content) {
        self.accent = accent
        self.content = content
    }

    var body: some View {
        content()
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color(red: 0.035, green: 0.045, blue: 0.065),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(
                        accent.opacity(colorSchemeContrast == .increased ? 0.72 : 0.36),
                        lineWidth: colorSchemeContrast == .increased ? 1.5 : 1
                    )
            }
            .environment(\.colorScheme, .dark)
    }
}

struct PhonoSectionHeader<Trailing: View>: View {
    let title: String
    let subtitle: String?
    let systemImage: String
    @ViewBuilder let trailing: () -> Trailing

    init(
        _ title: String,
        subtitle: String? = nil,
        systemImage: String,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 16)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .accessibilityElement(children: .combine)

            Spacer(minLength: 8)
            trailing()
        }
    }
}

extension PhonoSectionHeader where Trailing == EmptyView {
    init(_ title: String, subtitle: String? = nil, systemImage: String) {
        self.init(title, subtitle: subtitle, systemImage: systemImage) {
            EmptyView()
        }
    }
}

// MARK: - Visualization Info Button

/// Reusable info button for visualization headers. Shows a popover with interpretation tips.
func vizInfoButton(title: String, showInfo: Binding<Bool>, tips: [String]) -> some View {
    VisualizationInfoButton(title: title, showInfo: showInfo, tips: tips)
}

private struct VisualizationInfoButton: View {
    let title: String
    @Binding var showInfo: Bool
    let tips: [String]
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        HStack(spacing: 5) {
            Text(title)
                .font(
                    .system(
                        size: 11,
                        weight: .semibold,
                        design: .rounded
                    )
                )
                .foregroundStyle(
                    .primary.opacity(colorSchemeContrast == .increased ? 1 : 0.78)
                )

            Button(action: { showInfo.toggle() }) {
                Image(systemName: "info.circle.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(
                        .primary.opacity(colorSchemeContrast == .increased ? 1 : 0.82)
                    )
                    .frame(width: 22, height: 22)
                    .contentShape(Circle())
                    .glassEffect(
                        .regular
                            .tint(.primary.opacity(colorSchemeContrast == .increased ? 0.18 : 0.09))
                            .interactive(),
                        in: .circle
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("About \(title.lowercased())")
            .accessibilityHint("Shows tips for reading this visualization.")
            .popover(isPresented: $showInfo, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("How to Read")
                        .font(.headline)
                        .foregroundStyle(.primary)

                    ForEach(tips, id: \.self) { tip in
                        HStack(alignment: .top, spacing: 6) {
                            Circle()
                                .fill(
                                    .primary.opacity(
                                        colorSchemeContrast == .increased ? 0.9 : 0.65
                                    )
                                )
                                .frame(width: 4, height: 4)
                                .padding(.top, 5)
                                .accessibilityHidden(true)
                            Text(tip)
                                .font(.caption)
                                .foregroundStyle(
                                    .primary.opacity(
                                        colorSchemeContrast == .increased ? 1 : 0.88
                                    )
                                )
                        }
                    }
                }
                .padding(12)
                .frame(width: 280)
            }
        }
    }
}

// MARK: - Equalizer View

struct EqualizerView: View {
    @Binding var eqBands: [Float]
    var theme: ColorTheme = .midnight
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @State private var selectedPreset = "Flat"
    @State private var selectedBandIndex = 0
    @State private var customPresets: [String: [Float]] = [:]
    @State private var showSaveDialog = false
    @State private var newPresetName = ""

    private let graphHorizontalInset: CGFloat = 4

    let bandLabels = ["31Hz", "62Hz", "125Hz", "250Hz", "500Hz", "1kHz", "2kHz", "4kHz", "8kHz", "16kHz"]
    let bandNames = ["Sub", "Bass", "B+", "Low M", "Mid", "Mid", "U.Mid", "Pres", "Treb", "Air"]

    let defaultPresets: [String: [Float]] = [
        "Flat": [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
        "Bass Boost": [6, 4, 1, -2, -3, -2, 0, 1, 2, 3],
        "Treble Boost": [-1, -2, -2, -1, 0, 2, 4, 6, 8, 9],
        "Vocal": [-4, -2, 1, 3, 4, 3, 2, 1, -1, -3],
        "Warm": [4, 3, 1, 0, -1, 0, 1, 2, 3, 4],
    ]

    var allPresets: [String: [Float]] {
        var all = defaultPresets
        all.merge(customPresets) { _, custom in custom }
        return all
    }

    var presetKeys: [String] {
        Array(allPresets.keys).sorted()
    }

    var body: some View {
        VStack(spacing: 10) {
            // Load custom presets from UserDefaults on first appearance
            EmptyView()
                .onAppear {
                    loadCustomPresets()
                }

            // Preset dropdown with expanded width and controls
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    Picker("Preset", selection: $selectedPreset) {
                        ForEach(presetKeys, id: \.self) { preset in
                            Text(preset).tag(preset)
                        }
                    }
                    .pickerStyle(.menu)
                    .font(.system(size: 11, weight: .medium))
                    .onChange(of: selectedPreset) { _, newPreset in
                        if let presetValues = allPresets[newPreset] {
                            eqBands = presetValues
                        }
                    }

                    Button(action: { showSaveDialog = true }) {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.glass)
                    .help("Save current settings as preset")
                    .accessibilityLabel("Save equalizer preset")

                    if customPresets[selectedPreset] != nil {
                        Button(action: deletePreset) {
                            Image(systemName: "trash")
                                .font(.system(size: 10))
                        }
                        .buttonStyle(.glass)
                        .help("Delete this custom preset")
                        .accessibilityLabel("Delete \(selectedPreset) preset")
                    }

                    Spacer()
                }
            }
            .padding(.horizontal, 4)

            // Save preset dialog
            if showSaveDialog {
                HStack(spacing: 6) {
                    TextField("Preset name", text: $newPresetName)
                        .font(.system(size: 10))
                        .textFieldStyle(.roundedBorder)

                    Button("Save") {
                        if !newPresetName.isEmpty {
                            customPresets[newPresetName] = eqBands
                            saveCustomPresets()
                            selectedPreset = newPresetName
                            newPresetName = ""
                            showSaveDialog = false
                        }
                    }
                    .buttonStyle(.glassProminent)

                    Button("Cancel") {
                        newPresetName = ""
                        showSaveDialog = false
                    }
                    .buttonStyle(.glass)
                }
                .padding(.horizontal, 4)
            }

            // Band name labels on top
            HStack(spacing: 0) {
                ForEach(0..<10, id: \.self) { index in
                    Text(bandNames[index])
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(equalizerSecondaryText)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .padding(.horizontal, graphHorizontalInset)

            // Graph view
            AnalogEqualizerGraphContent(eqBands: $eqBands, theme: theme)
                .frame(height: 140)
                .padding(.horizontal, graphHorizontalInset)
                .accessibilityHidden(true)

            // Frequency labels
            HStack(spacing: 0) {
                ForEach(0..<10, id: \.self) { index in
                    VStack(spacing: 1) {
                        Text(bandLabels[index])
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(equalizerSecondaryText)
                        Text(String(format: "%+.0f", eqBands[index]))
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundStyle(
                                eqBands[index] == 0 ? .secondary : (eqBands[index] > 0 ? theme.accent : Color.orange))
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .padding(.horizontal, graphHorizontalInset)

            HStack(spacing: 8) {
                Picker("Band", selection: $selectedBandIndex) {
                    ForEach(bandLabels.indices, id: \.self) { index in
                        Text(bandLabels[index]).tag(index)
                    }
                }
                .frame(width: 108)

                Slider(
                    value: selectedBandBinding,
                    in: -12...12,
                    step: 0.5
                )
                .tint(theme.sliderTint)
                .accessibilityLabel("\(selectedBandLabel) equalizer level")

                Text(String(format: "%+.1f dB", selectedBandValue))
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .frame(width: 58, alignment: .trailing)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("processing.equalizer.bandEditor")
        }
    }

    private var selectedBandBinding: Binding<Float> {
        Binding(
            get: { selectedBandValue },
            set: { newValue in
                guard eqBands.indices.contains(selectedBandIndex) else { return }
                eqBands[selectedBandIndex] = min(12, max(-12, newValue))
            }
        )
    }

    private var selectedBandValue: Float {
        guard eqBands.indices.contains(selectedBandIndex) else { return 0 }
        return eqBands[selectedBandIndex]
    }

    private var selectedBandLabel: String {
        guard bandLabels.indices.contains(selectedBandIndex) else { return "Equalizer" }
        return bandLabels[selectedBandIndex]
    }

    private var equalizerSecondaryText: Color {
        .primary.opacity(colorSchemeContrast == .increased ? 0.95 : 0.68)
    }

    private func deletePreset() {
        customPresets.removeValue(forKey: selectedPreset)
        saveCustomPresets()
        selectedPreset = "Flat"
        if let flatValues = allPresets["Flat"] {
            eqBands = flatValues
        }
    }

    private func loadCustomPresets() {
        if let data = UserDefaults.standard.data(forKey: "EQCustomPresets") {
            do {
                let decoded = try JSONDecoder().decode([String: [Float]].self, from: data)
                customPresets = decoded
            } catch {
                print("Failed to load custom presets: \(error)")
            }
        }
    }

    private func saveCustomPresets() {
        do {
            let data = try JSONEncoder().encode(customPresets)
            UserDefaults.standard.set(data, forKey: "EQCustomPresets")
        } catch {
            print("Failed to save custom presets: \(error)")
        }
    }
}

// MARK: - Analog Equalizer Graph Content

struct AnalogEqualizerGraphContent: View {
    @Binding var eqBands: [Float]
    var theme: ColorTheme = .midnight
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                drawGraph(context: &context, size: size)
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(in: geometry.size))
        }
        .background(
            Color(red: 0.035, green: 0.045, blue: 0.065),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(
                    .white.opacity(colorSchemeContrast == .increased ? 0.38 : 0.18),
                    lineWidth: colorSchemeContrast == .increased ? 1.5 : 1
                )
        }
        .environment(\.colorScheme, .dark)
    }

    private func drawGraph(context: inout GraphicsContext, size: CGSize) {
        let width = size.width
        let height = size.height
        let centerY = height / 2
        let bandCount = eqBands.count
        guard width > 0, height > 0, bandCount > 0 else { return }

        let pixelsPerDB: CGFloat = 5.0
        var gridPath = Path()

        for y in stride(from: 0, through: height, by: height / 4) {
            gridPath.move(to: CGPoint(x: 0, y: y))
            gridPath.addLine(to: CGPoint(x: width, y: y))
        }

        for index in 0...bandCount {
            let x = (width / CGFloat(bandCount)) * CGFloat(index)
            gridPath.move(to: CGPoint(x: x, y: 0))
            gridPath.addLine(to: CGPoint(x: x, y: height))
        }

        context.stroke(
            gridPath,
            with: .color(
                Color.primary.opacity(colorSchemeContrast == .increased ? 0.28 : 0.14)
            ),
            lineWidth: colorSchemeContrast == .increased ? 1 : 0.5
        )

        var centerLine = Path()
        centerLine.move(to: CGPoint(x: 0, y: centerY))
        centerLine.addLine(to: CGPoint(x: width, y: centerY))
        context.stroke(
            centerLine,
            with: .color(
                Color.primary.opacity(colorSchemeContrast == .increased ? 0.62 : 0.36)
            ),
            lineWidth: colorSchemeContrast == .increased ? 1.5 : 1
        )

        let bandWidth = width / CGFloat(bandCount)
        let curvePoints = eqBands.enumerated().map { index, gain in
            CGPoint(
                x: bandWidth * (CGFloat(index) + 0.5),
                y: centerY - CGFloat(gain) * pixelsPerDB
            )
        }

        let leftEdgePoint = CGPoint(x: 0, y: centerY)
        let rightEdgePoint = CGPoint(x: width, y: centerY)
        var allPoints = [leftEdgePoint]
        allPoints.append(contentsOf: curvePoints)
        allPoints.append(rightEdgePoint)

        var curve = Path()
        curve.move(to: leftEdgePoint)

        for index in 1..<allPoints.count {
            let current = allPoints[index]
            let previous = allPoints[index - 1]
            let previousPoint = index > 1 ? allPoints[index - 2] : previous
            let nextPoint = index < allPoints.count - 1 ? allPoints[index + 1] : current
            let dx = current.x - previous.x
            let dy = current.y - previous.y
            let previousTangent =
                index > 1
                ? CGPoint(x: current.x - previousPoint.x, y: current.y - previousPoint.y)
                : CGPoint(x: dx, y: dy)
            let nextTangent =
                index < allPoints.count - 1
                ? CGPoint(x: nextPoint.x - previous.x, y: nextPoint.y - previous.y)
                : CGPoint(x: dx, y: dy)
            let smoothing: CGFloat = 0.15

            curve.addCurve(
                to: current,
                control1: CGPoint(
                    x: previous.x + previousTangent.x * smoothing,
                    y: previous.y + previousTangent.y * smoothing
                ),
                control2: CGPoint(
                    x: current.x - nextTangent.x * smoothing,
                    y: current.y - nextTangent.y * smoothing
                )
            )
        }

        context.stroke(curve, with: .color(theme.accent), lineWidth: 2)

        let pointSize: CGFloat = 6
        for point in curvePoints {
            context.fill(
                Path(
                    ellipseIn: CGRect(
                        x: point.x - pointSize / 2,
                        y: point.y - pointSize / 2,
                        width: pointSize,
                        height: pointSize
                    )
                ),
                with: .color(theme.accent)
            )
        }

        let gradientWidth: CGFloat = 20
        context.fill(
            Path(CGRect(x: 0, y: 0, width: gradientWidth, height: height)),
            with: .linearGradient(
                Gradient(colors: [Color.secondary.opacity(0.05), Color.clear]),
                startPoint: .zero,
                endPoint: CGPoint(x: gradientWidth, y: 0)
            )
        )
        context.fill(
            Path(CGRect(x: width - gradientWidth, y: 0, width: gradientWidth, height: height)),
            with: .linearGradient(
                Gradient(colors: [Color.clear, Color.secondary.opacity(0.05)]),
                startPoint: CGPoint(x: width - gradientWidth, y: 0),
                endPoint: CGPoint(x: width, y: 0)
            )
        )
    }

    private func dragGesture(in size: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { gesture in
                let width = size.width
                let height = size.height
                let bandCount = eqBands.count
                guard width > 0, height > 0, bandCount > 0 else { return }

                let centerY = height / 2
                let pixelsPerDB: CGFloat = 5.0
                let bandWidth = width / CGFloat(bandCount)
                var closestIndex = 0
                var minimumDistance = CGFloat.infinity

                for index in 0..<bandCount {
                    let bandX = bandWidth * (CGFloat(index) + 0.5)
                    let bandY = centerY - CGFloat(eqBands[index]) * pixelsPerDB
                    let distance = hypot(
                        gesture.location.x - bandX,
                        gesture.location.y - bandY
                    )
                    if distance < minimumDistance {
                        minimumDistance = distance
                        closestIndex = index
                    }
                }

                if minimumDistance < 25 {
                    let newLevel = Float((centerY - gesture.location.y) / pixelsPerDB)
                    eqBands[closestIndex] = min(12, max(-12, newLevel))
                }
            }
    }
}
