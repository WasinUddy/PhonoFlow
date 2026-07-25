import Foundation
import Synchronization
import XCTest

@testable import PhonoFlow

enum TestSupportError: Error {
    case expectedHTTPResponse
    case expectedEvent
    case expectedAudioChunk
}

final class TestRemoteClock: RemoteClock, @unchecked Sendable {
    private let value: Mutex<Date>

    init(_ value: Date) {
        self.value = Mutex(value)
    }

    var now: Date {
        value.withLock { $0 }
    }

    func advance(by interval: TimeInterval) {
        value.withLock {
            $0 = $0.addingTimeInterval(interval)
        }
    }
}

final class CountingRemoteRandom: RemoteRandomByteGenerating, @unchecked Sendable {
    private let nextByte: Mutex<UInt8>

    init(startingAt byte: UInt8 = 1) {
        nextByte = Mutex(byte)
    }

    func bytes(count: Int) throws -> Data {
        guard count >= 0 else {
            throw RemoteAuthenticationError.credentialFailure
        }
        let byte = nextByte.withLock { value in
            let result = value
            value &+= 1
            return result
        }
        return Data(repeating: byte, count: count)
    }
}

@MainActor
final class FakeRemoteCoordinator: RemoteControlCoordinating {
    private(set) var commands: [RemoteControlCommand] = []
    var snapshot: RemoteStateSnapshot
    var commandFailure: RemoteControlFailure?

    init(snapshot: RemoteStateSnapshot = .fixture()) {
        self.snapshot = snapshot
    }

    func remoteStateSnapshot() -> RemoteStateSnapshot {
        snapshot
    }

    func applyRemoteCommand(
        _ command: RemoteControlCommand
    ) async throws -> RemoteStateSnapshot {
        commands.append(command)
        if let commandFailure {
            throw commandFailure
        }

        snapshot.revision &+= 1
        switch command {
        case .refreshDevices:
            break
        case .selectAudio(let selection):
            snapshot.selection = selection
        case .setMonitor(let request):
            snapshot.monitor.enabled = request.enabled
        case .setProcessing(let request):
            if let gain = request.gain {
                snapshot.processing.gain = gain
            }
            if let autoGainEnabled = request.autoGainEnabled {
                snapshot.processing.autoGainEnabled = autoGainEnabled
            }
            if let enabled = request.enabled {
                snapshot.processing.enabled = enabled
            }
        case .setEqualizer(let request):
            if let enabled = request.enabled {
                snapshot.equalizer.enabled = enabled
            }
            if let bands = request.bands {
                snapshot.equalizer.bands = bands
            }
        case .setRadio(let request):
            snapshot.radio.enabled = request.enabled
        case .setRecording(let request):
            snapshot.recording.enabled = request.enabled
        }
        return snapshot
    }
}

@MainActor
struct RouterHarness {
    let clock: TestRemoteClock
    let pairing: RemotePairingService
    let events: RemoteEventHub
    let audio: RemoteAudioFanout
    let coordinator: FakeRemoteCoordinator
    let router: RemoteRequestRouter
    let configuration: RemoteAccessConfiguration

    init(
        configuration: RemoteAccessConfiguration = RemoteAccessConfiguration(
            bindHost: "127.0.0.1",
            port: 17_866,
            allowedHosts: ["phonoflow.test"],
            generalRequestsPerMinute: 240,
            advertiseBonjour: false
        ),
        snapshot: RemoteStateSnapshot = .fixture(),
        rateLimiter: RemoteRequestRateLimiter? = nil
    ) {
        let clock = TestRemoteClock(.testReference)
        let pairing = RemotePairingService(
            store: InMemoryRemoteCredentialStore(),
            clock: clock,
            random: CountingRemoteRandom()
        )
        let events = RemoteEventHub(
            maximumClients: configuration.maxEventClients,
            clock: clock
        )
        let audio = RemoteAudioFanout(
            maximumClients: configuration.maxAudioClients,
            maximumClientsPerAddress: configuration.maxAudioClientsPerAddress,
            queueCapacity: 2,
            clock: clock
        )
        let coordinator = FakeRemoteCoordinator(snapshot: snapshot)
        let assets = InMemoryRemoteStaticAssetProvider(assets: [
            "/": RemoteStaticAsset(
                content: Data("<!doctype html><title>PhonoFlow</title>".utf8),
                contentType: "text/html; charset=utf-8",
                cacheControl: "no-cache"
            ),
            "/styles.css": RemoteStaticAsset(
                content: Data("body{}".utf8),
                contentType: "text/css; charset=utf-8",
                cacheControl: "public, max-age=3600"
            ),
        ])

        self.clock = clock
        self.pairing = pairing
        self.events = events
        self.audio = audio
        self.coordinator = coordinator
        self.configuration = configuration
        router = RemoteRequestRouter(
            configuration: configuration,
            coordinator: coordinator,
            pairing: pairing,
            eventHub: events,
            audio: audio,
            assets: assets,
            rateLimiter: rateLimiter
        )
    }

