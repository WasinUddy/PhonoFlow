import Foundation
import XCTest

@testable import PhonoFlow

@MainActor
final class LegacyStreamServerTests: XCTestCase {
    func testDedicatedListenerExposesOnlyExactGetStreamRoute()
        async throws
    {
        let fanout = RemoteAudioFanout()

        for target in [
            "/",
            "/api/v1/state",
            "/audio/live.wav",
            "/styles.css",
            "/stream?token=ignored",
            "/stream/",
        ] {
            let result = await LegacyStreamRequestHandler.handle(
                request(.get, target),
                allowedSources: [],
                audio: fanout
            )
            XCTAssertEqual(
                response(from: result)?.status,
                404,
                "Dedicated legacy listener unexpectedly exposed \(target)"
            )
        }

        let mutation = await LegacyStreamRequestHandler.handle(
            request(.post, "/stream"),
            allowedSources: [],
            audio: fanout
        )
        let mutationResponse = try XCTUnwrap(response(from: mutation))
        XCTAssertEqual(mutationResponse.status, 405)
        XCTAssertEqual(mutationResponse.headers["Allow"], "GET")

        let stream = await LegacyStreamRequestHandler.handle(
            request(.get, "/stream"),
            allowedSources: [],
            audio: fanout
        )
        guard case .legacyFloat32Audio(let subscription) = stream else {
            return XCTFail("Expected the one permitted route to open legacy audio.")
        }
        XCTAssertEqual(subscription.kind, .legacyFloat32)
        XCTAssertNil(subscription.principal)
        await subscription.cancel()
    }

    func testDedicatedListenerUsesSocketPeerForExactAndCIDRPolicy()
        async throws
    {
        let fanout = RemoteAudioFanout()
        let allowed: Set<String> = [
            "192.0.2.0/24",
            "2001:db8::/32",
            "198.51.100.42",
        ]

        for peer in [
            "192.0.2.27",
            "192.0.2.27:50123",
            "[2001:db8::7]:50123",
            "198.51.100.42",
        ] {
            let result = await LegacyStreamRequestHandler.handle(
                request(.get, "/stream", remoteAddress: peer),
                allowedSources: allowed,
                audio: fanout
            )
            guard case .legacyFloat32Audio(let subscription) = result else {
                return XCTFail("Expected \(peer) to match the source allow-list.")
            }
            await subscription.cancel()
        }

        let denied = await LegacyStreamRequestHandler.handle(
            request(
                .get,
                "/stream",
                headers: ["X-Forwarded-For": "192.0.2.27"],
                remoteAddress: "203.0.113.9"
            ),
            allowedSources: allowed,
            audio: fanout
        )
        let deniedResponse = try XCTUnwrap(response(from: denied))
        XCTAssertEqual(deniedResponse.status, 403)
        let problem = try RemoteJSON.decoder().decode(
            RemoteAPIProblem.self,
            from: deniedResponse.body
        )
        XCTAssertEqual(problem.code, "legacy_source_forbidden")
    }

    func testStoppingLegacyListenerRevokesOnlyLegacySubscribers()
        async throws
    {
        let fanout = RemoteAudioFanout(
            maximumClients: 4,
            maximumClientsPerAddress: 4
        )
        let transport = RecordingLegacyTransport()
        let server = LegacyStreamServer(
            configuration: LegacyStreamConfiguration(
                bindHost: "127.0.0.1",
                port: 17_865,
                allowedSources: ["127.0.0.1"]
            ),
            audio: fanout,
            transport: transport
        )
        let browser = try await fanout.subscribe(
            kind: .pcm16Browser,
            principal: nil,
            remoteAddress: "browser"
        )
        var browserIterator = browser.stream.makeAsyncIterator()
        let pairedLegacy = try await fanout.subscribe(
            kind: .legacyFloat32,
            principal: nil,
            remoteAddress: "paired-legacy",
            origin: .pairedRemoteAccess
        )
        var pairedLegacyIterator =
            pairedLegacy.stream.makeAsyncIterator()

        try await server.start()
        let runningState = await server.lifecycleState()
        XCTAssertEqual(
            runningState,
            .running(host: "127.0.0.1", port: 17_865)
        )
        let startedConfigurations =
            await transport.startedConfigurations()
        XCTAssertEqual(
            startedConfigurations,
            [
                RemoteTransportConfiguration(
                    bindHost: "127.0.0.1",
                    port: 17_865,
                    maximumBodyBytes: 1_024
                )
            ]
        )

        let route = await transport.handle(
            request(.get, "/stream", remoteAddress: "127.0.0.1")
        )
        guard case .legacyFloat32Audio(let legacy) = route else {
            return XCTFail("Expected a live compatibility subscription.")
        }
        var legacyIterator = legacy.stream.makeAsyncIterator()
        let initialLegacyCount =
            await fanout.listenerCount(kind: .legacyFloat32)
        XCTAssertEqual(
            initialLegacyCount,
            2
        )
        let initialBrowserCount =
            await fanout.listenerCount(kind: .pcm16Browser)
        XCTAssertEqual(
            initialBrowserCount,
            1
        )

        await server.stop()
        let stoppedState = await server.lifecycleState()
        let closedLegacyChunk = await legacyIterator.next()
        let retainedLegacyCount =
            await fanout.listenerCount(kind: .legacyFloat32)
        let retainedBrowserCount =
            await fanout.listenerCount(kind: .pcm16Browser)
        XCTAssertEqual(stoppedState, .disabled)
        XCTAssertNil(closedLegacyChunk)
        XCTAssertEqual(
            retainedLegacyCount,
            1,
            "Stopping the dedicated port must not close the paired server's /stream."
        )
        XCTAssertEqual(
            retainedBrowserCount,
            1,
            "Stopping the legacy port must not disconnect paired browser audio."
        )

        let browserChunk = Data([1, 2, 3, 4])
        await fanout.publishPCM16(browserChunk)
        let receivedBrowserChunk = await browserIterator.next()
        XCTAssertEqual(receivedBrowserChunk, browserChunk)
        let pairedLegacyChunk = Data([5, 6, 7, 8])
        await fanout.publishLegacyFloat32(pairedLegacyChunk)
        let receivedPairedLegacyChunk =
            await pairedLegacyIterator.next()
        XCTAssertEqual(
            receivedPairedLegacyChunk,
            pairedLegacyChunk
        )

        // Turning Radio off is broader than stopping or reconfiguring only
        // the dedicated listener: every legacy stream must terminate.
        await fanout.revoke(kind: .legacyFloat32)
        let closedPairedLegacyChunk =
            await pairedLegacyIterator.next()
        let browserCountAfterRadioOff =
            await fanout.listenerCount(kind: .pcm16Browser)
        XCTAssertNil(closedPairedLegacyChunk)
        XCTAssertEqual(browserCountAfterRadioOff, 1)

        await browser.cancel()
        await pairedLegacy.cancel()
    }

