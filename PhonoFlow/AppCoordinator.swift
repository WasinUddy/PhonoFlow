//
//  AppCoordinator.swift
//  PhonoFlow
//
//  Main-actor authority shared by the native interface and paired LAN clients.
//

import CoreAudio
import Foundation
import Observation

private let coordinatorEQFrequencies: [Float] = [
    31, 62, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000,
]

private struct CoordinatorAudioSelection: Equatable {
    var inputUID: String
    var inputName: String
    var inputRouteID: String
    var outputUID: String?
    var outputName: String?
}

private struct CoordinatorAudioBinding: Equatable {
    var inputDeviceID: AudioDeviceID
    var inputAlive: Bool
    var inputGeneration: UInt64
    var outputDeviceID: AudioDeviceID?
    var outputAlive: Bool
    var outputGeneration: UInt64?
}

/// A normalized snapshot used to decide whether the authoritative revision
/// should advance. Meter values, timestamps, and recording elapsed time are
/// deliberately excluded because they have their own bounded-rate publication.
private struct CoordinatorStateFingerprint: Equatable {
    var engine: RemoteEngineState
    var devices: [RemoteAudioDevice]
    var selection: RemoteAudioSelection?
    var processing: RemoteProcessingState
    var equalizer: RemoteEqualizerState
    var monitor: RemoteToggleState
    var radio: RemoteRadioState
    var recordingEnabled: Bool
    var recordingElapsedSecond: Int
    var recordingFileName: String?
    var diagnostics: RemoteDiagnosticsSnapshot
}

/// Injectable listener dependencies keep coordinator lifecycle tests hermetic
/// while preserving the production server configuration by default.
struct AppCoordinatorRemoteDependencies {
    var bindHost: String
    var legacyBindHost: String
    var pairing: RemotePairingService?
    var bonjour: (any RemoteBonjourAdvertising)?
    var remoteTransport: (any RemoteHTTPTransport)?
    var legacyTransport: (any RemoteHTTPTransport)?
    var localAuthorityProvider: @Sendable () -> Set<String>
    var usesAcceptanceEnvironment: Bool

    init(
        bindHost: String = "0.0.0.0",
        legacyBindHost: String = "0.0.0.0",
        pairing: RemotePairingService? = nil,
        bonjour: (any RemoteBonjourAdvertising)? = nil,
        remoteTransport: (any RemoteHTTPTransport)? = nil,
        legacyTransport: (any RemoteHTTPTransport)? = nil,
        localAuthorityProvider: @escaping @Sendable () -> Set<String> = {
            RemoteLocalInterfaces.currentAuthorities()
        },
        usesAcceptanceEnvironment: Bool = true
    ) {
        self.bindHost = bindHost
        self.legacyBindHost = legacyBindHost
        self.pairing = pairing
        self.bonjour = bonjour
        self.remoteTransport = remoteTransport
        self.legacyTransport = legacyTransport
        self.localAuthorityProvider = localAuthorityProvider
        self.usesAcceptanceEnvironment = usesAcceptanceEnvironment
    }
}

@MainActor
@Observable
final class AppCoordinator: RemoteControlCoordinating {
    let audioManager: AudioDeviceManager
    let audioMonitor: AudioMonitor
    let settings: AppSettings

    /// The server and capture worker share this concrete fanout. Keeping it
    /// here avoids an inaccessible server-owned stream provider and lets the
    /// audio pipeline publish one converted block to every browser.
    let remoteAudioFanout: RemoteAudioFanout

    private(set) var revision: UInt64 = 1
    private(set) var remoteAccessState: RemoteServerLifecycleState = .disabled
    private(set) var remoteEndpoint: RemoteBoundEndpoint?
    private(set) var pairingCode: RemotePairingCode?
    private(set) var listenerCounts = RemoteListenerCounts(eventStreams: 0, audioStreams: 0)
    private(set) var remoteAccessError: String?
    private(set) var legacyStreamState: RemoteServerLifecycleState =
        .disabled
    private(set) var legacyStreamEndpoint: RemoteBoundEndpoint?
    private(set) var legacyStreamError: String?
    private(set) var nativeCommandError: String?

    var remoteAccessURL: URL? {
        guard let endpoint = remoteEndpoint else { return nil }
        let host = Self.advertisedHost(for: endpoint.host)
        let escapedHost = host.contains(":") ? "[\(host)]" : host
        return URL(string: "http://\(escapedHost):\(endpoint.port)/")
    }

    var remoteAccessStatusText: String {
        switch remoteAccessState {
        case .disabled:
            return "Off"
        case .starting:
            return "Starting"
        case .running(let host, let port):
            return "\(host):\(port)"
        case .failed(let message):
            return "Failed: \(message)"
        case .stopping:
            return "Stopping"
        }
    }

    @ObservationIgnored
    private lazy var remoteServer = RemoteAccessServer(
        configuration: desiredRemoteConfiguration(),
        coordinator: self,
        pairing: remoteDependencies.pairing,
        audio: remoteAudioFanout,
        bonjour: remoteDependencies.bonjour,
        transport: remoteDependencies.remoteTransport,
        localAuthorityProvider: remoteDependencies.localAuthorityProvider,
        usesAcceptanceEnvironment:
            remoteDependencies.usesAcceptanceEnvironment
    )

    @ObservationIgnored
    private lazy var legacyStreamServer = LegacyStreamServer(
        configuration: desiredLegacyStreamConfiguration(),
        audio: remoteAudioFanout,
        transport: remoteDependencies.legacyTransport
    )

    @ObservationIgnored private let remoteDependencies: AppCoordinatorRemoteDependencies
    @ObservationIgnored private var maintenanceTimer: DispatchSourceTimer?
    @ObservationIgnored private var maintenanceTask: Task<Void, Never>?
    @ObservationIgnored private var shutdownTask: Task<Void, Never>?
    @ObservationIgnored private var isActive = false
    @ObservationIgnored private var lifecycleGeneration: UInt64 = 0
    @ObservationIgnored private var meterSequence: UInt64 = 0
    @ObservationIgnored private var lastPublishedRevision: UInt64 = 0
    @ObservationIgnored private var latestMeters = RemoteMeterSnapshot(
        left: 0,
        right: 0,
        peak: 0
    )
    @ObservationIgnored private var lastFingerprint: CoordinatorStateFingerprint?
    @ObservationIgnored private var appliedRemoteConfiguration: RemoteAccessConfiguration?
    @ObservationIgnored private var failedRemoteConfiguration: RemoteAccessConfiguration?
    @ObservationIgnored private var appliedLegacyStreamConfiguration: LegacyStreamConfiguration?
    @ObservationIgnored private var failedLegacyStreamConfiguration: LegacyStreamConfiguration?
    @ObservationIgnored private var lastReconciledRadioEnabled = false
    @ObservationIgnored private var lastAppliedSelection: CoordinatorAudioSelection?
    @ObservationIgnored private var lastAppliedAudioBinding: CoordinatorAudioBinding?
    @ObservationIgnored private var nativeInterfaceVisible = false
    @ObservationIgnored private var nativeAdvancedVisualizationsVisible = false
    @ObservationIgnored private var appliedNativeVisualizationDemand: Bool?
    @ObservationIgnored private var processingEnabled = true
    @ObservationIgnored private var equalizerEnabled = true
    @ObservationIgnored private var configuredGain: Float
    @ObservationIgnored private var configuredAutoGain: Bool
    @ObservationIgnored private var configuredEQBands: [Float]

    convenience init() {
        self.init(
            audioManager: AudioDeviceManager(),
            audioMonitor: AudioMonitor(),
            settings: AppSettings()
        )
    }

