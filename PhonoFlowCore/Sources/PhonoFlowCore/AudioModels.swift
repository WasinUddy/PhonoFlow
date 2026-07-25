import Foundation

// MARK: - Validation

/// Errors raised when an audio model would otherwise contain an invalid or
/// unsafe value.
public enum AudioModelValidationError: Error, LocalizedError, Codable, Sendable, Equatable {
    case emptyIdentifier(field: String)
    case invalidChannelCount(Int)
    case invalidChannelMap([Int])
    case channelOutOfRange(channel: Int, channelCount: Int)
    case invalidSampleRate(Double)
    case invalidBufferFrameRange(minimum: Int, maximum: Int)
    case invalidMaximumFramesPerSlice(Int)
    case duplicateRouteIdentifier(String)
    case routeDoesNotBelongToDevice(routeID: String)

    public var errorDescription: String? {
        switch self {
        case .emptyIdentifier(let field):
            "\(field) must not be empty."
        case .invalidChannelCount(let count):
            "Channel count must not be negative; received \(count)."
        case .invalidChannelMap(let channels):
            "A stereo client channel map must contain exactly two non-negative source channels; received \(channels)."
        case .channelOutOfRange(let channel, let channelCount):
            "Source channel \(channel) is outside the device's \(channelCount)-channel input range."
        case .invalidSampleRate(let rate):
            "Sample rate must be finite and greater than zero; received \(rate)."
        case .invalidBufferFrameRange(let minimum, let maximum):
            "Buffer-frame range is invalid: \(minimum)...\(maximum)."
        case .invalidMaximumFramesPerSlice(let count):
            "Maximum frames per slice must be greater than zero; received \(count)."
        case .duplicateRouteIdentifier(let identifier):
            "Input route identifier \(identifier) is duplicated."
        case .routeDoesNotBelongToDevice(let routeID):
            "Input route \(routeID) references a channel that is not available on the device."
        }
    }
}

@inline(__always)
private func validatedIdentifier(_ value: String, field: String) throws -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        throw AudioModelValidationError.emptyIdentifier(field: field)
    }
    return trimmed
}

// MARK: - Channels and routes

/// The two hardware input channels presented to PhonoFlow's stereo client
/// format. Channel indices are zero-based, matching Core Audio.
public struct AudioChannelMap: Codable, Sendable, Hashable {
    public let sourceChannels: [Int]

    public init(sourceChannels: [Int]) throws {
        guard sourceChannels.count == 2, sourceChannels.allSatisfy({ $0 >= 0 }) else {
            throw AudioModelValidationError.invalidChannelMap(sourceChannels)
        }
        self.sourceChannels = sourceChannels
    }

    /// The default map for a device. A mono source is copied to both client
    /// channels; devices with two or more inputs use their first pair.
    public static func defaultMap(inputChannelCount: Int) throws -> Self {
        guard inputChannelCount >= 0 else {
            throw AudioModelValidationError.invalidChannelCount(inputChannelCount)
        }
        guard inputChannelCount > 0 else {
            throw AudioModelValidationError.channelOutOfRange(channel: 0, channelCount: 0)
        }

        return try Self(sourceChannels: inputChannelCount == 1 ? [0, 0] : [0, 1])
    }

    /// Produces a consecutive route starting at `firstChannel`. If the final
    /// channel is unpaired, it is duplicated so that it remains selectable.
    public static func route(
        startingAt firstChannel: Int,
        inputChannelCount: Int
    ) throws -> Self {
        guard inputChannelCount >= 0 else {
            throw AudioModelValidationError.invalidChannelCount(inputChannelCount)
        }
        guard firstChannel >= 0, firstChannel < inputChannelCount else {
            throw AudioModelValidationError.channelOutOfRange(
                channel: firstChannel,
                channelCount: inputChannelCount
            )
        }

        let secondChannel = min(firstChannel + 1, inputChannelCount - 1)
        return try Self(sourceChannels: [firstChannel, secondChannel])
    }

    public func validate(inputChannelCount: Int) throws {
        guard inputChannelCount >= 0 else {
            throw AudioModelValidationError.invalidChannelCount(inputChannelCount)
        }

        for channel in sourceChannels where channel >= inputChannelCount {
            throw AudioModelValidationError.channelOutOfRange(
                channel: channel,
                channelCount: inputChannelCount
            )
        }
    }

    /// A directly consumable AUHAL channel-map value.
    public var coreAudioChannels: [Int32] {
        sourceChannels.map { Int32($0) }
    }

