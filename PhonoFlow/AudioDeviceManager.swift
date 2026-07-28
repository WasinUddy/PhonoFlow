//
//  AudioDeviceManager.swift
//  PhonoFlow
//
//  Core Audio device discovery and stable route selection.
//

import AVFoundation
import CoreAudio
import Foundation
import Observation

nonisolated struct AudioInputRoute:
    Identifiable,
    Hashable,
    Codable,
    Sendable
{
    let id: String
    let name: String
    /// Zero-based Core Audio source channels for the stereo client output.
    let channelMap: [Int32]
    let channelNames: [String]
}

nonisolated enum AudioDeviceTransport: String, Codable, Sendable {
    case builtIn
    case usb
    case bluetooth
    case hdmi
    case displayPort
    case aggregate
    case virtual
    case other
}

nonisolated struct AudioSampleRateRange: Hashable, Codable, Sendable {
    let minimum: Double
    let maximum: Double

    var displayName: String {
        if minimum == maximum {
            return Self.format(minimum)
        }
        return "\(Self.format(minimum))–\(Self.format(maximum))"
    }

    private static func format(_ value: Double) -> String {
        if value >= 1_000 {
            return String(format: "%.1f kHz", value / 1_000)
        }
        return String(format: "%.0f Hz", value)
    }
}

nonisolated struct AudioDevice: Identifiable, Hashable, Sendable {
    /// The Core Audio object ID is process-local and may change after reconnect.
    let id: AudioDeviceID
    /// Stable identity used for persistence and remote-control APIs.
    let uid: String
    let name: String
    let isInput: Bool
    let isOutput: Bool
    let inputChannelCount: Int
    let outputChannelCount: Int
    let inputRoutes: [AudioInputRoute]
    let nominalSampleRate: Double
    let availableSampleRates: [AudioSampleRateRange]
    let bufferFrameRange: ClosedRange<UInt32>?
    let transport: AudioDeviceTransport
    let isAlive: Bool

    var formatSummary: String {
        let direction: String
        switch (inputChannelCount, outputChannelCount) {
        case (let input, let output) where input > 0 && output > 0:
            direction = "\(input) in / \(output) out"
        case (let input, _) where input > 0:
            direction = "\(input) in"
        default:
            direction = "\(outputChannelCount) out"
        }
        let rate =
            nominalSampleRate >= 1_000
            ? String(format: "%.1f kHz", nominalSampleRate / 1_000)
            : String(format: "%.0f Hz", nominalSampleRate)
        return "\(direction) · \(rate)"
    }
}

private enum Defaults {
    static let inputUID = "selectedInputDeviceUID"
    static let outputUID = "selectedOutputDeviceUID"
    static let inputName = "selectedInputDeviceName"
    static let outputName = "selectedOutputDeviceName"
    static let inputSelectionMode = "selectedInputDeviceSelectionMode"
    static let outputSelectionMode = "selectedOutputDeviceSelectionMode"
    static let inputRoutePrefix = "selectedInputRoute."
}

nonisolated enum AudioDeviceSelectionPreference: Equatable, Sendable {
    case none
    case systemDefault
    case device(uid: String)
}

private struct InputDeviceBindingFingerprint: Equatable {
    let id: AudioDeviceID
    let isAlive: Bool
    let channelCount: Int
    let nominalSampleRate: Double
    let bufferFrameRange: ClosedRange<UInt32>?
}

private struct OutputDeviceBindingFingerprint: Equatable {
    let id: AudioDeviceID
    let isAlive: Bool
    let channelCount: Int
    let nominalSampleRate: Double
    let bufferFrameRange: ClosedRange<UInt32>?
}

nonisolated enum AudioDeviceRefreshError:
    LocalizedError,
    Equatable,
    Sendable
{
    case discoveryFailed(String)

    var errorDescription: String? {
        switch self {
        case .discoveryFailed(let detail):
            detail
        }
    }
}

@MainActor
@Observable
final class AudioDeviceManager {
    var inputDevices: [AudioDevice] = []
    var outputDevices: [AudioDevice] = []

    var selectedInputDeviceID: AudioDeviceID? {
        didSet {
            guard !isRefreshing else { return }
            persistInputSelection()
            restoreInputRoute()
        }
    }

