import Foundation
import XCTest

@testable import PhonoFlow

@MainActor
final class RemoteLifecycleCoverageExpansionTests: XCTestCase {
    func testPairedServerLifecyclePublishesAndReportsInjectedDependencies() async throws {
        let clock = TestRemoteClock(.testReference)
        let pairing = makePairing(clock: clock)
        let events = RemoteEventHub(maximumClients: 2, clock: clock)
        let audio = RemoteAudioFanout(
            maximumClients: 2,
            maximumClientsPerAddress: 2,
            clock: clock
        )
        let transport = CoverageRemoteTransport(
            endpoint: RemoteBoundEndpoint(host: "127.0.0.1", port: 19_001)
        )
        let bonjour = CoverageBonjourAdvertiser()
        let coordinator = FakeRemoteCoordinator()
        let server = RemoteAccessServer(
            configuration: RemoteAccessConfiguration(
                bindHost: "127.0.0.1",
                port: 0,
                advertiseBonjour: false
            ),
            coordinator: coordinator,
            pairing: pairing,
            eventHub: events,
            audio: audio,
            assets: CoverageStaticAssets(),
            bonjour: bonjour,
            transport: transport,
            localAuthorityProvider: { ["interface.local"] },
            usesAcceptanceEnvironment: false
        )

        XCTAssertEqual(RemoteListenerCounts(eventStreams: 2, audioStreams: 3).total, 5)
        let initialEndpoint = await server.boundEndpoint()
        let initialLifecycle = await server.lifecycleState()
        XCTAssertNil(initialEndpoint)
        XCTAssertEqual(initialLifecycle, .disabled)

        let updated = RemoteAccessConfiguration(
            bindHost: "127.0.0.1",
            port: 0,
            serviceName: "Coverage Flow",
            allowedHosts: ["configured.local"],
            maxEventClients: 2,
            maxAudioClients: 2,
            maxAudioClientsPerAddress: 2,
            advertiseBonjour: true
        )
        try await server.updateConfiguration(updated)
        let storedConfiguration = await server.currentConfiguration()
        XCTAssertTrue(storedConfiguration.allowedHosts.contains("configured.local"))
        XCTAssertTrue(storedConfiguration.allowedHosts.contains("interface.local"))

        let principal = RemoteSessionPrincipal(
            sessionID: "coverage-session",
            expiresAt: clock.now.addingTimeInterval(3_600)
        )
        let eventSubscription = try await events.subscribe(
            principal: principal,
            snapshot: .fixture(revision: 10)
        )
        let audioSubscription = try await audio.subscribe(
            kind: .pcm16Browser,
            principal: principal,
            remoteAddress: "127.0.0.1"
        )
        addTeardownBlock {
            await server.stop()
            await eventSubscription.cancel()
            await audioSubscription.cancel()
        }
        guard
            case .snapshot(let initialSnapshot) = try await nextEvent(
                from: eventSubscription,
                description: "initial paired-server snapshot"
            )
        else {
            return XCTFail("Expected the subscription's initial snapshot.")
        }
        XCTAssertEqual(initialSnapshot.revision, 10)

        try await server.start()
        let runningLifecycle = await server.lifecycleState()
        let runningEndpoint = await server.boundEndpoint()
        let transportConfigurations = await transport.configurations()
        XCTAssertEqual(
            runningLifecycle,
            .running(host: "127.0.0.1", port: 19_001)
        )
        XCTAssertEqual(
            runningEndpoint,
            RemoteBoundEndpoint(host: "127.0.0.1", port: 19_001)
        )
        XCTAssertEqual(
            transportConfigurations,
            [
                RemoteTransportConfiguration(
                    bindHost: "127.0.0.1",
                    port: 0,
                    maximumBodyBytes: updated.maxJSONBodyBytes
                )
            ]
        )
        let advertisements = await bonjour.advertisements()
        XCTAssertEqual(advertisements.count, 1)
        XCTAssertEqual(advertisements.first?.serviceName, "Coverage Flow")
        XCTAssertEqual(advertisements.first?.serviceType, "_phonoflow._tcp.")
        XCTAssertEqual(advertisements.first?.port, 19_001)
        XCTAssertEqual(advertisements.first?.txt["api"], "v1")

        let issuedCode = try await server.issuePairingCode()
        let currentPairingCode = await server.currentPairingCode()
        let activeListenerCounts = await server.listenerCounts()
        XCTAssertEqual(currentPairingCode, issuedCode)
        XCTAssertEqual(
            activeListenerCounts,
            RemoteListenerCounts(eventStreams: 1, audioStreams: 1)
        )

        let state = RemoteStateSnapshot.fixture(revision: 11)
        await server.publish(snapshot: state)
        guard
            case .state(let publishedState) = try await nextEvent(
                from: eventSubscription,
                description: "paired-server state publication"
            )
        else {
            return XCTFail("Expected the server to publish an authoritative state event.")
        }
        XCTAssertEqual(publishedState, state)

        let meters = RemoteMeterSnapshot(
            left: 0.2,
            right: 0.4,
            peak: 0.4,
            sequence: 12,
            timestamp: clock.now
        )
        await server.publish(meters: meters)
        guard
            case .meters(let publishedMeters) = try await nextEvent(
                from: eventSubscription,
                description: "paired-server meter publication"
            )
        else {
            return XCTFail("Expected a meter event.")
        }
        XCTAssertEqual(publishedMeters, meters)

        let spectrum = RemoteSpectrogramColumn(
            sequence: 13,
            timestamp: clock.now,
            intensities: Array(repeating: 42, count: 64)
        )
        await server.publish(spectrogram: spectrum)
        guard
            case .spectrum(let publishedSpectrum) = try await nextEvent(
                from: eventSubscription,
                description: "paired-server spectrogram publication"
            )
        else {
            return XCTFail("Expected a spectrogram event.")
        }
        XCTAssertEqual(publishedSpectrum, spectrum)

        await assertRemoteAccessError(.alreadyRunning) {
            try await server.start()
        }
        await assertRemoteAccessError(.configurationLocked) {
            try await server.updateConfiguration(updated)
        }

        await server.stop()
        let stoppedLifecycle = await server.lifecycleState()
        let stoppedEndpoint = await server.boundEndpoint()
        let stoppedPairingCode = await server.currentPairingCode()
        let stoppedListenerCounts = await server.listenerCounts()
        let closedEvent = try await nextEvent(
            from: eventSubscription,
            description: "paired event stream closure"
        )
        XCTAssertEqual(stoppedLifecycle, .disabled)
        XCTAssertNil(stoppedEndpoint)
        XCTAssertNil(stoppedPairingCode)
        XCTAssertEqual(
            stoppedListenerCounts,
            RemoteListenerCounts(eventStreams: 0, audioStreams: 0)
        )
        XCTAssertNil(closedEvent)
        let closedAudio = try await nextAudioChunk(
            from: audioSubscription,
            description: "paired audio stream closure"
        )
        XCTAssertNil(closedAudio)
        await server.stop()
        let transportStops = await transport.stopCount()
        XCTAssertEqual(transportStops, 1)
    }

