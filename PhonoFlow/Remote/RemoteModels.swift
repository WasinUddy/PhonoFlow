//
//  RemoteModels.swift
//  PhonoFlow
//
//  Framework-neutral wire models for the paired LAN remote-control API.
//

import Foundation

nonisolated public enum RemoteEnginePhase: String, Codable, Sendable {
    case idle
    case starting
    case running
    case disconnected
    case failed
}

nonisolated public struct RemoteAudioFormat: Codable, Sendable, Equatable {
    public var sampleRate: Double
    public var channelCount: Int
    public var bufferFrameCount: Int

    public init(sampleRate: Double, channelCount: Int, bufferFrameCount: Int) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.bufferFrameCount = bufferFrameCount
    }
}

nonisolated public struct RemoteProblemSummary: Codable, Sendable, Equatable {
    public var code: String
    public var title: String
    public var detail: String

    public init(code: String, title: String, detail: String) {
        self.code = code
        self.title = title
        self.detail = detail
    }
}

nonisolated public struct RemoteEngineState: Codable, Sendable, Equatable {
    public var phase: RemoteEnginePhase
    public var format: RemoteAudioFormat?
    public var problem: RemoteProblemSummary?

    public init(
        phase: RemoteEnginePhase,
        format: RemoteAudioFormat? = nil,
        problem: RemoteProblemSummary? = nil
    ) {
        self.phase = phase
        self.format = format
        self.problem = problem
    }
}

nonisolated public enum RemoteDeviceConnectionState: String, Codable, Sendable {
    case connected
    case disconnected
}

nonisolated public enum RemoteDeviceTransport: String, Codable, Sendable {
    case builtIn
    case usb
    case thunderbolt
    case bluetooth
    case virtual
    case aggregate
    case unknown
}

nonisolated public struct RemoteInputRoute: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var label: String
    /// Zero-based CoreAudio channel indices. Stereo routes always contain two values.
    public var channels: [Int]

    public init(id: String, label: String, channels: [Int]) {
        self.id = id
        self.label = label
        self.channels = channels
    }
}

nonisolated public struct RemoteAudioDevice: Codable, Sendable, Equatable, Identifiable {
    public var id: String { uid }
    public var uid: String
    public var name: String
    public var inputChannelCount: Int
    public var outputChannelCount: Int
    public var inputRoutes: [RemoteInputRoute]
    public var supportedSampleRates: [Double]
    public var transport: RemoteDeviceTransport
    public var connectionState: RemoteDeviceConnectionState

    public init(
        uid: String,
        name: String,
        inputChannelCount: Int,
        outputChannelCount: Int,
        inputRoutes: [RemoteInputRoute],
        supportedSampleRates: [Double],
        transport: RemoteDeviceTransport,
        connectionState: RemoteDeviceConnectionState
    ) {
        self.uid = uid
        self.name = name
        self.inputChannelCount = inputChannelCount
        self.outputChannelCount = outputChannelCount
        self.inputRoutes = inputRoutes
        self.supportedSampleRates = supportedSampleRates
        self.transport = transport
        self.connectionState = connectionState
    }
}

nonisolated public struct RemoteAudioSelection: Codable, Sendable, Equatable {
    public var inputUID: String
    public var inputRouteID: String
    public var outputUID: String?

    public init(inputUID: String, inputRouteID: String, outputUID: String? = nil) {
        self.inputUID = inputUID
        self.inputRouteID = inputRouteID
        self.outputUID = outputUID
    }
}

nonisolated public struct RemoteMeterSnapshot: Codable, Sendable, Equatable {
    /// Linear values in the inclusive range 0...1.
    public var left: Float
    public var right: Float
    public var peak: Float
    public var sequence: UInt64
    public var timestamp: Date

    public init(left: Float, right: Float, peak: Float, sequence: UInt64 = 0, timestamp: Date = Date()) {
        self.left = left
        self.right = right
        self.peak = peak
        self.sequence = sequence
        self.timestamp = timestamp
    }
}

nonisolated public struct RemoteProcessingState: Codable, Sendable, Equatable {
    public var gain: Float
    public var autoGainEnabled: Bool
    public var enabled: Bool

    public init(gain: Float, autoGainEnabled: Bool, enabled: Bool) {
        self.gain = gain
        self.autoGainEnabled = autoGainEnabled
        self.enabled = enabled
    }
}

nonisolated public struct RemoteEqualizerBand: Codable, Sendable, Equatable {
    public var frequencyHz: Float
    public var gainDB: Float

    public init(frequencyHz: Float, gainDB: Float) {
        self.frequencyHz = frequencyHz
        self.gainDB = gainDB
    }
}

nonisolated public struct RemoteEqualizerState: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var bands: [RemoteEqualizerBand]

    public init(enabled: Bool, bands: [RemoteEqualizerBand]) {
        self.enabled = enabled
        self.bands = bands
    }
}

nonisolated public struct RemoteToggleState: Codable, Sendable, Equatable {
    public var enabled: Bool

    public init(enabled: Bool) {
        self.enabled = enabled
    }
}

nonisolated public struct RemoteRadioState: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var listenerCount: Int

    public init(enabled: Bool, listenerCount: Int) {
        self.enabled = enabled
        self.listenerCount = listenerCount
    }
}

nonisolated public struct RemoteRecordingState: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var durationSeconds: Double
    public var fileName: String?

    public init(enabled: Bool, durationSeconds: Double, fileName: String? = nil) {
        self.enabled = enabled
        self.durationSeconds = durationSeconds
        self.fileName = fileName
    }
}

