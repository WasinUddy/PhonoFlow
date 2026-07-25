//
//  AudioMonitor.swift
//  PhonoFlow
//
//  High-fidelity stereo audio monitoring with real-time DSP:
//  - 10-band parametric EQ (biquad, Transposed Direct Form II)
//  - Soft limiter (tanh-based, transparent below threshold)
//  - Clock drift compensation (Catmull-Rom cubic resampling, same-device bypass)
//  - DC offset removal (first-order high-pass)
//  - Output sample rate matching (eliminates HAL resampling)
//

import Accelerate
import AudioToolbox
import CoreAudio
import Darwin
import Foundation
import PhonoFlowCore
import QuartzCore
import Synchronization
import os

// MARK: - Configuration

nonisolated private enum AudioConfig {
    static let eqBandCount = 10
    static let eqPublicationSlotCount = 3
    static let eqFrequencies: [Float] = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    static let eqQ: Float = 1.414  // sqrt(2), standard graphic EQ bandwidth
    static let softLimitThreshold: Float = 0.891  // -1 dBFS
    static let ringCapacity = 16_384
    static let workCapacity = 4096
    static let driftTarget = 1024  // ~23 ms at 44.1 kHz — tighter for lower latency
    static let driftThreshold = 128  // correct drift early and often
    static let targetBufferFrames: UInt32 = 256
}

nonisolated struct AudioRuntimeFormat: Equatable, Sendable {
    let sampleRate: Double
    let channelCount: Int
    let bufferFrames: UInt32
    let inputChannelMap: [Int32]

    var summary: String {
        let rate =
            sampleRate >= 1_000
            ? String(format: "%.1f kHz", sampleRate / 1_000)
            : String(format: "%.0f Hz", sampleRate)
        return "\(rate) · \(channelCount) ch · \(bufferFrames) frames"
    }
}

nonisolated struct AudioEngineFailure: Error, Equatable, Identifiable, Sendable {
    let id = UUID()
    let operation: String
    let status: OSStatus
    let deviceID: AudioDeviceID?
    let detail: String

    var localizedDescription: String {
        "\(operation): \(detail) (\(Self.statusString(status)))"
    }

    private static func statusString(_ status: OSStatus) -> String {
        let value = UInt32(bitPattern: status)
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff),
        ]
        if bytes.allSatisfy({ $0 >= 32 && $0 <= 126 }),
            let fourCC = String(bytes: bytes, encoding: .ascii)
        {
            return "'\(fourCC)'"
        }
        return "\(status)"
    }
}

nonisolated enum AudioEngineStatus: Equatable, Sendable {
    case idle
    case starting
    case running(AudioRuntimeFormat)
    case disconnected
    case failed(AudioEngineFailure)
}

// MARK: - Audio Monitor

@MainActor
@Observable
class AudioMonitor {
    var peakLevel: Float = 0
    var gain: Float = 1.0
    var isMonitoring = false
    var isPassthroughEnabled = false
    var isStreamingEnabled = false
    var streamURL: String = ""
    private(set) var engineStatus: AudioEngineStatus = .idle
    private(set) var lastError: AudioEngineFailure?
    private(set) var negotiatedBufferFrames: UInt32 = AudioConfig.targetBufferFrames
    private(set) var inputChannelMap: [Int32] = [0, 1]
    private(set) var callbackOverflowCount: UInt64 = 0
    private(set) var playbackOverflowCount: UInt64 = 0
    private(set) var playbackUnderrunCount: UInt64 = 0
    private(set) var callbackCount: UInt64 = 0
    private(set) var maximumCallbackDurationMicroseconds: Double = 0
    var isRecording = false
    var recordingDuration: Double = 0
    var recordingURL: URL?
    private(set) var lastRecordingFailure: AudioRecorder.TerminalFailure?
    var isAutoGainEnabled: Bool = false {
        didSet {
            guard oldValue != isAutoGainEnabled else { return }
            if isAutoGainEnabled {
                startAutoGain()
            } else {
                stopAutoGain()
            }
        }
    }

    // Visualization data
    var leftWaveform: [Float] = Array(repeating: 0, count: 200)
    var rightWaveform: [Float] = Array(repeating: 0, count: 200)
    var phasePoints: [(x: Float, y: Float)] = []
    var leftLevel: Float = 0
    var rightLevel: Float = 0
    var spectrogramImage: CGImage?
    var spectrogramEnabled: Bool = false {
        didSet { updateAnalysisDemand() }
    }

    // Pause visualizations when app is collapsed to save CPU/battery
    var visualizationsPaused: Bool = false {
        didSet { updateAnalysisDemand() }
    }

    private(set) var analysisDroppedFrameCount: UInt64 = 0
    private(set) var fanoutDroppedFrameCount: UInt64 = 0
    private(set) var analysisQueueDepth: Int = 0
    private(set) var fanoutQueueDepth: Int = 0
    private(set) var spectrogramRenderSkipCount: UInt64 = 0
    private(set) var spectrogramImageAgeMilliseconds: Double = 0

    // Keep a nonisolated copy for the audio thread to read during setup
    private var lastEqBands: [Float] = Array(repeating: 0, count: AudioConfig.eqBandCount)

    var eqBands: [Float] = Array(repeating: 0, count: AudioConfig.eqBandCount) {
        didSet {
            lastEqBands = eqBands
            sharedState.updateEQCoefficients(bands: eqBands, sampleRate: Float(captureSampleRate))
        }
    }

    private var inputUnit: AudioUnit?
    private var outputUnit: AudioUnit?
    private var inputUnitStarted = false
    private var outputUnitStarted = false
    private var outputUnitInitialized = false
    private var inputCallbackRefCon: UnsafeMutableRawPointer?
    private var outputCallbackRefCon: UnsafeMutableRawPointer?
    private var inputCallbackContext: AudioCallbackContext?
    private var outputCallbackContext: AudioCallbackContext?
    private var inputDeviceID: AudioDeviceID = 0
    private var outputDeviceID: AudioDeviceID?
    private var hasActiveOutputFailure = false

    private let audioUnitRuntime: any AudioUnitHALRuntime
    private let pipelineWorker: AudioPipelineWorker
    private let sharedState: SharedAudioState
    private let recorder: AudioRecorder
    private(set) var captureSampleRate: Double = 44100
    private var remoteSpectrumSubscribersVisible = false
    private var remoteAudioSubscribersVisible = false
    private var pipelineAudioFanout: RemoteAudioFanout?
    private var pipelineRemoteServer: RemoteAccessServer?
    private var pairedRemoteBaseURL: String?
    private var legacyListenerBaseURL: String?
    #if DEBUG
        private var fakeCaptureSource: FakeCaptureSource?
        private let acceptanceAudioBackendOverride: Bool?
        private var shouldUseAcceptanceAudioBackend: Bool {
            // A caller-injected HAL must remain authoritative even when the
            // surrounding process is an acceptance-test host. The environment
            // remains call-time configuration because acceptance tests may
            // scope it around a single operation after creating the monitor.
            audioUnitRuntime === SystemAudioUnitHALRuntime.shared
                && (acceptanceAudioBackendOverride
                    ?? FakeCaptureSource.isRequestedByEnvironment)
        }
    #endif

    var isMeteringEnabled: Bool = false {
        didSet {
            sharedState.setMeteringEnabled(isMeteringEnabled)
        }
    }

    init(
        audioUnitRuntime: any AudioUnitHALRuntime =
            SystemAudioUnitHALRuntime.shared,
        acceptanceAudioBackendOverride: Bool? = nil,
        recorder: AudioRecorder = AudioRecorder()
    ) {
        let worker = AudioPipelineWorker()
        self.audioUnitRuntime = audioUnitRuntime
        self.recorder = recorder
        #if DEBUG
            self.acceptanceAudioBackendOverride =
                acceptanceAudioBackendOverride
        #endif
        pipelineWorker = worker
        sharedState = SharedAudioState(
            pipelineWorker: worker,
            audioUnitRuntime: audioUnitRuntime
        )
        worker.setNativePublisher { [weak self] frame in
            self?.spectrogramImage = frame.image
            let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            let age =
                now >= frame.column.timestampNanoseconds
                ? now - frame.column.timestampNanoseconds
                : 0
            self?.spectrogramImageAgeMilliseconds =
                Double(age) / 1_000_000
        }
    }

    isolated deinit {
        uiUpdateTimer?.setEventHandler {}
        uiUpdateTimer?.cancel()
        autoGainTimer?.invalidate()

        sharedState.setPlaybackEnabled(false)
        sharedState.setVolume(0)
        inputCallbackContext?.deactivateAndWait()
        outputCallbackContext?.deactivateAndWait()

        if let inputUnit {
            if inputUnitStarted {
                _ = audioUnitRuntime.stop(inputUnit)
            }
            if audioUnitRuntime.dispose(inputUnit) == noErr {
                releaseInputCallbackRefCon()
            } else {
                // Core Audio may still hold the tiny callback context. Detach
                // the full pipeline so a teardown failure cannot leak it.
                inputCallbackContext?.detachState()
            }
        }
        if let outputUnit {
            if outputUnitStarted {
                _ = audioUnitRuntime.stop(outputUnit)
            }
            if audioUnitRuntime.dispose(outputUnit) == noErr {
                releaseOutputCallbackRefCon()
            } else {
                outputCallbackContext?.detachState()
            }
        }
        pipelineWorker.stopAndDrain()
    }

    func startMonitoring(
        deviceID: AudioDeviceID,
        outputDeviceID: AudioDeviceID?,
        inputChannelMap: [Int32] = [0, 1]
    ) {
        stopMonitoring()
        guard inputUnit == nil, self.outputUnit == nil else {
            if lastError == nil {
                recordFailure(
                    operation: "Restart audio",
                    status: kAudio_ParamError,
                    deviceID: deviceID,
                    detail: "A previous AudioUnit is still awaiting Core Audio cleanup."
                )
            }
            return
        }

        engineStatus = .starting
        lastError = nil
        hasActiveOutputFailure = false
        inputDeviceID = deviceID
        self.outputDeviceID = outputDeviceID
        self.inputChannelMap = Self.normalizedChannelMap(inputChannelMap)

        #if DEBUG
            if shouldUseAcceptanceAudioBackend {
                startFakeMonitoring()
                return
            }
        #endif

        guard
            setupInputUnit(
                deviceID: deviceID,
                channelMap: self.inputChannelMap
            )
        else {
            return
        }

        sharedState.sameDevice = outputDeviceID == deviceID
        sharedState.setGain(gain)
        // Input gain is applied exactly once in the capture callback. Local
        // monitor output remains unity unless monitoring is disabled.
        sharedState.setVolume(1)
        sharedState.setMeteringEnabled(isMeteringEnabled)
        pipelineWorker.configure(sampleRate: captureSampleRate)

        guard let inputUnit else {
            recordFailure(
                operation: "Start input",
                status: kAudio_ParamError,
                deviceID: deviceID,
                detail: "The input AudioUnit was not created."
            )
            disposeAudioUnits()
            return
        }
        // Treat a failed start conservatively: Core Audio may have partially
        // activated the unit, so teardown must still issue a stop.
        inputUnitStarted = true
        let startStatus = audioUnitRuntime.start(inputUnit)
        guard
            requireNoErr(
                startStatus,
                operation: "Start input",
                deviceID: deviceID
            )
        else {
            disposeAudioUnits()
            return
        }
        isMonitoring = true
        engineStatus = .running(
            AudioRuntimeFormat(
                sampleRate: captureSampleRate,
                channelCount: 2,
                bufferFrames: negotiatedBufferFrames,
                inputChannelMap: self.inputChannelMap
            )
        )

        // Always start UI update timer for visualizations and metering
        startUIUpdateTimer()
    }