    var selectedOutputDeviceID: AudioDeviceID? {
        didSet {
            guard !isRefreshing else { return }
            persistOutputSelection()
        }
    }

    var selectedInputRouteID: String? {
        didSet {
            guard !isRefreshing,
                let uid = selectedInputDevice?.uid,
                let routeID = selectedInputRouteID
            else { return }
            preferences.set(
                routeID,
                forKey: Defaults.inputRoutePrefix + uid
            )
        }
    }

    var microphonePermissionGranted = false
    var permissionDenied = false
    private(set) var lastDiscoveryError: String?

    // Saved UID/name for devices that may be disconnected.
    private(set) var savedInputUID: String?
    private(set) var savedInputName: String?
    private(set) var savedOutputUID: String?
    private(set) var savedOutputName: String?
    private(set) var inputSelectionPreference: AudioDeviceSelectionPreference =
        .systemDefault
    private(set) var outputSelectionPreference: AudioDeviceSelectionPreference =
        .systemDefault

    @ObservationIgnored private var isRefreshing = false
    @ObservationIgnored private let hal: any CoreAudioHAL
    @ObservationIgnored private let preferences: any AudioDevicePreferences
    @ObservationIgnored private var deviceListListener: (any CoreAudioHALListener)?
    @ObservationIgnored private var aliveListeners: [AudioDeviceID: any CoreAudioHALListener] = [:]
    @ObservationIgnored private var inputDeviceGenerations: [String: UInt64] = [:]
    @ObservationIgnored private var outputDeviceGenerations: [String: UInt64] = [:]
    @ObservationIgnored private var lastInputBindingsByUID: [String: InputDeviceBindingFingerprint] = [:]
    @ObservationIgnored private var lastOutputBindingsByUID: [String: OutputDeviceBindingFingerprint] = [:]

    var selectedInputDevice: AudioDevice? {
        guard let id = selectedInputDeviceID else { return nil }
        return inputDevices.first { $0.id == id }
    }

    var selectedOutputDevice: AudioDevice? {
        guard let id = selectedOutputDeviceID else { return nil }
        return outputDevices.first { $0.id == id }
    }

    var selectedInputRoute: AudioInputRoute? {
        guard let device = selectedInputDevice else { return nil }
        if let routeID = selectedInputRouteID,
            let route = device.inputRoutes.first(where: { $0.id == routeID })
        {
            return route
        }
        return device.inputRoutes.first
    }

    var availableInputRoutes: [AudioInputRoute] {
        selectedInputDevice?.inputRoutes ?? []
    }

    var isInputAvailable: Bool {
        guard let id = selectedInputDeviceID else {
            return savedInputUID == nil
        }
        return inputDevices.contains { $0.id == id && $0.isAlive }
    }

    var isOutputAvailable: Bool {
        guard let id = selectedOutputDeviceID else {
            return savedOutputUID == nil
        }
        return outputDevices.contains { $0.id == id && $0.isAlive }
    }

    convenience init() {
        self.init(
            hal: Self.makeDefaultHAL(),
            preferences: Self.makeDefaultPreferences()
        )
    }

    /// Injection point used by deterministic unit and acceptance harnesses.
    init(
        hal: any CoreAudioHAL,
        preferences: any AudioDevicePreferences =
            UserDefaultsAudioDevicePreferences()
    ) {
        self.hal = hal
        self.preferences = preferences
        savedInputUID = preferences.string(forKey: Defaults.inputUID)
        savedInputName = preferences.string(forKey: Defaults.inputName)
        savedOutputUID = preferences.string(forKey: Defaults.outputUID)
        savedOutputName = preferences.string(forKey: Defaults.outputName)
        inputSelectionPreference = Self.selectionPreference(
            persistedMode: preferences.string(
                forKey: Defaults.inputSelectionMode
            ),
            legacyUID: savedInputUID
        )
        outputSelectionPreference = Self.selectionPreference(
            persistedMode: preferences.string(
                forKey: Defaults.outputSelectionMode
            ),
            legacyUID: savedOutputUID
        )
        persistSelectionModes()

        installHardwareListener()
        updatePermissionStatus()
        if microphonePermissionGranted {
            try? refreshDevices()
        }
    }

    deinit {
        deviceListListener?.cancel()
        for listener in aliveListeners.values {
            listener.cancel()
        }
    }

