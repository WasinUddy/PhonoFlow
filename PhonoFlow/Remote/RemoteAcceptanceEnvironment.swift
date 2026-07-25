//
//  RemoteAcceptanceEnvironment.swift
//  PhonoFlow
//
//  Deterministic debug-only launch inputs shared by XCUITest and Playwright.
//

import Foundation

#if DEBUG
    nonisolated public struct RemoteAcceptanceEnvironment: Sendable, Equatable {
        public var isEnabled: Bool
        public var bindHost: String
        public var port: UInt16
        public var pairingCode: String?
        public var stateDirectory: URL?
        public var disablesBonjour: Bool

        public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
            isEnabled = environment["PHONOFLOW_ACCEPTANCE"] == "1"
            let requestedHost = environment["PHONOFLOW_REMOTE_BIND_HOST"]
            bindHost = requestedHost == "::1" ? "::1" : "127.0.0.1"
            port = environment["PHONOFLOW_REMOTE_PORT"].flatMap(UInt16.init) ?? 17_866
            let candidate = environment["PHONOFLOW_PAIRING_CODE"]
            pairingCode =
                candidate?.range(of: #"^\d{6}$"#, options: .regularExpression) == nil
                ? nil
                : candidate
            stateDirectory = environment["PHONOFLOW_STATE_DIR"].map {
                URL(fileURLWithPath: $0, isDirectory: true)
            }
            // Acceptance servers are always loopback-only and undiscoverable.
            disablesBonjour = true
        }

        public func applying(to base: RemoteAccessConfiguration) -> RemoteAccessConfiguration {
            guard isEnabled else { return base }
            var configuration = base
            configuration.bindHost = bindHost
            configuration.port = port
            configuration.advertiseBonjour = !disablesBonjour
            configuration.allowedHosts.formUnion(["localhost", "127.0.0.1", "::1"])
            return configuration
        }

        /// Optional rendezvous file for parallel CI jobs using port 0.
        public func writeReadiness(_ endpoint: RemoteBoundEndpoint) throws {
            guard isEnabled, let stateDirectory else { return }
            try FileManager.default.createDirectory(
                at: stateDirectory,
                withIntermediateDirectories: true
            )
            let destination = stateDirectory.appendingPathComponent("remote-ready.json")
            let data = try RemoteJSON.encoder().encode(endpoint)
            try data.write(to: destination, options: .atomic)
        }
    }
#endif
