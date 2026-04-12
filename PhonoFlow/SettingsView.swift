//
//  SettingsView.swift
//  PhonoFlow
//

import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @State private var newHost = ""
    @State private var portText = ""

    var body: some View {
        @Bindable var settings = settings

        TabView {
            generalTab(settings: $settings)
                .tabItem { Label("General", systemImage: "gear") }

            radioTab(settings: $settings)
                .tabItem { Label("Radio", systemImage: "antenna.radiowaves.left.and.right") }

            appearanceTab(settings: $settings)
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
        }
        .frame(width: 480, height: 460)
    }

    // MARK: - General

    private func generalTab(settings: Bindable<AppSettings>) -> some View {
        Form {
            Section("Interface Mode") {
                Toggle("Pro Mode", isOn: settings.isProMode)

                Text(self.settings.isProMode
                     ? "Shows waveform meter and radio streaming features."
                     : "Shows only monitoring and gain control for simpler interface.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Startup") {
                Toggle("Launch at Login", isOn: settings.launchAtLogin)

                Text("Automatically start PhonoFlow when you log in to your Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if self.settings.isProMode {
                Section("Visualizations") {
                    Toggle("Advanced Visualizations", isOn: settings.showAdvancedVisualizations)

                    Text("Shows real-time waveform, spectrogram, and phase scope.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Label("Uses additional CPU for real-time FFT analysis and rendering. Disable if you experience high CPU usage or reduced battery life.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
        .padding(12)
    }

    // MARK: - Radio

    private func radioTab(settings: Bindable<AppSettings>) -> some View {
        Form {
            Section("Stream Port") {
                HStack {
                    TextField("Port", text: $portText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .onAppear { portText = String(self.settings.radioPort) }
                        .onChange(of: portText) {
                            if let val = UInt16(portText), val > 0 {
                                self.settings.radioPort = val
                            }
                        }
                    Text("Default: 7865")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Allowed Hosts") {
                Text("Leave empty to allow all connections.\nAdd IP addresses or CIDR ranges to restrict access.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(self.settings.allowedHosts, id: \.self) { host in
                    HStack {
                        Text(host)
                            .font(.system(.body, design: .monospaced))
                        Spacer()
                        Button(role: .destructive) {
                            self.settings.allowedHosts.removeAll { $0 == host }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                    }
                }

                HStack {
                    TextField("e.g. 192.168.1.0/24", text: $newHost)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { addHost() }
                    Button("Add") { addHost() }
                        .disabled(newHost.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .padding(12)
    }

    // MARK: - Appearance

    private func appearanceTab(settings: Bindable<AppSettings>) -> some View {
        Form {
            Section("Color Theme") {
                Picker("Theme", selection: settings.theme) {
                    ForEach(ColorTheme.allCases) { theme in
                        HStack(spacing: 8) {
                            Circle().fill(theme.accent).frame(width: 10, height: 10)
                            Text(theme.rawValue)
                        }
                        .tag(theme)
                    }
                }
                .pickerStyle(.radioGroup)
            }

            Section("Preview") {
                themePreview
            }
        }
        .formStyle(.grouped)
        .padding(12)
    }

    private var themePreview: some View {
        HStack(spacing: 6) {
            ForEach(0..<12, id: \.self) { i in
                let fraction = Float(i) / 11.0
                RoundedRectangle(cornerRadius: 2)
                    .fill(fraction > MeterThresholds.peak
                          ? AppColors.meterPeakRed
                          : fraction > MeterThresholds.warning
                            ? AppColors.meterWarningYellow
                            : settings.theme.meterGreen)
                    .frame(height: 10)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Helpers

    private func addHost() {
        let trimmed = newHost.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !settings.allowedHosts.contains(trimmed) else { return }
        settings.allowedHosts.append(trimmed)
        newHost = ""
    }
}
