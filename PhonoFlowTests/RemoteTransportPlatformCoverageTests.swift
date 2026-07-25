import Darwin
import Dispatch
import Foundation
import NIOCore
import XCTest

@testable import PhonoFlow

@MainActor
final class RemoteTransportPlatformCoverageTests: XCTestCase {
    func testTransportConvertsRequestsAndRegistersEverySupportedMethod() async throws {
        try await withStoppedTransport { transport in
            let requests = TransportRequestLog()
            let endpoint = try await transport.start(
                configuration: configuration(maximumBodyBytes: 1_024)
            ) { request in
                await requests.append(request)
                let isConversionRequest = request.target == "/convert?mode=binary"
                let body = Data((isConversionRequest ? "converted" : "accepted").utf8)
                return .response(
                    RemoteHTTPResponse(
                        status: isConversionRequest ? 207 : 200,
                        headers: [
                            "Bad Header": "must-be-dropped",
                            "Content-Length": String(body.count),
                            "Content-Type": "application/octet-stream",
                            "X-Transport-Test": "bridged",
                        ],
                        body: body
                    )
                )
            }

            do {
                _ = try await transport.start(
                    configuration: configuration(),
                    handler: { _ in .response(RemoteHTTPResponse(status: 500)) }
                )
                XCTFail("Starting an active transport must fail.")
            } catch is HummingbirdTransportAlreadyRunning {
                // Expected.
            }

            for method in RemoteHTTPMethod.allCases {
                let response = try await CoverageLoopbackHTTPClient.request(
                    endpoint: endpoint,
                    method: method.rawValue,
                    target: "/methods/\(method.rawValue.lowercased())"
                )
                XCTAssertEqual(response.status, 200, method.rawValue)
            }

            let binaryBody = Data([0x00, 0x01, 0x7F, 0x80, 0xFE, 0xFF])
            let conversionResponse = try await CoverageLoopbackHTTPClient.request(
                endpoint: endpoint,
                method: "POST",
                target: "/convert?mode=binary",
                headerLines: [
                    ("X-Repeated", "first"),
                    ("X-Repeated", "second"),
                    ("X-Mixed-Case", "Preserved value"),
                ],
                body: binaryBody
            )

            XCTAssertEqual(conversionResponse.status, 207)
            XCTAssertEqual(conversionResponse.body, Data("converted".utf8))
            XCTAssertEqual(conversionResponse.headers["x-transport-test"], "bridged")
            XCTAssertNil(conversionResponse.headers["bad header"])

            let lastRequest = await requests.last
            let captured = try XCTUnwrap(lastRequest)
            XCTAssertEqual(captured.method, .post)
            XCTAssertEqual(captured.target, "/convert?mode=binary")
            XCTAssertEqual(captured.body, binaryBody)
            XCTAssertEqual(captured.remoteAddress, "127.0.0.1")
            XCTAssertEqual(captured.headers["x-mixed-case"], "Preserved value")
            XCTAssertNotNil(captured.headers["host"])
            XCTAssertEqual(
                captured.headers["x-repeated"]?
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) },
                ["first", "second"]
            )

            let receivedMethods = await requests.methods
            XCTAssertEqual(
                Array(receivedMethods.prefix(RemoteHTTPMethod.allCases.count)),
                RemoteHTTPMethod.allCases
            )

