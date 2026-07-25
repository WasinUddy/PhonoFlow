import CryptoKit
import Foundation
import Security
import SwiftUI
import Synchronization
import XCTest

@testable import PhonoFlow

@MainActor
final class RemoteInfrastructureCoverageTests: XCTestCase {
    func testSecureRandomAndKeychainErrorSurfaces() throws {
        let random = SecureRemoteRandom()

        XCTAssertThrowsError(try random.bytes(count: -1)) { error in
            XCTAssertEqual(error as? RemoteAuthenticationError, .credentialFailure)
        }
        XCTAssertEqual(try random.bytes(count: 0), Data())
        XCTAssertEqual(try random.bytes(count: 32).count, 32)

        let known = RemoteKeychainError(status: errSecItemNotFound)
        XCTAssertEqual(known.status, errSecItemNotFound)
        XCTAssertTrue(known.localizedDescription.contains("\(errSecItemNotFound)"))

        let unknownStatus = OSStatus(-123_456)
        let unknown = RemoteKeychainError(status: unknownStatus)
        XCTAssertEqual(unknown.status, unknownStatus)
        XCTAssertTrue(unknown.localizedDescription.contains("\(unknownStatus)"))
    }

    #if DEBUG
        func testAcceptancePairingCodeValidationAndExplicitInvalidation() async throws {
            let clock = TestRemoteClock(.testReference)
            let service = RemotePairingService(
                store: InMemoryRemoteCredentialStore(),
                clock: clock,
                random: CountingRemoteRandom()
            )

            try await service.prepare()
            await assertAuthenticationError(.invalidPairingCode) {
                _ = try await service.issuePairingCodeForAcceptance("12345")
            }
            await assertAuthenticationError(.invalidPairingCode) {
                _ = try await service.issuePairingCodeForAcceptance("12345x")
            }

            let issued = try await service.issuePairingCodeForAcceptance("042042")
            XCTAssertEqual(issued.code, "042042")
            XCTAssertEqual(
                issued.expiresAt,
                clock.now.addingTimeInterval(RemotePairingService.pairingLifetime)
            )
            let currentCode = await service.currentPairingCode()
            XCTAssertEqual(currentCode, issued)

            await service.invalidatePairingCode()
            let invalidatedCode = await service.currentPairingCode()
            XCTAssertNil(invalidatedCode)
        }
    #endif

    func testRandomRejectionSamplingAndWrongByteCountAreHandled() async throws {
        let scripted = CoverageScriptedRemoteRandom([
            Data([0xFF, 0xFF, 0xFF]),
            Data([0x00, 0x00, 0x07]),
        ])
        let service = RemotePairingService(
            store: InMemoryRemoteCredentialStore(),
            clock: TestRemoteClock(.testReference),
            random: scripted
        )

        let code = try await service.issuePairingCode()
        XCTAssertEqual(code.code, "000007")

        let shortService = RemotePairingService(
            store: InMemoryRemoteCredentialStore(),
            clock: TestRemoteClock(.testReference),
            random: CoverageShortRemoteRandom()
        )
        await assertAuthenticationError(.credentialFailure) {
            _ = try await shortService.issuePairingCode()
        }
    }

