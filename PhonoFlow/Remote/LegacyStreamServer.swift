//
//  LegacyStreamServer.swift
//  PhonoFlow
//
//  A deliberately narrow compatibility listener. Unlike RemoteAccessServer,
//  this listener can run while paired Remote Access is disabled and exposes
//  exactly one unauthenticated route: GET /stream.
//

import Foundation

nonisolated public struct LegacyStreamConfiguration: Sendable, Equatable {
    public var bindHost: String
    public var port: UInt16
    public var allowedSources: Set<String>

    public init(
        bindHost: String = "0.0.0.0",
        port: UInt16 = 7865,
        allowedSources: Set<String> = []
    ) {
        self.bindHost = bindHost
        self.port = port
        self.allowedSources = allowedSources
    }
}

nonisolated public enum LegacyStreamServerError: Error, Sendable, Equatable {
    case alreadyRunning
    case configurationLocked
    case notRunning
}

/// Stateless request policy kept separate from the listener lifecycle so the
/// exact-route and source-address rules can be tested without opening a port.
nonisolated public enum LegacyStreamRequestHandler {
    public static func handle(
        _ request: RemoteHTTPRequest,
        allowedSources: Set<String>,
        audio: any RemoteAudioStreamProviding
    ) async -> RemoteRouteResult {
        do {
            let target = try RemoteRequestSecurity.normalizeTarget(
                request.target
            )
            guard target.path == "/stream", target.query == nil else {
                throw problem(
                    status: 404,
                    title: "Not found",
                    detail: "The legacy listener only exposes /stream.",
                    instance: target.path,
                    code: "route_not_found"
                )
            }
            guard request.method == .get else {
                return .response(
                    problemResponse(
                        problem(
                            status: 405,
                            title: "Method not allowed",
                            detail: "The legacy stream only accepts GET.",
                            instance: target.path,
                            code: "method_not_allowed"
                        ),
                        extraHeaders: ["Allow": RemoteHTTPMethod.get.rawValue]
                    ))
            }
            try RemoteRequestSecurity.validateLegacySource(
                remoteAddress: request.remoteAddress,
                allowedSources: allowedSources
            )
            do {
                return .legacyFloat32Audio(
                    try await audio.subscribe(
                        kind: .legacyFloat32,
                        principal: nil,
                        remoteAddress: request.remoteAddress,
                        origin: .dedicatedLegacyListener
                    )
                )
            } catch RemoteAudioSubscriptionError.clientCapacity {
                throw problem(
                    status: 503,
                    title: "Legacy stream unavailable",
                    detail: "The maximum number of audio listeners is connected.",
                    instance: target.path,
                    code: "audio_client_capacity"
                )
            } catch RemoteAudioSubscriptionError.addressCapacity {
                throw problem(
                    status: 503,
                    title: "Legacy stream unavailable",
                    detail: "This client already has the maximum number of audio streams.",
                    instance: target.path,
                    code: "audio_address_capacity"
                )
            }
        } catch let apiProblem as RemoteAPIProblem {
            return .response(problemResponse(apiProblem))
        } catch {
            return .response(
                problemResponse(
                    problem(
                        status: 503,
                        title: "Legacy stream unavailable",
                        detail: "The audio stream could not be opened.",
                        instance: request.target,
                        code: "legacy_stream_unavailable"
                    )))
        }
    }

    private static func problem(
        status: Int,
        title: String,
        detail: String,
        instance: String,
        code: String
    ) -> RemoteAPIProblem {
        RemoteRequestSecurity.problem(
            status: status,
            title: title,
            detail: detail,
            instance: instance,
            code: code
        )
    }

    private static func problemResponse(
        _ problem: RemoteAPIProblem,
        extraHeaders: [String: String] = [:]
    ) -> RemoteHTTPResponse {
        var headers = extraHeaders
        headers["Content-Type"] =
            "application/problem+json; charset=utf-8"
        return RemoteHTTPResponse(
            status: problem.status,
            headers: RemoteHTTPHeaders.applyingSecurityHeaders(
                to: headers,
                noStore: true
            ),
            body: (try? RemoteJSON.encoder().encode(problem)) ?? Data()
        )
    }
}

/// Owns the dedicated VLC/mpv listener. It intentionally has no pairing,
/// static assets, API router, SSE hub, or Bonjour advertiser.
public actor LegacyStreamServer {
    private var configuration: LegacyStreamConfiguration
    private let audio: any RemoteAudioStreamProviding
    private let transport: any RemoteHTTPTransport
    private var state: RemoteServerLifecycleState = .disabled
    private var endpoint: RemoteBoundEndpoint?
    private var lifecycleGeneration: UInt64 = 0

    public init(
        configuration: LegacyStreamConfiguration =
            LegacyStreamConfiguration(),
        audio: any RemoteAudioStreamProviding,
        transport: (any RemoteHTTPTransport)? = nil
    ) {
        self.configuration = configuration
        self.audio = audio
        self.transport =
            transport ?? RemoteHTTPTransportFactory.makeDefault()
    }

    public func lifecycleState() -> RemoteServerLifecycleState {
        state
    }

    public func boundEndpoint() -> RemoteBoundEndpoint? {
        endpoint
    }

    public func currentConfiguration() -> LegacyStreamConfiguration {
        configuration
    }

    public func updateConfiguration(
        _ configuration: LegacyStreamConfiguration
    ) throws {
        guard state == .disabled else {
            throw LegacyStreamServerError.configurationLocked
        }
        self.configuration = configuration
    }

    public func start() async throws {
        guard state == .disabled else {
            throw LegacyStreamServerError.alreadyRunning
        }
        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration
        let configuration = configuration
        state = .starting

        do {
            let resolvedEndpoint = try await transport.start(
                configuration: RemoteTransportConfiguration(
                    bindHost: configuration.bindHost,
                    port: configuration.port,
                    maximumBodyBytes: 1_024
                )
            ) { [audio] request in
                await LegacyStreamRequestHandler.handle(
                    request,
                    allowedSources: configuration.allowedSources,
                    audio: audio
                )
            }
            try requireActiveStart(generation)
            endpoint = resolvedEndpoint
            state = .running(
                host: resolvedEndpoint.host,
                port: resolvedEndpoint.port
            )
        } catch {
            guard lifecycleGeneration == generation else {
                throw LegacyStreamServerError.notRunning
            }
            await transport.stop()
            guard lifecycleGeneration == generation else {
                throw LegacyStreamServerError.notRunning
            }
            await audio.revoke(origin: .dedicatedLegacyListener)
            guard lifecycleGeneration == generation else {
                throw LegacyStreamServerError.notRunning
            }
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
        await transport.stop()
        guard lifecycleGeneration == generation else { return }
        await audio.revoke(origin: .dedicatedLegacyListener)
        guard lifecycleGeneration == generation else { return }
        endpoint = nil
        state = .disabled
    }

    public func listenerCount() async -> Int {
        await audio.listenerCount(kind: .legacyFloat32)
    }

    private func requireActiveStart(_ generation: UInt64) throws {
        guard lifecycleGeneration == generation, state == .starting else {
            throw LegacyStreamServerError.notRunning
        }
    }
}