    func testPairedServerBonjourFailurePerformsCompleteCleanup() async throws {
        let clock = TestRemoteClock(.testReference)
        let events = RemoteEventHub(clock: clock)
        let audio = RemoteAudioFanout(clock: clock)
        let principal = RemoteSessionPrincipal(
            sessionID: "cleanup",
            expiresAt: clock.now.addingTimeInterval(3_600)
        )
        let eventSubscription = try await events.subscribe(
            principal: principal,
            snapshot: .fixture()
        )
        let audioSubscription = try await audio.subscribe(
            kind: .pcm16Browser,
            principal: principal,
            remoteAddress: "cleanup-client"
        )
        let transport = CoverageRemoteTransport(
            endpoint: RemoteBoundEndpoint(host: "0.0.0.0", port: 19_002)
        )
        let bonjour = CoverageBonjourAdvertiser(failure: .bonjour)
        let coordinator = FakeRemoteCoordinator()
        let server = RemoteAccessServer(
            configuration: RemoteAccessConfiguration(
                port: 19_002,
                advertiseBonjour: true
            ),
            coordinator: coordinator,
            pairing: makePairing(clock: clock),
            eventHub: events,
            audio: audio,
            assets: CoverageStaticAssets(),
            bonjour: bonjour,
            transport: transport,
            localAuthorityProvider: { ["cleanup.local"] },
            usesAcceptanceEnvironment: false
        )
        addTeardownBlock {
            await server.stop()
            await eventSubscription.cancel()
            await audioSubscription.cancel()
        }

        do {
            try await server.start()
            XCTFail("A Bonjour failure must fail startup.")
        } catch let error as CoverageFailure {
            XCTAssertEqual(error, .bonjour)
        }

        guard case .failed(let detail) = await server.lifecycleState() else {
            return XCTFail("The failed startup should remain inspectable.")
        }
        XCTAssertTrue(detail.contains("bonjour"))
        let failedEndpoint = await server.boundEndpoint()
        let cleanupTransportStops = await transport.stopCount()
        let cleanupBonjourStops = await bonjour.stopCount()
        let closedEvent = try await nextEvent(
            from: eventSubscription,
            description: "failed-server event stream cleanup"
        )
        let closedAudio = try await nextAudioChunk(
            from: audioSubscription,
            description: "failed-server audio stream cleanup"
        )
        let cleanedListenerCount = await server.listenerCounts().total
        XCTAssertNil(failedEndpoint)
        XCTAssertEqual(cleanupTransportStops, 1)
        XCTAssertEqual(cleanupBonjourStops, 1)
        XCTAssertNil(closedEvent)
        XCTAssertNil(closedAudio)
        XCTAssertEqual(cleanedListenerCount, 0)

        await assertRemoteAccessError(.alreadyRunning) {
            try await server.start()
        }
        await server.stop()
        let stoppedLifecycle = await server.lifecycleState()
        let totalTransportStops = await transport.stopCount()
        XCTAssertEqual(stoppedLifecycle, .disabled)
        XCTAssertEqual(totalTransportStops, 2)
    }

