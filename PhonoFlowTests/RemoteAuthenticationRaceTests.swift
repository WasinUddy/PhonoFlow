import Foundation
import XCTest

@testable import PhonoFlow

@MainActor
final class RemoteAuthenticationRaceTests: XCTestCase {
    func testLogoutDuringAudioRegistrationCannotLeaveAStaleStream() async throws {
        let pairing = RemotePairingService(
            store: InMemoryRemoteCredentialStore(),
            clock: TestRemoteClock(.testReference),
            random: CountingRemoteRandom()
        )
        let baseAudio = RemoteAudioFanout(clock: TestRemoteClock(.testReference))
        let suspendedAudio = SuspendingRemoteAudioProvider(base: baseAudio)
        let context = makeContext(pairing: pairing, audio: suspendedAudio)
        let token = try await pairToken(pairing: pairing)

        await suspendedAudio.suspendNextSubscription()
        let streamRequest = context.request(
            .get,
            "/audio/live.wav",
            token: token
        )
        let streamTask = Task {
            await context.router.handle(streamRequest)
        }
        await waitUntil {
            await suspendedAudio.isSubscriptionSuspended()
        }

        let logout = try requireHTTPResponse(
            await context.router.handle(
                context.request(
                    .post,
                    "/api/v1/auth/logout",
                    token: token,
                    body: Data("{}".utf8)
                )
            )
        )
        XCTAssertEqual(logout.status, 204)
        let listenersAfterLogout = await baseAudio.listenerCount()
        XCTAssertEqual(listenersAfterLogout, 0)

        await suspendedAudio.resumeSubscription()
        let staleRegistration = try requireHTTPResponse(await streamTask.value)
        XCTAssertEqual(staleRegistration.status, 401)
        XCTAssertEqual(
            try decodeProblem(staleRegistration).code,
            "authentication_required"
        )
        let listenersAfterRevalidation = await baseAudio.listenerCount()
        XCTAssertEqual(listenersAfterRevalidation, 0)
    }

    func testFailedLogoutKeepsCookieTokenAndStreamsLive() async throws {
        let store = FailableRemoteCredentialStore()
        let pairing = RemotePairingService(
            store: store,
            clock: TestRemoteClock(.testReference),
            random: CountingRemoteRandom()
        )
        let audio = RemoteAudioFanout(clock: TestRemoteClock(.testReference))
        let context = makeContext(pairing: pairing, audio: audio)
        let token = try await pairToken(pairing: pairing)
        let principal = try await pairing.validate(token: token)
        let subscription = try await audio.subscribe(
            kind: .pcm16Browser,
            principal: principal,
            remoteAddress: "127.0.0.1"
        )
        await store.failWrites()

        let response = try requireHTTPResponse(
            await context.router.handle(
                context.request(
                    .post,
                    "/api/v1/auth/logout",
                    token: token,
                    body: Data("{}".utf8)
                )
            )
        )

        XCTAssertEqual(response.status, 503)
        XCTAssertNil(response.headers["Set-Cookie"])
        XCTAssertEqual(
            try decodeProblem(response).code,
            "credential_persistence_failed"
        )
        let stillValidPrincipal = try await pairing.validate(token: token)
        XCTAssertEqual(stillValidPrincipal, principal)
        let listenersAfterFailedLogout = await audio.listenerCount()
        XCTAssertEqual(listenersAfterFailedLogout, 1)
        await subscription.cancel()
    }

    func testSessionCapacityEvictionClosesEventAndAudioStreams() async throws {
        let clock = TestRemoteClock(.testReference)
        let pairing = RemotePairingService(
            store: InMemoryRemoteCredentialStore(),
            clock: clock,
            random: CountingRemoteRandom(),
            maximumSessions: 1
        )
        let events = RemoteEventHub(clock: clock)
        let audio = RemoteAudioFanout(clock: clock)
        let context = makeContext(
            pairing: pairing,
            events: events,
            audio: audio
        )
        let firstToken = try await pairToken(
            pairing: pairing,
            remoteAddress: "192.0.2.1"
        )
        let firstPrincipal = try await pairing.validate(token: firstToken)
        let eventSubscription = try await events.subscribe(
            principal: firstPrincipal,
            snapshot: .fixture(),
            remoteAddress: "192.0.2.1"
        )
        let audioSubscription = try await audio.subscribe(
            kind: .pcm16Browser,
            principal: firstPrincipal,
            remoteAddress: "192.0.2.1"
        )
        var eventIterator = eventSubscription.stream.makeAsyncIterator()
        var audioIterator = audioSubscription.stream.makeAsyncIterator()

        let replacementCode = try await pairing.issuePairingCode()
        let response = try requireHTTPResponse(
            await context.router.handle(
                context.request(
                    .post,
                    "/api/v1/auth/pair",
                    body: try jsonData(
                        RemotePairRequest(code: replacementCode.code)
                    )
                )
            )
        )

        XCTAssertEqual(response.status, 200)
        let eventClientCount = await events.clientCount
        let audioClientCount = await audio.listenerCount()
        XCTAssertEqual(eventClientCount, 0)
        XCTAssertEqual(audioClientCount, 0)
        guard response.status == 200,
            eventClientCount == 0,
            audioClientCount == 0
        else {
            await eventSubscription.cancel()
            await audioSubscription.cancel()
            return
        }
        let eventAfterEviction = await eventIterator.next()
        let audioAfterEviction = await audioIterator.next()
        XCTAssertNil(eventAfterEviction)
        XCTAssertNil(audioAfterEviction)
        do {
            _ = try await pairing.validate(token: firstToken)
            XCTFail("The capacity-evicted session remained valid")
        } catch let error as RemoteAuthenticationError {
            XCTAssertEqual(error, .invalidSession)
        }
    }

