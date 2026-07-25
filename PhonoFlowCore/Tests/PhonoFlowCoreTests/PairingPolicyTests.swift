import CryptoKit
import Foundation
import Testing

@testable import PhonoFlowCore

@Suite("Pairing policy")
struct PairingPolicyTests {
    private let start = Date(timeIntervalSince1970: 1_750_000_000)

    @Test("Codes are zero-padded, six digits, and expire after ten minutes")
    func codeGenerationAndExpiry() async throws {
        let clock = ManualPairingClock(now: start)
        let randomness = ScriptedRandomness([
            0x00, 0x00, 0x10, 0x92,  // 4,242
        ])
        let policy = try makePolicy(clock: clock, randomness: randomness)

        let challenge = try await policy.generateCode()
        #expect(challenge.code == "004242")
        #expect(challenge.issuedAt == start)
        #expect(challenge.expiresAt == start.addingTimeInterval(600))
        #expect(await policy.currentChallenge() == challenge)

        await clock.advance(by: 600)
        #expect(await policy.currentChallenge() == nil)
    }

    @Test("Code generation rejection-samples to avoid modulo bias")
    func unbiasedCodeGeneration() async throws {
        let clock = ManualPairingClock(now: start)
        let randomness = ScriptedRandomness([
            0xff, 0xff, 0xff, 0xff,  // Rejected.
            0x00, 0x00, 0x00, 0x01,
        ])
        let policy = try makePolicy(clock: clock, randomness: randomness)

        let challenge = try await policy.generateCode()

        #expect(challenge.code == "000001")
        #expect(await randomness.requestCount == 2)
    }

    @Test("A code is invalid at its exact expiry time")
    func expiredPairingCode() async throws {
        let clock = ManualPairingClock(now: start)
        let randomness = ScriptedRandomness(codeBytes + sessionBytes)
        let policy = try makePolicy(clock: clock, randomness: randomness)
        let challenge = try await policy.generateCode()
        await clock.advance(by: 600)

        await expectPolicyError(.codeExpired) {
            _ = try await policy.pair(code: challenge.code, source: "192.168.1.10")
        }
        #expect(await policy.failureCount(for: "192.168.1.10") == 1)
    }

    @Test("The sixth attempt is limited per source for a rolling ten minutes")
    func failureRateLimit() async throws {
        let clock = ManualPairingClock(now: start)
        let randomness = ScriptedRandomness(
            codeBytes + sessionBytes + codeBytes + sessionBytes
        )
        let policy = try makePolicy(clock: clock, randomness: randomness)
        _ = try await policy.generateCode()

        for _ in 0..<5 {
            await expectPolicyError(.invalidCode) {
                _ = try await policy.pair(code: "999999", source: "192.168.1.20")
            }
        }

        await expectPolicyError(
            .rateLimited(retryAfter: start.addingTimeInterval(600))
        ) {
            _ = try await policy.pair(code: "000001", source: "192.168.1.20")
        }

        // Limits are isolated by source.
        let challenge = await policy.currentChallenge()
        let otherSession = try await policy.pair(
            code: try #require(challenge?.code),
            source: "192.168.1.21"
        )
        #expect(otherSession.claims.expiresAt == start.addingTimeInterval(30 * 86_400))

        await clock.advance(by: 601)
        let refreshed = try await policy.generateCode()
        _ = try await policy.pair(code: refreshed.code, source: "192.168.1.20")
    }

    @Test("A successful pairing clears earlier failures for that source")
    func successfulPairingClearsFailures() async throws {
        let clock = ManualPairingClock(now: start)
        let randomness = ScriptedRandomness(codeBytes + sessionBytes)
        let policy = try makePolicy(clock: clock, randomness: randomness)
        let challenge = try await policy.generateCode()

        await expectPolicyError(.invalidCode) {
            _ = try await policy.pair(code: "999999", source: "localhost")
        }
        #expect(await policy.failureCount(for: "localhost") == 1)

        _ = try await policy.pair(code: challenge.code, source: "localhost")
        #expect(await policy.failureCount(for: "localhost") == 0)
    }

    @Test("Pairing issues a signed session valid for thirty days")
    func signedSessionLifetime() async throws {
        let clock = ManualPairingClock(now: start)
        let randomness = ScriptedRandomness(codeBytes + sessionBytes)
        let policy = try makePolicy(clock: clock, randomness: randomness)
        let challenge = try await policy.generateCode()
        let issued = try await policy.pair(
            code: challenge.code,
            source: "fe80::1"
        )

        #expect(issued.claims.version == SessionClaims.currentVersion)
        #expect(issued.claims.issuedAt == start)
        #expect(issued.claims.expiresAt == start.addingTimeInterval(30 * 86_400))
        #expect(issued.token.split(separator: ".").count == 2)
        #expect(try await policy.validate(sessionToken: issued.token) == issued.claims)

        await clock.advance(by: 30 * 86_400)
        await expectPolicyError(.expiredSession) {
            _ = try await policy.validate(sessionToken: issued.token)
        }
    }