    func testLegacyHandlerMapsCapacityAndProviderFailures() async throws {
        let clientLimited = RemoteAudioFanout(
            maximumClients: 1,
            maximumClientsPerAddress: 1
        )
        let retained = try await clientLimited.subscribe(
            kind: .pcm16Browser,
            principal: nil,
            remoteAddress: "first-client"
        )
        addTeardownBlock {
            await retained.cancel()
        }
        try await assertLegacyProblem(
            audio: clientLimited,
            remoteAddress: "second-client",
            code: "audio_client_capacity"
        )
        await retained.cancel()

        let addressLimited = RemoteAudioFanout(
            maximumClients: 3,
            maximumClientsPerAddress: 1
        )
        let sameAddress = try await addressLimited.subscribe(
            kind: .pcm16Browser,
            principal: nil,
            remoteAddress: "same-client"
        )
        addTeardownBlock {
            await sameAddress.cancel()
        }
        try await assertLegacyProblem(
            audio: addressLimited,
            remoteAddress: "SAME-CLIENT",
            code: "audio_address_capacity"
        )
        await sameAddress.cancel()

        try await assertLegacyProblem(
            audio: CoverageThrowingAudioProvider(error: .unavailable),
            remoteAddress: "provider-error",
            code: "legacy_stream_unavailable"
        )
    }

    func testLegacyServerConfigurationLifecycleAndStartupFailure() async throws {
        let audio = RemoteAudioFanout()
        let transport = CoverageRemoteTransport(
            endpoint: RemoteBoundEndpoint(host: "127.0.0.1", port: 19_003)
        )
        let server = LegacyStreamServer(audio: audio, transport: transport)
        addTeardownBlock {
            await server.stop()
        }
        let initialConfiguration = await server.currentConfiguration()
        XCTAssertEqual(
            initialConfiguration,
            LegacyStreamConfiguration()
        )

        let updated = LegacyStreamConfiguration(
            bindHost: "127.0.0.1",
            port: 19_003,
            allowedSources: ["127.0.0.1"]
        )
        try await server.updateConfiguration(updated)
        let storedConfiguration = await server.currentConfiguration()
        XCTAssertEqual(storedConfiguration, updated)
        try await server.start()
        let runningLifecycle = await server.lifecycleState()
        let runningEndpoint = await server.boundEndpoint()
        XCTAssertEqual(
            runningLifecycle,
            .running(host: "127.0.0.1", port: 19_003)
        )
        XCTAssertEqual(
            runningEndpoint,
            RemoteBoundEndpoint(host: "127.0.0.1", port: 19_003)
        )
        await assertLegacyServerError(.configurationLocked) {
            try await server.updateConfiguration(updated)
        }
        await assertLegacyServerError(.alreadyRunning) {
            try await server.start()
        }

        let subscription = try await audio.subscribe(
            kind: .legacyFloat32,
            principal: nil,
            remoteAddress: "legacy-count",
            origin: .dedicatedLegacyListener
        )
        addTeardownBlock {
            await subscription.cancel()
        }
        let activeListenerCount = await server.listenerCount()
        XCTAssertEqual(activeListenerCount, 1)
        await server.stop()
        let stoppedLifecycle = await server.lifecycleState()
        let stoppedEndpoint = await server.boundEndpoint()
        let stoppedListenerCount = await server.listenerCount()
        XCTAssertEqual(stoppedLifecycle, .disabled)
        XCTAssertNil(stoppedEndpoint)
        XCTAssertEqual(stoppedListenerCount, 0)
        let closedChunk = try await nextAudioChunk(
            from: subscription,
            description: "legacy audio stream closure"
        )
        XCTAssertNil(closedChunk)
        await server.stop()

        let failedTransport = CoverageRemoteTransport(failure: .transport)
        let failedServer = LegacyStreamServer(
            configuration: updated,
            audio: audio,
            transport: failedTransport
        )
        addTeardownBlock {
            await failedServer.stop()
        }
        do {
            try await failedServer.start()
            XCTFail("A transport failure must fail the legacy listener.")
        } catch let error as CoverageFailure {
            XCTAssertEqual(error, .transport)
        }
        guard case .failed(let detail) = await failedServer.lifecycleState() else {
            return XCTFail("Expected a failed lifecycle state.")
        }
        XCTAssertTrue(detail.contains("transport"))
        let failedEndpoint = await failedServer.boundEndpoint()
        let failedTransportStops = await failedTransport.stopCount()
        XCTAssertNil(failedEndpoint)
        XCTAssertEqual(failedTransportStops, 1)
        await failedServer.stop()
        let recoveredLifecycle = await failedServer.lifecycleState()
        XCTAssertEqual(recoveredLifecycle, .disabled)
    }

