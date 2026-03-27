//
//  ContentView.swift
//  PhonoFlow
//
//  Created by Wasin Silakong on 26/3/2569 BE.
//

import AppKit
import Combine
import CoreAudio
import SwiftUI

struct ContentView: View {
    @Environment(AudioDeviceManager.self) private var audioManager
    @Environment(AudioMonitor.self) private var audioMonitor
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var audioManager = audioManager
        @Bindable var audioMonitor = audioMonitor

        GlassEffectContainer {
            VStack(spacing: 0) {
                header
                content(audioManager: $audioManager, audioMonitor: $audioMonitor)
            }
        }
        .frame(width: 540)
        .onAppear {
            audioManager.updatePermissionStatus()

            // Auto-request microphone permission if not granted
            if !audioManager.microphonePermissionGranted && !audioManager.permissionDenied {
                audioManager.requestMicrophonePermission()
            }

            // Enable metering based on mode
            audioMonitor.isMeteringEnabled = settings.isProMode

            if audioManager.microphonePermissionGranted {
                audioManager.refreshDevices()
                if !audioMonitor.isMonitoring,
                   let deviceID = audioManager.selectedInputDeviceID,
                   audioManager.isInputAvailable {
                    audioMonitor.startMonitoring(deviceID: deviceID,
                                                 outputDeviceID: audioManager.selectedOutputDeviceID)
                }
            }

            // Ask about launch at login on first launch
            if !settings.hasAskedLaunchAtLogin {
                settings.hasAskedLaunchAtLogin = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    showLaunchAtLoginPrompt()
                }
            }
        }
        .onChange(of: audioManager.selectedInputDeviceID) { _, newValue in
            audioManager.refreshDevices()
            if let deviceID = newValue, audioManager.isInputAvailable {
                audioMonitor.startMonitoring(deviceID: deviceID,
                                             outputDeviceID: audioManager.selectedOutputDeviceID)
            } else {
                audioMonitor.stopMonitoring()
            }
        }
        .onChange(of: audioManager.selectedOutputDeviceID) { _, newValue in
            audioManager.refreshDevices()
            if let deviceID = newValue {
                audioMonitor.updatePassthroughOutput(deviceID: deviceID)
            }
        }
        .onChange(of: audioMonitor.gain) {
            audioMonitor.updatePassthroughVolume()
        }
        .onChange(of: settings.isProMode) { _, newValue in
            audioMonitor.isMeteringEnabled = newValue
            if newValue {
                // Start UI updates when switching to pro mode
                audioMonitor.startUIUpdateTimer()
            } else {
                // Disable all Pro features when switching to basic mode
                if audioMonitor.isStreamingEnabled {
                    audioMonitor.stopStreaming()
                }
            }
        }
    }

    private var theme: ColorTheme { settings.theme }

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

    private var modeBadgeGradient: LinearGradient {
        if settings.isProMode {
            // PRO badge uses theme accent color
            let baseColor = theme.accent
            let lighterColor = baseColor.opacity(0.8)
            return LinearGradient(
                colors: [baseColor, lighterColor],
                startPoint: .leading, endPoint: .trailing
            )
        } else {
            // BASIC badge is grey
            return LinearGradient(
                colors: [
                    Color(red: 0.5, green: 0.5, blue: 0.5),
                    Color(red: 0.6, green: 0.6, blue: 0.6)
                ],
                startPoint: .leading, endPoint: .trailing
            )
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Text("PhonoFlow")
                .font(.system(size: 13, weight: .semibold))

            Text(settings.isProMode ? "PRO" : "BASIC")
                .font(.system(size: 9, weight: .heavy))
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(modeBadgeGradient, in: Capsule())

            Spacer()

            if settings.isProMode {
                statusIndicator
            }

            Button {
                SettingsWindowController.shared.open(settings: settings)
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(AppColors.closeRed.opacity(0.7))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var statusIndicator: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
                .shadow(color: statusColor.opacity(0.6), radius: 3)
            Text(statusLabel)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    private var statusColor: Color {
        if audioMonitor.isStreamingEnabled && audioMonitor.isPassthroughEnabled {
            return AppColors.onAirRed
        } else if audioMonitor.isPassthroughEnabled {
            return theme.activeColor
        } else if audioMonitor.isStreamingEnabled {
            return AppColors.streamingYellow
        } else {
            return AppColors.standbyGray
        }
    }

    private var statusLabel: String {
        if audioMonitor.isStreamingEnabled && audioMonitor.isPassthroughEnabled {
            return "On Air"
        } else if audioMonitor.isPassthroughEnabled {
            return "Monitoring"
        } else if audioMonitor.isStreamingEnabled {
            return "Streaming"
        } else {
            return "Standby"
        }
    }

    // MARK: - Main content

    private func content(audioManager: Bindable<AudioDeviceManager>,
                         audioMonitor: Bindable<AudioMonitor>) -> some View {
        VStack(spacing: 8) {
            sectionCard {
                HStack(spacing: 10) {
                    deviceRow(icon: "mic.fill",
                              selection: audioManager.selectedInputDeviceID,
                              devices: self.audioManager.inputDevices,
                              disconnectedName: self.audioManager.isInputAvailable ? nil : self.audioManager.savedInputName)
                    Divider().frame(height: 20).opacity(0.3)
                    deviceRow(icon: "speaker.wave.2.fill",
                              selection: audioManager.selectedOutputDeviceID,
                              devices: self.audioManager.outputDevices,
                              disconnectedName: self.audioManager.isOutputAvailable ? nil : self.audioManager.savedOutputName)
                }
            }

            if settings.isProMode {
                sectionCard {
                    WaveformView(peakLevel: self.audioMonitor.peakLevel,
                                 gain: audioMonitor.gain,
                                 theme: theme)
                }

                sectionCard {
                    EqualizerView(eqBands: audioMonitor.eqBands, theme: theme)
                }
            }

            sectionCard {
                VStack(spacing: 10) {
                    controlButtons
                    if self.audioMonitor.isStreamingEnabled {
                        streamURLBar
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 14)
    }

    // MARK: - Control buttons

    private var controlButtons: some View {
        HStack(spacing: 8) {
            controlButton(
                icon: "headphones",
                label: audioMonitor.isPassthroughEnabled ? "Monitoring" : "Monitor",
                isActive: audioMonitor.isPassthroughEnabled,
                activeColor: theme.activeColor
            ) {
                if audioMonitor.isPassthroughEnabled {
                    audioMonitor.disablePassthrough()
                } else {
                    audioMonitor.enablePassthrough()
                }
            }

            if settings.isProMode {
                controlButton(
                    icon: "antenna.radiowaves.left.and.right",
                    label: audioMonitor.isStreamingEnabled ? "On Air" : "Radio",
                    isActive: audioMonitor.isStreamingEnabled,
                    activeColor: AppColors.onAirRed
                ) {
                    if audioMonitor.isStreamingEnabled {
                        audioMonitor.stopStreaming()
                    } else {
                        audioMonitor.startStreaming(port: settings.radioPort,
                                                    allowedHosts: settings.allowedHosts)
                    }
                }
            }
        }
    }

    // MARK: - Reusable components

    private func sectionCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private func deviceRow(icon: String,
                           selection: Binding<AudioDeviceID?>,
                           devices: [AudioDevice],
                           disconnectedName: String?) -> some View {
        DeviceRowView(icon: icon, selection: selection, devices: devices, 
                      disconnectedName: disconnectedName, audioManager: audioManager)
    }

    @ViewBuilder
    private func controlButton(icon: String, label: String,
                                isActive: Bool, activeColor: Color,
                                action: @escaping () -> Void) -> some View {
        if isActive {
            Button(action: action) {
                Label(label, systemImage: icon)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(activeColor)
        } else {
            Button(action: action) {
                Label(label, systemImage: icon)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(GlassButtonStyle())
        }
    }

    // MARK: - Stream URL

    private var streamURLBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "link")
                .font(.system(size: 9))
                .foregroundStyle(AppColors.onAirRed.opacity(0.8))

            Text(audioMonitor.streamURL)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            Spacer()

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(audioMonitor.streamURL, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
    }

}

// MARK: - Device Row View

struct DeviceRowView: View {
    let icon: String
    @Binding var selection: AudioDeviceID?
    let devices: [AudioDevice]
    let disconnectedName: String?
    let audioManager: AudioDeviceManager

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(disconnectedName != nil
                                 ? AppColors.closeRed.opacity(0.8)
                                 : .primary.opacity(0.35))

            HStack {
                Picker("Device", selection: $selection) {
                    if let name = disconnectedName {
                        Text(name)
                            .foregroundStyle(AppColors.closeRed)
                            .tag(nil as AudioDeviceID?)
                    } else {
                        Text("None").tag(nil as AudioDeviceID?)
                    }
                    ForEach(devices) { device in
                        Text(device.name).tag(device.id as AudioDeviceID?)
                    }
                }
                .labelsHidden()
                
                Button(action: {
                    audioManager.refreshDevices()
                }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Refresh device list")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