    func testStopClosesIngressBeforeFinalSubscriberRevoke() async throws {
        let fanout = RemoteAudioFanout(
            maximumClients: 2,
            maximumClientsPerAddress: 2
        )
        let transport = SubscribingDuringStopLegacyTransport()
        let server = LegacyStreamServer(
            configuration: LegacyStreamConfiguration(
                bindHost: "127.0.0.1",
                port: 17_865
            ),
            audio: fanout,
            transport: transport
        )
        try await server.start()

        await server.stop()

        let stopSubscription =
            await transport.subscriptionOpenedDuringStop()
        let subscription = try XCTUnwrap(stopSubscription)
        var iterator = subscription.stream.makeAsyncIterator()
        let closedChunk = await iterator.next()
        let listenerCount = await fanout.listenerCount(
            kind: .legacyFloat32
        )
        let lifecycleState = await server.lifecycleState()
        XCTAssertNil(closedChunk)
        XCTAssertEqual(listenerCount, 0)
        XCTAssertEqual(lifecycleState, .disabled)
    }

    func testLatchedPairedBindFailureKeepsDedicatedListenerRunning() {
        let configuration = RemoteAccessConfiguration(
            port: 17_865,
            advertiseBonjour: false
        )

        XCTAssertFalse(
            AppCoordinator.shouldYieldDedicatedLegacyListener(
                shouldRunRemoteAccess: true,
                remoteConfiguration: configuration,
                radioPort: 17_865,
                remoteLifecycle: .failed("Address already in use"),
                failedRemoteConfiguration: configuration
            ),
            "A latched failure must not bounce a working Radio listener every maintenance tick."
        )
        XCTAssertTrue(
            AppCoordinator.shouldYieldDedicatedLegacyListener(
                shouldRunRemoteAccess: true,
                remoteConfiguration: configuration,
                radioPort: 17_865,
                remoteLifecycle: .failed("Address already in use"),
                failedRemoteConfiguration: nil
            ),
            "An explicit retry may hand the shared port back to paired Remote Access."
        )
        XCTAssertTrue(
            AppCoordinator.shouldYieldDedicatedLegacyListener(
                shouldRunRemoteAccess: true,
                remoteConfiguration: configuration,
                radioPort: 17_865,
                remoteLifecycle: .running(
                    host: "127.0.0.1",
                    port: 17_865
                ),
                failedRemoteConfiguration: nil
            )
        )
    }

