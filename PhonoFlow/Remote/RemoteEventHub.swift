//
//  RemoteEventHub.swift
//  PhonoFlow
//

import Foundation

nonisolated public enum RemoteServerEvent: Sendable, Equatable {
    case snapshot(RemoteStateSnapshot)
    case state(RemoteStateSnapshot)
    case meters(RemoteMeterSnapshot)
    case spectrum(RemoteSpectrogramColumn)
    case heartbeat(Date)

    fileprivate var isControlEvent: Bool {
        switch self {
        case .snapshot, .state:
            return true
        case .meters, .spectrum, .heartbeat:
            return false
        }
    }

    public func serverSentEventData() throws -> Data {
        switch self {
        case .heartbeat(let date):
            let value = ISO8601DateFormatter().string(from: date)
            return Data(": heartbeat \(value)\n\n".utf8)
        case .snapshot(let snapshot):
            return try Self.encode(name: "snapshot", id: snapshot.revision, payload: snapshot)
        case .state(let snapshot):
            return try Self.encode(name: "state", id: snapshot.revision, payload: snapshot)
        case .meters(let meters):
            return try Self.encode(name: "meters", id: meters.sequence, payload: meters)
        case .spectrum(let column):
            return try Self.encode(name: "spectrogram", id: column.sequence, payload: column)
        }
    }

    private static func encode<T: Encodable>(
        name: String,
        id: UInt64,
        payload: T
    ) throws -> Data {
        let encoded = try RemoteJSON.encoder().encode(payload)
        guard let json = String(data: encoded, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return Data("id: \(id)\nevent: \(name)\ndata: \(json)\n\n".utf8)
    }
}

public actor RemoteEventMailbox {
    private let controlCapacity: Int
    private let maximumConsecutiveDrops: Int
    private var controlEvents: [RemoteServerEvent] = []
    private var latestMeters: RemoteServerEvent?
    private var latestSpectrum: RemoteServerEvent?
    private var heartbeat: RemoteServerEvent?
    private var waiters: [CheckedContinuation<RemoteServerEvent?, Never>] = []
    private var isClosed = false
    private var consecutiveDrops = 0

    init(controlCapacity: Int = 16, maximumConsecutiveDrops: Int = 128) {
        self.controlCapacity = max(1, controlCapacity)
        self.maximumConsecutiveDrops = max(1, maximumConsecutiveDrops)
    }

    /// Returns false once the client is evicted or closed.
    func enqueue(_ event: RemoteServerEvent) -> Bool {
        guard !isClosed else { return false }

        if !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            consecutiveDrops = 0
            waiter.resume(returning: event)
            return true
        }

        switch event {
        case .snapshot, .state:
            if controlEvents.count >= controlCapacity {
                // A full snapshot/state is a safe resynchronization point.
                controlEvents = [event]
                consecutiveDrops += 1
            } else {
                controlEvents.append(event)
            }
        case .meters:
            if latestMeters != nil { consecutiveDrops += 1 }
            latestMeters = event
        case .spectrum:
            if latestSpectrum != nil { consecutiveDrops += 1 }
            latestSpectrum = event
        case .heartbeat:
            if heartbeat != nil { consecutiveDrops += 1 }
            heartbeat = event
        }

        if consecutiveDrops >= maximumConsecutiveDrops {
            close()
            return false
        }
        return true
    }

    func next() async -> RemoteServerEvent? {
        if let event = dequeue() {
            consecutiveDrops = 0
            return event
        }
        guard !isClosed else { return nil }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    /// Read-only synchronization diagnostic for deterministic lifecycle tests.
    func waitingConsumerCount() -> Int {
        waiters.count
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        controlEvents.removeAll(keepingCapacity: false)
        latestMeters = nil
        latestSpectrum = nil
        heartbeat = nil
        let waiters = self.waiters
        self.waiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume(returning: nil)
        }
    }

    private func dequeue() -> RemoteServerEvent? {
        if !controlEvents.isEmpty {
            return controlEvents.removeFirst()
        }
        if let latestMeters {
            self.latestMeters = nil
            return latestMeters
        }
        if let latestSpectrum {
            self.latestSpectrum = nil
            return latestSpectrum
        }
        if let heartbeat {
            self.heartbeat = nil
            return heartbeat
        }
        return nil
    }
}

