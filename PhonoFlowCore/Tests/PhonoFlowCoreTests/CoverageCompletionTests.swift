import Foundation
import Testing

@testable import PhonoFlowCore

@Suite("Audio model edge coverage")
struct AudioModelEdgeCoverageTests {
    @Test("Every validation error has an actionable description")
    func validationDescriptions() {
        let errors: [AudioModelValidationError] = [
            .emptyIdentifier(field: "UID"),
            .invalidChannelCount(-1),
            .invalidChannelMap([0]),
            .channelOutOfRange(channel: 3, channelCount: 2),
            .invalidSampleRate(0),
            .invalidBufferFrameRange(minimum: 0, maximum: 1),
            .invalidMaximumFramesPerSlice(0),
            .duplicateRouteIdentifier("pair"),
            .routeDoesNotBelongToDevice(routeID: "pair"),
        ]

        for error in errors {
            #expect(!(error.errorDescription ?? "").isEmpty)
        }
    }

    @Test("Negative channel counts and empty devices are rejected consistently")
    func channelCountEdges() throws {
        #expect(throws: AudioModelValidationError.invalidChannelCount(-1)) {
            try AudioChannelMap.defaultMap(inputChannelCount: -1)
        }
        #expect(throws: AudioModelValidationError.invalidChannelCount(-1)) {
            try AudioChannelMap.route(startingAt: 0, inputChannelCount: -1)
        }

        let map = try AudioChannelMap(sourceChannels: [0, 1])
        #expect(throws: AudioModelValidationError.invalidChannelCount(-1)) {
            try map.validate(inputChannelCount: -1)
        }
        #expect(map.coreAudioChannels == [0, 1])

        #expect(try AudioInputRoute.generate(inputChannelCount: 0).isEmpty)
        #expect(throws: AudioModelValidationError.invalidChannelCount(-1)) {
            try AudioInputRoute.generate(inputChannelCount: -1)
        }
    }

    @Test("Route decoding executes valid and validation-failure paths")
    func routeCodable() throws {
        let route = try AudioInputRoute(
            id: " channels-1-2 ",
            name: " Analogue ",
            channelMap: AudioChannelMap(sourceChannels: [0, 1])
        )
        let decoded = try JSONDecoder().decode(
            AudioInputRoute.self,
            from: JSONEncoder().encode(route)
        )
        #expect(decoded.id == "channels-1-2")
        #expect(decoded.name == "Analogue")

        let invalid = Data(
            #"{"id":"","name":"Input","channelMap":{"sourceChannels":[0,1]}}"#.utf8
        )
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(AudioInputRoute.self, from: invalid)
        }
    }

    @Test("Buffer ranges validate, query, and round-trip")
    func bufferFrameRanges() throws {
        let range = try AudioBufferFrameRange(minimum: 32, maximum: 1_024)
        #expect(range.contains(32))
        #expect(range.contains(512))
        #expect(!range.contains(1_025))
        #expect(
            try JSONDecoder().decode(
                AudioBufferFrameRange.self,
                from: JSONEncoder().encode(range)
            ) == range
        )

        #expect(
            throws: AudioModelValidationError.invalidBufferFrameRange(
                minimum: 0,
                maximum: 1
            )
        ) {
            try AudioBufferFrameRange(minimum: 0, maximum: 1)
        }
        let invalid = Data(#"{"minimum":64,"maximum":32}"#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(AudioBufferFrameRange.self, from: invalid)
        }
    }

    @Test("Device descriptors cover Codable and all validation exits")
    func deviceDescriptorEdges() throws {
        let descriptor = try AudioDeviceDescriptor(
            uid: "device-uid",
            name: "Interface",
            inputChannelCount: 2,
            outputChannelCount: 2,
            inputChannelNames: ["Mic", "Line"],
            outputChannelNames: ["Left", "Right"],
            supportedSampleRates: [44_100, 48_000],
            bufferFrameRange: AudioBufferFrameRange(minimum: 32, maximum: 512),
            transport: .usb,
            connectionState: .disconnected
        )
        let decoded = try JSONDecoder().decode(
            AudioDeviceDescriptor.self,
            from: JSONEncoder().encode(descriptor)
        )
        #expect(decoded == descriptor)

        #expect(throws: AudioModelValidationError.invalidChannelCount(-1)) {
            try AudioDeviceDescriptor(
                uid: "uid",
                name: "Input",
                inputChannelCount: -1,
                outputChannelCount: 0
            )
        }
        #expect(throws: AudioModelValidationError.invalidChannelCount(-1)) {
            try AudioDeviceDescriptor(
                uid: "uid",
                name: "Output",
                inputChannelCount: 0,
                outputChannelCount: -1
            )
        }
        #expect(throws: AudioModelValidationError.invalidSampleRate(0)) {
            try AudioDeviceDescriptor(
                uid: "uid",
                name: "Invalid rate",
                inputChannelCount: 0,
                outputChannelCount: 0,
                supportedSampleRates: [0]
            )
        }

        var object = try #require(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(descriptor)
            ) as? [String: Any]
        )
        object["uid"] = ""
        let invalid = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(AudioDeviceDescriptor.self, from: invalid)
        }
    }

    @Test("Selection and sample formats cover optional and bit-depth branches")
    func selectionAndFormats() throws {
        let selection = try AudioDeviceSelection(
            inputUID: " input ",
            inputRouteID: " route ",
            outputUID: " output "
        )
        #expect(selection.inputUID == "input")
        #expect(selection.inputRouteID == "route")
        #expect(selection.outputUID == "output")

        #expect(AudioSampleFormat.float32.bitsPerSample == 32)
        #expect(AudioSampleFormat.pcmInt16.bitsPerSample == 16)
        #expect(AudioSampleFormat.pcmInt24.bitsPerSample == 24)
        #expect(AudioSampleFormat.pcmInt32.bitsPerSample == 32)

        let invalid = Data(
            #"{"sampleRate":0,"channelCount":2,"sampleFormat":"pcmInt16","isInterleaved":true,"maximumFramesPerSlice":128}"#
                .utf8
        )
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(AudioStreamFormat.self, from: invalid)
        }
    }

    @Test("All engine states encode, decode, and expose matching helpers")
    func engineStates() throws {
        let format = try AudioStreamFormat(
            sampleRate: 48_000,
            channelCount: 2,
            maximumFramesPerSlice: 256
        )
        let failure = AudioEngineFailure(
            code: .renderFailed,
            message: "Render failed"
        )
        let states: [AudioEngineState] = [
            .idle,
            .starting,
            .running(format),
            .disconnected,
            .failed(failure),
        ]
        let expectedKinds: [AudioEngineState.Kind] = [
            .idle, .starting, .running, .disconnected, .failed,
        ]

        for (state, kind) in zip(states, expectedKinds) {
            #expect(state.kind == kind)
            #expect(
                try JSONDecoder().decode(
                    AudioEngineState.self,
                    from: JSONEncoder().encode(state)
                ) == state
            )
        }
        #expect(AudioEngineState.idle.runningFormat == nil)
        #expect(AudioEngineState.idle.failure == nil)
        #expect(failure.errorDescription == "Render failed")
    }

    @Test("Every API problem factory produces its status and description")
    func problemFactories() {
        let problems: [(APIProblem, Int)] = [
            (.unauthorized(detail: "Pair first."), 401),
            (.forbidden(detail: "Wrong origin."), 403),
            (.notFound(detail: "Unknown route."), 404),
            (.methodNotAllowed(detail: "Use PUT."), 405),
            (.conflict(detail: "Recording."), 409),
            (.unprocessableEntity(detail: "Invalid."), 422),
            (.serviceUnavailable(detail: "No device."), 503),
        ]

        for (problem, status) in problems {
            #expect(problem.status == status)
            #expect(problem.errorDescription == problem.detail)
        }
        let fallback = APIProblem(
            title: "Fallback title",
            status: 500,
            code: .internalError
        )
        #expect(fallback.errorDescription == "Fallback title")
    }
}