    func testStoppingLegacyServerDuringStartCannotResurrectIt() async throws {
        let transport = CoverageRemoteTransport(suspendStart: true)
        let server = LegacyStreamServer(
            configuration: LegacyStreamConfiguration(port: 19_004),
            audio: RemoteAudioFanout(),
            transport: transport
        )

        let startTask = Task {
            try await server.start()
        }
        addTeardownBlock {
            startTask.cancel()
            await transport.cancelPendingStart()
            await server.stop()
            _ = try? await startTask.value
        }
        try await waitUntil(
            description: "legacy transport start continuation"
        ) {
            await transport.hasPendingStart()
        }
        let startingLifecycle = await server.lifecycleState()
        XCTAssertEqual(startingLifecycle, .starting)

        await server.stop()
        let stoppedLifecycle = await server.lifecycleState()
        XCTAssertEqual(stoppedLifecycle, .disabled)
        await transport.resumeStart(
            with: RemoteBoundEndpoint(host: "127.0.0.1", port: 19_004)
        )
        do {
            try await bounded(
                description: "superseded legacy server start",
                operation: {
                    try await startTask.value
                },
                cleanup: {
                    startTask.cancel()
                    await transport.cancelPendingStart()
                    await server.stop()
                }
            )
            XCTFail("A stopped start operation must not resurrect the listener.")
        } catch let error as LegacyStreamServerError {
            XCTAssertEqual(error, .notRunning)
        }
        let finalLifecycle = await server.lifecycleState()
        XCTAssertEqual(finalLifecycle, .disabled)
    }

    func testRouterMapsRatePairingCapacityAssetsAndUnexpectedFailures() async throws {
        let clock = TestRemoteClock(.testReference)
        let pairing = makePairing(clock: clock)
        let events = RemoteEventHub(maximumClients: 1, clock: clock)
        let audio = RemoteAudioFanout(clock: clock)
        let coordinator = CoverageCoordinator()
        let configuration = RemoteAccessConfiguration(
            bindHost: "127.0.0.1",
            port: 19_005,
            allowedHosts: ["coverage.local"],
            allowUnauthenticatedLegacyStream: true,
            maxEventClients: 1,
            generalRequestsPerMinute: 240,
            advertiseBonjour: false
        )
        let rateLimitedRouter = RemoteRequestRouter(
            configuration: configuration,
            coordinator: coordinator,
            pairing: pairing,
            eventHub: events,
            audio: audio,
            assets: CoverageStaticAssets(),
            rateLimiter: RemoteRequestRateLimiter(
                maximumRequests: 1,
                clock: clock
            )
        )

        let first = try requireHTTPResponse(
            await rateLimitedRouter.handle(request(.get, "/", port: configuration.port))
        )
        XCTAssertEqual(first.status, 200)
        let limited = try requireHTTPResponse(
            await rateLimitedRouter.handle(request(.get, "/", port: configuration.port))
        )
        XCTAssertEqual(limited.status, 429)
        XCTAssertEqual(limited.headers["Retry-After"], "60")
        XCTAssertEqual(try decodeProblem(limited).code, "request_rate_limited")

        let router = RemoteRequestRouter(
            configuration: configuration,
            coordinator: coordinator,
            pairing: pairing,
            eventHub: events,
            audio: audio,
            assets: CoverageStaticAssets(),
            rateLimiter: RemoteRequestRateLimiter(
                maximumRequests: 1_000,
                clock: clock
            )
        )
        let missingAsset = try requireHTTPResponse(
            await router.handle(
                request(
                    .get,
                    "/src/app.js",
                    port: configuration.port,
                    remoteAddress: "asset-client"
                )
            )
        )
        XCTAssertEqual(missingAsset.status, 404)
        XCTAssertEqual(try decodeProblem(missingAsset).code, "asset_not_found")

        let pairingCode = try await pairing.issuePairingCode()
        XCTAssertEqual(pairingCode.code.count, 6)
        var lastPairingResponse: RemoteHTTPResponse?
        for attempt in 0..<6 {
            lastPairingResponse = try requireHTTPResponse(
                await router.handle(
                    request(
                        .post,
                        "/api/v1/auth/pair",
                        port: configuration.port,
                        body: try jsonData(RemotePairRequest(code: "000000")),
                        remoteAddress: "pair-client",
                        mutation: true
                    )
                )
            )
            XCTAssertEqual(lastPairingResponse?.status, attempt < 5 ? 401 : 429)
        }
        let lockedPairing = try XCTUnwrap(lastPairingResponse)
        XCTAssertEqual(try decodeProblem(lockedPairing).code, "pairing_rate_limited")
        XCTAssertEqual(lockedPairing.headers["Retry-After"], "600")

        let token = try await pairToken(pairing: pairing, remoteAddress: "events-client")
        let firstEvents = await router.handle(
            request(
                .get,
                "/api/v1/events",
                port: configuration.port,
                token: token,
                remoteAddress: "events-client"
            )
        )
        guard case .events(let eventSubscription) = firstEvents else {
            return XCTFail("Expected the first event subscription.")
        }
        addTeardownBlock {
            await eventSubscription.cancel()
        }
        let capacityResponse = try requireHTTPResponse(
            await router.handle(
                request(
                    .get,
                    "/api/v1/events",
                    port: configuration.port,
                    token: token,
                    remoteAddress: "events-client-2"
                )
            )
        )
        XCTAssertEqual(capacityResponse.status, 503)
        XCTAssertEqual(try decodeProblem(capacityResponse).code, "event_client_capacity")
        await eventSubscription.cancel()

        let invalidOptionalSession = try requireHTTPResponse(
            await router.handle(
                request(
                    .get,
                    "/stream",
                    port: configuration.port,
                    token: "invalid-token",
                    remoteAddress: "legacy-client"
                )
            )
        )
        XCTAssertEqual(invalidOptionalSession.status, 401)
        XCTAssertEqual(
            try decodeProblem(invalidOptionalSession).code,
            "authentication_required"
        )

        coordinator.commandError = CoverageFailure.coordinator
        let unexpectedFailure = try requireHTTPResponse(
            await router.handle(
                request(
                    .put,
                    "/api/v1/monitor",
                    port: configuration.port,
                    token: token,
                    body: try jsonData(RemoteBooleanCommand(enabled: true)),
                    remoteAddress: "command-client",
                    mutation: true
                )
            )
        )
        XCTAssertEqual(unexpectedFailure.status, 503)
        XCTAssertEqual(
            try decodeProblem(unexpectedFailure).code,
            "remote_access_unavailable"
        )
    }