    func stopMonitoring() {
        stopUIUpdateTimer()
        isPassthroughEnabled = false
        sharedState.setPlaybackEnabled(false)
        stopStreaming()
        #if DEBUG
            fakeCaptureSource?.stop()
            fakeCaptureSource = nil
        #endif

        _ = disposeInputUnit()

        // Capture is stopped before the worker is drained, guaranteeing that
        // a recording can be finalized without a producer racing its boundary.
        stopRecording()
        pipelineWorker.stopAndDrain()

        _ = disposeOutputUnit()

        isMonitoring = false
        peakLevel = 0
        if inputUnit == nil, outputUnit == nil {
            sharedState.reset()
        }
        if case .failed = engineStatus {
            // Preserve the actionable failure after teardown.
        } else {
            engineStatus = .idle
        }
    }

    #if DEBUG
        private func startFakeMonitoring() {
            captureSampleRate = 48_000
            negotiatedBufferFrames = 256
            sharedState.sameDevice = true
            sharedState.setGain(gain)
            sharedState.setVolume(1)
            sharedState.setMeteringEnabled(isMeteringEnabled)
            pipelineWorker.configure(sampleRate: captureSampleRate)

            let source = FakeCaptureSource(
                sharedState: sharedState,
                sampleRate: captureSampleRate,
                frameCount: Int(negotiatedBufferFrames)
            )
            fakeCaptureSource = source
            source.start()

            isMonitoring = true
            engineStatus = .running(
                AudioRuntimeFormat(
                    sampleRate: captureSampleRate,
                    channelCount: 2,
                    bufferFrames: negotiatedBufferFrames,
                    inputChannelMap: inputChannelMap
                )
            )
            startUIUpdateTimer()
        }
    #endif

    // MARK: - Passthrough

    func enablePassthrough() {
        guard isMonitoring, let outputDeviceID else {
            recordOutputFailure(
                operation: "Enable monitor",
                status: kAudio_ParamError,
                deviceID: outputDeviceID,
                detail: "Select an output device before enabling monitoring."
            )
            return
        }
        #if DEBUG
            if shouldUseAcceptanceAudioBackend {
                sharedState.resetPlayback()
                // The acceptance backend has no output callback consumer.
                sharedState.setPlaybackEnabled(false)
                sharedState.setVolume(1)
                isPassthroughEnabled = true
                recoverFromOutputFailureIfNeeded()
                return
            }
        #endif
        if outputUnit != nil, !outputUnitInitialized {
            guard disposeOutputUnit() else { return }
        }
        if outputUnit == nil, !setupOutputUnit(deviceID: outputDeviceID) {
            return
        }
        guard let outputUnit else { return }
        outputCallbackContext?.deactivateAndWait()
        sharedState.resetPlayback()
        sharedState.setPlaybackEnabled(true)
        sharedState.setVolume(1)
        outputCallbackContext?.activate()
        if outputUnitStarted {
            // A previous stop returned an error, so conservatively treat the
            // unit as still running instead of starting it a second time.
            isPassthroughEnabled = true
            recoverFromOutputFailureIfNeeded()
            return
        }
        outputUnitStarted = true
        let status = audioUnitRuntime.start(outputUnit)
        guard
            requireOutputNoErr(
                status,
                operation: "Start output",
                deviceID: outputDeviceID
            )
        else {
            sharedState.setPlaybackEnabled(false)
            sharedState.setVolume(0)
            outputCallbackContext?.deactivateAndWait()
            _ = disposeOutputUnit()
            if self.outputUnit == nil {
                sharedState.resetPlayback()
            }
            return
        }
        isPassthroughEnabled = true
        recoverFromOutputFailureIfNeeded()
    }

    func disablePassthrough() {
        #if DEBUG
            if shouldUseAcceptanceAudioBackend {
                isPassthroughEnabled = false
                sharedState.setPlaybackEnabled(false)
                sharedState.setVolume(0)
                sharedState.resetPlayback()
                return
            }
        #endif
        guard let outputUnit else {
            sharedState.setPlaybackEnabled(false)
            sharedState.setVolume(0)
            sharedState.resetPlayback()
            return
        }
        isPassthroughEnabled = false
        sharedState.setPlaybackEnabled(false)
        sharedState.setVolume(0)
        outputCallbackContext?.deactivateAndWait()
        guard outputUnitStarted else {
            sharedState.resetPlayback()
            return
        }
        let status = audioUnitRuntime.stop(outputUnit)
        guard status == noErr else {
            // Keep ownership and the conservative "started" state. The gate
            // makes any callback that Core Audio continues to issue return
            // silence without touching the playback ring.
            recordOutputFailure(
                operation: "Stop output",
                status: status,
                deviceID: outputDeviceID,
                detail: "Core Audio could not stop output monitoring."
            )
            return
        }
        outputUnitStarted = false
        sharedState.resetPlayback()
    }

    func updatePassthroughOutput(deviceID: AudioDeviceID) {
        let shouldRestart = isMonitoring && isPassthroughEnabled
        let previousDeviceID = outputDeviceID

        if outputUnit != nil {
            isPassthroughEnabled = false
            sharedState.setPlaybackEnabled(false)
            sharedState.setVolume(0)
            guard disposeOutputUnit() else {
                outputDeviceID = previousDeviceID
                return
            }
            sharedState.resetPlayback()
        }

        outputDeviceID = deviceID
        guard shouldRestart else { return }
        enablePassthrough()
    }

    func clearPassthroughOutput() {
        disablePassthrough()
        if outputUnit != nil {
            guard disposeOutputUnit() else { return }
            sharedState.resetPlayback()
        }
        outputDeviceID = nil
    }

    func updatePassthroughVolume() {
        sharedState.setVolume(isPassthroughEnabled ? 1 : 0)
        sharedState.setGain(gain)
    }

    // MARK: - Streaming

    func startStreaming(port: UInt16 = 7865, allowedHosts: [String] = []) {
        guard !isStreamingEnabled else { return }
        _ = allowedHosts  // Source policy is enforced by LegacyStreamServer.
        pipelineWorker.setLegacyStreamingEnabled(true)
        isStreamingEnabled = true
        updateStreamURL(fallbackPort: port)
    }

    func stopStreaming() {
        pipelineWorker.setLegacyStreamingEnabled(false)
        isStreamingEnabled = false
        streamURL = ""
    }

    /// Connects the capture worker to the paired-LAN server. The fanout is
    /// injected separately because the server and monitor intentionally share
    /// one bounded source of browser and legacy audio chunks.
    func attachRemoteAccess(
        audioFanout: RemoteAudioFanout,
        server: RemoteAccessServer,
        baseURL: String? = nil
    ) {
        pipelineAudioFanout = audioFanout
        pipelineRemoteServer = server
        pairedRemoteBaseURL = baseURL
        refreshRemotePipelineAttachment()
        // Default to ready-to-listen until the coordinator starts publishing
        // exact subscription visibility; this prevents the first browser
        // connection from waiting for a later state reconciliation.
        remoteAudioSubscribersVisible = true
        pipelineWorker.setRemoteAudioSubscribersVisible(true)
    }

    func detachRemoteAccess() {
        remoteSpectrumSubscribersVisible = false
        remoteAudioSubscribersVisible = false
        pairedRemoteBaseURL = nil
        pipelineRemoteServer = nil
        pipelineWorker.setRemoteSpectrumSubscribersVisible(false)
        pipelineWorker.setRemoteAudioSubscribersVisible(false)
        refreshRemotePipelineAttachment()
        if isStreamingEnabled {
            updateStreamURL()
        }
    }

    /// Connects the dedicated compatibility listener to the same bounded
    /// fanout used by paired browser audio. No WebUI or API service is implied.
    func attachLegacyStream(
        audioFanout: RemoteAudioFanout,
        baseURL: String
    ) {
        pipelineAudioFanout = audioFanout
        legacyListenerBaseURL = baseURL
        refreshRemotePipelineAttachment()
        if isStreamingEnabled {
            updateStreamURL()
        }
    }

    /// Detaches only the dedicated listener. A concurrently running paired
    /// server keeps its browser audio and authenticated `/stream` route.
    func detachLegacyStream() {
        legacyListenerBaseURL = nil
        refreshRemotePipelineAttachment()
        if isStreamingEnabled {
            updateStreamURL()
        }
    }

    private func refreshRemotePipelineAttachment() {
        let shouldKeepAudioFanout =
            pipelineRemoteServer != nil || legacyListenerBaseURL != nil
        if !shouldKeepAudioFanout {
            pipelineAudioFanout = nil
        }
        pipelineWorker.attach(
            remoteAudio: shouldKeepAudioFanout ? pipelineAudioFanout : nil,
            remoteServer: pipelineRemoteServer
        )
    }

    private func updateStreamURL(fallbackPort: UInt16 = 7865) {
        let localHost =
            RemoteLocalInterfaces.currentAddresses().sorted().first
            ?? "localhost"
        let localAuthority =
            localHost.contains(":") ? "[\(localHost)]" : localHost
        let baseURL =
            legacyListenerBaseURL
            ?? pairedRemoteBaseURL
            ?? "http://\(localAuthority):\(fallbackPort)"
        streamURL =
            "\(baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/stream"
    }

    /// AppCoordinator updates this from the authoritative remote visibility
    /// state. Analysis remains fully suspended when both this and the native
    /// advanced visualization are false.
    func setRemoteSpectrumSubscribersVisible(_ visible: Bool) {
        remoteSpectrumSubscribersVisible = visible
        pipelineWorker.setRemoteSpectrumSubscribersVisible(visible)
    }

    func setRemoteAudioSubscribersVisible(_ visible: Bool) {
        remoteAudioSubscribersVisible = visible
        pipelineWorker.setRemoteAudioSubscribersVisible(visible)
    }

    #if DEBUG
        var testingCallbackGain: Float {
            sharedState.getParams().gain
        }

        var testingAutoGainPeak: Float {
            sharedState.getAutoGainPeakLevel()
        }

        var testingEQIsActive: Bool {
            sharedState.isEQActive
        }

        var testingAutoGainTimerIdentity: ObjectIdentifier? {
            autoGainTimer.map(ObjectIdentifier.init)
        }

        func testingAdjustAutoGain() {
            adjustAutoGain()
        }
    #endif

    // MARK: - Recording