    private enum CodingKeys: String, CodingKey {
        case sourceChannels
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let channels = try container.decode([Int].self, forKey: .sourceChannels)

        do {
            try self.init(sourceChannels: channels)
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .sourceChannels,
                in: container,
                debugDescription: error.localizedDescription
            )
        }
    }
}

/// A stable, persistable input route independent of Core Audio's transient
/// `AudioDeviceID`.
public struct AudioInputRoute: Identifiable, Codable, Sendable, Hashable {
    public let id: String
    public let name: String
    public let channelMap: AudioChannelMap

    public init(id: String, name: String, channelMap: AudioChannelMap) throws {
        self.id = try validatedIdentifier(id, field: "Input route ID")
        self.name = try validatedIdentifier(name, field: "Input route name")
        self.channelMap = channelMap
    }

    /// Builds stable, non-overlapping input routes. Hardware-provided channel
    /// names are used when present; otherwise labels such as “Inputs 1–2” are
    /// generated.
    public static func generate(
        inputChannelCount: Int,
        channelNames: [String] = []
    ) throws -> [Self] {
        guard inputChannelCount >= 0 else {
            throw AudioModelValidationError.invalidChannelCount(inputChannelCount)
        }
        guard inputChannelCount > 0 else { return [] }

        let resolvedNames = resolvedChannelNames(
            count: inputChannelCount,
            suppliedNames: channelNames,
            fallbackPrefix: "Input"
        )
        let hasHardwareName = (0..<inputChannelCount).map { index in
            guard channelNames.indices.contains(index) else { return false }
            return !channelNames[index].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        return try stride(from: 0, to: inputChannelCount, by: 2).map { firstChannel in
            let map = try AudioChannelMap.route(
                startingAt: firstChannel,
                inputChannelCount: inputChannelCount
            )
            let secondChannel = map.sourceChannels[1]
            let isMono = firstChannel == secondChannel
            let id = "channels-\(firstChannel + 1)-\(secondChannel + 1)"

            let name: String
            if isMono {
                name = resolvedNames[firstChannel]
            } else if hasHardwareName[firstChannel] || hasHardwareName[secondChannel] {
                name = "\(resolvedNames[firstChannel]) / \(resolvedNames[secondChannel])"
            } else {
                name = "Inputs \(firstChannel + 1)–\(secondChannel + 1)"
            }

            return try Self(id: id, name: name, channelMap: map)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case channelMap
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        do {
            try self.init(
                id: container.decode(String.self, forKey: .id),
                name: container.decode(String.self, forKey: .name),
                channelMap: container.decode(AudioChannelMap.self, forKey: .channelMap)
            )
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .id,
                in: container,
                debugDescription: error.localizedDescription
            )
        }
    }
}

private func resolvedChannelNames(
    count: Int,
    suppliedNames: [String],
    fallbackPrefix: String
) -> [String] {
    (0..<count).map { index in
        if suppliedNames.indices.contains(index) {
            let name = suppliedNames[index].trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                return name
            }
        }
        return "\(fallbackPrefix) \(index + 1)"
    }
}

// MARK: - Device description

public enum AudioDeviceTransport: String, Codable, Sendable, CaseIterable {
    case builtIn
    case usb
    case thunderbolt
    case fireWire
    case bluetooth
    case bluetoothLE
    case hdmi
    case displayPort
    case airPlay
    case avb
    case pci
    case aggregate
    case virtual
    case unknown
}

public enum AudioDeviceConnectionState: String, Codable, Sendable {
    case connected
    case disconnected
    case unavailable
}

public struct AudioBufferFrameRange: Codable, Sendable, Hashable {
    public let minimum: Int
    public let maximum: Int

    public init(minimum: Int, maximum: Int) throws {
        guard minimum > 0, maximum >= minimum else {
            throw AudioModelValidationError.invalidBufferFrameRange(
                minimum: minimum,
                maximum: maximum
            )
        }
        self.minimum = minimum
        self.maximum = maximum
    }

    public func contains(_ frameCount: Int) -> Bool {
        minimum...maximum ~= frameCount
    }

    private enum CodingKeys: String, CodingKey {
        case minimum
        case maximum
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        do {
            try self.init(
                minimum: container.decode(Int.self, forKey: .minimum),
                maximum: container.decode(Int.self, forKey: .maximum)
            )
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .minimum,
                in: container,
                debugDescription: error.localizedDescription
            )
        }
    }
}

