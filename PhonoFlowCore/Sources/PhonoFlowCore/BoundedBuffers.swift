import Foundation
import Synchronization

public enum BoundedBufferError: Error, Equatable, Sendable {
    case capacityMustBePositivePowerOfTwo(Int)
}

public struct SPSCBufferStatistics: Equatable, Sendable {
    public let capacity: Int
    public let approximateCount: Int
    public let overflowEvents: UInt64
    public let droppedElements: UInt64
    public let underflowEvents: UInt64

    public init(
        capacity: Int,
        approximateCount: Int,
        overflowEvents: UInt64,
        droppedElements: UInt64,
        underflowEvents: UInt64
    ) {
        self.capacity = capacity
        self.approximateCount = approximateCount
        self.overflowEvents = overflowEvents
        self.droppedElements = droppedElements
        self.underflowEvents = underflowEvents
    }
}

/// A fixed-capacity, allocation-free single-producer/single-consumer queue.
///
/// Exactly one execution context may call producer methods (`offer` and
/// `write`) and exactly one execution context may call consumer methods
/// (`poll` and `read`). Producer and consumer may run concurrently. The queue
/// deliberately rejects an entire block when it cannot fit, preserving audio
/// block boundaries instead of overwriting unread samples.
///
/// The unchecked `Sendable` conformance is limited to this type because Swift
/// pointers do not carry synchronization semantics. Release/acquire cursor
/// publication protects initialized storage under the documented SPSC rules.
public final class BoundedSPSCBuffer<Element: Sendable>: @unchecked Sendable {
    public let capacity: Int

    private let capacityMask: UInt64
    private let storage: UnsafeMutablePointer<Element>
    private let readCursor = Atomic<UInt64>(0)
    private let writeCursor = Atomic<UInt64>(0)
    private let overflowEventCounter = Atomic<UInt64>(0)
    private let droppedElementCounter = Atomic<UInt64>(0)
    private let underflowEventCounter = Atomic<UInt64>(0)

    public init(capacity: Int) throws {
        guard capacity > 0, capacity.isPowerOfTwo else {
            throw BoundedBufferError.capacityMustBePositivePowerOfTwo(capacity)
        }
        self.capacity = capacity
        capacityMask = UInt64(capacity - 1)
        storage = .allocate(capacity: capacity)
    }

    deinit {
        // Destruction requires producer and consumer to be quiescent.
        let read = readCursor.load(ordering: .relaxed)
        let write = writeCursor.load(ordering: .relaxed)
        var cursor = read
        while cursor != write {
            storage.advanced(by: storageIndex(for: cursor)).deinitialize(count: 1)
            cursor &+= 1
        }
        storage.deallocate()
    }

    /// Offers one value without blocking or allocating.
    @discardableResult
    public func offer(_ element: Element) -> Bool {
        let write = writeCursor.load(ordering: .relaxed)
        let read = readCursor.load(ordering: .acquiring)
        guard write &- read < UInt64(capacity) else {
            recordOverflow(dropped: 1)
            return false
        }

        storage.advanced(by: storageIndex(for: write)).initialize(to: element)
        writeCursor.store(write &+ 1, ordering: .releasing)
        return true
    }

    /// Offers a complete block, returning zero rather than partially writing
    /// when the queue lacks room.
    @discardableResult
    public func write(_ elements: UnsafeBufferPointer<Element>) -> Int {
        guard !elements.isEmpty else {
            return 0
        }
        guard elements.count <= capacity else {
            recordOverflow(dropped: elements.count)
            return 0
        }

        let write = writeCursor.load(ordering: .relaxed)
        let read = readCursor.load(ordering: .acquiring)
        let occupied = Int(write &- read)
        guard elements.count <= capacity - occupied else {
            recordOverflow(dropped: elements.count)
            return 0
        }

        for offset in elements.indices {
            let cursor = write &+ UInt64(offset)
            storage
                .advanced(by: storageIndex(for: cursor))
                .initialize(to: elements[offset])
        }
        writeCursor.store(write &+ UInt64(elements.count), ordering: .releasing)
        return elements.count
    }

