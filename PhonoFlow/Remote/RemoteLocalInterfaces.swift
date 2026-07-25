//
//  RemoteLocalInterfaces.swift
//  PhonoFlow
//

import Darwin
import Foundation

nonisolated public enum RemoteLocalInterfaces {
    /// Returns numeric IPv4/IPv6 addresses currently assigned to active,
    /// non-loopback interfaces. Intended for an exact Host allow-list.
    public static func currentAddresses() -> Set<String> {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else {
            return []
        }
        defer { freeifaddrs(pointer) }

        var addresses: Set<String> = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let interface = cursor?.pointee {
            defer { cursor = interface.ifa_next }
            guard let socketAddress = interface.ifa_addr else { continue }
            let flags = Int32(interface.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            let family = Int32(socketAddress.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length: socklen_t
            if family == AF_INET {
                length = socklen_t(MemoryLayout<sockaddr_in>.size)
            } else {
                length = socklen_t(MemoryLayout<sockaddr_in6>.size)
            }
            guard
                getnameinfo(
                    socketAddress,
                    length,
                    &host,
                    socklen_t(host.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                ) == 0
            else {
                continue
            }
            let terminator = host.firstIndex(of: 0) ?? host.endIndex
            var value = String(
                decoding: host[..<terminator].map { UInt8(bitPattern: $0) },
                as: UTF8.self
            )
            if let scope = value.firstIndex(of: "%") {
                value = String(value[..<scope])
            }
            addresses.insert(value.lowercased())
        }
        return addresses
    }

    /// Host authorities that can legitimately identify this Mac right now.
    /// Bonjour advertises a service instance separately; clients use the SRV
    /// target hostname, so the machine hostname—not the instance name—belongs
    /// in the Host allow-list.
    public static func currentAuthorities() -> Set<String> {
        authorities(
            addresses: currentAddresses(),
            hostname: ProcessInfo.processInfo.hostName
        )
    }

    /// Pure authority normalization used by the system adapter and deterministic
    /// tests. Interface enumeration remains isolated in `currentAddresses()`.
    static func authorities(
        addresses: Set<String>,
        hostname: String
    ) -> Set<String> {
        var authorities = addresses
        let hostname =
            hostname
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        guard !hostname.isEmpty else { return authorities }
        authorities.insert(hostname)
        if !hostname.contains(".") {
            authorities.insert(hostname + ".local")
        }
        return authorities
    }
}