    init(
        audioManager: AudioDeviceManager,
        audioMonitor: AudioMonitor,
        settings: AppSettings,
        remoteAudioFanout: RemoteAudioFanout = RemoteAudioFanout(),
        remoteDependencies: AppCoordinatorRemoteDependencies =
            AppCoordinatorRemoteDependencies()
    ) {
        self.audioManager = audioManager
        self.audioMonitor = audioMonitor
        self.settings = settings
        self.remoteAudioFanout = remoteAudioFanout
        self.remoteDependencies = remoteDependencies
        configuredGain = audioMonitor.gain
        configuredAutoGain = audioMonitor.isAutoGainEnabled
        configuredEQBands = Self.normalizedEQBands(audioMonitor.eqBands)
        lastAppliedSelection = Self.selection(from: audioManager)
        if audioMonitor.isMonitoring {
            lastAppliedAudioBinding = Self.binding(from: audioManager)
        }
        latestMeters = makeMeterSnapshot(advancingSequence: false)
        lastFingerprint = makeFingerprint(from: makeSnapshot())
    }

    deinit {
        maintenanceTimer?.setEventHandler {}
        maintenanceTimer?.cancel()
    }

    // MARK: - Application lifecycle

    /// Starts app-owned services. Calling this repeatedly is harmless.
    func activate() {
        guard !isActive else { return }
        isActive = true
        lifecycleGeneration &+= 1
        audioMonitor.isMeteringEnabled = true
        audioManager.updatePermissionStatus()
        if audioManager.microphonePermissionGranted {
            try? refreshAudioDevices()
        }

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now(),
            repeating: .milliseconds(100),
            leeway: .milliseconds(10)
        )
        timer.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.scheduleMaintenanceTick()
            }
        }
        timer.resume()
        maintenanceTimer = timer
        scheduleMaintenanceTick()
    }

    func shutdown() {
        guard isActive else { return }
        isActive = false
        lifecycleGeneration &+= 1
        let shutdownGeneration = lifecycleGeneration
        maintenanceTimer?.setEventHandler {}
        maintenanceTimer?.cancel()
        maintenanceTimer = nil
        maintenanceTask?.cancel()
        maintenanceTask = nil
        audioMonitor.setRemoteSpectrumSubscribersVisible(false)
        audioMonitor.setRemoteAudioSubscribersVisible(false)
        audioMonitor.detachRemoteAccess()
        audioMonitor.detachLegacyStream()
        audioMonitor.stopMonitoring()
        remoteAccessState = .stopping
        remoteEndpoint = nil
        pairingCode = nil
        legacyStreamState = .stopping
        legacyStreamEndpoint = nil
        listenerCounts = RemoteListenerCounts(
            eventStreams: 0,
            audioStreams: 0
        )

        shutdownTask = Task {
            @MainActor [
                weak self,
                remoteServer,
                legacyStreamServer
            ] in
            await legacyStreamServer.stop()
            await remoteServer.stop()
            guard let self else { return }
            if lifecycleGeneration == shutdownGeneration {
                remoteAccessState = .disabled
                remoteAccessError = nil
                legacyStreamState = .disabled
                legacyStreamError = nil
            }
            shutdownTask = nil
        }
    }

    /// Stops app-owned services and returns only after both listeners finish
    /// revoking clients and releasing their transports.
    func shutdownAndWait() async {
        shutdown()
        await shutdownTask?.value
    }

    // MARK: - Pairing and remote status

    @discardableResult
    func issuePairingCode() async throws -> RemotePairingCode {
        let authoritativeState = await remoteServer.lifecycleState()
        remoteAccessState = authoritativeState
        guard case .running = authoritativeState else {
            pairingCode = nil
            let failure = Self.remoteAccessNotRunningFailure()
            remoteAccessError = failure.detail
            throw failure
        }
        do {
            let issued = try await remoteServer.issuePairingCode()
            pairingCode = issued
            remoteAccessError = nil
            return issued
        } catch RemoteAccessServerError.notRunning {
            pairingCode = nil
            remoteAccessState = await remoteServer.lifecycleState()
            let failure = Self.remoteAccessNotRunningFailure()
            remoteAccessError = failure.detail
            throw failure
        } catch {
            remoteAccessError = String(describing: error)
            throw error
        }
    }

    func revokeAllBrowsers() async throws {
        do {
            try await remoteServer.revokeAllBrowsers()
            pairingCode = nil
            listenerCounts = await remoteServer.listenerCounts()
            remoteAccessError = nil
        } catch {
            remoteAccessError = String(describing: error)
            throw error
        }
    }

    /// Clears a failed-start latch and retries the current configuration.
    func retryRemoteAccess() {
        failedRemoteConfiguration = nil
        scheduleMaintenanceTick()
    }

    // MARK: - Native command surface

    /// Prepares capture for the menu-bar interface without allowing the view
    /// to mutate the device manager or audio engine directly.
    func prepareNativeInterface() {
        audioMonitor.isMeteringEnabled = true
        audioManager.updatePermissionStatus()

        guard audioManager.microphonePermissionGranted else {
            if !audioManager.permissionDenied {
                audioManager.requestMicrophonePermission()
            }
            return
        }

        refreshNativeAudioDevices()
    }

    func requestNativeMicrophoneAccess() {
        nativeCommandError = nil
        audioManager.requestMicrophonePermission()
    }

    /// Records whether the menu-bar interface is currently presented. Views
    /// report visibility; the coordinator alone owns the resulting audio
    /// analysis and UI-publish lifecycle.
    func setNativeInterfaceVisible(_ visible: Bool) {
        guard nativeInterfaceVisible != visible else { return }
        nativeInterfaceVisible = visible
        applyNativeVisualizationDemand()

        if visible, audioMonitor.isMonitoring {
            audioMonitor.startUIUpdateTimer()
        }
    }

    /// Sets demand for the high-cost waveform, phase, and spectrogram views.
    /// This is kept separate from interface visibility so a hidden popover
    /// never performs analysis even when the preference remains enabled.
    func setNativeAdvancedVisualizationsVisible(_ visible: Bool) {
        guard nativeAdvancedVisualizationsVisible != visible else { return }
        nativeAdvancedVisualizationsVisible = visible
        applyNativeVisualizationDemand()
    }

    @discardableResult
    func refreshNativeAudioDevices() -> Bool {
        performNativeCommand {
            try refreshAudioDevices()
        }
    }

    @discardableResult
    func selectNativeInputDevice(uid: String?) -> Bool {
        performNativeCommand {
            guard let uid else {
                try clearNativeInputSelection()
                return
            }
            guard
                let device = audioManager.inputDevices.first(where: {
                    $0.uid == uid && $0.isAlive
                })
            else {
                throw RemoteControlFailure(
                    kind: .invalid,
                    code: "input_device_invalid",
                    detail: "The selected input device is not connected."
                )
            }
            guard
                let route =
                    device.inputRoutes.first(where: {
                        $0.id == audioManager.savedInputRouteID(forDeviceUID: uid)
                    }) ?? device.inputRoutes.first
            else {
                throw RemoteControlFailure(
                    kind: .invalid,
                    code: "input_route_unavailable",
                    detail: "The selected input does not expose a usable channel route."
                )
            }
            try applyAudioSelection(
                RemoteAudioSelection(
                    inputUID: uid,
                    inputRouteID: route.id,
                    outputUID: audioManager.selectedOutputDevice?.uid
                )
            )
        }
    }

    @discardableResult
    func selectNativeInputRoute(id: String?) -> Bool {
        performNativeCommand {
            guard let input = audioManager.selectedInputDevice else {
                throw RemoteControlFailure(
                    kind: .invalid,
                    code: "input_device_required",
                    detail: "Select an input device before choosing a channel route."
                )
            }
            guard
                let route =
                    input.inputRoutes.first(where: { $0.id == id })
                    ?? (id == nil ? input.inputRoutes.first : nil)
            else {
                throw RemoteControlFailure(
                    kind: .invalid,
                    code: "input_route_invalid",
                    detail: "The selected input route is no longer available."
                )
            }
            try applyAudioSelection(
                RemoteAudioSelection(
                    inputUID: input.uid,
                    inputRouteID: route.id,
                    outputUID: audioManager.selectedOutputDevice?.uid
                )
            )
        }
    }

    @discardableResult
    func selectNativeOutputDevice(uid: String?) -> Bool {
        performNativeCommand {
            let output: AudioDevice?
            if let uid {
                guard
                    let resolved = audioManager.outputDevices.first(where: {
                        $0.uid == uid && $0.isAlive
                    })
                else {
                    throw RemoteControlFailure(
                        kind: .invalid,
                        code: "output_device_invalid",
                        detail: "The selected output device is not connected."
                    )
                }
                output = resolved
            } else {
                output = nil
            }

            guard
                let input = audioManager.selectedInputDevice,
                let route = audioManager.selectedInputRoute
            else {
                audioManager.selectedOutputDeviceID = output?.id
                if let output {
                    audioMonitor.updatePassthroughOutput(deviceID: output.id)
                } else {
                    audioMonitor.clearPassthroughOutput()
                }
                return
            }

            try applyAudioSelection(
                RemoteAudioSelection(
                    inputUID: input.uid,
                    inputRouteID: route.id,
                    outputUID: output?.uid
                )
            )
        }
    }

    @discardableResult
    func setNativeMonitorEnabled(_ enabled: Bool) -> Bool {
        performNativeCommand {
            try applyMonitor(enabled: enabled)
        }
    }

    @discardableResult
    func setNativeRadioEnabled(_ enabled: Bool) -> Bool {
        performNativeCommand {
            try applyRadio(enabled: enabled)
        }
    }

    @discardableResult
    func setNativeRecordingEnabled(_ enabled: Bool) -> Bool {
        performNativeCommand {
            try applyRecording(enabled: enabled)
        }
    }

    @discardableResult
    func setNativeGain(_ gain: Float) -> Bool {
        performNativeCommand {
            try applyProcessing(RemoteProcessingCommand(gain: gain))
        }
    }

    @discardableResult
    func setNativeAutoGainEnabled(_ enabled: Bool) -> Bool {
        performNativeCommand {
            try applyProcessing(
                RemoteProcessingCommand(autoGainEnabled: enabled)
            )
        }
    }

    @discardableResult
    func setNativeEqualizerBands(_ gains: [Float]) -> Bool {
        performNativeCommand {
            guard gains.count == coordinatorEQFrequencies.count else {
                throw RemoteControlFailure(
                    kind: .invalid,
                    code: "equalizer_band_count",
                    detail: "The equalizer requires exactly ten bands."
                )
            }
            try applyEqualizer(
                RemoteEqualizerCommand(
                    bands: zip(coordinatorEQFrequencies, gains).map {
                        RemoteEqualizerBand(
                            frequencyHz: $0.0,
                            gainDB: $0.1
                        )
                    }
                )
            )
        }
    }

    private func performNativeCommand(
        _ operation: () throws -> Void
    ) -> Bool {
        do {
            try operation()
            nativeCommandError = nil
            _ = commitAuthoritativeState()
            scheduleMaintenanceTick()
            return true
        } catch let failure as RemoteControlFailure {
            nativeCommandError = failure.detail
            return false
        } catch {
            nativeCommandError = error.localizedDescription
            return false
        }
    }

    private func applyNativeVisualizationDemand() {
        let shouldRun =
            nativeInterfaceVisible
            && nativeAdvancedVisualizationsVisible
        guard appliedNativeVisualizationDemand != shouldRun else { return }
        appliedNativeVisualizationDemand = shouldRun
        if shouldRun {
            audioMonitor.resumeVisualizations()
        } else {
            audioMonitor.pauseVisualizations()
        }
    }

    private func clearNativeInputSelection() throws {
        guard !audioMonitor.isRecording else {
            throw RemoteControlFailure(
                kind: .conflict,
                code: "recording_locks_capture",
                detail: "Stop recording before clearing the input device."
            )
        }
        audioMonitor.clearSpectrogram()
        audioMonitor.stopMonitoring()
        audioManager.selectedInputDeviceID = nil
        lastAppliedSelection = nil
        lastAppliedAudioBinding = nil
    }

    // MARK: - RemoteControlCoordinating

    func remoteStateSnapshot() -> RemoteStateSnapshot {
        commitAuthoritativeState()
    }

    func applyRemoteCommand(
        _ command: RemoteControlCommand
    ) async throws -> RemoteStateSnapshot {
        switch command {
        case .refreshDevices:
            try refreshAudioDevices()

        case .selectAudio(let selection):
            try applyAudioSelection(selection)

        case .setMonitor(let command):
            try applyMonitor(enabled: command.enabled)

        case .setProcessing(let command):
            try applyProcessing(command)

        case .setEqualizer(let command):
            try applyEqualizer(command)

        case .setRadio(let command):
            try applyRadio(enabled: command.enabled)

        case .setRecording(let command):
            try applyRecording(enabled: command.enabled)
        }

        let snapshot = commitAuthoritativeState()
        // RemoteRequestRouter publishes successful command responses to its
        // event hub immediately. Recording this revision prevents the 10 Hz
        // reconciler from emitting a duplicate copy of the same transition.
        lastPublishedRevision = snapshot.revision
        return snapshot
    }

    // MARK: - Command implementations

    private func refreshAudioDevices() throws {
        do {
            try audioManager.refreshDevices()
        } catch let failure as AudioDeviceRefreshError {
            throw RemoteControlFailure(
                kind: .unavailable,
                code: "device_discovery_failed",
                detail: failure.localizedDescription
            )
        }
        reconcileAudioSelection()
    }

    private func applyAudioSelection(
        _ selection: RemoteAudioSelection
    ) throws {
        guard
            let input = audioManager.inputDevices.first(where: {
                $0.uid == selection.inputUID && $0.isAlive
            })
        else {
            throw RemoteControlFailure(
                kind: .invalid,
                code: "input_device_invalid",
                detail: "The requested input device is not connected."
            )
        }
        guard
            let route = input.inputRoutes.first(where: {
                $0.id == selection.inputRouteID
            })
        else {
            throw RemoteControlFailure(
                kind: .invalid,
                code: "input_route_invalid",
                detail: "The requested input route is not available on this device."
            )
        }

        let output: AudioDevice?
        if let outputUID = selection.outputUID {
            guard
                let resolved = audioManager.outputDevices.first(where: {
                    $0.uid == outputUID && $0.isAlive
                })
            else {
                throw RemoteControlFailure(
                    kind: .invalid,
                    code: "output_device_invalid",
                    detail: "The requested output device is not connected."
                )
            }
            output = resolved
        } else {
            output = nil
        }

        let previous = lastAppliedSelection
        let previousInput = previous.flatMap { applied in
            audioManager.inputDevices.first {
                $0.uid == applied.inputUID
            }
        }
        let previousRoute = previous.flatMap { applied in
            previousInput?.inputRoutes.first {
                $0.id == applied.inputRouteID
            }
        }
        let previousOutput = previous?.outputUID.flatMap { uid in
            audioManager.outputDevices.first { $0.uid == uid }
        }
        let desiredBinding = Self.binding(
            input: input,
            output: output,
            manager: audioManager
        )
        let changesCapture =
            previous?.inputUID != selection.inputUID
            || previous?.inputRouteID != selection.inputRouteID
        if audioMonitor.isRecording && changesCapture {
            throw RemoteControlFailure(
                kind: .conflict,
                code: "recording_locks_capture",
                detail: "Stop recording before changing the input device, route, or sample rate."
            )
        }

        let captureBindingChanged =
            lastAppliedAudioBinding?.inputDeviceID
            != desiredBinding.inputDeviceID
            || lastAppliedAudioBinding?.inputAlive
                != desiredBinding.inputAlive
            || lastAppliedAudioBinding?.inputGeneration
                != desiredBinding.inputGeneration
        let outputChanged =
            previous?.outputUID != selection.outputUID
            || lastAppliedAudioBinding?.outputDeviceID
                != desiredBinding.outputDeviceID
            || lastAppliedAudioBinding?.outputAlive
                != desiredBinding.outputAlive
            || lastAppliedAudioBinding?.outputGeneration
                != desiredBinding.outputGeneration
        let shouldResumeRadio = audioMonitor.isStreamingEnabled
        let shouldResumeMonitor = audioMonitor.isPassthroughEnabled
        let restartsCapture =
            changesCapture || captureBindingChanged
            || !audioMonitor.isMonitoring
        if restartsCapture {
            audioMonitor.clearSpectrogram()
            audioMonitor.startMonitoring(
                deviceID: input.id,
                outputDeviceID: output?.id,
                inputChannelMap: route.channelMap
            )
            guard audioMonitor.isMonitoring else {
                let failureDetail =
                    audioMonitor.lastError?.localizedDescription
                    ?? "Core Audio could not start the selected input."
                // Device preferences remain untouched until capture succeeds.
                // Restore the previous live engine when possible so a rejected
                // remote command does not tear down otherwise healthy audio.
                if let previousInput,
                    previousInput.isAlive,
                    let previousRoute
                {
                    audioMonitor.startMonitoring(
                        deviceID: previousInput.id,
                        outputDeviceID: previousOutput?.id,
                        inputChannelMap: previousRoute.channelMap
                    )
                    restoreActiveNativeServices(
                        radio: shouldResumeRadio,
                        monitor: shouldResumeMonitor,
                        hasOutput: previousOutput != nil
                    )
                }
                throw RemoteControlFailure(
                    kind: .unavailable,
                    code: "capture_start_failed",
                    detail: failureDetail
                )
            }

            restoreActiveNativeServices(
                radio: shouldResumeRadio,
                monitor: shouldResumeMonitor,
                hasOutput: output != nil
            )
            if shouldResumeMonitor, output != nil,
                !audioMonitor.isPassthroughEnabled
            {
                let failureDetail =
                    audioMonitor.lastError?.localizedDescription
                    ?? "Core Audio could not restart output monitoring."
                if let previousInput,
                    previousInput.isAlive,
                    let previousRoute
                {
                    audioMonitor.startMonitoring(
                        deviceID: previousInput.id,
                        outputDeviceID: previousOutput?.id,
                        inputChannelMap: previousRoute.channelMap
                    )
                    restoreActiveNativeServices(
                        radio: shouldResumeRadio,
                        monitor: shouldResumeMonitor,
                        hasOutput: previousOutput != nil
                    )
                }
                throw RemoteControlFailure(
                    kind: .unavailable,
                    code: "monitor_restart_failed",
                    detail: failureDetail
                )
            }
        }

        if !restartsCapture, audioMonitor.isMonitoring, outputChanged {
            if let output {
                audioMonitor.updatePassthroughOutput(deviceID: output.id)
            } else {
                audioMonitor.clearPassthroughOutput()
            }
            if shouldResumeMonitor, output != nil,
                !audioMonitor.isPassthroughEnabled
            {
                let failureDetail =
                    audioMonitor.lastError?.localizedDescription
                    ?? "Core Audio could not switch to the selected output."
                if let previousOutput {
                    audioMonitor.updatePassthroughOutput(
                        deviceID: previousOutput.id
                    )
                    audioMonitor.enablePassthrough()
                } else {
                    audioMonitor.clearPassthroughOutput()
                }
                throw RemoteControlFailure(
                    kind: .unavailable,
                    code: "output_switch_failed",
                    detail: failureDetail
                )
            }
        }

        // Commit the stable selection only after the hardware transition has
        // succeeded, keeping the command atomic from clients' perspective.
        audioManager.selectedInputDeviceID = input.id
        audioManager.selectedInputRouteID = route.id
        audioManager.selectedOutputDeviceID = output?.id
        lastAppliedSelection = Self.selection(from: audioManager)
        if audioMonitor.isMonitoring {
            lastAppliedAudioBinding = desiredBinding
        }
    }

    private func restoreActiveNativeServices(
        radio: Bool,
        monitor: Bool,
        hasOutput: Bool
    ) {
        if radio {
            audioMonitor.startStreaming(
                port: settings.radioPort,
                allowedHosts: settings.allowedHosts
            )
        }
        if monitor, hasOutput {
            audioMonitor.enablePassthrough()
        }
    }

    private func applyMonitor(enabled: Bool) throws {
        guard enabled != audioMonitor.isPassthroughEnabled else { return }
        if enabled {
            guard audioMonitor.isMonitoring else {
                throw RemoteControlFailure(
                    kind: .unavailable,
                    code: "capture_not_running",
                    detail: "Select and start an input before enabling monitoring."
                )
            }
            guard audioManager.selectedOutputDevice != nil else {
                throw RemoteControlFailure(
                    kind: .invalid,
                    code: "output_required",
                    detail: "Select an output device before enabling monitoring."
                )
            }
            audioMonitor.enablePassthrough()
            guard audioMonitor.isPassthroughEnabled else {
                throw RemoteControlFailure(
                    kind: .unavailable,
                    code: "monitor_start_failed",
                    detail: audioMonitor.lastError?.localizedDescription
                        ?? "Core Audio could not start output monitoring."
                )
            }
        } else {
            audioMonitor.disablePassthrough()
        }
    }

    private func applyProcessing(
        _ command: RemoteProcessingCommand
    ) throws {
        if let gain = command.gain {
            guard gain.isFinite, (0...4).contains(gain) else {
                throw RemoteControlFailure(
                    kind: .invalid,
                    code: "gain_invalid",
                    detail: "Gain must be finite and between 0 and 4."
                )
            }
            configuredGain = gain
        }
        if let autoGain = command.autoGainEnabled {
            configuredAutoGain = autoGain
        }
        if let enabled = command.enabled {
            processingEnabled = enabled
        }
        applyConfiguredProcessing()
    }

    private func applyEqualizer(
        _ command: RemoteEqualizerCommand
    ) throws {
        if let bands = command.bands {
            guard bands.count == coordinatorEQFrequencies.count else {
                throw RemoteControlFailure(
                    kind: .invalid,
                    code: "equalizer_band_count",
                    detail: "The equalizer requires exactly ten bands."
                )
            }
            for (index, band) in bands.enumerated() {
                let expectedFrequency = coordinatorEQFrequencies[index]
                guard band.frequencyHz.isFinite,
                    abs(band.frequencyHz - expectedFrequency) < 0.5,
                    band.gainDB.isFinite,
                    (-12...12).contains(band.gainDB)
                else {
                    throw RemoteControlFailure(
                        kind: .invalid,
                        code: "equalizer_band_invalid",
                        detail:
                            "Equalizer frequencies must match the ten supported bands and gains must be between -12 and 12 dB."
                    )
                }
            }
            configuredEQBands = bands.map(\.gainDB)
        }
        if let enabled = command.enabled {
            equalizerEnabled = enabled
        }
        applyConfiguredProcessing()
    }

    private func applyRadio(enabled: Bool) throws {
        guard enabled != audioMonitor.isStreamingEnabled else { return }
        if enabled {
            guard audioMonitor.isMonitoring else {
                throw RemoteControlFailure(
                    kind: .unavailable,
                    code: "capture_not_running",
                    detail: "Select and start an input before enabling Radio."
                )
            }
            audioMonitor.startStreaming(
                port: settings.radioPort,
                allowedHosts: settings.allowedHosts
            )
            guard audioMonitor.isStreamingEnabled else {
                throw RemoteControlFailure(
                    kind: .unavailable,
                    code: "radio_start_failed",
                    detail: "The legacy Radio listener could not bind to its configured port."
                )
            }
        } else {
            audioMonitor.stopStreaming()
        }
    }

    private func applyRecording(enabled: Bool) throws {
        guard enabled != audioMonitor.isRecording else { return }
        if enabled {
            guard audioMonitor.isMonitoring else {
                throw RemoteControlFailure(
                    kind: .unavailable,
                    code: "capture_not_running",
                    detail: "Select and start an input before recording."
                )
            }
            audioMonitor.startRecording()
            guard audioMonitor.isRecording else {
                throw RemoteControlFailure(
                    kind: .unavailable,
                    code: "recording_start_failed",
                    detail: "PhonoFlow could not create a recording file."
                )
            }
        } else {
            if case .failure(let failure) = audioMonitor.stopRecording() {
                throw RemoteControlFailure(
                    kind: .unavailable,
                    code: "recording_finalize_failed",
                    detail: failure.localizedDescription
                )
            }
        }
    }

    private func applyConfiguredProcessing() {
        audioMonitor.gain = processingEnabled ? configuredGain : 1
        audioMonitor.isAutoGainEnabled =
            processingEnabled && configuredAutoGain
        audioMonitor.eqBands =
            processingEnabled && equalizerEnabled
            ? configuredEQBands
            : Array(repeating: 0, count: coordinatorEQFrequencies.count)
        audioMonitor.updatePassthroughVolume()
    }

    // MARK: - Periodic reconciliation

    private func scheduleMaintenanceTick() {
        guard isActive, maintenanceTask == nil else { return }
        let generation = lifecycleGeneration
        let pendingShutdown = shutdownTask
        maintenanceTask = Task { @MainActor [weak self] in
            if let pendingShutdown {
                await pendingShutdown.value
            }
            guard let self,
                isActive,
                lifecycleGeneration == generation,
                !Task.isCancelled
            else {
                if self?.lifecycleGeneration == generation {
                    self?.maintenanceTask = nil
                }
                return
            }
            await maintenanceTick(generation: generation)
            if lifecycleGeneration == generation {
                maintenanceTask = nil
            }
        }
    }

    private func maintenanceTick(generation: UInt64) async {
        guard
            isActive,
            lifecycleGeneration == generation,
            !Task.isCancelled
        else { return }

        reconcileAudioSelection()
        reconcileNativeProcessingState()
        await reconcileRemoteAccess(generation: generation)
        guard
            isActive,
            lifecycleGeneration == generation,
            !Task.isCancelled
        else { return }
        await reconcileLegacyStream(generation: generation)
        guard
            isActive,
            lifecycleGeneration == generation,
            !Task.isCancelled
        else { return }
        await refreshRemoteStatus(generation: generation)
        guard
            isActive,
            lifecycleGeneration == generation,
            !Task.isCancelled
        else { return }

        latestMeters = makeMeterSnapshot(advancingSequence: true)
        let snapshot = commitAuthoritativeState()

        guard case .running = remoteAccessState else { return }
        if snapshot.revision != lastPublishedRevision {
            await remoteServer.publish(snapshot: snapshot)
            lastPublishedRevision = snapshot.revision
        }
        await remoteServer.publish(meters: latestMeters)
    }

    private func reconcileAudioSelection() {
        let current = Self.selection(from: audioManager)

        if audioMonitor.isRecording, let lastAppliedSelection {
            let captureSelectionChanged =
                current?.inputUID != lastAppliedSelection.inputUID
                || current?.inputRouteID
                    != lastAppliedSelection.inputRouteID
            if captureSelectionChanged {
                if current != nil, restore(selection: lastAppliedSelection) {
                    return
                }
                preserveDisconnectedSelection(lastAppliedSelection)
                return
            }
        }

        guard let input = audioManager.selectedInputDevice,
            input.isAlive,
            let route = audioManager.selectedInputRoute
        else {
            finalizeCaptureForDisconnect()
            return
        }

        let currentBinding = Self.binding(from: audioManager)
        let routeNeedsRestart = audioMonitor.inputChannelMap != route.channelMap
        let inputNeedsRebind =
            lastAppliedAudioBinding?.inputDeviceID != input.id
            || lastAppliedAudioBinding?.inputAlive != input.isAlive
            || lastAppliedAudioBinding?.inputGeneration
                != audioManager.inputGeneration(forDeviceUID: input.uid)
        if !audioMonitor.isMonitoring || routeNeedsRestart || inputNeedsRebind {
            let output =
                audioManager.selectedOutputDevice.flatMap {
                    $0.isAlive ? $0 : nil
                }
            audioMonitor.startMonitoring(
                deviceID: input.id,
                outputDeviceID: output?.id,
                inputChannelMap: route.channelMap
            )
            lastAppliedAudioBinding =
                audioMonitor.isMonitoring ? currentBinding : nil
        } else if lastAppliedSelection?.outputUID
            != audioManager.selectedOutputDevice?.uid
            || lastAppliedAudioBinding?.outputDeviceID
                != currentBinding?.outputDeviceID
            || lastAppliedAudioBinding?.outputAlive
                != currentBinding?.outputAlive
            || lastAppliedAudioBinding?.outputGeneration
                != currentBinding?.outputGeneration
        {
            if let output = audioManager.selectedOutputDevice,
                output.isAlive
            {
                audioMonitor.updatePassthroughOutput(deviceID: output.id)
            } else {
                audioMonitor.clearPassthroughOutput()
            }
            lastAppliedAudioBinding = currentBinding
        }
        lastAppliedSelection = Self.selection(from: audioManager)
    }

    private func restore(selection: CoordinatorAudioSelection) -> Bool {
        guard
            let input = audioManager.inputDevices.first(where: {
                $0.uid == selection.inputUID && $0.isAlive
            }),
            input.inputRoutes.contains(where: {
                $0.id == selection.inputRouteID
            })
        else { return false }
        audioManager.selectedInputDeviceID = input.id
        audioManager.selectedInputRouteID = selection.inputRouteID
        audioManager.selectedOutputDeviceID = selection.outputUID.flatMap {
            uid in audioManager.outputDevices.first(where: { $0.uid == uid })?.id
        }
        return true
    }

    private func finalizeCaptureForDisconnect() {
        guard audioMonitor.isMonitoring || audioMonitor.isRecording else {
            lastAppliedAudioBinding = nil
            return
        }
        // stopMonitoring synchronously finalizes an active recording before
        // the disconnected engine state is exposed.
        audioMonitor.stopMonitoring()
        lastAppliedAudioBinding = nil
    }

    private func preserveDisconnectedSelection(
        _ selection: CoordinatorAudioSelection
    ) {
        audioManager.preserveDisconnectedSelection(
            inputUID: selection.inputUID,
            inputName: selection.inputName,
            inputRouteID: selection.inputRouteID,
            outputUID: selection.outputUID,
            outputName: selection.outputName
        )
        finalizeCaptureForDisconnect()
    }

    private func reconcileNativeProcessingState() {
        guard processingEnabled else { return }
        configuredGain = min(max(audioMonitor.gain, 0), 4)
        configuredAutoGain = audioMonitor.isAutoGainEnabled
        if equalizerEnabled {
            configuredEQBands = Self.normalizedEQBands(audioMonitor.eqBands)
        }
    }

    /// Decides when paired Remote Access may take ownership of Radio's port.
    /// A same-configuration failure is latched until an explicit retry or
    /// configuration change, so the working dedicated listener must remain
    /// untouched while that failure is reported.
    nonisolated static func shouldYieldDedicatedLegacyListener(
        shouldRunRemoteAccess: Bool,
        remoteConfiguration: RemoteAccessConfiguration,
        radioPort: UInt16,
        remoteLifecycle: RemoteServerLifecycleState,
        failedRemoteConfiguration: RemoteAccessConfiguration?
    ) -> Bool {
        guard
            shouldRunRemoteAccess,
            remoteConfiguration.port == radioPort
        else { return false }

        if case .failed = remoteLifecycle {
            return failedRemoteConfiguration != remoteConfiguration
        }
        if case .stopping = remoteLifecycle {
            return false
        }
        return true
    }

    private func reconcileRemoteAccess(generation: UInt64) async {
        guard isActive, lifecycleGeneration == generation else { return }
        let configuration = desiredRemoteConfiguration()
        let shouldRun = shouldRunRemoteAccess
        var lifecycle = await remoteServer.lifecycleState()

        // A paired server and the dedicated compatibility listener cannot own
        // the same socket. Give the paired service the configured shared port;
        // its exact `/stream` route continues to use the same audio fanout.
        if Self.shouldYieldDedicatedLegacyListener(
            shouldRunRemoteAccess: shouldRun,
            remoteConfiguration: configuration,
            radioPort: settings.radioPort,
            remoteLifecycle: lifecycle,
            failedRemoteConfiguration: failedRemoteConfiguration
        ) {
            let legacyLifecycle =
                await legacyStreamServer.lifecycleState()
            if legacyLifecycle != .disabled {
                audioMonitor.detachLegacyStream()
                await legacyStreamServer.stop()
                appliedLegacyStreamConfiguration = nil
                legacyStreamState = .disabled
                legacyStreamEndpoint = nil
            }
        }

        if !shouldRun {
            if lifecycle != .disabled {
                audioMonitor.detachRemoteAccess()
                await remoteServer.stop()
            }
            audioMonitor.setRemoteSpectrumSubscribersVisible(false)
            audioMonitor.setRemoteAudioSubscribersVisible(false)
            appliedRemoteConfiguration = nil
            failedRemoteConfiguration = nil
            remoteAccessError = nil
            return
        }

        if case .running = lifecycle,
            appliedRemoteConfiguration != configuration
        {
            audioMonitor.detachRemoteAccess()
            await remoteServer.stop()
            lifecycle = .disabled
            appliedRemoteConfiguration = nil
        }

        if case .running = lifecycle {
            // Refresh exact interface and hostname authorities after DHCP,
            // Wi-Fi, VPN, or hostname changes without bouncing the listener.
            await remoteServer.refreshLocalAuthorities()
        }

        if case .failed = lifecycle {
            guard failedRemoteConfiguration != configuration else { return }
            await remoteServer.stop()
            lifecycle = .disabled
        }

        guard
            lifecycle == .disabled,
            isActive,
            lifecycleGeneration == generation,
            !Task.isCancelled
        else { return }
        do {
            try await remoteServer.updateConfiguration(configuration)
            try await remoteServer.start()
            guard
                isActive,
                lifecycleGeneration == generation,
                !Task.isCancelled,
                shouldRunRemoteAccess,
                desiredRemoteConfiguration() == configuration
            else {
                await remoteServer.stop()
                return
            }
            appliedRemoteConfiguration = configuration
            failedRemoteConfiguration = nil
            remoteAccessError = nil
            let endpoint = await remoteServer.boundEndpoint()
            audioMonitor.attachRemoteAccess(
                audioFanout: remoteAudioFanout,
                server: remoteServer,
                baseURL: endpoint.map(Self.remoteBaseURL)
            )
            await remoteAudioFanout.setLegacySampleRate(
                UInt32(max(1, audioMonitor.captureSampleRate.rounded()))
            )
        } catch {
            audioMonitor.detachRemoteAccess()
            appliedRemoteConfiguration = nil
            failedRemoteConfiguration = configuration
            remoteAccessError = String(describing: error)
        }
    }

    private func reconcileLegacyStream(generation: UInt64) async {
        guard
            isActive,
            lifecycleGeneration == generation,
            !Task.isCancelled
        else { return }

        let shouldRun = audioMonitor.isStreamingEnabled
        let wasRunning = lastReconciledRadioEnabled
        lastReconciledRadioEnabled = shouldRun
        let configuration = desiredLegacyStreamConfiguration()
        let pairedState = await remoteServer.lifecycleState()
        let pairedEndpoint = await remoteServer.boundEndpoint()
        let usesPairedListener =
            shouldRun
            && shouldRunRemoteAccess
            && (!settings.allowLegacyUnauthenticatedStream
                || pairedEndpoint?.port == configuration.port)
            && {
                if case .running = pairedState { return true }
                return false
            }()

        if !shouldRun {
            if wasRunning {
                // Radio is authoritative for every legacy Float32 stream,
                // including clients using a shared paired-access port.
                await remoteAudioFanout.revoke(kind: .legacyFloat32)
            }
            let lifecycle = await legacyStreamServer.lifecycleState()
            if lifecycle != .disabled {
                audioMonitor.detachLegacyStream()
                await legacyStreamServer.stop()
            } else {
                audioMonitor.detachLegacyStream()
            }
            appliedLegacyStreamConfiguration = nil
            failedLegacyStreamConfiguration = nil
            legacyStreamState = .disabled
            legacyStreamEndpoint = nil
            legacyStreamError = nil
            return
        }

        if usesPairedListener, let pairedEndpoint {
            let lifecycle = await legacyStreamServer.lifecycleState()
            if lifecycle != .disabled {
                audioMonitor.detachLegacyStream()
                await legacyStreamServer.stop()
            }
            audioMonitor.attachLegacyStream(
                audioFanout: remoteAudioFanout,
                baseURL: Self.remoteBaseURL(for: pairedEndpoint)
            )
            appliedLegacyStreamConfiguration = nil
            failedLegacyStreamConfiguration = nil
            legacyStreamState = pairedState
            legacyStreamEndpoint = pairedEndpoint
            legacyStreamError = nil
            return
        }

        // The dedicated listener has no pairing surface by design, so it must
        // never bind unless the user explicitly enables the compatibility
        // escape hatch. With the escape hatch off, a running paired listener
        // above remains the sole owner of `/stream` and requires a session.
        guard settings.allowLegacyUnauthenticatedStream else {
            let lifecycle = await legacyStreamServer.lifecycleState()
            if lifecycle != .disabled {
                audioMonitor.detachLegacyStream()
                await legacyStreamServer.stop()
            } else {
                audioMonitor.detachLegacyStream()
            }
            appliedLegacyStreamConfiguration = nil
            failedLegacyStreamConfiguration = nil
            legacyStreamState = .disabled
            legacyStreamEndpoint = nil
            legacyStreamError = nil
            return
        }

        var lifecycle = await legacyStreamServer.lifecycleState()
        if case .running = lifecycle,
            appliedLegacyStreamConfiguration != configuration
        {
            audioMonitor.detachLegacyStream()
            await legacyStreamServer.stop()
            lifecycle = .disabled
            appliedLegacyStreamConfiguration = nil
        }

        if case .failed = lifecycle {
            guard failedLegacyStreamConfiguration != configuration else {
                legacyStreamState = lifecycle
                legacyStreamEndpoint = nil
                return
            }
            await legacyStreamServer.stop()
            lifecycle = .disabled
        }

        guard
            lifecycle == .disabled,
            isActive,
            lifecycleGeneration == generation,
            !Task.isCancelled
        else {
            legacyStreamState = lifecycle
            legacyStreamEndpoint =
                await legacyStreamServer.boundEndpoint()
            return
        }

        do {
            try await legacyStreamServer.updateConfiguration(
                configuration
            )
            try await legacyStreamServer.start()
            guard
                isActive,
                lifecycleGeneration == generation,
                !Task.isCancelled,
                audioMonitor.isStreamingEnabled,
                desiredLegacyStreamConfiguration() == configuration
            else {
                await legacyStreamServer.stop()
                return
            }
            let endpoint = await legacyStreamServer.boundEndpoint()
            if let endpoint {
                audioMonitor.attachLegacyStream(
                    audioFanout: remoteAudioFanout,
                    baseURL: Self.remoteBaseURL(for: endpoint)
                )
            }
            await remoteAudioFanout.setLegacySampleRate(
                UInt32(
                    max(
                        1,
                        audioMonitor.captureSampleRate.rounded()
                    )
                )
            )
            appliedLegacyStreamConfiguration = configuration
            failedLegacyStreamConfiguration = nil
            legacyStreamState =
                await legacyStreamServer.lifecycleState()
            legacyStreamEndpoint = endpoint
            legacyStreamError = nil
        } catch {
            audioMonitor.detachLegacyStream()
            appliedLegacyStreamConfiguration = nil
            failedLegacyStreamConfiguration = configuration
            legacyStreamState =
                await legacyStreamServer.lifecycleState()
            legacyStreamEndpoint = nil
            legacyStreamError = String(describing: error)
            nativeCommandError =
                "The legacy Radio listener could not bind to port \(configuration.port)."
            audioMonitor.stopStreaming()
        }
    }

    private func refreshRemoteStatus(generation: UInt64) async {
        let state = await remoteServer.lifecycleState()
        let endpoint = await remoteServer.boundEndpoint()
        let code: RemotePairingCode?
        let counts: RemoteListenerCounts
        if case .running = state {
            code = await remoteServer.currentPairingCode()
            counts = await remoteServer.listenerCounts()
        } else {
            code = nil
            counts = RemoteListenerCounts(
                eventStreams: 0,
                audioStreams:
                    await remoteAudioFanout.listenerCount(
                        kind: .legacyFloat32
                    )
            )
        }
        let browserAudioListeners =
            await remoteAudioFanout.listenerCount(kind: .pcm16Browser)
        guard
            isActive,
            lifecycleGeneration == generation,
            !Task.isCancelled
        else { return }

        remoteAccessState = state
        remoteEndpoint = endpoint
        pairingCode = code
        listenerCounts = counts
        if case .running = state {
            audioMonitor.setRemoteSpectrumSubscribersVisible(
                listenerCounts.eventStreams > 0
            )
            audioMonitor.setRemoteAudioSubscribersVisible(
                browserAudioListeners > 0
            )
        } else {
            audioMonitor.setRemoteSpectrumSubscribersVisible(false)
            audioMonitor.setRemoteAudioSubscribersVisible(false)
        }
        if case .failed(let message) = state,
            remoteAccessError == nil
        {
            remoteAccessError = message
        }
    }

    private var shouldRunRemoteAccess: Bool {
        #if DEBUG
            if remoteDependencies.usesAcceptanceEnvironment,
                RemoteAcceptanceEnvironment().isEnabled
            {
                return true
            }
        #endif
        return settings.remoteAccessEnabled
    }

    private func desiredRemoteConfiguration() -> RemoteAccessConfiguration {
        RemoteAccessConfiguration(
            bindHost: remoteDependencies.bindHost,
            port: settings.remoteAccessPort,
            serviceName: "PhonoFlow",
            allowedHosts: [],
            legacyAllowedSources: Set(settings.allowedHosts),
            allowUnauthenticatedLegacyStream:
                settings.allowLegacyUnauthenticatedStream
                && settings.remoteAccessPort == settings.radioPort,
            advertiseBonjour: true
        )
    }

    private func desiredLegacyStreamConfiguration()
        -> LegacyStreamConfiguration
    {
        LegacyStreamConfiguration(
            bindHost: remoteDependencies.legacyBindHost,
            port: settings.radioPort,
            allowedSources: Set(settings.allowedHosts)
        )
    }

    // MARK: - Snapshot conversion

    private func commitAuthoritativeState() -> RemoteStateSnapshot {
        var snapshot = makeSnapshot()
        let fingerprint = makeFingerprint(from: snapshot)
        if let lastFingerprint, lastFingerprint != fingerprint {
            revision &+= 1
        }
        lastFingerprint = fingerprint
        snapshot.revision = revision
        snapshot.generatedAt = Date()
        return snapshot
    }

    private func makeSnapshot() -> RemoteStateSnapshot {
        RemoteStateSnapshot(
            revision: revision,
            engine: makeEngineState(),
            devices: makeRemoteDevices(),
            selection: makeRemoteSelection(),
            meters: latestMeters,
            processing: RemoteProcessingState(
                gain: configuredGain,
                autoGainEnabled: configuredAutoGain,
                enabled: processingEnabled
            ),
            equalizer: RemoteEqualizerState(
                enabled: equalizerEnabled,
                bands: zip(coordinatorEQFrequencies, configuredEQBands).map {
                    RemoteEqualizerBand(
                        frequencyHz: $0.0,
                        gainDB: $0.1
                    )
                }
            ),
            monitor: RemoteToggleState(
                enabled: audioMonitor.isPassthroughEnabled
            ),
            radio: RemoteRadioState(
                enabled: audioMonitor.isStreamingEnabled,
                listenerCount: listenerCounts.audioStreams
            ),
            recording: RemoteRecordingState(
                enabled: audioMonitor.isRecording,
                durationSeconds: audioMonitor.recordingDuration,
                fileName: audioMonitor.recordingURL?.lastPathComponent
            ),
            diagnostics: RemoteDiagnosticsSnapshot(
                callbackDurationMicroseconds:
                    audioMonitor.maximumCallbackDurationMicroseconds,
                xruns: audioMonitor.callbackOverflowCount,
                ringOverflows: audioMonitor.callbackOverflowCount,
                ringUnderflows: audioMonitor.playbackUnderrunCount,
                queueDepth: audioMonitor.analysisQueueDepth
                    + audioMonitor.fanoutQueueDepth,
                queueDrops: audioMonitor.analysisDroppedFrameCount
                    + audioMonitor.fanoutDroppedFrameCount,
                renderSkips: audioMonitor.spectrogramRenderSkipCount,
                imageAgeMilliseconds:
                    audioMonitor.spectrogramImageAgeMilliseconds
            )
        )
    }

    private func makeFingerprint(
        from snapshot: RemoteStateSnapshot
    ) -> CoordinatorStateFingerprint {
        CoordinatorStateFingerprint(
            engine: snapshot.engine,
            devices: snapshot.devices,
            selection: snapshot.selection,
            processing: snapshot.processing,
            equalizer: snapshot.equalizer,
            monitor: snapshot.monitor,
            radio: snapshot.radio,
            recordingEnabled: snapshot.recording.enabled,
            recordingElapsedSecond: snapshot.recording.enabled
                ? Int(snapshot.recording.durationSeconds.rounded(.down))
                : 0,
            recordingFileName: snapshot.recording.fileName,
            diagnostics: RemoteDiagnosticsSnapshot(
                xruns: snapshot.diagnostics.xruns,
                ringOverflows: snapshot.diagnostics.ringOverflows,
                ringUnderflows: snapshot.diagnostics.ringUnderflows,
                queueDrops: snapshot.diagnostics.queueDrops,
                renderSkips: snapshot.diagnostics.renderSkips
            )
        )
    }

    private func makeEngineState() -> RemoteEngineState {
        if let selectedInput = audioManager.selectedInputDevice,
            !selectedInput.isAlive
        {
            return RemoteEngineState(
                phase: .disconnected,
                problem: RemoteProblemSummary(
                    code: "input_disconnected",
                    title: "Input disconnected",
                    detail: "\(selectedInput.name) is not connected."
                )
            )
        }
        if audioManager.savedInputUID != nil,
            audioManager.selectedInputDevice == nil
        {
            return RemoteEngineState(
                phase: .disconnected,
                problem: RemoteProblemSummary(
                    code: "input_disconnected",
                    title: "Input disconnected",
                    detail: "\(audioManager.savedInputName ?? "The selected input") is not connected."
                )
            )
        }

        switch audioMonitor.engineStatus {
        case .idle:
            return RemoteEngineState(phase: .idle)
        case .starting:
            return RemoteEngineState(phase: .starting)
        case .running(let format):
            return RemoteEngineState(
                phase: .running,
                format: RemoteAudioFormat(
                    sampleRate: format.sampleRate,
                    channelCount: format.channelCount,
                    bufferFrameCount: Int(format.bufferFrames)
                )
            )
        case .disconnected:
            return RemoteEngineState(
                phase: .disconnected,
                problem: RemoteProblemSummary(
                    code: "input_disconnected",
                    title: "Input disconnected",
                    detail: "The selected input is not connected."
                )
            )
        case .failed(let error):
            return RemoteEngineState(
                phase: .failed,
                problem: RemoteProblemSummary(
                    code: "coreaudio_failure",
                    title: error.operation,
                    detail: error.localizedDescription
                )
            )
        }
    }

    private func makeRemoteDevices() -> [RemoteAudioDevice] {
        let inputByUID = Dictionary(
            uniqueKeysWithValues: audioManager.inputDevices.map { ($0.uid, $0) }
        )
        let outputByUID = Dictionary(
            uniqueKeysWithValues: audioManager.outputDevices.map { ($0.uid, $0) }
        )
        var uids = Set(inputByUID.keys)
        uids.formUnion(outputByUID.keys)

        var devices = uids.compactMap { uid -> RemoteAudioDevice? in
            let input = inputByUID[uid]
            let output = outputByUID[uid]
            guard let base = input ?? output else { return nil }
            let rates = Self.supportedRates(
                for: [input, output].compactMap { $0 }
            )
            return RemoteAudioDevice(
                uid: uid,
                name: base.name,
                inputChannelCount: input?.inputChannelCount ?? 0,
                outputChannelCount: output?.outputChannelCount ?? 0,
                inputRoutes: (input?.inputRoutes ?? []).map {
                    RemoteInputRoute(
                        id: $0.id,
                        label: $0.name,
                        channels: $0.channelMap.map(Int.init)
                    )
                },
                supportedSampleRates: rates,
                transport: Self.remoteTransport(base.transport),
                connectionState: (input?.isAlive == true || output?.isAlive == true)
                    ? .connected
                    : .disconnected
            )
        }

        if let savedUID = audioManager.savedInputUID,
            !uids.contains(savedUID)
        {
            let savedRouteID = audioManager.savedInputRouteID(
                forDeviceUID: savedUID
            )
            devices.append(
                RemoteAudioDevice(
                    uid: savedUID,
                    name: audioManager.savedInputName ?? "Saved input",
                    inputChannelCount: 0,
                    outputChannelCount: 0,
                    inputRoutes: savedRouteID.map {
                        [
                            RemoteInputRoute(
                                id: $0,
                                label: "Saved input route",
                                channels: []
                            )
                        ]
                    } ?? [],
                    supportedSampleRates: [],
                    transport: .unknown,
                    connectionState: .disconnected
                )
            )
            uids.insert(savedUID)
        }
        if let savedUID = audioManager.savedOutputUID,
            !uids.contains(savedUID)
        {
            devices.append(
                RemoteAudioDevice(
                    uid: savedUID,
                    name: audioManager.savedOutputName ?? "Saved output",
                    inputChannelCount: 0,
                    outputChannelCount: 0,
                    inputRoutes: [],
                    supportedSampleRates: [],
                    transport: .unknown,
                    connectionState: .disconnected
                )
            )
        }

        return devices.sorted {
            if $0.name == $1.name { return $0.uid < $1.uid }
            return $0.name.localizedStandardCompare($1.name)
                == .orderedAscending
        }
    }

    private func makeRemoteSelection() -> RemoteAudioSelection? {
        if let selection = Self.selection(from: audioManager) {
            return RemoteAudioSelection(
                inputUID: selection.inputUID,
                inputRouteID: selection.inputRouteID,
                outputUID: selection.outputUID
            )
        }
        guard let inputUID = audioManager.savedInputUID,
            let routeID = audioManager.savedInputRouteID(
                forDeviceUID: inputUID
            )
        else {
            return nil
        }
        return RemoteAudioSelection(
            inputUID: inputUID,
            inputRouteID: routeID,
            outputUID: audioManager.savedOutputUID
        )
    }

    private func makeMeterSnapshot(
        advancingSequence: Bool
    ) -> RemoteMeterSnapshot {
        if advancingSequence {
            meterSequence &+= 1
        }
        return RemoteMeterSnapshot(
            left: Self.clampedMeter(audioMonitor.leftLevel),
            right: Self.clampedMeter(audioMonitor.rightLevel),
            peak: Self.clampedMeter(audioMonitor.peakLevel),
            sequence: meterSequence,
            timestamp: Date()
        )
    }

    private static func selection(
        from manager: AudioDeviceManager
    ) -> CoordinatorAudioSelection? {
        guard let input = manager.selectedInputDevice,
            let route = manager.selectedInputRoute
        else {
            return nil
        }
        return CoordinatorAudioSelection(
            inputUID: input.uid,
            inputName: input.name,
            inputRouteID: route.id,
            outputUID: manager.selectedOutputDevice?.uid
                ?? manager.savedOutputUID,
            outputName: manager.selectedOutputDevice?.name
                ?? manager.savedOutputName
        )
    }

    private static func binding(
        from manager: AudioDeviceManager
    ) -> CoordinatorAudioBinding? {
        guard let input = manager.selectedInputDevice else { return nil }
        return binding(
            input: input,
            output: manager.selectedOutputDevice,
            manager: manager
        )
    }

    private static func binding(
        input: AudioDevice,
        output: AudioDevice?,
        manager: AudioDeviceManager
    ) -> CoordinatorAudioBinding {
        return CoordinatorAudioBinding(
            inputDeviceID: input.id,
            inputAlive: input.isAlive,
            inputGeneration: manager.inputGeneration(
                forDeviceUID: input.uid
            ),
            outputDeviceID: output?.id,
            outputAlive: output?.isAlive ?? false,
            outputGeneration: output.map {
                manager.outputGeneration(forDeviceUID: $0.uid)
            }
        )
    }

    private static func normalizedEQBands(_ bands: [Float]) -> [Float] {
        var normalized = Array(
            bands.prefix(coordinatorEQFrequencies.count)
        ).map { value in
            value.isFinite ? min(max(value, -12), 12) : 0
        }
        if normalized.count < coordinatorEQFrequencies.count {
            normalized.append(
                contentsOf: repeatElement(
                    0,
                    count: coordinatorEQFrequencies.count - normalized.count
                )
            )
        }
        return normalized
    }

    private static func supportedRates(
        for devices: [AudioDevice]
    ) -> [Double] {
        var rates = Set<Double>()
        for device in devices {
            if device.nominalSampleRate > 0 {
                rates.insert(device.nominalSampleRate)
            }
            for range in device.availableSampleRates {
                if range.minimum > 0 { rates.insert(range.minimum) }
                if range.maximum > 0 { rates.insert(range.maximum) }
            }
        }
        return rates.sorted()
    }

    private static func remoteTransport(
        _ transport: AudioDeviceTransport
    ) -> RemoteDeviceTransport {
        switch transport {
        case .builtIn:
            return .builtIn
        case .usb:
            return .usb
        case .bluetooth:
            return .bluetooth
        case .aggregate:
            return .aggregate
        case .virtual:
            return .virtual
        case .hdmi, .displayPort, .other:
            return .unknown
        }
    }

    private static func clampedMeter(_ value: Float) -> Float {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }

    private static func remoteAccessNotRunningFailure() -> RemoteControlFailure {
        RemoteControlFailure(
            kind: .unavailable,
            code: "remote_access_not_running",
            detail: "Enable Remote Access before creating a pairing code."
        )
    }

    private static func remoteBaseURL(
        for endpoint: RemoteBoundEndpoint
    ) -> String {
        let host = advertisedHost(for: endpoint.host)
        let authority = host.contains(":") ? "[\(host)]" : host
        return "http://\(authority):\(endpoint.port)"
    }

    private static func advertisedHost(for boundHost: String) -> String {
        guard boundHost == "0.0.0.0" || boundHost == "::" else {
            return boundHost
        }
        let addresses = RemoteLocalInterfaces.currentAddresses().sorted()
        return addresses.first(where: { $0.contains(".") })
            ?? addresses.first
            ?? "localhost"
    }
}
