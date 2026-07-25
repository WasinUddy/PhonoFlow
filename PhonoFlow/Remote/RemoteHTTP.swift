//
//  RemoteHTTP.swift
//  PhonoFlow
//
//  A small transport-neutral HTTP surface. Hummingbird is an edge adapter;
//  routing, authorization, and response semantics remain unit-testable here.
//

import Foundation

nonisolated public enum RemoteHTTPMethod: String, Codable, Sendable, CaseIterable {
    case get = "GET"
    case head = "HEAD"
    case post = "POST"
    case put = "PUT"
    case patch = "PATCH"
    case delete = "DELETE"
    case options = "OPTIONS"
    case connect = "CONNECT"
    case trace = "TRACE"

    public var isMutation: Bool {
        switch self {
        case .post, .put, .patch, .delete:
            return true
        case .get, .head, .options, .connect, .trace:
            return false
        }
    }
}

nonisolated public struct RemoteHTTPRequest: Sendable {
    public var method: RemoteHTTPMethod
    /// Raw origin-form request target, including an optional query.
    public var target: String
    /// Lowercase header names. Repeated header fields must be comma-joined by the adapter.
    public var headers: [String: String]
    public var body: Data
    /// Direct socket peer address. Never sourced from X-Forwarded-For.
    public var remoteAddress: String

    public init(
        method: RemoteHTTPMethod,
        target: String,
        headers: [String: String],
        body: Data = Data(),
        remoteAddress: String
    ) {
        self.method = method
        self.target = target
        self.headers = Dictionary(
            headers.map { ($0.key.lowercased(), $0.value) },
            uniquingKeysWith: { first, second in first + "," + second }
        )
        self.body = body
        self.remoteAddress = remoteAddress
    }

    public subscript(header name: String) -> String? {
        headers[name.lowercased()]
    }
}

nonisolated public struct RemoteHTTPResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}

nonisolated public struct RemoteAPIProblem: Codable, Error, Sendable, Equatable {
    public var type: String
    public var title: String
    public var status: Int
    public var detail: String
    public var instance: String
    public var code: String

    public init(
        type: String = "about:blank",
        title: String,
        status: Int,
        detail: String,
        instance: String,
        code: String
    ) {
        self.type = type
        self.title = title
        self.status = status
        self.detail = detail
        self.instance = instance
        self.code = code
    }
}

nonisolated public enum RemoteRouteResult: Sendable {
    case response(RemoteHTTPResponse)
    case events(RemoteEventSubscription)
    case pcm16Audio(RemoteAudioSubscription)
    case legacyFloat32Audio(RemoteAudioSubscription)
}

nonisolated public struct RemoteAccessConfiguration: Sendable, Equatable {
    public var bindHost: String
    public var port: UInt16
    public var serviceName: String
    /// Exact non-IP authorities accepted in addition to localhost and serviceName.local.
    public var allowedHosts: Set<String>
    /// Exact client IP addresses or CIDR ranges allowed to use an explicitly
    /// unauthenticated legacy `/stream`. This is intentionally separate from
    /// HTTP Host-authority validation.
    public var legacyAllowedSources: Set<String>
    /// Browser PCM and SSE sessions are always authenticated. This opt-in only
    /// preserves the historical unauthenticated VLC/mpv `/stream` endpoint.
    public var allowUnauthenticatedLegacyStream: Bool
    public var maxJSONBodyBytes: Int
    public var maxPairBodyBytes: Int
    public var maxEventClients: Int
    public var maxAudioClients: Int
    public var maxAudioClientsPerAddress: Int
    public var generalRequestsPerMinute: Int
    public var advertiseBonjour: Bool

    public init(
        bindHost: String = "0.0.0.0",
        port: UInt16 = 7866,
        serviceName: String = "PhonoFlow",
        allowedHosts: Set<String> = [],
        legacyAllowedSources: Set<String> = [],
        allowUnauthenticatedLegacyStream: Bool = false,
        maxJSONBodyBytes: Int = 16 * 1_024,
        maxPairBodyBytes: Int = 1_024,
        maxEventClients: Int = 8,
        maxAudioClients: Int = 8,
        maxAudioClientsPerAddress: Int = 2,
        generalRequestsPerMinute: Int = 240,
        advertiseBonjour: Bool = true
    ) {
        self.bindHost = bindHost
        self.port = port
        self.serviceName = serviceName
        self.allowedHosts = allowedHosts
        self.legacyAllowedSources = legacyAllowedSources
        self.allowUnauthenticatedLegacyStream = allowUnauthenticatedLegacyStream
        self.maxJSONBodyBytes = max(1_024, maxJSONBodyBytes)
        self.maxPairBodyBytes = max(256, min(maxPairBodyBytes, self.maxJSONBodyBytes))
        self.maxEventClients = max(1, maxEventClients)
        self.maxAudioClients = max(1, maxAudioClients)
        self.maxAudioClientsPerAddress = max(1, maxAudioClientsPerAddress)
        self.generalRequestsPerMinute = max(10, generalRequestsPerMinute)
        self.advertiseBonjour = advertiseBonjour
    }
}

