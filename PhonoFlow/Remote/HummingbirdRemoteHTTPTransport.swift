//
//  HummingbirdRemoteHTTPTransport.swift
//  PhonoFlow
//
//  Adapter for Hummingbird 2.25.1. The file is inert until the pinned
//  Hummingbird package product is linked to the app/core target.
//

#if canImport(Hummingbird)
    import Foundation
    import HTTPTypes
    import Hummingbird
    import NIOCore

    nonisolated struct PhonoFlowRemoteRequestContext: RequestContext {
        var coreContext: CoreRequestContextStorage
        let remoteAddress: SocketAddress?

        var maxUploadSize: Int { 16 * 1_024 }

        init(source: ApplicationRequestContextSource) {
            coreContext = .init(source: source)
            remoteAddress = source.channel.remoteAddress
        }

        var remoteAddressString: String {
            switch remoteAddress {
            case .v4(let address):
                return String(describing: address.host)
            case .v6(let address):
                return String(describing: address.host)
            case .unixDomainSocket(let address):
                return String(describing: address)
            case nil:
                return "unknown"
            }
        }
    }

    nonisolated struct HummingbirdTransportAlreadyRunning: Error, Sendable {}
    nonisolated struct HummingbirdTransportEndedBeforeReady: Error, Sendable {}

    public actor HummingbirdRemoteHTTPTransport: nonisolated RemoteHTTPTransport {
        private var applicationTask: Task<Void, Never>?

        public init() {}

        public func start(
            configuration: RemoteTransportConfiguration,
            handler: @escaping @Sendable (RemoteHTTPRequest) async -> RemoteRouteResult
        ) async throws -> RemoteBoundEndpoint {
            guard applicationTask == nil else {
                throw HummingbirdTransportAlreadyRunning()
            }

            let router = Router(context: PhonoFlowRemoteRequestContext.self)
            Self.register(
                router: router,
                configuration: configuration,
                handler: handler
            )

            let ready = AsyncThrowingStream<RemoteBoundEndpoint, any Error>.makeStream(
                bufferingPolicy: .bufferingNewest(1)
            )
            let application = Application(
                router: router,
                configuration: .init(
                    address: .hostname(configuration.bindHost, port: Int(configuration.port)),
                    serverName: "PhonoFlow"
                ),
                onServerRunning: { channel in
                    guard let port = channel.localAddress?.port,
                        let resolvedPort = UInt16(exactly: port)
                    else {
                        ready.continuation.finish(throwing: HummingbirdTransportEndedBeforeReady())
                        return
                    }
                    ready.continuation.yield(
                        RemoteBoundEndpoint(host: configuration.bindHost, port: resolvedPort)
                    )
                    ready.continuation.finish()
                }
            )

            let task = Task {
                do {
                    try await application.run()
                    ready.continuation.finish(throwing: HummingbirdTransportEndedBeforeReady())
                } catch {
                    ready.continuation.finish(throwing: error)
                }
            }
            applicationTask = task

            var iterator = ready.stream.makeAsyncIterator()
            guard let endpoint = try await iterator.next() else {
                task.cancel()
                await task.value
                applicationTask = nil
                throw HummingbirdTransportEndedBeforeReady()
            }
            return endpoint
        }

        public func stop() async {
            guard let task = applicationTask else { return }
            applicationTask = nil
            task.cancel()
            await task.value
        }

        private nonisolated static func register(
            router: Router<PhonoFlowRemoteRequestContext>,
            configuration: RemoteTransportConfiguration,
            handler: @escaping @Sendable (RemoteHTTPRequest) async -> RemoteRouteResult
        ) {
            let bridge: @Sendable (Request, PhonoFlowRemoteRequestContext) async throws -> Response = {
                request,
                context in
                await response(
                    for: request,
                    context: context,
                    maximumBodyBytes: configuration.maximumBodyBytes,
                    handler: handler
                )
            }

            let paths: [RouterPath] = ["", "/**"]
            for path in paths {
                router.get(path, use: bridge)
                router.head(path, use: bridge)
                router.post(path, use: bridge)
                router.put(path, use: bridge)
                router.patch(path, use: bridge)
                router.delete(path, use: bridge)
                router.on(path, method: .options, use: bridge)
                router.on(path, method: .connect, use: bridge)
                router.on(path, method: .trace, use: bridge)
            }
        }

        private nonisolated static func response(
            for request: Request,
            context: PhonoFlowRemoteRequestContext,
            maximumBodyBytes: Int,
            handler: @escaping @Sendable (RemoteHTTPRequest) async -> RemoteRouteResult
        ) async -> Response {
            let body: Data
            do {
                let buffer = try await request.body.collect(upTo: maximumBodyBytes)
                body = Data(buffer.readableBytesView)
            } catch {
                let problem = RemoteRequestSecurity.problem(
                    status: 413,
                    title: "Content too large",
                    detail: "The request body exceeds the Remote Access limit.",
                    instance: request.head.path ?? "/",
                    code: "body_too_large"
                )
                return makeResponse(problemResponse(problem))
            }

            var headers: [String: String] = [:]
            for field in request.headers {
                let name = field.name.canonicalName
                if let existing = headers[name] {
                    headers[name] = existing + "," + field.value
                } else {
                    headers[name] = field.value
                }
            }
            if headers["host"] == nil, let authority = request.head.authority {
                headers["host"] = authority
            }

            guard let method = RemoteHTTPMethod(rawValue: request.method.rawValue) else {
                let problem = RemoteRequestSecurity.problem(
                    status: 405,
                    title: "Method not allowed",
                    detail: "This HTTP method is not supported.",
                    instance: request.head.path ?? "/",
                    code: "method_not_allowed"
                )
                return makeResponse(problemResponse(problem))
            }

            let result = await handler(
                RemoteHTTPRequest(
                    method: method,
                    target: request.head.path ?? "/",
                    headers: headers,
                    body: body,
                    remoteAddress: context.remoteAddressString
                ))
            switch result {
            case .response(let response):
                return makeResponse(response)
            case .events(let subscription):
                return eventResponse(subscription)
            case .pcm16Audio(let subscription):
                return audioResponse(subscription, isLegacy: false)
            case .legacyFloat32Audio(let subscription):
                return audioResponse(subscription, isLegacy: true)
            }
        }

        private nonisolated static func makeResponse(_ response: RemoteHTTPResponse) -> Response {
            Response(
                status: HTTPResponse.Status(code: response.status),
                headers: makeHeaders(response.headers),
                body: .init(byteBuffer: ByteBuffer(bytes: response.body))
            )
        }

        private nonisolated static func eventResponse(
            _ subscription: RemoteEventSubscription
        ) -> Response {
            let headers = RemoteHTTPHeaders.applyingSecurityHeaders(
                to: [
                    "Content-Type": "text/event-stream; charset=utf-8",
                    "Cache-Control": "no-cache, no-store",
                    "Connection": "keep-alive",
                    "X-Accel-Buffering": "no",
                ],
                noStore: true
            )
            return Response(
                status: .ok,
                headers: makeHeaders(headers),
                body: .init { writer in
                    do {
                        try await writer.write(ByteBuffer(string: "retry: 2000\n\n"))
                        for await event in subscription.stream {
                            try await writer.write(ByteBuffer(bytes: try event.serverSentEventData()))
                        }
                        await subscription.cancel()
                        try await writer.finish(nil)
                    } catch {
                        await subscription.cancel()
                        throw error
                    }
                }
            )
        }

        private nonisolated static func audioResponse(
            _ subscription: RemoteAudioSubscription,
            isLegacy: Bool
        ) -> Response {
            var values: [String: String] = [
                "Content-Type": "audio/wav",
                "Cache-Control": "no-cache, no-store",
                "Accept-Ranges": "none",
            ]
            if isLegacy {
                values["icy-name"] = "PhonoFlow Radio"
            }
            let headers = RemoteHTTPHeaders.applyingSecurityHeaders(to: values, noStore: true)
            return Response(
                status: .ok,
                headers: makeHeaders(headers),
                body: .init { writer in
                    do {
                        try await writer.write(
                            ByteBuffer(bytes: RemoteWAV.streamingHeader(format: subscription.format))
                        )
                        for await chunk in subscription.stream {
                            try await writer.write(ByteBuffer(bytes: chunk))
                        }
                        await subscription.cancel()
                        try await writer.finish(nil)
                    } catch {
                        await subscription.cancel()
                        throw error
                    }
                }
            )
        }

        private nonisolated static func makeHeaders(_ values: [String: String]) -> HTTPFields {
            var fields = HTTPFields()
            for (name, value) in values {
                guard let fieldName = HTTPField.Name(name) else { continue }
                fields[fieldName] = value
            }
            return fields
        }

        private nonisolated static func problemResponse(
            _ problem: RemoteAPIProblem
        ) -> RemoteHTTPResponse {
            RemoteHTTPResponse(
                status: problem.status,
                headers: RemoteHTTPHeaders.applyingSecurityHeaders(
                    to: ["Content-Type": "application/problem+json; charset=utf-8"],
                    noStore: true
                ),
                body: (try? RemoteJSON.encoder().encode(problem)) ?? Data()
            )
        }
    }
#endif
