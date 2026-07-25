import Darwin
import Foundation
import XCTest

@testable import PhonoFlow

@MainActor
final class HummingbirdRemoteServerIntegrationTests: XCTestCase {
    func testLifecycleServesAllowListedAssetsAndEnforcesExactRoutesAndMethods() async throws {
        let harness = makeHarness()

        let initialState = await harness.server.lifecycleState()
        XCTAssertEqual(initialState, .disabled)
        do {
            _ = try await harness.server.issuePairingCode()
            XCTFail("Pairing must not be available before the listener starts.")
        } catch let error as RemoteAccessServerError {
            XCTAssertEqual(error, .notRunning)
        }

        try await harness.server.start()
        let firstBoundEndpoint = await harness.server.boundEndpoint()
        let firstEndpoint = try XCTUnwrap(firstBoundEndpoint)
        XCTAssertEqual(firstEndpoint.host, "127.0.0.1")
        XCTAssertNotEqual(firstEndpoint.port, 0)
        let runningState = await harness.server.lifecycleState()
        XCTAssertEqual(
            runningState,
            .running(host: firstEndpoint.host, port: firstEndpoint.port)
        )

        do {
            try await harness.server.start()
            XCTFail("A second start must be rejected.")
        } catch let error as RemoteAccessServerError {
            XCTAssertEqual(error, .alreadyRunning)
        }
        do {
            try await harness.server.updateConfiguration(
                RemoteAccessConfiguration(
                    bindHost: "127.0.0.1",
                    port: 0,
                    advertiseBonjour: false
                )
            )
            XCTFail("Configuration must be locked while the listener is running.")
        } catch let error as RemoteAccessServerError {
            XCTAssertEqual(error, .configurationLocked)
        }

        let root = try await LoopbackHTTPClient.request(
            endpoint: firstEndpoint,
            method: "GET",
            path: "/"
        )
        XCTAssertEqual(root.status, 200)
        XCTAssertEqual(root.body, Data("<!doctype html><title>PhonoFlow</title>".utf8))
        XCTAssertEqual(root.headers["content-type"], "text/html; charset=utf-8")
        XCTAssertEqual(root.headers["x-frame-options"], "DENY")
        XCTAssertEqual(
            root.headers["content-security-policy"],
            RemoteHTTPHeaders.contentSecurityPolicy
        )
        XCTAssertFalse(
            root.headers.keys.contains { $0.hasPrefix("access-control-allow-") },
            "The trusted-LAN server must not enable CORS."
        )

        let stylesheetHead = try await LoopbackHTTPClient.request(
            endpoint: firstEndpoint,
            method: "HEAD",
            path: "/styles.css"
        )
        XCTAssertEqual(stylesheetHead.status, 200)
        XCTAssertTrue(stylesheetHead.body.isEmpty)
        XCTAssertEqual(stylesheetHead.headers["content-length"], "27")
        XCTAssertEqual(stylesheetHead.headers["content-type"], "text/css; charset=utf-8")

        let script = try await LoopbackHTTPClient.request(
            endpoint: firstEndpoint,
            method: "GET",
            path: "/src/app.js"
        )
        XCTAssertEqual(script.status, 200)
        XCTAssertEqual(script.body, Data("export const ready = true;".utf8))
        XCTAssertEqual(script.headers["content-type"], "text/javascript; charset=utf-8")

        for rejectedPath in [
            "/styles.css/",
            "/styles.css?cache=1",
            "/src/%61pp.js",
            "/not-bundled.js",
        ] {
            let rejected = try await LoopbackHTTPClient.request(
                endpoint: firstEndpoint,
                method: "GET",
                path: rejectedPath
            )
            XCTAssertEqual(rejected.status, 404, rejectedPath)
            XCTAssertEqual(try problem(from: rejected).code, "route_not_found", rejectedPath)
        }

        let wrongMethod = try await LoopbackHTTPClient.request(
            endpoint: firstEndpoint,
            method: "PATCH",
            path: "/"
        )
        XCTAssertEqual(wrongMethod.status, 405)
        XCTAssertEqual(wrongMethod.headers["allow"], "GET, HEAD")
        XCTAssertEqual(try problem(from: wrongMethod).code, "method_not_allowed")

        let invalidHost = try await LoopbackHTTPClient.request(
            endpoint: firstEndpoint,
            method: "GET",
            path: "/",
            headers: ["Host": "attacker.example:\(firstEndpoint.port)"]
        )
        XCTAssertEqual(invalidHost.status, 421)
        XCTAssertEqual(try problem(from: invalidHost).code, "invalid_host")

        await harness.server.stop()
        let stoppedState = await harness.server.lifecycleState()
        let stoppedEndpoint = await harness.server.boundEndpoint()
        XCTAssertEqual(stoppedState, .disabled)
        XCTAssertNil(stoppedEndpoint)

        try await harness.server.start()
        let restartedBoundEndpoint = await harness.server.boundEndpoint()
        let restartedEndpoint = try XCTUnwrap(restartedBoundEndpoint)
        XCTAssertNotEqual(restartedEndpoint.port, 0)
        let restartedRoot = try await LoopbackHTTPClient.request(
            endpoint: restartedEndpoint,
            method: "GET",
            path: "/"
        )
        XCTAssertEqual(restartedRoot.status, 200)
        XCTAssertEqual(restartedRoot.body, root.body)
        await harness.server.stop()
    }