            await transport.stop()
            await transport.stop()
        }
    }

    func testOversizedBodyReturnsSecuredProblemWithoutCallingHandler() async throws {
        try await withStoppedTransport { transport in
            let requests = TransportRequestLog()
            let endpoint = try await transport.start(
                configuration: configuration(maximumBodyBytes: 8)
            ) { request in
                await requests.append(request)
                return .response(RemoteHTTPResponse(status: 204))
            }

            let response = try await CoverageLoopbackHTTPClient.request(
                endpoint: endpoint,
                method: "POST",
                target: "/too-large?source=test",
                body: Data(repeating: 0x41, count: 9)
            )

            XCTAssertEqual(response.status, 413)
            XCTAssertEqual(
                response.headers["content-type"],
                "application/problem+json; charset=utf-8"
            )
            XCTAssertEqual(response.headers["cache-control"], "no-store")
            XCTAssertEqual(response.headers["x-content-type-options"], "nosniff")
            let problem = try RemoteJSON.decoder().decode(RemoteAPIProblem.self, from: response.body)
            XCTAssertEqual(problem.status, 413)
            XCTAssertEqual(problem.code, "body_too_large")
            XCTAssertEqual(problem.instance, "/too-large?source=test")
            let requestCount = await requests.count
            XCTAssertEqual(requestCount, 0)
        }
    }

    func testFiniteEventAndAudioResponsesExposeWireHeadersAndWAVFormats() async throws {
        let eventHub = RemoteEventHub(clock: TestRemoteClock(.testReference))
        let eventSubscription = try await eventHub.subscribe(
            principal: RemoteSessionPrincipal(
                sessionID: "transport-events",
                expiresAt: .testReference.addingTimeInterval(60)
            ),
            snapshot: .fixture()
        )
        addTeardownBlock {
            await eventSubscription.cancel()
        }
        await eventSubscription.cancel()

        let audio = RemoteAudioFanout(
            legacySampleRate: 96_000,
            clock: TestRemoteClock(.testReference)
        )
        let browserSubscription = try await audio.subscribe(
            kind: .pcm16Browser,
            principal: nil,
            remoteAddress: "browser"
        )
        addTeardownBlock {
            await browserSubscription.cancel()
        }
        let legacySubscription = try await audio.subscribe(
            kind: .legacyFloat32,
            principal: nil,
            remoteAddress: "player"
        )
        addTeardownBlock {
            await legacySubscription.cancel()
        }
        await browserSubscription.cancel()
        await legacySubscription.cancel()

        try await withStoppedTransport { transport in
            let endpoint = try await transport.start(configuration: configuration()) { request in
                switch request.target {
                case "/events":
                    return .events(eventSubscription)
                case "/audio":
                    return .pcm16Audio(browserSubscription)
                case "/legacy":
                    return .legacyFloat32Audio(legacySubscription)
                default:
                    return .response(RemoteHTTPResponse(status: 404))
                }
            }

            let event = try await CoverageURLSessionClient.request(endpoint: endpoint, path: "/events")
            XCTAssertEqual(event.status, 200)
            XCTAssertEqual(event.headers["content-type"], "text/event-stream; charset=utf-8")
            XCTAssertEqual(event.headers["cache-control"], "no-store")
            XCTAssertEqual(event.headers["x-accel-buffering"], "no")
            XCTAssertEqual(event.body, Data("retry: 2000\n\n".utf8))

            let browser = try await CoverageURLSessionClient.request(
                endpoint: endpoint,
                path: "/audio"
            )
            XCTAssertEqual(browser.status, 200)
            XCTAssertEqual(browser.headers["content-type"], "audio/wav")
            XCTAssertEqual(browser.headers["accept-ranges"], "none")
            XCTAssertNil(browser.headers["icy-name"])
            XCTAssertEqual(browser.body.count, 44)
            XCTAssertEqual(littleEndianUInt16(browser.body, at: 20), 1)
            XCTAssertEqual(littleEndianUInt32(browser.body, at: 24), 48_000)

            let legacy = try await CoverageURLSessionClient.request(
                endpoint: endpoint,
                path: "/legacy"
            )
            XCTAssertEqual(legacy.status, 200)
            XCTAssertEqual(legacy.headers["content-type"], "audio/wav")
            XCTAssertEqual(legacy.headers["icy-name"], "PhonoFlow Radio")
            XCTAssertEqual(legacy.body.count, 44)
            XCTAssertEqual(littleEndianUInt16(legacy.body, at: 20), 3)
            XCTAssertEqual(littleEndianUInt32(legacy.body, at: 24), 96_000)
        }
    }

    func testBindFailureCanBeStoppedAndRetried() async throws {
        let reservation = try LoopbackPortReservation()
        addTeardownBlock {
            reservation.close()
        }
        try await withStoppedTransport { transport in
            do {
                _ = try await transport.start(
                    configuration: configuration(port: reservation.port),
                    handler: { _ in .response(RemoteHTTPResponse(status: 204)) }
                )
                XCTFail("Binding to an occupied loopback port must fail.")
            } catch is HummingbirdTransportAlreadyRunning {
                XCTFail("The initial bind failure must be reported, not mistaken for an active server.")
            } catch let error as IOError {
                XCTAssertEqual(
                    error.errnoCode,
                    EADDRINUSE,
                    "An occupied loopback port must fail specifically with EADDRINUSE."
                )
            } catch {
                XCTFail("Expected NIO EADDRINUSE, got \(type(of: error)): \(error)")
            }

            await transport.stop()
            let endpoint = try await transport.start(
                configuration: configuration(),
                handler: { _ in .response(RemoteHTTPResponse(status: 204)) }
            )
            XCTAssertNotEqual(endpoint.port, 0)
        }
    }

    func testStoppedTransportRefusesRequestsAndCanRestart() async throws {
        try await withStoppedTransport { transport in
            let handler: @Sendable (RemoteHTTPRequest) async -> RemoteRouteResult = { _ in
                let body = Data("running".utf8)
                return .response(
                    RemoteHTTPResponse(
                        status: 200,
                        headers: ["Content-Length": String(body.count)],
                        body: body
                    ))
            }
            let firstEndpoint = try await transport.start(
                configuration: configuration(),
                handler: handler
            )
            let firstResponse = try await CoverageLoopbackHTTPClient.request(
                endpoint: firstEndpoint,
                method: "GET",
                target: "/lifecycle"
            )
            XCTAssertEqual(firstResponse.status, 200)
            XCTAssertEqual(firstResponse.body, Data("running".utf8))

            await transport.stop()
            do {
                _ = try await CoverageLoopbackHTTPClient.request(
                    endpoint: firstEndpoint,
                    method: "GET",
                    target: "/after-stop"
                )
                XCTFail("A stopped transport must refuse new requests.")
            } catch let error as CoverageLoopbackHTTPError {
                switch error {
                case .connect, .connectTimeout:
                    break
                default:
                    XCTFail("Expected a bounded connection failure, got \(error).")
                }
            } catch {
                XCTFail("Expected a loopback transport error, got \(error).")
            }

            await transport.stop()
            let restartedEndpoint = try await transport.start(
                configuration: configuration(),
                handler: handler
            )
            let restartedResponse = try await CoverageLoopbackHTTPClient.request(
                endpoint: restartedEndpoint,
                method: "GET",
                target: "/after-restart"
            )
            XCTAssertEqual(restartedResponse.status, 200)
            XCTAssertEqual(restartedResponse.body, Data("running".utf8))
        }
    }

    private func configuration(
        port: UInt16 = 0,
        maximumBodyBytes: Int = 16 * 1_024
    ) -> RemoteTransportConfiguration {
        RemoteTransportConfiguration(
            bindHost: "127.0.0.1",
            port: port,
            maximumBodyBytes: maximumBodyBytes
        )
    }

    private func withStoppedTransport(
        _ operation: (HummingbirdRemoteHTTPTransport) async throws -> Void
    ) async throws {
        let transport = HummingbirdRemoteHTTPTransport()
        addTeardownBlock {
            await transport.stop()
        }
        do {
            try await operation(transport)
            await transport.stop()
        } catch {
            await transport.stop()
            throw error
        }
    }
}