/// Stable metadata for a Core Audio device. The UID is the public identity;
/// transient numeric device IDs intentionally do not appear in this model.
public struct AudioDeviceDescriptor: Identifiable, Codable, Sendable, Hashable {
    public var id: String { uid }

    public let uid: String
    public let name: String
    public let inputChannelCount: Int
    public let outputChannelCount: Int
    public let inputChannelNames: [String]
    public let outputChannelNames: [String]
    public let inputRoutes: [AudioInputRoute]
    public let supportedSampleRates: [Double]
    public let bufferFrameRange: AudioBufferFrameRange?
    public let transport: AudioDeviceTransport
    public let connectionState: AudioDeviceConnectionState

    public var isInputCapable: Bool { inputChannelCount > 0 }
    public var isOutputCapable: Bool { outputChannelCount > 0 }

    public init(
        uid: String,
        name: String,
        inputChannelCount: Int,
        outputChannelCount: Int,
        inputChannelNames: [String] = [],
        outputChannelNames: [String] = [],
        inputRoutes: [AudioInputRoute]? = nil,
        supportedSampleRates: [Double] = [],
        bufferFrameRange: AudioBufferFrameRange? = nil,
        transport: AudioDeviceTransport = .unknown,
        connectionState: AudioDeviceConnectionState = .connected
    ) throws {
        guard inputChannelCount >= 0 else {
            throw AudioModelValidationError.invalidChannelCount(inputChannelCount)
        }
        guard outputChannelCount >= 0 else {
            throw AudioModelValidationError.invalidChannelCount(outputChannelCount)
        }

        let normalizedRates = Array(Set(supportedSampleRates)).sorted()
        if let invalidRate = normalizedRates.first(where: { !$0.isFinite || $0 <= 0 }) {
            throw AudioModelValidationError.invalidSampleRate(invalidRate)
        }

        let resolvedRoutes =
            try inputRoutes
            ?? AudioInputRoute.generate(
                inputChannelCount: inputChannelCount,
                channelNames: inputChannelNames
            )
        var routeIDs = Set<String>()
        for route in resolvedRoutes {
            guard routeIDs.insert(route.id).inserted else {
                throw AudioModelValidationError.duplicateRouteIdentifier(route.id)
            }
            do {
                try route.channelMap.validate(inputChannelCount: inputChannelCount)
            } catch {
                throw AudioModelValidationError.routeDoesNotBelongToDevice(routeID: route.id)
            }
        }

        self.uid = try validatedIdentifier(uid, field: "Audio device UID")
        self.name = try validatedIdentifier(name, field: "Audio device name")
        self.inputChannelCount = inputChannelCount
        self.outputChannelCount = outputChannelCount
        self.inputChannelNames = resolvedChannelNames(
            count: inputChannelCount,
            suppliedNames: inputChannelNames,
            fallbackPrefix: "Input"
        )
        self.outputChannelNames = resolvedChannelNames(
            count: outputChannelCount,
            suppliedNames: outputChannelNames,
            fallbackPrefix: "Output"
        )
        self.inputRoutes = resolvedRoutes
        self.supportedSampleRates = normalizedRates
        self.bufferFrameRange = bufferFrameRange
        self.transport = transport
        self.connectionState = connectionState
    }

    public func inputRoute(id: String) -> AudioInputRoute? {
        inputRoutes.first { $0.id == id }
    }

    private enum CodingKeys: String, CodingKey {
        case uid
        case name
        case inputChannelCount
        case outputChannelCount
        case inputChannelNames
        case outputChannelNames
        case inputRoutes
        case supportedSampleRates
        case bufferFrameRange
        case transport
        case connectionState
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        do {
            try self.init(
                uid: container.decode(String.self, forKey: .uid),
                name: container.decode(String.self, forKey: .name),
                inputChannelCount: container.decode(Int.self, forKey: .inputChannelCount),
                outputChannelCount: container.decode(Int.self, forKey: .outputChannelCount),
                inputChannelNames: container.decode([String].self, forKey: .inputChannelNames),
                outputChannelNames: container.decode([String].self, forKey: .outputChannelNames),
                inputRoutes: container.decode([AudioInputRoute].self, forKey: .inputRoutes),
                supportedSampleRates: container.decode([Double].self, forKey: .supportedSampleRates),
                bufferFrameRange: container.decodeIfPresent(
                    AudioBufferFrameRange.self,
                    forKey: .bufferFrameRange
                ),
                transport: container.decode(AudioDeviceTransport.self, forKey: .transport),
                connectionState: container.decode(
                    AudioDeviceConnectionState.self,
                    forKey: .connectionState
                )
            )
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .uid,
                in: container,
                debugDescription: error.localizedDescription
            )
        }
    }
}