    func testRouterReportsDeallocatedCoordinatorForStateAndCommands() async throws {
        let clock = TestRemoteClock(.testReference)
        let pairing = makePairing(clock: clock)
        let configuration = RemoteAccessConfiguration(
            bindHost: "127.0.0.1",
            port: 19_006,
            allowedHosts: ["coverage.local"],
            advertiseBonjour: false
        )
        var coordinator: CoverageCoordinator? = CoverageCoordinator()
        let router = RemoteRequestRouter(
            configuration: configuration,
            coordinator: try XCTUnwrap(coordinator),
            pairing: pairing,
            eventHub: RemoteEventHub(clock: clock),
            audio: RemoteAudioFanout(clock: clock),
            assets: CoverageStaticAssets()
        )
        coordinator = nil
        let token = try await pairToken(pairing: pairing, remoteAddress: "weak-client")

        let stateResponse = try requireHTTPResponse(
            await router.handle(
                request(
                    .get,
                    "/api/v1/state",
                    port: configuration.port,
                    token: token,
                    remoteAddress: "weak-client"
                )
            )
        )
        XCTAssertEqual(stateResponse.status, 503)
        XCTAssertEqual(try decodeProblem(stateResponse).code, "coordinator_unavailable")

        let commandResponse = try requireHTTPResponse(
            await router.handle(
                request(
                    .post,
                    "/api/v1/devices/refresh",
                    port: configuration.port,
                    token: token,
                    body: Data("{}".utf8),
                    remoteAddress: "weak-client",
                    mutation: true
                )
            )
        )
        XCTAssertEqual(commandResponse.status, 503)
        XCTAssertEqual(try decodeProblem(commandResponse).code, "coordinator_unavailable")
    }