    func testPairedAndDedicatedListenersRunIndependentlyOnTheirConfiguredPorts()
        async throws
    {
        let fanout = RemoteAudioFanout()
        let pairedTransport = RecordingLegacyTransport()
        let legacyTransport = RecordingLegacyTransport()
        let paired = RemoteAccessServer(
            configuration: RemoteAccessConfiguration(
                bindHost: "127.0.0.1",
                port: 17_866,
                allowedHosts: ["localhost"],
                advertiseBonjour: false
            ),
            coordinator: FakeRemoteCoordinator(),
            pairing: RemotePairingService(
                store: InMemoryRemoteCredentialStore(),
                clock: TestRemoteClock(.testReference),
                random: CountingRemoteRandom()
            ),
            audio: fanout,
            assets: InMemoryRemoteStaticAssetProvider(assets: [
                "/": RemoteStaticAsset(
                    content: Data("<!doctype html>".utf8),
                    contentType: "text/html; charset=utf-8",
                    cacheControl: "no-cache"
                )
            ]),
            bonjour: DisabledRemoteBonjourAdvertiser(),
            transport: pairedTransport,
            localAuthorityProvider: { ["localhost", "127.0.0.1"] }
        )
        let legacy = LegacyStreamServer(
            configuration: LegacyStreamConfiguration(
                bindHost: "127.0.0.1",
                port: 17_865,
                allowedSources: ["127.0.0.1"]
            ),
            audio: fanout,
            transport: legacyTransport
        )

        try await paired.start()
        try await legacy.start()

        let pairedPort = await paired.boundEndpoint()?.port
        let legacyPort = await legacy.boundEndpoint()?.port
        XCTAssertEqual(
            pairedPort,
            17_866
        )
        XCTAssertEqual(
            legacyPort,
            17_865
        )
        let hiddenAPI = await legacyTransport.handle(
            request(.get, "/api/v1/state")
        )
        XCTAssertEqual(response(from: hiddenAPI)?.status, 404)

        let pairedRoot = await pairedTransport.handle(
            request(
                .get,
                "/",
                headers: ["Host": "localhost:17866"]
            )
        )
        XCTAssertEqual(response(from: pairedRoot)?.status, 200)

        await legacy.stop()
        let retainedPairedState = await paired.lifecycleState()
        XCTAssertEqual(
            retainedPairedState,
            .running(host: "127.0.0.1", port: 17_866),
            "Stopping Radio must not stop paired Remote Access."
        )

        let unauthenticatedPairedStream = try await fanout.subscribe(
            kind: .legacyFloat32,
            principal: nil,
            remoteAddress: "paired-legacy",
            origin: .pairedRemoteAccess
        )
        var pairedIterator =
            unauthenticatedPairedStream.stream.makeAsyncIterator()
        await paired.stop()
        let closedPairedChunk = await pairedIterator.next()
        XCTAssertNil(
            closedPairedChunk,
            "Stopping paired Remote Access must close unauthenticated /stream clients owned by that listener."
        )
    }

    private func request(
        _ method: RemoteHTTPMethod,
        _ target: String,
        headers: [String: String] = [:],
        remoteAddress: String = "127.0.0.1"
    ) -> RemoteHTTPRequest {
        RemoteHTTPRequest(
            method: method,
            target: target,
            headers: headers,
            remoteAddress: remoteAddress
        )
    }

    private func response(
        from result: RemoteRouteResult
    ) -> RemoteHTTPResponse? {
        guard case .response(let response) = result else { return nil }
        return response
    }
}

private actor RecordingLegacyTransport:
    nonisolated RemoteHTTPTransport
{
    private var configurations: [RemoteTransportConfiguration] = []
    private var handler: (@Sendable (RemoteHTTPRequest) async -> RemoteRouteResult)?

    func start(
        configuration: RemoteTransportConfiguration,
        handler:
            @escaping @Sendable (RemoteHTTPRequest) async
            -> RemoteRouteResult
    ) async throws -> RemoteBoundEndpoint {
        configurations.append(configuration)
        self.handler = handler
        return RemoteBoundEndpoint(
            host: configuration.bindHost,
            port: configuration.port
        )
    }

    func stop() async {
        handler = nil
    }

    func startedConfigurations() -> [RemoteTransportConfiguration] {
        configurations
    }

    func handle(
        _ request: RemoteHTTPRequest
    ) async -> RemoteRouteResult {
        guard let handler else {
            return .response(RemoteHTTPResponse(status: 503))
        }
        return await handler(request)
    }
}

private actor SubscribingDuringStopLegacyTransport:
    nonisolated RemoteHTTPTransport
{
    private var handler: (@Sendable (RemoteHTTPRequest) async -> RemoteRouteResult)?
    private var stopSubscription: RemoteAudioSubscription?

    func start(
        configuration: RemoteTransportConfiguration,
        handler:
            @escaping @Sendable (RemoteHTTPRequest) async
            -> RemoteRouteResult
    ) async throws -> RemoteBoundEndpoint {
        self.handler = handler
        return RemoteBoundEndpoint(
            host: configuration.bindHost,
            port: configuration.port
        )
    }

    func stop() async {
        guard let handler else { return }
        let result = await handler(
            RemoteHTTPRequest(
                method: .get,
                target: "/stream",
                headers: [:],
                remoteAddress: "127.0.0.1"
            )
        )
        if case .legacyFloat32Audio(let subscription) = result {
            stopSubscription = subscription
        }
        self.handler = nil
    }

    func subscriptionOpenedDuringStop() -> RemoteAudioSubscription? {
        stopSubscription
    }
}