// MARK: - Selection and negotiated format

/// The complete public device selection. A nil output keeps capture, analysis,
/// recording, and streaming active without local monitoring.
public struct AudioDeviceSelection: Codable, Sendable, Hashable {
    public let inputUID: String
    public let inputRouteID: String
    public let outputUID: String?

    public init(inputUID: String, inputRouteID: String, outputUID: String? = nil) throws {
        self.inputUID = try validatedIdentifier(inputUID, field: "Input device UID")
        self.inputRouteID = try validatedIdentifier(inputRouteID, field: "Input route ID")
        if let outputUID {
            self.outputUID = try validatedIdentifier(outputUID, field: "Output device UID")
        } else {
            self.outputUID = nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case inputUID
        case inputRouteID
        case outputUID
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        do {
            try self.init(
                inputUID: container.decode(String.self, forKey: .inputUID),
                inputRouteID: container.decode(String.self, forKey: .inputRouteID),
                outputUID: container.decodeIfPresent(String.self, forKey: .outputUID)
            )
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .inputUID,
                in: container,
                debugDescription: error.localizedDescription
            )
        }
    }
}

public enum AudioSampleFormat: String, Codable, Sendable {
    case float32
    case pcmInt16
    case pcmInt24
    case pcmInt32

    public var bitsPerSample: Int {
        switch self {
        case .float32, .pcmInt32: 32
        case .pcmInt16: 16
        case .pcmInt24: 24
        }
    }
}

/// The client format actually negotiated with the audio engine.
public struct AudioStreamFormat: Codable, Sendable, Hashable {
    public let sampleRate: Double
    public let channelCount: Int
    public let sampleFormat: AudioSampleFormat
    public let isInterleaved: Bool
    public let maximumFramesPerSlice: Int

    public init(
        sampleRate: Double,
        channelCount: Int,
        sampleFormat: AudioSampleFormat = .float32,
        isInterleaved: Bool = false,
        maximumFramesPerSlice: Int
    ) throws {
        guard sampleRate.isFinite, sampleRate > 0 else {
            throw AudioModelValidationError.invalidSampleRate(sampleRate)
        }
        guard channelCount > 0 else {
            throw AudioModelValidationError.invalidChannelCount(channelCount)
        }
        guard maximumFramesPerSlice > 0 else {
            throw AudioModelValidationError.invalidMaximumFramesPerSlice(maximumFramesPerSlice)
        }

        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.sampleFormat = sampleFormat
        self.isInterleaved = isInterleaved
        self.maximumFramesPerSlice = maximumFramesPerSlice
    }

    private enum CodingKeys: String, CodingKey {
        case sampleRate
        case channelCount
        case sampleFormat
        case isInterleaved
        case maximumFramesPerSlice
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        do {
            try self.init(
                sampleRate: container.decode(Double.self, forKey: .sampleRate),
                channelCount: container.decode(Int.self, forKey: .channelCount),
                sampleFormat: container.decode(AudioSampleFormat.self, forKey: .sampleFormat),
                isInterleaved: container.decode(Bool.self, forKey: .isInterleaved),
                maximumFramesPerSlice: container.decode(
                    Int.self,
                    forKey: .maximumFramesPerSlice
                )
            )
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .sampleRate,
                in: container,
                debugDescription: error.localizedDescription
            )
        }
    }
}

// MARK: - Engine state and failures

public enum AudioEngineFailureCode: String, Codable, Sendable {
    case microphonePermissionDenied
    case deviceUnavailable
    case unsupportedFormat
    case invalidChannelMap
    case propertyReadFailed
    case propertyWriteFailed
    case audioUnitCreationFailed
    case audioUnitInitializationFailed
    case audioUnitStartFailed
    case renderFailed
    case recordingConflict
    case internalError
}

/// A serializable error safe to expose to both the native UI and remote API.
public struct AudioEngineFailure: Error, LocalizedError, Codable, Sendable, Hashable {
    public let code: AudioEngineFailureCode
    public let message: String
    public let recoverySuggestion: String?
    public let osStatus: Int32?
    public let deviceUID: String?

    public init(
        code: AudioEngineFailureCode,
        message: String,
        recoverySuggestion: String? = nil,
        osStatus: Int32? = nil,
        deviceUID: String? = nil
    ) {
        self.code = code
        self.message = message
        self.recoverySuggestion = recoverySuggestion
        self.osStatus = osStatus
        self.deviceUID = deviceUID
    }