    func testPersistedCredentialValidationAndExpiredSessionCleanup() async throws {
        let now = Date.testReference
        let secret = Data(repeating: 0xA5, count: 32)
        let validExpiry = now.addingTimeInterval(3_600)
        let futureIssuedAt = now.addingTimeInterval(61)
        let futureExpiry = now.addingTimeInterval(3_661)
        let credential = CoverageCredentialBlob(
            version: 1,
            secret: secret,
            epoch: 9,
            sessions: [
                CoverageSessionRecord(
                    id: "expired",
                    issuedAt: now.addingTimeInterval(-7_200),
                    expiresAt: now.addingTimeInterval(-1)
                ),
                CoverageSessionRecord(
                    id: "valid",
                    issuedAt: now,
                    expiresAt: validExpiry
                ),
                CoverageSessionRecord(
                    id: "future",
                    issuedAt: futureIssuedAt,
                    expiresAt: futureExpiry
                ),
            ]
        )
        let store = CoverageCredentialStore(
            data: try RemoteJSON.encoder().encode(credential)
        )
        let service = RemotePairingService(
            store: store,
            clock: TestRemoteClock(now),
            random: CountingRemoteRandom()
        )

        try await service.prepare()
        let validPayload = CoverageTokenPayload(
            version: 1,
            sessionID: "valid",
            issuedAt: now,
            expiresAt: validExpiry,
            epoch: 9
        )
        let validToken = try coverageToken(payload: validPayload, secret: secret)
        let validPrincipal = try await service.validate(token: validToken)
        XCTAssertEqual(
            validPrincipal,
            RemoteSessionPrincipal(
                sessionID: "valid",
                expiresAt: validExpiry,
                generation: 9
            )
        )
        let writeCount = await store.writeCount()
        XCTAssertEqual(writeCount, 1)

        await assertAuthenticationError(.invalidSession) {
            _ = try await service.validate(token: String(repeating: "x", count: 2_049))
        }
        await assertAuthenticationError(.invalidSession) {
            _ = try await service.validate(token: "v1.***.***")
        }

        var invalidVersion = validPayload
        invalidVersion.version = 2
        let invalidVersionToken = try coverageToken(payload: invalidVersion, secret: secret)
        await assertAuthenticationError(.invalidSession) {
            _ = try await service.validate(token: invalidVersionToken)
        }

        let futurePayload = CoverageTokenPayload(
            version: 1,
            sessionID: "future",
            issuedAt: futureIssuedAt,
            expiresAt: futureExpiry,
            epoch: 9
        )
        let futureToken = try coverageToken(payload: futurePayload, secret: secret)
        await assertAuthenticationError(.invalidSession) {
            _ = try await service.validate(token: futureToken)
        }

        XCTAssertNil(
            RemotePairingService.token(
                fromCookieHeader: "malformed-cookie; another=value"
            )
        )
    }

    func testMalformedCredentialBlobsAndWriteFailuresAreTyped() async throws {
        let now = Date.testReference
        let invalidJSON = RemotePairingService(
            store: InMemoryRemoteCredentialStore(data: Data("{}".utf8)),
            clock: TestRemoteClock(now),
            random: CountingRemoteRandom()
        )
        await assertAuthenticationError(.credentialFailure) {
            try await invalidJSON.prepare()
        }

        let wrongVersion = CoverageCredentialBlob(
            version: 2,
            secret: Data(repeating: 1, count: 32),
            epoch: 1,
            sessions: []
        )
        let wrongVersionService = RemotePairingService(
            store: InMemoryRemoteCredentialStore(
                data: try RemoteJSON.encoder().encode(wrongVersion)
            ),
            clock: TestRemoteClock(now),
            random: CountingRemoteRandom()
        )
        await assertAuthenticationError(.credentialFailure) {
            try await wrongVersionService.prepare()
        }

        let shortSecret = CoverageCredentialBlob(
            version: 1,
            secret: Data(repeating: 1, count: 31),
            epoch: 1,
            sessions: []
        )
        let shortSecretService = RemotePairingService(
            store: InMemoryRemoteCredentialStore(
                data: try RemoteJSON.encoder().encode(shortSecret)
            ),
            clock: TestRemoteClock(now),
            random: CountingRemoteRandom()
        )
        await assertAuthenticationError(.credentialFailure) {
            try await shortSecretService.prepare()
        }

        let genericWriteFailure = RemotePairingService(
            store: CoverageRejectingCredentialStore(failure: .generic),
            clock: TestRemoteClock(now),
            random: CountingRemoteRandom()
        )
        await assertAuthenticationError(.credentialFailure) {
            try await genericWriteFailure.prepare()
        }

        let typedWriteFailure = RemotePairingService(
            store: CoverageRejectingCredentialStore(failure: .authentication),
            clock: TestRemoteClock(now),
            random: CountingRemoteRandom()
        )
        await assertAuthenticationError(.invalidSession) {
            try await typedWriteFailure.prepare()
        }
    }

    func testSessionCapacityEvictsTheOldestSession() async throws {
        let service = RemotePairingService(
            store: InMemoryRemoteCredentialStore(),
            clock: TestRemoteClock(.testReference),
            random: CountingRemoteRandom(),
            maximumSessions: 1
        )
        let firstCode = try await service.issuePairingCode()
        let first = try await service.pair(
            code: firstCode.code,
            remoteAddress: "192.0.2.1"
        )
        let secondCode = try await service.issuePairingCode()
        let second = try await service.pair(
            code: secondCode.code,
            remoteAddress: "192.0.2.2"
        )

        XCTAssertEqual(second.invalidatedSessionIDs, [first.principal.sessionID])
        await assertAuthenticationError(.invalidSession) {
            _ = try await service.validate(token: first.token)
        }
        let secondPrincipal = try await service.validate(token: second.token)
        XCTAssertEqual(secondPrincipal, second.principal)
    }

