//
//  RemoteRequestSecurity.swift
//  PhonoFlow
//

import Foundation
import Network

nonisolated public struct RemoteNormalizedTarget: Sendable, Equatable {
    public var path: String
    public var query: String?

    public init(path: String, query: String?) {
        self.path = path
        self.query = query
    }
}

nonisolated public struct RemoteAuthority: Sendable, Equatable {
    public var host: String
    public var port: UInt16

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }
}

nonisolated public enum RemoteRequestSecurity {
    public static let mutationHeaderName = "x-phonoflow-mutation"

    public static func normalizeTarget(_ target: String) throws -> RemoteNormalizedTarget {
        guard target.hasPrefix("/"),
            !target.hasPrefix("//"),
            !target.contains("#"),
            !target.contains("\\"),
            !target.lowercased().contains("%2f"),
            !target.lowercased().contains("%5c")
        else {
            throw problem(
                status: 400,
                title: "Invalid request target",
                detail: "The request target is not a canonical origin-form path.",
                instance: "/",
                code: "invalid_request_target"
            )
        }

        let parts = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let path = String(parts[0])
        let query = parts.count == 2 ? String(parts[1]) : nil
        guard path == "/" || (!path.hasSuffix("/") && !path.contains("//")) else {
            throw problem(
                status: 404,
                title: "Not found",
                detail: "No route matches this canonical path.",
                instance: path,
                code: "route_not_found"
            )
        }

        let decoded = path.removingPercentEncoding ?? ""
        let decodedSegments = decoded.split(separator: "/", omittingEmptySubsequences: false)
        guard !decoded.isEmpty,
            !decodedSegments.contains("."),
            !decodedSegments.contains(".."),
            decoded == path
        else {
            // The API intentionally accepts no percent-encoded route aliases.
            throw problem(
                status: 404,
                title: "Not found",
                detail: "No route matches this encoded path.",
                instance: path,
                code: "route_not_found"
            )
        }
        return RemoteNormalizedTarget(path: path, query: query)
    }

    public static func validateAuthority(
        hostHeader: String?,
        remoteAddress: String,
        configuration: RemoteAccessConfiguration,
        boundPort: UInt16
    ) throws -> RemoteAuthority {
        guard let hostHeader,
            !hostHeader.contains(","),
            let authority = parseAuthority(hostHeader),
            authority.port == boundPort
        else {
            throw problem(
                status: 421,
                title: "Misdirected request",
                detail: "The Host header does not identify this PhonoFlow listener.",
                instance: "/",
                code: "invalid_host"
            )
        }

        let allowedNames = Set(
            configuration.allowedHosts.map(canonicalHostname)
                + [
                    "localhost",
                    "127.0.0.1",
                    "::1",
                ]
        )
        if allowedNames.contains(authority.host) {
            if isLoopback(authority.host), !isLoopback(remoteAddress) {
                throw problem(
                    status: 421,
                    title: "Misdirected request",
                    detail: "The localhost authority is only valid for a loopback peer.",
                    instance: "/",
                    code: "invalid_host"
                )
            }
            return authority
        }
        throw problem(
            status: 421,
            title: "Misdirected request",
            detail: "Remote Access only accepts current local-interface or advertised authorities.",
            instance: "/",
            code: "invalid_host"
        )
    }

    public static func validateMutation(
        request: RemoteHTTPRequest,
        authority: RemoteAuthority
    ) throws {
        guard request[header: mutationHeaderName] == "1" else {
            throw problem(
                status: 403,
                title: "Request rejected",
                detail: "The required PhonoFlow mutation header is missing.",
                instance: request.target,
                code: "mutation_header_required"
            )
        }

        guard let origin = request[header: "origin"],
            !origin.contains(","),
            let components = URLComponents(string: origin),
            components.scheme?.lowercased() == "http",
            let originHost = components.host.map(canonicalHostname),
            originHost == authority.host,
            UInt16(components.port ?? 80) == authority.port,
            components.user == nil,
            components.password == nil,
            components.path.isEmpty || components.path == "/",
            components.query == nil,
            components.fragment == nil
        else {
            throw problem(
                status: 403,
                title: "Origin rejected",
                detail: "Mutations require an exact same-origin HTTP request.",
                instance: request.target,
                code: "invalid_origin"
            )
        }

        let contentType = request[header: "content-type"]?
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard contentType == "application/json" else {
            throw problem(
                status: 415,
                title: "Unsupported media type",
                detail: "Mutations require application/json.",
                instance: request.target,
                code: "json_required"
            )
        }
    }

    /// Enforces the optional peer-IP/CIDR policy for the compatibility stream.
    /// Host headers are deliberately irrelevant here: they identify the
    /// listener, not the connected client.
    public static func validateLegacySource(
        remoteAddress: String,
        allowedSources: Set<String>,
        instance: String = "/stream"
    ) throws {
        guard !allowedSources.isEmpty else { return }
        guard let peer = binaryIPAddress(remoteAddress),
            allowedSources.contains(where: {
                sourceRule($0, contains: peer)
            })
        else {
            throw problem(
                status: 403,
                title: "Legacy stream client rejected",
                detail: "This client address is not in the legacy stream allow-list.",
                instance: instance,
                code: "legacy_source_forbidden"
            )
        }
    }

    public static func problem(
        status: Int,
        title: String,
        detail: String,
        instance: String,
        code: String
    ) -> RemoteAPIProblem {
        RemoteAPIProblem(
            type: "https://phonoflow.local/problems/\(code)",
            title: title,
            status: status,
            detail: detail,
            instance: instance,
            code: code
        )
    }

    private static func parseAuthority(_ value: String) -> RemoteAuthority? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("[") {
            guard let closingBracket = trimmed.firstIndex(of: "]") else { return nil }
            let host = String(trimmed[trimmed.index(after: trimmed.startIndex)..<closingBracket])
            let suffix = trimmed[trimmed.index(after: closingBracket)...]
            guard suffix.first == ":",
                let port = UInt16(suffix.dropFirst())
            else {
                return nil
            }
            return RemoteAuthority(host: canonicalHostname(host), port: port)
        }

        guard let colon = trimmed.lastIndex(of: ":"),
            !trimmed[..<colon].contains(":"),
            let port = UInt16(trimmed[trimmed.index(after: colon)...])
        else {
            return nil
        }
        let host = canonicalHostname(String(trimmed[..<colon]))
        guard !host.isEmpty else { return nil }
        return RemoteAuthority(host: host, port: port)
    }

    private static func canonicalHostname(_ value: String) -> String {
        value
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    private static func isLoopback(_ address: String) -> Bool {
        let value = canonicalHostname(address.split(separator: "%").first.map(String.init) ?? address)
        if value == "::1" || value == "localhost" { return true }
        return ipv4Octets(value)?.first == 127
    }

    private static func ipv4Octets(_ value: String) -> [Int]? {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let octets = parts.compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else {
            return nil
        }
        return octets
    }

    private struct BinaryIPAddress {
        var bytes: [UInt8]
        var bitCount: Int { bytes.count * 8 }
    }

    private static func sourceRule(
        _ rule: String,
        contains peer: BinaryIPAddress
    ) -> Bool {
        let components = rule.split(
            separator: "/",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard let network = binaryIPAddress(String(components[0])),
            network.bitCount == peer.bitCount
        else {
            return false
        }
        let prefix: Int
        if components.count == 2 {
            guard let parsed = Int(components[1]),
                (0...network.bitCount).contains(parsed)
            else {
                return false
            }
            prefix = parsed
        } else {
            prefix = network.bitCount
        }

        let fullBytes = prefix / 8
        if fullBytes > 0,
            network.bytes[..<fullBytes] != peer.bytes[..<fullBytes]
        {
            return false
        }
        let remainingBits = prefix % 8
        guard remainingBits > 0 else { return true }
        let mask = UInt8.max << UInt8(8 - remainingBits)
        return network.bytes[fullBytes] & mask == peer.bytes[fullBytes] & mask
    }

    private static func binaryIPAddress(
        _ rawValue: String
    ) -> BinaryIPAddress? {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("["),
            let closing = value.firstIndex(of: "]")
        {
            value = String(value[value.index(after: value.startIndex)..<closing])
        } else if value.filter({ $0 == ":" }).count == 1,
            let colon = value.lastIndex(of: ":"),
            UInt16(value[value.index(after: colon)...]) != nil
        {
            value = String(value[..<colon])
        }
        if let zone = value.firstIndex(of: "%") {
            value = String(value[..<zone])
        }
        if value.lowercased().hasPrefix("::ffff:") {
            value = String(value.dropFirst("::ffff:".count))
        }

        if let address = IPv4Address(value) {
            return BinaryIPAddress(bytes: Array(address.rawValue))
        }
        if let address = IPv6Address(value) {
            return BinaryIPAddress(bytes: Array(address.rawValue))
        }
        return nil
    }
}

nonisolated public struct RemoteRateLimitResult: Sendable, Equatable {
    public var isAllowed: Bool
    public var retryAfterSeconds: Int

    public init(isAllowed: Bool, retryAfterSeconds: Int = 0) {
        self.isAllowed = isAllowed
        self.retryAfterSeconds = retryAfterSeconds
    }
}

public actor RemoteRequestRateLimiter {
    private let maximumRequests: Int
    private let interval: TimeInterval
    private let maximumBuckets: Int
    private let clock: any RemoteClock
    private var buckets: [String: [Date]] = [:]

    public init(
        maximumRequests: Int,
        interval: TimeInterval = 60,
        maximumBuckets: Int = 2_048,
        clock: any RemoteClock = SystemRemoteClock()
    ) {
        self.maximumRequests = max(1, maximumRequests)
        self.interval = max(1, interval)
        self.maximumBuckets = max(32, maximumBuckets)
        self.clock = clock
    }

    public func check(remoteAddress: String) -> RemoteRateLimitResult {
        let now = clock.now
        let key = remoteAddress.lowercased()
        var requests = buckets[key, default: []]
        requests.removeAll { now.timeIntervalSince($0) >= interval }
        guard requests.count < maximumRequests else {
            buckets[key] = requests
            let retryAfter = max(1, Int(ceil(interval - now.timeIntervalSince(requests[0]))))
            return RemoteRateLimitResult(isAllowed: false, retryAfterSeconds: retryAfter)
        }
        requests.append(now)
        buckets[key] = requests
        pruneBucketsIfNeeded()
        return RemoteRateLimitResult(isAllowed: true)
    }

    private func pruneBucketsIfNeeded() {
        guard buckets.count > maximumBuckets else { return }
        let overflow = buckets.count - maximumBuckets
        let keys =
            buckets
            .sorted { ($0.value.last ?? .distantPast) < ($1.value.last ?? .distantPast) }
            .prefix(overflow)
            .map(\.key)
        for key in keys {
            buckets[key] = nil
        }
    }
}