    func testEventSerializationMailboxCancellationEvictionAndExpiry() async throws {
        let snapshot = RemoteStateSnapshot.fixture(revision: 21)
        let stateBytes = try RemoteServerEvent.state(snapshot).serverSentEventData()
        let stateText = try XCTUnwrap(String(data: stateBytes, encoding: .utf8))
        XCTAssertTrue(stateText.contains("id: 21\nevent: state\n"))

        let meters = RemoteMeterSnapshot(
            left: 0.1,
            right: 0.2,
            peak: 0.2,
            sequence: 22,
            timestamp: .testReference
        )
        let meterBytes = try RemoteServerEvent.meters(meters).serverSentEventData()
        let meterText = try XCTUnwrap(String(data: meterBytes, encoding: .utf8))
        XCTAssertTrue(meterText.contains("id: 22\nevent: meters\n"))

        let heartbeatBytes = try RemoteServerEvent.heartbeat(.testReference).serverSentEventData()
        let heartbeatText = try XCTUnwrap(String(data: heartbeatBytes, encoding: .utf8))
        XCTAssertTrue(heartbeatText.hasPrefix(": heartbeat "))
        XCTAssertTrue(heartbeatText.hasSuffix("\n\n"))

        let directMailbox = RemoteEventMailbox(
            controlCapacity: 1,
            maximumConsecutiveDrops: 2
        )
        let acceptedSnapshot = await directMailbox.enqueue(.snapshot(snapshot))
        let acceptedReplacement = await directMailbox.enqueue(.state(snapshot))
        let evictedByReplacement = await directMailbox.enqueue(.state(snapshot))
        let closedMailboxEvent = try await nextMailboxEvent(
            from: directMailbox,
            description: "evicted direct mailbox closure"
        )
        let acceptedAfterClose = await directMailbox.enqueue(.heartbeat(.testReference))
        XCTAssertTrue(acceptedSnapshot)
        XCTAssertTrue(acceptedReplacement)
        XCTAssertFalse(evictedByReplacement)
        XCTAssertNil(closedMailboxEvent)
        XCTAssertFalse(acceptedAfterClose)
        await directMailbox.close()

        let waitingMailbox = RemoteEventMailbox()
        let readerReady = CoverageOneShotSignal()
        let readerRelease = CoverageOneShotSignal()
        let waitingTask = Task {
            await readerReady.signal()
            await readerRelease.wait()
            return await waitingMailbox.next()
        }
        addTeardownBlock {
            waitingTask.cancel()
            await readerRelease.signal()
            await waitingMailbox.close()
            _ = await waitingTask.value
        }
        try await waitForSignal(
            readerReady,
            description: "mailbox reader readiness"
        )
        await readerRelease.signal()
        let resumedWaiter = await waitingMailbox.enqueue(.heartbeat(.testReference))
        let waitedEvent = try await bounded(
            description: "waiting mailbox delivery",
            operation: {
                await waitingTask.value
            },
            cleanup: {
                waitingTask.cancel()
                await readerRelease.signal()
                await waitingMailbox.close()
            }
        )
        XCTAssertTrue(resumedWaiter)
        XCTAssertEqual(waitedEvent, .heartbeat(.testReference))
        await waitingMailbox.close()

        let clock = TestRemoteClock(.testReference)
        let hub = RemoteEventHub(clock: clock)
        let principal = RemoteSessionPrincipal(
            sessionID: "cancelled-stream",
            expiresAt: clock.now.addingTimeInterval(3_600)
        )
        let subscription = try await hub.subscribe(
            principal: principal,
            snapshot: snapshot
        )
        let cancellationReady = CoverageOneShotSignal()
        let cancellationRelease = CoverageOneShotSignal()
        let cancelledRead = Task {
            await cancellationReady.signal()
            await cancellationRelease.wait()
            var iterator = subscription.stream.makeAsyncIterator()
            return await iterator.next()
        }
        addTeardownBlock {
            cancelledRead.cancel()
            await cancellationRelease.signal()
            await subscription.cancel()
            _ = await cancelledRead.value
        }
        try await waitForSignal(
            cancellationReady,
            description: "cancelled event reader readiness"
        )
        cancelledRead.cancel()
        await cancellationRelease.signal()
        let cancelledEvent = try await bounded(
            description: "cancelled event stream read",
            operation: {
                await cancelledRead.value
            },
            cleanup: {
                cancelledRead.cancel()
                await cancellationRelease.signal()
                await subscription.cancel()
            }
        )
        let cancelledClientCount = await hub.clientCount
        XCTAssertNil(cancelledEvent)
        XCTAssertEqual(cancelledClientCount, 0)
        await hub.publish(snapshot: .fixture(revision: 23))
        let evictedClientCount = await hub.clientCount
        XCTAssertEqual(evictedClientCount, 0)

        let expired = try await hub.subscribe(
            principal: RemoteSessionPrincipal(
                sessionID: "already-expired",
                expiresAt: clock.now.addingTimeInterval(-1)
            ),
            snapshot: snapshot
        )
        addTeardownBlock {
            await expired.cancel()
        }
        try await waitUntil(
            description: "expired event subscription removal"
        ) {
            await hub.clientCount == 0
        }
        let expiredEvent = try await nextEvent(
            from: expired,
            description: "expired event stream closure"
        )
        XCTAssertNil(expiredEvent)
        await hub.unsubscribe(UUID())
    }

    func testSecurityAcceptsBracketedMappedZonedAndPartialPrefixAddresses() async throws {
        let configuration = RemoteAccessConfiguration(
            port: 19_007,
            allowedHosts: ["2001:db8::7", "127.999.0.1"],
            advertiseBonjour: false
        )
        XCTAssertEqual(
            try RemoteRequestSecurity.validateAuthority(
                hostHeader: "[2001:db8::7]:19007",
                remoteAddress: "2001:db8::8",
                configuration: configuration,
                boundPort: 19_007
            ),
            RemoteAuthority(host: "2001:db8::7", port: 19_007)
        )
        XCTAssertEqual(
            try RemoteRequestSecurity.validateAuthority(
                hostHeader: "127.999.0.1:19007",
                remoteAddress: "198.51.100.1",
                configuration: configuration,
                boundPort: 19_007
            ),
            RemoteAuthority(host: "127.999.0.1", port: 19_007)
        )

        for malformed in [
            "[2001:db8::7:19007",
            "[2001:db8::7]",
            "[2001:db8::7]19007",
        ] {
            XCTAssertThrowsError(
                try RemoteRequestSecurity.validateAuthority(
                    hostHeader: malformed,
                    remoteAddress: "2001:db8::8",
                    configuration: configuration,
                    boundPort: 19_007
                )
            )
        }

        XCTAssertNoThrow(
            try RemoteRequestSecurity.validateLegacySource(
                remoteAddress: "[fe80::abcd%en0]:50123",
                allowedSources: ["fe80::/64"]
            )
        )
        XCTAssertNoThrow(
            try RemoteRequestSecurity.validateLegacySource(
                remoteAddress: "::ffff:192.0.2.44",
                allowedSources: ["192.0.2.0/24"]
            )
        )
        XCTAssertNoThrow(
            try RemoteRequestSecurity.validateLegacySource(
                remoteAddress: "198.51.100.200",
                allowedSources: ["198.51.100.128/25"]
            )
        )
        XCTAssertThrowsError(
            try RemoteRequestSecurity.validateLegacySource(
                remoteAddress: "198.51.100.127",
                allowedSources: ["198.51.100.128/25"]
            )
        )

        let limiter = RemoteRequestRateLimiter(
            maximumRequests: 3,
            maximumBuckets: 32,
            clock: TestRemoteClock(.testReference)
        )
        for index in 0..<34 {
            let result = await limiter.check(remoteAddress: "client-\(index)")
            XCTAssertTrue(result.isAllowed)
        }
    }

