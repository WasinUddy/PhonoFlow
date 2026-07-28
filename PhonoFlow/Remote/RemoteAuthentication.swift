//
//  RemoteAuthentication.swift
//  PhonoFlow
//

import CryptoKit
import Foundation
import Security

nonisolated public protocol RemoteClock: Sendable {
    var now: Date { get }
}

nonisolated public struct SystemRemoteClock: RemoteClock {
    public init() {}
    public var now: Date { Date() }
}

nonisolated public protocol RemoteRandomByteGenerating: Sendable {
    func bytes(count: Int) throws -> Data
}

nonisolated public struct SecureRemoteRandom: RemoteRandomByteGenerating {
    public init() {}

    public func bytes(count: Int) throws -> Data {
        guard count >= 0 else { throw RemoteAuthenticationError.credentialFailure }
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { buffer -> OSStatus in
            guard let baseAddress = buffer.baseAddress else {
                return count == 0 ? errSecSuccess : errSecAllocate
            }
            return SecRandomCopyBytes(kSecRandomDefault, count, baseAddress)
        }
        guard status == errSecSuccess else {
            throw RemoteKeychainError(status: status)
        }
        return data
    }
}

nonisolated public protocol RemoteCredentialStoring: Sendable {
    func readCredential() async throws -> Data?
    func writeCredential(_ data: Data) async throws
}

nonisolated public struct RemoteKeychainError: Error, Sendable, LocalizedError {
    public var status: OSStatus

    public init(status: OSStatus) {
        self.status = status
    }

    public var errorDescription: String? {
        if let message = SecCopyErrorMessageString(status, nil) as String? {
            return "Keychain error \(status): \(message)"
        }
        return "Keychain error \(status)"
    }
}

/// Stores a single versioned credential blob. Session state and secret rotation
/// therefore survive app relaunches and "Revoke all browsers" is durable.
public actor KeychainRemoteCredentialStore: nonisolated RemoteCredentialStoring {
    private let service: String
    private let account: String

    public init(
        service: String = "com.wasinuddy.PhonoFlow.remote-access",
        account: String = "session-credentials"
    ) {
        self.service = service
        self.account = account
    }

    public func readCredential() async throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = result as? Data else {
            throw RemoteKeychainError(status: status)
        }
        return data
    }

    public func writeCredential(_ data: Data) async throws {
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let updateStatus = SecItemUpdate(identity as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw RemoteKeychainError(status: updateStatus)
        }

        var insertion = identity
        for (key, value) in attributes {
            insertion[key] = value
        }
        let addStatus = SecItemAdd(insertion as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw RemoteKeychainError(status: addStatus)
        }
    }
}

public actor InMemoryRemoteCredentialStore: nonisolated RemoteCredentialStoring {
    private var data: Data?

    public init(data: Data? = nil) {
        self.data = data
    }

    public func readCredential() async throws -> Data? {
        data
    }

    public func writeCredential(_ data: Data) async throws {
        self.data = data
    }
}

nonisolated public struct RemotePairingCode: Codable, Sendable, Equatable {
    public var code: String
    public var expiresAt: Date

    public init(code: String, expiresAt: Date) {
        self.code = code
        self.expiresAt = expiresAt
    }
}

nonisolated public struct RemoteSessionPrincipal: Sendable, Equatable, Hashable {
    public var sessionID: String
    public var expiresAt: Date
    /// Credential epoch that authenticated this principal. A principal from
    /// before "Revoke all browsers" can never be reused after secret rotation.
    public var generation: UInt64

    public init(sessionID: String, expiresAt: Date, generation: UInt64 = 0) {
        self.sessionID = sessionID
        self.expiresAt = expiresAt
        self.generation = generation
    }
}

nonisolated public struct RemoteIssuedSession: Sendable, Equatable {
    public var token: String
    public var principal: RemoteSessionPrincipal
    /// Sessions removed while enforcing expiry and capacity. The request
    /// router uses these IDs to close their already-connected SSE/audio
    /// streams after the credential update is durable.
    public var invalidatedSessionIDs: [String]

    public init(
        token: String,
        principal: RemoteSessionPrincipal,
        invalidatedSessionIDs: [String] = []
    ) {
        self.token = token
        self.principal = principal
        self.invalidatedSessionIDs = invalidatedSessionIDs
    }
}