    func testPairingAuthenticationAndMutationSecurityAcrossRealHTTP() async throws {
        let harness = makeHarness()
        try await harness.server.start()
        let boundEndpoint = await harness.server.boundEndpoint()
        let endpoint = try XCTUnwrap(boundEndpoint)

        let pairingCode = try await harness.server.issuePairingCode()
        XCTAssertEqual(pairingCode.code.count, 6)

        let missingMutationHeader = try await pair(
            endpoint: endpoint,
            code: pairingCode.code,
            mutationHeaders: [
                "Content-Type": "application/json",
                "Origin": origin(for: endpoint),
            ]
        )
        XCTAssertEqual(missingMutationHeader.status, 403)
        XCTAssertEqual(
            try problem(from: missingMutationHeader).code,
            "mutation_header_required"
        )

        let crossOrigin = try await pair(
            endpoint: endpoint,
            code: pairingCode.code,
            mutationHeaders: [
                "Content-Type": "application/json",
                "Origin": "http://attacker.example:\(endpoint.port)",
                "X-PhonoFlow-Mutation": "1",
            ]
        )
        XCTAssertEqual(crossOrigin.status, 403)
        XCTAssertEqual(try problem(from: crossOrigin).code, "invalid_origin")

        let invalidCode = try await pair(
            endpoint: endpoint,
            code: "000000",
            mutationHeaders: validMutationHeaders(for: endpoint)
        )
        XCTAssertEqual(invalidCode.status, 401)
        XCTAssertEqual(try problem(from: invalidCode).code, "pairing_failed")

        let paired = try await pair(
            endpoint: endpoint,
            code: pairingCode.code,
            mutationHeaders: validMutationHeaders(for: endpoint)
        )
        XCTAssertEqual(paired.status, 200)
        let setCookie = try XCTUnwrap(paired.headers["set-cookie"])
        XCTAssertTrue(setCookie.contains("HttpOnly"))
        XCTAssertTrue(setCookie.contains("SameSite=Strict"))
        XCTAssertTrue(setCookie.contains("Max-Age=2592000"))
        let cookie = String(try XCTUnwrap(setCookie.split(separator: ";").first))

        let pairResponse = try RemoteJSON.decoder().decode(
            RemotePairResponse.self,
            from: paired.body
        )
        XCTAssertEqual(pairResponse.state, .fixture())

        let unauthenticatedState = try await LoopbackHTTPClient.request(
            endpoint: endpoint,
            method: "GET",
            path: "/api/v1/state"
        )
        XCTAssertEqual(unauthenticatedState.status, 401)
        XCTAssertEqual(
            unauthenticatedState.headers["www-authenticate"],
            "PhonoFlowSession"
        )
        XCTAssertEqual(
            try problem(from: unauthenticatedState).code,
            "authentication_required"
        )

        let authenticatedState = try await LoopbackHTTPClient.request(
            endpoint: endpoint,
            method: "GET",
            path: "/api/v1/state",
            headers: ["Cookie": cookie]
        )
        XCTAssertEqual(authenticatedState.status, 200)
        XCTAssertEqual(authenticatedState.headers["cache-control"], "no-store")
        XCTAssertFalse(
            authenticatedState.headers.keys.contains {
                $0.hasPrefix("access-control-allow-")
            }
        )
        XCTAssertEqual(
            try RemoteJSON.decoder().decode(
                RemoteStateSnapshot.self,
                from: authenticatedState.body
            ),
            .fixture()
        )

        let monitorWithoutOrigin = try await LoopbackHTTPClient.request(
            endpoint: endpoint,
            method: "PUT",
            path: "/api/v1/monitor",
            headers: [
                "Content-Type": "application/json",
                "Cookie": cookie,
                "X-PhonoFlow-Mutation": "1",
            ],
            body: try RemoteJSON.encoder().encode(RemoteBooleanCommand(enabled: true))
        )
        XCTAssertEqual(monitorWithoutOrigin.status, 403)
        XCTAssertEqual(try problem(from: monitorWithoutOrigin).code, "invalid_origin")

        let monitor = try await LoopbackHTTPClient.request(
            endpoint: endpoint,
            method: "PUT",
            path: "/api/v1/monitor",
            headers: validMutationHeaders(for: endpoint).merging(
                ["Cookie": cookie],
                uniquingKeysWith: { _, replacement in replacement }
            ),
            body: try RemoteJSON.encoder().encode(RemoteBooleanCommand(enabled: true))
        )
        XCTAssertEqual(monitor.status, 200)
        XCTAssertTrue(harness.coordinator.snapshot.monitor.enabled)
        XCTAssertEqual(
            harness.coordinator.commands,
            [
                .setMonitor(RemoteBooleanCommand(enabled: true))
            ])

        await harness.server.stop()
    }