    @Test("Issued and decoded claims use identical millisecond precision")
    func canonicalSessionDates() async throws {
        let fractionalStart = Date(timeIntervalSince1970: 1_750_000_000.123_456)
        let clock = ManualPairingClock(now: fractionalStart)
        let randomness = ScriptedRandomness(codeBytes + sessionBytes)
        let policy = try makePolicy(clock: clock, randomness: randomness)
        let challenge = try await policy.generateCode()
        let issued = try await policy.pair(
            code: challenge.code,
            source: "192.168.1.29"
        )

        let validated = try await policy.validate(sessionToken: issued.token)

        #expect(validated == issued.claims)
        #expect(
            issued.claims.expiresAt.timeIntervalSince(issued.claims.issuedAt)
                == 30 * 86_400)
    }

    @Test("Payload and signature tampering are rejected")
    func tamperedSession() async throws {
        let clock = ManualPairingClock(now: start)
        let randomness = ScriptedRandomness(codeBytes + sessionBytes)
        let policy = try makePolicy(clock: clock, randomness: randomness)
        let challenge = try await policy.generateCode()
        let issued = try await policy.pair(
            code: challenge.code,
            source: "192.168.1.30"
        )
        let pieces = issued.token.split(separator: ".").map(String.init)

        let tamperedPayload = mutateFirstCharacter(pieces[0]) + "." + pieces[1]
        await expectPolicyError(.invalidSessionSignature) {
            _ = try await policy.validate(sessionToken: tamperedPayload)
        }

        let tamperedSignature = pieces[0] + "." + mutateFirstCharacter(pieces[1])
        await expectPolicyError(.invalidSessionSignature) {
            _ = try await policy.validate(sessionToken: tamperedSignature)
        }
    }

    @Test("Rotating the injected signer invalidates existing browser sessions")
    func signerRotationRevokesSessions() async throws {
        let clock = ManualPairingClock(now: start)
        let randomness = ScriptedRandomness(codeBytes + sessionBytes)
        let original = try makePolicy(
            clock: clock,
            randomness: randomness,
            secret: Data("original-secret".utf8)
        )
        let challenge = try await original.generateCode()
        let issued = try await original.pair(
            code: challenge.code,
            source: "192.168.1.40"
        )

        let rotated = try makePolicy(
            clock: clock,
            randomness: ScriptedRandomness([]),
            secret: Data("rotated-secret".utf8)
        )
        await expectPolicyError(.invalidSessionSignature) {
            _ = try await rotated.validate(sessionToken: issued.token)
        }
    }

    @Test("Malformed codes, invalid sources, and absent challenges are rejected")
    func invalidInputs() async throws {
        let clock = ManualPairingClock(now: start)
        let policy = try makePolicy(
            clock: clock,
            randomness: ScriptedRandomness(codeBytes)
        )

        await expectPolicyError(.invalidSource) {
            _ = try await policy.pair(code: "123456", source: "")
        }
        await expectPolicyError(.noActiveCode) {
            _ = try await policy.pair(code: "123456", source: "192.168.1.50")
        }

        let challenge = try await policy.generateCode()
        for malformed in ["12345", "1234567", "１２３４５６", "12 456", "abcdef"] {
            await expectPolicyError(.invalidCode) {
                _ = try await policy.pair(
                    code: malformed,
                    source: "192.168.1.\(malformed.utf8.count)"
                )
            }
        }
        #expect(challenge.code == "000001")
    }

    @Test("Concurrent failures cannot bypass the actor-isolated limit")
    func concurrentRateLimit() async throws {
        let clock = ManualPairingClock(now: start)
        let policy = try makePolicy(
            clock: clock,
            randomness: ScriptedRandomness(codeBytes)
        )
        _ = try await policy.generateCode()

        let errors = await withTaskGroup(
            of: PairingPolicyError?.self,
            returning: [PairingPolicyError].self
        ) { group in
            for _ in 0..<12 {
                group.addTask {
                    do {
                        _ = try await policy.pair(
                            code: "999999",
                            source: "192.168.1.60"
                        )
                        return nil
                    } catch let error as PairingPolicyError {
                        return error
                    } catch {
                        return nil
                    }
                }
            }

            var collected: [PairingPolicyError] = []
            for await error in group {
                if let error {
                    collected.append(error)
                }
            }
            return collected
        }

        #expect(errors.filter { $0 == .invalidCode }.count == 5)
        #expect(
            errors.filter {
                if case .rateLimited = $0 { return true }
                return false
            }.count == 7)
        #expect(await policy.failureCount(for: "192.168.1.60") == 5)
    }

    @Test("A valid challenge cannot be replayed while session issuance is suspended")
    func concurrentSuccessfulPairingConsumesChallengeOnce() async throws {
        let clock = ManualPairingClock(now: start)
        let randomness = SuspendingSessionRandomness()
        let policy = PairingPolicy(
            clock: clock,
            randomness: randomness,
            signer: try HMACSHA256SessionSigner(secret: Data("unit-test-secret".utf8))
        )
        let challenge = try await policy.generateCode()

        let firstPair = Task {
            try await policy.pair(code: challenge.code, source: "192.168.1.70")
        }
        for _ in 0..<2_000 {
            if await randomness.isSessionRequestSuspended() {
                break
            }
            await Task.yield()
        }
        #expect(await randomness.isSessionRequestSuspended())

        await expectPolicyError(.noActiveCode) {
            _ = try await policy.pair(
                code: challenge.code,
                source: "192.168.1.71"
            )
        }

        await randomness.resumeSessionRequest()
        _ = try await firstPair.value
        await expectPolicyError(.noActiveCode) {
            _ = try await policy.pair(
                code: challenge.code,
                source: "192.168.1.72"
            )
        }
    }

    @Test("A challenge remains retryable when session issuance fails")
    func failedSessionIssuanceRestoresChallenge() async throws {
        let clock = ManualPairingClock(now: start)
        let randomness = FailOnceSessionRandomness()
        let policy = PairingPolicy(
            clock: clock,
            randomness: randomness,
            signer: try HMACSHA256SessionSigner(secret: Data("unit-test-secret".utf8))
        )
        let challenge = try await policy.generateCode()

        do {
            _ = try await policy.pair(
                code: challenge.code,
                source: "192.168.1.80"
            )
            Issue.record("Expected the injected session-randomness failure")
        } catch let error as PairingRandomnessError {
            #expect(error == .generationFailed(status: -77))
        }

        #expect(await policy.currentChallenge() == challenge)
        _ = try await policy.pair(
            code: challenge.code,
            source: "192.168.1.80"
        )
        #expect(await policy.currentChallenge() == nil)
    }

    private var codeBytes: [UInt8] {
        [0x00, 0x00, 0x00, 0x01]
    }

    private var sessionBytes: [UInt8] {
        Array(0..<16)
    }

    private func makePolicy(
        clock: ManualPairingClock,
        randomness: ScriptedRandomness,
        secret: Data = Data("unit-test-secret".utf8)
    ) throws -> PairingPolicy {
        PairingPolicy(
            clock: clock,
            randomness: randomness,
            signer: try HMACSHA256SessionSigner(secret: secret)
        )
    }
}