private actor TransportRequestLog {
    private var requests: [RemoteHTTPRequest] = []

    var last: RemoteHTTPRequest? {
        requests.last
    }

    var methods: [RemoteHTTPMethod] {
        requests.map(\.method)
    }

    var count: Int {
        requests.count
    }

    func append(_ request: RemoteHTTPRequest) {
        requests.append(request)
    }
}

nonisolated private struct CoverageHTTPResponse: Sendable {
    var status: Int
    var headers: [String: String]
    var body: Data
}

nonisolated private enum CoverageLoopbackHTTPError: Error, Sendable {
    case socketCreation(Int32)
    case socketConfiguration(Int32)
    case invalidAddress
    case connect(Int32)
    case connectTimeout
    case send(Int32)
    case sendTimeout
    case receive(Int32)
    case receiveTimeout
    case malformedResponse
}

nonisolated private enum CoverageLoopbackHTTPClient {
    private static let operationTimeoutNanoseconds: UInt64 = 3_000_000_000
    private static let cancellationPollNanoseconds: UInt64 = 50_000_000

    static func request(
        endpoint: RemoteBoundEndpoint,
        method: String,
        target: String,
        headerLines: [(String, String)] = [],
        body: Data = Data()
    ) async throws -> CoverageHTTPResponse {
        let cancellation = CoverageSocketCancellation()
        let task = Task.detached {
            try requestBlocking(
                endpoint: endpoint,
                method: method,
                target: target,
                headerLines: headerLines,
                body: body,
                cancellation: cancellation
            )
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
            cancellation.cancel()
        }
    }

    private static func requestBlocking(
        endpoint: RemoteBoundEndpoint,
        method: String,
        target: String,
        headerLines: [(String, String)],
        body: Data,
        cancellation: CoverageSocketCancellation
    ) throws -> CoverageHTTPResponse {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw CoverageLoopbackHTTPError.socketCreation(errno)
        }
        cancellation.install(descriptor)
        defer {
            cancellation.clear(descriptor)
            Darwin.close(descriptor)
        }
        try Task.checkCancellation()

        var noSignal: Int32 = 1
        let noSignalSize = socklen_t(MemoryLayout.size(ofValue: noSignal))
        let configuredNoSignal = withUnsafePointer(to: &noSignal) {
            Darwin.setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                $0,
                noSignalSize
            )
        }
        guard configuredNoSignal == 0 else {
            throw CoverageLoopbackHTTPError.socketConfiguration(errno)
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(endpoint.port).bigEndian
        guard inet_pton(AF_INET, endpoint.host, &address.sin_addr) == 1 else {
            throw CoverageLoopbackHTTPError.invalidAddress
        }
        try connect(descriptor, to: &address)
        try Task.checkCancellation()

        var head = "\(method) \(target) HTTP/1.1\r\n"
        head += "Host: 127.0.0.1:\(endpoint.port)\r\n"
        head += "Connection: close\r\n"
        head += "Content-Length: \(body.count)\r\n"
        for (name, value) in headerLines {
            head += "\(name): \(value)\r\n"
        }
        head += "\r\n"
        var payload = Data(head.utf8)
        payload.append(body)
        try sendAll(payload, to: descriptor)

        let raw = try receiveResponse(from: descriptor, requestMethod: method)
        try Task.checkCancellation()
        return try parse(raw, requestMethod: method)
    }

    private static func connect(
        _ descriptor: Int32,
        to address: inout sockaddr_in
    ) throws {
        let flags = Darwin.fcntl(descriptor, F_GETFL)
        guard flags >= 0, Darwin.fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw CoverageLoopbackHTTPError.socketConfiguration(errno)
        }

        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }
        if connected != 0 {
            guard errno == EINPROGRESS else {
                throw CoverageLoopbackHTTPError.connect(errno)
            }
            try waitForReadiness(
                descriptor,
                events: Int16(POLLOUT),
                deadline: operationDeadline(),
                timeoutError: .connectTimeout,
                operationError: CoverageLoopbackHTTPError.connect
            )

            var socketError: Int32 = 0
            var socketErrorSize = socklen_t(MemoryLayout.size(ofValue: socketError))
            let readError = withUnsafeMutablePointer(to: &socketError) {
                Darwin.getsockopt(
                    descriptor,
                    SOL_SOCKET,
                    SO_ERROR,
                    $0,
                    &socketErrorSize
                )
            }
            guard readError == 0 else {
                throw CoverageLoopbackHTTPError.socketConfiguration(errno)
            }
            guard socketError == 0 else {
                throw CoverageLoopbackHTTPError.connect(socketError)
            }
        }
    }

    private static func sendAll(_ data: Data, to descriptor: Int32) throws {
        let deadline = operationDeadline()
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var sent = 0
            while sent < bytes.count {
                try Task.checkCancellation()
                let amount = Darwin.send(
                    descriptor,
                    baseAddress.advanced(by: sent),
                    bytes.count - sent,
                    0
                )
                if amount > 0 {
                    sent += amount
                    continue
                }
                if amount == 0 {
                    throw CoverageLoopbackHTTPError.send(EPIPE)
                }

                let sendError = errno
                if sendError == EINTR {
                    continue
                }
                if sendError == EAGAIN || sendError == EWOULDBLOCK {
                    try waitForReadiness(
                        descriptor,
                        events: Int16(POLLOUT),
                        deadline: deadline,
                        timeoutError: .sendTimeout,
                        operationError: CoverageLoopbackHTTPError.send
                    )
                    continue
                }
                throw CoverageLoopbackHTTPError.send(sendError)
            }
        }
    }

    private static func receiveResponse(
        from descriptor: Int32,
        requestMethod: String
    ) throws -> Data {
        let deadline = operationDeadline()
        var raw = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            try Task.checkCancellation()
            let received = buffer.withUnsafeMutableBytes {
                Darwin.recv(descriptor, $0.baseAddress, $0.count, 0)
            }
            if received > 0 {
                raw.append(contentsOf: buffer.prefix(received))
                if responseIsComplete(raw, requestMethod: requestMethod) {
                    return raw
                }
                continue
            }
            if received == 0 {
                return raw
            }

            let receiveError = errno
            if receiveError == EINTR {
                continue
            }
            if receiveError == EAGAIN || receiveError == EWOULDBLOCK {
                try waitForReadiness(
                    descriptor,
                    events: Int16(POLLIN),
                    deadline: deadline,
                    timeoutError: .receiveTimeout,
                    operationError: CoverageLoopbackHTTPError.receive
                )
                continue
            }
            throw CoverageLoopbackHTTPError.receive(receiveError)
        }
    }

    private static func operationDeadline() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds &+ operationTimeoutNanoseconds
    }

    private static func waitForReadiness(
        _ descriptor: Int32,
        events: Int16,
        deadline: UInt64,
        timeoutError: CoverageLoopbackHTTPError,
        operationError: (Int32) -> CoverageLoopbackHTTPError
    ) throws {
        while true {
            try Task.checkCancellation()
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else {
                throw timeoutError
            }

            let pollNanoseconds = min(
                deadline - now,
                cancellationPollNanoseconds
            )
            let pollMilliseconds = Int32(
                max(1, (pollNanoseconds + 999_999) / 1_000_000)
            )
            var descriptorStatus = pollfd(
                fd: descriptor,
                events: events,
                revents: 0
            )
            let pollResult = Darwin.poll(&descriptorStatus, 1, pollMilliseconds)
            if pollResult > 0 {
                try Task.checkCancellation()
                return
            }
            if pollResult == 0 {
                continue
            }

            let pollError = errno
            if pollError == EINTR {
                continue
            }
            throw operationError(pollError)
        }
    }

    private static func responseIsComplete(_ raw: Data, requestMethod: String) -> Bool {
        guard let boundary = raw.range(of: Data("\r\n\r\n".utf8)) else {
            return false
        }
        if requestMethod == "HEAD" {
            return true
        }
        let head = String(decoding: raw[..<boundary.lowerBound], as: UTF8.self)
        let parsed = parseHead(head)
        guard let contentLength = parsed.headers["content-length"].flatMap(Int.init) else {
            return false
        }
        return raw[boundary.upperBound...].count >= contentLength
    }

    private static func parse(
        _ raw: Data,
        requestMethod: String
    ) throws -> CoverageHTTPResponse {
        guard let boundary = raw.range(of: Data("\r\n\r\n".utf8)) else {
            throw CoverageLoopbackHTTPError.malformedResponse
        }
        let parsed = parseHead(String(decoding: raw[..<boundary.lowerBound], as: UTF8.self))
        guard let status = parsed.status else {
            throw CoverageLoopbackHTTPError.malformedResponse
        }
        let body =
            requestMethod == "HEAD"
            ? Data()
            : Data(raw[boundary.upperBound...])
        return CoverageHTTPResponse(status: status, headers: parsed.headers, body: body)
    }

    private static func parseHead(
        _ head: String
    ) -> (status: Int?, headers: [String: String]) {
        let lines = head.components(separatedBy: "\r\n")
        let status = lines.first?
            .split(separator: " ")
            .dropFirst()
            .first
            .flatMap { Int($0) }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let name = line[..<separator].lowercased()
            let value = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        return (status, headers)
    }
}

