import CryptoKit
import Foundation
import Security

/// Supplies wall-clock time to pairing and session validation.
///
/// An asynchronous requirement lets tests use an actor-backed manual clock
/// without introducing unchecked sendability solely for testability.
public protocol PairingClock: Sendable {
    func now() async -> Date
}

public struct SystemPairingClock: PairingClock {
    public init() {}

    public func now() async -> Date {
        Date()
    }
}

/// Supplies cryptographically secure bytes to the pairing policy.
public protocol PairingRandomness: Sendable {
    func randomBytes(count: Int) async throws -> [UInt8]
}

public enum PairingRandomnessError: Error, Equatable, Sendable {
    case invalidCount
    case generationFailed(status: Int32)
}

public struct SystemPairingRandomness: PairingRandomness {
    public init() {}

    public func randomBytes(count: Int) async throws -> [UInt8] {
        guard count >= 0 else {
            throw PairingRandomnessError.invalidCount
        }
        guard count > 0 else {
            return []
        }

        var bytes = [UInt8](repeating: 0, count: count)
        let status = bytes.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else {
                return errSecParam
            }
            return SecRandomCopyBytes(
                kSecRandomDefault,
                count,
                baseAddress
            )
        }
        guard status == errSecSuccess else {
            throw PairingRandomnessError.generationFailed(status: status)
        }
        return bytes
    }
}

/// Produces a message authentication signature.
///
/// Secret storage and rotation intentionally live outside this abstraction so
/// an app can source the secret from Keychain while tests use deterministic
/// signers.
public protocol SessionSigning: Sendable {
    func signature(for message: Data) throws -> Data
}

public enum SessionSignerError: Error, Equatable, Sendable {
    case emptySecret
}

public struct HMACSHA256SessionSigner: SessionSigning {
    private let key: SymmetricKey

    public init(secret: Data) throws {
        guard !secret.isEmpty else {
            throw SessionSignerError.emptySecret
        }
        key = SymmetricKey(data: secret)
    }

    public func signature(for message: Data) throws -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: message, using: key))
    }
}

public struct PairingChallenge: Codable, Equatable, Sendable {
    public let code: String
    public let issuedAt: Date
    public let expiresAt: Date

    public init(code: String, issuedAt: Date, expiresAt: Date) {
        self.code = code
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
    }
}

public struct SessionClaims: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    public let sessionID: String
    public let issuedAt: Date
    public let expiresAt: Date

    public init(
        version: Int = SessionClaims.currentVersion,
        sessionID: String,
        issuedAt: Date,
        expiresAt: Date
    ) {
        self.version = version
        self.sessionID = sessionID
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
    }
}

public struct SignedPairingSession: Codable, Equatable, Sendable {
    public let token: String
    public let claims: SessionClaims

    public init(token: String, claims: SessionClaims) {
        self.token = token
        self.claims = claims
    }
}

public enum PairingPolicyError: Error, Equatable, Sendable {
    case invalidSource
    case noActiveCode
    case codeExpired
    case invalidCode
    case rateLimited(retryAfter: Date)
    case invalidRandomness
    case randomnessExhausted
    case malformedSession
    case invalidSessionSignature
    case unsupportedSessionVersion
    case expiredSession
}

extension PairingPolicyError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidSource:
            "The pairing source is missing or invalid."
        case .noActiveCode:
            "Generate a pairing code before pairing a browser."
        case .codeExpired:
            "The pairing code has expired."
        case .invalidCode:
            "The pairing code is invalid."
        case .rateLimited(let retryAfter):
            "Too many pairing attempts. Try again after \(retryAfter.formatted())."
        case .invalidRandomness:
            "The randomness provider returned an invalid result."
        case .randomnessExhausted:
            "Unable to generate an unbiased pairing code."
        case .malformedSession:
            "The session token is malformed."
        case .invalidSessionSignature:
            "The session signature is invalid."
        case .unsupportedSessionVersion:
            "The session version is not supported."
        case .expiredSession:
            "The session has expired."
        }
    }
}