    /// Returns the next value, or nil when no value is currently available.
    public func poll() -> Element? {
        let read = readCursor.load(ordering: .relaxed)
        let write = writeCursor.load(ordering: .acquiring)
        guard read != write else {
            underflowEventCounter.wrappingAdd(1, ordering: .relaxed)
            return nil
        }

        let value = storage.advanced(by: storageIndex(for: read)).move()
        readCursor.store(read &+ 1, ordering: .releasing)
        return value
    }

    /// Moves as many available values as will fit into initialized destination
    /// storage. A zero result is counted as one underflow event.
    @discardableResult
    public func read(into destination: UnsafeMutableBufferPointer<Element>) -> Int {
        guard !destination.isEmpty else {
            return 0
        }

        let read = readCursor.load(ordering: .relaxed)
        let write = writeCursor.load(ordering: .acquiring)
        let available = Int(write &- read)
        let count = min(destination.count, available)
        guard count > 0 else {
            underflowEventCounter.wrappingAdd(1, ordering: .relaxed)
            return 0
        }

        for offset in 0..<count {
            let cursor = read &+ UInt64(offset)
            destination[offset] = storage.advanced(by: storageIndex(for: cursor)).move()
        }
        readCursor.store(read &+ UInt64(count), ordering: .releasing)
        return count
    }

    /// A moment-in-time diagnostic snapshot; count may change immediately.
    public func statistics() -> SPSCBufferStatistics {
        let read = readCursor.load(ordering: .acquiring)
        let write = writeCursor.load(ordering: .acquiring)
        return SPSCBufferStatistics(
            capacity: capacity,
            approximateCount: min(capacity, Int(write &- read)),
            overflowEvents: overflowEventCounter.load(ordering: .relaxed),
            droppedElements: droppedElementCounter.load(ordering: .relaxed),
            underflowEvents: underflowEventCounter.load(ordering: .relaxed)
        )
    }

    @inline(__always)
    private func storageIndex(for cursor: UInt64) -> Int {
        Int(cursor & capacityMask)
    }

    @inline(__always)
    private func recordOverflow(dropped: Int) {
        overflowEventCounter.wrappingAdd(1, ordering: .relaxed)
        droppedElementCounter.wrappingAdd(UInt64(dropped), ordering: .relaxed)
    }
}

public struct FanoutSubscription<Element: Sendable>: Sendable {
    public let id: UUID
    public let stream: AsyncStream<Element>

    public init(id: UUID, stream: AsyncStream<Element>) {
        self.id = id
        self.stream = stream
    }
}

public struct FanoutPublishReport: Equatable, Sendable {
    public let subscriberCount: Int
    public let enqueuedCount: Int
    public let droppedCount: Int
    public let evictedSubscriberIDs: [UUID]

    public init(
        subscriberCount: Int,
        enqueuedCount: Int,
        droppedCount: Int,
        evictedSubscriberIDs: [UUID]
    ) {
        self.subscriberCount = subscriberCount
        self.enqueuedCount = enqueuedCount
        self.droppedCount = droppedCount
        self.evictedSubscriberIDs = evictedSubscriberIDs
    }
}

public struct FanoutStatistics: Equatable, Sendable {
    public let activeSubscribers: Int
    public let publishedElements: UInt64
    public let enqueuedDeliveries: UInt64
    public let droppedDeliveries: UInt64
    public let evictedSubscribers: UInt64

    public init(
        activeSubscribers: Int,
        publishedElements: UInt64,
        enqueuedDeliveries: UInt64,
        droppedDeliveries: UInt64,
        evictedSubscribers: UInt64
    ) {
        self.activeSubscribers = activeSubscribers
        self.publishedElements = publishedElements
        self.enqueuedDeliveries = enqueuedDeliveries
        self.droppedDeliveries = droppedDeliveries
        self.evictedSubscribers = evictedSubscribers
    }
}