    func updatePermissionStatus() {
        if hal.bypassesMicrophonePermission {
            microphonePermissionGranted = true
            permissionDenied = false
            return
        }

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
            permissionDenied = false
        }
    }

    func requestMicrophonePermission() {
        if hal.bypassesMicrophonePermission {
            microphonePermissionGranted = true
            permissionDenied = false
            try? refreshDevices()
            return
        }

        Task { @MainActor [weak self] in
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            guard let self else { return }
            microphonePermissionGranted = granted
            permissionDenied = !granted
            if granted {
                try? refreshDevices()
            }
        }
    }

    func refreshDevices() throws {
        do {
            let descriptions = try hal.devices()
            var discoveryWarning: String?
            let defaultInputID: AudioDeviceID?
            do {
                defaultInputID = try hal.defaultInputDeviceID()
            } catch {
                defaultInputID = nil
                discoveryWarning = error.localizedDescription
            }
            let defaultOutputID: AudioDeviceID?
            do {
                defaultOutputID = try hal.defaultOutputDeviceID()
            } catch {
                defaultOutputID = nil
                if discoveryWarning == nil {
                    discoveryWarning = error.localizedDescription
                }
            }
            let devices =
                descriptions
                .filter {
                    $0.inputChannelCount > 0 || $0.outputChannelCount > 0
                }
                .map(Self.makeDevice)
            updateDeviceGenerations(descriptions)

            let inputs =
                devices
                .filter(\.isInput)
                .sorted {
                    $0.name.localizedStandardCompare($1.name)
                        == .orderedAscending
                }
            let outputs =
                devices
                .filter(\.isOutput)
                .sorted {
                    $0.name.localizedStandardCompare($1.name)
                        == .orderedAscending
                }

            isRefreshing = true
            inputDevices = inputs
            outputDevices = outputs

            switch inputSelectionPreference {
            case .none:
                selectedInputDeviceID = nil
            case .systemDefault:
                selectedInputDeviceID =
                    defaultInputID.flatMap { defaultID in
                        inputs.first(where: { $0.id == defaultID })?.id
                    } ?? inputs.first?.id
            case .device(let savedUID):
                selectedInputDeviceID =
                    inputs.first {
                        $0.uid == savedUID
                    }?.id
            }

            switch outputSelectionPreference {
            case .none:
                selectedOutputDeviceID = nil
            case .systemDefault:
                selectedOutputDeviceID =
                    defaultOutputID.flatMap {
                        defaultID in
                        outputs.first(where: { $0.id == defaultID })?.id
                    } ?? outputs.first?.id
            case .device(let savedUID):
                selectedOutputDeviceID =
                    outputs.first {
                        $0.uid == savedUID
                    }?.id
            }

            restoreInputRoute()
            isRefreshing = false
            lastDiscoveryError = discoveryWarning
            reinstallAliveListeners(
                deviceIDs: descriptions.map(\.id)
            )
        } catch {
            isRefreshing = false
            let failure = AudioDeviceRefreshError.discoveryFailed(
                error.localizedDescription
            )
            lastDiscoveryError = failure.localizedDescription
            throw failure
        }
    }

    /// Name to display for the currently selected (possibly disconnected) input.
    var selectedInputDisplayName: String? {
        selectedInputDevice?.name ?? savedInputName
    }

    /// Name to display for the currently selected (possibly disconnected) output.
    var selectedOutputDisplayName: String? {
        selectedOutputDevice?.name ?? savedOutputName
    }

    /// Reads a persisted per-device route through the injected preference
    /// boundary. This also lets coordinator snapshots avoid reaching into
    /// `UserDefaults` directly.
    func savedInputRouteID(forDeviceUID uid: String) -> String? {
        preferences.string(forKey: Defaults.inputRoutePrefix + uid)
    }

    /// Changes when a device with this stable UID disappears, reconnects,
    /// changes its process-local Core Audio ID, or reports different hardware
    /// capabilities. Coordinators use this to rebind an AudioUnit even when
    /// the public UID and route remain unchanged.
    func inputGeneration(forDeviceUID uid: String) -> UInt64 {
        inputDeviceGenerations[uid, default: 0]
    }

    func outputGeneration(forDeviceUID uid: String) -> UInt64 {
        outputDeviceGenerations[uid, default: 0]
    }

    /// Pins the live capture identity after a recording-time disconnect so a
    /// system-default fallback cannot masquerade as the device that produced
    /// the file. The stable UID is then restored normally if it reconnects.
    func preserveDisconnectedSelection(
        inputUID: String,
        inputName: String,
        inputRouteID: String,
        outputUID: String?,
        outputName: String?
    ) {
        isRefreshing = true

        inputSelectionPreference = .device(uid: inputUID)
        savedInputUID = inputUID
        savedInputName = inputName
        selectedInputDeviceID =
            inputDevices.first {
                $0.uid == inputUID && $0.isAlive
            }?.id
        selectedInputRouteID =
            selectedInputDevice?.inputRoutes.contains {
                $0.id == inputRouteID
            } == true ? inputRouteID : nil
        preferences.set(
            SelectionMode.device.rawValue,
            forKey: Defaults.inputSelectionMode
        )
        preferences.set(inputUID, forKey: Defaults.inputUID)
        preferences.set(inputName, forKey: Defaults.inputName)
        preferences.set(
            inputRouteID,
            forKey: Defaults.inputRoutePrefix + inputUID
        )

        if let outputUID {
            outputSelectionPreference = .device(uid: outputUID)
            savedOutputUID = outputUID
            savedOutputName = outputName
            selectedOutputDeviceID =
                outputDevices.first {
                    $0.uid == outputUID && $0.isAlive
                }?.id
            preferences.set(
                SelectionMode.device.rawValue,
                forKey: Defaults.outputSelectionMode
            )
            preferences.set(outputUID, forKey: Defaults.outputUID)
            if let outputName {
                preferences.set(outputName, forKey: Defaults.outputName)
            } else {
                preferences.removeObject(forKey: Defaults.outputName)
            }
        } else {
            outputSelectionPreference = .none
            savedOutputUID = nil
            savedOutputName = nil
            selectedOutputDeviceID = nil
            preferences.set(
                SelectionMode.none.rawValue,
                forKey: Defaults.outputSelectionMode
            )
            preferences.removeObject(forKey: Defaults.outputUID)
            preferences.removeObject(forKey: Defaults.outputName)
        }

        isRefreshing = false
    }

    // MARK: - Route creation

    static func makeInputRoutes(
        channelCount: Int,
        channelNames: [String]
    ) -> [AudioInputRoute] {
        guard channelCount > 0 else { return [] }
        if channelCount == 1 {
            let name = channelNames.first ?? "Input 1"
            return [
                AudioInputRoute(
                    id: "channels-1-1",
                    name: "\(name) (Mono)",
                    channelMap: [0, 0],
                    channelNames: [name, name]
                )
            ]
        }

        return stride(from: 0, to: channelCount, by: 2).map { left in
            let right = min(left + 1, channelCount - 1)
            let leftName =
                channelNames.indices.contains(left)
                ? channelNames[left]
                : "Input \(left + 1)"
            let rightName =
                channelNames.indices.contains(right)
                ? channelNames[right]
                : "Input \(right + 1)"
            let genericName =
                left == right
                ? "\(leftName) (Mono)"
                : "Inputs \(left + 1)–\(right + 1)"
            let descriptiveName: String
            if leftName == "Input \(left + 1)",
                rightName == "Input \(right + 1)"
            {
                descriptiveName = genericName
            } else if left == right {
                descriptiveName = "\(leftName) (Mono)"
            } else {
                descriptiveName =
                    "\(genericName) · \(leftName) / \(rightName)"
            }

            return AudioInputRoute(
                id: "channels-\(left + 1)-\(right + 1)",
                name: descriptiveName,
                channelMap: [Int32(left), Int32(right)],
                channelNames: [leftName, rightName]
            )
        }
    }

    /// Compatibility helper for app-internal callers. Stable UIDs should be
    /// retained instead of this process-local ID.
    static func deviceUID(for deviceID: AudioDeviceID) -> String? {
        try? ProductionCoreAudioHAL().deviceUID(for: deviceID)
    }

    // MARK: - Persistence

    private func persistInputSelection() {
        guard let device = selectedInputDevice else {
            inputSelectionPreference = .none
            savedInputUID = nil
            savedInputName = nil
            selectedInputRouteID = nil
            preferences.set(
                SelectionMode.none.rawValue,
                forKey: Defaults.inputSelectionMode
            )
            preferences.removeObject(forKey: Defaults.inputUID)
            preferences.removeObject(forKey: Defaults.inputName)
            return
        }

        inputSelectionPreference = .device(uid: device.uid)
        savedInputUID = device.uid
        savedInputName = device.name
        preferences.set(
            SelectionMode.device.rawValue,
            forKey: Defaults.inputSelectionMode
        )
        preferences.set(device.uid, forKey: Defaults.inputUID)
        preferences.set(device.name, forKey: Defaults.inputName)
    }

    private func persistOutputSelection() {
        guard let device = selectedOutputDevice else {
            outputSelectionPreference = .none
            savedOutputUID = nil
            savedOutputName = nil
            preferences.set(
                SelectionMode.none.rawValue,
                forKey: Defaults.outputSelectionMode
            )
            preferences.removeObject(forKey: Defaults.outputUID)
            preferences.removeObject(forKey: Defaults.outputName)
            return
        }

        outputSelectionPreference = .device(uid: device.uid)
        savedOutputUID = device.uid
        savedOutputName = device.name
        preferences.set(
            SelectionMode.device.rawValue,
            forKey: Defaults.outputSelectionMode
        )
        preferences.set(device.uid, forKey: Defaults.outputUID)
        preferences.set(device.name, forKey: Defaults.outputName)
    }

    private enum SelectionMode: String {
        case none
        case systemDefault
        case device
    }

    private static func selectionPreference(
        persistedMode: String?,
        legacyUID: String?
    ) -> AudioDeviceSelectionPreference {
        switch persistedMode.flatMap(SelectionMode.init(rawValue:)) {
        case .some(.none):
            return .none
        case .some(.systemDefault):
            return .systemDefault
        case .some(.device):
            return legacyUID.map(AudioDeviceSelectionPreference.device(uid:))
                ?? .none
        case nil:
            return legacyUID.map(AudioDeviceSelectionPreference.device(uid:))
                ?? .systemDefault
        }
    }

    private func persistSelectionModes() {
        if inputSelectionPreference == .none
            || inputSelectionPreference == .systemDefault
        {
            savedInputUID = nil
            savedInputName = nil
            preferences.removeObject(forKey: Defaults.inputUID)
            preferences.removeObject(forKey: Defaults.inputName)
        }
        if outputSelectionPreference == .none
            || outputSelectionPreference == .systemDefault
        {
            savedOutputUID = nil
            savedOutputName = nil
            preferences.removeObject(forKey: Defaults.outputUID)
            preferences.removeObject(forKey: Defaults.outputName)
        }
        preferences.set(
            Self.mode(for: inputSelectionPreference).rawValue,
            forKey: Defaults.inputSelectionMode
        )
        preferences.set(
            Self.mode(for: outputSelectionPreference).rawValue,
            forKey: Defaults.outputSelectionMode
        )
    }

    private static func mode(
        for preference: AudioDeviceSelectionPreference
    ) -> SelectionMode {
        switch preference {
        case .none:
            .none
        case .systemDefault:
            .systemDefault
        case .device:
            .device
        }
    }

    private func updateDeviceGenerations(
        _ descriptions: [CoreAudioHALDevice]
    ) {
        let currentInputs: [String: InputDeviceBindingFingerprint] = Dictionary(
            descriptions.compactMap {
                device
                    -> (String, InputDeviceBindingFingerprint)? in
                guard device.inputChannelCount > 0 else { return nil }
                return (
                    device.uid,
                    InputDeviceBindingFingerprint(
                        id: device.id,
                        isAlive: device.isAlive,
                        channelCount: device.inputChannelCount,
                        nominalSampleRate: device.nominalSampleRate,
                        bufferFrameRange: device.bufferFrameRange
                    )
                )
            },
            uniquingKeysWith: { _, latest in latest }
        )
        for (uid, binding) in currentInputs
        where lastInputBindingsByUID[uid] != binding {
            inputDeviceGenerations[uid, default: 0] &+= 1
        }
        for uid in lastInputBindingsByUID.keys where currentInputs[uid] == nil {
            inputDeviceGenerations[uid, default: 0] &+= 1
        }
        lastInputBindingsByUID = currentInputs

        let currentOutputs: [String: OutputDeviceBindingFingerprint] = Dictionary(
            descriptions.compactMap {
                device
                    -> (String, OutputDeviceBindingFingerprint)? in
                guard device.outputChannelCount > 0 else { return nil }
                return (
                    device.uid,
                    OutputDeviceBindingFingerprint(
                        id: device.id,
                        isAlive: device.isAlive,
                        channelCount: device.outputChannelCount,
                        nominalSampleRate: device.nominalSampleRate,
                        bufferFrameRange: device.bufferFrameRange
                    )
                )
            },
            uniquingKeysWith: { _, latest in latest }
        )
        for (uid, binding) in currentOutputs
        where lastOutputBindingsByUID[uid] != binding {
            outputDeviceGenerations[uid, default: 0] &+= 1
        }
        for uid in lastOutputBindingsByUID.keys
        where currentOutputs[uid] == nil {
            outputDeviceGenerations[uid, default: 0] &+= 1
        }
        lastOutputBindingsByUID = currentOutputs
    }

    private func restoreInputRoute() {
        guard let device = selectedInputDevice else {
            selectedInputRouteID = nil
            return
        }

        let saved = preferences.string(
            forKey: Defaults.inputRoutePrefix + device.uid
        )
        let resolved =
            device.inputRoutes.contains {
                $0.id == saved
            } ? saved : device.inputRoutes.first?.id
        selectedInputRouteID = resolved
        if let resolved, resolved != saved {
            preferences.set(
                resolved,
                forKey: Defaults.inputRoutePrefix + device.uid
            )
        }
    }

    // MARK: - Change listeners

    private func installHardwareListener() {
        do {
            deviceListListener = try hal.observeDeviceList {
                [weak self] in
                Task { @MainActor [weak self] in
                    guard self?.microphonePermissionGranted == true else {
                        return
                    }
                    try? self?.refreshDevices()
                }
            }
        } catch {
            lastDiscoveryError = error.localizedDescription
        }
    }

    private func reinstallAliveListeners(deviceIDs: [AudioDeviceID]) {
        for listener in aliveListeners.values {
            listener.cancel()
        }
        aliveListeners.removeAll(keepingCapacity: true)

        for deviceID in deviceIDs {
            do {
                let listener = try hal.observeAlive(
                    deviceID: deviceID
                ) { [weak self] in
                    Task { @MainActor [weak self] in
                        try? self?.refreshDevices()
                    }
                }
                aliveListeners[deviceID] = listener
            } catch {
                lastDiscoveryError = error.localizedDescription
            }
        }
    }

    // MARK: - Translation

    private static func makeDevice(
        _ description: CoreAudioHALDevice
    ) -> AudioDevice {
        AudioDevice(
            id: description.id,
            uid: description.uid,
            name: description.name,
            isInput: description.inputChannelCount > 0,
            isOutput: description.outputChannelCount > 0,
            inputChannelCount: description.inputChannelCount,
            outputChannelCount: description.outputChannelCount,
            inputRoutes: makeInputRoutes(
                channelCount: description.inputChannelCount,
                channelNames: description.inputChannelNames
            ),
            nominalSampleRate: description.nominalSampleRate,
            availableSampleRates: description.availableSampleRates,
            bufferFrameRange: description.bufferFrameRange,
            transport: description.transport,
            isAlive: description.isAlive
        )
    }

    private static func makeDefaultHAL() -> any CoreAudioHAL {
        #if DEBUG
            let environment = ProcessInfo.processInfo.environment
            if environment["PHONOFLOW_ACCEPTANCE"] == "1",
                environment["PHONOFLOW_AUDIO_BACKEND"]?.lowercased() == "fake"
            {
                return FakeCoreAudioHAL()
            }
        #endif
        return ProductionCoreAudioHAL()
    }

    private static func makeDefaultPreferences() -> any AudioDevicePreferences {
        #if DEBUG
            let environment = ProcessInfo.processInfo.environment
            if environment["PHONOFLOW_ACCEPTANCE"] == "1",
                environment["PHONOFLOW_AUDIO_BACKEND"]?.lowercased() == "fake"
            {
                // Acceptance runs must not inherit a developer machine's
                // persisted hardware UIDs or route selections.
                return InMemoryAudioDevicePreferences()
            }
        #endif
        return UserDefaultsAudioDevicePreferences()
    }
}
