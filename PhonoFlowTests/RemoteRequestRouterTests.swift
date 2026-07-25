import Foundation
import XCTest

@testable import PhonoFlow

@MainActor
final class RemoteRequestRouterTests: XCTestCase {
    func testStaticAssetGETAndHEADHaveSecurityHeadersAndNoCORS() async throws {
        let harness = RouterHarness()

        let get = try requireHTTPResponse(
            await harness.router.handle(harness.request(.get, "/"))
        )
        XCTAssertEqual(get.status, 200)
        XCTAssertFalse(get.body.isEmpty)
        XCTAssertEqual(get.headers["Content-Type"], "text/html; charset=utf-8")
        XCTAssertNotNil(get.headers["Content-Security-Policy"])
        XCTAssertEqual(get.headers["X-Frame-Options"], "DENY")
        XCTAssertFalse(
            get.headers.keys.contains {
                $0.lowercased().hasPrefix("access-control-allow-")
            }
        )

        let head = try requireHTTPResponse(
            await harness.router.handle(harness.request(.head, "/"))
        )
        XCTAssertEqual(head.status, 200)
        XCTAssertTrue(head.body.isEmpty)
        XCTAssertEqual(head.headers["Content-Length"], String(get.body.count))
    }

    func testOnlyExactCanonicalRoutesAreAccepted() async throws {
        let harness = RouterHarness()
        let rejectedTargets = [
            "/api/v1/state/",
            "/api//v1/state",
            "/api/v1/state?anything=1",
            "/api/v1/%73tate",
            "/api/v1/../state",
            "//api/v1/state",
            "/not-a-route",
        ]

        for target in rejectedTargets {
            let response = try requireHTTPResponse(
                await harness.router.handle(harness.request(.get, target))
            )
            XCTAssertTrue(
                [400, 404].contains(response.status),
                "\(target) unexpectedly returned \(response.status)"
            )
            let problem = try decodeProblem(response)
            XCTAssertTrue(
                ["invalid_request_target", "route_not_found"].contains(problem.code),
                "\(target) returned \(problem.code)"
            )
        }
    }

    func testEveryControlRouteRejectsWrongMethodWithAllowHeader() async throws {
        let harness = RouterHarness()
        let mutations: [(String, String)] = [
            ("/api/v1/auth/pair", "POST"),
            ("/api/v1/auth/logout", "POST"),
            ("/api/v1/devices/refresh", "POST"),
            ("/api/v1/audio/selection", "PUT"),
            ("/api/v1/monitor", "PUT"),
            ("/api/v1/processing", "PUT"),
            ("/api/v1/equalizer", "PUT"),
            ("/api/v1/radio", "PUT"),
            ("/api/v1/recording", "PUT"),
        ]

        for (path, allowed) in mutations {
            let response = try requireHTTPResponse(
                await harness.router.handle(harness.request(.get, path))
            )
            XCTAssertEqual(response.status, 405, path)
            XCTAssertEqual(response.headers["Allow"], allowed, path)
            let problem = try decodeProblem(response)
            XCTAssertEqual(problem.code, "method_not_allowed", path)
        }

        for path in ["/api/v1/state", "/api/v1/events", "/audio/live.wav", "/stream"] {
            let response = try requireHTTPResponse(
                await harness.router.handle(harness.request(.post, path))
            )
            XCTAssertEqual(response.status, 405, path)
            XCTAssertEqual(response.headers["Allow"], "GET", path)
        }
    }

    func testHostMustMatchBoundListenerAndLoopbackAuthorityRequiresLoopbackPeer() async throws {
        let harness = RouterHarness()
        let cases: [(headers: [String: String], peer: String)] = [
            ([:], "127.0.0.1"),
            (["Host": "localhost:9999"], "127.0.0.1"),
            (["Host": "evil.example:17866"], "127.0.0.1"),
            (["Host": "localhost:17866"], "192.168.1.12"),
            (["Host": "localhost:17866,evil.example:17866"], "127.0.0.1"),
        ]

        for item in cases {
            var request = harness.request(
                .get,
                "/",
                headers: item.headers,
                remoteAddress: item.peer
            )
            if item.headers["Host"] == nil {
                request.headers["host"] = nil
            }
            let response = try requireHTTPResponse(
                await harness.router.handle(request)
            )
            XCTAssertEqual(response.status, 421)
            let problem = try decodeProblem(response)
            XCTAssertEqual(problem.code, "invalid_host")
        }
    }