    func startRecording() {
        guard !isRecording else { return }
        do {
            let url = try recorder.start(sampleRate: captureSampleRate)
            recordingURL = url
            lastRecordingFailure = nil
            isRecording = true
            recordingDuration = 0
            pipelineWorker.setRecorder(recorder)
            os_log(.info, "PhonoFlow: Recording started → %{public}@", url.path)
        } catch {
            isRecording = false
            recordingURL = nil
            if case .initializationFailed(let failure) =
                error as? AudioRecorder.RecorderError
            {
                lastRecordingFailure = failure
            } else {
                lastRecordingFailure = nil
            }
            os_log(.error, "PhonoFlow: Recording failed — %{public}@", error.localizedDescription)
        }
    }

    @discardableResult
    func stopRecording() -> AudioRecorder.TerminalResult? {
        guard isRecording else { return nil }
        pipelineWorker.setRecorder(nil)
        let result = recorder.stop()
        isRecording = false
        switch result {
        case .success(let recording):
            recordingURL = recording.url
            lastRecordingFailure = nil
        case .failure(let failure):
            recordingURL = nil
            lastRecordingFailure = failure
            os_log(
                .error,
                "PhonoFlow: Recording finalization failed — %{public}@",
                failure.localizedDescription
            )
        case nil:
            recordingURL = nil
        }
        return result
    }

    // MARK: - Audio Unit Setup

    static func normalizedChannelMap(_ map: [Int32]) -> [Int32] {
        switch map.count {
        case 0: return [0, 0]
        case 1: return [max(map[0], 0), max(map[0], 0)]
        default: return [max(map[0], 0), max(map[1], 0)]
        }
    }

