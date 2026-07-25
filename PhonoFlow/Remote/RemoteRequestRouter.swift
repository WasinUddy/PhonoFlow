//
//  RemoteRequestRouter.swift
//  PhonoFlow
//

import Foundation

public actor RemoteRequestRouter {
    private struct Route: Sendable {
        var methods: Set<RemoteHTTPMethod>
        var requiresSession: Bool
        var maximumBodyBytes: Int
    }

    private weak var coordinator: (any RemoteControlCoordinating)?
    private let pairing: RemotePairingService
    private let eventHub: RemoteEventHub
    private let audio: any RemoteAudioStreamProviding
    private let assets: any RemoteStaticAssetProviding
    private let rateLimiter: RemoteRequestRateLimiter
    private var configuration: RemoteAccessConfiguration
    private var boundPort: UInt16

    private var routes: [String: Route] {
        let json = configuration.maxJSONBodyBytes
        let pair = configuration.maxPairBodyBytes
        return [
            "/": Route(methods: [.get, .head], requiresSession: false, maximumBodyBytes: 0),
            "/styles.css": Route(methods: [.get, .head], requiresSession: false, maximumBodyBytes: 0),
            "/src/app.js": Route(methods: [.get, .head], requiresSession: false, maximumBodyBytes: 0),
            "/src/api.js": Route(methods: [.get, .head], requiresSession: false, maximumBodyBytes: 0),
            "/src/live-audio.js": Route(methods: [.get, .head], requiresSession: false, maximumBodyBytes: 0),
            "/src/state.js": Route(methods: [.get, .head], requiresSession: false, maximumBodyBytes: 0),
            "/src/spectrogram.js": Route(methods: [.get, .head], requiresSession: false, maximumBodyBytes: 0),
            "/src/view.js": Route(methods: [.get, .head], requiresSession: false, maximumBodyBytes: 0),
            "/api/v1/auth/pair": Route(methods: [.post], requiresSession: false, maximumBodyBytes: pair),
            "/api/v1/auth/logout": Route(methods: [.post], requiresSession: true, maximumBodyBytes: json),
            "/api/v1/state": Route(methods: [.get], requiresSession: true, maximumBodyBytes: 0),
            "/api/v1/events": Route(methods: [.get], requiresSession: true, maximumBodyBytes: 0),
            "/api/v1/devices/refresh": Route(methods: [.post], requiresSession: true, maximumBodyBytes: json),
            "/api/v1/audio/selection": Route(methods: [.put], requiresSession: true, maximumBodyBytes: json),
            "/api/v1/monitor": Route(methods: [.put], requiresSession: true, maximumBodyBytes: json),
            "/api/v1/processing": Route(methods: [.put], requiresSession: true, maximumBodyBytes: json),
            "/api/v1/equalizer": Route(methods: [.put], requiresSession: true, maximumBodyBytes: json),
            "/api/v1/radio": Route(methods: [.put], requiresSession: true, maximumBodyBytes: json),
            "/api/v1/recording": Route(methods: [.put], requiresSession: true, maximumBodyBytes: json),
            "/audio/live.wav": Route(methods: [.get], requiresSession: true, maximumBodyBytes: 0),
            "/stream": Route(
                methods: [.get],
                requiresSession: !configuration.allowUnauthenticatedLegacyStream,
                maximumBodyBytes: 0
            ),
        ]
    }

    public init(
        configuration: RemoteAccessConfiguration,
        coordinator: any RemoteControlCoordinating,
        pairing: RemotePairingService,
        eventHub: RemoteEventHub,
        audio: any RemoteAudioStreamProviding,
        assets: any RemoteStaticAssetProviding,
        rateLimiter: RemoteRequestRateLimiter? = nil
    ) {
        self.configuration = configuration
        self.boundPort = configuration.port
        self.coordinator = coordinator
        self.pairing = pairing
        self.eventHub = eventHub
        self.audio = audio
        self.assets = assets
        self.rateLimiter =
            rateLimiter
            ?? RemoteRequestRateLimiter(
                maximumRequests: configuration.generalRequestsPerMinute
            )
    }

    public func setBoundEndpoint(_ endpoint: RemoteBoundEndpoint) {
        boundPort = endpoint.port
    }

    public func updateConfiguration(_ configuration: RemoteAccessConfiguration) {
        self.configuration = configuration
        if configuration.port != 0 {
            boundPort = configuration.port
        }
    }

    public func handle(_ request: RemoteHTTPRequest) async -> RemoteRouteResult {
        let limit = await rateLimiter.check(remoteAddress: request.remoteAddress)
        guard limit.isAllowed else {
            let instance =
                (try? RemoteRequestSecurity.normalizeTarget(request.target))?.path
                ?? "/"
            return .response(
                problemResponse(
                    RemoteRequestSecurity.problem(
                        status: 429,
                        title: "Too many requests",
                        detail: "This client has exceeded the Remote Access request limit.",
                        instance: instance,
                        code: "request_rate_limited"
                    ),
                    extraHeaders: ["Retry-After": String(limit.retryAfterSeconds)]
                ))
        }

        do {
            let target = try RemoteRequestSecurity.normalizeTarget(request.target)
            guard target.query == nil else {
                throw RemoteRequestSecurity.problem(
                    status: 404,
                    title: "Not found",
                    detail: "This endpoint does not accept query parameters.",
                    instance: target.path,
                    code: "route_not_found"
                )
            }
            guard let route = routes[target.path] else {
                throw RemoteRequestSecurity.problem(
                    status: 404,
                    title: "Not found",
                    detail: "No Remote Access route matches this path.",
                    instance: target.path,
                    code: "route_not_found"
                )
            }
            guard route.methods.contains(request.method) else {
                return .response(
                    problemResponse(
                        RemoteRequestSecurity.problem(
                            status: 405,
                            title: "Method not allowed",
                            detail: "This route does not accept \(request.method.rawValue).",
                            instance: target.path,
                            code: "method_not_allowed"
                        ),
                        extraHeaders: [
                            "Allow": route.methods.map(\.rawValue).sorted().joined(separator: ", ")
                        ]
                    ))
            }

            let authority = try RemoteRequestSecurity.validateAuthority(
                hostHeader: request[header: "host"],
                remoteAddress: request.remoteAddress,
                configuration: configuration,
                boundPort: boundPort
            )

            guard request.body.count <= route.maximumBodyBytes else {
                throw RemoteRequestSecurity.problem(
                    status: 413,
                    title: "Content too large",
                    detail: "The request body exceeds this endpoint's limit.",
                    instance: target.path,
                    code: "body_too_large"
                )
            }
            if request.method.isMutation {
                try RemoteRequestSecurity.validateMutation(request: request, authority: authority)
            }

            let principal: RemoteSessionPrincipal?
            if route.requiresSession {
                principal = try await authenticatedPrincipal(for: request, instance: target.path)
            } else if target.path == "/stream" {
                // An explicitly unauthenticated compatibility stream still
                // accepts a paired session. Valid sessions bypass the
                // optional legacy source-IP allow-list.
                principal = try await optionalAuthenticatedPrincipal(
                    for: request,
                    instance: target.path
                )
            } else {
                principal = nil
            }

            return try await dispatch(
                path: target.path,
                request: request,
                principal: principal
            )
        } catch let problem as RemoteAPIProblem {
            return .response(problemResponse(problem))
        } catch {
            return .response(
                problemResponse(
                    RemoteRequestSecurity.problem(
                        status: 503,
                        title: "Remote Access unavailable",
                        detail: "The request could not be completed.",
                        instance: request.target,
                        code: "remote_access_unavailable"
                    )
                ))
        }
    }

    private func dispatch(
        path: String,
        request: RemoteHTTPRequest,
        principal: RemoteSessionPrincipal?
    ) async throws -> RemoteRouteResult {
        switch path {
        case "/", "/styles.css", "/src/app.js", "/src/api.js", "/src/live-audio.js",
            "/src/state.js", "/src/spectrogram.js", "/src/view.js":
            guard let asset = await assets.asset(forRequestPath: path) else {
                throw RemoteRequestSecurity.problem(
                    status: 404,
                    title: "Not found",
                    detail: "The bundled WebUI resource is unavailable.",
                    instance: path,
                    code: "asset_not_found"
                )
            }
            let body = request.method == .head ? Data() : asset.content
            return .response(
                RemoteHTTPResponse(
                    status: 200,
                    headers: RemoteHTTPHeaders.applyingSecurityHeaders(to: [
                        "Content-Type": asset.contentType,
                        "Cache-Control": asset.cacheControl,
                        "Content-Length": String(asset.content.count),
                    ]),
                    body: body
                ))

        case "/api/v1/auth/pair":
            let payload: RemotePairRequest = try decode(request, path: path)
            let issued: RemoteIssuedSession
            do {
                issued = try await pairing.pair(
                    code: payload.code,
                    remoteAddress: request.remoteAddress
                )
            } catch RemoteAuthenticationError.invalidPairingCode {
                throw RemoteRequestSecurity.problem(
                    status: 401,
                    title: "Pairing failed",
                    detail: "The pairing code is invalid or expired.",
                    instance: path,
                    code: "pairing_failed"
                )
            } catch RemoteAuthenticationError.pairingRateLimited(let seconds) {
                return .response(
                    problemResponse(
                        RemoteRequestSecurity.problem(
                            status: 429,
                            title: "Pairing temporarily locked",
                            detail: "Too many failed pairing attempts.",
                            instance: path,
                            code: "pairing_rate_limited"
                        ),
                        extraHeaders: ["Retry-After": String(seconds)]
                    ))
            }
            await revokeStreams(sessionIDs: issued.invalidatedSessionIDs)
            let snapshot = try await stateSnapshot(path: path)
            let response = RemotePairResponse(expiresAt: issued.principal.expiresAt, state: snapshot)
            return .response(
                try jsonResponse(
                    response,
                    headers: ["Set-Cookie": RemotePairingService.sessionCookie(token: issued.token)]
                ))

        case "/api/v1/auth/logout":
            guard
                let token = RemotePairingService.token(
                    fromCookieHeader: request[header: "cookie"]
                )
            else {
                throw unauthorized(path)
            }
            let revoked: RemoteSessionPrincipal
            do {
                revoked = try await pairing.revoke(token: token)
            } catch let error as RemoteAuthenticationError {
                switch error {
                case .invalidSession:
                    throw unauthorized(path)
                case .credentialFailure:
                    throw credentialUnavailable(path)
                default:
                    throw credentialUnavailable(path)
                }
            }
            await eventHub.revoke(sessionID: revoked.sessionID)
            await audio.revoke(sessionID: revoked.sessionID)
            return .response(
                RemoteHTTPResponse(
                    status: 204,
                    headers: RemoteHTTPHeaders.applyingSecurityHeaders(
                        to: ["Set-Cookie": RemotePairingService.expiredSessionCookie()],
                        noStore: true
                    )
                ))

        case "/api/v1/state":
            return .response(try jsonResponse(try await stateSnapshot(path: path)))

        case "/api/v1/events":
            guard let principal else { throw unauthorized(path) }
            do {
                let subscription = try await eventHub.subscribe(
                    principal: principal,
                    snapshot: try await stateSnapshot(path: path),
                    remoteAddress: request.remoteAddress
                )
                do {
                    try await revalidateStreamPrincipal(principal, path: path)
                } catch {
                    await subscription.cancel()
                    throw error
                }
                return .events(subscription)
            } catch is RemoteEventCapacityError {
                throw RemoteRequestSecurity.problem(
                    status: 503,
                    title: "Event stream unavailable",
                    detail: "The maximum number of browser event streams is connected.",
                    instance: path,
                    code: "event_client_capacity"
                )
            }

        case "/api/v1/devices/refresh":
            return try await commandResponse(.refreshDevices)

        case "/api/v1/audio/selection":
            let command: RemoteAudioSelection = try decode(request, path: path)
            guard !command.inputUID.isEmpty, !command.inputRouteID.isEmpty else {
                throw validationProblem("Input UID and route ID are required.", path: path)
            }
            return try await commandResponse(.selectAudio(command))

        case "/api/v1/monitor":
            return try await commandResponse(.setMonitor(try decode(request, path: path)))

        case "/api/v1/processing":
            let command: RemoteProcessingCommand = try decode(request, path: path)
            guard command.gain != nil || command.autoGainEnabled != nil || command.enabled != nil else {
                throw validationProblem("At least one processing field is required.", path: path)
            }
            if let gain = command.gain, !gain.isFinite || !(0...4).contains(gain) {
                throw validationProblem("Gain must be finite and between 0 and 4.", path: path)
            }
            return try await commandResponse(.setProcessing(command))

        case "/api/v1/equalizer":
            let command: RemoteEqualizerCommand = try decode(request, path: path)
            guard command.enabled != nil || command.bands != nil else {
                throw validationProblem("Equalizer enabled or bands is required.", path: path)
            }
            if let bands = command.bands {
                guard bands.count == 10,
                    bands.allSatisfy({
                        $0.frequencyHz.isFinite && $0.frequencyHz > 0 && $0.gainDB.isFinite
                            && (-12...12).contains($0.gainDB)
                    })
                else {
                    throw validationProblem(
                        "Equalizer must contain ten finite bands with gains from -12 to 12 dB.",
                        path: path
                    )
                }
            }
            return try await commandResponse(.setEqualizer(command))

        case "/api/v1/radio":
            return try await commandResponse(.setRadio(try decode(request, path: path)))

        case "/api/v1/recording":
            return try await commandResponse(.setRecording(try decode(request, path: path)))

        case "/audio/live.wav":
            guard let principal else { throw unauthorized(path) }
            let subscription = try await audio.subscribe(
                kind: .pcm16Browser,
                principal: principal,
                remoteAddress: request.remoteAddress
            )
            do {
                try await revalidateStreamPrincipal(principal, path: path)
            } catch {
                await subscription.cancel()
                throw error
            }
            return .pcm16Audio(subscription)

        case "/stream":
            if principal == nil {
                try RemoteRequestSecurity.validateLegacySource(
                    remoteAddress: request.remoteAddress,
                    allowedSources: configuration.legacyAllowedSources,
                    instance: path
                )
            }
            let snapshot = try await stateSnapshot(path: path)
            guard snapshot.radio.enabled else {
                throw RemoteRequestSecurity.problem(
                    status: 503,
                    title: "Radio is off",
                    detail: "Enable Radio before opening the legacy stream.",
                    instance: path,
                    code: "radio_disabled"
                )
            }
            let subscription = try await audio.subscribe(
                kind: .legacyFloat32,
                principal: principal,
                remoteAddress: request.remoteAddress
            )
            if let principal {
                do {
                    try await revalidateStreamPrincipal(principal, path: path)
                } catch {
                    await subscription.cancel()
                    throw error
                }
            }
            return .legacyFloat32Audio(subscription)

        default:
            throw RemoteRequestSecurity.problem(
                status: 404,
                title: "Not found",
                detail: "No route matches this path.",
                instance: path,
                code: "route_not_found"
            )
        }
    }

    private func authenticatedPrincipal(
        for request: RemoteHTTPRequest,
        instance: String
    ) async throws -> RemoteSessionPrincipal {
        guard
            let token = RemotePairingService.token(
                fromCookieHeader: request[header: "cookie"]
            )
        else {
            throw unauthorized(instance)
        }
        do {
            return try await pairing.validate(token: token)
        } catch let error as RemoteAuthenticationError {
            if error == .invalidSession {
                throw unauthorized(instance)
            }
            throw credentialUnavailable(instance)
        }
    }

    private func optionalAuthenticatedPrincipal(
        for request: RemoteHTTPRequest,
        instance: String
    ) async throws -> RemoteSessionPrincipal? {
        guard
            let token = RemotePairingService.token(
                fromCookieHeader: request[header: "cookie"]
            )
        else {
            return nil
        }
        do {
            return try await pairing.validate(token: token)
        } catch let error as RemoteAuthenticationError {
            if error == .invalidSession {
                throw unauthorized(instance)
            }
            throw credentialUnavailable(instance)
        }
    }

    private func revalidateStreamPrincipal(
        _ principal: RemoteSessionPrincipal,
        path: String
    ) async throws {
        do {
            try await pairing.validate(principal: principal)
        } catch let error as RemoteAuthenticationError {
            if error == .invalidSession {
                throw unauthorized(path)
            }
            throw credentialUnavailable(path)
        }
    }

    private func revokeStreams(sessionIDs: [String]) async {
        for sessionID in Set(sessionIDs) {
            await eventHub.revoke(sessionID: sessionID)
            await audio.revoke(sessionID: sessionID)
        }
    }

    private func unauthorized(_ path: String) -> RemoteAPIProblem {
        RemoteRequestSecurity.problem(
            status: 401,
            title: "Authentication required",
            detail: "Pair this browser with PhonoFlow to continue.",
            instance: path,
            code: "authentication_required"
        )
    }

    private func credentialUnavailable(_ path: String) -> RemoteAPIProblem {
        RemoteRequestSecurity.problem(
            status: 503,
            title: "Browser session storage unavailable",
            detail:
                "PhonoFlow could not persist the browser session change. Try again without discarding the current session.",
            instance: path,
            code: "credential_persistence_failed"
        )
    }

    private func validationProblem(_ detail: String, path: String) -> RemoteAPIProblem {
        RemoteRequestSecurity.problem(
            status: 422,
            title: "Invalid command",
            detail: detail,
            instance: path,
            code: "invalid_command"
        )
    }

    private func decode<T: Decodable>(
        _ request: RemoteHTTPRequest,
        path: String
    ) throws -> T {
        do {
            return try RemoteJSON.decoder().decode(T.self, from: request.body)
        } catch {
            throw RemoteRequestSecurity.problem(
                status: 422,
                title: "Invalid JSON",
                detail: "The JSON body does not match this endpoint.",
                instance: path,
                code: "invalid_json"
            )
        }
    }

    private func commandResponse(_ command: RemoteControlCommand) async throws -> RemoteRouteResult {
        guard let coordinator else {
            throw RemoteRequestSecurity.problem(
                status: 503,
                title: "Remote Access unavailable",
                detail: "The application coordinator is no longer available.",
                instance: "/api/v1",
                code: "coordinator_unavailable"
            )
        }
        do {
            let snapshot = try await coordinator.applyRemoteCommand(command)
            await eventHub.publish(snapshot: snapshot)
            return .response(try jsonResponse(snapshot))
        } catch let failure as RemoteControlFailure {
            let status: Int
            let title: String
            switch failure.kind {
            case .conflict:
                status = 409
                title = "Command conflicts with current state"
            case .invalid:
                status = 422
                title = "Invalid command"
            case .unavailable:
                status = 503
                title = "Audio engine unavailable"
            case .forbidden:
                status = 403
                title = "Command forbidden"
            }
            throw RemoteRequestSecurity.problem(
                status: status,
                title: title,
                detail: failure.detail,
                instance: "/api/v1",
                code: failure.code
            )
        }
    }

    private func stateSnapshot(path: String) async throws -> RemoteStateSnapshot {
        guard let coordinator else {
            throw RemoteRequestSecurity.problem(
                status: 503,
                title: "Remote Access unavailable",
                detail: "The application coordinator is no longer available.",
                instance: path,
                code: "coordinator_unavailable"
            )
        }
        return await coordinator.remoteStateSnapshot()
    }

    private func jsonResponse<T: Encodable>(
        _ value: T,
        status: Int = 200,
        headers: [String: String] = [:]
    ) throws -> RemoteHTTPResponse {
        var responseHeaders = headers
        responseHeaders["Content-Type"] = "application/json; charset=utf-8"
        return RemoteHTTPResponse(
            status: status,
            headers: RemoteHTTPHeaders.applyingSecurityHeaders(to: responseHeaders, noStore: true),
            body: try RemoteJSON.encoder().encode(value)
        )
    }

    private func problemResponse(
        _ problem: RemoteAPIProblem,
        extraHeaders: [String: String] = [:]
    ) -> RemoteHTTPResponse {
        var headers = extraHeaders
        headers["Content-Type"] = "application/problem+json; charset=utf-8"
        if problem.status == 401 {
            headers["WWW-Authenticate"] = "PhonoFlowSession"
        }
        return RemoteHTTPResponse(
            status: problem.status,
            headers: RemoteHTTPHeaders.applyingSecurityHeaders(to: headers, noStore: true),
            body: (try? RemoteJSON.encoder().encode(problem)) ?? Data()
        )
    }
}
