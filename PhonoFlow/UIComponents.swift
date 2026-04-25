//
//  UIComponents.swift
//  PhonoFlow
//
//  Reusable UI components and styles
//

import SwiftUI

// MARK: - Glass Effect Container

struct GlassEffectContainer<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
    }
}

// MARK: - Glass Button Style

struct GlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(configuration.isPressed ? .secondary : .primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
            .opacity(configuration.isPressed ? 0.7 : 1.0)
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}

// MARK: - Visualization Info Button

/// Reusable info button for visualization headers. Shows a popover with interpretation tips.
func vizInfoButton(title: String, showInfo: Binding<Bool>, tips: [String]) -> some View {
    HStack(spacing: 4) {
        Text(title)
            .font(.system(size: 9, weight: .semibold, design: .rounded))
            .foregroundStyle(.primary.opacity(0.5))

        Button(action: { showInfo.wrappedValue.toggle() }) {
            Image(systemName: "info.circle")
                .font(.system(size: 9))
                .foregroundStyle(.primary.opacity(0.35))
        }
        .buttonStyle(.plain)
        .popover(isPresented: showInfo, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Text("How to Read")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)

                ForEach(tips, id: \.self) { tip in
                    HStack(alignment: .top, spacing: 6) {
                        Circle()
                            .fill(.primary.opacity(0.4))
                            .frame(width: 4, height: 4)
                            .padding(.top, 4)
                        Text(tip)
                            .font(.system(size: 10))
                            .foregroundStyle(.primary.opacity(0.8))
                    }
                }
            }
            .padding(10)
            .frame(width: 260)
        }
    }
}

// MARK: - Equalizer View

struct EqualizerView: View {
    @Binding var eqBands: [Float]
    var theme: ColorTheme = .midnight
    @State private var selectedPreset = "Flat"
    @State private var customPresets: [String: [Float]] = [:]
    @State private var showSaveDialog = false
    @State private var newPresetName = ""

    let bandLabels = ["31Hz", "62Hz", "125Hz", "250Hz", "500Hz", "1kHz", "2kHz", "4kHz", "8kHz", "16kHz"]
    let bandNames = ["Sub", "Bass", "B+", "Low M", "Mid", "Mid", "U.Mid", "Pres", "Treb", "Air"]
    