    func pairedToken(
        remoteAddress: String = "127.0.0.1"
    ) async throws -> String {
        let pairingCode = try await pairing.issuePairingCode()
        return try await pairing.pair(
            code: pairingCode.code,
            remoteAddress: remoteAddress
        ).token
    }

    func request(
        _ method: RemoteHTTPMethod,
        _ target: String,
        token: String? = nil,
        body: Data = Data(),
        headers: [String: String] = [:],
        mutationSecurity: Bool = true,
        remoteAddress: String = "127.0.0.1"
    ) -> RemoteHTTPRequest {
        var requestHeaders = [
            "Host": "localhost:\(configuration.port)"
        ]
        if let token {
            requestHeaders["Cookie"] = RemotePairingService.sessionCookie(token: token)
                .split(separator: ";", maxSplits: 1)
                .first
                .map(String.init)
        }
        if method.isMutation, mutationSecurity {
            requestHeaders["Origin"] = "http://localhost:\(configuration.port)"
            requestHeaders["Content-Type"] = "application/json"
            requestHeaders["X-PhonoFlow-Mutation"] = "1"
        }
        requestHeaders.merge(headers) { _, replacement in replacement }
        return RemoteHTTPRequest(
            method: method,
            target: target,
            headers: requestHeaders,
            body: body,
            remoteAddress: remoteAddress
        )
    }
}

extension Date {
    static let testReference = Date(timeIntervalSince1970: 1_735_689_600)
}

extension RemoteStateSnapshot {
    static func fixture(
        revision: UInt64 = 7,
        generatedAt: Date = .testReference
    ) -> RemoteStateSnapshot {
        let routes = [
            RemoteInputRoute(id: "channels-1-2", label: "Inputs 1–2", channels: [0, 1]),
            RemoteInputRoute(id: "channels-3-4", label: "Inputs 3–4", channels: [2, 3]),
        ]
        return RemoteStateSnapshot(
            revision: revision,
            generatedAt: generatedAt,
            engine: RemoteEngineState(
                phase: .running,
                format: RemoteAudioFormat(
                    sampleRate: 48_000,
                    channelCount: 2,
                    bufferFrameCount: 256
                )
            ),
            devices: [
                RemoteAudioDevice(
                    uid: "usb-focusrite",
                    name: "Scarlett 2i2",
                    inputChannelCount: 4,
                    outputChannelCount: 2,
                    inputRoutes: routes,
                    supportedSampleRates: [44_100, 48_000, 96_000],
                    transport: .usb,
                    connectionState: .connected
                )
            ],
            selection: RemoteAudioSelection(
                inputUID: "usb-focusrite",
                inputRouteID: "channels-1-2",
                outputUID: "usb-focusrite"
            ),
            meters: RemoteMeterSnapshot(
                left: 0.25,
                right: 0.5,
                peak: 0.75,
                sequence: 1,
                timestamp: generatedAt
            ),
            processing: RemoteProcessingState(
                gain: 1,
                autoGainEnabled: false,
                enabled: true
            ),
            equalizer: RemoteEqualizerState(
                enabled: false,
                bands: (0..<10).map {
                    RemoteEqualizerBand(
                        frequencyHz: Float(31.25 * pow(2, Double($0))),
                        gainDB: 0
                    )
                }
            ),
            monitor: RemoteToggleState(enabled: false),
            radio: RemoteRadioState(enabled: false, listenerCount: 0),
            recording: RemoteRecordingState(enabled: false, durationSeconds: 0),
            diagnostics: RemoteDiagnosticsSnapshot()
        )
    }
}

func requireHTTPResponse(
    _ result: RemoteRouteResult,
    file: StaticString = #filePath,
    line: UInt = #line
) throws -> RemoteHTTPResponse {
    guard case .response(let response) = result else {
        XCTFail("Expected an HTTP response", file: file, line: line)
        throw TestSupportError.expectedHTTPResponse
    }
    return response
}

func decodeProblem(
    _ response: RemoteHTTPResponse,
    file: StaticString = #filePath,
    line: UInt = #line
) throws -> RemoteAPIProblem {
    XCTAssertEqual(
        response.headers["Content-Type"],
        "application/problem+json; charset=utf-8",
        file: file,
        line: line
    )
    return try RemoteJSON.decoder().decode(RemoteAPIProblem.self, from: response.body)
}

func jsonData<T: Encodable>(_ value: T) throws -> Data {
    try RemoteJSON.encoder().encode(value)
}

func littleEndianUInt16(_ data: Data, at offset: Int) -> UInt16 {
    UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
}

func littleEndianInt16(_ data: Data, at offset: Int) -> Int16 {
    Int16(bitPattern: littleEndianUInt16(data, at: offset))
}

func littleEndianUInt32(_ data: Data, at offset: Int) -> UInt32 {
    UInt32(data[offset])
        | UInt32(data[offset + 1]) << 8
        | UInt32(data[offset + 2]) << 16
        | UInt32(data[offset + 3]) << 24
}
