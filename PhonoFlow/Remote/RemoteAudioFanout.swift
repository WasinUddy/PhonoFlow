//
//  RemoteAudioFanout.swift
//  PhonoFlow
//

import Foundation

nonisolated public enum RemoteAudioStreamKind: Sendable, Equatable {
    case pcm16Browser
    case legacyFloat32
}

/// Identifies which listener owns a subscription so independently managed
/// transports sharing one fanout never revoke each other's clients.
nonisolated public enum RemoteAudioSubscriptionOrigin: Sendable, Equatable {
    case pairedRemoteAccess
    case dedicatedLegacyListener
}

nonisolated public enum RemoteAudioEncoding: Sendable, Equatable {
    case pcm16
    case float32

    fileprivate var waveFormatCode: UInt16 {
        switch self {
        case .pcm16: return 1
        case .float32: return 3
        }
    }

    fileprivate var bitsPerSample: UInt16 {
        switch self {
        case .pcm16: return 16
        case .float32: return 32
        }
    }
}

nonisolated public struct RemoteAudioStreamFormat: Sendable, Equatable {
    public var encoding: RemoteAudioEncoding
    public var sampleRate: UInt32
    public var channelCount: UInt16

    public init(encoding: RemoteAudioEncoding, sampleRate: UInt32, channelCount: UInt16 = 2) {
        self.encoding = encoding
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }
}

public actor RemoteAudioMailbox {
    private let capacity: Int
    private var chunks: [Data] = []
    private var waiters: [CheckedContinuation<Data?, Never>] = []
    private var isClosed = false

    init(capacity: Int = 8) {
        self.capacity = max(1, capacity)
    }

    /// Audio is latency-sensitive: one full-queue drop evicts the slow client
    /// instead of accumulating lag or memory.
    func enqueue(_ data: Data) -> Bool {
        guard !isClosed else { return false }
        if !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            waiter.resume(returning: data)
            return true
        }
        guard chunks.count < capacity else {
            close()
            return false
        }
        chunks.append(data)
        return true
    }

    func next() async -> Data? {
        if !chunks.isEmpty {
            return chunks.removeFirst()
        }
        guard !isClosed else { return nil }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    /// Read-only synchronization diagnostic for deterministic tests. Calling it
    /// never changes queue, continuation, or delivery state.
    func waitingConsumerCount() -> Int {
        waiters.count
    }

    func hasWaitingConsumer() -> Bool {
        !waiters.isEmpty
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        chunks.removeAll(keepingCapacity: false)
        let waiters = self.waiters
        self.waiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume(returning: nil)
        }
    }
}

nonisolated public struct RemoteAudioByteStream: AsyncSequence, Sendable {
    public typealias Element = Data

    public struct AsyncIterator: AsyncIteratorProtocol {
        fileprivate let mailbox: RemoteAudioMailbox
        fileprivate let cancellation: @Sendable () async -> Void

        public mutating func next() async -> Data? {
            let mailbox = self.mailbox
            let cancellation = self.cancellation
            let chunk: Data? = await withTaskCancellationHandler {
                if Task.isCancelled {
                    await mailbox.close()
                    return nil
                }
                return await mailbox.next()
            } onCancel: {
                Task {
                    await mailbox.close()
                    await cancellation()
                }
            }

            guard !Task.isCancelled, let chunk else {
                await cancellation()
                return nil
            }
            return chunk
        }
    }

    fileprivate let mailbox: RemoteAudioMailbox
    fileprivate let cancellation: @Sendable () async -> Void

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(mailbox: mailbox, cancellation: cancellation)
    }

    /// Read-only synchronization diagnostic used by deterministic lifecycle
    /// tests to cancel only after `next()` has installed its continuation.
    func waitingConsumerCount() async -> Int {
        await mailbox.waitingConsumerCount()
    }

    func hasWaitingConsumer() async -> Bool {
        await mailbox.hasWaitingConsumer()
    }
}

nonisolated public struct RemoteAudioSubscription: Sendable {
    public var id: UUID
    public var kind: RemoteAudioStreamKind
    public var format: RemoteAudioStreamFormat
    public var principal: RemoteSessionPrincipal?
    public var stream: RemoteAudioByteStream
    private let cancellation: @Sendable () async -> Void

    fileprivate init(
        id: UUID,
        kind: RemoteAudioStreamKind,
        format: RemoteAudioStreamFormat,
        principal: RemoteSessionPrincipal?,
        mailbox: RemoteAudioMailbox,
        cancellation: @escaping @Sendable () async -> Void
    ) {
        self.id = id
        self.kind = kind
        self.format = format
        self.principal = principal
        self.stream = RemoteAudioByteStream(
            mailbox: mailbox,
            cancellation: cancellation
        )
        self.cancellation = cancellation
    }

    public func cancel() async {
        await cancellation()
    }
}