    private func setupInputUnit(
        deviceID: AudioDeviceID,
        channelMap: [Int32]
    ) -> Bool {
        let desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        guard let component = audioUnitRuntime.findComponent(matching: desc) else {
            recordFailure(
                operation: "Find AUHAL input component",
                status: kAudio_ParamError,
                deviceID: deviceID,
                detail: "Core Audio did not provide a HAL output component."
            )
            return false
        }

        var unit: AudioUnit?
        let createStatus = audioUnitRuntime.instantiate(component, unit: &unit)
        guard
            requireNoErr(
                createStatus,
                operation: "Create input AudioUnit",
                deviceID: deviceID
            ), let unit
        else {
            return false
        }
        inputUnit = unit

        func fail(
            _ status: OSStatus,
            operation: String,
            detail: String = ""
        ) -> Bool {
            recordFailure(
                operation: operation,
                status: status,
                deviceID: deviceID,
                detail: detail.isEmpty ? "Core Audio rejected the input configuration." : detail
            )
            _ = disposeInputUnit()
            return false
        }

        var enableIO: UInt32 = 1
        var status = audioUnitRuntime.setProperty(
            unit,
            id: kAudioOutputUnitProperty_EnableIO,
            scope: kAudioUnitScope_Input,
            element: 1,
            data: &enableIO,
            byteCount: UInt32(MemoryLayout<UInt32>.size)
        )
        guard status == noErr else {
            return fail(status, operation: "Enable input I/O")
        }

        enableIO = 0
        status = audioUnitRuntime.setProperty(
            unit,
            id: kAudioOutputUnitProperty_EnableIO,
            scope: kAudioUnitScope_Output,
            element: 0,
            data: &enableIO,
            byteCount: UInt32(MemoryLayout<UInt32>.size)
        )
        guard status == noErr else {
            return fail(status, operation: "Disable input-unit output I/O")
        }

        var deviceIDVar = deviceID
        status = audioUnitRuntime.setProperty(
            unit,
            id: kAudioOutputUnitProperty_CurrentDevice,
            scope: kAudioUnitScope_Global,
            element: 0,
            data: &deviceIDVar,
            byteCount: UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            return fail(status, operation: "Select input device")
        }

        switch negotiateDeviceBufferSize(deviceID) {
        case .success(let bufferFrames):
            negotiatedBufferFrames = bufferFrames
        case .failure(let failure):
            return fail(
                failure.status,
                operation: failure.operation,
                detail: failure.detail
            )
        }

        var deviceFormat = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = audioUnitRuntime.getProperty(
            unit,
            id: kAudioUnitProperty_StreamFormat,
            scope: kAudioUnitScope_Input,
            element: 1,
            data: &deviceFormat,
            byteCount: &size
        )
        guard status == noErr, deviceFormat.mSampleRate > 0 else {
            return fail(
                status == noErr ? kAudio_ParamError : status,
                operation: "Read input device format"
            )
        }

        let hardwareChannelCount = Int(deviceFormat.mChannelsPerFrame)
        guard
            channelMap.allSatisfy({
                $0 >= 0 && Int($0) < hardwareChannelCount
            })
        else {
            return fail(
                kAudio_ParamError,
                operation: "Select input channels",
                detail: "The selected channel pair is unavailable on this \(hardwareChannelCount)-channel device."
            )
        }

        captureSampleRate = deviceFormat.mSampleRate
        var clientFormat = AudioStreamBasicDescription(
            mSampleRate: captureSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat
                | kAudioFormatFlagIsPacked
                | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: UInt32(MemoryLayout<Float>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(MemoryLayout<Float>.size),
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        status = audioUnitRuntime.setProperty(
            unit,
            id: kAudioUnitProperty_StreamFormat,
            scope: kAudioUnitScope_Output,
            element: 1,
            data: &clientFormat,
            byteCount: UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        )
        guard status == noErr else {
            return fail(status, operation: "Set two-channel input client format")
        }

        var map = Self.normalizedChannelMap(channelMap)
        status = map.withUnsafeMutableBytes { bytes in
            audioUnitRuntime.setProperty(
                unit,
                id: kAudioOutputUnitProperty_ChannelMap,
                scope: kAudioUnitScope_Output,
                element: 1,
                data: bytes.baseAddress,
                byteCount: UInt32(bytes.count)
            )
        }
        guard status == noErr else {
            return fail(status, operation: "Apply input channel map")
        }

        var maximumFrames: UInt32 = max(negotiatedBufferFrames, 1)
        size = UInt32(MemoryLayout<UInt32>.size)
        status = audioUnitRuntime.getProperty(
            unit,
            id: kAudioUnitProperty_MaximumFramesPerSlice,
            scope: kAudioUnitScope_Global,
            element: 0,
            data: &maximumFrames,
            byteCount: &size
        )
        guard status == noErr else {
            return fail(status, operation: "Read input maximum frames")
        }
        sharedState.prepareInputCapacity(Int(maximumFrames) + 1)
        sharedState.channelCount = 2
        sharedState.updateDCFilterCoefficient(sampleRate: Float(captureSampleRate))
        sharedState.updateEQCoefficients(bands: lastEqBands, sampleRate: Float(captureSampleRate))

        let callbackContext = AudioCallbackContext(state: sharedState)
        callbackContext.activate()
        let state = Unmanaged.passRetained(callbackContext).toOpaque()

        var callbackStruct = AURenderCallbackStruct(
            inputProc: inputRenderCallback,
            inputProcRefCon: UnsafeMutableRawPointer(mutating: state)
        )
        status = audioUnitRuntime.setProperty(
            unit,
            id: kAudioOutputUnitProperty_SetInputCallback,
            scope: kAudioUnitScope_Global,
            element: 0,
            data: &callbackStruct,
            byteCount: UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        )
        guard status == noErr else {
            callbackContext.deactivateAndWait()
            Unmanaged<AudioCallbackContext>.fromOpaque(state).release()
            return fail(status, operation: "Install input callback")
        }
        inputCallbackContext = callbackContext
        inputCallbackRefCon = state

        sharedState.inputUnit = unit

        status = audioUnitRuntime.initialize(unit)
        guard status == noErr else {
            return fail(status, operation: "Initialize input AudioUnit")
        }
        return true
    }

    private func setupOutputUnit(deviceID: AudioDeviceID) -> Bool {
        let desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        guard let component = audioUnitRuntime.findComponent(matching: desc) else {
            recordOutputFailure(
                operation: "Find AUHAL output component",
                status: kAudio_ParamError,
                deviceID: deviceID,
                detail: "Core Audio did not provide a HAL output component."
            )
            return false
        }

        var unit: AudioUnit?
        let createStatus = audioUnitRuntime.instantiate(component, unit: &unit)
        guard
            requireOutputNoErr(
                createStatus,
                operation: "Create output AudioUnit",
                deviceID: deviceID
            ), let unit
        else {
            return false
        }
        outputUnit = unit
        outputUnitInitialized = false

        func fail(
            _ status: OSStatus,
            operation: String,
            detail: String = "Core Audio rejected the output configuration."
        ) -> Bool {
            recordOutputFailure(
                operation: operation,
                status: status,
                deviceID: deviceID,
                detail: detail
            )
            _ = disposeOutputUnit()
            return false
        }

        var deviceIDVar = deviceID
        var status = audioUnitRuntime.setProperty(
            unit,
            id: kAudioOutputUnitProperty_CurrentDevice,
            scope: kAudioUnitScope_Global,
            element: 0,
            data: &deviceIDVar,
            byteCount: UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            return fail(status, operation: "Select output device")
        }

        // Never mutate another device's nominal hardware rate. AUHAL performs
        // the simple PCM conversion from our capture-rate client format.
        switch negotiateDeviceBufferSize(deviceID) {
        case .success:
            break
        case .failure(let failure):
            return fail(
                failure.status,
                operation: failure.operation,
                detail: failure.detail
            )
        }

        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = audioUnitRuntime.getProperty(
            unit,
            id: kAudioUnitProperty_StreamFormat,
            scope: kAudioUnitScope_Input,
            element: 0,
            data: &asbd,
            byteCount: &size
        )
        guard status == noErr else {
            return fail(status, operation: "Read output device format")
        }

        asbd.mFormatID = kAudioFormatLinearPCM
        asbd.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved
        asbd.mSampleRate = captureSampleRate
        asbd.mBitsPerChannel = 32
        asbd.mBytesPerFrame = 4
        asbd.mBytesPerPacket = 4
        asbd.mFramesPerPacket = 1
        asbd.mChannelsPerFrame = 2

        status = audioUnitRuntime.setProperty(
            unit,
            id: kAudioUnitProperty_StreamFormat,
            scope: kAudioUnitScope_Input,
            element: 0,
            data: &asbd,
            byteCount: UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        )
        guard status == noErr else {
            return fail(status, operation: "Set output client format")
        }

        var maximumFrames: UInt32 = max(negotiatedBufferFrames, 1)
        size = UInt32(MemoryLayout<UInt32>.size)
        status = audioUnitRuntime.getProperty(
            unit,
            id: kAudioUnitProperty_MaximumFramesPerSlice,
            scope: kAudioUnitScope_Global,
            element: 0,
            data: &maximumFrames,
            byteCount: &size
        )
        guard status == noErr else {
            return fail(status, operation: "Read output maximum frames")
        }
        sharedState.prepareOutputCapacity(Int(maximumFrames) + 2)

        let callbackContext = AudioCallbackContext(state: sharedState)
        callbackContext.activate()
        let state = Unmanaged.passRetained(callbackContext).toOpaque()
        var callbackStruct = AURenderCallbackStruct(
            inputProc: outputRenderCallback,
            inputProcRefCon: UnsafeMutableRawPointer(mutating: state)
        )
        status = audioUnitRuntime.setProperty(
            unit,
            id: kAudioUnitProperty_SetRenderCallback,
            scope: kAudioUnitScope_Input,
            element: 0,
            data: &callbackStruct,
            byteCount: UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        )
        guard status == noErr else {
            callbackContext.deactivateAndWait()
            Unmanaged<AudioCallbackContext>.fromOpaque(state).release()
            return fail(status, operation: "Install output callback")
        }
        outputCallbackContext = callbackContext
        outputCallbackRefCon = state

        status = audioUnitRuntime.initialize(unit)
        guard status == noErr else {
            return fail(status, operation: "Initialize output AudioUnit")
        }
        outputUnitInitialized = true
        sharedState.sameDevice = inputDeviceID == deviceID
        return true
    }

    private func negotiateDeviceBufferSize(
        _ deviceID: AudioDeviceID
    ) -> Result<UInt32, AudioEngineFailure> {
        var rangeAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSizeRange,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var range = AudioValueRange(
            mMinimum: Double(AudioConfig.targetBufferFrames),
            mMaximum: Double(AudioConfig.targetBufferFrames)
        )
        var rangeSize = UInt32(MemoryLayout<AudioValueRange>.size)
        var status = audioUnitRuntime.getObjectPropertyData(
            objectID: deviceID,
            address: &rangeAddress,
            qualifierDataSize: 0,
            qualifierData: nil,
            dataSize: &rangeSize,
            data: &range
        )
        guard status == noErr else {
            return .failure(
                AudioEngineFailure(
                    operation: "Read device buffer range",
                    status: status,
                    deviceID: deviceID,
                    detail: "Core Audio could not report the supported buffer range."
                )
            )
        }
        let lower = UInt32(max(range.mMinimum, 1))
        let upper = UInt32(max(range.mMaximum, Double(lower)))
        var requested = min(max(AudioConfig.targetBufferFrames, lower), upper)

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        status = audioUnitRuntime.setObjectPropertyData(
            objectID: deviceID,
            address: &address,
            qualifierDataSize: 0,
            qualifierData: nil,
            dataSize: UInt32(MemoryLayout<UInt32>.size),
            data: &requested
        )
        guard status == noErr else {
            return .failure(
                AudioEngineFailure(
                    operation: "Set device buffer size",
                    status: status,
                    deviceID: deviceID,
                    detail: "Core Audio could not apply the negotiated buffer size."
                )
            )
        }
        var actual = requested
        var actualSize = UInt32(MemoryLayout<UInt32>.size)
        status = audioUnitRuntime.getObjectPropertyData(
            objectID: deviceID,
            address: &address,
            qualifierDataSize: 0,
            qualifierData: nil,
            dataSize: &actualSize,
            data: &actual
        )
        guard status == noErr else {
            return .failure(
                AudioEngineFailure(
                    operation: "Read device buffer size",
                    status: status,
                    deviceID: deviceID,
                    detail: "Core Audio could not confirm the negotiated buffer size."
                )
            )
        }
        return .success(actual)
    }

    private func disposeAudioUnits() {
        sharedState.setPlaybackEnabled(false)
        sharedState.setVolume(0)
        _ = disposeInputUnit()
        _ = disposeOutputUnit()
        isMonitoring = false
        isPassthroughEnabled = false
    }

    /// Stops and disposes the input unit without relinquishing the handle or
    /// callback retain until Core Audio confirms disposal. A failed stop is
    /// deliberately followed by disposal: successful disposal is the stronger
    /// synchronous callback-lifetime boundary.
    @discardableResult
    private func disposeInputUnit() -> Bool {
        guard let unit = inputUnit else { return true }
        inputCallbackContext?.deactivateAndWait()

        if inputUnitStarted {
            let status = audioUnitRuntime.stop(unit)
            if status == noErr {
                inputUnitStarted = false
            } else {
                reportCleanupFailure(
                    status,
                    operation: "Stop input",
                    deviceID: inputDeviceID
                )
            }
        }

        let disposeStatus = audioUnitRuntime.dispose(unit)
        guard disposeStatus == noErr else {
            reportCleanupFailure(
                disposeStatus,
                operation: "Dispose input AudioUnit",
                deviceID: inputDeviceID
            )
            return false
        }

        inputUnitStarted = false
        inputUnit = nil
        sharedState.inputUnit = nil
        releaseInputCallbackRefCon()
        return true
    }

    /// Mirrors `disposeInputUnit()` for output. In particular, a failed stop
    /// never permits playback-ring reset while a render callback may be live.
    @discardableResult
    private func disposeOutputUnit() -> Bool {
        guard let unit = outputUnit else { return true }
        outputCallbackContext?.deactivateAndWait()

        if outputUnitStarted {
            let status = audioUnitRuntime.stop(unit)
            if status == noErr {
                outputUnitStarted = false
            } else {
                reportOutputCleanupFailure(
                    status,
                    operation: "Stop output",
                    deviceID: outputDeviceID
                )
            }
        }

        let disposeStatus = audioUnitRuntime.dispose(unit)
        guard disposeStatus == noErr else {
            reportOutputCleanupFailure(
                disposeStatus,
                operation: "Dispose output AudioUnit",
                deviceID: outputDeviceID
            )
            return false
        }

        outputUnitStarted = false
        outputUnitInitialized = false
        outputUnit = nil
        releaseOutputCallbackRefCon()
        return true
    }

    private func releaseInputCallbackRefCon() {
        guard let inputCallbackRefCon else { return }
        self.inputCallbackRefCon = nil
        inputCallbackContext = nil
        Unmanaged<AudioCallbackContext>
            .fromOpaque(inputCallbackRefCon)
            .release()
    }

    private func releaseOutputCallbackRefCon() {
        guard let outputCallbackRefCon else { return }
        self.outputCallbackRefCon = nil
        outputCallbackContext = nil
        Unmanaged<AudioCallbackContext>
            .fromOpaque(outputCallbackRefCon)
            .release()
    }

    @discardableResult
    private func requireNoErr(
        _ status: OSStatus,
        operation: String,
        deviceID: AudioDeviceID?
    ) -> Bool {
        guard status == noErr else {
            recordFailure(
                operation: operation,
                status: status,
                deviceID: deviceID,
                detail: "Core Audio returned an error."
            )
            return false
        }
        return true
    }

    @discardableResult
    private func requireOutputNoErr(
        _ status: OSStatus,
        operation: String,
        deviceID: AudioDeviceID?
    ) -> Bool {
        guard status == noErr else {
            recordOutputFailure(
                operation: operation,
                status: status,
                deviceID: deviceID,
                detail: "Core Audio returned an error."
            )
            return false
        }
        return true
    }

    private func reportCleanupFailure(
        _ status: OSStatus,
        operation: String,
        deviceID: AudioDeviceID?
    ) {
        guard status != noErr else { return }
        recordFailure(
            operation: operation,
            status: status,
            deviceID: deviceID,
            detail: "Core Audio could not complete audio-unit cleanup."
        )
    }

    private func reportOutputCleanupFailure(
        _ status: OSStatus,
        operation: String,
        deviceID: AudioDeviceID?
    ) {
        guard status != noErr else { return }
        recordOutputFailure(
            operation: operation,
            status: status,
            deviceID: deviceID,
            detail: "Core Audio could not complete audio-unit cleanup."
        )
    }

    private func recordOutputFailure(
        operation: String,
        status: OSStatus,
        deviceID: AudioDeviceID?,
        detail: String
    ) {
        recordFailure(
            operation: operation,
            status: status,
            deviceID: deviceID,
            detail: detail
        )
        hasActiveOutputFailure = true
    }

    private func recoverFromOutputFailureIfNeeded() {
        guard hasActiveOutputFailure, isMonitoring else { return }
        hasActiveOutputFailure = false
        lastError = nil
        engineStatus = .running(
            AudioRuntimeFormat(
                sampleRate: captureSampleRate,
                channelCount: 2,
                bufferFrames: negotiatedBufferFrames,
                inputChannelMap: inputChannelMap
            )
        )
    }

    private func recordFailure(
        operation: String,
        status: OSStatus,
        deviceID: AudioDeviceID?,
        detail: String
    ) {
        hasActiveOutputFailure = false
        let failure = AudioEngineFailure(
            operation: operation,
            status: status,
            deviceID: deviceID,
            detail: detail
        )
        lastError = failure
        engineStatus = .failed(failure)
        os_log(.error, "PhonoFlow audio error: %{public}@", failure.localizedDescription)
    }

    // MARK: - UI Updates

    private var uiUpdateTimer: DispatchSourceTimer?
    private var lastUpdateTime: CFTimeInterval = 0

    // Pre-allocated viz buffers (avoid alloc/dealloc every frame)
    private let vizBufSize = 1024
    private let visualizationBuffers = VisualizationBuffers(capacity: 1024)

    func startUIUpdateTimer() {
        stopUIUpdateTimer()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now(),
            repeating: .milliseconds(33),
            leeway: .milliseconds(2)
        )
        timer.setEventHandler { [weak self] in
            self?.performUIUpdate()
        }
        timer.resume()
        uiUpdateTimer = timer
    }

    private func performUIUpdate() {
        let now = CACurrentMediaTime()
        let timeSinceLastUpdate = now - lastUpdateTime
        guard timeSinceLastUpdate >= (1.0 / 31.0) else { return }
        lastUpdateTime = now

        let renderFailure = sharedState.takeRenderFailure()
        if renderFailure != noErr {
            recordFailure(
                operation: "Render input",
                status: renderFailure,
                deviceID: inputDeviceID,
                detail: "Core Audio could not render the selected input channels."
            )
        }

        if isMeteringEnabled {
            peakLevel = sharedState.getPeakLevel()
        }
        callbackOverflowCount = sharedState.callbackOverflows
        playbackOverflowCount = sharedState.playbackOverflows
        playbackUnderrunCount = sharedState.playbackUnderruns
        callbackCount = sharedState.callbackCount
        maximumCallbackDurationMicroseconds =
            Double(sharedState.maximumCallbackDurationNanoseconds) / 1_000
        analysisDroppedFrameCount = pipelineWorker.analysisDroppedFrames
        fanoutDroppedFrameCount = pipelineWorker.fanoutDroppedFrames
        analysisQueueDepth = pipelineWorker.analysisQueueDepth
        fanoutQueueDepth = pipelineWorker.fanoutQueueDepth
        spectrogramRenderSkipCount = pipelineWorker.skippedNativeFrames

        // Update recording duration
        if isRecording {
            recordingDuration = recorder.durationSeconds
            if !recorder.isRecording {
                stopRecording()
            }
        }

        if !visualizationsPaused {
            updateVisualizationDataLightweight()
        } else {
            updateLevelsOnly()
        }
    }

    /// Lightweight update — waveforms and phase at refresh rate, no spectrogram
    private func updateVisualizationDataLightweight() {
        let leftBuf = visualizationBuffers.left
        let rightBuf = visualizationBuffers.right

        let count = sharedState.peekStereoRecent(left: leftBuf, right: rightBuf, count: vizBufSize)
        guard count > 0 else { return }

        // Update waveform data
        let waveformCount = min(200, count)
        leftWaveform = Array(UnsafeBufferPointer(start: leftBuf, count: waveformCount))
        rightWaveform = Array(UnsafeBufferPointer(start: rightBuf, count: waveformCount))

        // Update phase scope points (downsample to 60 points)
        let step = max(waveformCount / 60, 1)
        phasePoints = stride(from: 0, to: waveformCount, by: step).map { i in
            (x: leftBuf[i], y: rightBuf[i])
        }

        // Update L/R levels with smoothing
        var leftRms: Float = 0
        var rightRms: Float = 0
        vDSP_rmsqv(leftBuf, 1, &leftRms, vDSP_Length(count))
        vDSP_rmsqv(rightBuf, 1, &rightRms, vDSP_Length(count))

        let scaledLeft = min(leftRms * 4.0, 1.0)
        let scaledRight = min(rightRms * 4.0, 1.0)

        let attackL: Float = scaledLeft > leftLevel ? 0.85 : 0.25
        let attackR: Float = scaledRight > rightLevel ? 0.85 : 0.25
        leftLevel += attackL * (scaledLeft - leftLevel)
        rightLevel += attackR * (scaledRight - rightLevel)
    }

    /// Lightweight update — only L/R levels for meter bars when viz is paused
    private func updateLevelsOnly() {
        let leftBuf = visualizationBuffers.left
        let rightBuf = visualizationBuffers.right

        let count = sharedState.peekStereoRecent(left: leftBuf, right: rightBuf, count: vizBufSize)
        guard count > 0 else { return }

        var leftRms: Float = 0
        var rightRms: Float = 0
        vDSP_rmsqv(leftBuf, 1, &leftRms, vDSP_Length(count))
        vDSP_rmsqv(rightBuf, 1, &rightRms, vDSP_Length(count))

        let scaledLeft = min(leftRms * 4.0, 1.0)
        let scaledRight = min(rightRms * 4.0, 1.0)

        let attackL: Float = scaledLeft > leftLevel ? 0.85 : 0.25
        let attackR: Float = scaledRight > rightLevel ? 0.85 : 0.25
        leftLevel += attackL * (scaledLeft - leftLevel)
        rightLevel += attackR * (scaledRight - rightLevel)
    }

    /// Clear spectrogram history and resume fresh
    func clearSpectrogram() {
        spectrogramImage = nil
        pipelineWorker.clearNativeHistory()
    }

    func enableSpectrogram() {
        spectrogramEnabled = true
        clearSpectrogram()
    }

    func disableSpectrogram() {
        spectrogramEnabled = false
        clearSpectrogram()
    }

    func pauseVisualizations() {
        visualizationsPaused = true
        disableSpectrogram()
    }

    func resumeVisualizations() {
        visualizationsPaused = false
        enableSpectrogram()
    }

    private func updateAnalysisDemand() {
        pipelineWorker.setNativeVisualizationEnabled(
            spectrogramEnabled && !visualizationsPaused
        )
        pipelineWorker.setRemoteSpectrumSubscribersVisible(
            remoteSpectrumSubscribersVisible
        )
    }

    private func stopUIUpdateTimer() {
        uiUpdateTimer?.setEventHandler {}
        uiUpdateTimer?.cancel()
        uiUpdateTimer = nil
    }

    // MARK: - Auto-Gain

    private var autoGainTimer: Timer?
    private let autoGainTargetLevel: Float = 0.5  // -6 dBFS RMS
    private let autoGainMinLevel: Float = 0.001  // -60 dBFS (ignore near-silence)
    private let autoGainSmoothingFactor: Float = 0.1  // Slow, smooth adjustments

    func startAutoGain() {
        guard autoGainTimer == nil else { return }
        autoGainTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.adjustAutoGain()
            }
        }
        if let timer = autoGainTimer {
            RunLoop.current.add(timer, forMode: .common)
        }
    }

    func stopAutoGain() {
        autoGainTimer?.invalidate()
        autoGainTimer = nil
    }

    private func adjustAutoGain() {
        guard isAutoGainEnabled else { return }

        guard gain.isFinite else {
            gain = 1
            sharedState.setGain(gain)
            return
        }
        let currentGain = gain
        if currentGain <= 0 {
            // A zero capture gain also produces a zero post-gain meter, so the
            // normal ratio cannot recover without a deterministic unity seed.
            gain = 1
            sharedState.setGain(gain)
            return
        }
        let postGainPeak = sharedState.getAutoGainPeakLevel()
        guard postGainPeak.isFinite, postGainPeak > autoGainMinLevel else {
            return
        }

        // The callback meter is post-gain. Convert its correction ratio back
        // into an absolute gain target instead of applying it as one.
        let targetGain =
            currentGain * autoGainTargetLevel / postGainPeak

        // Clamp to reasonable range (0.1x to 4.0x)
        let clampedTarget = max(0.1, min(4.0, targetGain))

        // Smoothly interpolate current gain toward target
        gain =
            currentGain
            + autoGainSmoothingFactor * (clampedTarget - currentGain)

        // Capture gain feeds meters, recordings, network streams, and local
        // output, so publish it even when no passthrough device is active.
        sharedState.setGain(gain)
        if isPassthroughEnabled {
            sharedState.setVolume(1)
        }
    }
}