nonisolated public enum RemoteAuthenticationError: Error, Sendable, Equatable {
    case invalidPairingCode
    case pairingRateLimited(retryAfterSeconds: Int)
    case invalidSession
    case sessionCapacity
    case credentialFailure
}

public actor RemotePairingService {
    public static let cookieName = "PhonoFlowSession"
    public static let pairingLifetime: TimeInterval = 10 * 60
    public static let sessionLifetime: TimeInterval = 30 * 24 * 60 * 60

    private struct SessionRecord: Codable, Sendable {
        var id: String
        var issuedAt: Date
        var expiresAt: Date
    }

    private struct CredentialBlob: Codable, Sendable {
        var version: Int
        var secret: Data
        var epoch: UInt64
        var sessions: [SessionRecord]
    }

    private struct TokenPayload: Codable, Sendable {
        var version: Int
        var sessionID: String
        var issuedAt: Date
        var expiresAt: Date
        var epoch: UInt64
    }

    private let store: any RemoteCredentialStoring
    private let clock: any RemoteClock
    private let random: any RemoteRandomByteGenerating
    private let maximumSessions: Int
    private var credential: CredentialBlob?
    private var activeCode: RemotePairingCode?
    private var failedAttempts: [String: [Date]] = [:]
    private var credentialOperationActive = false
    private var credentialOperationWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        store: any RemoteCredentialStoring = KeychainRemoteCredentialStore(),
        clock: any RemoteClock = SystemRemoteClock(),
        random: any RemoteRandomByteGenerating = SecureRemoteRandom(),
        maximumSessions: Int = 32
    ) {
        self.store = store
        self.clock = clock
        self.random = random
        self.maximumSessions = max(1, maximumSessions)
    }

    /// Must run before binding the listener. Keychain failures stop Remote
    /// Access instead of silently falling back to an ephemeral signing key.
    public func prepare() async throws {
        await acquireCredentialOperation()
        defer { releaseCredentialOperation() }
        _ = try await loadCredential()
    }

    @discardableResult
    public func issuePairingCode() async throws -> RemotePairingCode {
        await acquireCredentialOperation()
        defer { releaseCredentialOperation() }
        let code = try generateSixDigitCode()
        let pairingCode = RemotePairingCode(
            code: code,
            expiresAt: clock.now.addingTimeInterval(Self.pairingLifetime)
        )
        activeCode = pairingCode
        return pairingCode
    }

    #if DEBUG
        /// Deterministic acceptance-only seam. The symbol is absent from
        /// Release.
        @discardableResult
        public func issuePairingCodeForAcceptance(
            _ code: String
        ) async throws -> RemotePairingCode {
            await acquireCredentialOperation()
            defer { releaseCredentialOperation() }
            guard code.range(of: #"^\d{6}$"#, options: .regularExpression) != nil else {
                throw RemoteAuthenticationError.invalidPairingCode
            }
            let pairingCode = RemotePairingCode(
                code: code,
                expiresAt: clock.now.addingTimeInterval(Self.pairingLifetime)
            )
            activeCode = pairingCode
            return pairingCode
        }
    #endif

    public func currentPairingCode() async -> RemotePairingCode? {
        await acquireCredentialOperation()
        defer { releaseCredentialOperation() }
        guard let activeCode, activeCode.expiresAt > clock.now else {
            self.activeCode = nil
            return nil
        }
        return activeCode
    }

    public func invalidatePairingCode() async {
        await acquireCredentialOperation()
        defer { releaseCredentialOperation() }
        activeCode = nil
    }

    public func pair(code: String, remoteAddress: String) async throws -> RemoteIssuedSession {
        await acquireCredentialOperation()
        defer { releaseCredentialOperation() }
        let peer = Self.canonicalPeer(remoteAddress)
        let now = clock.now
        pruneFailures(now: now)

        let recentFailures = failedAttempts[peer, default: []]
            .filter { now.timeIntervalSince($0) < Self.pairingLifetime }
        if recentFailures.count >= 5 {
            let oldest = recentFailures.min() ?? now
            let retryAfter = max(
                1,
                Int(ceil(Self.pairingLifetime - now.timeIntervalSince(oldest)))
            )
            throw RemoteAuthenticationError.pairingRateLimited(retryAfterSeconds: retryAfter)
        }

        guard code.range(of: #"^\d{6}$"#, options: .regularExpression) != nil,
            let activeCode,
            activeCode.expiresAt > now,
            Self.constantTimeEqual(code, activeCode.code)
        else {
            if let retryAfter = makeFailureBucketAvailable(for: peer, now: now) {
                throw RemoteAuthenticationError.pairingRateLimited(
                    retryAfterSeconds: retryAfter
                )
            }
            failedAttempts[peer, default: []].append(now)
            throw RemoteAuthenticationError.invalidPairingCode
        }

        var credential = try await loadCredential()
        var invalidatedSessionIDs = credential.sessions.compactMap {
            $0.expiresAt <= now ? $0.id : nil
        }
        credential.sessions.removeAll { $0.expiresAt <= now }
        if credential.sessions.count >= maximumSessions {
            credential.sessions =
                credential.sessions.enumerated()
                .sorted { lhs, rhs in
                    lhs.element.issuedAt == rhs.element.issuedAt
                        ? lhs.offset < rhs.offset
                        : lhs.element.issuedAt < rhs.element.issuedAt
                }
                .map(\.element)
            let removalCount = credential.sessions.count - maximumSessions + 1
            invalidatedSessionIDs.append(
                contentsOf: credential.sessions.prefix(removalCount).map(\.id)
            )
            credential.sessions.removeFirst(removalCount)
        }

        let sessionID = try random.bytes(count: 32).base64URLEncodedString()
        // `RemoteJSON` uses Foundation's ISO-8601 strategy, whose encoded form
        // has whole-second precision. Normalize before both persistence and
        // signing so the decoded token and its session record compare exactly.
        let issuedAt = Self.normalizedTokenDate(now)
        let expiresAt = issuedAt.addingTimeInterval(Self.sessionLifetime)
        credential.sessions.append(
            SessionRecord(id: sessionID, issuedAt: issuedAt, expiresAt: expiresAt)
        )

        let payload = TokenPayload(
            version: 1,
            sessionID: sessionID,
            issuedAt: issuedAt,
            expiresAt: expiresAt,
            epoch: credential.epoch
        )
        let token = try sign(payload: payload, secret: credential.secret)
        try await saveCredential(credential)
        // Consume the native code only after the new session and any capacity
        // evictions have been durably persisted. A transient Keychain failure
        // can therefore be retried with the same still-valid code.
        self.activeCode = nil
        failedAttempts[peer] = nil
        return RemoteIssuedSession(
            token: token,
            principal: RemoteSessionPrincipal(
                sessionID: sessionID,
                expiresAt: expiresAt,
                generation: credential.epoch
            ),
            invalidatedSessionIDs: invalidatedSessionIDs
        )
    }

    public func validate(token: String) async throws -> RemoteSessionPrincipal {
        await acquireCredentialOperation()
        defer { releaseCredentialOperation() }
        return try await validateSession(token: token)
    }

    /// Revalidates an already-decoded principal at a stream registration
    /// boundary. This closes the validate-before-subscribe race without
    /// retaining or redistributing the bearer token.
    public func validate(principal: RemoteSessionPrincipal) async throws {
        await acquireCredentialOperation()
        defer { releaseCredentialOperation() }
        var credential = try await loadCredential()
        let now = clock.now
        guard principal.generation == credential.epoch,
            principal.expiresAt > now,
            credential.sessions.contains(where: {
                $0.id == principal.sessionID && $0.expiresAt == principal.expiresAt
            })
        else {
            throw RemoteAuthenticationError.invalidSession
        }
        await persistExpiredSessionCleanupIfNeeded(&credential, now: now)
    }

    private func validateSession(token: String) async throws -> RemoteSessionPrincipal {
        guard token.utf8.count <= 2_048 else {
            throw RemoteAuthenticationError.invalidSession
        }
        let components = token.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3,
            components[0] == "v1",
            let payloadData = Data(base64URLEncoded: String(components[1])),
            let signature = Data(base64URLEncoded: String(components[2]))
        else {
            throw RemoteAuthenticationError.invalidSession
        }

        var credential = try await loadCredential()
        let key = SymmetricKey(data: credential.secret)
        guard
            HMAC<SHA256>.isValidAuthenticationCode(
                signature,
                authenticating: Data(components[1].utf8),
                using: key
            )
        else {
            throw RemoteAuthenticationError.invalidSession
        }

        guard let payload = try? RemoteJSON.decoder().decode(TokenPayload.self, from: payloadData),
            payload.version == 1,
            payload.epoch == credential.epoch
        else {
            throw RemoteAuthenticationError.invalidSession
        }

        let now = clock.now
        guard payload.issuedAt <= now.addingTimeInterval(60),
            payload.expiresAt > now,
            payload.expiresAt.timeIntervalSince(payload.issuedAt) <= Self.sessionLifetime + 60,
            credential.sessions.contains(where: {
                $0.id == payload.sessionID && $0.expiresAt == payload.expiresAt
            })
        else {
            throw RemoteAuthenticationError.invalidSession
        }

        await persistExpiredSessionCleanupIfNeeded(&credential, now: now)
        return RemoteSessionPrincipal(
            sessionID: payload.sessionID,
            expiresAt: payload.expiresAt,
            generation: payload.epoch
        )
    }

    @discardableResult
    public func revoke(token: String) async throws -> RemoteSessionPrincipal {
        await acquireCredentialOperation()
        defer { releaseCredentialOperation() }
        let principal = try await validateSession(token: token)
        var credential = try await loadCredential()
        credential.sessions.removeAll { $0.id == principal.sessionID }
        try await saveCredential(credential)
        return principal
    }

    public func revokeAll() async throws {
        await acquireCredentialOperation()
        defer { releaseCredentialOperation() }
        var credential = try await loadCredential()
        credential.secret = try random.bytes(count: 32)
        credential.epoch &+= 1
        credential.sessions.removeAll(keepingCapacity: false)
        try await saveCredential(credential)
        // Keep an outstanding code retryable if rotation could not be made
        // durable. It is consumed only with the successful credential update.
        activeCode = nil
    }

    public nonisolated static func sessionCookie(token: String) -> String {
        "\(cookieName)=\(token); Path=/; Max-Age=2592000; HttpOnly; SameSite=Strict"
    }

    public nonisolated static func expiredSessionCookie() -> String {
        "\(cookieName)=; Path=/; Max-Age=0; Expires=Thu, 01 Jan 1970 00:00:00 GMT; HttpOnly; SameSite=Strict"
    }

    public nonisolated static func token(fromCookieHeader header: String?) -> String? {
        guard let header else { return nil }
        for component in header.split(separator: ";") {
            let pair = component.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { continue }
            if pair[0].trimmingCharacters(in: .whitespaces) == cookieName {
                let token = pair[1].trimmingCharacters(in: .whitespaces)
                return token.isEmpty ? nil : token
            }
        }
        return nil
    }

    private func loadCredential() async throws -> CredentialBlob {
        if let credential {
            return credential
        }
        if let data = try await store.readCredential() {
            guard let decoded = try? RemoteJSON.decoder().decode(CredentialBlob.self, from: data),
                decoded.version == 1,
                decoded.secret.count == 32
            else {
                throw RemoteAuthenticationError.credentialFailure
            }
            credential = decoded
            return decoded
        }

        let created = CredentialBlob(
            version: 1,
            secret: try random.bytes(count: 32),
            epoch: 1,
            sessions: []
        )
        try await saveCredential(created)
        return created
    }

    private func saveCredential(_ credential: CredentialBlob) async throws {
        let data: Data
        do {
            data = try RemoteJSON.encoder().encode(credential)
            try await store.writeCredential(data)
        } catch let error as RemoteAuthenticationError {
            throw error
        } catch {
            throw RemoteAuthenticationError.credentialFailure
        }
        self.credential = credential
    }

    /// Expired records are housekeeping, not an authorization dependency for
    /// another still-live session. If Keychain is temporarily unavailable,
    /// retain the unpruned cached blob and retry cleanup on the next successful
    /// validation instead of rejecting the valid browser.
    private func persistExpiredSessionCleanupIfNeeded(
        _ credential: inout CredentialBlob,
        now: Date
    ) async {
        let before = credential.sessions.count
        credential.sessions.removeAll { $0.expiresAt <= now }
        guard credential.sessions.count != before else { return }
        do {
            try await saveCredential(credential)
        } catch {
            // `saveCredential` updates the cache only after a successful
            // store write, so leaving this error non-fatal also preserves a
            // retryable cleanup operation.
        }
    }

    /// Swift actors are reentrant at each credential-store `await`. This FIFO
    /// gate makes pairing, validation cleanup, logout, and secret rotation
    /// linearizable so an older suspended write can never overwrite a newer
    /// "Revoke all" credential.
    private func acquireCredentialOperation() async {
        guard credentialOperationActive else {
            credentialOperationActive = true
            return
        }
        await withCheckedContinuation {
            credentialOperationWaiters.append($0)
        }
    }

    private func releaseCredentialOperation() {
        guard !credentialOperationWaiters.isEmpty else {
            credentialOperationActive = false
            return
        }
        credentialOperationWaiters.removeFirst().resume()
    }

    private func sign(payload: TokenPayload, secret: Data) throws -> String {
        let payloadData = try RemoteJSON.encoder().encode(payload)
        let encodedPayload = payloadData.base64URLEncodedString()
        let signature = HMAC<SHA256>.authenticationCode(
            for: Data(encodedPayload.utf8),
            using: SymmetricKey(data: secret)
        )
        return "v1.\(encodedPayload).\(Data(signature).base64URLEncodedString())"
    }

    private func generateSixDigitCode() throws -> String {
        // Rejection sampling avoids modulo bias: 16,000,000 is the largest
        // multiple of 1,000,000 that fits in three random bytes.
        while true {
            let bytes = try random.bytes(count: 3)
            guard bytes.count == 3 else {
                throw RemoteAuthenticationError.credentialFailure
            }
            let value =
                UInt32(bytes[bytes.startIndex]) << 16 | UInt32(bytes[bytes.index(after: bytes.startIndex)]) << 8
                | UInt32(bytes[bytes.index(bytes.startIndex, offsetBy: 2)])
            guard value < 16_000_000 else { continue }
            return String(format: "%06u", value % 1_000_000)
        }
    }

    private func pruneFailures(now: Date) {
        for key in failedAttempts.keys {
            failedAttempts[key]?.removeAll {
                now.timeIntervalSince($0) >= Self.pairingLifetime
            }
            if failedAttempts[key]?.isEmpty == true {
                failedAttempts[key] = nil
            }
        }
    }

    /// Keeps source tracking bounded without letting address churn erase a
    /// peer that already reached the five-attempt lockout. Under the extreme
    /// case where every retained bucket is locked, a new invalid source is
    /// conservatively limited until the earliest bucket expires.
    private func makeFailureBucketAvailable(for peer: String, now: Date) -> Int? {
        let maximumFailureBuckets = 2_048
        guard failedAttempts[peer] == nil,
            failedAttempts.count >= maximumFailureBuckets
        else {
            return nil
        }

        if let eviction =
            failedAttempts
            .filter({ $0.value.count < 5 })
            .min(by: { lhs, rhs in
                let lhsDate = lhs.value.last ?? .distantPast
                let rhsDate = rhs.value.last ?? .distantPast
                return lhsDate == rhsDate ? lhs.key < rhs.key : lhsDate < rhsDate
            })
        {
            failedAttempts[eviction.key] = nil
            return nil
        }

        let earliestFailure =
            failedAttempts.values.compactMap(\.first).min()
            ?? now
        return max(
            1,
            Int(
                ceil(
                    Self.pairingLifetime
                        - now.timeIntervalSince(earliestFailure)
                )
            )
        )
    }

    private nonisolated static func canonicalPeer(_ address: String) -> String {
        address
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()
    }

    private nonisolated static func normalizedTokenDate(_ date: Date) -> Date {
        Date(timeIntervalSince1970: floor(date.timeIntervalSince1970))
    }

    private nonisolated static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        var difference = UInt8(truncatingIfNeeded: left.count ^ right.count)
        let count = max(left.count, right.count)
        for index in 0..<count {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            difference |= a ^ b
        }
        return difference == 0
    }
}
nonisolated

    extension Data
{
    fileprivate func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    fileprivate init?(base64URLEncoded value: String) {
        var base64 =
            value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.utf8.count % 4
        if remainder != 0 {
            base64.append(String(repeating: "=", count: 4 - remainder))
        }
        self.init(base64Encoded: base64)
    }
}