    func testSSEIsClosedOnStopAndAuthenticatedSessionSurvivesRestart() async throws {
        let harness = makeHarness()
        try await harness.server.start()
        let boundEndpoint = await harness.server.boundEndpoint()
        let endpoint = try XCTUnwrap(boundEndpoint)
        let pairingCode = try await harness.server.issuePairingCode()
        let paired = try await pair(
            endpoint: endpoint,
            code: pairingCode.code,
            mutationHeaders: validMutationHeaders(for: endpoint)
        )
        let setCookie = try XCTUnwrap(paired.headers["set-cookie"])
        let cookie = String(try XCTUnwrap(setCookie.split(separator: ";").first))
        let codeInvalidatedByStop = try await harness.server.issuePairingCode()

        let streamTask = Task {
            try await LoopbackHTTPClient.request(
                endpoint: endpoint,
                method: "GET",
                path: "/api/v1/events",
                headers: ["Cookie": cookie],
                receiveTimeout: 8
            )
        }
        try await waitUntil(timeout: .seconds(3)) {
            await harness.server.listenerCounts().eventStreams == 1
        }
        let connectedListeners = await harness.server.listenerCounts()
        XCTAssertEqual(connectedListeners.eventStreams, 1)

        let stopClock = ContinuousClock()
        let stopStarted = stopClock.now
        await harness.server.stop()
        let stopLatency = stopStarted.duration(to: stopClock.now)
        XCTAssertLessThan(
            stopLatency,
            .seconds(2),
            "Stopping Remote Access must close SSE clients before awaiting transport shutdown."
        )
        let eventResponse = try await streamTask.value
        XCTAssertEqual(eventResponse.status, 200)
        XCTAssertEqual(eventResponse.headers["content-type"], "text/event-stream; charset=utf-8")
        let eventWire = String(decoding: eventResponse.raw, as: UTF8.self)
        XCTAssertTrue(eventWire.contains("retry: 2000"))
        XCTAssertTrue(eventWire.contains("event: snapshot"))
        XCTAssertTrue(eventWire.contains("\"revision\":7"))
        let stoppedListeners = await harness.server.listenerCounts()
        let stoppedState = await harness.server.lifecycleState()
        let stoppedPairingCode = await harness.server.currentPairingCode()
        XCTAssertEqual(stoppedListeners.eventStreams, 0)
        XCTAssertEqual(stoppedState, .disabled)
        XCTAssertNil(stoppedPairingCode)

        try await harness.server.start()
        let restartedBoundEndpoint = await harness.server.boundEndpoint()
        let restartedEndpoint = try XCTUnwrap(restartedBoundEndpoint)

        let restoredSession = try await LoopbackHTTPClient.request(
            endpoint: restartedEndpoint,
            method: "GET",
            path: "/api/v1/state",
            headers: ["Cookie": cookie]
        )
        XCTAssertEqual(restoredSession.status, 200)

        let staleCode = try await pair(
            endpoint: restartedEndpoint,
            code: codeInvalidatedByStop.code,
            mutationHeaders: validMutationHeaders(for: restartedEndpoint)
        )
        XCTAssertEqual(staleCode.status, 401)
        XCTAssertEqual(try problem(from: staleCode).code, "pairing_failed")

        await harness.server.stop()
    }

