//
//  ContentView.swift
//  PhonoFlow
//

import AppKit
import SwiftUI

struct ContentView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(AudioDeviceManager.self) private var audioManager
    @Environment(AudioMonitor.self) private var audioMonitor
    @Environment(AppSettings.self) private var settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @Namespace private var glassNamespace

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            VStack(spacing: 0) {
                header

                ScrollView {
                    VStack(spacing: 10) {
                        if let alert = audioAlert {
                            audioAlertView(alert)
                                .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                        }

                        deviceSection
                            .glassEffectID("devices", in: glassNamespace)

                        MeterGainSectionView(
                            audioMonitor: audioMonitor,
                            theme: theme
                        )

                        if settings.isProMode {
                            processingSection
                                .glassEffectID("processing", in: glassNamespace)
                                .glassEffectTransition(.matchedGeometry)
                        }

                        if settings.isProMode, settings.showAdvancedVisualizations {
                            VisualizationDashboardView(
                                audioMonitor: audioMonitor,
                                theme: theme
                            )
                            .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                        }

                        actionsSection
                            .glassEffectID("actions", in: glassNamespace)

                        if settings.showDiagnostics {
                            diagnosticsSection
                                .glassEffectID("diagnostics", in: glassNamespace)
                                .glassEffectTransition(.materialize)
                                .transition(.opacity)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.top, 2)
                    .padding(.bottom, 14)
                }
                .scrollIndicators(.automatic)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 560, height: 680)
        .background {
            popoverBackground
        }
        .tint(theme.accent)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: audioAlert)
        .onAppear(perform: handleAppear)
        .onDisappear {
            coordinator.setNativeInterfaceVisible(false)
        }
        .onChange(of: settings.isProMode) { _, _ in
            updateVisualizationActivity()
        }
        .onChange(of: settings.showAdvancedVisualizations) { _, _ in
            updateVisualizationActivity()
        }
    }

    private var theme: ColorTheme { settings.theme }

    private var popoverBackground: some View {
        Group {
            if reduceTransparency {
                Color(nsColor: .windowBackgroundColor)
            } else {
                LinearGradient(
                    colors: [
                        theme.accent.opacity(0.10),
                        Color(nsColor: .windowBackgroundColor),
                        Color(nsColor: .windowBackgroundColor),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
        .ignoresSafeArea()
    }

    // MARK: - Lifecycle

    private func handleAppear() {
        coordinator.prepareNativeInterface()
        coordinator.setNativeInterfaceVisible(true)
        updateVisualizationActivity()

        if !settings.hasAskedLaunchAtLogin {
            settings.hasAskedLaunchAtLogin = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                showLaunchAtLoginPrompt()
            }
        }
    }

    private func refreshAndRetryAudio() {
        coordinator.refreshNativeAudioDevices()
    }

    private var hasUsableOutput: Bool {
        audioManager.isOutputAvailable
            && audioManager.selectedOutputDeviceID != nil
    }

    private func updateVisualizationActivity() {
        coordinator.setNativeAdvancedVisualizationsVisible(
            settings.isProMode && settings.showAdvancedVisualizations
        )
    }

    private func showLaunchAtLoginPrompt() {
        let alert = NSAlert()
        alert.messageText = "Launch PhonoFlow at Login?"
        alert.informativeText = "Would you like PhonoFlow to start automatically when you log in to your Mac?"
        alert.addButton(withTitle: "Yes")
        alert.addButton(withTitle: "No")
        alert.alertStyle = .informational

        if alert.runModal() == .alertFirstButtonReturn {
            settings.launchAtLogin = true
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "waveform.badge.magnifyingglass")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(theme.accent)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 0) {
                    Text("PhonoFlow")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                    Text("Native audio workspace")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }

            Text(settings.isProMode ? "PRO" : "BASIC")
                .font(.system(size: 9, weight: .heavy, design: .rounded))
                .foregroundStyle(settings.isProMode ? .black.opacity(0.82) : .white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(modeBadgeGradient, in: Capsule())
                .accessibilityLabel("\(settings.isProMode ? "Pro" : "Basic") interface mode")

            Spacer(minLength: 4)

            statusIndicator

            Button {
                SettingsWindowController.shared.open(settings: settings)
            } label: {
                Image(systemName: "gearshape")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.glass)
            .keyboardShortcut(",", modifiers: .command)
            .help("Settings (⌘,)")
            .accessibilityLabel("Open Settings")

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.glass)
            .tint(AppColors.closeRed)
            .keyboardShortcut("q", modifiers: .command)
            .help("Quit PhonoFlow (⌘Q)")
            .accessibilityLabel("Quit PhonoFlow")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var statusIndicator: some View {
        let content = HStack(spacing: 5) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
                .shadow(color: statusColor.opacity(0.55), radius: 3)
            Text(statusLabel)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .frame(width: 108)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Audio status")
        .accessibilityValue(statusLabel)

        if reduceTransparency {
            content
                .background(
                    Color(nsColor: .controlBackgroundColor),
                    in: Capsule()
                )
                .overlay {
                    Capsule().stroke(statusColor.opacity(0.35), lineWidth: 1)
                }
        } else {
            content
                .glassEffect(
                    .regular.tint(statusColor.opacity(0.18)),
                    in: .capsule
                )
                .glassEffectID("audio-status", in: glassNamespace)
                .glassEffectTransition(.matchedGeometry)
        }
    }

    private var modeBadgeGradient: LinearGradient {
        let colors =
            settings.isProMode
            ? [theme.accent, theme.accent.opacity(0.72)]
            : [
                Color(red: 0.26, green: 0.27, blue: 0.31),
                Color(red: 0.36, green: 0.37, blue: 0.42),
            ]
        return LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
    }

    private var statusColor: Color {
        if audioMonitor.isRecording {
            return AppColors.meterPeakRed
        } else if audioMonitor.isStreamingEnabled && audioMonitor.isPassthroughEnabled {
            return AppColors.onAirRed
        } else if audioMonitor.isPassthroughEnabled {
            return theme.activeColor
        } else if audioMonitor.isStreamingEnabled {
            return AppColors.streamingYellow
        } else if case .starting = audioMonitor.engineStatus {
            return AppColors.streamingYellow
        } else if audioMonitor.isMonitoring {
            return theme.accent
        } else if case .failed = audioMonitor.engineStatus {
            return .orange
        } else if case .disconnected = audioMonitor.engineStatus {
            return AppColors.closeRed
        } else {
            return AppColors.standbyGray
        }
    }

    private var statusLabel: String {
        if audioMonitor.isRecording {
            return "Recording"
        } else if audioMonitor.isStreamingEnabled && audioMonitor.isPassthroughEnabled {
            return "On Air"
        } else if audioMonitor.isPassthroughEnabled {
            return "Monitoring"
        } else if audioMonitor.isStreamingEnabled {
            return "Streaming"
        } else if case .starting = audioMonitor.engineStatus {
            return "Starting"
        } else if audioMonitor.isMonitoring {
            return "Captured"
        } else if case .failed = audioMonitor.engineStatus {
            return "Needs Attention"
        } else if case .disconnected = audioMonitor.engineStatus {
            return "Disconnected"
        } else {
            return "Standby"
        }
    }

    // MARK: - Audio devices

    private var deviceSection: some View {
        LiquidGlassSection(tint: theme.accent.opacity(0.07)) {
            VStack(spacing: 10) {
                PhonoSectionHeader(
                    "Audio Devices",
                    subtitle: self.audioMonitor.isMonitoring ? negotiatedFormat : "Engine idle",
                    systemImage: "waveform.circle"
                ) {
                    Button {
                        self.refreshAndRetryAudio()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.glass)
                    .keyboardShortcut("r", modifiers: .command)
                    .help("Refresh audio devices (⌘R)")
                    .accessibilityLabel("Refresh audio devices")
                }

                Divider().opacity(0.35)

                DeviceRowView(
                    title: "Input",
                    icon: "mic.fill",
                    selectionUID: Binding(
                        get: {
                            self.audioManager.selectedInputDevice?.uid
                                ?? self.audioManager.savedInputUID
                        },
                        set: { uid in
                            self.coordinator.selectNativeInputDevice(uid: uid)
                        }
                    ),
                    devices: self.audioManager.inputDevices,
                    disconnectedUID: self.audioManager.isInputAvailable
                        ? nil
                        : self.audioManager.savedInputUID,
                    disconnectedName: self.audioManager.isInputAvailable
                        ? nil
                        : self.audioManager.savedInputName,
                    isEnabled: !self.audioMonitor.isRecording
                )

                if !self.audioManager.availableInputRoutes.isEmpty {
                    InputRouteRowView(
                        selection: Binding(
                            get: {
                                self.audioManager.selectedInputRouteID
                            },
                            set: { routeID in
                                self.coordinator.selectNativeInputRoute(
                                    id: routeID
                                )
                            }
                        ),
                        routes: self.audioManager.availableInputRoutes,
                        isEnabled: !self.audioMonitor.isRecording
                    )
                }

                DeviceRowView(
                    title: "Output",
                    icon: "speaker.wave.2.fill",
                    selectionUID: Binding(
                        get: {
                            self.audioManager.selectedOutputDevice?.uid
                                ?? self.audioManager.savedOutputUID
                        },
                        set: { uid in
                            self.coordinator.selectNativeOutputDevice(uid: uid)
                        }
                    ),
                    devices: self.audioManager.outputDevices,
                    disconnectedUID: self.audioManager.isOutputAvailable
                        ? nil
                        : self.audioManager.savedOutputUID,
                    disconnectedName: self.audioManager.isOutputAvailable
                        ? nil
                        : self.audioManager.savedOutputName,
                    isEnabled: true
                )

                if self.audioMonitor.isRecording {
                    Label(
                        "Input device and route are locked while recording.",
                        systemImage: "lock.fill"
                    )
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var negotiatedFormat: String {
        if case .running(let format) = audioMonitor.engineStatus {
            return format.summary
        }
        let rate = audioMonitor.captureSampleRate
        return String(format: "%.1f kHz • stereo Float32", rate / 1_000)
    }

    // MARK: - Processing

    private var processingSection: some View {
        LiquidGlassSection(tint: theme.accent.opacity(0.06)) {
            VStack(spacing: 10) {
                PhonoSectionHeader(
                    "Processing",
                    subtitle: "10-band EQ and soft limiter",
                    systemImage: "slider.horizontal.3"
                )
                EqualizerView(
                    eqBands: Binding(
                        get: { self.audioMonitor.eqBands },
                        set: { bands in
                            self.coordinator.setNativeEqualizerBands(bands)
                        }
                    ),
                    theme: theme
                )
            }
        }
    }

    // MARK: - Actions

    private var actionsSection: some View {
        LiquidGlassSection(tint: statusColor.opacity(0.07)) {
            VStack(spacing: 10) {
                PhonoSectionHeader(
                    "Actions",
                    subtitle: actionSubtitle,
                    systemImage: "play.square.stack"
                )

                HStack(spacing: 8) {
                    controlButton(
                        icon: "headphones",
                        label: audioMonitor.isPassthroughEnabled ? "Monitoring" : "Monitor",
                        isActive: audioMonitor.isPassthroughEnabled,
                        activeColor: theme.activeColor,
                        shortcut: "m",
                        shortcutModifiers: [.command, .shift],
                        accessibilityIdentifier: "action.monitor",
                        isEnabled: audioMonitor.isMonitoring && hasUsableOutput
                    ) {
                        coordinator.setNativeMonitorEnabled(
                            !audioMonitor.isPassthroughEnabled
                        )
                    }

                    if settings.isProMode || audioMonitor.isStreamingEnabled {
                        controlButton(
                            icon: "antenna.radiowaves.left.and.right",
                            label: audioMonitor.isStreamingEnabled ? "On Air" : "Radio",
                            isActive: audioMonitor.isStreamingEnabled,
                            activeColor: AppColors.onAirRed,
                            shortcut: "b",
                            shortcutModifiers: [.command, .shift],
                            accessibilityIdentifier: "action.radio",
                            isEnabled: audioMonitor.isMonitoring
                        ) {
                            coordinator.setNativeRadioEnabled(
                                !audioMonitor.isStreamingEnabled
                            )
                        }
                    }

                    if settings.isProMode || audioMonitor.isRecording {
                        controlButton(
                            icon: "record.circle",
                            label: audioMonitor.isRecording ? "Stop" : "Record",
                            isActive: audioMonitor.isRecording,
                            activeColor: AppColors.meterPeakRed,
                            shortcut: "r",
                            shortcutModifiers: [.command, .shift],
                            accessibilityIdentifier: "action.record",
                            isEnabled: audioMonitor.isMonitoring
                        ) {
                            coordinator.setNativeRecordingEnabled(
                                !audioMonitor.isRecording
                            )
                        }
                    }
                }

                if audioMonitor.isStreamingEnabled {
                    streamURLBar
                        .transition(.opacity)
                }

                if audioMonitor.recordingURL != nil {
                    RecordingFileRowView(audioMonitor: audioMonitor)
                        .transition(.opacity)
                }

                if let failure = audioMonitor.lastRecordingFailure {
                    Label(
                        failure.localizedDescription,
                        systemImage: "record.circle.fill"
                    )
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("recording.finalization-error")
                    .transition(.opacity)
                }
            }
        }
    }

    private var actionSubtitle: String {
        if !audioMonitor.isMonitoring {
            return "Choose a working input to begin"
        } else if !hasUsableOutput {
            return "Capture works; monitoring needs an output"
        } else {
            return "Capture, listen, broadcast, or record"
        }
    }

    @ViewBuilder
    private func controlButton(
        icon: String,
        label: String,
        isActive: Bool,
        activeColor: Color,
        shortcut: KeyEquivalent,
        shortcutModifiers: EventModifiers,
        accessibilityIdentifier: String,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        if isActive {
            Button(action: action) {
                Label(label, systemImage: icon)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .tint(activeColor)
            .keyboardShortcut(shortcut, modifiers: shortcutModifiers)
            .accessibilityIdentifier(accessibilityIdentifier)
            .accessibilityValue("On")
        } else {
            Button(action: action) {
                Label(label, systemImage: icon)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .keyboardShortcut(shortcut, modifiers: shortcutModifiers)
            .accessibilityIdentifier(accessibilityIdentifier)
            .disabled(!isEnabled)
            .accessibilityValue("Off")
        }
    }

    private var streamURLBar: some View {
        HStack(spacing: 7) {
            Image(systemName: "link")
                .foregroundStyle(AppColors.onAirRed)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text("Legacy Float32 stream")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(audioMonitor.streamURL)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            Spacer()

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(audioMonitor.streamURL, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.glass)
            .help("Copy stream URL")
            .accessibilityLabel("Copy legacy stream URL")
        }
        .padding(8)
        .background(
            Color.primary.opacity(0.055),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
    }

    // MARK: - Diagnostics

    private var diagnosticsSection: some View {
        LiquidGlassSection {
            VStack(spacing: 9) {
                PhonoSectionHeader(
                    "Diagnostics",
                    subtitle: "Current UI-facing engine state",
                    systemImage: "gauge.with.dots.needle.50percent"
                )

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                    diagnosticRow("Capture", value: audioMonitor.isMonitoring ? "Running" : "Idle")
                    diagnosticRow("Format", value: negotiatedFormat)
                    diagnosticRow(
                        "Input route",
                        value: audioManager.selectedInputRoute?.name ?? "Default"
                    )
                    diagnosticRow(
                        "Channel map",
                        value: audioMonitor.inputChannelMap.map(String.init).joined(separator: ", ")
                    )
                    diagnosticRow(
                        "Callback overflows",
                        value: String(audioMonitor.callbackOverflowCount)
                    )
                    diagnosticRow(
                        "Playback underruns",
                        value: String(audioMonitor.playbackUnderrunCount)
                    )
                    diagnosticRow(
                        "Analysis",
                        value: settings.isProMode && settings.showAdvancedVisualizations
                            ? "Visible"
                            : "Suspended"
                    )
                    diagnosticRow(
                        "Remote WebUI",
                        value: coordinator.remoteAccessStatusText
                    )
                    diagnosticRow(
                        "Remote listeners",
                        value: String(coordinator.listenerCounts.total)
                    )
                }
                .font(.system(size: 10, design: .monospaced))
            }
        }
    }

    private func diagnosticRow(_ label: String, value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .gridColumnAlignment(.trailing)
                .textSelection(.enabled)
        }
    }

    // MARK: - Alerts

    fileprivate enum AudioAlert: Equatable {
        case permissionRequired
        case permissionDenied
        case inputDisconnected(String)
        case engineStopped
        case engineFailed(String)
        case discoveryFailed(String)
        case commandFailed(String)
    }

    private var audioAlert: AudioAlert? {
        if audioManager.permissionDenied {
            return .permissionDenied
        }
        if !audioManager.microphonePermissionGranted {
            return .permissionRequired
        }
        if let error = coordinator.nativeCommandError {
            return .commandFailed(error)
        }
        if !audioManager.isInputAvailable {
            return .inputDisconnected(audioManager.savedInputName ?? "Saved input")
        }
        if let error = audioMonitor.lastError {
            return .engineFailed(error.localizedDescription)
        }
        if let error = audioManager.lastDiscoveryError {
            return .discoveryFailed(error)
        }
        if audioManager.selectedInputDeviceID != nil,
            case .idle = audioMonitor.engineStatus
        {
            return .engineStopped
        }
        return nil
    }

    private func audioAlertView(_ alert: AudioAlert) -> some View {
        HStack(alignment: .center, spacing: 9) {
            Image(systemName: alert.icon)
                .foregroundStyle(alert.color)
                .font(.system(size: 14, weight: .semibold))

            VStack(alignment: .leading, spacing: 1) {
                Text(alert.title)
                    .font(.system(size: 11, weight: .semibold))
                Text(alert.message)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            switch alert {
            case .permissionRequired:
                Button("Allow") {
                    coordinator.requestNativeMicrophoneAccess()
                }
                .buttonStyle(.glassProminent)
            case .permissionDenied:
                Button("Open Settings") {
                    openMicrophonePrivacySettings()
                }
                .buttonStyle(.glass)
            case .inputDisconnected, .engineStopped, .engineFailed,
                .discoveryFailed, .commandFailed:
                Button("Refresh") {
                    refreshAndRetryAudio()
                }
                .buttonStyle(.glass)
            }
        }
        .padding(10)
        .background(
            alert.color.opacity(reduceTransparency ? 0.16 : 0.09),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(alert.color.opacity(0.4), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }

    private func openMicrophonePrivacySettings() {
        guard
            let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
            )
        else { return }
        NSWorkspace.shared.open(url)
    }

}

extension ContentView.AudioAlert {
    fileprivate var icon: String {
        switch self {
        case .permissionRequired:
            return "mic.badge.plus"
        case .permissionDenied:
            return "mic.slash.fill"
        case .inputDisconnected:
            return "cable.connector.slash"
        case .engineStopped:
            return "exclamationmark.triangle.fill"
        case .engineFailed:
            return "waveform.badge.exclamationmark"
        case .discoveryFailed:
            return "arrow.clockwise.circle.fill"
        case .commandFailed:
            return "exclamationmark.bubble.fill"
        }
    }

    fileprivate var color: Color {
        switch self {
        case .permissionRequired:
            return .blue
        case .permissionDenied, .inputDisconnected:
            return AppColors.closeRed
        case .engineStopped, .engineFailed, .discoveryFailed, .commandFailed:
            return .orange
        }
    }

    fileprivate var title: String {
        switch self {
        case .permissionRequired:
            return "Microphone Access Required"
        case .permissionDenied:
            return "Microphone Access Is Off"
        case .inputDisconnected(let name):
            return "\(name) Is Disconnected"
        case .engineStopped:
            return "Audio Engine Is Not Running"
        case .engineFailed:
            return "Core Audio Could Not Start"
        case .discoveryFailed:
            return "Device Discovery Failed"
        case .commandFailed:
            return "Audio Command Was Not Applied"
        }
    }

    fileprivate var message: String {
        switch self {
        case .permissionRequired:
            return "Allow access to discover and capture audio inputs."
        case .permissionDenied:
            return "Enable PhonoFlow in Privacy & Security → Microphone."
        case .inputDisconnected:
            return "Reconnect it or choose another input device."
        case .engineStopped:
            return "Refresh devices or choose another input."
        case .engineFailed(let detail), .discoveryFailed(let detail),
            .commandFailed(let detail):
            return detail
        }
    }
}

// MARK: - Device Row

struct DeviceRowView: View {
    let title: String
    let icon: String
    @Binding var selectionUID: String?
    let devices: [AudioDevice]
    let disconnectedUID: String?
    let disconnectedName: String?
    let isEnabled: Bool

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(disconnectedName == nil ? .secondary : AppColors.closeRed)
                .frame(width: 18)
                .accessibilityHidden(true)

            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .leading)

            Picker(title, selection: $selectionUID) {
                Text("None").tag(nil as String?)

                if let disconnectedUID, let disconnectedName {
                    Text("\(disconnectedName) — Disconnected")
                        .tag(disconnectedUID as String?)
                }

                ForEach(devices) { device in
                    Text(device.name).tag(device.uid as String?)
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .trailing)
            .disabled(!isEnabled)
            .accessibilityLabel("\(title) device")
            .accessibilityValue(selectedDeviceName)
            .accessibilityIdentifier(
                title == "Input" ? "audio.input.device" : "audio.output.device"
            )

            Circle()
                .fill(connectionColor)
                .frame(width: 6, height: 6)
                .frame(width: 44)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }

    private var selectedDeviceName: String {
        if let selectionUID,
            let selected = devices.first(where: { $0.uid == selectionUID })
        {
            return selected.name
        }
        if let disconnectedName {
            return "\(disconnectedName), disconnected"
        }
        return "None"
    }

    private var connectionColor: Color {
        if disconnectedName != nil {
            return AppColors.closeRed
        }
        return selectionUID == nil ? AppColors.standbyGray : .green
    }
}

struct InputRouteRowView: View {
    @Binding var selection: String?
    let routes: [AudioInputRoute]
    let isEnabled: Bool

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .accessibilityHidden(true)

            Text("Route")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .leading)

            Picker("Input route", selection: $selection) {
                ForEach(routes) { route in
                    Text(route.name).tag(route.id as String?)
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .trailing)
            .disabled(!isEnabled)
            .accessibilityLabel("Input channel pair")
            .accessibilityValue(selectedRoute?.name ?? "Default")
            .accessibilityIdentifier("audio.input.route")

            Text(channelMapLabel)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 44, alignment: .center)
        }
        .frame(maxWidth: .infinity)
    }

    private var selectedRoute: AudioInputRoute? {
        guard let selection else { return routes.first }
        return routes.first { $0.id == selection } ?? routes.first
    }

    private var channelMapLabel: String {
        guard let route = selectedRoute else { return "—" }
        return route.channelMap
            .map { String(Int($0) + 1) }
            .joined(separator: " → ")
    }
}

// MARK: - Isolated Live Views

/// Keeps 30 Hz meter changes from invalidating device controls and glass chrome.
private struct MeterGainSectionView: View {
    @Environment(AppCoordinator.self) private var coordinator
    let audioMonitor: AudioMonitor
    let theme: ColorTheme

    var body: some View {
        SolidVisualizationSurface(accent: theme.accent) {
            VStack(spacing: 10) {
                PhonoSectionHeader(
                    "Meter & Gain",
                    subtitle: audioMonitor.isMonitoring ? "Live input" : "Waiting for input",
                    systemImage: "waveform.path"
                )

                WaveformView(
                    leftLevel: audioMonitor.leftLevel,
                    rightLevel: audioMonitor.rightLevel,
                    gain: Binding(
                        get: { audioMonitor.gain },
                        set: { coordinator.setNativeGain($0) }
                    ),
                    isAutoGainEnabled: Binding(
                        get: { audioMonitor.isAutoGainEnabled },
                        set: {
                            coordinator.setNativeAutoGainEnabled($0)
                        }
                    ),
                    theme: theme
                )
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Stereo level meter and input gain")
                .accessibilityValue(meterAccessibilityValue)
            }
        }
    }

    private var meterAccessibilityValue: String {
        let left = decibelLabel(audioMonitor.leftLevel)
        let right = decibelLabel(audioMonitor.rightLevel)
        let gain =
            audioMonitor.gain < 0.001
            ? "muted"
            : String(format: "%+.1f decibels", 20 * log10(audioMonitor.gain))
        return "Left \(left), right \(right), gain \(gain)"
    }

    private func decibelLabel(_ level: Float) -> String {
        guard level > 0.000_01 else { return "silent" }
        return String(format: "%.1f decibels", max(20 * log10(level), -80))
    }
}

/// Owns high-frequency waveform/phase/image observation so the rest of the
/// menu only updates for discrete engine and control state changes.
private struct VisualizationDashboardView: View {
    let audioMonitor: AudioMonitor
    let theme: ColorTheme

    var body: some View {
        VStack(spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                WaveformPanelView(audioMonitor: audioMonitor, theme: theme)
                PhasePanelView(audioMonitor: audioMonitor, theme: theme)
                    .frame(width: 156)
            }

            SpectrogramPanelView(audioMonitor: audioMonitor, theme: theme)
        }
    }
}

private struct WaveformPanelView: View {
    let audioMonitor: AudioMonitor
    let theme: ColorTheme

    var body: some View {
        SolidVisualizationSurface(accent: theme.accent) {
            AdvancedWaveformView(
                leftWaveform: audioMonitor.leftWaveform,
                rightWaveform: audioMonitor.rightWaveform,
                theme: theme
            )
        }
    }
}

private struct PhasePanelView: View {
    let audioMonitor: AudioMonitor
    let theme: ColorTheme

    var body: some View {
        SolidVisualizationSurface(accent: theme.accent) {
            PhaseScopeView(
                points: audioMonitor.phasePoints,
                theme: theme
            )
        }
    }
}

private struct SpectrogramPanelView: View {
    let audioMonitor: AudioMonitor
    let theme: ColorTheme

    var body: some View {
        SolidVisualizationSurface(accent: theme.accent) {
            SpectrogramView(
                spectrogramImage: audioMonitor.spectrogramImage,
                sampleRate: audioMonitor.captureSampleRate,
                theme: theme
            )
        }
    }
}

private struct RecordingFileRowView: View {
    let audioMonitor: AudioMonitor

    var body: some View {
        if let url = audioMonitor.recordingURL {
            HStack(spacing: 7) {
                Image(systemName: "waveform.circle.fill")
                    .foregroundStyle(AppColors.meterPeakRed)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 1) {
                    Text(url.lastPathComponent)
                        .font(.caption2.monospaced().weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(audioMonitor.isRecording ? durationLabel : "Saved")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    NSWorkspace.shared.selectFile(
                        url.path,
                        inFileViewerRootedAtPath: url.deletingLastPathComponent().path
                    )
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.glass)
                .help("Show recording in Finder")
                .accessibilityLabel("Show recording in Finder")
            }
            .padding(8)
            .background(
                Color.primary.opacity(0.055),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
        }
    }

    private var durationLabel: String {
        let minutes = Int(audioMonitor.recordingDuration) / 60
        let seconds = Int(audioMonitor.recordingDuration) % 60
        return String(format: "Recording · %d:%02d", minutes, seconds)
    }
}
