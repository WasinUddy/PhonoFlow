import Foundation
import Testing

@testable import PhonoFlowCore

@Suite("Bounded SPSC buffer")
struct BoundedSPSCBufferTests {
    @Test("Capacity must be a positive power of two")
    func capacityValidation() {
        for capacity in [-1, 0, 3, 6] {
            #expect(
                throws: BoundedBufferError.capacityMustBePositivePowerOfTwo(capacity)
            ) {
                try BoundedSPSCBuffer<Int>(capacity: capacity)
            }
        }
        #expect(throws: Never.self) {
            _ = try BoundedSPSCBuffer<Int>(capacity: 8)
        }
    }

    @Test("FIFO behavior includes exact capacity and wraparound")
    func fifoAndWraparound() throws {
        let buffer = try BoundedSPSCBuffer<Int>(capacity: 4)
        for value in 0..<4 {
            #expect(buffer.offer(value))
        }
        #expect(!buffer.offer(99))
        #expect(buffer.poll() == 0)
        #expect(buffer.poll() == 1)
        #expect(buffer.offer(4))
        #expect(buffer.offer(5))
        #expect(
            [buffer.poll(), buffer.poll(), buffer.poll(), buffer.poll()] == [
                2, 3, 4, 5,
            ])
        #expect(buffer.poll() == nil)

        let statistics = buffer.statistics()
        #expect(statistics.approximateCount == 0)
        #expect(statistics.overflowEvents == 1)
        #expect(statistics.droppedElements == 1)
        #expect(statistics.underflowEvents == 1)
    }

    @Test("Block writes are all-or-nothing and reads preserve order")
    func blockOperations() throws {
        let buffer = try BoundedSPSCBuffer<Int>(capacity: 8)
        let first = [0, 1, 2, 3, 4, 5]
        let second = [6, 7, 8]

        #expect(first.withUnsafeBufferPointer { buffer.write($0) } == 6)
        #expect(second.withUnsafeBufferPointer { buffer.write($0) } == 0)

        var destination = [Int](repeating: -1, count: 4)
        let read = destination.withUnsafeMutableBufferPointer {
            buffer.read(into: $0)
        }
        #expect(read == 4)
        #expect(destination == [0, 1, 2, 3])
        #expect(second.withUnsafeBufferPointer { buffer.write($0) } == 3)

        var remainder = [Int](repeating: -1, count: 5)
        #expect(
            remainder.withUnsafeMutableBufferPointer { buffer.read(into: $0) } == 5
        )
        #expect(remainder == [4, 5, 6, 7, 8])
        #expect(buffer.statistics().droppedElements == 3)
    }

    @Test("One producer and one consumer safely traverse many wraps")
    func concurrentStress() async throws {
        let buffer = try BoundedSPSCBuffer<Int>(capacity: 256)
        let count = 50_000

        async let producer: Void = Task.detached {
            for value in 0..<count {
                while !buffer.offer(value) {
                    await Task.yield()
                }
            }
        }.value

        async let consumer: [Int] = Task.detached {
            var result: [Int] = []
            result.reserveCapacity(count)
            while result.count < count {
                if let value = buffer.poll() {
                    result.append(value)
                } else {
                    await Task.yield()
                }
            }
            return result
        }.value

        _ = await producer
        let values = await consumer
        #expect(values == Array(0..<count))
        #expect(buffer.statistics().approximateCount == 0)
    }
}

@Suite("Bounded fanout")
struct BoundedFanoutTests {
    @Test("Subscribers receive independent ordered streams")
    func multicast() async {
        let fanout = BoundedFanout<Int>(bufferCapacity: 4)
        let first = await fanout.subscribe()
        let second = await fanout.subscribe()

        _ = await fanout.publish(10)
        _ = await fanout.publish(20)

        var firstIterator = first.stream.makeAsyncIterator()
        var secondIterator = second.stream.makeAsyncIterator()
        #expect(await firstIterator.next() == 10)
        #expect(await firstIterator.next() == 20)
        #expect(await secondIterator.next() == 10)
        #expect(await secondIterator.next() == 20)

        let statistics = await fanout.statistics()
        #expect(statistics.activeSubscribers == 2)
        #expect(statistics.publishedElements == 2)
        #expect(statistics.enqueuedDeliveries == 4)
        #expect(statistics.droppedDeliveries == 0)
        await fanout.finish()
    }

    @Test("A stalled subscriber is bounded and then evicted")
    func slowSubscriberEviction() async {
        let fanout = BoundedFanout<Int>(
            bufferCapacity: 1,
            consecutiveDropLimit: 2
        )
        let subscription = await fanout.subscribe()

        let first = await fanout.publish(1)
        let second = await fanout.publish(2)
        let third = await fanout.publish(3)

        #expect(first.enqueuedCount == 1)
        #expect(second.droppedCount == 1)
        #expect(second.evictedSubscriberIDs.isEmpty)
        #expect(third.droppedCount == 1)
        #expect(third.evictedSubscriberIDs == [subscription.id])

        let statistics = await fanout.statistics()
        #expect(statistics.activeSubscribers == 0)
        #expect(statistics.droppedDeliveries == 2)
        #expect(statistics.evictedSubscribers == 1)
    }

    @Test("Replacing an ID cannot be removed by the old termination callback")
    func replacementGeneration() async {
        let fanout = BoundedFanout<Int>(bufferCapacity: 2)
        let id = UUID()
        let old = await fanout.subscribe(id: id)
        _ = old
        let replacement = await fanout.subscribe(id: id)

        for _ in 0..<8 {
            await Task.yield()
        }
        #expect(await fanout.statistics().activeSubscribers == 1)
        _ = await fanout.publish(42)
        var iterator = replacement.stream.makeAsyncIterator()
        #expect(await iterator.next() == 42)
        await fanout.finish()
    }

    @Test("Unsubscribe finishes a stream and updates subscriber count")
    func unsubscribe() async {
        let fanout = BoundedFanout<Int>(bufferCapacity: 2)
        let subscription = await fanout.subscribe()
        await fanout.unsubscribe(id: subscription.id)

        var iterator = subscription.stream.makeAsyncIterator()
        #expect(await iterator.next() == nil)
        #expect(await fanout.statistics().activeSubscribers == 0)
    }
}
