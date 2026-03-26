//
//  AudioDeviceManager.swift
//  PhonoFlow
//
//  Created by Wasin Silakong on 26/3/2569 BE.
//

import AVFoundation
import CoreAudio

struct AudioDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let isInput: Bool
    let isOutput: Bool
}

private enum Defaults {
    static let inputUID = "selectedInputDeviceUID"
    static let outputUID = "selectedOutputDeviceUID"
    static let inputName = "selectedInputDeviceName"
    static let outputName = "selectedOutputDeviceName"
}

@Observable
class AudioDeviceManager {
    var inputDevices: [AudioDevice] = []
    var outputDevices: [AudioDevice] = []
    var selectedInputDeviceID: AudioDeviceID? {
        didSet { persistSelection() }
    }
    var selectedOutputDeviceID: AudioDeviceID? {
        didSet { persistSelection() }
    }
    var microphonePermissionGranted = false
    var permissionDenied = false

    // Saved UID/name for devices that may be disconnected
    private(set) var savedInputUID: String?
    private(set) var savedInputName: String?
    private(set) var savedOutputUID: String?
    private(set) var savedOutputName: String?

    var isInputAvailable: Bool {
        guard let id = selectedInputDeviceID else {
            return savedInputUID == nil
        }
        return inputDevices.contains { $0.id == id }
    }

    var isOutputAvailable: Bool {
        guard let id = selectedOutputDeviceID else {
            return savedOutputUID == nil
        }
        return outputDevices.contains { $0.id == id }
    }

    init() {
        savedInputUID = UserDefaults.standard.string(forKey: Defaults.inputUID)
        savedInputName = UserDefaults.standard.string(forKey: Defaults.inputName)
        savedOutputUID = UserDefaults.standard.string(forKey: Defaults.outputUID)
        savedOutputName = UserDefaults.standard.string(forKey: Defaults.outputName)

        updatePermissionStatus()
        if microphonePermissionGranted {
            refreshDevices()
        }
    }

    func updatePermissionStatus() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            microphonePermissionGranted = true
            permissionDenied = false
        case .denied, .restricted:
            microphonePermissionGranted = false
            permissionDenied = true
        case .notDetermined:
            microphonePermissionGranted = false
            permissionDenied = false
        @unknown default:
            microphonePermissionGranted = false
        }
    }

    func requestMicrophonePermission() {
        Task {
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            microphonePermissionGranted = granted
            permissionDenied = !granted
            if granted {
                refreshDevices()
            }
        }
    }

    func refreshDevices() {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress, 0, nil, &dataSize
        ) == noErr else { return }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress, 0, nil, &dataSize, &deviceIDs
        ) == noErr else { return }

        var inputs: [AudioDevice] = []
        var outputs: [AudioDevice] = []

        for deviceID in deviceIDs {
            let name = deviceName(for: deviceID)
            let uid = Self.deviceUID(for: deviceID) ?? ""
            let hasInput = hasStreams(deviceID: deviceID, scope: kAudioDevicePropertyScopeInput)
            let hasOutput = hasStreams(deviceID: deviceID, scope: kAudioDevicePropertyScopeOutput)

            let device = AudioDevice(id: deviceID, uid: uid, name: name,
                                     isInput: hasInput, isOutput: hasOutput)
            if hasInput { inputs.append(device) }
            if hasOutput { outputs.append(device) }
        }

        inputDevices = inputs
        outputDevices = outputs

        // Restore saved input device by UID
        if let savedUID = savedInputUID {
            if let match = inputs.first(where: { $0.uid == savedUID }) {
                selectedInputDeviceID = match.id
            } else {
                // Device not connected — keep selectedInputDeviceID nil
                // but preserve savedInputUID so it reconnects later
                selectedInputDeviceID = nil
            }
        } else {
            selectedInputDeviceID = defaultDevice(for: kAudioHardwarePropertyDefaultInputDevice)
                ?? inputs.first?.id
        }

        // Restore saved output device by UID
        if let savedUID = savedOutputUID {
            if let match = outputs.first(where: { $0.uid == savedUID }) {
                selectedOutputDeviceID = match.id
            } else {
                selectedOutputDeviceID = nil
            }
        } else {
            selectedOutputDeviceID = defaultDevice(for: kAudioHardwarePropertyDefaultOutputDevice)
                ?? outputs.first?.id
        }
    }

    /// Name to display for the currently selected (possibly disconnected) input
    var selectedInputDisplayName: String? {
        if let id = selectedInputDeviceID,
           let dev = inputDevices.first(where: { $0.id == id }) {
            return dev.name
        }
        return savedInputName
    }

    /// Name to display for the currently selected (possibly disconnected) output
    var selectedOutputDisplayName: String? {
        if let id = selectedOutputDeviceID,
           let dev = outputDevices.first(where: { $0.id == id }) {
            return dev.name
        }
        return savedOutputName
    }

    // MARK: - Persistence

    private func persistSelection() {
        if let id = selectedInputDeviceID,
           let dev = inputDevices.first(where: { $0.id == id }) {
            savedInputUID = dev.uid
            savedInputName = dev.name
            UserDefaults.standard.set(dev.uid, forKey: Defaults.inputUID)
            UserDefaults.standard.set(dev.name, forKey: Defaults.inputName)
        }
        if let id = selectedOutputDeviceID,
           let dev = outputDevices.first(where: { $0.id == id }) {
            savedOutputUID = dev.uid
            savedOutputName = dev.name
            UserDefaults.standard.set(dev.uid, forKey: Defaults.outputUID)
            UserDefaults.standard.set(dev.name, forKey: Defaults.outputName)
        }
    }

    // MARK: - CoreAudio helpers

    private func defaultDevice(for selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = 0
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress, 0, nil, &dataSize, &deviceID
        )
        return status == noErr ? deviceID : nil
    }

    private func deviceName(for deviceID: AudioDeviceID) -> String {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var prop: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(
            deviceID, &propertyAddress, 0, nil, &dataSize, &prop
        ) == noErr, let cf = prop?.takeUnretainedValue() else { return "Unknown Device" }
        return cf as String
    }

    static func deviceUID(for deviceID: AudioDeviceID) -> String? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var prop: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(
            deviceID, &propertyAddress, 0, nil, &dataSize, &prop
        ) == noErr, let cf = prop?.takeUnretainedValue() else { return nil }
        return cf as String
    }

    private func hasStreams(deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) -> Bool {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(deviceID, &propertyAddress, 0, nil, &dataSize)
        return status == noErr && dataSize > 0
    }
}
