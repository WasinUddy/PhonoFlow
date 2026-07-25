import Foundation
import Synchronization
import XCTest

@testable import PhonoFlow

@MainActor
final class RemoteAccessServerSecurityTests: XCTestCase {
    func testLegacySourceRulesNeverBecomeHostAuthorities() async throws {
        let authorities = TestAuthorityProvider(["studio-mac.local"])
        let transport = TestRemoteHTTPTransport()
        let server = makeServer(
            configuration: RemoteAccessConfiguration(
                port: 17_866,
                legacyAllowedSources: ["192.0.2.0/24"],
                allowUnauthenticatedLegacyStream: true,
                advertiseBonjour: false
            ),
            transport: transport,
            authorities: authorities
        )

        try await server.start()

        let acceptedStatus = await responseStatus(
            transport,
            host: "studio-mac.local:17866",
            remoteAddress: "192.0.2.10"
        )
        XCTAssertEqual(acceptedStatus, 200)
        let clientIPHostStatus = await responseStatus(
            transport,
            host: "192.0.2.10:17866",
            remoteAddress: "192.0.2.10"
        )
        XCTAssertEqual(
            clientIPHostStatus,
            421,
            "A compatibility-stream client allow-list entry must never authorize an HTTP Host header."
        )
        await server.stop()
    }

    func testRefreshingLocalAuthoritiesReplacesStaleInterfaceAuthorities() async throws {
        let authorities = TestAuthorityProvider(["old-address.local"])
        let transport = TestRemoteHTTPTransport()
        let server = makeServer(
            configuration: RemoteAccessConfiguration(
                port: 17_866,
                allowedHosts: ["configured.local"],
                advertiseBonjour: false
            ),
            transport: transport,
            authorities: authorities
        )

        try await server.start()

        let initialStatus = await responseStatus(
            transport,
            host: "old-address.local:17866"
        )
        XCTAssertEqual(initialStatus, 200)

        authorities.replace(with: ["new-address.local"])
        await server.refreshLocalAuthorities()

        let refreshedStatus = await responseStatus(
            transport,
            host: "new-address.local:17866"
        )
        XCTAssertEqual(refreshedStatus, 200)
        let configuredStatus = await responseStatus(
            transport,
            host: "configured.local:17866"
        )
        XCTAssertEqual(
            configuredStatus,
            200,
            "Explicit Host authorities must survive an interface refresh."
        )
        let staleStatus = await responseStatus(
            transport,
            host: "old-address.local:17866"
        )
        XCTAssertEqual(
            staleStatus,
            421,
            "An address removed after DHCP/VPN changes must stop being a valid Host authority."
        )
        await server.stop()
    }

    func testRevokeAllInvalidatesSessionsAndOutstandingPairingCode() async throws {
        let pairing = RemotePairingService(
            store: InMemoryRemoteCredentialStore(),
            clock: TestRemoteClock(.testReference),
            random: CountingRemoteRandom()
        )
        let transport = TestRemoteHTTPTransport()
        let server = makeServer(
            transport: transport,
            pairing: pairing,
            authorities: TestAuthorityProvider(["studio-mac.local"])
        )

        try await server.start()

        let firstCode = try await server.issuePairingCode()
        let session = try await pairing.pair(
            code: firstCode.code,
            remoteAddress: "192.0.2.10"
        )
        let outstandingCode = try await server.issuePairingCode()

        try await server.revokeAllBrowsers()

        let currentCode = await server.currentPairingCode()
        XCTAssertNil(currentCode)
        await assertInvalidSession(session.token, pairing: pairing)
        do {
            _ = try await pairing.pair(
                code: outstandingCode.code,
                remoteAddress: "192.0.2.11"
            )
            XCTFail("Revoke all must consume the outstanding pairing code.")
        } catch let error as RemoteAuthenticationError {
            XCTAssertEqual(error, .invalidPairingCode)
        }
        await server.stop()
    }

    func testPairingIssuanceCannotInterleaveWithRevokeAll() async throws {
        let store = SuspendingRemoteCredentialStore()
        let pairing = RemotePairingService(
            store: store,
            clock: TestRemoteClock(.testReference),
            random: CountingRemoteRandom()
        )
        let transport = TestRemoteHTTPTransport()
        let server = makeServer(
            transport: transport,
            pairing: pairing,
            authorities: TestAuthorityProvider(["studio-mac.local"])
        )

        try await server.start()
        _ = try await server.issuePairingCode()
        await store.suspendNextWrite()

        let revokeTask = Task {
            try await server.revokeAllBrowsers()
        }
        await waitUntil {
            await store.hasSuspendedWrite()
        }
        await assertPairingUnavailable(server)

        await store.resumeWrite()
        try await revokeTask.value
        let code = await server.currentPairingCode()
        XCTAssertNil(code)
        await server.stop()
    }