    private func makeHarness() -> LiveRemoteHarness {
        let configuration = RemoteAccessConfiguration(
            bindHost: "127.0.0.1",
            port: 0,
            allowedHosts: ["localhost", "127.0.0.1"],
            generalRequestsPerMinute: 1_000,
            advertiseBonjour: false
        )
        let clock = TestRemoteClock(.testReference)
        let pairing = RemotePairingService(
            store: InMemoryRemoteCredentialStore(),
            clock: clock,
            random: CountingRemoteRandom()
        )
        let events = RemoteEventHub(maximumClients: 2, clock: clock)
        let audio = RemoteAudioFanout(
            maximumClients: 2,
            maximumClientsPerAddress: 2,
            queueCapacity: 2,
            clock: clock
        )
        let coordinator = FakeRemoteCoordinator()
        let assets = InMemoryRemoteStaticAssetProvider(assets: [
            "/": RemoteStaticAsset(
                content: Data("<!doctype html><title>PhonoFlow</title>".utf8),
                contentType: "text/html; charset=utf-8",
                cacheControl: "no-cache"
            ),
            "/styles.css": RemoteStaticAsset(
                content: Data("body { color: CanvasText; }".utf8),
                contentType: "text/css; charset=utf-8",
                cacheControl: "public, max-age=3600"
            ),
            "/src/app.js": RemoteStaticAsset(
                content: Data("export const ready = true;".utf8),
                contentType: "text/javascript; charset=utf-8",
                cacheControl: "public, max-age=3600"
            ),
        ])
        let server = RemoteAccessServer(
            configuration: configuration,
            coordinator: coordinator,
            pairing: pairing,
            eventHub: events,
            audio: audio,
            assets: assets,
            bonjour: DisabledRemoteBonjourAdvertiser(),
            transport: HummingbirdRemoteHTTPTransport()
        )
        return LiveRemoteHarness(
            server: server,
            coordinator: coordinator
        )
    }

    private func pair(
        endpoint: RemoteBoundEndpoint,
        code: String,
        mutationHeaders: [String: String]
    ) async throws -> LoopbackHTTPResponse {
        try await LoopbackHTTPClient.request(
            endpoint: endpoint,
            method: "POST",
            path: "/api/v1/auth/pair",
            headers: mutationHeaders,
            body: try RemoteJSON.encoder().encode(RemotePairRequest(code: code))
        )
    }