nonisolated public struct RemoteEventStream: AsyncSequence, Sendable {
    public typealias Element = RemoteServerEvent

    public struct AsyncIterator: AsyncIteratorProtocol {
        fileprivate let mailbox: RemoteEventMailbox
        fileprivate let cancellation: @Sendable () async -> Void

        public mutating func next() async -> RemoteServerEvent? {
            let mailbox = self.mailbox
            let cancellation = self.cancellation
            let event: RemoteServerEvent? = await withTaskCancellationHandler {
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

            guard !Task.isCancelled, let event else {
                await cancellation()
                return nil
            }
            return event
        }
    }

    fileprivate let mailbox: RemoteEventMailbox
    fileprivate let cancellation: @Sendable () async -> Void

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(mailbox: mailbox, cancellation: cancellation)
    }

    func waitingConsumerCount() async -> Int {
        await mailbox.waitingConsumerCount()
    }
}

nonisolated public struct RemoteEventSubscription: Sendable {
    public var id: UUID
    public var principal: RemoteSessionPrincipal
    public var stream: RemoteEventStream
    private let cancellation: @Sendable () async -> Void

    fileprivate init(
        id: UUID,
        principal: RemoteSessionPrincipal,
        mailbox: RemoteEventMailbox,
        cancellation: @escaping @Sendable () async -> Void
    ) {
        self.id = id
        self.principal = principal
        self.stream = RemoteEventStream(
            mailbox: mailbox,
            cancellation: cancellation
        )
        self.cancellation = cancellation
    }

    public func cancel() async {
        await cancellation()
    }
}

nonisolated public enum RemoteEventCapacityError: Error, Sendable, Equatable {
    case clientCapacity
    case sessionCapacity
    case sourceCapacity
}

