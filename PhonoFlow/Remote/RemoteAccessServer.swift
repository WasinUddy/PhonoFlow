//
//  RemoteAccessServer.swift
//  PhonoFlow
//
//  Lifecycle owner for the paired LAN service. It is independent of Radio:
//  `/audio/live.wav`, controls, and WebUI remain available whenever Remote
//  Access is enabled; only the compatibility `/stream` route is Radio-gated.
//

import Foundation

nonisolated public struct RemoteListenerCounts: Sendable, Equatable {
    public var eventStreams: Int
    public var audioStreams: Int

    public init(eventStreams: Int, audioStreams: Int) {
        self.eventStreams = eventStreams
        self.audioStreams = audioStreams
    }

    public var total: Int { eventStreams + audioStreams }
}

nonisolated public enum RemoteAccessServerError: Error, Sendable, Equatable {
    case alreadyRunning
    case configurationLocked
    case notRunning
}

public actor RemoteAccessServer {
    private var configuration: RemoteAccessConfiguration
    private var configuredAllowedHosts: Set<String>
    private let pairing: RemotePairingService
    private let eventHub: RemoteEventHub
    private let audio: any RemoteAudioStreamProviding
    private let assets: any RemoteStaticAssetProviding
    private let bonjour: any RemoteBonjourAdvertising
    private let transport: any RemoteHTTPTransport
    private let localAuthorityProvider: @Sendable () -> Set<String>
    private let usesAcceptanceEnvironment: Bool
    private let router: RemoteRequestRouter
    private var state: RemoteServerLifecycleState = .disabled
    private var endpoint: RemoteBoundEndpoint?
    private var lifecycleGeneration: UInt64 = 0
    private var browserRevocationInProgress = false

    public init(
        configuration: RemoteAccessConfiguration = RemoteAccessConfiguration(),
        coordinator: any RemoteControlCoordinating,
        pairing: RemotePairingService? = nil,
        eventHub: RemoteEventHub? = nil,
        audio: (any RemoteAudioStreamProviding)? = nil,
        assets: (any RemoteStaticAssetProviding)? = nil,
        bonjour: (any RemoteBonjourAdvertising)? = nil,
        transport: (any RemoteHTTPTransport)? = nil,
        localAuthorityProvider: @escaping @Sendable () -> Set<String> = {
            RemoteLocalInterfaces.currentAuthorities()
        },
        usesAcceptanceEnvironment: Bool = true
    ) {
        var resolvedConfiguration = configuration
        #if DEBUG
            if usesAcceptanceEnvironment {
                let acceptance = RemoteAcceptanceEnvironment()
                resolvedConfiguration = acceptance.applying(
                    to: resolvedConfiguration
                )
            }
        #endif
        let configuredAllowedHosts = resolvedConfiguration.allowedHosts
        resolvedConfiguration.allowedHosts.formUnion(
            localAuthorityProvider()
        )

        let resolvedPairing =
            pairing
            ?? RemoteAccessDependencyFactory.makePairing(
                usesAcceptanceEnvironment: usesAcceptanceEnvironment
            )
        let resolvedEvents =
            eventHub
            ?? RemoteAccessDependencyFactory.makeEvents(
                configuration: resolvedConfiguration
            )
        let resolvedAudio =
            audio
            ?? RemoteAccessDependencyFactory.makeAudio(
                configuration: resolvedConfiguration
            )
        let resolvedAssets = assets ?? RemoteAccessDependencyFactory.makeAssets()

        self.configuration = resolvedConfiguration
        self.configuredAllowedHosts = configuredAllowedHosts
        self.pairing = resolvedPairing
        self.eventHub = resolvedEvents
        self.audio = resolvedAudio
        self.assets = resolvedAssets
        self.bonjour = bonjour ?? RemoteAccessDependencyFactory.makeBonjour()
        self.transport = transport ?? RemoteHTTPTransportFactory.makeDefault()
        self.localAuthorityProvider = localAuthorityProvider
        self.usesAcceptanceEnvironment = usesAcceptanceEnvironment
        self.router = RemoteRequestRouter(
            configuration: resolvedConfiguration,
            coordinator: coordinator,
            pairing: resolvedPairing,
            eventHub: resolvedEvents,
            audio: resolvedAudio,
            assets: resolvedAssets
        )
    }

    public func lifecycleState() -> RemoteServerLifecycleState {
        state
    }

    public func boundEndpoint() -> RemoteBoundEndpoint? {
        endpoint
    }

    public func currentConfiguration() -> RemoteAccessConfiguration {
        configuration
    }

    public func updateConfiguration(_ configuration: RemoteAccessConfiguration) async throws {
        guard case .disabled = state else {
            throw RemoteAccessServerError.configurationLocked
        }
        var updated = configuration
        #if DEBUG
            if usesAcceptanceEnvironment {
                updated = RemoteAcceptanceEnvironment().applying(to: updated)
            }
        #endif
        configuredAllowedHosts = updated.allowedHosts
        updated.allowedHosts.formUnion(localAuthorityProvider())
        self.configuration = updated
        await router.updateConfiguration(updated)
    }

    /// Refreshes exact IP and hostname authorities after DHCP, Wi-Fi, VPN, or
    /// hostname changes without restarting capture or the HTTP listener.
    public func refreshLocalAuthorities() async {
        configuration.allowedHosts = configuredAllowedHosts.union(
            localAuthorityProvider()
        )
        await router.updateConfiguration(configuration)
    }

    public func start() async throws {
        guard case .disabled = state else {
            throw RemoteAccessServerError.alreadyRunning
        }
        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration
        state = .starting

        do {
            try await pairing.prepare()
            try requireActiveStart(generation)
            #if DEBUG
                if usesAcceptanceEnvironment {
                    let acceptance = RemoteAcceptanceEnvironment()
                    if acceptance.isEnabled,
                        let code = acceptance.pairingCode
                    {
                        try await pairing.issuePairingCodeForAcceptance(code)
                        try requireActiveStart(generation)
                    }
                }
            #endif

            await refreshLocalAuthorities()
            try requireActiveStart(generation)
            let resolvedEndpoint = try await transport.start(
                configuration: RemoteTransportConfiguration(
                    bindHost: configuration.bindHost,
                    port: configuration.port,
                    maximumBodyBytes: configuration.maxJSONBodyBytes
                )
            ) { [router] request in
                await router.handle(request)
            }
            try requireActiveStart(generation)
            endpoint = resolvedEndpoint
            await router.setBoundEndpoint(resolvedEndpoint)
            try requireActiveStart(generation)

            if configuration.advertiseBonjour {
                try await bonjour.start(
                    serviceName: configuration.serviceName,
                    serviceType: "_phonoflow._tcp.",
                    port: resolvedEndpoint.port,
                    txt: [
                        "api": "v1",
                        "path": "/",
                        "paired": "true",
                    ]
                )
                try requireActiveStart(generation)
            }
            state = .running(host: resolvedEndpoint.host, port: resolvedEndpoint.port)

            #if DEBUG
                if usesAcceptanceEnvironment {
                    // The rendezvous file is optional test instrumentation. A
                    // sandboxed UI-test runner may not share the caller's
                    // temporary directory, so its failure must not tear down an
                    // otherwise healthy Remote Access listener.
                    _ = try? RemoteAcceptanceEnvironment().writeReadiness(
                        resolvedEndpoint
                    )
                }
            #endif
        } catch {
            guard lifecycleGeneration == generation else {
                throw RemoteAccessServerError.notRunning
            }
            await pairing.invalidatePairingCode()
            try requireCurrentGeneration(generation)
            await bonjour.stop()
            try requireCurrentGeneration(generation)
            await eventHub.revokeAll()
            try requireCurrentGeneration(generation)
            await audio.revoke(origin: .pairedRemoteAccess)
            try requireCurrentGeneration(generation)
            await transport.stop()
            try requireCurrentGeneration(generation)
            endpoint = nil
            state = .failed(String(describing: error))
            throw error
        }
    }

    public func stop() async {
        switch state {
        case .disabled, .stopping:
            return
        case .starting, .running, .failed:
            break
        }
        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration
        state = .stopping
        await pairing.invalidatePairingCode()
        await bonjour.stop()
        await eventHub.revokeAll()
        await audio.revoke(origin: .pairedRemoteAccess)
        await transport.stop()
        guard lifecycleGeneration == generation else { return }
        endpoint = nil
        state = .disabled
    }

    @discardableResult
    public func issuePairingCode() async throws -> RemotePairingCode {
        guard case .running = state, !browserRevocationInProgress else {
            throw RemoteAccessServerError.notRunning
        }
        let code = try await pairing.issuePairingCode()
        guard case .running = state, !browserRevocationInProgress else {
            await pairing.invalidatePairingCode()
            throw RemoteAccessServerError.notRunning
        }
        return code
    }

    public func currentPairingCode() async -> RemotePairingCode? {
        guard case .running = state else { return nil }
        let code = await pairing.currentPairingCode()
        guard case .running = state, !browserRevocationInProgress else {
            return nil
        }
        return code
    }

    public func revokeAllBrowsers() async throws {
        guard !browserRevocationInProgress else {
            throw RemoteAccessServerError.configurationLocked
        }
        browserRevocationInProgress = true
        defer { browserRevocationInProgress = false }
        try await pairing.revokeAll()
        await pairing.invalidatePairingCode()
        await eventHub.revokeAll()
        await audio.revokeAllAuthenticated()
        await pairing.invalidatePairingCode()
    }

    public func listenerCounts() async -> RemoteListenerCounts {
        RemoteListenerCounts(
            eventStreams: await eventHub.clientCount,
            audioStreams: await audio.listenerCount()
        )
    }

    /// Called by the coordinator after native or non-HTTP authoritative changes.
    public func publish(snapshot: RemoteStateSnapshot) async {
        await eventHub.publish(snapshot: snapshot)
    }

    /// Safe to call from an audio-analysis worker, never from the real-time callback.
    public func publish(meters: RemoteMeterSnapshot) async {
        await eventHub.publish(meters: meters)
    }

    /// Safe to call from `SpectrogramProcessor`'s worker.
    public func publish(spectrogram: RemoteSpectrogramColumn) async {
        await eventHub.publish(spectrogram: spectrogram)
    }

    private func requireActiveStart(_ generation: UInt64) throws {
        guard lifecycleGeneration == generation, state == .starting else {
            throw RemoteAccessServerError.notRunning
        }
    }

    private func requireCurrentGeneration(_ generation: UInt64) throws {
        guard lifecycleGeneration == generation else {
            throw RemoteAccessServerError.notRunning
        }
    }
}