// MARK: - Lock-free stereo rings

nonisolated private final class VisualizationBuffers: @unchecked Sendable {
    let left: UnsafeMutablePointer<Float>
    let right: UnsafeMutablePointer<Float>

    init(capacity: Int) {
        left = .allocate(capacity: capacity)
        right = .allocate(capacity: capacity)
        left.initialize(repeating: 0, count: capacity)
        right.initialize(repeating: 0, count: capacity)
    }

    deinit {
        left.deallocate()
        right.deallocate()
    }
}

/// Single-producer/single-consumer stereo ring. The input callback is the only
/// producer and the output callback is the only consumer.
nonisolated private final class RealtimeStereoRing: @unchecked Sendable {
    private let left: UnsafeMutablePointer<Float>
    private let right: UnsafeMutablePointer<Float>
    private let capacity: UInt64
    private let writeSequence = Atomic<UInt64>(0)
    private let readSequence = Atomic<UInt64>(0)
    private let overflowCount = Atomic<UInt64>(0)
    private let underrunCount = Atomic<UInt64>(0)

    init(capacity: Int) {
        self.capacity = UInt64(max(capacity, 2))
        left = .allocate(capacity: Int(self.capacity))
        right = .allocate(capacity: Int(self.capacity))
        left.initialize(repeating: 0, count: Int(self.capacity))
        right.initialize(repeating: 0, count: Int(self.capacity))
    }

    deinit {
        left.deallocate()
        right.deallocate()
    }

    func write(
        left sourceLeft: UnsafePointer<Float>,
        right sourceRight: UnsafePointer<Float>,
        count requestedCount: Int
    ) {
        guard requestedCount > 0 else { return }
        let write = writeSequence.load(ordering: .relaxed)
        let read = readSequence.load(ordering: .acquiring)
        let used = min(write &- read, capacity)
        let available = capacity &- used
        let count = min(UInt64(requestedCount), available)
        guard count > 0 else {
            overflowCount.wrappingAdd(
                UInt64(requestedCount),
                ordering: .relaxed
            )
            return
        }

        copyIntoRing(
            destination: left,
            source: sourceLeft,
            sequence: write,
            count: Int(count)
        )
        copyIntoRing(
            destination: right,
            source: sourceRight,
            sequence: write,
            count: Int(count)
        )
        writeSequence.store(write &+ count, ordering: .releasing)
        if count < UInt64(requestedCount) {
            overflowCount.wrappingAdd(
                UInt64(requestedCount) &- count,
                ordering: .relaxed
            )
        }
    }

    func read(
        left destinationLeft: UnsafeMutablePointer<Float>,
        right destinationRight: UnsafeMutablePointer<Float>,
        count requestedCount: Int
    ) -> Int {
        guard requestedCount > 0 else { return 0 }
        let read = readSequence.load(ordering: .relaxed)
        let write = writeSequence.load(ordering: .acquiring)
        let available = min(write &- read, capacity)
        let count = min(UInt64(requestedCount), available)
        if count > 0 {
            copyFromRing(
                source: left,
                destination: destinationLeft,
                sequence: read,
                count: Int(count)
            )
            copyFromRing(
                source: right,
                destination: destinationRight,
                sequence: read,
                count: Int(count)
            )
            readSequence.store(read &+ count, ordering: .releasing)
        }
        if count < UInt64(requestedCount) {
            let missing = requestedCount - Int(count)
            memset(
                destinationLeft + Int(count),
                0,
                missing * MemoryLayout<Float>.stride
            )
            memset(
                destinationRight + Int(count),
                0,
                missing * MemoryLayout<Float>.stride
            )
            underrunCount.wrappingAdd(1, ordering: .relaxed)
        }
        return Int(count)
    }

    func fillLevel() -> Int {
        let read = readSequence.load(ordering: .acquiring)
        let write = writeSequence.load(ordering: .acquiring)
        return Int(min(write &- read, capacity))
    }

    func reset() {
        let write = writeSequence.load(ordering: .acquiring)
        readSequence.store(write, ordering: .releasing)
    }

    var overflows: UInt64 {
        overflowCount.load(ordering: .relaxed)
    }

    var underruns: UInt64 {
        underrunCount.load(ordering: .relaxed)
    }

    private func copyIntoRing(
        destination: UnsafeMutablePointer<Float>,
        source: UnsafePointer<Float>,
        sequence: UInt64,
        count: Int
    ) {
        let start = Int(sequence % capacity)
        let first = min(count, Int(capacity) - start)
        memcpy(
            destination + start,
            source,
            first * MemoryLayout<Float>.stride
        )
        if first < count {
            memcpy(
                destination,
                source + first,
                (count - first) * MemoryLayout<Float>.stride
            )
        }
    }

    private func copyFromRing(
        source: UnsafePointer<Float>,
        destination: UnsafeMutablePointer<Float>,
        sequence: UInt64,
        count: Int
    ) {
        let start = Int(sequence % capacity)
        let first = min(count, Int(capacity) - start)
        memcpy(
            destination,
            source + start,
            first * MemoryLayout<Float>.stride
        )
        if first < count {
            memcpy(
                destination + first,
                source,
                (count - first) * MemoryLayout<Float>.stride
            )
        }
    }
}