    func testFailureBucketCapacityPreservesLockedPeersAndExpiryRestoresAccess() async throws {
        let clock = TestRemoteClock(.testReference)
        let service = RemotePairingService(
            store: InMemoryRemoteCredentialStore(),
            clock: clock,
            random: CountingRemoteRandom()
        )
        let capacityCode = try await service.issuePairingCode()
        let oldestPeer = "198.51.100.1"

        for _ in 0..<5 {
            do {
                _ = try await service.pair(
                    code: "999999",
                    remoteAddress: oldestPeer
                )
                XCTFail("An invalid pairing code must be rejected")
            } catch let error as RemoteAuthenticationError {
                XCTAssertEqual(error, .invalidPairingCode)
            }
        }
        await assertAuthenticationError(.pairingRateLimited(retryAfterSeconds: 600)) {
            _ = try await service.pair(
                code: capacityCode.code,
                remoteAddress: oldestPeer
            )
        }

        clock.advance(by: 1)
        for index in 0..<2_048 {
            do {
                _ = try await service.pair(
                    code: "999999",
                    remoteAddress: "203.0.\(index / 256).\(index % 256)"
                )
                XCTFail("An invalid pairing code must be rejected")
            } catch let error as RemoteAuthenticationError {
                XCTAssertEqual(error, .invalidPairingCode)
            }
        }

        await assertAuthenticationError(.pairingRateLimited(retryAfterSeconds: 599)) {
            _ = try await service.pair(
                code: capacityCode.code,
                remoteAddress: oldestPeer
            )
        }

        let expiringPeer = "192.0.2.55"
        for _ in 0..<5 {
            await assertAuthenticationError(.invalidPairingCode) {
                _ = try await service.pair(
                    code: "999999",
                    remoteAddress: expiringPeer
                )
            }
        }
        await assertAuthenticationError(.pairingRateLimited(retryAfterSeconds: 600)) {
            _ = try await service.pair(
                code: "999999",
                remoteAddress: expiringPeer
            )
        }

        clock.advance(by: RemotePairingService.pairingLifetime + 1)
        let freshCode = try await service.issuePairingCode()
        let freshSession = try await service.pair(
            code: freshCode.code,
            remoteAddress: expiringPeer
        )
        let freshPrincipal = try await service.validate(token: freshSession.token)
        XCTAssertEqual(freshPrincipal, freshSession.principal)
    }