public actor RemoteEventHub {
    private static let spectrumIntervalNanoseconds: Int64 = 1_000_000_000 / 15 + 1
    /// `Date` stores seconds as `Double`, so sub-microsecond representation
    /// noise grows as timestamps move away from the reference date. This
    /// tolerance is far below one audio sample at 48 kHz while preserving the
    /// processor's alternating 66,666,666/667 ns 15 Hz cadence.
    private static let spectrumTimestampToleranceNanoseconds: Int64 = 1_000

    private struct Client: Sendable {
        var principal: RemoteSessionPrincipal
        var remoteAddress: String
        var mailbox: RemoteEventMailbox
        var expiryTask: Task<Void, Never>
    }

    private let maximumClients: Int
    private let maximumClientsPerSession: Int
    private let maximumClientsPerAddress: Int
    private let clock: any RemoteClock
    private var clients: [UUID: Client] = [:]
    private var latestSnapshot: RemoteStateSnapshot?
    private var lastMeterPublication = Date.distantPast
    private var lastSpectrumPublication = Date.distantPast
    private var heartbeatTask: Task<Void, Never>?

    public init(
        maximumClients: Int = 8,
        maximumClientsPerSession: Int = 2,
        maximumClientsPerAddress: Int = 2,
        clock: any RemoteClock = SystemRemoteClock()
    ) {
        self.maximumClients = max(1, maximumClients)
        self.maximumClientsPerSession = max(1, maximumClientsPerSession)
        self.maximumClientsPerAddress = max(1, maximumClientsPerAddress)
        self.clock = clock
    }

    deinit {
        heartbeatTask?.cancel()
        for client in clients.values {
            client.expiryTask.cancel()
            let mailbox = client.mailbox
            Task {
                await mailbox.close()
            }
        }
    }

    public func subscribe(
        principal: RemoteSessionPrincipal,
        snapshot: RemoteStateSnapshot,
        remoteAddress: String = ""
    ) async throws -> RemoteEventSubscription {
        guard clients.count < maximumClients else {
            throw RemoteEventCapacityError.clientCapacity
        }
        guard
            clients.values.count(where: {
                $0.principal.sessionID == principal.sessionID
            }) < maximumClientsPerSession
        else {
            throw RemoteEventCapacityError.sessionCapacity
        }
        let canonicalAddress = remoteAddress.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).lowercased()
        guard
            canonicalAddress.isEmpty
                || clients.values.count(where: {
                    $0.remoteAddress == canonicalAddress
                }) < maximumClientsPerAddress
        else {
            throw RemoteEventCapacityError.sourceCapacity
        }
        latestSnapshot = snapshot
        let id = UUID()
        let mailbox = RemoteEventMailbox()
        let expiryTask = makeExpiryTask(id: id, expiresAt: principal.expiresAt)
        clients[id] = Client(
            principal: principal,
            remoteAddress: canonicalAddress,
            mailbox: mailbox,
            expiryTask: expiryTask
        )
        _ = await mailbox.enqueue(.snapshot(snapshot))
        startHeartbeatIfNeeded()
        return RemoteEventSubscription(
            id: id,
            principal: principal,
            mailbox: mailbox
        ) { [weak self] in
            await self?.unsubscribe(id)
        }
    }

    public func unsubscribe(_ id: UUID) async {
        await removeClient(id)
        stopHeartbeatIfIdle()
    }

    public func revoke(sessionID: String) async {
        let matchingIDs = clients.compactMap { id, client in
            client.principal.sessionID == sessionID ? id : nil
        }
        for id in matchingIDs {
            await removeClient(id)
        }
        stopHeartbeatIfIdle()
    }

    public func revokeAll() async {
        let existingIDs = Array(clients.keys)
        for id in existingIDs {
            await removeClient(id)
        }
        stopHeartbeatIfIdle()
    }

    public func publish(snapshot: RemoteStateSnapshot) async {
        latestSnapshot = snapshot
        await publish(.state(snapshot))
    }

    /// Enforces the API's 10 Hz meter ceiling even if the audio engine calls faster.
    public func publish(meters: RemoteMeterSnapshot) async {
        guard meters.timestamp.timeIntervalSince(lastMeterPublication) >= 0.1 else { return }
        lastMeterPublication = meters.timestamp
        await publish(.meters(meters))
    }

    /// Enforces the API's 15 Hz spectrogram ceiling.
    @discardableResult
    public func publish(spectrogram: RemoteSpectrogramColumn) async -> Bool {
        guard spectrogram.intensities.count == 64 else { return false }
        if lastSpectrumPublication != .distantPast {
            let elapsedSeconds = spectrogram.timestamp.timeIntervalSince(lastSpectrumPublication)
            guard elapsedSeconds >= 0 else { return false }
            let elapsedNanoseconds = Int64((elapsedSeconds * 1_000_000_000).rounded())
            guard
                elapsedNanoseconds
                    >= Self.spectrumIntervalNanoseconds
                    - Self.spectrumTimestampToleranceNanoseconds
            else {
                return false
            }
        }
        lastSpectrumPublication = spectrogram.timestamp
        await publish(.spectrum(spectrogram))
        return true
    }

    public var clientCount: Int {
        clients.count
    }

    private func publish(_ event: RemoteServerEvent) async {
        var closedIDs: [UUID] = []
        for (id, client) in clients {
            if await !client.mailbox.enqueue(event) {
                closedIDs.append(id)
            }
        }
        for id in closedIDs {
            await removeClient(id)
        }
        stopHeartbeatIfIdle()
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
            await self?.expire(id)
        }
    }

    private func expire(_ id: UUID) async {
        await removeClient(id)
        stopHeartbeatIfIdle()
    }

    private func removeClient(_ id: UUID) async {
        guard let client = clients.removeValue(forKey: id) else { return }
        client.expiryTask.cancel()
        await client.mailbox.close()
    }

    private func startHeartbeatIfNeeded() {
        guard heartbeatTask == nil, !clients.isEmpty else { return }
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(15))
                } catch {
                    return
                }
                guard let self else { return }
                await self.publish(.heartbeat(Date()))
            }
        }
    }

    private func stopHeartbeatIfIdle() {
        guard clients.isEmpty else { return }
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }
}