    private func validMutationHeaders(
        for endpoint: RemoteBoundEndpoint
    ) -> [String: String] {
        [
            "Content-Type": "application/json",
            "Origin": origin(for: endpoint),
            "X-PhonoFlow-Mutation": "1",
        ]
    }

    private func origin(for endpoint: RemoteBoundEndpoint) -> String {
        "http://127.0.0.1:\(endpoint.port)"
    }

    private func problem(from response: LoopbackHTTPResponse) throws -> RemoteAPIProblem {
        XCTAssertEqual(
            response.headers["content-type"],
            "application/problem+json; charset=utf-8"
        )
        return try RemoteJSON.decoder().decode(RemoteAPIProblem.self, from: response.body)
    }

    private func waitUntil(
        timeout: Duration,
        condition: @escaping @Sendable () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for the asynchronous server condition.")
    }
}

private struct LiveRemoteHarness {
    let server: RemoteAccessServer
    let coordinator: FakeRemoteCoordinator
}

nonisolated private struct LoopbackHTTPResponse: Sendable {
    let status: Int
    let headers: [String: String]
    let body: Data
    let raw: Data
}

nonisolated private enum LoopbackHTTPError: Error, Sendable {
    case socketCreation(Int32)
    case invalidAddress
    case connect(Int32)
    case send(Int32)
    case receive(Int32)
    case malformedResponse
    case malformedChunkedBody
}

