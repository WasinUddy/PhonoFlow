#if DEBUG
    import Foundation
    import XCTest
    @testable import PhonoFlow

    final class RemoteAcceptanceEnvironmentTests: XCTestCase {
        func testDisabledEnvironmentDoesNotChangeConfiguration() {
            let environment = RemoteAcceptanceEnvironment(environment: [:])
            let base = RemoteAccessConfiguration(
                bindHost: "0.0.0.0",
                port: 7_866,
                serviceName: "Custom",
                allowedHosts: ["custom.local"],
                advertiseBonjour: true
            )

            XCTAssertFalse(environment.isEnabled)
            XCTAssertNil(environment.pairingCode)
            XCTAssertNil(environment.stateDirectory)
            XCTAssertTrue(environment.disablesBonjour)
            XCTAssertEqual(environment.applying(to: base), base)
        }

        func testEnabledEnvironmentAcceptsOnlyDocumentedDeterministicInputs() {
            let statePath = FileManager.default.temporaryDirectory
                .appendingPathComponent("PhonoFlow Acceptance State")
                .path
            let environment = RemoteAcceptanceEnvironment(environment: [
                "PHONOFLOW_ACCEPTANCE": "1",
                "PHONOFLOW_REMOTE_BIND_HOST": "::1",
                "PHONOFLOW_REMOTE_PORT": "17867",
                "PHONOFLOW_PAIRING_CODE": "123456",
                "PHONOFLOW_STATE_DIR": statePath,
                "PHONOFLOW_DISABLE_BONJOUR": "0",
            ])

            XCTAssertTrue(environment.isEnabled)
            XCTAssertEqual(environment.bindHost, "::1")
            XCTAssertEqual(environment.port, 17_867)
            XCTAssertEqual(environment.pairingCode, "123456")
            XCTAssertEqual(environment.stateDirectory?.path, statePath)
            XCTAssertTrue(
                environment.disablesBonjour,
                "Acceptance mode must never advertise regardless of an environment override"
            )
        }

        func testUnsafeOrInvalidInputsFallBackToLoopbackDefaults() {
            for host in ["0.0.0.0", "::", "192.168.1.20", "localhost", "evil.example"] {
                let environment = RemoteAcceptanceEnvironment(environment: [
                    "PHONOFLOW_ACCEPTANCE": "1",
                    "PHONOFLOW_REMOTE_BIND_HOST": host,
                    "PHONOFLOW_REMOTE_PORT": "70000",
                    "PHONOFLOW_PAIRING_CODE": "12345A",
                ])

                XCTAssertEqual(environment.bindHost, "127.0.0.1", host)
                XCTAssertEqual(environment.port, 17_866, host)
                XCTAssertNil(environment.pairingCode, host)
            }
        }

        func testApplyingEnabledEnvironmentForcesLoopbackAndDisablesBonjour() {
            let environment = RemoteAcceptanceEnvironment(environment: [
                "PHONOFLOW_ACCEPTANCE": "1",
                "PHONOFLOW_REMOTE_BIND_HOST": "127.0.0.1",
                "PHONOFLOW_REMOTE_PORT": "0",
                "PHONOFLOW_PAIRING_CODE": "654321",
            ])
            let base = RemoteAccessConfiguration(
                bindHost: "0.0.0.0",
                port: 7_866,
                allowedHosts: ["studio-mac.local"],
                advertiseBonjour: true
            )

            let applied = environment.applying(to: base)

            XCTAssertEqual(applied.bindHost, "127.0.0.1")
            XCTAssertEqual(applied.port, 0)
            XCTAssertFalse(applied.advertiseBonjour)
            XCTAssertTrue(
                applied.allowedHosts.isSuperset(of: [
                    "studio-mac.local",
                    "localhost",
                    "127.0.0.1",
                    "::1",
                ]))
        }

        func testReadinessFileContainsActualBoundEndpoint() throws {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("PhonoFlowAcceptance-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            let environment = RemoteAcceptanceEnvironment(environment: [
                "PHONOFLOW_ACCEPTANCE": "1",
                "PHONOFLOW_STATE_DIR": directory.path,
            ])
            let endpoint = RemoteBoundEndpoint(host: "127.0.0.1", port: 41_234)

            try environment.writeReadiness(endpoint)

            let data = try Data(
                contentsOf: directory.appendingPathComponent("remote-ready.json")
            )
            let decoded = try RemoteJSON.decoder().decode(
                RemoteBoundEndpoint.self,
                from: data
            )
            XCTAssertEqual(decoded, endpoint)
        }
    }
#endif