/// Single-producer snapshot ring for meters and spectrum analysis. It is
/// intentionally independent from playback, so output consumption cannot make
/// the spectrogram freeze.
nonisolated private final class AnalysisStereoRing: @unchecked Sendable {
    private let left: UnsafeMutablePointer<Float>
    private let right: UnsafeMutablePointer<Float>
    private let capacity: UInt64
    private let writeSequence = Atomic<UInt64>(0)
    private let readSequence = Atomic<UInt64>(0)
    private let dropCount = Atomic<UInt64>(0)

    init(capacity: Int) {
        self.capacity = UInt64(max(capacity, 2))
        left = .allocate(capacity: Int(self.capacity))
        right = .allocate(capacity: Int(self.capacity))
        left.initialize(repeating: 0, count: Int(self.capacity))
        right.initialize(repeating: 0, count: Int(self.capacity))
    }

    deinit {
        left.deallocate()
        right.deallocate()
    }

    func write(
        left sourceLeft: UnsafePointer<Float>,
        right sourceRight: UnsafePointer<Float>,
        count requestedCount: Int
    ) {
        guard requestedCount > 0 else { return }
        let sequence = writeSequence.load(ordering: .relaxed)
        let read = readSequence.load(ordering: .acquiring)
        let used = min(sequence &- read, capacity)
        let count = min(UInt64(requestedCount), capacity &- used)
        guard count > 0 else {
            dropCount.wrappingAdd(
                UInt64(requestedCount),
                ordering: .relaxed
            )
            return
        }
        copyIntoRing(
            destination: left,
            source: sourceLeft,
            sequence: sequence,
            count: Int(count)
        )
        copyIntoRing(
            destination: right,
            source: sourceRight,
            sequence: sequence,
            count: Int(count)
        )
        writeSequence.store(sequence &+ count, ordering: .releasing)
        if count < UInt64(requestedCount) {
            dropCount.wrappingAdd(
                UInt64(requestedCount) &- count,
                ordering: .relaxed
            )
        }
    }

    func peekRecent(
        left destinationLeft: UnsafeMutablePointer<Float>,
        right destinationRight: UnsafeMutablePointer<Float>,
        count requestedCount: Int
    ) -> Int {
        guard requestedCount > 0 else { return 0 }
        let read = readSequence.load(ordering: .relaxed)
        let end = writeSequence.load(ordering: .acquiring)
        let available = min(end &- read, capacity)
        let count = min(UInt64(requestedCount), available)
        guard count > 0 else { return 0 }
        let start = end &- count
        copyFromRing(
            source: left,
            destination: destinationLeft,
            sequence: start,
            count: Int(count)
        )
        copyFromRing(
            source: right,
            destination: destinationRight,
            sequence: start,
            count: Int(count)
        )
        readSequence.store(end, ordering: .releasing)
        return Int(count)
    }

    var droppedFrames: UInt64 {
        dropCount.load(ordering: .relaxed)
    }

    func reset() {
        let write = writeSequence.load(ordering: .acquiring)
        readSequence.store(write, ordering: .releasing)
    }

    private func copyIntoRing(
        destination: UnsafeMutablePointer<Float>,
        source: UnsafePointer<Float>,
        sequence: UInt64,
        count: Int
    ) {
        let start = Int(sequence % capacity)
        let first = min(count, Int(capacity) - start)
        memcpy(destination + start, source, first * MemoryLayout<Float>.stride)
        if first < count {
            memcpy(
                destination,
                source + first,
                (count - first) * MemoryLayout<Float>.stride
            )
        }
    }

    private func copyFromRing(
        source: UnsafePointer<Float>,
        destination: UnsafeMutablePointer<Float>,
        sequence: UInt64,
        count: Int
    ) {
        let start = Int(sequence % capacity)
        let first = min(count, Int(capacity) - start)
        memcpy(destination, source + start, first * MemoryLayout<Float>.stride)
        if first < count {
            memcpy(
                destination + first,
                source,
                (count - first) * MemoryLayout<Float>.stride
            )
        }
    }
}

// MARK: - Shared Audio State

/// Lock-free callback admission gate. Teardown first closes admission and then
/// waits for callbacks that already passed the gate. A callback arriving after
/// closure may touch the retained gate object, but it cannot touch audio
/// buffers or rings.
nonisolated private final class RealtimeCallbackGate: @unchecked Sendable {
    private let enabled = Atomic<Bool>(false)
    private let activeCallbacks = Atomic<UInt32>(0)

    func activate() {
        enabled.store(true, ordering: .sequentiallyConsistent)
    }

    func begin() -> Bool {
        activeCallbacks.wrappingAdd(
            1,
            ordering: .sequentiallyConsistent
        )
        guard enabled.load(ordering: .sequentiallyConsistent) else {
            activeCallbacks.wrappingSubtract(
                1,
                ordering: .sequentiallyConsistent
            )
            return false
        }
        return true
    }

    func end() {
        activeCallbacks.wrappingSubtract(
            1,
            ordering: .sequentiallyConsistent
        )
    }

    func deactivateAndWait() {
        enabled.store(false, ordering: .sequentiallyConsistent)
        while activeCallbacks.load(ordering: .sequentiallyConsistent)
            != 0
        {
            usleep(50)
        }
    }
}

/// The AudioUnit owns one retained callback context. During ordinary retries
/// it keeps the shared pipeline alive. If disposal fails during monitor deinit,
/// the context is detached so only this small no-op sentinel remains reachable
/// from Core Audio.
nonisolated private final class AudioCallbackContext: @unchecked Sendable {
    private let gate = RealtimeCallbackGate()
    private var state: SharedAudioState?

    init(state: SharedAudioState) {
        self.state = state
    }

    func activate() {
        gate.activate()
    }

    func begin() -> SharedAudioState? {
        guard gate.begin() else { return nil }
        guard let state else {
            gate.end()
            return nil
        }
        return state
    }

    func end() {
        gate.end()
    }

    func deactivateAndWait() {
        gate.deactivateAndWait()
    }

    func detachState() {
        gate.deactivateAndWait()
        state = nil
    }
}