/// Generates short-lived pairing codes, rate-limits failed attempts, and
/// issues signed browser sessions.
///
/// All mutable state is actor-isolated. Callers should use a normalized source
/// address (normally the remote IP address) for `source`.
public actor PairingPolicy {
    public struct Configuration: Equatable, Sendable {
        public var codeLifetime: TimeInterval
        public var failureWindow: TimeInterval
        public var maximumFailuresPerSource: Int
        public var sessionLifetime: TimeInterval

        public init(
            codeLifetime: TimeInterval = 10 * 60,
            failureWindow: TimeInterval = 10 * 60,
            maximumFailuresPerSource: Int = 5,
            sessionLifetime: TimeInterval = 30 * 24 * 60 * 60
        ) {
            precondition(codeLifetime > 0, "Pairing code lifetime must be positive")
            precondition(failureWindow > 0, "Failure window must be positive")
            precondition(maximumFailuresPerSource > 0, "Maximum failures must be positive")
            precondition(sessionLifetime > 0, "Session lifetime must be positive")

            self.codeLifetime = codeLifetime
            self.failureWindow = failureWindow
            self.maximumFailuresPerSource = maximumFailuresPerSource
            self.sessionLifetime = sessionLifetime
        }

        public static let `default` = Configuration()
    }

    private let configuration: Configuration
    private let clock: any PairingClock
    private let randomness: any PairingRandomness
    private let signer: any SessionSigning

    private var activeChallenge: PairingChallenge?
    private var reservedChallenge: (id: UInt64, challenge: PairingChallenge)?
    private var nextReservationID: UInt64 = 0
    private var failuresBySource: [String: [Date]] = [:]

    public init(
        configuration: Configuration = .default,
        clock: any PairingClock = SystemPairingClock(),
        randomness: any PairingRandomness = SystemPairingRandomness(),
        signer: any SessionSigning
    ) {
        self.configuration = configuration
        self.clock = clock
        self.randomness = randomness
        self.signer = signer
    }

    /// Replaces any previous challenge with a new six-digit code.
    @discardableResult
    public func generateCode() async throws -> PairingChallenge {
        let timestamp = await clock.now()
        let code = try await generateSixDigitCode()
        let challenge = PairingChallenge(
            code: code,
            issuedAt: timestamp,
            expiresAt: timestamp.addingTimeInterval(configuration.codeLifetime)
        )
        // A newly generated native code supersedes an in-flight reservation.
        // The already-authorized attempt may still finish, but its cleanup
        // must never consume this newer challenge.
        reservedChallenge = nil
        activeChallenge = challenge
        pruneFailures(at: timestamp)
        return challenge
    }

    public func currentChallenge() async -> PairingChallenge? {
        guard let challenge = activeChallenge else {
            return nil
        }

        let timestamp = await clock.now()
        guard timestamp < challenge.expiresAt else {
            activeChallenge = nil
            return nil
        }
        return challenge
    }

    /// Validates a pairing attempt and returns a signed 30-day session.
    ///
    /// The first five failures in a rolling window are reported normally. Any
    /// further attempt from the same source is rate-limited until its oldest
    /// retained failure leaves the window.
    public func pair(code: String, source: String) async throws -> SignedPairingSession {
        guard isValidSource(source) else {
            throw PairingPolicyError.invalidSource
        }

        let timestamp = await clock.now()
        let failures = activeFailures(for: source, at: timestamp)
        if failures.count >= configuration.maximumFailuresPerSource,
            let oldestFailure = failures.first
        {
            throw PairingPolicyError.rateLimited(
                retryAfter: oldestFailure.addingTimeInterval(configuration.failureWindow)
            )
        }

        guard let challenge = activeChallenge else {
            recordFailure(for: source, at: timestamp)
            throw PairingPolicyError.noActiveCode
        }
        guard timestamp < challenge.expiresAt else {
            activeChallenge = nil
            recordFailure(for: source, at: timestamp)
            throw PairingPolicyError.codeExpired
        }
        guard isSixDigitCode(code),
            constantTimeEqual(Array(code.utf8), Array(challenge.code.utf8))
        else {
            recordFailure(for: source, at: timestamp)
            throw PairingPolicyError.invalidCode
        }

        // Actor methods are reentrant at the randomness await below. Reserve
        // the challenge before suspension so a concurrent request cannot
        // replay it. Restore it if issuance fails and no newer code replaced
        // this reservation.
        nextReservationID &+= 1
        let reservationID = nextReservationID
        activeChallenge = nil
        reservedChallenge = (reservationID, challenge)
        do {
            let session = try await issueSession(at: timestamp)
            if reservedChallenge?.id == reservationID {
                reservedChallenge = nil
            }
            failuresBySource.removeValue(forKey: source)
            return session
        } catch {
            if reservedChallenge?.id == reservationID {
                reservedChallenge = nil
                activeChallenge = challenge
            }
            throw error
        }
    }

    /// Verifies a session signature before decoding and validating its claims.
    public func validate(sessionToken: String) async throws -> SessionClaims {
        let pieces = sessionToken.split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        guard pieces.count == 2,
            let payload = base64URLDecode(String(pieces[0])),
            let suppliedSignature = base64URLDecode(String(pieces[1]))
        else {
            throw PairingPolicyError.malformedSession
        }

        let expectedSignature = try signer.signature(for: payload)
        guard
            constantTimeEqual(
                Array(suppliedSignature),
                Array(expectedSignature)
            )
        else {
            throw PairingPolicyError.invalidSessionSignature
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        guard let claims = try? decoder.decode(SessionClaims.self, from: payload) else {
            throw PairingPolicyError.malformedSession
        }
        guard claims.version == SessionClaims.currentVersion else {
            throw PairingPolicyError.unsupportedSessionVersion
        }

        let timestamp = await clock.now()
        guard claims.expiresAt > claims.issuedAt,
            timestamp < claims.expiresAt
        else {
            throw PairingPolicyError.expiredSession
        }
        return claims
    }

    public func failureCount(for source: String) async -> Int {
        let timestamp = await clock.now()
        return activeFailures(for: source, at: timestamp).count
    }

    private func issueSession(at timestamp: Date) async throws -> SignedPairingSession {
        let sessionBytes = try await randomness.randomBytes(count: 16)
        guard sessionBytes.count == 16 else {
            throw PairingPolicyError.invalidRandomness
        }

        // JSON's milliseconds-since-epoch representation is also the token's
        // canonical time precision. Normalize before returning the claims so a
        // freshly issued session compares exactly with its decoded token.
        let issuedAt = dateAtMillisecondPrecision(timestamp)
        let claims = SessionClaims(
            sessionID: base64URLEncode(Data(sessionBytes)),
            issuedAt: issuedAt,
            expiresAt: issuedAt.addingTimeInterval(configuration.sessionLifetime)
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let payload = try encoder.encode(claims)
        let signature = try signer.signature(for: payload)
        let token = "\(base64URLEncode(payload)).\(base64URLEncode(signature))"
        return SignedPairingSession(token: token, claims: claims)
    }

    private func generateSixDigitCode() async throws -> String {
        let possibleValues = UInt64(UInt32.max) + 1
        let codeCount: UInt64 = 1_000_000
        let acceptanceLimit = possibleValues - (possibleValues % codeCount)

        // A secure random source will almost certainly succeed immediately.
        // The bound protects against a broken injected source looping forever.
        for _ in 0..<128 {
            let bytes = try await randomness.randomBytes(count: 4)
            guard bytes.count == 4 else {
                throw PairingPolicyError.invalidRandomness
            }

            let value = bytes.reduce(UInt32(0)) { partial, byte in
                (partial << 8) | UInt32(byte)
            }
            let widened = UInt64(value)
            guard widened < acceptanceLimit else {
                continue
            }

            let digits = String(widened % codeCount)
            return String(repeating: "0", count: 6 - digits.count) + digits
        }
        throw PairingPolicyError.randomnessExhausted
    }

    private func activeFailures(for source: String, at timestamp: Date) -> [Date] {
        let cutoff = timestamp.addingTimeInterval(-configuration.failureWindow)
        let active = (failuresBySource[source] ?? []).filter { $0 > cutoff }
        if active.isEmpty {
            failuresBySource.removeValue(forKey: source)
        } else {
            failuresBySource[source] = active
        }
        return active
    }

    private func recordFailure(for source: String, at timestamp: Date) {
        var active = activeFailures(for: source, at: timestamp)
        active.append(timestamp)
        failuresBySource[source] = active
    }

    private func pruneFailures(at timestamp: Date) {
        for source in Array(failuresBySource.keys) {
            _ = activeFailures(for: source, at: timestamp)
        }
    }

    private func isValidSource(_ source: String) -> Bool {
        !source.isEmpty
            && source.utf8.count <= 255
            && source.unicodeScalars.allSatisfy { !$0.properties.isWhitespace }
    }

    private func isSixDigitCode(_ code: String) -> Bool {
        let bytes = Array(code.utf8)
        return bytes.count == 6 && bytes.allSatisfy { (48...57).contains($0) }
    }
}

@inline(never)
private func constantTimeEqual(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
    var difference = lhs.count ^ rhs.count
    let comparisonCount = max(lhs.count, rhs.count)
    for index in 0..<comparisonCount {
        let left = index < lhs.count ? lhs[index] : 0
        let right = index < rhs.count ? rhs[index] : 0
        difference |= Int(left ^ right)
    }
    return difference == 0
}

private func base64URLEncode(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

private func dateAtMillisecondPrecision(_ date: Date) -> Date {
    let milliseconds = (date.timeIntervalSince1970 * 1_000).rounded(.towardZero)
    return Date(timeIntervalSince1970: milliseconds / 1_000)
}

private func base64URLDecode(_ value: String) -> Data? {
    guard !value.isEmpty,
        value.utf8.allSatisfy({
            (65...90).contains($0)
                || (97...122).contains($0)
                || (48...57).contains($0)
                || $0 == 45
                || $0 == 95
        })
    else {
        return nil
    }

    let remainder = value.utf8.count % 4
    guard remainder != 1 else {
        return nil
    }
    let padding = remainder == 0 ? "" : String(repeating: "=", count: 4 - remainder)
    let base64 =
        value
        .replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
        + padding
    return Data(base64Encoded: base64, options: [])
}