    func testBundledStaticAssetsUseAllowListDevelopmentFallbackAndCache() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PhonoFlow-RemoteInfrastructureCoverageTests-\(ProcessInfo.processInfo.processIdentifier)",
                isDirectory: true
            )
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let emptyBundle = try makeEmptyBundle(at: root.appendingPathComponent("Empty.bundle"))
        let fixtures: [CoverageAssetFixture] = [
            .init("/", "index.html", "text/html; charset=utf-8", "no-cache"),
            .init(
                "/styles.css",
                "styles.css",
                "text/css; charset=utf-8",
                "public, max-age=3600"
            ),
            .init(
                "/src/app.js",
                "src/app.js",
                "text/javascript; charset=utf-8",
                "public, max-age=3600"
            ),
            .init(
                "/src/api.js",
                "src/api.js",
                "text/javascript; charset=utf-8",
                "public, max-age=3600"
            ),
            .init(
                "/src/state.js",
                "src/state.js",
                "text/javascript; charset=utf-8",
                "public, max-age=3600"
            ),
            .init(
                "/src/spectrogram.js",
                "src/spectrogram.js",
                "text/javascript; charset=utf-8",
                "public, max-age=3600"
            ),
            .init(
                "/src/view.js",
                "src/view.js",
                "text/javascript; charset=utf-8",
                "public, max-age=3600"
            ),
        ]

        for fixture in fixtures {
            let url = root.appendingPathComponent(fixture.relativePath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fixture.content.write(to: url, options: .atomic)
        }

        let provider = BundledRemoteStaticAssetProvider(
            bundle: emptyBundle,
            developmentRoot: root
        )
        for fixture in fixtures {
            let asset = await provider.asset(forRequestPath: fixture.requestPath)
            XCTAssertEqual(asset?.content, fixture.content)
            XCTAssertEqual(asset?.contentType, fixture.contentType)
            XCTAssertEqual(asset?.cacheControl, fixture.cacheControl)
        }
        let unknownAsset = await provider.asset(forRequestPath: "/not-allow-listed")
        XCTAssertNil(unknownAsset)

        try FileManager.default.removeItem(at: root.appendingPathComponent("index.html"))
        let cachedIndex = await provider.asset(forRequestPath: "/")
        XCTAssertEqual(
            cachedIndex?.content,
            fixtures[0].content,
            "A cached allow-listed asset should not depend on a later filesystem read."
        )

        let missingRoot = root.appendingPathComponent("Missing", isDirectory: true)
        try FileManager.default.createDirectory(
            at: missingRoot,
            withIntermediateDirectories: true
        )
        let missingProvider = BundledRemoteStaticAssetProvider(
            bundle: emptyBundle,
            developmentRoot: missingRoot
        )
        let missingAsset = await missingProvider.asset(forRequestPath: "/styles.css")
        XCTAssertNil(missingAsset)
    }

    func testHTTPValueTypesAndUnavailableTransportEdges() async throws {
        for method in RemoteHTTPMethod.allCases {
            XCTAssertEqual(
                method.isMutation,
                [.post, .put, .patch, .delete].contains(method)
            )
        }

        let body = Data([0x01, 0x02])
        let request = RemoteHTTPRequest(
            method: .post,
            target: "/api/v1/state?detail=1",
            headers: ["Host": "first.local", "host": "second.local"],
            body: body,
            remoteAddress: "192.0.2.4"
        )
        XCTAssertEqual(
            Set(request[header: "HOST"]?.split(separator: ",").map(String.init) ?? []),
            Set(["first.local", "second.local"])
        )
        XCTAssertEqual(request.body, body)
        XCTAssertEqual(request.remoteAddress, "192.0.2.4")

        let transportConfiguration = RemoteTransportConfiguration(
            bindHost: "127.0.0.1",
            port: 9_999,
            maximumBodyBytes: 4_096
        )
        XCTAssertEqual(transportConfiguration.bindHost, "127.0.0.1")
        XCTAssertEqual(transportConfiguration.port, 9_999)
        XCTAssertEqual(transportConfiguration.maximumBodyBytes, 4_096)

        let unavailable = RemoteTransportUnavailable()
        XCTAssertTrue(unavailable.localizedDescription.contains("Hummingbird 2.x"))
        let transport = UnavailableRemoteHTTPTransport()
        await transport.stop()
        do {
            _ = try await transport.start(
                configuration: transportConfiguration,
                handler: { _ in
                    .response(RemoteHTTPResponse(status: 204))
                }
            )
            XCTFail("The unavailable transport must reject startup.")
        } catch {
            XCTAssertTrue(error is RemoteTransportUnavailable)
        }
    }

    func testThemesAndSettingsDefaultAndPersistenceBranches() {
        let preferences = InMemoryAudioDevicePreferences(values: [
            "colorTheme": "Not a theme",
            "radioPort": 0,
            "remoteAccessPort": 70_000,
        ])

        let defaulted = AppSettings(defaults: preferences)
        XCTAssertEqual(defaulted.theme, .midnight)
        XCTAssertEqual(defaulted.allowedHosts, [])
        XCTAssertEqual(defaulted.radioPort, AppSettings.defaultRadioPort)
        XCTAssertEqual(defaulted.remoteAccessPort, AppSettings.defaultRemoteAccessPort)
        XCTAssertFalse(defaulted.allowLegacyUnauthenticatedStream)
        XCTAssertFalse(defaulted.isProMode)
        XCTAssertFalse(defaulted.showAdvancedVisualizations)
        XCTAssertFalse(defaulted.showDiagnostics)

        defaulted.theme = .ocean
        defaulted.allowedHosts = ["studio.local", "player.local"]
        defaulted.radioPort = 8_765
        defaulted.remoteAccessEnabled = true
        defaulted.remoteAccessPort = 8_766
        defaulted.allowLegacyUnauthenticatedStream = true
        defaulted.isProMode = true
        defaulted.launchAtLogin = true
        defaulted.showAdvancedVisualizations = true
        defaulted.showDiagnostics = true
        defaulted.hasAskedLaunchAtLogin = true

        let persisted = AppSettings(defaults: preferences)
        XCTAssertEqual(persisted.theme, .ocean)
        XCTAssertEqual(persisted.allowedHosts, ["studio.local", "player.local"])
        XCTAssertEqual(persisted.radioPort, 8_765)
        XCTAssertTrue(persisted.remoteAccessEnabled)
        XCTAssertEqual(persisted.remoteAccessPort, 8_766)
        XCTAssertTrue(persisted.allowLegacyUnauthenticatedStream)
        XCTAssertTrue(persisted.isProMode)
        XCTAssertTrue(persisted.launchAtLogin)
        XCTAssertTrue(persisted.showAdvancedVisualizations)
        XCTAssertTrue(persisted.showDiagnostics)
        XCTAssertTrue(persisted.hasAskedLaunchAtLogin)

        let colors = ColorTheme.allCases.flatMap { theme -> [Color] in
            XCTAssertEqual(theme.id, theme.rawValue)
            return [
                theme.accent,
                theme.meterGreen,
                theme.activeColor,
                theme.sliderTint,
            ]
        }
        XCTAssertEqual(colors.count, ColorTheme.allCases.count * 4)
    }

    private func assertAuthenticationError(
        _ expected: RemoteAuthenticationError,
        file: StaticString = #filePath,
        line: UInt = #line,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch let error as RemoteAuthenticationError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }

    private func coverageToken(
        payload: CoverageTokenPayload,
        secret: Data
    ) throws -> String {
        let payloadData = try RemoteJSON.encoder().encode(payload)
        let encodedPayload = payloadData.coverageBase64URLEncodedString()
        let signature = HMAC<SHA256>.authenticationCode(
            for: Data(encodedPayload.utf8),
            using: SymmetricKey(data: secret)
        )
        return "v1.\(encodedPayload).\(Data(signature).coverageBase64URLEncodedString())"
    }

    private func makeEmptyBundle(at url: URL) throws -> Bundle {
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(
            at: contents,
            withIntermediateDirectories: true
        )
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.wasinuddy.PhonoFlow.coverage-assets",
            "CFBundleName": "CoverageAssets",
            "CFBundlePackageType": "BNDL",
            "CFBundleShortVersionString": "1",
            "CFBundleVersion": "1",
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try data.write(to: contents.appendingPathComponent("Info.plist"), options: .atomic)
        return try XCTUnwrap(Bundle(url: url))
    }
}