nonisolated private final class CoverageSocketCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32?
    private var isCancelled = false

    func install(_ descriptor: Int32) {
        lock.lock()
        self.descriptor = descriptor
        if isCancelled {
            Darwin.shutdown(descriptor, SHUT_RDWR)
        }
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        if let descriptor {
            Darwin.shutdown(descriptor, SHUT_RDWR)
        }
        lock.unlock()
    }

    func clear(_ descriptor: Int32) {
        lock.lock()
        if self.descriptor == descriptor {
            self.descriptor = nil
        }
        lock.unlock()
    }
}

nonisolated private enum CoverageURLSessionClient {
    static func request(
        endpoint: RemoteBoundEndpoint,
        path: String
    ) async throws -> CoverageHTTPResponse {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 3
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(
            url: URL(string: "http://\(endpoint.host):\(endpoint.port)\(path)")!
        )
        request.setValue("close", forHTTPHeaderField: "Connection")
        let (body, response) = try await session.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            headers[String(describing: key).lowercased()] = String(describing: value)
        }
        return CoverageHTTPResponse(status: http.statusCode, headers: headers, body: body)
    }
}

nonisolated private final class LoopbackPortReservation: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32?
    let port: UInt16

    init() throws {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw CoverageLoopbackHTTPError.socketCreation(errno)
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }
        guard bound == 0, Darwin.listen(descriptor, 1) == 0 else {
            Darwin.close(descriptor)
            throw CoverageLoopbackHTTPError.connect(errno)
        }

        var resolved = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let readAddress = withUnsafeMutablePointer(to: &resolved) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(descriptor, $0, &length)
            }
        }
        guard readAddress == 0 else {
            Darwin.close(descriptor)
            throw CoverageLoopbackHTTPError.invalidAddress
        }

        self.descriptor = descriptor
        port = UInt16(bigEndian: resolved.sin_port)
    }

    deinit {
        close()
    }

    func close() {
        lock.lock()
        guard let descriptor else {
            lock.unlock()
            return
        }
        self.descriptor = nil
        lock.unlock()
        Darwin.close(descriptor)
    }
}