private nonisolated enum RemoteAccessDependencyFactory {
    static func makePairing(
        usesAcceptanceEnvironment: Bool
    ) -> RemotePairingService {
        #if DEBUG
            if usesAcceptanceEnvironment,
                RemoteAcceptanceEnvironment().isEnabled
            {
                return RemotePairingService(store: InMemoryRemoteCredentialStore())
            }
        #endif
        return RemotePairingService()
    }

    static func makeEvents(configuration: RemoteAccessConfiguration) -> RemoteEventHub {
        RemoteEventHub(maximumClients: configuration.maxEventClients)
    }

    static func makeAudio(
        configuration: RemoteAccessConfiguration
    ) -> any RemoteAudioStreamProviding {
        RemoteAudioFanout(
            maximumClients: configuration.maxAudioClients,
            maximumClientsPerAddress: configuration.maxAudioClientsPerAddress
        )
    }

    static func makeAssets() -> any RemoteStaticAssetProviding {
        BundledRemoteStaticAssetProvider(
            developmentRoot: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("WebUI", isDirectory: true)
        )
    }

    static func makeBonjour() -> any RemoteBonjourAdvertising {
        FoundationRemoteBonjourAdvertiser()
    }
}

nonisolated public enum RemoteHTTPTransportFactory {
    public static func makeDefault() -> any RemoteHTTPTransport {
        #if canImport(Hummingbird)
            HummingbirdRemoteHTTPTransport()
        #else
            UnavailableRemoteHTTPTransport()
        #endif
    }
}