    private func makeContext(
        pairing: RemotePairingService,
        events: RemoteEventHub? = nil,
        audio: any RemoteAudioStreamProviding
    ) -> AuthenticationRouterContext {
        let configuration = RemoteAccessConfiguration(
            bindHost: "127.0.0.1",
            port: 17_866,
            generalRequestsPerMinute: 240,
            advertiseBonjour: false
        )
        let coordinator = FakeRemoteCoordinator(snapshot: .fixture())
        let events = events ?? RemoteEventHub(clock: TestRemoteClock(.testReference))
        let router = RemoteRequestRouter(
            configuration: configuration,
            coordinator: coordinator,
            pairing: pairing,
            eventHub: events,
            audio: audio,
            assets: InMemoryRemoteStaticAssetProvider(assets: [:])
        )
        return AuthenticationRouterContext(
            configuration: configuration,
            coordinator: coordinator,
            events: events,
            router: router
        )
    }

    private func pairToken(
        pairing: RemotePairingService,
        remoteAddress: String = "127.0.0.1"
    ) async throws -> String {
        let code = try await pairing.issuePairingCode()
        return try await pairing.pair(
            code: code.code,
            remoteAddress: remoteAddress
        ).token
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
        XCTFail("Timed out waiting for the suspended stream registration.")
    }
}

@MainActor
private struct AuthenticationRouterContext {
    let configuration: RemoteAccessConfiguration
    // Retain the router's weak coordinator for the duration of each test.
    let coordinator: FakeRemoteCoordinator
    let events: RemoteEventHub
    let router: RemoteRequestRouter

    func request(
        _ method: RemoteHTTPMethod,
        _ target: String,
        token: String? = nil,
        body: Data = Data(),
        remoteAddress: String = "127.0.0.1"
    ) -> RemoteHTTPRequest {
        var headers = ["Host": "localhost:\(configuration.port)"]
        if let token {
            headers["Cookie"] = "\(RemotePairingService.cookieName)=\(token)"
        }
        if method.isMutation {
            headers["Origin"] = "http://localhost:\(configuration.port)"
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
}

private actor FailableRemoteCredentialStore:
    nonisolated RemoteCredentialStoring
{
    private var credential: Data?
    private var writesFail = false

    func readCredential() async throws -> Data? {
        credential
    }

    func writeCredential(_ data: Data) async throws {
        guard !writesFail else {
            throw FailableRemoteCredentialStoreError.injected
        }
        credential = data
    }

    func failWrites() {
        writesFail = true
    }
}

private enum FailableRemoteCredentialStoreError: Error {
    case injected
}

private actor SuspendingRemoteAudioProvider:
    nonisolated RemoteAudioStreamProviding
{
    private let base: RemoteAudioFanout
    private var shouldSuspendNextSubscription = false
    private var subscriptionSuspended = false
    private var continuation: CheckedContinuation<Void, Never>?

    init(base: RemoteAudioFanout) {
        self.base = base
    }

    func suspendNextSubscription() {
        shouldSuspendNextSubscription = true
    }

    func isSubscriptionSuspended() -> Bool {
        subscriptionSuspended
    }

    func resumeSubscription() {
        subscriptionSuspended = false
        continuation?.resume()
        continuation = nil
    }

    func subscribe(
        kind: RemoteAudioStreamKind,
        principal: RemoteSessionPrincipal?,
        remoteAddress: String,
        origin: RemoteAudioSubscriptionOrigin
    ) async throws -> RemoteAudioSubscription {
        if shouldSuspendNextSubscription {
            shouldSuspendNextSubscription = false
            subscriptionSuspended = true
            await withCheckedContinuation {
                continuation = $0
            }
            subscriptionSuspended = false
        }
        return try await base.subscribe(
            kind: kind,
            principal: principal,
            remoteAddress: remoteAddress,
            origin: origin
        )
    }

    func unsubscribe(_ id: UUID) async {
        await base.unsubscribe(id)
    }

    func revoke(sessionID: String) async {
        await base.revoke(sessionID: sessionID)
    }

    func revoke(kind: RemoteAudioStreamKind) async {
        await base.revoke(kind: kind)
    }

    func revoke(origin: RemoteAudioSubscriptionOrigin) async {
        await base.revoke(origin: origin)
    }

    func revokeAllAuthenticated() async {
        await base.revokeAllAuthenticated()
    }

    func listenerCount() async -> Int {
        await base.listenerCount()
    }

    func listenerCount(kind: RemoteAudioStreamKind) async -> Int {
        await base.listenerCount(kind: kind)
    }
}