/// Actor-isolated bounded multicast for worker-to-network/UI delivery.
///
/// Every subscriber owns an independent buffering-newest queue. A stalled
/// subscriber cannot grow memory or block peers and is evicted after a
/// configurable number of consecutive drops.
public actor BoundedFanout<Element: Sendable> {
    private struct Subscriber {
        let token: UUID
        let continuation: AsyncStream<Element>.Continuation
        var consecutiveDrops: Int
    }

    public let bufferCapacity: Int
    public let consecutiveDropLimit: Int

    private var subscribers: [UUID: Subscriber] = [:]
    private var publishedElements: UInt64 = 0
    private var enqueuedDeliveries: UInt64 = 0
    private var droppedDeliveries: UInt64 = 0
    private var evictedSubscribers: UInt64 = 0

    public init(bufferCapacity: Int, consecutiveDropLimit: Int = 3) {
        precondition(bufferCapacity > 0, "Fanout buffer capacity must be positive")
        precondition(consecutiveDropLimit > 0, "Drop limit must be positive")
        self.bufferCapacity = bufferCapacity
        self.consecutiveDropLimit = consecutiveDropLimit
    }

    public func subscribe(id: UUID = UUID()) -> FanoutSubscription<Element> {
        if let existing = subscribers.removeValue(forKey: id) {
            existing.continuation.finish()
        }

        let pair = AsyncStream<Element>.makeStream(
            bufferingPolicy: .bufferingNewest(bufferCapacity)
        )
        let token = UUID()
        pair.continuation.onTermination = { [weak self] _ in
            Task {
                await self?.removeSubscriber(id: id, token: token)
            }
        }
        subscribers[id] = Subscriber(
            token: token,
            continuation: pair.continuation,
            consecutiveDrops: 0
        )
        return FanoutSubscription(id: id, stream: pair.stream)
    }

    @discardableResult
    public func publish(_ element: Element) -> FanoutPublishReport {
        publishedElements &+= 1

        let subscriberCount = subscribers.count
        var enqueuedCount = 0
        var droppedCount = 0
        var removals: [UUID] = []
        var evictions: [UUID] = []
        removals.reserveCapacity(subscriberCount)
        evictions.reserveCapacity(subscriberCount)

        for id in Array(subscribers.keys) {
            guard var subscriber = subscribers[id] else {
                continue
            }
            switch subscriber.continuation.yield(element) {
            case .enqueued:
                enqueuedCount += 1
                enqueuedDeliveries &+= 1
                subscriber.consecutiveDrops = 0
                subscribers[id] = subscriber

            case .dropped:
                droppedCount += 1
                droppedDeliveries &+= 1
                subscriber.consecutiveDrops += 1
                if subscriber.consecutiveDrops >= consecutiveDropLimit {
                    subscriber.continuation.finish()
                    removals.append(id)
                    evictions.append(id)
                    evictedSubscribers &+= 1
                } else {
                    subscribers[id] = subscriber
                }

            case .terminated:
                removals.append(id)

            @unknown default:
                removals.append(id)
            }
        }

        for id in removals {
            subscribers.removeValue(forKey: id)
        }
        return FanoutPublishReport(
            subscriberCount: subscriberCount,
            enqueuedCount: enqueuedCount,
            droppedCount: droppedCount,
            evictedSubscriberIDs: evictions
        )
    }

    public func unsubscribe(id: UUID) {
        guard let subscriber = subscribers.removeValue(forKey: id) else {
            return
        }
        subscriber.continuation.finish()
    }

    public func finish() {
        let current = Array(subscribers.values)
        subscribers.removeAll(keepingCapacity: true)
        for subscriber in current {
            subscriber.continuation.finish()
        }
    }

    public func statistics() -> FanoutStatistics {
        FanoutStatistics(
            activeSubscribers: subscribers.count,
            publishedElements: publishedElements,
            enqueuedDeliveries: enqueuedDeliveries,
            droppedDeliveries: droppedDeliveries,
            evictedSubscribers: evictedSubscribers
        )
    }

    private func removeSubscriber(id: UUID, token: UUID) {
        guard subscribers[id]?.token == token else {
            return
        }
        subscribers.removeValue(forKey: id)
    }
}

extension Int {
    fileprivate var isPowerOfTwo: Bool {
        self > 0 && (self & (self - 1)) == 0
    }
}