nonisolated public struct RemoteDiagnosticsSnapshot: Codable, Sendable, Equatable {
    public var callbackDurationMicroseconds: Double
    public var xruns: UInt64
    public var ringOverflows: UInt64
    public var ringUnderflows: UInt64
    public var queueDepth: Int
    public var queueDrops: UInt64
    public var fftLatencyMilliseconds: Double
    public var renderSkips: UInt64
    public var imageAgeMilliseconds: Double
    public var memoryBytes: UInt64

    public init(
        callbackDurationMicroseconds: Double = 0,
        xruns: UInt64 = 0,
        ringOverflows: UInt64 = 0,
        ringUnderflows: UInt64 = 0,
        queueDepth: Int = 0,
        queueDrops: UInt64 = 0,
        fftLatencyMilliseconds: Double = 0,
        renderSkips: UInt64 = 0,
        imageAgeMilliseconds: Double = 0,
        memoryBytes: UInt64 = 0
    ) {
        self.callbackDurationMicroseconds = callbackDurationMicroseconds
        self.xruns = xruns
        self.ringOverflows = ringOverflows
        self.ringUnderflows = ringUnderflows
        self.queueDepth = queueDepth
        self.queueDrops = queueDrops
        self.fftLatencyMilliseconds = fftLatencyMilliseconds
        self.renderSkips = renderSkips
        self.imageAgeMilliseconds = imageAgeMilliseconds
        self.memoryBytes = memoryBytes
    }
}

nonisolated public struct RemoteStateSnapshot: Codable, Sendable, Equatable {
    /// Monotonically increases only when authoritative state changes.
    public var revision: UInt64
    public var generatedAt: Date
    public var engine: RemoteEngineState
    public var devices: [RemoteAudioDevice]
    public var selection: RemoteAudioSelection?
    public var meters: RemoteMeterSnapshot
    public var processing: RemoteProcessingState
    public var equalizer: RemoteEqualizerState
    public var monitor: RemoteToggleState
    public var radio: RemoteRadioState
    public var recording: RemoteRecordingState
    public var diagnostics: RemoteDiagnosticsSnapshot

    public init(
        revision: UInt64,
        generatedAt: Date = Date(),
        engine: RemoteEngineState,
        devices: [RemoteAudioDevice],
        selection: RemoteAudioSelection?,
        meters: RemoteMeterSnapshot,
        processing: RemoteProcessingState,
        equalizer: RemoteEqualizerState,
        monitor: RemoteToggleState,
        radio: RemoteRadioState,
        recording: RemoteRecordingState,
        diagnostics: RemoteDiagnosticsSnapshot
    ) {
        self.revision = revision
        self.generatedAt = generatedAt
        self.engine = engine
        self.devices = devices
        self.selection = selection
        self.meters = meters
        self.processing = processing
        self.equalizer = equalizer
        self.monitor = monitor
        self.radio = radio
        self.recording = recording
        self.diagnostics = diagnostics
    }
}

nonisolated public struct RemoteSpectrogramColumn: Codable, Sendable, Equatable {
    public var sequence: UInt64
    public var timestamp: Date
    /// Exactly 64 intensity values, low-to-high frequency, each in 0...255.
    public var intensities: [UInt8]

    public init(sequence: UInt64, timestamp: Date = Date(), intensities: [UInt8]) {
        self.sequence = sequence
        self.timestamp = timestamp
        self.intensities = intensities
    }
}

// MARK: - Mutation payloads

nonisolated public struct RemotePairRequest: Codable, Sendable {
    public var code: String

    public init(code: String) {
        self.code = code
    }
}

nonisolated public struct RemotePairResponse: Codable, Sendable {
    public var expiresAt: Date
    public var state: RemoteStateSnapshot

    public init(expiresAt: Date, state: RemoteStateSnapshot) {
        self.expiresAt = expiresAt
        self.state = state
    }
}

nonisolated public struct RemoteBooleanCommand: Codable, Sendable, Equatable {
    public var enabled: Bool

    public init(enabled: Bool) {
        self.enabled = enabled
    }
}

nonisolated public struct RemoteProcessingCommand: Codable, Sendable, Equatable {
    public var gain: Float?
    public var autoGainEnabled: Bool?
    public var enabled: Bool?

    public init(gain: Float? = nil, autoGainEnabled: Bool? = nil, enabled: Bool? = nil) {
        self.gain = gain
        self.autoGainEnabled = autoGainEnabled
        self.enabled = enabled
    }
}

nonisolated public struct RemoteEqualizerCommand: Codable, Sendable, Equatable {
    public var enabled: Bool?
    public var bands: [RemoteEqualizerBand]?

    public init(enabled: Bool? = nil, bands: [RemoteEqualizerBand]? = nil) {
        self.enabled = enabled
        self.bands = bands
    }
}

nonisolated public enum RemoteControlCommand: Sendable, Equatable {
    case refreshDevices
    case selectAudio(RemoteAudioSelection)
    case setMonitor(RemoteBooleanCommand)
    case setProcessing(RemoteProcessingCommand)
    case setEqualizer(RemoteEqualizerCommand)
    case setRadio(RemoteBooleanCommand)
    case setRecording(RemoteBooleanCommand)
}

/// The app's `@MainActor AppCoordinator` implements this bridge. Network handlers
/// can only request typed, idempotent commands and never mutate UI state directly.
@MainActor
public protocol RemoteControlCoordinating: AnyObject, Sendable {
    func remoteStateSnapshot() -> RemoteStateSnapshot
    func applyRemoteCommand(_ command: RemoteControlCommand) async throws -> RemoteStateSnapshot
}

nonisolated public struct RemoteControlFailure: Error, Sendable {
    public enum Kind: Sendable {
        case conflict
        case invalid
        case unavailable
        case forbidden
    }

    public var kind: Kind
    public var code: String
    public var detail: String

    public init(kind: Kind, code: String, detail: String) {
        self.kind = kind
        self.code = code
        self.detail = detail
    }
}