private actor ManualPairingClock: PairingClock {
    private var timestamp: Date

    init(now: Date) {
        timestamp = now
    }

    func now() -> Date {
        timestamp
    }

    func advance(by interval: TimeInterval) {
        timestamp = timestamp.addingTimeInterval(interval)
    }
}

private actor ScriptedRandomness: PairingRandomness {
    private let bytes: [UInt8]
    private var offset = 0
    private(set) var requestCount = 0

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    func randomBytes(count: Int) throws -> [UInt8] {
        requestCount += 1
        guard count >= 0, offset + count <= bytes.count else {
            throw PairingRandomnessError.generationFailed(status: -1)
        }
        defer { offset += count }
        return Array(bytes[offset..<(offset + count)])
    }
}

private actor SuspendingSessionRandomness: PairingRandomness {
    private var continuation: CheckedContinuation<[UInt8], Error>?
    private var sessionRequestSuspended = false

    func randomBytes(count: Int) async throws -> [UInt8] {
        switch count {
        case 4:
            return [0x00, 0x00, 0x00, 0x01]
        case 16:
            sessionRequestSuspended = true
            return try await withCheckedThrowingContinuation {
                continuation = $0
            }
        default:
            throw PairingRandomnessError.invalidCount
        }
    }

    func isSessionRequestSuspended() -> Bool {
        sessionRequestSuspended
    }

    func resumeSessionRequest() {
        sessionRequestSuspended = false
        continuation?.resume(returning: Array(0..<16))
        continuation = nil
    }
}

private actor FailOnceSessionRandomness: PairingRandomness {
    private var failedSessionRequest = false

    func randomBytes(count: Int) async throws -> [UInt8] {
        switch count {
        case 4:
            return [0x00, 0x00, 0x00, 0x01]
        case 16 where !failedSessionRequest:
            failedSessionRequest = true
            throw PairingRandomnessError.generationFailed(status: -77)
        case 16:
            return Array(0..<16)
        default:
            throw PairingRandomnessError.invalidCount
        }
    }
}

private func expectPolicyError(
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

private func mutateFirstCharacter(_ value: String) -> String {
    guard let first = value.first else {
        return value
    }
    return (first == "A" ? "B" : "A") + String(value.dropFirst())
}