nonisolated private enum LoopbackHTTPClient {
    static func request(
        endpoint: RemoteBoundEndpoint,
        method: String,
        path: String,
        headers: [String: String] = [:],
        body: Data = Data(),
        receiveTimeout: Int = 3
    ) async throws -> LoopbackHTTPResponse {
        try await Task.detached {
            try requestBlocking(
                endpoint: endpoint,
                method: method,
                path: path,
                headers: headers,
                body: body,
                receiveTimeout: receiveTimeout
            )
        }.value
    }

    private static func requestBlocking(
        endpoint: RemoteBoundEndpoint,
        method: String,
        path: String,
        headers: [String: String],
        body: Data,
        receiveTimeout: Int
    ) throws -> LoopbackHTTPResponse {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw LoopbackHTTPError.socketCreation(errno)
        }
        defer { Darwin.close(descriptor) }

        var noSignal: Int32 = 1
        let noSignalSize = socklen_t(MemoryLayout.size(ofValue: noSignal))
        _ = withUnsafePointer(to: &noSignal) {
            Darwin.setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                $0,
                noSignalSize
            )
        }
        var timeout = timeval(tv_sec: receiveTimeout, tv_usec: 0)
        let timeoutSize = socklen_t(MemoryLayout.size(ofValue: timeout))
        _ = withUnsafePointer(to: &timeout) {
            Darwin.setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_RCVTIMEO,
                $0,
                timeoutSize
            )
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(endpoint.port).bigEndian
        guard inet_pton(AF_INET, endpoint.host, &address.sin_addr) == 1 else {
            throw LoopbackHTTPError.invalidAddress
        }
        let connectResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }
        guard connectResult == 0 else {
            throw LoopbackHTTPError.connect(errno)
        }

        var requestHeaders = headers
        if !requestHeaders.keys.contains(where: { $0.caseInsensitiveCompare("Host") == .orderedSame }) {
            requestHeaders["Host"] = "127.0.0.1:\(endpoint.port)"
        }
        requestHeaders["Connection"] = "close"
        requestHeaders["Content-Length"] = String(body.count)

        var head = "\(method) \(path) HTTP/1.1\r\n"
        for (name, value) in requestHeaders.sorted(by: { $0.key < $1.key }) {
            head += "\(name): \(value)\r\n"
        }
        head += "\r\n"
        var payload = Data(head.utf8)
        payload.append(body)
        try sendAll(payload, to: descriptor)

        var raw = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let received = buffer.withUnsafeMutableBytes {
                Darwin.recv(descriptor, $0.baseAddress, $0.count, 0)
            }
            if received == 0 {
                break
            }
            if received < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    break
                }
                throw LoopbackHTTPError.receive(errno)
            }
            raw.append(contentsOf: buffer.prefix(received))
            if responseIsComplete(raw, requestMethod: method) {
                break
            }
        }
        return try parse(raw: raw, requestMethod: method)
    }

    private static func sendAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var sent = 0
            while sent < bytes.count {
                let amount = Darwin.send(
                    descriptor,
                    baseAddress.advanced(by: sent),
                    bytes.count - sent,
                    0
                )
                guard amount > 0 else {
                    throw LoopbackHTTPError.send(errno)
                }
                sent += amount
            }
        }
    }

    private static func responseIsComplete(
        _ raw: Data,
        requestMethod: String
    ) -> Bool {
        guard let boundary = raw.range(of: Data("\r\n\r\n".utf8)) else {
            return false
        }
        if requestMethod == "HEAD" {
            return true
        }
        let head = String(decoding: raw[..<boundary.lowerBound], as: UTF8.self)
        let parsed = parseHeaderLines(head)
        if let status = parsed.status, status == 204 || status == 304 {
            return true
        }
        let body = raw[boundary.upperBound...]
        if let length = parsed.headers["content-length"].flatMap(Int.init) {
            return body.count >= length
        }
        if parsed.headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            return body.range(of: Data("\r\n0\r\n\r\n".utf8)) != nil
                || body.starts(with: Data("0\r\n\r\n".utf8))
        }
        return false
    }

    private static func parse(
        raw: Data,
        requestMethod: String
    ) throws -> LoopbackHTTPResponse {
        guard let boundary = raw.range(of: Data("\r\n\r\n".utf8)) else {
            throw LoopbackHTTPError.malformedResponse
        }
        let head = String(decoding: raw[..<boundary.lowerBound], as: UTF8.self)
        let parsed = parseHeaderLines(head)
        guard let status = parsed.status else {
            throw LoopbackHTTPError.malformedResponse
        }
        let bodyBytes = Data(raw[boundary.upperBound...])
        let body: Data
        if requestMethod == "HEAD" || status == 204 || status == 304 {
            body = Data()
        } else if parsed.headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            body = (try? decodeChunked(bodyBytes)) ?? bodyBytes
        } else if let length = parsed.headers["content-length"].flatMap(Int.init) {
            body = Data(bodyBytes.prefix(length))
        } else {
            body = bodyBytes
        }
        return LoopbackHTTPResponse(
            status: status,
            headers: parsed.headers,
            body: body,
            raw: raw
        )
    }

    private static func parseHeaderLines(
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
            if let existing = headers[name] {
                headers[name] = existing + "," + value
            } else {
                headers[name] = value
            }
        }
        return (status, headers)
    }

    private static func decodeChunked(_ data: Data) throws -> Data {
        var cursor = data.startIndex
        var decoded = Data()
        let delimiter = Data("\r\n".utf8)

        while cursor < data.endIndex {
            guard let lineRange = data[cursor...].range(of: delimiter) else {
                throw LoopbackHTTPError.malformedChunkedBody
            }
            let sizeText =
                String(decoding: data[cursor..<lineRange.lowerBound], as: UTF8.self)
                .split(separator: ";", maxSplits: 1)
                .first
                .map(String.init) ?? ""
            guard let size = Int(sizeText, radix: 16) else {
                throw LoopbackHTTPError.malformedChunkedBody
            }
            cursor = lineRange.upperBound
            if size == 0 {
                return decoded
            }
            guard data.distance(from: cursor, to: data.endIndex) >= size + 2 else {
                throw LoopbackHTTPError.malformedChunkedBody
            }
            let payloadEnd = data.index(cursor, offsetBy: size)
            decoded.append(data[cursor..<payloadEnd])
            let suffixEnd = data.index(payloadEnd, offsetBy: 2)
            guard data[payloadEnd..<suffixEnd] == delimiter else {
                throw LoopbackHTTPError.malformedChunkedBody
            }
            cursor = suffixEnd
        }
        throw LoopbackHTTPError.malformedChunkedBody
    }
}