@Suite("Pairing policy edge coverage")
struct PairingPolicyEdgeCoverageTests {
    private let start = Date(timeIntervalSince1970: 1_750_000_000)

    @Test("System providers cover count validation and secure generation")
    func systemProviders() async throws {
        let clock = SystemPairingClock()
        #expect(await clock.now().timeIntervalSince1970 > 0)

        let randomness = SystemPairingRandomness()
        await #expect(throws: PairingRandomnessError.invalidCount) {
            try await randomness.randomBytes(count: -1)
        }
        #expect(try await randomness.randomBytes(count: 0).isEmpty)
        #expect(try await randomness.randomBytes(count: 16).count == 16)
    }

    @Test("Pairing and signer errors all expose localized descriptions")
    func errorDescriptions() {
        #expect(throws: SessionSignerError.emptySecret) {
            try HMACSHA256SessionSigner(secret: Data())
        }

        let errors: [PairingPolicyError] = [
            .invalidSource,
            .noActiveCode,
            .codeExpired,
            .invalidCode,
            .rateLimited(retryAfter: start),
            .invalidRandomness,
            .randomnessExhausted,
            .malformedSession,
            .invalidSessionSignature,
            .unsupportedSessionVersion,
            .expiredSession,
        ]
        for error in errors {
            #expect(!(error.errorDescription ?? "").isEmpty)
        }
    }

    @Test("No challenge and malformed token shapes are explicit")
    func absentAndMalformed() async throws {
        let policy = PairingPolicy(
            clock: CoverageClock(now: start),
            randomness: CoverageRandomness(responses: []),
            signer: CoverageSigner(signature: Data([1, 2, 3]))
        )
        #expect(await policy.currentChallenge() == nil)

        for token in ["", "one-piece", "a.b", "!.AQID"] {
            await expectCoveragePolicyError(.malformedSession) {
                _ = try await policy.validate(sessionToken: token)
            }
        }
        await expectCoveragePolicyError(.invalidSessionSignature) {
            _ = try await policy.validate(sessionToken: "AAAA.AQ")
        }
    }

    @Test("Signed malformed, unsupported, and invalid-lifetime claims are rejected")
    func signedClaimValidation() async throws {
        let signer = CoverageSigner(signature: Data([1, 2, 3]))
        let policy = PairingPolicy(
            clock: CoverageClock(now: start),
            randomness: CoverageRandomness(responses: []),
            signer: signer
        )

        let malformed = signedCoverageToken(
            payload: Data([0, 0, 0]),
            signature: signer.value
        )
        await expectCoveragePolicyError(.malformedSession) {
            _ = try await policy.validate(sessionToken: malformed)
        }

        let unsupported = SessionClaims(
            version: SessionClaims.currentVersion + 1,
            sessionID: "unsupported",
            issuedAt: start,
            expiresAt: start.addingTimeInterval(60)
        )
        await expectCoveragePolicyError(.unsupportedSessionVersion) {
            _ = try await policy.validate(
                sessionToken: try signedCoverageToken(
                    claims: unsupported,
                    signature: signer.value
                )
            )
        }

        let invalidLifetime = SessionClaims(
            sessionID: "invalid-lifetime",
            issuedAt: start,
            expiresAt: start
        )
        await expectCoveragePolicyError(.expiredSession) {
            _ = try await policy.validate(
                sessionToken: try signedCoverageToken(
                    claims: invalidLifetime,
                    signature: signer.value
                )
            )
        }
    }

    @Test("Wrong random byte counts and rejection exhaustion are typed")
    func randomnessFailures() async throws {
        let shortCodePolicy = PairingPolicy(
            clock: CoverageClock(now: start),
            randomness: CoverageRandomness(responses: [[0, 1, 2]]),
            signer: CoverageSigner(signature: Data([1]))
        )
        await expectCoveragePolicyError(.invalidRandomness) {
            _ = try await shortCodePolicy.generateCode()
        }

        let shortSessionPolicy = PairingPolicy(
            clock: CoverageClock(now: start),
            randomness: CoverageRandomness(
                responses: [[0, 0, 0, 1], [0, 1, 2]]
            ),
            signer: CoverageSigner(signature: Data([1]))
        )
        let challenge = try await shortSessionPolicy.generateCode()
        await expectCoveragePolicyError(.invalidRandomness) {
            _ = try await shortSessionPolicy.pair(
                code: challenge.code,
                source: "192.168.1.1"
            )
        }

        let exhaustedRandomness = CoverageRandomness(
            responses: Array(
                repeating: [0xff, 0xff, 0xff, 0xff],
                count: 128
            )
        )
        let exhaustedPolicy = PairingPolicy(
            clock: CoverageClock(now: start),
            randomness: exhaustedRandomness,
            signer: CoverageSigner(signature: Data([1]))
        )
        await expectCoveragePolicyError(.randomnessExhausted) {
            _ = try await exhaustedPolicy.generateCode()
        }
        #expect(await exhaustedRandomness.requestCount == 128)
    }

    @Test("Source validation rejects long and whitespace-bearing addresses")
    func sourceValidation() async {
        let policy = PairingPolicy(
            clock: CoverageClock(now: start),
            randomness: CoverageRandomness(responses: []),
            signer: CoverageSigner(signature: Data([1]))
        )
        for source in [String(repeating: "a", count: 256), "host name"] {
            await expectCoveragePolicyError(.invalidSource) {
                _ = try await policy.pair(code: "000001", source: source)
            }
        }
    }
}