    private func makePairing(clock: TestRemoteClock) -> RemotePairingService {
        RemotePairingService(
            store: InMemoryRemoteCredentialStore(),
            clock: clock,
            random: CountingRemoteRandom()
        )
    }

    private func pairToken(
        pairing: RemotePairingService,
        remoteAddress: String
    ) async throws -> String {
        let code = try await pairing.issuePairingCode()
        return try await pairing.pair(
            code: code.code,
            remoteAddress: remoteAddress
        ).token
    }

    private func request(
        _ method: RemoteHTTPMethod,
        _ target: String,
        port: UInt16,
        token: String? = nil,
        body: Data = Data(),
        remoteAddress: String = "coverage-client",
        mutation: Bool = false
    ) -> RemoteHTTPRequest {
        var headers = ["Host": "coverage.local:\(port)"]
        if let token {
            headers["Cookie"] = "\(RemotePairingService.cookieName)=\(token)"
        }
        if mutation {
            headers["Origin"] = "http://coverage.local:\(port)"
            headers["Content-Type"] = "application/json"
            headers["X-PhonoFlow-Mutation"] = "1"
        }
        return RemoteHTTPRequest(
            method: method,
            target: target,
            headers: headers,
            body: body,
            remoteAddress: remoteAddress
        )
    }

    private func assertLegacyProblem(
        audio: any RemoteAudioStreamProviding,
        remoteAddress: String,
        code: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let result = await LegacyStreamRequestHandler.handle(
            RemoteHTTPRequest(
                method: .get,
                target: "/stream",
                headers: [:],
                remoteAddress: remoteAddress
            ),
            allowedSources: [],
            audio: audio
        )
        let response = try requireHTTPResponse(result, file: file, line: line)
        XCTAssertEqual(response.status, 503, file: file, line: line)
        XCTAssertEqual(
            try decodeProblem(response, file: file, line: line).code,
            code,
            file: file,
            line: line
        )
    }

    private func assertRemoteAccessError(
        _ expected: RemoteAccessServerError,
        operation: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("Expected \(expected).", file: file, line: line)
        } catch let error as RemoteAccessServerError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }

    private func assertLegacyServerError(
        _ expected: LegacyStreamServerError,
        operation: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("Expected \(expected).", file: file, line: line)
        } catch let error as LegacyStreamServerError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }

    private func nextEvent(
        from subscription: RemoteEventSubscription,
        description: String
    ) async throws -> RemoteServerEvent? {
        try await bounded(
            description: description,
            operation: {
                var iterator = subscription.stream.makeAsyncIterator()
                return await iterator.next()
            },
            cleanup: {
                await subscription.cancel()
            }
        )
    }

    private func nextAudioChunk(
        from subscription: RemoteAudioSubscription,
        description: String
    ) async throws -> Data? {
        try await bounded(
            description: description,
            operation: {
                var iterator = subscription.stream.makeAsyncIterator()
                return await iterator.next()
            },
            cleanup: {
                await subscription.cancel()
            }
        )
    }

    private func nextMailboxEvent(
        from mailbox: RemoteEventMailbox,
        description: String
    ) async throws -> RemoteServerEvent? {
        try await bounded(
            description: description,
            operation: {
                await mailbox.next()
            },
            cleanup: {
                await mailbox.close()
            }
        )
    }

    private func waitForSignal(
        _ signal: CoverageOneShotSignal,
        description: String
    ) async throws {
        _ = try await bounded(
            description: description,
            operation: {
                await signal.wait()
                return true
            },
            cleanup: {
                await signal.signal()
            }
        )
    }

    private func bounded<T: Sendable>(
        description: String,
        timeout: Duration = .seconds(1),
        operation: @escaping @Sendable () async throws -> T,
        cleanup: @escaping @Sendable () async -> Void
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                await cleanup()
                throw CoverageAsyncTestError.timedOut(description)
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                await cleanup()
                throw CoverageAsyncTestError.timedOut(description)
            }
            return result
        }
    }

    private func waitUntil(
        description: String,
        timeout: Duration = .seconds(1),
        pollInterval: Duration = .milliseconds(1),
        predicate: @escaping @Sendable () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        repeat {
            if await predicate() {
                return
            }
            try await Task.sleep(for: pollInterval)
        } while clock.now < deadline
        throw CoverageAsyncTestError.timedOut(description)
    }
}

private enum CoverageAsyncTestError: Error, Sendable, Equatable {
    case timedOut(String)
}