    let defaultPresets: [String: [Float]] = [
        "Flat": [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
        "Bass Boost": [6, 4, 1, -2, -3, -2, 0, 1, 2, 3],
        "Treble Boost": [-1, -2, -2, -1, 0, 2, 4, 6, 8, 9],
        "Vocal": [-4, -2, 1, 3, 4, 3, 2, 1, -1, -3],
        "Warm": [4, 3, 1, 0, -1, 0, 1, 2, 3, 4]
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
                    .buttonStyle(GlassButtonStyle())
                    .help("Save current settings as preset")
                    
                    if customPresets[selectedPreset] != nil {
                        Button(action: deletePreset) {
                            Image(systemName: "trash")
                                .font(.system(size: 10))
                        }
                        .buttonStyle(GlassButtonStyle())
                        .help("Delete this custom preset")
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
                    .buttonStyle(GlassButtonStyle())
                    
                    Button("Cancel") {
                        newPresetName = ""
                        showSaveDialog = false
                    }
                    .buttonStyle(GlassButtonStyle())
                }
                .padding(.horizontal, 4)
            }

            // Band name labels on top
            HStack(spacing: 0) {
                ForEach(0..<10, id: \.self) { index in
                    VStack(spacing: 0) {
                        Text(bandNames[index])
                            .font(.system(size: 7, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .padding(.horizontal, 4)

            // Graph view
            AnalogEqualizerGraphContent(eqBands: $eqBands, theme: theme)
                .frame(height: 140)

            // Frequency labels
            HStack(spacing: 0) {
                ForEach(0..<10, id: \.self) { index in
                    VStack(spacing: 1) {
                        Text(bandLabels[index])
                            .font(.system(size: 7, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(String(format: "%+.0f", eqBands[index]))
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundStyle(eqBands[index] == 0 ? .secondary : (eqBands[index] > 0 ? theme.accent : Color.orange))
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .padding(.horizontal, 4)
        }
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

    var body: some View {
        Canvas { context, size in
            let width = size.width
            let height = size.height
            let centerY = height / 2
            let bandCount = eqBands.count
            let pixelsPerDB: CGFloat = 5.0  // ±12 dB = 60 pixels on each side with headroom

            // Draw grid background
            var gridPath = Path()
            
            // Horizontal grid lines
            for i in stride(from: 0, through: height, by: height / 4) {
                gridPath.move(to: CGPoint(x: 0, y: i))
                gridPath.addLine(to: CGPoint(x: width, y: i))
            }
            
            // Vertical grid lines - one for each band
            for i in stride(from: 0, through: bandCount, by: 1) {
                let x = (width / CGFloat(bandCount)) * CGFloat(i)
                gridPath.move(to: CGPoint(x: x, y: 0))
                gridPath.addLine(to: CGPoint(x: x, y: height))
            }
            
            context.stroke(
                gridPath,
                with: .color(Color.secondary.opacity(0.1)),
                lineWidth: 0.5
            )

            // Draw center line (0dB)
            var centerLine = Path()
            centerLine.move(to: CGPoint(x: 0, y: centerY))
            centerLine.addLine(to: CGPoint(x: width, y: centerY))
            context.stroke(
                centerLine,
                with: .color(Color.secondary.opacity(0.3)),
                lineWidth: 1.0
            )

            // Calculate curve points for all bands - center in each column
            var curvePoints: [CGPoint] = []
            for i in 0..<bandCount {
                let x = (width / CGFloat(bandCount)) * CGFloat(i) + (width / CGFloat(bandCount * 2))
                let y = centerY - CGFloat(eqBands[i]) * pixelsPerDB
                curvePoints.append(CGPoint(x: x, y: y))
            }

            // Draw curve from left edge (0dB) through all band points to right edge (0dB)
            var curve = Path()
            let leftEdgePoint = CGPoint(x: 0, y: centerY)  // Fixed at 0dB on left
            let rightEdgePoint = CGPoint(x: width, y: centerY)  // Fixed at 0dB on right
            
            // Build complete point list with edge points
            var allPoints = [leftEdgePoint]
            allPoints.append(contentsOf: curvePoints)
            allPoints.append(rightEdgePoint)
            
            // Start at left edge
            curve.move(to: leftEdgePoint)
            
            // Draw smooth curve through all points using local cubic Bezier interpolation
            for i in 1..<allPoints.count {
                let current = allPoints[i]
                let previous = allPoints[i - 1]
                
                // Use only adjacent points for control points (more local, less far-reaching effect)
                let prevPoint = i > 1 ? allPoints[i - 2] : previous
                let nextPoint = i < allPoints.count - 1 ? allPoints[i + 1] : current
                
                // Calculate control points based only on current segment
                let dx = current.x - previous.x
                let dy = current.y - previous.y
                
                // Calculate tangent directions based on local points
                let prevTangent = i > 1 ? CGPoint(x: current.x - prevPoint.x, y: current.y - prevPoint.y) : CGPoint(x: dx, y: dy)
                let nextTangent = i < allPoints.count - 1 ? CGPoint(x: nextPoint.x - previous.x, y: nextPoint.y - previous.y) : CGPoint(x: dx, y: dy)
                
                // Use a small smoothing factor to keep control points close to the segment
                let smoothing: CGFloat = 0.15
                let cp1x = previous.x + (prevTangent.x * smoothing)
                let cp1y = previous.y + (prevTangent.y * smoothing)
                let cp2x = current.x - (nextTangent.x * smoothing)
                let cp2y = current.y - (nextTangent.y * smoothing)
                
                curve.addCurve(
                    to: current,
                    control1: CGPoint(x: cp1x, y: cp1y),
                    control2: CGPoint(x: cp2x, y: cp2y)
                )
            }

            // Draw curve line (no fill)
            context.stroke(
                curve,
                with: .color(theme.accent),
                lineWidth: 2.0
            )

            // Draw control points
            let pointSize: CGFloat = 6
            for point in curvePoints {
                context.fill(
                    Path(ellipseIn: CGRect(x: point.x - pointSize / 2, y: point.y - pointSize / 2, width: pointSize, height: pointSize)),
                    with: .color(theme.accent)
                )
            }

            // Draw fade gradient on left side
            let leftGradientWidth: CGFloat = 20
            let leftGradient = Gradient(colors: [Color.secondary.opacity(0.05), Color.clear])
            context.fill(
                Path(CGRect(x: 0, y: 0, width: leftGradientWidth, height: height)),
                with: .linearGradient(leftGradient, startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: leftGradientWidth, y: 0))
            )

            // Draw fade gradient on right side
            let rightGradientWidth: CGFloat = 20
            let rightGradient = Gradient(colors: [Color.clear, Color.secondary.opacity(0.05)])
            context.fill(
                Path(CGRect(x: width - rightGradientWidth, y: 0, width: rightGradientWidth, height: height)),
                with: .linearGradient(rightGradient, startPoint: CGPoint(x: width - rightGradientWidth, y: 0), endPoint: CGPoint(x: width, y: 0))
            )

        }
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(6)
        .gesture(
            DragGesture()
                .onChanged { gesture in
                    let width = 540.0 - 24.0
                    let height = 140.0
                    let centerY = height / 2
                    let bandCount = eqBands.count
                    let pixelsPerDB: CGFloat = 5.0  // ±12 dB = 60 pixels with headroom

                    let touchX = gesture.location.x
                    let touchY = gesture.location.y

                    // Find closest band
                    var closestIndex = 0
                    var minDist = CGFloat.infinity

                    for i in 0..<bandCount {
                        let bandX = (width / CGFloat(bandCount)) * CGFloat(i) + (width / CGFloat(bandCount * 2))
                        let bandY = centerY - CGFloat(eqBands[i]) * pixelsPerDB
                        let dist = sqrt(pow(touchX - bandX, 2) + pow(touchY - bandY, 2))
                        if dist < minDist {
                            minDist = dist
                            closestIndex = i
                        }
                    }

                    let dragThreshold = 25.0
                    if minDist < dragThreshold {
                        let newLevel = Float((centerY - touchY) / pixelsPerDB)
                        // Limit to ±12 dB range
                        eqBands[closestIndex] = min(12, max(-12, newLevel))
                    }
                }
        )
    }
}

// MARK: - Vinyl Restore (real-time click/pop removal)

struct VinylRestoreView: View {
    @Binding var isEnabled: Bool
    @Binding var strength: DeclickStrength
    var theme: ColorTheme = .midnight

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "circle.hexagongrid.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(isEnabled ? theme.accent : .secondary)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Vinyl Restore")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Remove dust pops and clicks in real time")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Toggle("", isOn: $isEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .tint(theme.accent)
            }

            HStack(spacing: 4) {
                ForEach(DeclickStrength.allCases) { option in
                    Button {
                        strength = option
                    } label: {
                        Text(option.label)
                            .font(.system(size: 10, weight: strength == option ? .semibold : .regular))
                            .foregroundStyle(strength == option ? Color.white : .primary.opacity(0.7))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(strength == option ? theme.accent : Color.primary.opacity(0.06))
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(!isEnabled)
                    .opacity(isEnabled ? 1.0 : 0.45)
                }
            }
        }
    }
}