private actor CoverageClock: PairingClock {
    let timestamp: Date

    init(now: Date) {
        timestamp = now
    }

    func now() -> Date {
        timestamp
    }
}

private actor CoverageRandomness: PairingRandomness {
    private var responses: [[UInt8]]
    private(set) var requestCount = 0

    init(responses: [[UInt8]]) {
        self.responses = responses
    }

    func randomBytes(count: Int) throws -> [UInt8] {
        requestCount += 1
        guard !responses.isEmpty else {
            throw PairingRandomnessError.generationFailed(status: -1)
        }
        return responses.removeFirst()
    }
}

private struct CoverageSigner: SessionSigning {
    let value: Data

    init(signature: Data) {
        value = signature
    }

    func signature(for message: Data) throws -> Data {
        _ = message
        return value
    }
}

private func signedCoverageToken(
    payload: Data,
    signature: Data
) -> String {
    "\(coverageBase64URL(payload)).\(coverageBase64URL(signature))"
}

private func signedCoverageToken(
    claims: SessionClaims,
    signature: Data
) throws -> String {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return signedCoverageToken(
        payload: try encoder.encode(claims),
        signature: signature
    )
}

private func coverageBase64URL(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

private func expectCoveragePolicyError(
    _ expected: PairingPolicyError,
    operation: () async throws -> Void
) async {
    do {
        try await operation()
        Issue.record("Expected \(expected), but the operation succeeded")
    } catch let error as PairingPolicyError {
        #expect(error == expected)
    } catch {
        Issue.record("Expected \(expected), but received \(error)")
    }
}