private enum CoverageFailure: Error, Sendable, Equatable {
    case bonjour
    case coordinator
    case transport
}

private actor CoverageOneShotSignal {
    private var isSignaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    deinit {
        for waiter in waiters {
            waiter.resume()
        }
    }

    func signal() {
        guard !isSignaled else { return }
        isSignaled = true
        let waiters = self.waiters
        self.waiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
    }

    func wait() async {
        guard !isSignaled else { return }
        await withCheckedContinuation {
            waiters.append($0)
        }
    }
}

@MainActor
private final class CoverageCoordinator: RemoteControlCoordinating {
    var snapshot = RemoteStateSnapshot.fixture()
    var commandError: (any Error)?

    func remoteStateSnapshot() -> RemoteStateSnapshot {
        snapshot
    }

    func applyRemoteCommand(
        _ command: RemoteControlCommand
    ) async throws -> RemoteStateSnapshot {
        if let commandError {
            throw commandError
        }
        snapshot.revision &+= 1
        if case .setMonitor(let request) = command {
            snapshot.monitor.enabled = request.enabled
        }
        return snapshot
    }
}

private actor CoverageStaticAssets: RemoteStaticAssetProviding {
    func asset(forRequestPath path: String) async -> RemoteStaticAsset? {
        guard path == "/" else { return nil }
        return RemoteStaticAsset(
            content: Data("<!doctype html>".utf8),
            contentType: "text/html; charset=utf-8",
            cacheControl: "no-cache"
        )
    }
}

private actor CoverageBonjourAdvertiser: RemoteBonjourAdvertising {
    struct Advertisement: Sendable {
        var serviceName: String
        var serviceType: String
        var port: UInt16
        var txt: [String: String]
    }

    private let failure: CoverageFailure?
    private var records: [Advertisement] = []
    private var stops = 0

    init(failure: CoverageFailure? = nil) {
        self.failure = failure
    }

    func start(
        serviceName: String,
        serviceType: String,
        port: UInt16,
        txt: [String: String]
    ) async throws {
        records.append(
            Advertisement(
                serviceName: serviceName,
                serviceType: serviceType,
                port: port,
                txt: txt
            )
        )
        if let failure {
            throw failure
        }
    }

    func stop() async {
        stops += 1
    }

    func advertisements() -> [Advertisement] {
        records
    }

    func stopCount() -> Int {
        stops
    }
}

private actor CoverageRemoteTransport: RemoteHTTPTransport {
    private let endpoint: RemoteBoundEndpoint
    private let failure: CoverageFailure?
    private let suspendStart: Bool
    private var recordedConfigurations: [RemoteTransportConfiguration] = []
    private var handler: (@Sendable (RemoteHTTPRequest) async -> RemoteRouteResult)?
    private var continuation: CheckedContinuation<RemoteBoundEndpoint, Error>?
    private var stops = 0

    init(
        endpoint: RemoteBoundEndpoint = RemoteBoundEndpoint(
            host: "127.0.0.1",
            port: 19_999
        ),
        failure: CoverageFailure? = nil,
        suspendStart: Bool = false
    ) {
        self.endpoint = endpoint
        self.failure = failure
        self.suspendStart = suspendStart
    }

    func start(
        configuration: RemoteTransportConfiguration,
        handler: @escaping @Sendable (RemoteHTTPRequest) async -> RemoteRouteResult
    ) async throws -> RemoteBoundEndpoint {
        recordedConfigurations.append(configuration)
        self.handler = handler
        if let failure {
            throw failure
        }
        guard suspendStart else {
            return endpoint
        }
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                continuation = $0
            }
        } onCancel: {
            Task {
                await self.cancelPendingStart()
            }
        }
    }

    func stop() async {
        stops += 1
        handler = nil
    }

    func configurations() -> [RemoteTransportConfiguration] {
        recordedConfigurations
    }

    func hasPendingStart() -> Bool {
        continuation != nil
    }

    func resumeStart(with endpoint: RemoteBoundEndpoint) {
        continuation?.resume(returning: endpoint)
        continuation = nil
    }

    func cancelPendingStart() {
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }

    func stopCount() -> Int {
        stops
    }
}

private actor CoverageThrowingAudioProvider: RemoteAudioStreamProviding {
    private let error: RemoteAudioSubscriptionError

    init(error: RemoteAudioSubscriptionError) {
        self.error = error
    }

    func subscribe(
        kind _: RemoteAudioStreamKind,
        principal _: RemoteSessionPrincipal?,
        remoteAddress _: String,
        origin _: RemoteAudioSubscriptionOrigin
    ) async throws -> RemoteAudioSubscription {
        throw error
    }

    func unsubscribe(_: UUID) async {}
    func revoke(sessionID _: String) async {}
    func revoke(kind _: RemoteAudioStreamKind) async {}
    func revoke(origin _: RemoteAudioSubscriptionOrigin) async {}
    func revokeAllAuthenticated() async {}
    func listenerCount() async -> Int { 0 }
    func listenerCount(kind _: RemoteAudioStreamKind) async -> Int { 0 }
}