private struct CoverageAssetFixture {
    let requestPath: String
    let relativePath: String
    let contentType: String
    let cacheControl: String
    let content: Data

    init(
        _ requestPath: String,
        _ relativePath: String,
        _ contentType: String,
        _ cacheControl: String
    ) {
        self.requestPath = requestPath
        self.relativePath = relativePath
        self.contentType = contentType
        self.cacheControl = cacheControl
        content = Data("fixture:\(requestPath)".utf8)
    }
}

private struct CoverageCredentialBlob: Codable {
    var version: Int
    var secret: Data
    var epoch: UInt64
    var sessions: [CoverageSessionRecord]
}

private struct CoverageSessionRecord: Codable {
    var id: String
    var issuedAt: Date
    var expiresAt: Date
}

private struct CoverageTokenPayload: Codable {
    var version: Int
    var sessionID: String
    var issuedAt: Date
    var expiresAt: Date
    var epoch: UInt64
}

private final class CoverageScriptedRemoteRandom:
    RemoteRandomByteGenerating,
    @unchecked Sendable
{
    private let responses: Mutex<[Data]>

    init(_ responses: [Data]) {
        self.responses = Mutex(responses)
    }

    func bytes(count: Int) throws -> Data {
        responses.withLock { responses in
            guard !responses.isEmpty else {
                return Data(repeating: 0, count: max(0, count))
            }
            return responses.removeFirst()
        }
    }
}

private struct CoverageShortRemoteRandom: RemoteRandomByteGenerating {
    func bytes(count: Int) throws -> Data {
        Data(repeating: 0, count: max(0, count - 1))
    }
}

private actor CoverageCredentialStore: nonisolated RemoteCredentialStoring {
    private var data: Data?
    private var writes = 0

    init(data: Data?) {
        self.data = data
    }

    func readCredential() async throws -> Data? {
        data
    }

    func writeCredential(_ data: Data) async throws {
        self.data = data
        writes += 1
    }

    func writeCount() -> Int {
        writes
    }
}

private actor CoverageRejectingCredentialStore:
    nonisolated RemoteCredentialStoring
{
    enum Failure: Sendable {
        case generic
        case authentication
    }

    private let failure: Failure

    init(failure: Failure) {
        self.failure = failure
    }

    func readCredential() async throws -> Data? {
        nil
    }

    func writeCredential(_: Data) async throws {
        switch failure {
        case .generic:
            throw CoverageInfrastructureError.writeRejected
        case .authentication:
            throw RemoteAuthenticationError.invalidSession
        }
    }
}

private enum CoverageInfrastructureError: Error {
    case writeRejected
}

extension Data {
    fileprivate func coverageBase64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
