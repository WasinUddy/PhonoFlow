//
//  RemoteBonjour.swift
//  PhonoFlow
//

import Foundation

nonisolated public protocol RemoteBonjourAdvertising: AnyObject, Sendable {
    func start(serviceName: String, serviceType: String, port: UInt16, txt: [String: String]) async throws
    func stop() async
}

/// Main-actor ownership keeps `NetService` lifecycle deterministic for a
/// menu-bar application. The service advertises presence only; HTTP still
/// binds and authenticates independently.
public actor FoundationRemoteBonjourAdvertiser: nonisolated RemoteBonjourAdvertising {
    private var service: NetService?

    public init() {}

    public func start(
        serviceName: String,
        serviceType: String = "_phonoflow._tcp.",
        port: UInt16,
        txt: [String: String]
    ) async throws {
        await stop()
        let service = NetService(
            domain: "local.",
            type: serviceType.hasSuffix(".") ? serviceType : serviceType + ".",
            name: serviceName,
            port: Int32(port)
        )
        let txtData = Dictionary(
            uniqueKeysWithValues: txt.map { key, value in
                (key, Data(value.utf8))
            })
        service.setTXTRecord(NetService.data(fromTXTRecord: txtData))
        service.publish(options: [.listenForConnections])
        self.service = service
    }

    public func stop() async {
        service?.stop()
        service = nil
    }
}

public actor DisabledRemoteBonjourAdvertiser: nonisolated RemoteBonjourAdvertising {
    public init() {}

    public func start(
        serviceName _: String,
        serviceType _: String,
        port _: UInt16,
        txt _: [String: String]
    ) async throws {}

    public func stop() async {}
}