nonisolated final class SharedAudioState: @unchecked Sendable {
    private let playbackRing = RealtimeStereoRing(capacity: AudioConfig.ringCapacity)
    private let visualizationRing = AnalysisStereoRing(capacity: AudioConfig.ringCapacity)
    private let pipelineWorker: AudioPipelineWorker
    let audioUnitRuntime: any AudioUnitHALRuntime

    private let smoothedPeak = Atomic<Float>(0)
    private let autoGainPeak = Atomic<Float>(0)
    private let volume = Atomic<Float>(0)
    private let gain = Atomic<Float>(1)
    private let meteringEnabled = Atomic<Bool>(false)
    private let playbackEnabled = Atomic<Bool>(false)

    // Three fixed coefficient slots allow the main actor to publish rapid EQ
    // changes without ever overwriting the slot currently copied by the audio
    // callback. No allocation or lock is needed on either side.
    private let eqCoeffsStaging: UnsafeMutablePointer<Float>
    private let eqPublishedSlot = Atomic<Int>(0)
    private let eqReaderSlot = Atomic<Int>(-1)
    private let eqVersion = Atomic<UInt32>(0)
    private let eqActive = Atomic<Bool>(false)

    let eqCoeffs: UnsafeMutablePointer<Float>
    let eqStateL: UnsafeMutablePointer<Float>
    let eqStateR: UnsafeMutablePointer<Float>
    var cachedEqVersion: UInt32 = 0
    var cachedEqActive: Bool = false

    var inputUnit: AudioUnit?
    var channelCount: Int = 2
    var sameDevice: Bool = false

    var dcLeftPrevX: Float = 0
    var dcLeftPrevY: Float = 0
    var dcRightPrevX: Float = 0
    var dcRightPrevY: Float = 0
    var dcFilterR: Float = 0.9972

    private(set) var inputCapacity = AudioConfig.workCapacity
    private(set) var outputCapacity = AudioConfig.workCapacity
    private(set) var workLeft: UnsafeMutablePointer<Float>
    private(set) var workRight: UnsafeMutablePointer<Float>
    private(set) var workOutL: UnsafeMutablePointer<Float>
    private(set) var workOutR: UnsafeMutablePointer<Float>
    private let inputOverflowCount = Atomic<UInt64>(0)
    private let renderFailureStatus = Atomic<OSStatus>(noErr)
    private let completedCallbackCount = Atomic<UInt64>(0)
    private let maximumCallbackNanoseconds = Atomic<UInt64>(0)

    init(
        pipelineWorker: AudioPipelineWorker,
        audioUnitRuntime: any AudioUnitHALRuntime
    ) {
        self.pipelineWorker = pipelineWorker
        self.audioUnitRuntime = audioUnitRuntime
        let capacity = AudioConfig.workCapacity
        workLeft = .allocate(capacity: capacity)
        workRight = .allocate(capacity: capacity)
        workOutL = .allocate(capacity: capacity)
        workOutR = .allocate(capacity: capacity)
        workLeft.initialize(repeating: 0, count: capacity)
        workRight.initialize(repeating: 0, count: capacity)
        workOutL.initialize(repeating: 0, count: capacity)
        workOutR.initialize(repeating: 0, count: capacity)

        let coefficientCount = AudioConfig.eqBandCount * 5
        let stateCount = AudioConfig.eqBandCount * 2
        eqCoeffsStaging = .allocate(
            capacity: coefficientCount * AudioConfig.eqPublicationSlotCount
        )
        eqCoeffsStaging.initialize(
            repeating: 0,
            count: coefficientCount * AudioConfig.eqPublicationSlotCount
        )
        eqCoeffs = .allocate(capacity: coefficientCount)
        eqCoeffs.initialize(repeating: 0, count: coefficientCount)
        eqStateL = .allocate(capacity: stateCount)
        eqStateL.initialize(repeating: 0, count: stateCount)
        eqStateR = .allocate(capacity: stateCount)
        eqStateR.initialize(repeating: 0, count: stateCount)

        for slot in 0..<AudioConfig.eqPublicationSlotCount {
            for band in 0..<AudioConfig.eqBandCount {
                eqCoeffsStaging[slot * coefficientCount + band * 5] = 1
            }
        }
        for band in 0..<AudioConfig.eqBandCount {
            eqCoeffs[band * 5] = 1
        }
    }

    deinit {
        workLeft.deallocate()
        workRight.deallocate()
        workOutL.deallocate()
        workOutR.deallocate()
        eqCoeffsStaging.deallocate()
        eqCoeffs.deallocate()
        eqStateL.deallocate()
        eqStateR.deallocate()
    }

    func prepareInputCapacity(_ requested: Int) {
        let capacity = max(requested, AudioConfig.workCapacity)
        guard capacity != inputCapacity else { return }
        workLeft.deallocate()
        workRight.deallocate()
        workLeft = .allocate(capacity: capacity)
        workRight = .allocate(capacity: capacity)
        workLeft.initialize(repeating: 0, count: capacity)
        workRight.initialize(repeating: 0, count: capacity)
        inputCapacity = capacity
    }

    func prepareOutputCapacity(_ requested: Int) {
        let capacity = max(requested, AudioConfig.workCapacity)
        guard capacity != outputCapacity else { return }
        workOutL.deallocate()
        workOutR.deallocate()
        workOutL = .allocate(capacity: capacity)
        workOutR = .allocate(capacity: capacity)
        workOutL.initialize(repeating: 0, count: capacity)
        workOutR.initialize(repeating: 0, count: capacity)
        outputCapacity = capacity
    }

    func recordInputOverflow() {
        inputOverflowCount.wrappingAdd(1, ordering: .relaxed)
    }

    func recordRenderFailure(_ status: OSStatus) {
        guard status != noErr else { return }
        _ = renderFailureStatus.compareExchange(
            expected: noErr,
            desired: status,
            ordering: .relaxed
        )
    }

    func takeRenderFailure() -> OSStatus {
        renderFailureStatus.exchange(
            noErr,
            ordering: .acquiringAndReleasing
        )
    }

    var callbackOverflows: UInt64 {
        inputOverflowCount.load(ordering: .relaxed)
            &+ playbackRing.overflows
            &+ visualizationRing.droppedFrames
    }

    var playbackOverflows: UInt64 {
        playbackRing.overflows
    }

    var playbackUnderruns: UInt64 {
        playbackRing.underruns
    }

    var callbackCount: UInt64 {
        completedCallbackCount.load(ordering: .relaxed)
    }

    var maximumCallbackDurationNanoseconds: UInt64 {
        maximumCallbackNanoseconds.load(ordering: .relaxed)
    }

    func recordCallbackDuration(nanoseconds: UInt64) {
        completedCallbackCount.wrappingAdd(1, ordering: .relaxed)
        var maximum = maximumCallbackNanoseconds.load(ordering: .relaxed)
        while nanoseconds > maximum {
            let result = maximumCallbackNanoseconds.compareExchange(
                expected: maximum,
                desired: nanoseconds,
                ordering: .relaxed
            )
            if result.exchanged {
                break
            }
            maximum = result.original
        }
    }

    func updateDCFilterCoefficient(sampleRate: Float) {
        dcFilterR = expf(-2.0 * Float.pi * 20.0 / sampleRate)
    }

    func updateEQCoefficients(bands: [Float], sampleRate: Float) {
        guard sampleRate > 0 else { return }
        let nyquistFrequency = sampleRate * 0.5
        var active = false
        let currentSlot = eqPublishedSlot.load(ordering: .acquiring)
        let readerSlot = eqReaderSlot.load(ordering: .acquiring)
        let nextSlot =
            (0..<AudioConfig.eqPublicationSlotCount).first {
                $0 != currentSlot && $0 != readerSlot
            }!
        let coefficientCount = AudioConfig.eqBandCount * 5
        let slot = eqCoeffsStaging + nextSlot * coefficientCount

        for index in 0..<AudioConfig.eqBandCount {
            let frequency = AudioConfig.eqFrequencies[index]
            let requestedGain = index < bands.count ? bands[index] : 0
            // A peaking filter centered at or above Nyquist is undefined for
            // the requested analog band and can produce unstable poles.
            // Bypass that band rather than folding it into audible spectrum.
            let gain =
                frequency < nyquistFrequency
                    && requestedGain.isFinite
                ? requestedGain
                : 0
            active = active || gain != 0
            let (b0, b1, b2, a1, a2) = computePeakingEQ(
                freq: frequency,
                gainDB: gain,
                q: AudioConfig.eqQ,
                sampleRate: sampleRate
            )
            let base = index * 5
            slot[base] = b0
            slot[base + 1] = b1
            slot[base + 2] = b2
            slot[base + 3] = a1
            slot[base + 4] = a2
        }
        eqActive.store(active, ordering: .relaxed)
        eqPublishedSlot.store(nextSlot, ordering: .releasing)
        eqVersion.wrappingAdd(1, ordering: .releasing)
    }

    /// Audio EQ Cookbook peaking EQ — Robert Bristow-Johnson
    private func computePeakingEQ(
        freq: Float, gainDB: Float, q: Float, sampleRate: Float
    ) -> (Float, Float, Float, Float, Float) {
        if gainDB == 0 { return (1, 0, 0, 0, 0) }
        let amplitude = powf(10, gainDB / 40.0)
        let w0 = 2.0 * Float.pi * freq / sampleRate
        let sinW0 = sinf(w0)
        let cosW0 = cosf(w0)
        let alpha = sinW0 / (2.0 * q)

        let b0 = 1.0 + alpha * amplitude
        let b1 = -2.0 * cosW0
        let b2 = 1.0 - alpha * amplitude
        let a0 = 1.0 + alpha / amplitude
        let a1 = -2.0 * cosW0
        let a2 = 1.0 - alpha / amplitude

        let invA0 = 1.0 / a0
        return (b0 * invA0, b1 * invA0, b2 * invA0, a1 * invA0, a2 * invA0)
    }

    // Called from input callback to sync coefficients if version changed
    func syncEQCoefficients() {
        let version = eqVersion.load(ordering: .acquiring)
        if version != cachedEqVersion {
            let coefficientCount = AudioConfig.eqBandCount * 5
            var slot: Int
            while true {
                slot = eqPublishedSlot.load(ordering: .acquiring)
                eqReaderSlot.store(slot, ordering: .releasing)
                if eqPublishedSlot.load(ordering: .acquiring) == slot {
                    break
                }
                eqReaderSlot.store(-1, ordering: .releasing)
            }
            memcpy(
                eqCoeffs,
                eqCoeffsStaging + slot * coefficientCount,
                coefficientCount * MemoryLayout<Float>.stride
            )
            eqReaderSlot.store(-1, ordering: .releasing)
            cachedEqVersion = version
        }
        cachedEqActive = eqActive.load(ordering: .relaxed)
    }

    // MARK: - Parameter Access

    func setVolume(_ vol: Float) {
        volume.store(vol, ordering: .relaxed)
    }
    func setGain(_ gain: Float) {
        self.gain.store(gain, ordering: .relaxed)
    }
    func setMeteringEnabled(_ enabled: Bool) {
        meteringEnabled.store(enabled, ordering: .relaxed)
    }
    func setPlaybackEnabled(_ enabled: Bool) {
        playbackEnabled.store(enabled, ordering: .releasing)
    }

    struct AudioParams {
        var gain: Float
        var volume: Float
        var meteringEnabled: Bool
    }

    func getParams() -> AudioParams {
        AudioParams(
            gain: gain.load(ordering: .relaxed),
            volume: volume.load(ordering: .relaxed),
            meteringEnabled: meteringEnabled.load(ordering: .relaxed)
        )
    }

    func getPeakLevel() -> Float {
        smoothedPeak.load(ordering: .relaxed)
    }

    func getAutoGainPeakLevel() -> Float {
        autoGainPeak.load(ordering: .relaxed)
    }

    var isEQActive: Bool {
        eqActive.load(ordering: .acquiring)
    }

    func updatePeak(rms: Float, gain: Float) {
        let postGainRMS = min(max(rms * gain, 0), 1)
        autoGainPeak.store(postGainRMS, ordering: .relaxed)
        let rawLevel = min(rms * 4.0, 1.0)
        let level = min(rawLevel * gain, 1.0)
        let previous = smoothedPeak.load(ordering: .relaxed)
        let coefficient: Float = level > previous ? 0.85 : 0.25
        smoothedPeak.store(
            previous + coefficient * (level - previous),
            ordering: .relaxed
        )
    }

    // MARK: - Stereo Ring Buffer (atomic L/R operations)

    func writeStereo(
        left: UnsafePointer<Float>,
        right: UnsafePointer<Float>,
        count: Int,
        captureTimestampNanoseconds: UInt64
    ) {
        if playbackEnabled.load(ordering: .acquiring) {
            playbackRing.write(left: left, right: right, count: count)
        }
        visualizationRing.write(left: left, right: right, count: count)
        pipelineWorker.enqueue(
            left: left,
            right: right,
            count: count,
            captureTimestampNanoseconds: captureTimestampNanoseconds
        )
    }

    func readStereo(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, count: Int) -> Int {
        playbackRing.read(left: left, right: right, count: count)
    }

    func ringFillLevel() -> Int {
        playbackRing.fillLevel()
    }

    func peekStereoRecent(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, count: Int) -> Int {
        visualizationRing.peekRecent(left: left, right: right, count: count)
    }

    func resetPlayback() {
        playbackRing.reset()
    }

    func reset() {
        smoothedPeak.store(0, ordering: .relaxed)
        autoGainPeak.store(0, ordering: .relaxed)
        renderFailureStatus.store(noErr, ordering: .relaxed)
        volume.store(0, ordering: .relaxed)
        playbackEnabled.store(false, ordering: .releasing)
        playbackRing.reset()
        visualizationRing.reset()

        inputUnit = nil
        dcLeftPrevX = 0
        dcLeftPrevY = 0
        dcRightPrevX = 0
        dcRightPrevY = 0

        // Reset EQ filter state
        let stateCount = AudioConfig.eqBandCount * 2
        eqStateL.initialize(repeating: 0, count: stateCount)
        eqStateR.initialize(repeating: 0, count: stateCount)
    }
}

// MARK: - DSP Free Functions

/// Process a single biquad section (Transposed Direct Form II)
/// Coefficients at coeffs[0..4] = [b0, b1, b2, a1, a2]
/// State at state[0..1] = [z1, z2]
nonisolated private func processBiquad(
    _ buffer: UnsafeMutablePointer<Float>,
    count: Int,
    coeffs: UnsafePointer<Float>,
    state: UnsafeMutablePointer<Float>
) {
    let b0 = coeffs[0]
    let b1 = coeffs[1]
    let b2 = coeffs[2]
    let a1 = coeffs[3]
    let a2 = coeffs[4]
    var z1 = state[0]
    var z2 = state[1]

    for i in 0..<count {
        let x = buffer[i]
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        buffer[i] = y
    }

    // Flush denormals to zero to prevent CPU spikes
    if z1.isSubnormal { z1 = 0 }
    if z2.isSubnormal { z2 = 0 }

    state[0] = z1
    state[1] = z2
}

/// Apply 10-band parametric EQ (cascade of biquad sections)
nonisolated private func applyEQ(
    _ buffer: UnsafeMutablePointer<Float>,
    count: Int,
    coeffs: UnsafePointer<Float>,
    state: UnsafeMutablePointer<Float>
) {
    for band in 0..<AudioConfig.eqBandCount {
        processBiquad(
            buffer, count: count,
            coeffs: coeffs + band * 5,
            state: state + band * 2)
    }
}

/// Soft limiter: transparent below threshold, tanh compression above
/// Approaches but never reaches ±1.0
nonisolated private func applySoftLimiter(_ buffer: UnsafeMutablePointer<Float>, count: Int) {
    // Fast path: skip if no samples exceed threshold
    var maxVal: Float = 0
    vDSP_maxmgv(buffer, 1, &maxVal, vDSP_Length(count))
    guard maxVal > AudioConfig.softLimitThreshold else { return }

    let threshold = AudioConfig.softLimitThreshold
    let headroom = 1.0 - threshold

    for i in 0..<count {
        let x = buffer[i]
        let absX = abs(x)
        if absX > threshold {
            let sign: Float = x >= 0 ? 1.0 : -1.0
            let excess = absX - threshold
            buffer[i] = sign * (threshold + headroom * tanhf(excess / headroom))
        }
    }
}

