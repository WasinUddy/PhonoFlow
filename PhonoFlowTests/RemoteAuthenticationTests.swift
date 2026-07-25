import Foundation
import XCTest

@testable import PhonoFlow

@MainActor
final class RemoteAuthenticationTests: XCTestCase {
    func testPairingCodeExpiresAfterTenMinutes() async throws {
        let clock = TestRemoteClock(.testReference)
        let service = makeService(clock: clock)
        let code = try await service.issuePairingCode()

        clock.advance(by: RemotePairingService.pairingLifetime + 1)

        do {
            _ = try await service.pair(code: code.code, remoteAddress: "192.168.1.20")
            XCTFail("Expired code should not pair")
        } catch let error as RemoteAuthenticationError {
            XCTAssertEqual(error, .invalidPairingCode)
        }
        let current = await service.currentPairingCode()
        XCTAssertNil(current)
    }

    func testFiveFailuresRateLimitOnlyTheCanonicalSourceAddress() async throws {
        let clock = TestRemoteClock(.testReference)
        let service = makeService(clock: clock)
        let validCode = try await service.issuePairingCode()

        for _ in 0..<5 {
            do {
                _ = try await service.pair(
                    code: "999999",
                    remoteAddress: "[FE80::CAFE]"
                )
                XCTFail("Invalid code should fail")
            } catch let error as RemoteAuthenticationError {
                XCTAssertEqual(error, .invalidPairingCode)
            }
        }

        do {
            _ = try await service.pair(
                code: validCode.code,
                remoteAddress: "fe80::cafe"
            )
            XCTFail("Sixth attempt from the same canonical peer should be rate limited")
        } catch let error as RemoteAuthenticationError {
            guard case .pairingRateLimited(let retryAfter) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(retryAfter, 600)
        }

        let issued = try await service.pair(
            code: validCode.code,
            remoteAddress: "192.168.1.21"
        )
        let validated = try await service.validate(token: issued.token)
        XCTAssertEqual(validated, issued.principal)
    }

    func testSuccessfulPairConsumesCodeAndIssuesThirtyDaySignedSession() async throws {
        let clock = TestRemoteClock(.testReference)
        let service = makeService(clock: clock)
        let code = try await service.issuePairingCode()
        let issued = try await service.pair(
            code: code.code,
            remoteAddress: "192.168.1.40"
        )

        XCTAssertEqual(
            issued.principal.expiresAt,
            clock.now.addingTimeInterval(RemotePairingService.sessionLifetime)
        )
        XCTAssertTrue(issued.token.hasPrefix("v1."))
        let validated = try await service.validate(token: issued.token)
        XCTAssertEqual(validated, issued.principal)
        let current = await service.currentPairingCode()
        XCTAssertNil(current)
    }

    func testSessionIssuedAtFractionalClockPrecisionValidates() async throws {
        let fractionalNow = Date(
            timeIntervalSince1970: Date.testReference.timeIntervalSince1970 + 0.875
        )
        let clock = TestRemoteClock(fractionalNow)
        let service = makeService(clock: clock)
        let code = try await service.issuePairingCode()

        let issued = try await service.pair(
            code: code.code,
            remoteAddress: "192.168.1.41"
        )
        let validated = try await service.validate(token: issued.token)

        XCTAssertEqual(validated, issued.principal)
        XCTAssertEqual(
            issued.principal.expiresAt.timeIntervalSince1970,
            floor(fractionalNow.timeIntervalSince1970)
                + RemotePairingService.sessionLifetime
        )
    }

    func testRevokeInvalidatesOneSession() async throws {
        let service = makeService(clock: TestRemoteClock(.testReference))
        let code = try await service.issuePairingCode()
        let issued = try await service.pair(
            code: code.code,
            remoteAddress: "192.168.1.10"
        )

        let revoked = try await service.revoke(token: issued.token)
        XCTAssertEqual(revoked, issued.principal)
        await assertInvalidSession(issued.token, service: service)
    }