    func testPairingCannotBeIssuedWhileStartingStoppingOrDisabled() async throws {
        let transport = TestRemoteHTTPTransport(
            suspendStart: true,
            suspendStop: true
        )
        let server = makeServer(
            transport: transport,
            authorities: TestAuthorityProvider(["studio-mac.local"])
        )

        await assertPairingUnavailable(server)

        let startTask = Task {
            try await server.start()
        }
        await waitUntil {
            await transport.startCallObserved()
        }
        let startingState = await server.lifecycleState()
        XCTAssertEqual(startingState, .starting)
        await assertPairingUnavailable(server)

        await transport.resumeStart()
        try await startTask.value
        _ = try await server.issuePairingCode()

        let stopTask = Task {
            await server.stop()
        }
        await waitUntil {
            await transport.stopCallObserved()
        }
        await assertPairingUnavailable(server)

        await transport.resumeStop()
        await stopTask.value
        let disabledState = await server.lifecycleState()
        XCTAssertEqual(disabledState, .disabled)
        await assertPairingUnavailable(server)
    }

    func testStopDuringStartCannotResurrectTheServer() async throws {
        let transport = TestRemoteHTTPTransport(suspendStart: true)
        let server = makeServer(
            transport: transport,
            authorities: TestAuthorityProvider(["studio-mac.local"])
        )

        let startTask = Task {
            try await server.start()
        }
        await waitUntil {
            await transport.startCallObserved()
        }

        await server.stop()
        let stoppedState = await server.lifecycleState()
        XCTAssertEqual(stoppedState, .disabled)

        await transport.resumeStart()
        do {
            try await startTask.value
            XCTFail("A start superseded by stop must not succeed.")
        } catch let error as RemoteAccessServerError {
            XCTAssertEqual(error, .notRunning)
        }

        let finalState = await server.lifecycleState()
        XCTAssertEqual(finalState, .disabled)
        await assertPairingUnavailable(server)
    }

    func testStoppingPairedServerClosesOnlyItsAudioSubscriptions()
        async throws
    {
        let fanout = RemoteAudioFanout(
            maximumClients: 4,
            maximumClientsPerAddress: 4
        )
        let transport = TestRemoteHTTPTransport()
        let server = makeServer(
            transport: transport,
            audio: fanout,
            authorities: TestAuthorityProvider(["studio-mac.local"])
        )
        let pairedLegacy = try await fanout.subscribe(
            kind: .legacyFloat32,
            principal: nil,
            remoteAddress: "paired-player",
            origin: .pairedRemoteAccess
        )
        let pairedBrowser = try await fanout.subscribe(
            kind: .pcm16Browser,
            principal: RemoteSessionPrincipal(
                sessionID: "paired-browser",
                expiresAt: Date().addingTimeInterval(3_600)
            ),
            remoteAddress: "paired-browser",
            origin: .pairedRemoteAccess
        )
        let dedicatedLegacy = try await fanout.subscribe(
            kind: .legacyFloat32,
            principal: nil,
            remoteAddress: "dedicated-player",
            origin: .dedicatedLegacyListener
        )
        var pairedLegacyIterator =
            pairedLegacy.stream.makeAsyncIterator()
        var pairedBrowserIterator =
            pairedBrowser.stream.makeAsyncIterator()
        var dedicatedIterator =
            dedicatedLegacy.stream.makeAsyncIterator()

        try await server.start()
        await server.stop()

        let pairedLegacyAfterStop = await pairedLegacyIterator.next()
        let pairedBrowserAfterStop = await pairedBrowserIterator.next()
        let retainedLegacyCount =
            await fanout.listenerCount(kind: .legacyFloat32)
        XCTAssertNil(pairedLegacyAfterStop)
        XCTAssertNil(pairedBrowserAfterStop)
        XCTAssertEqual(retainedLegacyCount, 1)

        let chunk = Data([0x01, 0x02, 0x03, 0x04])
        await fanout.publishLegacyFloat32(chunk)
        let retainedChunk = await dedicatedIterator.next()
        XCTAssertEqual(retainedChunk, chunk)
        await dedicatedLegacy.cancel()
    }

    private func makeServer(
        configuration: RemoteAccessConfiguration = RemoteAccessConfiguration(
            port: 17_866,
            advertiseBonjour: false
        ),
        transport: TestRemoteHTTPTransport,
        pairing: RemotePairingService = RemotePairingService(
            store: InMemoryRemoteCredentialStore(),
            clock: TestRemoteClock(.testReference),
            random: CountingRemoteRandom()
        ),
        audio: (any RemoteAudioStreamProviding)? = nil,
        authorities: TestAuthorityProvider
    ) -> RemoteAccessServer {
        RemoteAccessServer(
            configuration: configuration,
            coordinator: FakeRemoteCoordinator(),
            pairing: pairing,
            audio: audio,
            assets: InMemoryRemoteStaticAssetProvider(assets: [
                "/": RemoteStaticAsset(
                    content: Data("<!doctype html>".utf8),
                    contentType: "text/html; charset=utf-8",
                    cacheControl: "no-cache"
                )
            ]),
            bonjour: DisabledRemoteBonjourAdvertiser(),
            transport: transport,
            localAuthorityProvider: {
                authorities.current()
            }
        )
    }