    public var errorDescription: String? { message }
}

/// The authoritative capture-engine state. Its custom Codable representation
/// is a stable discriminated object (`state`, then `format` or `error`).
public enum AudioEngineState: Sendable, Hashable {
    case idle
    case starting
    case running(AudioStreamFormat)
    case disconnected
    case failed(AudioEngineFailure)

    public enum Kind: String, Codable, Sendable {
        case idle
        case starting
        case running
        case disconnected
        case failed
    }

    public var kind: Kind {
        switch self {
        case .idle: .idle
        case .starting: .starting
        case .running: .running
        case .disconnected: .disconnected
        case .failed: .failed
        }
    }

    public var runningFormat: AudioStreamFormat? {
        guard case .running(let format) = self else { return nil }
        return format
    }

    public var failure: AudioEngineFailure? {
        guard case .failed(let error) = self else { return nil }
        return error
    }

    public var isRunning: Bool {
        kind == .running
    }
}

extension AudioEngineState: Codable {
    private enum CodingKeys: String, CodingKey {
        case state
        case format
        case error
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .state)

        switch kind {
        case .idle:
            self = .idle
        case .starting:
            self = .starting
        case .running:
            self = .running(try container.decode(AudioStreamFormat.self, forKey: .format))
        case .disconnected:
            self = .disconnected
        case .failed:
            self = .failed(try container.decode(AudioEngineFailure.self, forKey: .error))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .state)

        switch self {
        case .running(let format):
            try container.encode(format, forKey: .format)
        case .failed(let error):
            try container.encode(error, forKey: .error)
        case .idle, .starting, .disconnected:
            break
        }
    }
}

// MARK: - Remote API problems

public enum APIProblemCode: String, Codable, Sendable {
    case invalidRequest
    case authenticationRequired
    case invalidPairingCode
    case forbidden
    case rateLimited
    case routeNotFound
    case methodNotAllowed
    case recordingInProgress
    case validationFailed
    case deviceUnavailable
    case engineUnavailable
    case internalError
}

public struct APIFieldViolation: Codable, Sendable, Hashable {
    public let field: String
    public let reason: String

    public init(field: String, reason: String) {
        self.field = field
        self.reason = reason
    }
}

/// RFC 9457-compatible problem details with a stable machine-readable code.
public struct APIProblem: Error, LocalizedError, Codable, Sendable, Hashable {
    public let type: String
    public let title: String
    public let status: Int
    public let detail: String?
    public let instance: String?
    public let code: APIProblemCode
    public let violations: [APIFieldViolation]

    public init(
        type: String = "about:blank",
        title: String,
        status: Int,
        detail: String? = nil,
        instance: String? = nil,
        code: APIProblemCode,
        violations: [APIFieldViolation] = []
    ) {
        self.type = type
        self.title = title
        self.status = status
        self.detail = detail
        self.instance = instance
        self.code = code
        self.violations = violations
    }

    public var errorDescription: String? {
        detail ?? title
    }

    public static func unauthorized(
        code: APIProblemCode = .authenticationRequired,
        detail: String? = nil
    ) -> Self {
        Self(title: "Unauthorized", status: 401, detail: detail, code: code)
    }

    public static func forbidden(detail: String? = nil) -> Self {
        Self(title: "Forbidden", status: 403, detail: detail, code: .forbidden)
    }

    public static func notFound(detail: String? = nil) -> Self {
        Self(title: "Not Found", status: 404, detail: detail, code: .routeNotFound)
    }

    public static func methodNotAllowed(detail: String? = nil) -> Self {
        Self(
            title: "Method Not Allowed",
            status: 405,
            detail: detail,
            code: .methodNotAllowed
        )
    }

    public static func conflict(
        code: APIProblemCode = .recordingInProgress,
        detail: String? = nil
    ) -> Self {
        Self(title: "Conflict", status: 409, detail: detail, code: code)
    }

    public static func unprocessableEntity(
        detail: String? = nil,
        violations: [APIFieldViolation] = []
    ) -> Self {
        Self(
            title: "Unprocessable Entity",
            status: 422,
            detail: detail,
            code: .validationFailed,
            violations: violations
        )
    }

    public static func serviceUnavailable(
        code: APIProblemCode = .engineUnavailable,
        detail: String? = nil
    ) -> Self {
        Self(title: "Service Unavailable", status: 503, detail: detail, code: code)
    }
}