    func testRevokeAllRotatesSecretAndInvalidatesExistingTokens() async throws {
        let service = makeService(clock: TestRemoteClock(.testReference))
        let firstCode = try await service.issuePairingCode()
        let first = try await service.pair(
            code: firstCode.code,
            remoteAddress: "192.168.1.10"
        )
        let secondCode = try await service.issuePairingCode()
        let second = try await service.pair(
            code: secondCode.code,
            remoteAddress: "192.168.1.11"
        )
        let outstandingCode = try await service.issuePairingCode()

        try await service.revokeAll()

        await assertInvalidSession(first.token, service: service)
        await assertInvalidSession(second.token, service: service)
        let currentCode = await service.currentPairingCode()
        XCTAssertNil(currentCode)
        do {
            _ = try await service.pair(
                code: outstandingCode.code,
                remoteAddress: "192.168.1.12"
            )
            XCTFail("Revoke all must invalidate an outstanding pairing code")
        } catch let error as RemoteAuthenticationError {
            XCTAssertEqual(error, .invalidPairingCode)
        }
    }

    func testSuspendedPairingWriteCannotOverwriteRevokeAllRotation() async throws {
        let store = ControllableRemoteCredentialStore()
        let service = RemotePairingService(
            store: store,
            clock: TestRemoteClock(.testReference),
            random: CountingRemoteRandom()
        )
        try await service.prepare()
        let code = try await service.issuePairingCode()
        await store.suspendNextWrite()

        let pairTask = Task {
            try await service.pair(
                code: code.code,
                remoteAddress: "192.168.1.70"
            )
        }
        await waitUntil {
            await store.hasSuspendedWrite()
        }

        let revokeTask = Task {
            try await service.revokeAll()
        }
        for _ in 0..<100 {
            await Task.yield()
        }
        let writesBeforeResume = await store.writeCount()
        XCTAssertEqual(
            writesBeforeResume,
            2,
            "Revoke all must wait for the older credential transaction instead of writing concurrently."
        )

        await store.resumeWrite()
        let issued = try await pairTask.value
        try await revokeTask.value
        await assertInvalidSession(issued.token, service: service)
    }

    func testPairingCodeRemainsRetryableWhenCredentialPersistenceFails() async throws {
        let store = ControllableRemoteCredentialStore()
        let service = RemotePairingService(
            store: store,
            clock: TestRemoteClock(.testReference),
            random: CountingRemoteRandom()
        )
        try await service.prepare()
        let code = try await service.issuePairingCode()
        await store.failNextWrite()

        do {
            _ = try await service.pair(
                code: code.code,
                remoteAddress: "192.168.1.80"
            )
            XCTFail("The injected credential write should fail")
        } catch let error as RemoteAuthenticationError {
            XCTAssertEqual(error, .credentialFailure)
        }

        let retryableCode = await service.currentPairingCode()
        XCTAssertEqual(retryableCode, code)
        let issued = try await service.pair(
            code: code.code,
            remoteAddress: "192.168.1.80"
        )
        let validated = try await service.validate(token: issued.token)
        XCTAssertEqual(validated, issued.principal)
    }