nonisolated public enum RemoteServerLifecycleState: Sendable, Equatable {
    case disabled
    case starting
    case running(host: String, port: UInt16)
    case failed(String)
    case stopping
}

nonisolated public struct RemoteTransportConfiguration: Sendable, Equatable {
    public var bindHost: String
    public var port: UInt16
    public var maximumBodyBytes: Int

    public init(bindHost: String, port: UInt16, maximumBodyBytes: Int) {
        self.bindHost = bindHost
        self.port = port
        self.maximumBodyBytes = maximumBodyBytes
    }
}

nonisolated public struct RemoteBoundEndpoint: Codable, Sendable, Equatable {
    public var host: String
    public var port: UInt16

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }
}

nonisolated public protocol RemoteHTTPTransport: Sendable {
    func start(
        configuration: RemoteTransportConfiguration,
        handler: @escaping @Sendable (RemoteHTTPRequest) async -> RemoteRouteResult
    ) async throws -> RemoteBoundEndpoint
    func stop() async
}

nonisolated public struct RemoteTransportUnavailable: Error, Sendable, LocalizedError {
    public var errorDescription: String? {
        "Hummingbird 2.x is not linked. Add the Hummingbird package product to enable Remote Access."
    }

    public init() {}
}

public actor UnavailableRemoteHTTPTransport: nonisolated RemoteHTTPTransport {
    public init() {}

    public func start(
        configuration _: RemoteTransportConfiguration,
        handler _: @escaping @Sendable (RemoteHTTPRequest) async -> RemoteRouteResult
    ) async throws -> RemoteBoundEndpoint {
        throw RemoteTransportUnavailable()
    }

    public func stop() async {}
}

nonisolated public enum RemoteHTTPHeaders {
    public static let contentSecurityPolicy =
        "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; "
        + "connect-src 'self'; media-src 'self'; object-src 'none'; base-uri 'none'; "
        + "frame-ancestors 'none'; form-action 'self'"

    public static let security: [String: String] = [
        "Content-Security-Policy": contentSecurityPolicy,
        "X-Content-Type-Options": "nosniff",
        "Referrer-Policy": "no-referrer",
        "Permissions-Policy": "camera=(), microphone=(), geolocation=()",
        "Cross-Origin-Resource-Policy": "same-origin",
        "X-Frame-Options": "DENY",
    ]

    public static func applyingSecurityHeaders(
        to headers: [String: String],
        noStore: Bool = false
    ) -> [String: String] {
        var result = security
        for (key, value) in headers {
            result[key] = value
        }
        if noStore {
            result["Cache-Control"] = "no-store"
        }
        // Deliberately never emit any Access-Control-Allow-* header.
        return result
    }
}

nonisolated public enum RemoteJSON {
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
