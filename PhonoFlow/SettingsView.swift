//
//  SettingsView.swift
//  PhonoFlow
//

import AppKit
import Network
import SwiftUI

private enum SettingsSection: Hashable {
    case general
    case audio
    case remoteAccess
    case appearance
    case diagnostics
}

private enum PortField: Hashable {
    case remoteAccess
    case legacyStream
}

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @State private var selection: SettingsSection = .general
    @State private var newHost = ""
    @State private var radioPortText = ""
    @State private var remotePortText = ""
    @State private var copiedDiagnostics = false
    @State private var copiedPairingCode = false
    @State private var pairingActionInFlight = false
    @State private var showRevokeConfirmation = false
    @State private var hostValidationMessage: String?
    @FocusState private var focusedPortField: PortField?

    var body: some View {
        @Bindable var settings = settings

        TabView(selection: $selection) {
            generalTab(settings: $settings)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsSection.general)

            audioTab(settings: $settings)
                .tabItem { Label("Audio", systemImage: "waveform") }
                .tag(SettingsSection.audio)

            remoteAccessTab(settings: $settings)
                .tabItem { Label("Remote Access", systemImage: "network") }
                .tag(SettingsSection.remoteAccess)

            appearanceTab(settings: $settings)
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
                .tag(SettingsSection.appearance)

            diagnosticsTab(settings: $settings)
                .tabItem { Label("Diagnostics", systemImage: "gauge.with.dots.needle.50percent") }
                .tag(SettingsSection.diagnostics)
        }
        .frame(minWidth: 520, idealWidth: 620, minHeight: 440, idealHeight: 520)
        .tint(settings.theme.accent)
        .onAppear {
            radioPortText = String(settings.radioPort)
            remotePortText = String(settings.remoteAccessPort)
        }
        .confirmationDialog(
            "Revoke access for every paired browser?",
            isPresented: $showRevokeConfirmation
        ) {
            Button("Revoke All Browsers", role: .destructive) {
                revokeAllBrowsers()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Browsers must pair again with a new six-digit code.")
        }
    }

    // MARK: - General

    private func generalTab(settings: Bindable<AppSettings>) -> some View {
        settingsForm {
            Section("Interface") {
                Toggle("Pro Mode", isOn: settings.isProMode)
                    .accessibilityHint("Shows processing, recording, streaming, and live visualization controls.")
                    .accessibilityIdentifier("settings.general.proMode")

                SettingsNote(
                    icon: "rectangle.3.group",
                    text: self.settings.isProMode
                        ? "The menu includes the complete audio workflow."
                        : "Basic mode keeps device, level, gain, and monitoring controls visible."
                )
            }

            Section("Startup") {
                Toggle("Launch at Login", isOn: settings.launchAtLogin)
                    .accessibilityIdentifier("settings.general.launchAtLogin")
                Text("Starts PhonoFlow in the menu bar after you sign in.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Accessibility") {
                LabeledContent("Reduce Motion") {
                    Text(reduceMotion ? "On" : "Off")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Reduce Transparency") {
                    Text(reduceTransparency ? "On" : "Off")
                        .foregroundStyle(.secondary)
                }
                Text("PhonoFlow follows these macOS Accessibility settings automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Audio

    private func audioTab(settings: Bindable<AppSettings>) -> some View {
        settingsForm {
            Section("Analysis") {
                Toggle("Advanced Visualizations", isOn: settings.showAdvancedVisualizations)
                    .disabled(!self.settings.isProMode)
                    .accessibilityIdentifier("settings.audio.advancedVisualizations")

                SettingsNote(
                    icon: self.settings.showAdvancedVisualizations
                        ? "waveform.path.ecg"
                        : "pause.circle",
                    text: self.settings.showAdvancedVisualizations
                        ? "Waveform, phase, and spectrogram analysis runs only while its view is visible."
                        : "Keep analysis off to minimize CPU and battery use."
                )

                if !self.settings.isProMode {
                    Text("Turn on Pro Mode in General to show advanced visualizations.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Capture Format") {
                LabeledContent("Client format", value: "Stereo Float32")
                LabeledContent("Input route", value: "Selected in the menu")
                Text(
                    "PhonoFlow uses the device’s native sample rate and exposes valid input pairs when the device reports multiple channels."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Processing") {
                LabeledContent("Equalizer", value: "10 bands")
                LabeledContent("Limiter", value: "Automatic")
                Text("Gain, equalizer, and limiter changes are applied to monitoring, recording, and streams.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Remote Access

    private func remoteAccessTab(settings: Bindable<AppSettings>) -> some View {
        settingsForm {
            Section {
                Toggle("Enable Paired Remote Access", isOn: settings.remoteAccessEnabled)
                    .accessibilityHint("Makes PhonoFlow controls available to paired browsers on your local network.")
                    .accessibilityIdentifier("settings.remote.enabled")

                LabeledContent("Control port") {
                    portField(
                        label: "Remote access port",
                        field: .remoteAccess,
                        text: $remotePortText,
                        value: self.settings.remoteAccessPort,
                        fallback: AppSettings.defaultRemoteAccessPort,
                        isEnabled: !self.settings.remoteAccessEnabled
                    ) { newValue in
                        self.settings.remoteAccessPort = newValue
                    }
                    .accessibilityHint(
                        self.settings.remoteAccessEnabled
                            ? "Disable Remote Access to change the control port."
                            : "Enter a port from 1 through 65535."
                    )
                }

                SettingsNote(
                    icon: remoteAccessIsRunning
                        ? "network.badge.shield.half.filled"
                        : "network.slash",
                    text: remoteAccessStatusMessage,
                    tint: remoteStatusTint
                )
                .accessibilityIdentifier("settings.remote.status")

                if let url = coordinator.remoteAccessURL {
                    HStack(spacing: 8) {
                        Text(url.absoluteString)
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)

                        Spacer()

                        Button {
                            NSWorkspace.shared.open(url)
                        } label: {
                            Image(systemName: "safari")
                        }
                        .buttonStyle(.glass)
                        .help("Open WebUI")
                        .accessibilityLabel("Open remote WebUI")

                        Button {
                            copyToPasteboard(url.absoluteString)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.glass)
                        .help("Copy WebUI address")
                        .accessibilityLabel("Copy remote WebUI address")
                        .accessibilityIdentifier("settings.remote.copyURL")
                    }
                }

                if let error = coordinator.remoteAccessError {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(
                            remoteAccessFailureSummary(error),
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)

                        DisclosureGroup("Technical details") {
                            Text(error)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 4)
                        }
                        .font(.caption)

                        Button("Retry Remote Access") {
                            coordinator.retryRemoteAccess()
                        }
                        .buttonStyle(.glass)
                        .disabled(!self.settings.remoteAccessEnabled)
                        .accessibilityIdentifier("settings.remote.retry")
                    }
                }
            } header: {
                Text("Paired WebUI")
            } footer: {
                Label(
                    "Trusted local networks only. Do not expose this port through router forwarding.",
                    systemImage: "exclamationmark.shield.fill"
                )
                .foregroundStyle(.orange)
            }

            Section("Pairing") {
                if let pairingCode = coordinator.pairingCode {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("PAIRING CODE")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)

                        HStack {
                            Text(pairingCode.code)
                                .font(.system(.title, design: .monospaced).weight(.bold))
                                .tracking(5)
                                .textSelection(.enabled)
                                .accessibilityLabel(
                                    pairingCode.code.map(String.init).joined(separator: " ")
                                )
                                .accessibilityIdentifier("settings.remote.pairingCode")

                            Spacer()

                            Button {
                                copyPairingCode(pairingCode.code)
                            } label: {
                                Label(
                                    copiedPairingCode ? "Copied" : "Copy",
                                    systemImage: copiedPairingCode ? "checkmark" : "doc.on.doc"
                                )
                            }
                            .buttonStyle(.glass)
                        }

                        Text("Expires \(pairingCode.expiresAt, style: .relative)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text(
                        remoteAccessIsRunning
                            ? "Generate a six-digit code to pair a browser for 30 days."
                            : "Enable Remote Access and wait for the service to start before pairing."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                HStack {
                    Button {
                        generatePairingCode()
                    } label: {
                        Group {
                            if pairingActionInFlight {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Label(
                                    coordinator.pairingCode == nil ? "Generate Code" : "New Code",
                                    systemImage: "number.square"
                                )
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(!remoteAccessIsRunning || pairingActionInFlight)
                    .accessibilityIdentifier("settings.remote.generatePairingCode")

                    Button(role: .destructive) {
                        showRevokeConfirmation = true
                    } label: {
                        Label("Revoke All Browsers", systemImage: "person.crop.circle.badge.xmark")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                    .disabled(!remoteAccessIsRunning || pairingActionInFlight)
                    .accessibilityIdentifier("settings.remote.revokeBrowsers")
                }

                LabeledContent(
                    "Connected listeners",
                    value:
                        "\(coordinator.listenerCounts.total) (\(coordinator.listenerCounts.eventStreams) control, \(coordinator.listenerCounts.audioStreams) audio)"
                )
                .accessibilityIdentifier("settings.remote.listenerCounts")
                LabeledContent("Code lifetime", value: "10 minutes")
                LabeledContent("Browser session", value: "30 days")
            }

            Section {
                Toggle(
                    "Allow unauthenticated legacy /stream",
                    isOn: settings.allowLegacyUnauthenticatedStream
                )
                .accessibilityIdentifier("settings.remote.legacyUnauthenticated")

                LabeledContent("Legacy stream port") {
                    portField(
                        label: "Legacy stream port",
                        field: .legacyStream,
                        text: $radioPortText,
                        value: self.settings.radioPort,
                        fallback: AppSettings.defaultRadioPort,
                        isEnabled: true
                    ) { newValue in
                        self.settings.radioPort = newValue
                    }
                }

                if self.settings.allowLegacyUnauthenticatedStream {
                    SettingsNote(
                        icon: "exclamationmark.triangle.fill",
                        text:
                            "Anyone whose source IP matches the legacy client list can listen without pairing.",
                        tint: .orange
                    )
                }
            } header: {
                Text("Legacy VLC / mpv Compatibility")
            }

            Section("Allowed Legacy Client Addresses") {
                Text(
                    "Leave empty to accept clients from any local address, or add exact source IP addresses and CIDR ranges."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                ForEach(self.settings.allowedHosts, id: \.self) { host in
                    HStack {
                        Text(host)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                        Spacer()
                        Button(role: .destructive) {
                            self.settings.allowedHosts.removeAll { $0 == host }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(host)")
                    }
                }

                HStack {
                    TextField("192.168.1.0/24", text: $newHost)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addHost)
                        .onChange(of: newHost) { _, _ in
                            hostValidationMessage = nil
                        }
                        .accessibilityLabel("New allowed legacy client address")
                    Button("Add", action: addHost)
                        .buttonStyle(.glass)
                        .disabled(newHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if let hostValidationMessage {
                    Label(hostValidationMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    // MARK: - Appearance

    private func appearanceTab(settings: Bindable<AppSettings>) -> some View {
        settingsForm {
            Section("Accent Theme") {
                Picker("Theme", selection: settings.theme) {
                    ForEach(ColorTheme.allCases) { theme in
                        Label {
                            Text(theme.rawValue)
                        } icon: {
                            Circle()
                                .fill(theme.accent)
                                .frame(width: 10, height: 10)
                        }
                        .tag(theme)
                    }
                }
                .pickerStyle(.radioGroup)
            }

            Section("Liquid Glass") {
                LabeledContent("Material", value: reduceTransparency ? "Solid fallback" : "Liquid Glass")
                Text(
                    reduceTransparency
                        ? "Reduce Transparency is enabled, so PhonoFlow uses opaque control surfaces."
                        : "Controls use native macOS 26 Liquid Glass. Live plots remain on solid surfaces for clarity and performance."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Meter Preview") {
                themePreview
                    .accessibilityElement()
                    .accessibilityLabel("\(self.settings.theme.rawValue) level meter preview")
            }
        }
    }

    // MARK: - Diagnostics

    private func diagnosticsTab(settings: Bindable<AppSettings>) -> some View {
        settingsForm {
            Section("Menu Diagnostics") {
                Toggle("Show Diagnostic Details", isOn: settings.showDiagnostics)
                    .accessibilityIdentifier("settings.diagnostics.visible")
                Text("Shows the negotiated capture format and visualization state in the menu.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Performance Policy") {
                LabeledContent("Waveform and phase", value: "30 Hz")
                LabeledContent("Spectrum", value: "15 Hz")
                LabeledContent("Hidden analysis", value: "Suspended")
                LabeledContent("Pending UI frames", value: "1 maximum")
            }

            Section("Support") {
                Button {
                    copyDiagnostics()
                } label: {
                    Label(
                        copiedDiagnostics ? "Copied" : "Copy Settings Summary",
                        systemImage: copiedDiagnostics ? "checkmark" : "doc.on.doc"
                    )
                }
                .buttonStyle(.glass)
                .accessibilityHint("Copies non-sensitive PhonoFlow settings to the clipboard.")

                Text("The summary excludes pairing codes, host entries, and recording paths.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Helpers

    private var remoteAccessIsRunning: Bool {
        if case .running = coordinator.remoteAccessState {
            return true
        }
        return false
    }

    private var remoteAccessStatusMessage: String {
        switch coordinator.remoteAccessState {
        case .disabled:
            return settings.remoteAccessEnabled
                ? "Remote access is waiting to start."
                : "Remote access is off. No browser control service is advertised."
        case .starting:
            return "Starting paired remote access…"
        case .running:
            return "Paired access is available independently of radio streaming."
        case .failed:
            return "Remote access could not start. Review the error and retry."
        case .stopping:
            return "Stopping paired remote access…"
        }
    }

    private var remoteStatusTint: Color {
        switch coordinator.remoteAccessState {
        case .running:
            return .green
        case .failed:
            return .orange
        default:
            return .secondary
        }
    }

    private func generatePairingCode() {
        guard !pairingActionInFlight else { return }
        pairingActionInFlight = true
        Task { @MainActor in
            defer { pairingActionInFlight = false }
            _ = try? await coordinator.issuePairingCode()
        }
    }

    private func revokeAllBrowsers() {
        guard !pairingActionInFlight else { return }
        pairingActionInFlight = true
        Task { @MainActor in
            defer { pairingActionInFlight = false }
            try? await coordinator.revokeAllBrowsers()
        }
    }

    private func copyPairingCode(_ code: String) {
        copyToPasteboard(code)
        copiedPairingCode = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            copiedPairingCode = false
        }
    }

    private func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func settingsForm<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        Form(content: content)
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
    }

    private func remoteAccessFailureSummary(_ error: String) -> String {
        let normalized = error.lowercased()
        if normalized.contains("permission") || normalized.contains("not permitted") {
            return "PhonoFlow cannot write its Remote Access data. Check storage permissions, then retry."
        }
        if normalized.contains("address already in use") || normalized.contains("eaddrinuse") {
            return "The control port is already in use. Disable Remote Access, choose another port, and retry."
        }
        if normalized.contains("network") || normalized.contains("socket") {
            return "The local network listener could not start. Check network access and retry."
        }
        return "Remote Access could not start. Retry the service or expand the technical details."
    }

    private func portField(
        label: String,
        field: PortField,
        text: Binding<String>,
        value: UInt16,
        fallback: UInt16,
        isEnabled: Bool,
        commit: @escaping (UInt16) -> Void
    ) -> some View {
        TextField(label, text: text, prompt: Text(String(fallback)))
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .font(.system(.body, design: .monospaced))
            .multilineTextAlignment(.trailing)
            .frame(width: 86)
            .focused($focusedPortField, equals: field)
            .onSubmit {
                commitPort(
                    text: text,
                    currentValue: value,
                    commit: commit
                )
            }
            .onChange(of: focusedPortField) { oldValue, newValue in
                if oldValue == field, newValue != field {
                    commitPort(
                        text: text,
                        currentValue: value,
                        commit: commit
                    )
                }
            }
            .disabled(!isEnabled)
            .accessibilityLabel(label)
    }

    private func commitPort(
        text: Binding<String>,
        currentValue: UInt16,
        commit: (UInt16) -> Void
    ) {
        if let port = validPort(text.wrappedValue) {
            commit(port)
            text.wrappedValue = String(port)
        } else {
            text.wrappedValue = String(currentValue)
        }
    }

    private func validPort(_ text: String) -> UInt16? {
        guard let raw = Int(text), (1...65_535).contains(raw) else { return nil }
        return UInt16(raw)
    }

    private var themePreview: some View {
        HStack(spacing: 5) {
            ForEach(0..<16, id: \.self) { index in
                let fraction = Float(index) / 15
                RoundedRectangle(cornerRadius: 2)
                    .fill(
                        fraction > MeterThresholds.peak
                            ? AppColors.meterPeakRed
                            : fraction > MeterThresholds.warning
                                ? AppColors.meterWarningYellow
                                : settings.theme.meterGreen
                    )
                    .frame(height: 12)
            }
        }
        .padding(.vertical, 6)
    }

    private func addHost() {
        let trimmed = newHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !settings.allowedHosts.contains(trimmed) else { return }
        guard isValidHostEntry(trimmed) else {
            hostValidationMessage = "Enter a valid IPv4/IPv6 address or CIDR range."
            return
        }
        settings.allowedHosts.append(trimmed)
        newHost = ""
        hostValidationMessage = nil
    }

    private func isValidHostEntry(_ entry: String) -> Bool {
        let components = entry.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count <= 2 else { return false }

        let address = String(components[0])
        let isIPv4 = IPv4Address(address) != nil
        let isIPv6 = IPv6Address(address) != nil
        guard isIPv4 || isIPv6 else { return false }

        guard components.count == 2 else { return true }
        guard let prefix = Int(components[1]) else { return false }
        return isIPv4 ? (0...32).contains(prefix) : (0...128).contains(prefix)
    }

    private func copyDiagnostics() {
        let summary = """
            PhonoFlow settings
            Mode: \(settings.isProMode ? "Pro" : "Basic")
            Theme: \(settings.theme.rawValue)
            Advanced visualizations: \(settings.showAdvancedVisualizations ? "On" : "Off")
            Remote access: \(settings.remoteAccessEnabled ? "On" : "Off")
            Remote service: \(coordinator.remoteAccessStatusText)
            Remote port: \(settings.remoteAccessPort)
            Remote listeners: \(coordinator.listenerCounts.total)
            Legacy unauthenticated option: \(settings.allowLegacyUnauthenticatedStream ? "On" : "Off")
            """

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(summary, forType: .string)
        copiedDiagnostics = true

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            copiedDiagnostics = false
        }
    }
}

private struct SettingsNote: View {
    let icon: String
    let text: String
    var tint: Color = .secondary

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .frame(width: 18, alignment: .center)
                .padding(.top, 1)

            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption)
        .foregroundStyle(tint)
        .accessibilityElement(children: .combine)
    }
}