    func testExpiredSessionCleanupFailureDoesNotRejectLiveSessionAndRetries() async throws {
        let day: TimeInterval = 24 * 60 * 60
        let clock = TestRemoteClock(.testReference)
        let store = ControllableRemoteCredentialStore()
        let service = RemotePairingService(
            store: store,
            clock: clock,
            random: CountingRemoteRandom()
        )
        try await service.prepare()

        let firstCode = try await service.issuePairingCode()
        _ = try await service.pair(
            code: firstCode.code,
            remoteAddress: "192.168.1.81"
        )
        clock.advance(by: day)
        let secondCode = try await service.issuePairingCode()
        let live = try await service.pair(
            code: secondCode.code,
            remoteAddress: "192.168.1.82"
        )
        clock.advance(by: 29 * day + 1)

        await store.failNextWrite()
        let writesBeforeCleanup = await store.writeCount()
        let firstValidation = try await service.validate(token: live.token)
        XCTAssertEqual(
            firstValidation,
            live.principal,
            "Housekeeping failure must not invalidate an otherwise-live token."
        )
        let writesAfterFailure = await store.writeCount()
        XCTAssertEqual(writesAfterFailure, writesBeforeCleanup + 1)

        let secondValidation = try await service.validate(token: live.token)
        XCTAssertEqual(secondValidation, live.principal)
        let writesAfterRetry = await store.writeCount()
        XCTAssertEqual(
            writesAfterRetry,
            writesBeforeCleanup + 2,
            "The unpersisted cleanup must be retried on the next validation."
        )
    }

    func testPrincipalGenerationIsRejectedAfterSecretRotation() async throws {
        let service = makeService(clock: TestRemoteClock(.testReference))
        let code = try await service.issuePairingCode()
        let issued = try await service.pair(
            code: code.code,
            remoteAddress: "192.168.1.83"
        )

        try await service.validate(principal: issued.principal)
        try await service.revokeAll()
        do {
            try await service.validate(principal: issued.principal)
            XCTFail("A principal from the previous credential generation remained valid")
        } catch let error as RemoteAuthenticationError {
            XCTAssertEqual(error, .invalidSession)
        }
    }

    func testSessionCookieIsHttpOnlyStrictAndRoundTripsAmongOtherCookies() {
        let token = "v1.payload.signature"
        let setCookie = RemotePairingService.sessionCookie(token: token)

        XCTAssertTrue(setCookie.contains("HttpOnly"))
        XCTAssertTrue(setCookie.contains("SameSite=Strict"))
        XCTAssertTrue(setCookie.contains("Max-Age=2592000"))
        XCTAssertEqual(
            RemotePairingService.token(
                fromCookieHeader: "theme=dark; PhonoFlowSession=\(token); other=value"
            ),
            token
        )
        XCTAssertNil(
            RemotePairingService.token(
                fromCookieHeader: "PhonoFlowSession=; theme=dark"
            )
        )
    }

    private func makeService(clock: TestRemoteClock) -> RemotePairingService {
        RemotePairingService(
            store: InMemoryRemoteCredentialStore(),
            clock: clock,
            random: CountingRemoteRandom()
        )
    }

    private func assertInvalidSession(
        _ token: String,
        service: RemotePairingService,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await service.validate(token: token)
            XCTFail("Expected an invalid session", file: file, line: line)
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
        XCTFail("Timed out waiting for the credential store.")
    }
}

private actor ControllableRemoteCredentialStore:
    nonisolated RemoteCredentialStoring
{
    private var data: Data?
    private var writes = 0
    private var shouldSuspendNextWrite = false
    private var shouldFailNextWrite = false
    private var suspendedWrite = false
    private var continuation: CheckedContinuation<Void, Never>?

    func readCredential() async throws -> Data? {
        data
    }

    func writeCredential(_ data: Data) async throws {
        writes += 1
        if shouldFailNextWrite {
            shouldFailNextWrite = false
            throw ControllableCredentialStoreError.injected
        }
        if shouldSuspendNextWrite {
            shouldSuspendNextWrite = false
            suspendedWrite = true
            await withCheckedContinuation {
                continuation = $0
            }
            suspendedWrite = false
        }
        self.data = data
    }

    func suspendNextWrite() {
        shouldSuspendNextWrite = true
    }

    func failNextWrite() {
        shouldFailNextWrite = true
    }

    func hasSuspendedWrite() -> Bool {
        suspendedWrite
    }

    func writeCount() -> Int {
        writes
    }

    func resumeWrite() {
        continuation?.resume()
        continuation = nil
    }
}

private enum ControllableCredentialStoreError: Error {
    case injected
}