    func testMutationRequiresCustomHeaderExactOriginAndJSON() async throws {
        let harness = RouterHarness()
        let token = try await harness.pairedToken()
        let body = try jsonData(RemoteBooleanCommand(enabled: true))

        var missingHeader = harness.request(
            .put,
            "/api/v1/monitor",
            token: token,
            body: body
        )
        missingHeader.headers[RemoteRequestSecurity.mutationHeaderName] = nil
        try await assertProblem(
            request: missingHeader,
            router: harness.router,
            status: 403,
            code: "mutation_header_required"
        )

        let crossOrigin = harness.request(
            .put,
            "/api/v1/monitor",
            token: token,
            body: body,
            headers: ["Origin": "http://phonoflow.test:17866"]
        )
        try await assertProblem(
            request: crossOrigin,
            router: harness.router,
            status: 403,
            code: "invalid_origin"
        )

        let nonJSON = harness.request(
            .put,
            "/api/v1/monitor",
            token: token,
            body: body,
            headers: ["Content-Type": "text/plain"]
        )
        try await assertProblem(
            request: nonJSON,
            router: harness.router,
            status: 415,
            code: "json_required"
        )
    }

    func testBodyLimitIsAppliedBeforeDecodingOrAuthentication() async throws {
        let configuration = RemoteAccessConfiguration(
            bindHost: "127.0.0.1",
            port: 17_866,
            maxJSONBodyBytes: 1_024,
            maxPairBodyBytes: 256,
            generalRequestsPerMinute: 240,
            advertiseBonjour: false
        )
        let harness = RouterHarness(configuration: configuration)

        try await assertProblem(
            request: harness.request(
                .put,
                "/api/v1/monitor",
                body: Data(repeating: 0x20, count: 1_025)
            ),
            router: harness.router,
            status: 413,
            code: "body_too_large"
        )
        try await assertProblem(
            request: harness.request(
                .post,
                "/api/v1/auth/pair",
                body: Data(repeating: 0x20, count: 257)
            ),
            router: harness.router,
            status: 413,
            code: "body_too_large"
        )
    }

    func testProtectedRoutesRequireValidSession() async throws {
        let harness = RouterHarness()

        for path in ["/api/v1/state", "/api/v1/events", "/audio/live.wav", "/stream"] {
            let response = try requireHTTPResponse(
                await harness.router.handle(harness.request(.get, path))
            )
            XCTAssertEqual(response.status, 401, path)
            XCTAssertEqual(
                response.headers["WWW-Authenticate"],
                "PhonoFlowSession",
                path
            )
            let problem = try decodeProblem(response)
            XCTAssertEqual(
                problem.code,
                "authentication_required",
                path
            )
        }
    }

    func testPairEndpointSetsSessionCookieAndReturnsAuthoritativeState() async throws {
        let harness = RouterHarness()
        let code = try await harness.pairing.issuePairingCode()
        let request = harness.request(
            .post,
            "/api/v1/auth/pair",
            body: try jsonData(RemotePairRequest(code: code.code))
        )

        let response = try requireHTTPResponse(
            await harness.router.handle(request)
        )
        XCTAssertEqual(response.status, 200)
        let cookie = try XCTUnwrap(response.headers["Set-Cookie"])
        XCTAssertTrue(cookie.contains("HttpOnly"))
        XCTAssertTrue(cookie.contains("SameSite=Strict"))
        let payload = try RemoteJSON.decoder().decode(
            RemotePairResponse.self,
            from: response.body
        )
        XCTAssertEqual(payload.state, .fixture())
    }

    func testInvalidPairingCodeReturns401Problem() async throws {
        let harness = RouterHarness()
        _ = try await harness.pairing.issuePairingCode()

        try await assertProblem(
            request: harness.request(
                .post,
                "/api/v1/auth/pair",
                body: try jsonData(RemotePairRequest(code: "000000"))
            ),
            router: harness.router,
            status: 401,
            code: "pairing_failed"
        )
    }