nonisolated public enum RemoteAudioSubscriptionError: Error, Sendable, Equatable {
    case clientCapacity
    case addressCapacity
    case unavailable
}

nonisolated public protocol RemoteAudioStreamProviding: Sendable {
    func subscribe(
        kind: RemoteAudioStreamKind,
        principal: RemoteSessionPrincipal?,
        remoteAddress: String,
        origin: RemoteAudioSubscriptionOrigin
    ) async throws -> RemoteAudioSubscription
    func unsubscribe(_ id: UUID) async
    func revoke(sessionID: String) async
    func revoke(kind: RemoteAudioStreamKind) async
    func revoke(origin: RemoteAudioSubscriptionOrigin) async
    func revokeAllAuthenticated() async
    func listenerCount() async -> Int
    func listenerCount(kind: RemoteAudioStreamKind) async -> Int
}

extension RemoteAudioStreamProviding {
    nonisolated public func subscribe(
        kind: RemoteAudioStreamKind,
        principal: RemoteSessionPrincipal?,
        remoteAddress: String
    ) async throws -> RemoteAudioSubscription {
        try await subscribe(
            kind: kind,
            principal: principal,
            remoteAddress: remoteAddress,
            origin: .pairedRemoteAccess
        )
    }
}

/// Worker-side fanout seam. The real-time callback must never call this actor;
/// a resampling/conversion worker publishes one shared immutable Data chunk.
public actor RemoteAudioFanout: nonisolated RemoteAudioStreamProviding {
    private struct Client: Sendable {
        var kind: RemoteAudioStreamKind
        var remoteAddress: String
        var principal: RemoteSessionPrincipal?
        var origin: RemoteAudioSubscriptionOrigin
        var mailbox: RemoteAudioMailbox
        var expiryTask: Task<Void, Never>?
    }

    private let maximumClients: Int
    private let maximumClientsPerAddress: Int
    private let queueCapacity: Int
    private let clock: any RemoteClock
    private var legacySampleRate: UInt32
    private var clients: [UUID: Client] = [:]

    public init(
        maximumClients: Int = 8,
        maximumClientsPerAddress: Int = 2,
        queueCapacity: Int = 8,
        legacySampleRate: UInt32 = 44_100,
        clock: any RemoteClock = SystemRemoteClock()
    ) {
        self.maximumClients = max(1, maximumClients)
        self.maximumClientsPerAddress = max(1, maximumClientsPerAddress)
        self.queueCapacity = max(1, queueCapacity)
        self.legacySampleRate = legacySampleRate
        self.clock = clock
    }

    deinit {
        for client in clients.values {
            client.expiryTask?.cancel()
            let mailbox = client.mailbox
            Task {
                await mailbox.close()
            }
        }
    }

    public func setLegacySampleRate(_ sampleRate: UInt32) async {
        let sampleRate = max(1, sampleRate)
        guard sampleRate != legacySampleRate else { return }
        legacySampleRate = sampleRate
        let staleLegacyIDs = clients.compactMap { id, client in
            client.kind == .legacyFloat32 ? id : nil
        }
        for id in staleLegacyIDs {
            await removeClient(id)
        }
    }

    public func subscribe(
        kind: RemoteAudioStreamKind,
        principal: RemoteSessionPrincipal?,
        remoteAddress: String,
        origin: RemoteAudioSubscriptionOrigin
    ) async throws -> RemoteAudioSubscription {
        guard clients.count < maximumClients else {
            throw RemoteAudioSubscriptionError.clientCapacity
        }
        let canonicalAddress = remoteAddress.lowercased()
        guard
            clients.values.filter({ $0.remoteAddress == canonicalAddress }).count
                < maximumClientsPerAddress
        else {
            throw RemoteAudioSubscriptionError.addressCapacity
        }

        let id = UUID()
        let mailbox = RemoteAudioMailbox(capacity: queueCapacity)
        let format: RemoteAudioStreamFormat
        switch kind {
        case .pcm16Browser:
            format = RemoteAudioStreamFormat(encoding: .pcm16, sampleRate: 48_000)
        case .legacyFloat32:
            format = RemoteAudioStreamFormat(encoding: .float32, sampleRate: legacySampleRate)
        }
        clients[id] = Client(
            kind: kind,
            remoteAddress: canonicalAddress,
            principal: principal,
            origin: origin,
            mailbox: mailbox,
            expiryTask: principal.map {
                makeExpiryTask(id: id, expiresAt: $0.expiresAt)
            }
        )
        return RemoteAudioSubscription(
            id: id,
            kind: kind,
            format: format,
            principal: principal,
            mailbox: mailbox
        ) { [weak self] in
            await self?.unsubscribe(id)
        }
    }

    public func unsubscribe(_ id: UUID) async {
        await removeClient(id)
    }

    public func revoke(sessionID: String) async {
        let matchingIDs = clients.compactMap { id, client in
            client.principal?.sessionID == sessionID ? id : nil
        }
        for id in matchingIDs {
            await removeClient(id)
        }
    }

    public func revoke(kind: RemoteAudioStreamKind) async {
        let matchingIDs = clients.compactMap { id, client in
            client.kind == kind ? id : nil
        }
        for id in matchingIDs {
            await removeClient(id)
        }
    }

    public func revoke(origin: RemoteAudioSubscriptionOrigin) async {
        let matchingIDs = clients.compactMap { id, client in
            client.origin == origin ? id : nil
        }
        for id in matchingIDs {
            await removeClient(id)
        }
    }

    public func revokeAllAuthenticated() async {
        let matchingIDs = clients.compactMap { id, client in
            client.principal == nil ? nil : id
        }
        for id in matchingIDs {
            await removeClient(id)
        }
    }

    public func listenerCount() async -> Int {
        clients.count
    }

    public func listenerCount(kind: RemoteAudioStreamKind) async -> Int {
        clients.values.count(where: { $0.kind == kind })
    }

    public func publishPCM16(_ data: Data) async {
        await publish(data, kind: .pcm16Browser)
    }

    public func publishLegacyFloat32(_ data: Data) async {
        await publish(data, kind: .legacyFloat32)
    }

    public func closeAll() async {
        let existingIDs = Array(clients.keys)
        for id in existingIDs {
            await removeClient(id)
        }
    }

    private func publish(_ data: Data, kind: RemoteAudioStreamKind) async {
        guard !data.isEmpty else { return }
        var closedIDs: [UUID] = []
        for (id, client) in clients where client.kind == kind {
            if await !client.mailbox.enqueue(data) {
                closedIDs.append(id)
            }
        }
        for id in closedIDs {
            await removeClient(id)
        }
    }

    private func makeExpiryTask(id: UUID, expiresAt: Date) -> Task<Void, Never> {
        let remaining = expiresAt.timeIntervalSince(clock.now)
        return Task { [weak self] in
            if remaining > 0 {
                do {
                    try await Task.sleep(for: .seconds(remaining))
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else { return }
            await self?.removeClient(id)
        }
    }

    private func removeClient(_ id: UUID) async {
        guard let client = clients.removeValue(forKey: id) else { return }
        client.expiryTask?.cancel()
        await client.mailbox.close()
    }
}

nonisolated public enum RemoteWAV {
    /// A 44-byte streaming WAV header with sentinel RIFF/data sizes.
    public static func streamingHeader(format: RemoteAudioStreamFormat) -> Data {
        let bits = format.encoding.bitsPerSample
        let blockAlign = format.channelCount * (bits / 8)
        let byteRate = format.sampleRate * UInt32(blockAlign)
        var data = Data(capacity: 44)
        data.append(contentsOf: [0x52, 0x49, 0x46, 0x46])  // RIFF
        data.appendLittleEndian(UInt32(0x7FFF_FFFF))
        data.append(contentsOf: [0x57, 0x41, 0x56, 0x45])  // WAVE
        data.append(contentsOf: [0x66, 0x6D, 0x74, 0x20])  // fmt
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(format.encoding.waveFormatCode)
        data.appendLittleEndian(format.channelCount)
        data.appendLittleEndian(format.sampleRate)
        data.appendLittleEndian(byteRate)
        data.appendLittleEndian(blockAlign)
        data.appendLittleEndian(bits)
        data.append(contentsOf: [0x64, 0x61, 0x74, 0x61])  // data
        data.appendLittleEndian(UInt32(0x7FFF_FFFF - 36))
        return data
    }

    /// Worker-side deterministic Float32 stereo to little-endian PCM16.
    public static func pcm16Interleaved(left: [Float], right: [Float]) -> Data {
        let count = min(left.count, right.count)
        var result = Data(capacity: count * 4)
        for index in 0..<count {
            result.appendLittleEndian(quantize(left[index]))
            result.appendLittleEndian(quantize(right[index]))
        }
        return result
    }

    private static func quantize(_ sample: Float) -> Int16 {
        guard sample.isFinite else { return 0 }
        if sample <= -1 { return Int16.min }
        if sample >= 1 { return Int16.max }
        return Int16((sample * 32_767).rounded())
    }
}
nonisolated

    extension Data
{
    fileprivate mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { bytes in
            append(contentsOf: bytes)
        }
    }
}