/// Catmull-Rom cubic resample srcCount samples → dstCount samples
/// Much higher quality than linear interpolation — preserves high-frequency detail
nonisolated private func cubicResample(
    src: UnsafePointer<Float>, srcCount: Int,
    dst: UnsafeMutablePointer<Float>, dstCount: Int
) {
    if srcCount == dstCount {
        memcpy(dst, src, dstCount * MemoryLayout<Float>.stride)
        return
    }
    guard srcCount > 1, dstCount > 0 else {
        if dstCount > 0 { memset(dst, 0, dstCount * MemoryLayout<Float>.stride) }
        return
    }

    let ratio = Float(srcCount - 1) / Float(max(dstCount - 1, 1))
    for i in 0..<dstCount {
        let srcPos = Float(i) * ratio
        let idx = Int(srcPos)
        let frac = srcPos - Float(idx)

        // Catmull-Rom spline with clamped boundary indices
        let p0 = src[max(idx - 1, 0)]
        let p1 = src[min(idx, srcCount - 1)]
        let p2 = src[min(idx + 1, srcCount - 1)]
        let p3 = src[min(idx + 2, srcCount - 1)]

        let a = -0.5 * p0 + 1.5 * p1 - 1.5 * p2 + 0.5 * p3
        let b = p0 - 2.5 * p1 + 2.0 * p2 - 0.5 * p3
        let c = -0.5 * p0 + 0.5 * p2
        let d = p1

        dst[i] = ((a * frac + b) * frac + c) * frac + d
    }
}

// MARK: - Input Render Callback

nonisolated private func inputRenderCallback(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {

    let context =
        Unmanaged<AudioCallbackContext>
        .fromOpaque(inRefCon)
        .takeUnretainedValue()
    guard let state = context.begin() else { return noErr }
    defer { context.end() }
    guard let unit = state.inputUnit else { return noErr }
    let callbackStart = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    defer {
        let callbackEnd = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        state.recordCallbackDuration(
            nanoseconds: callbackEnd &- callbackStart
        )
    }

    let channelCount = state.channelCount
    let frameCount = Int(inNumberFrames)
    guard frameCount <= state.inputCapacity else {
        state.recordInputOverflow()
        return kAudio_ParamError
    }
    let byteSize = inNumberFrames * UInt32(MemoryLayout<Float>.stride)
    let leftBuf = state.workLeft
    let rightBuf = state.workRight

    // Render from hardware
    if channelCount >= 2 {
        var stereoABL: (AudioBufferList, AudioBuffer) = (
            AudioBufferList(
                mNumberBuffers: 2,
                mBuffers: AudioBuffer(
                    mNumberChannels: 1, mDataByteSize: byteSize,
                    mData: UnsafeMutableRawPointer(leftBuf))
            ),
            AudioBuffer(
                mNumberChannels: 1, mDataByteSize: byteSize,
                mData: UnsafeMutableRawPointer(rightBuf))
        )
        var renderStatus: OSStatus = noErr
        withUnsafeMutablePointer(to: &stereoABL) { ptr in
            let ablPtr = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: AudioBufferList.self)
            renderStatus = state.audioUnitRuntime.render(
                unit,
                actionFlags: ioActionFlags,
                timestamp: inTimeStamp,
                bus: 1,
                frameCount: inNumberFrames,
                data: ablPtr
            )
        }
        guard renderStatus == noErr else {
            state.recordRenderFailure(renderStatus)
            return renderStatus
        }
    } else {
        var bufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: 1, mDataByteSize: byteSize,
                mData: UnsafeMutableRawPointer(leftBuf))
        )
        let status = state.audioUnitRuntime.render(
            unit,
            actionFlags: ioActionFlags,
            timestamp: inTimeStamp,
            bus: 1,
            frameCount: inNumberFrames,
            data: &bufferList
        )
        guard status == noErr else {
            state.recordRenderFailure(status)
            return status
        }
        memcpy(rightBuf, leftBuf, frameCount * MemoryLayout<Float>.stride)
    }

    // Batch-read parameters (single lock acquisition)
    let params = state.getParams()

    // Sync EQ state to check if DSP is needed
    state.syncEQCoefficients()
    let eqActive = state.cachedEqActive
    let gainActive = params.gain != 1.0

    // Clean passthrough when no processing is engaged (Audacity-style transparent
    // wire). The DC filter is only needed for EQ, while the limiter protects any
    // boosted path (EQ and/or gain).
    if eqActive {
        // DC offset removal — first-order high-pass (~20 Hz)
        // Only needed when EQ is active (boosted bands can amplify DC from preamp)
        let filterCoefficient = state.dcFilterR
        var lpx = state.dcLeftPrevX
        var lpy = state.dcLeftPrevY
        var rpx = state.dcRightPrevX
        var rpy = state.dcRightPrevY

        for i in 0..<frameCount {
            let lx = leftBuf[i]
            lpy = lx - lpx + filterCoefficient * lpy
            lpx = lx
            leftBuf[i] = lpy
            let rx = rightBuf[i]
            rpy = rx - rpx + filterCoefficient * rpy
            rpx = rx
            rightBuf[i] = rpy
        }
        state.dcLeftPrevX = lpx
        state.dcLeftPrevY = lpy
        state.dcRightPrevX = rpx
        state.dcRightPrevY = rpy
    }

    // Apply gain
    if gainActive {
        var g = params.gain
        vDSP_vsmul(leftBuf, 1, &g, leftBuf, 1, vDSP_Length(frameCount))
        vDSP_vsmul(rightBuf, 1, &g, rightBuf, 1, vDSP_Length(frameCount))
    }

    // Apply 10-band parametric EQ
    if eqActive {
        applyEQ(leftBuf, count: frameCount, coeffs: state.eqCoeffs, state: state.eqStateL)
        applyEQ(rightBuf, count: frameCount, coeffs: state.eqCoeffs, state: state.eqStateR)

        // Soft limiter — EQ boosts can clip even at unity gain.
        applySoftLimiter(leftBuf, count: frameCount)
        applySoftLimiter(rightBuf, count: frameCount)
    } else if params.gain > 1 {
        // Gain is applied once above; protect every boosted path, including
        // headless recording/streaming with a flat EQ.
        applySoftLimiter(leftBuf, count: frameCount)
        applySoftLimiter(rightBuf, count: frameCount)
    }

    // Metering — average RMS of both channels
    if params.meteringEnabled {
        var leftRms: Float = 0
        var rightRms: Float = 0
        vDSP_rmsqv(leftBuf, 1, &leftRms, vDSP_Length(frameCount))
        vDSP_rmsqv(rightBuf, 1, &rightRms, vDSP_Length(frameCount))
        // Peak-based control must not add 6 dB simply because only one input
        // of a stereo interface carries signal.
        state.updatePeak(rms: max(leftRms, rightRms), gain: 1)
    }

    // One allocation-free fanout into independent bounded rings for playback,
    // native visualization, continuous analysis, and recording/network work.
    state.writeStereo(
        left: leftBuf,
        right: rightBuf,
        count: frameCount,
        captureTimestampNanoseconds: callbackStart
    )

    return noErr
}

// MARK: - Output Render Callback

nonisolated private func outputRenderCallback(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {

    let context =
        Unmanaged<AudioCallbackContext>
        .fromOpaque(inRefCon)
        .takeUnretainedValue()
    guard let state = context.begin() else {
        if let ioData {
            for buffer in UnsafeMutableAudioBufferListPointer(ioData) {
                if let data = buffer.mData {
                    memset(data, 0, Int(buffer.mDataByteSize))
                }
            }
        }
        return noErr
    }
    defer { context.end() }
    guard let bufferListPtr = ioData else { return noErr }

    let frameCount = Int(inNumberFrames)
    let bufferList = UnsafeMutableAudioBufferListPointer(bufferListPtr)

    guard bufferList.count >= 1,
        let ch0 = bufferList[0].mData?.assumingMemoryBound(to: Float.self)
    else {
        return noErr
    }
    guard frameCount + 1 <= state.outputCapacity else {
        for buffer in bufferList {
            if let data = buffer.mData {
                memset(data, 0, Int(buffer.mDataByteSize))
            }
        }
        return kAudio_ParamError
    }

    let volume = state.getParams().volume

    // Drift compensation: only needed when input/output are on different devices
    // (different clock domains). Same-device shares one clock — no drift possible.
    var framesToRead = frameCount
    if !state.sameDevice {
        let fill = state.ringFillLevel()
        if fill > AudioConfig.driftTarget + AudioConfig.driftThreshold {
            framesToRead = frameCount + 1
        } else if fill > 0, fill < AudioConfig.driftTarget - AudioConfig.driftThreshold {
            framesToRead = max(frameCount - 1, 1)
        }
    }

    let tempL = state.workOutL
    let tempR = state.workOutR

    if bufferList.count >= 2, let ch1 = bufferList[1].mData?.assumingMemoryBound(to: Float.self) {
        // Stereo output
        let read = state.readStereo(left: tempL, right: tempR, count: framesToRead)

        if read == frameCount {
            memcpy(ch0, tempL, frameCount * MemoryLayout<Float>.stride)
            memcpy(ch1, tempR, frameCount * MemoryLayout<Float>.stride)
        } else if read > 0 {
            cubicResample(src: tempL, srcCount: read, dst: ch0, dstCount: frameCount)
            cubicResample(src: tempR, srcCount: read, dst: ch1, dstCount: frameCount)
        } else {
            memset(ch0, 0, frameCount * MemoryLayout<Float>.stride)
            memset(ch1, 0, frameCount * MemoryLayout<Float>.stride)
        }

        if volume != 1.0 {
            var vol = volume
            vDSP_vsmul(ch0, 1, &vol, ch0, 1, vDSP_Length(frameCount))
            vDSP_vsmul(ch1, 1, &vol, ch1, 1, vDSP_Length(frameCount))
        }
    } else {
        // Mono output — read stereo and sum
        let read = state.readStereo(left: tempL, right: tempR, count: framesToRead)

        if read > 0 {
            vDSP_vadd(tempL, 1, tempR, 1, tempL, 1, vDSP_Length(read))
            var half: Float = 0.5
            vDSP_vsmul(tempL, 1, &half, tempL, 1, vDSP_Length(read))

            if read == frameCount {
                memcpy(ch0, tempL, frameCount * MemoryLayout<Float>.stride)
            } else {
                cubicResample(src: tempL, srcCount: read, dst: ch0, dstCount: frameCount)
            }
        } else {
            memset(ch0, 0, frameCount * MemoryLayout<Float>.stride)
        }

        if volume != 1.0 {
            var vol = volume
            vDSP_vsmul(ch0, 1, &vol, ch0, 1, vDSP_Length(frameCount))
        }
    }

    // Silence extra channels
    if bufferList.count > 2 {
        for i in 2..<bufferList.count {
            if let chData = bufferList[i].mData {
                memset(chData, 0, Int(bufferList[i].mDataByteSize))
            }
        }
    }

    return noErr
}