    func testStateEndpointReturnsSnapshotAndDisablesCaching() async throws {
        let harness = RouterHarness()
        let token = try await harness.pairedToken()

        let response = try requireHTTPResponse(
            await harness.router.handle(
                harness.request(.get, "/api/v1/state", token: token)
            )
        )

        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.headers["Cache-Control"], "no-store")
        let decoded = try RemoteJSON.decoder().decode(
            RemoteStateSnapshot.self,
            from: response.body
        )
        XCTAssertEqual(decoded, .fixture())
    }

    func testEventAndBrowserAudioRoutesReturnAuthenticatedSubscriptions() async throws {
        let harness = RouterHarness()
        let token = try await harness.pairedToken()

        let eventResult = await harness.router.handle(
            harness.request(.get, "/api/v1/events", token: token)
        )
        guard case .events(let eventSubscription) = eventResult else {
            return XCTFail("Expected SSE subscription")
        }
        var eventIterator = eventSubscription.stream.makeAsyncIterator()
        guard case .snapshot(let snapshot) = await eventIterator.next() else {
            await eventSubscription.cancel()
            return XCTFail("Expected initial SSE snapshot")
        }
        XCTAssertEqual(snapshot, .fixture())

        let audioResult = await harness.router.handle(
            harness.request(.get, "/audio/live.wav", token: token)
        )
        guard case .pcm16Audio(let audioSubscription) = audioResult else {
            await eventSubscription.cancel()
            return XCTFail("Expected browser PCM subscription")
        }
        XCTAssertEqual(audioSubscription.principal, eventSubscription.principal)
        XCTAssertEqual(
            audioSubscription.format,
            RemoteAudioStreamFormat(encoding: .pcm16, sampleRate: 48_000)
        )

        await eventSubscription.cancel()
        await audioSubscription.cancel()
    }

    func testLegacyStreamRequiresRadioAndCanPreserveExplicitUnauthenticatedCompatibility()
        async throws
    {
        var disabledSnapshot = RemoteStateSnapshot.fixture()
        disabledSnapshot.radio.enabled = false
        let disabledHarness = RouterHarness(snapshot: disabledSnapshot)
        let token = try await disabledHarness.pairedToken()
        try await assertProblem(
            request: disabledHarness.request(.get, "/stream", token: token),
            router: disabledHarness.router,
            status: 503,
            code: "radio_disabled"
        )

        var enabledSnapshot = RemoteStateSnapshot.fixture()
        enabledSnapshot.radio.enabled = true
        let compatibilityConfiguration = RemoteAccessConfiguration(
            bindHost: "127.0.0.1",
            port: 17_866,
            legacyAllowedSources: ["127.0.0.1"],
            allowUnauthenticatedLegacyStream: true,
            generalRequestsPerMinute: 240,
            advertiseBonjour: false
        )
        let enabledHarness = RouterHarness(
            configuration: compatibilityConfiguration,
            snapshot: enabledSnapshot
        )
        let result = await enabledHarness.router.handle(
            enabledHarness.request(.get, "/stream")
        )
        guard case .legacyFloat32Audio(let subscription) = result else {
            return XCTFail("Expected legacy Float32 subscription")
        }
        XCTAssertNil(subscription.principal)
        XCTAssertEqual(subscription.format.encoding, .float32)
        await subscription.cancel()
    }

    func testLegacyStreamAllowlistAcceptsExactIPv4CIDRAndIPv6Rules()
        async throws
    {
        var snapshot = RemoteStateSnapshot.fixture()
        snapshot.radio.enabled = true
        let configuration = RemoteAccessConfiguration(
            bindHost: "0.0.0.0",
            port: 17_866,
            allowedHosts: ["phonoflow.test"],
            legacyAllowedSources: [
                "192.0.2.10",
                "10.42.0.0/16",
                "2001:db8:abcd::/48",
            ],
            allowUnauthenticatedLegacyStream: true,
            generalRequestsPerMinute: 240,
            advertiseBonjour: false
        )
        let harness = RouterHarness(
            configuration: configuration,
            snapshot: snapshot
        )
        let acceptedPeers = [
            "192.0.2.10",
            "10.42.99.3:54321",
            "[2001:db8:abcd::7]:55000",
        ]

        for peer in acceptedPeers {
            let result = await harness.router.handle(
                harness.request(
                    .get,
                    "/stream",
                    headers: ["Host": "phonoflow.test:17866"],
                    remoteAddress: peer
                )
            )
            guard case .legacyFloat32Audio(let subscription) = result else {
                return XCTFail("Expected allow-listed legacy stream for \(peer)")
            }
            XCTAssertNil(subscription.principal)
            await subscription.cancel()
        }
    }

    func testLegacyStreamAllowlistRejectsUnlistedAndMalformedSources()
        async throws
    {
        var snapshot = RemoteStateSnapshot.fixture()
        snapshot.radio.enabled = true
        let configuration = RemoteAccessConfiguration(
            bindHost: "0.0.0.0",
            port: 17_866,
            allowedHosts: ["phonoflow.test"],
            legacyAllowedSources: [
                "192.0.2.10",
                "10.42.0.0/16",
                "2001:db8:abcd::/48",
                "not-an-address",
                "10.0.0.0/99",
            ],
            allowUnauthenticatedLegacyStream: true,
            generalRequestsPerMinute: 240,
            advertiseBonjour: false
        )
        let harness = RouterHarness(
            configuration: configuration,
            snapshot: snapshot
        )

        for peer in ["192.0.2.11", "10.43.0.1", "2001:db8:abce::1", "invalid"] {
            try await assertProblem(
                request: harness.request(
                    .get,
                    "/stream",
                    headers: ["Host": "phonoflow.test:17866"],
                    remoteAddress: peer
                ),
                router: harness.router,
                status: 403,
                code: "legacy_source_forbidden"
            )
        }
    }

    func testAuthenticatedLegacyStreamBypassesSourceAllowlist() async throws {
        var snapshot = RemoteStateSnapshot.fixture()
        snapshot.radio.enabled = true
        let configuration = RemoteAccessConfiguration(
            bindHost: "0.0.0.0",
            port: 17_866,
            allowedHosts: ["phonoflow.test"],
            legacyAllowedSources: ["192.0.2.10"],
            allowUnauthenticatedLegacyStream: true,
            generalRequestsPerMinute: 240,
            advertiseBonjour: false
        )
        let harness = RouterHarness(
            configuration: configuration,
            snapshot: snapshot
        )
        let token = try await harness.pairedToken(
            remoteAddress: "198.51.100.9"
        )
        let result = await harness.router.handle(
            harness.request(
                .get,
                "/stream",
                token: token,
                headers: ["Host": "phonoflow.test:17866"],
                remoteAddress: "198.51.100.9"
            )
        )

        guard case .legacyFloat32Audio(let subscription) = result else {
            return XCTFail("Authenticated legacy stream should bypass allow-list")
        }
        XCTAssertNotNil(subscription.principal)
        await subscription.cancel()
    }

    func testLogoutRevokesSessionAndClosesItsEventAndAudioStreams() async throws {
        let harness = RouterHarness()
        let token = try await harness.pairedToken()
        let principal = try await harness.pairing.validate(token: token)
        let eventSubscription = try await harness.events.subscribe(
            principal: principal,
            snapshot: .fixture()
        )
        let audioSubscription = try await harness.audio.subscribe(
            kind: .pcm16Browser,
            principal: principal,
            remoteAddress: "127.0.0.1"
        )
        var eventIterator = eventSubscription.stream.makeAsyncIterator()
        var audioIterator = audioSubscription.stream.makeAsyncIterator()

        let response = try requireHTTPResponse(
            await harness.router.handle(
                harness.request(
                    .post,
                    "/api/v1/auth/logout",
                    token: token,
                    body: Data("{}".utf8)
                )
            )
        )

        XCTAssertEqual(response.status, 204)
        XCTAssertTrue(response.headers["Set-Cookie"]?.contains("Max-Age=0") == true)
        do {
            _ = try await harness.pairing.validate(token: token)
            XCTFail("Logged-out token remained valid")
        } catch let error as RemoteAuthenticationError {
            XCTAssertEqual(error, .invalidSession)
        }
        let closedEvent = await eventIterator.next()
        let closedAudio = await audioIterator.next()
        XCTAssertNil(closedEvent)
        XCTAssertNil(closedAudio)
        let eventCount = await harness.events.clientCount
        let audioCount = await harness.audio.listenerCount()
        XCTAssertEqual(eventCount, 0)
        XCTAssertEqual(audioCount, 0)
    }

    func testAllValidMutationsAreTypedIdempotentCommands() async throws {
        let harness = RouterHarness()
        let token = try await harness.pairedToken()
        let bands = (0..<10).map {
            RemoteEqualizerBand(
                frequencyHz: Float(40 * ($0 + 1)),
                gainDB: Float($0 - 5)
            )
        }
        let operations: [(RemoteHTTPMethod, String, Data)] = [
            (.post, "/api/v1/devices/refresh", Data("{}".utf8)),
            (
                .put,
                "/api/v1/audio/selection",
                try jsonData(
                    RemoteAudioSelection(
                        inputUID: "usb-focusrite",
                        inputRouteID: "channels-3-4",
                        outputUID: nil
                    )
                )
            ),
            (.put, "/api/v1/monitor", try jsonData(RemoteBooleanCommand(enabled: true))),
            (
                .put,
                "/api/v1/processing",
                try jsonData(
                    RemoteProcessingCommand(
                        gain: 1.5,
                        autoGainEnabled: true,
                        enabled: true
                    )
                )
            ),
            (
                .put,
                "/api/v1/equalizer",
                try jsonData(RemoteEqualizerCommand(enabled: true, bands: bands))
            ),
            (.put, "/api/v1/radio", try jsonData(RemoteBooleanCommand(enabled: true))),
            (.put, "/api/v1/recording", try jsonData(RemoteBooleanCommand(enabled: true))),
        ]

        for (method, path, body) in operations {
            let response = try requireHTTPResponse(
                await harness.router.handle(
                    harness.request(method, path, token: token, body: body)
                )
            )
            XCTAssertEqual(response.status, 200, path)
        }

        XCTAssertEqual(harness.coordinator.commands.count, operations.count)
        XCTAssertEqual(harness.coordinator.snapshot.revision, 14)
        XCTAssertEqual(
            harness.coordinator.snapshot.selection?.inputRouteID,
            "channels-3-4"
        )
        XCTAssertTrue(harness.coordinator.snapshot.monitor.enabled)
        XCTAssertEqual(harness.coordinator.snapshot.processing.gain, 1.5)
        XCTAssertEqual(harness.coordinator.snapshot.equalizer.bands, bands)
        XCTAssertTrue(harness.coordinator.snapshot.radio.enabled)
        XCTAssertTrue(harness.coordinator.snapshot.recording.enabled)
    }

    func testCommandPayloadValidationReturnsStructured422() async throws {
        let harness = RouterHarness()
        let token = try await harness.pairedToken()
        let invalid: [(String, Data)] = [
            (
                "/api/v1/audio/selection",
                try jsonData(RemoteAudioSelection(inputUID: "", inputRouteID: ""))
            ),
            (
                "/api/v1/processing",
                try jsonData(RemoteProcessingCommand())
            ),
            (
                "/api/v1/processing",
                try jsonData(RemoteProcessingCommand(gain: 4.1))
            ),
            (
                "/api/v1/equalizer",
                try jsonData(
                    RemoteEqualizerCommand(
                        bands: [RemoteEqualizerBand(frequencyHz: 1_000, gainDB: 0)]
                    )
                )
            ),
        ]

        for (path, body) in invalid {
            try await assertProblem(
                request: harness.request(.put, path, token: token, body: body),
                router: harness.router,
                status: 422,
                code: "invalid_command"
            )
        }

        try await assertProblem(
            request: harness.request(
                .put,
                "/api/v1/monitor",
                token: token,
                body: Data(#"{"enabled":"yes"}"#.utf8)
            ),
            router: harness.router,
            status: 422,
            code: "invalid_json"
        )
    }

    func testCoordinatorFailuresMapToExplicitProblemStatuses() async throws {
        let harness = RouterHarness()
        let token = try await harness.pairedToken()
        let mappings: [(RemoteControlFailure.Kind, Int)] = [
            (.conflict, 409),
            (.invalid, 422),
            (.unavailable, 503),
            (.forbidden, 403),
        ]

        for (kind, status) in mappings {
            harness.coordinator.commandFailure = RemoteControlFailure(
                kind: kind,
                code: "test_failure",
                detail: "Deterministic failure"
            )
            try await assertProblem(
                request: harness.request(
                    .put,
                    "/api/v1/recording",
                    token: token,
                    body: try jsonData(RemoteBooleanCommand(enabled: true))
                ),
                router: harness.router,
                status: status,
                code: "test_failure"
            )
        }
    }

    func testFailedDeviceRefreshReturnsStructuredServiceUnavailable()
        async throws
    {
        let harness = RouterHarness()
        let token = try await harness.pairedToken()
        harness.coordinator.commandFailure = RemoteControlFailure(
            kind: .unavailable,
            code: "device_discovery_failed",
            detail: "HAL temporarily unavailable"
        )

        let response = try requireHTTPResponse(
            await harness.router.handle(
                harness.request(
                    .post,
                    "/api/v1/devices/refresh",
                    token: token,
                    body: Data("{}".utf8)
                )
            )
        )

        XCTAssertEqual(response.status, 503)
        XCTAssertEqual(
            response.headers["Content-Type"],
            "application/problem+json; charset=utf-8"
        )
        let problem = try decodeProblem(response)
        XCTAssertEqual(problem.code, "device_discovery_failed")
        XCTAssertEqual(problem.detail, "HAL temporarily unavailable")
        XCTAssertEqual(harness.coordinator.commands, [.refreshDevices])
    }

    func testGeneralRequestRateLimitIsPerSource() async throws {
        let clock = TestRemoteClock(.testReference)
        let limiter = RemoteRequestRateLimiter(
            maximumRequests: 2,
            interval: 60,
            clock: clock
        )

        let first = await limiter.check(remoteAddress: "A")
        let second = await limiter.check(remoteAddress: "a")
        XCTAssertTrue(first.isAllowed)
        XCTAssertTrue(second.isAllowed)
        let limited = await limiter.check(remoteAddress: "A")
        XCTAssertFalse(limited.isAllowed)
        XCTAssertEqual(limited.retryAfterSeconds, 60)
        let otherPeer = await limiter.check(remoteAddress: "B")
        XCTAssertTrue(otherPeer.isAllowed)

        clock.advance(by: 60)
        let afterWindow = await limiter.check(remoteAddress: "a")
        XCTAssertTrue(afterWindow.isAllowed)
    }

    func testGeneralRateLimitBoundsRequestsRejectedDuringValidation() async throws {
        let clock = TestRemoteClock(.testReference)
        let harness = RouterHarness(
            rateLimiter: RemoteRequestRateLimiter(
                maximumRequests: 1,
                interval: 60,
                clock: clock
            )
        )

        var invalidHost = harness.request(
            .get,
            "/",
            remoteAddress: "127.0.0.1"
        )
        invalidHost.headers["host"] = nil
        let cases: [(request: RemoteHTTPRequest, status: Int, code: String)] = [
            (
                harness.request(
                    .get,
                    "//api/v1/state",
                    remoteAddress: "malformed-target-client"
                ),
                400,
                "invalid_request_target"
            ),
            (
                harness.request(
                    .get,
                    "/not-a-route",
                    remoteAddress: "unknown-route-client"
                ),
                404,
                "route_not_found"
            ),
            (
                harness.request(
                    .get,
                    "/api/v1/auth/pair",
                    remoteAddress: "wrong-method-client"
                ),
                405,
                "method_not_allowed"
            ),
            (invalidHost, 421, "invalid_host"),
        ]

        for item in cases {
            let rejected = try requireHTTPResponse(
                await harness.router.handle(item.request)
            )
            XCTAssertEqual(rejected.status, item.status)
            XCTAssertEqual(try decodeProblem(rejected).code, item.code)
            if item.code == "method_not_allowed" {
                XCTAssertEqual(rejected.headers["Allow"], "POST")
            }

            let limited = try requireHTTPResponse(
                await harness.router.handle(item.request)
            )
            XCTAssertEqual(limited.status, 429)
            XCTAssertEqual(limited.headers["Retry-After"], "60")
            XCTAssertEqual(
                try decodeProblem(limited).code,
                "request_rate_limited"
            )
        }
    }

    func testPairingLimiterRetainsItsSpecificLockoutResponse() async throws {
        let clock = TestRemoteClock(.testReference)
        let harness = RouterHarness(
            rateLimiter: RemoteRequestRateLimiter(
                maximumRequests: 10,
                interval: 60,
                clock: clock
            )
        )
        _ = try await harness.pairing.issuePairingCode()
        let request = harness.request(
            .post,
            "/api/v1/auth/pair",
            body: try jsonData(RemotePairRequest(code: "000000")),
            remoteAddress: "127.0.0.8"
        )

        for attempt in 0..<6 {
            let response = try requireHTTPResponse(
                await harness.router.handle(request)
            )
            let problem = try decodeProblem(response)
            if attempt < 5 {
                XCTAssertEqual(response.status, 401)
                XCTAssertEqual(problem.code, "pairing_failed")
            } else {
                XCTAssertEqual(response.status, 429)
                XCTAssertEqual(problem.code, "pairing_rate_limited")
                XCTAssertEqual(response.headers["Retry-After"], "600")
            }
        }
    }

    private func assertProblem(
        request: RemoteHTTPRequest,
        router: RemoteRequestRouter,
        status: Int,
        code: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let response = try requireHTTPResponse(
            await router.handle(request),
            file: file,
            line: line
        )
        XCTAssertEqual(response.status, status, file: file, line: line)
        let problem = try decodeProblem(response, file: file, line: line)
        XCTAssertEqual(
            problem.code,
            code,
            file: file,
            line: line
        )
    }

}