    private func responseStatus(
        _ transport: TestRemoteHTTPTransport,
        host: String,
        remoteAddress: String = "192.0.2.10"
    ) async -> Int? {
        let result = await transport.handle(
            RemoteHTTPRequest(
                method: .get,
                target: "/",
                headers: ["Host": host],
                remoteAddress: remoteAddress
            )
        )
        guard case .response(let response) = result else {
            XCTFail("Expected an HTTP response.")
            return nil
        }
        return response.status
    }

    private func assertPairingUnavailable(
        _ server: RemoteAccessServer,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await server.issuePairingCode()
            XCTFail("Pairing must only be available from a running server.", file: file, line: line)
        } catch let error as RemoteAccessServerError {
            XCTAssertEqual(error, .notRunning, file: file, line: line)
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }

    private func assertInvalidSession(
        _ token: String,
        pairing: RemotePairingService,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await pairing.validate(token: token)
            XCTFail("Expected the session to be invalid.", file: file, line: line)
        } catch let error as RemoteAuthenticationError {
            XCTAssertEqual(error, .invalidSession, file: file, line: line)
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }

    private func waitUntil(
        attempts: Int = 2_000,
        _ predicate: @escaping @Sendable () async -> Bool
    ) async {
        for _ in 0..<attempts {
            if await predicate() {
                return
            }
            await Task.yield()
        }
        XCTFail("Timed out waiting for the asynchronous lifecycle transition.")
    }
}

private final class TestAuthorityProvider: @unchecked Sendable {
    private let authorities: Mutex<Set<String>>

    init(_ authorities: Set<String>) {
        self.authorities = Mutex(authorities)
    }

    func current() -> Set<String> {
        authorities.withLock { $0 }
    }

    func replace(with authorities: Set<String>) {
        self.authorities.withLock {
            $0 = authorities
        }
    }
}

private actor TestRemoteHTTPTransport: nonisolated RemoteHTTPTransport {
    private let endpoint = RemoteBoundEndpoint(host: "0.0.0.0", port: 17_866)
    private let suspendStart: Bool
    private let suspendStop: Bool
    private var handler: (@Sendable (RemoteHTTPRequest) async -> RemoteRouteResult)?
    private var startContinuation: CheckedContinuation<RemoteBoundEndpoint, Error>?
    private var stopContinuation: CheckedContinuation<Void, Never>?
    private var observedStart = false
    private var observedStop = false

    init(suspendStart: Bool = false, suspendStop: Bool = false) {
        self.suspendStart = suspendStart
        self.suspendStop = suspendStop
    }

    func start(
        configuration _: RemoteTransportConfiguration,
        handler: @escaping @Sendable (RemoteHTTPRequest) async -> RemoteRouteResult
    ) async throws -> RemoteBoundEndpoint {
        self.handler = handler
        observedStart = true
        guard suspendStart else {
            return endpoint
        }
        return try await withCheckedThrowingContinuation {
            startContinuation = $0
        }
    }

    func stop() async {
        observedStop = true
        guard suspendStop else {
            handler = nil
            return
        }
        await withCheckedContinuation {
            stopContinuation = $0
        }
        handler = nil
    }

    func startCallObserved() -> Bool {
        observedStart
    }

    func stopCallObserved() -> Bool {
        observedStop
    }

    func resumeStart() {
        startContinuation?.resume(returning: endpoint)
        startContinuation = nil
    }

    func resumeStop() {
        stopContinuation?.resume()
        stopContinuation = nil
    }

    func handle(_ request: RemoteHTTPRequest) async -> RemoteRouteResult {
        guard let handler else {
            return .response(RemoteHTTPResponse(status: 503))
        }
        return await handler(request)
    }
}

private actor SuspendingRemoteCredentialStore: nonisolated RemoteCredentialStoring {
    private var data: Data?
    private var shouldSuspendNextWrite = false
    private var suspendedWrite = false
    private var writeContinuation: CheckedContinuation<Void, Never>?

    func readCredential() async throws -> Data? {
        data
    }

    func writeCredential(_ data: Data) async throws {
        if shouldSuspendNextWrite {
            shouldSuspendNextWrite = false
            suspendedWrite = true
            await withCheckedContinuation {
                writeContinuation = $0
            }
            suspendedWrite = false
        }
        self.data = data
    }

    func suspendNextWrite() {
        shouldSuspendNextWrite = true
    }

    func hasSuspendedWrite() -> Bool {
        suspendedWrite
    }

    func resumeWrite() {
        writeContinuation?.resume()
        writeContinuation = nil
    }
}
