import Foundation
import XCTest

@testable import PhonoFlow

@MainActor
final class RemoteEventHubTests: XCTestCase {
    func testSubscriptionAlwaysStartsWithFullSnapshot() async throws {
        let hub = RemoteEventHub(
            maximumClients: 1,
            clock: TestRemoteClock(.testReference)
        )
        let snapshot = RemoteStateSnapshot.fixture(revision: 41)
        let subscription = try await hub.subscribe(
            principal: principal(),
            snapshot: snapshot
        )
        var iterator = subscription.stream.makeAsyncIterator()

        let event = await iterator.next()

        guard case .snapshot(let received) = event else {
            await subscription.cancel()
            return XCTFail("First event was not a snapshot")
        }
        XCTAssertEqual(received, snapshot)
        let count = await hub.clientCount
        XCTAssertEqual(count, 1)
        await subscription.cancel()
        let finalCount = await hub.clientCount
        XCTAssertEqual(finalCount, 0)
    }

    func testClientCapacityIsBounded() async throws {
        let hub = RemoteEventHub(
            maximumClients: 1,
            clock: TestRemoteClock(.testReference)
        )
        let first = try await hub.subscribe(
            principal: principal(id: "one"),
            snapshot: .fixture()
        )

        do {
            _ = try await hub.subscribe(
                principal: principal(id: "two"),
                snapshot: .fixture()
            )
            XCTFail("Second subscription should exceed capacity")
        } catch is RemoteEventCapacityError {
            // Expected.
        }

        await first.cancel()
    }

    func testCapacityIsBoundedPerSessionAndSource() async throws {
        let hub = RemoteEventHub(
            maximumClients: 4,
            maximumClientsPerSession: 1,
            maximumClientsPerAddress: 2,
            clock: TestRemoteClock(.testReference)
        )
        let first = try await hub.subscribe(
            principal: principal(id: "session-one"),
            snapshot: .fixture(),
            remoteAddress: "CLIENT-A"
        )

        do {
            _ = try await hub.subscribe(
                principal: principal(id: "session-one"),
                snapshot: .fixture(),
                remoteAddress: "client-b"
            )
            XCTFail("One session must not consume every SSE slot")
        } catch let error as RemoteEventCapacityError {
            XCTAssertEqual(error, .sessionCapacity)
        }

        let second = try await hub.subscribe(
            principal: principal(id: "session-two"),
            snapshot: .fixture(),
            remoteAddress: "client-a"
        )
        do {
            _ = try await hub.subscribe(
                principal: principal(id: "session-three"),
                snapshot: .fixture(),
                remoteAddress: "client-a"
            )
            XCTFail("One source must not consume every SSE slot")
        } catch let error as RemoteEventCapacityError {
            XCTAssertEqual(error, .sourceCapacity)
        }

        let third = try await hub.subscribe(
            principal: principal(id: "session-three"),
            snapshot: .fixture(),
            remoteAddress: "client-b"
        )
        let fourth = try await hub.subscribe(
            principal: principal(id: "session-four"),
            snapshot: .fixture(),
            remoteAddress: "client-c"
        )
        do {
            _ = try await hub.subscribe(
                principal: principal(id: "session-five"),
                snapshot: .fixture(),
                remoteAddress: "client-d"
            )
            XCTFail("The global SSE capacity must remain bounded")
        } catch let error as RemoteEventCapacityError {
            XCTAssertEqual(error, .clientCapacity)
        }

        await first.cancel()
        await second.cancel()
        await third.cancel()
        await fourth.cancel()
    }

    func testCancellingPendingEventReadReleasesCapacity() async throws {
        let hub = RemoteEventHub(
            maximumClients: 1,
            maximumClientsPerSession: 1,
            maximumClientsPerAddress: 1,
            clock: TestRemoteClock(.testReference)
        )
        let subscription = try await hub.subscribe(
            principal: principal(),
            snapshot: .fixture(),
            remoteAddress: "idle-client"
        )
        var initialIterator = subscription.stream.makeAsyncIterator()
        guard case .snapshot = await initialIterator.next() else {
            return XCTFail("Expected the initial snapshot")
        }
        let pendingRead = Task { () -> RemoteServerEvent? in
            var iterator = subscription.stream.makeAsyncIterator()
            return await iterator.next()
        }

        let installedWaiter = await waitUntil {
            await subscription.stream.waitingConsumerCount() == 1
        }
        XCTAssertTrue(installedWaiter)

        pendingRead.cancel()
        let releasedCapacity = await waitUntil {
            await hub.clientCount == 0
        }
        if !releasedCapacity {
            await subscription.cancel()
        }
        let cancelledEvent = await pendingRead.value

        XCTAssertTrue(releasedCapacity)
        XCTAssertNil(cancelledEvent)
        let replacement = try await hub.subscribe(
            principal: principal(id: "replacement"),
            snapshot: .fixture(),
            remoteAddress: "idle-client"
        )
        await replacement.cancel()
    }

    func testMultipleEventIteratorsDoNotOverwritePendingReads() async throws {
        let hub = RemoteEventHub(clock: TestRemoteClock(.testReference))
        let subscription = try await hub.subscribe(
            principal: principal(),
            snapshot: .fixture(revision: 1)
        )
        var initialIterator = subscription.stream.makeAsyncIterator()
        _ = await initialIterator.next()

        let firstRead = Task { () -> RemoteServerEvent? in
            var iterator = subscription.stream.makeAsyncIterator()
            return await iterator.next()
        }
        let secondRead = Task { () -> RemoteServerEvent? in
            var iterator = subscription.stream.makeAsyncIterator()
            return await iterator.next()
        }
        let bothWaiting = await waitUntil {
            await subscription.stream.waitingConsumerCount() == 2
        }
        XCTAssertTrue(bothWaiting)

        await hub.publish(snapshot: .fixture(revision: 2))
        await hub.publish(snapshot: .fixture(revision: 3))
        let received = [await firstRead.value, await secondRead.value].compactMap {
            event -> UInt64? in
            guard case .state(let snapshot) = event else { return nil }
            return snapshot.revision
        }

        XCTAssertEqual(Set(received), Set([2, 3]))
        await subscription.cancel()
    }

    func testHubDeinitClosesPendingEventReads() async throws {
        var hub: RemoteEventHub? = RemoteEventHub(
            clock: TestRemoteClock(.testReference)
        )
        weak let releasedHub = hub
        let subscription = try await XCTUnwrap(hub).subscribe(
            principal: principal(),
            snapshot: .fixture()
        )
        var initialIterator = subscription.stream.makeAsyncIterator()
        _ = await initialIterator.next()
        let pendingRead = Task { () -> RemoteServerEvent? in
            var iterator = subscription.stream.makeAsyncIterator()
            return await iterator.next()
        }
        let installedWaiter = await waitUntil {
            await subscription.stream.waitingConsumerCount() == 1
        }
        XCTAssertTrue(installedWaiter)

        hub = nil
        let released = await waitUntil {
            releasedHub == nil
        }
        let closedByDeinit = await waitUntil {
            await subscription.stream.waitingConsumerCount() == 0
        }
        if !closedByDeinit {
            pendingRead.cancel()
        }
        let finalEvent = await pendingRead.value

        XCTAssertTrue(released)
        XCTAssertTrue(closedByDeinit)
        XCTAssertNil(finalEvent)
    }

    func testMeterAndSpectrumCadenceUsesEventTimestampsWithoutWallClockWaiting() async throws {
        let hub = RemoteEventHub(clock: TestRemoteClock(.testReference))
        let subscription = try await hub.subscribe(
            principal: principal(),
            snapshot: .fixture()
        )
        var iterator = subscription.stream.makeAsyncIterator()
        _ = await iterator.next()
        let base = Date.testReference

        await hub.publish(
            meters: RemoteMeterSnapshot(
                left: 0.1,
                right: 0.2,
                peak: 0.2,
                sequence: 10,
                timestamp: base
            )
        )
        guard case .meters(let firstMeter) = await iterator.next() else {
            await subscription.cancel()
            return XCTFail("Expected first meter event")
        }
        XCTAssertEqual(firstMeter.sequence, 10)

        await hub.publish(
            meters: RemoteMeterSnapshot(
                left: 0.3,
                right: 0.4,
                peak: 0.4,
                sequence: 11,
                timestamp: base.addingTimeInterval(0.05)
            )
        )
        await hub.publish(
            meters: RemoteMeterSnapshot(
                left: 0.5,
                right: 0.6,
                peak: 0.6,
                sequence: 12,
                timestamp: base.addingTimeInterval(0.11)
            )
        )
        guard case .meters(let nextMeter) = await iterator.next() else {
            await subscription.cancel()
            return XCTFail("Expected cadence-qualified meter event")
        }
        XCTAssertEqual(nextMeter.sequence, 12)

        await hub.publish(
            spectrogram: RemoteSpectrogramColumn(
                sequence: 20,
                timestamp: base,
                intensities: Array(repeating: 10, count: 64)
            )
        )
        guard case .spectrum(let firstSpectrum) = await iterator.next() else {
            await subscription.cancel()
            return XCTFail("Expected first spectrum event")
        }
        XCTAssertEqual(firstSpectrum.sequence, 20)

        await hub.publish(
            spectrogram: RemoteSpectrogramColumn(
                sequence: 21,
                timestamp: base.addingTimeInterval(0.01),
                intensities: Array(repeating: 20, count: 64)
            )
        )
        await hub.publish(
            spectrogram: RemoteSpectrogramColumn(
                sequence: 22,
                timestamp: base.addingTimeInterval(0.07),
                intensities: Array(repeating: 30, count: 64)
            )
        )
        guard case .spectrum(let nextSpectrum) = await iterator.next() else {
            await subscription.cancel()
            return XCTFail("Expected cadence-qualified spectrum event")
        }
        XCTAssertEqual(nextSpectrum.sequence, 22)
        XCTAssertEqual(nextSpectrum.intensities.count, 64)

        await subscription.cancel()
    }

    func testSpectrumRejectsColumnsThatAreNotExactly64Bytes() async throws {
        let hub = RemoteEventHub(clock: TestRemoteClock(.testReference))
        let subscription = try await hub.subscribe(
            principal: principal(),
            snapshot: .fixture()
        )
        var iterator = subscription.stream.makeAsyncIterator()
        _ = await iterator.next()

        await hub.publish(
            spectrogram: RemoteSpectrogramColumn(
                sequence: 1,
                timestamp: .testReference,
                intensities: Array(repeating: 1, count: 63)
            )
        )
        await hub.publish(
            spectrogram: RemoteSpectrogramColumn(
                sequence: 2,
                timestamp: .testReference,
                intensities: Array(0..<64)
            )
        )

        guard case .spectrum(let column) = await iterator.next() else {
            await subscription.cancel()
            return XCTFail("Expected valid spectrum")
        }
        XCTAssertEqual(column.sequence, 2)
        XCTAssertEqual(column.intensities, Array(0..<64))
        await subscription.cancel()
    }

    func testAuthenticatedEventStreamClosesWhenSessionExpires() async throws {
        let hub = RemoteEventHub()
        let subscription = try await hub.subscribe(
            principal: principal(
                expiresAt: Date().addingTimeInterval(0.1)
            ),
            snapshot: .fixture()
        )
        var iterator = subscription.stream.makeAsyncIterator()

        guard case .snapshot = await iterator.next() else {
            return XCTFail("Expected the initial snapshot")
        }
        let eventAfterExpiry = await iterator.next()
        let clientCount = await hub.clientCount
        XCTAssertNil(eventAfterExpiry)
        XCTAssertEqual(clientCount, 0)
    }

    func testMailboxCoalescesContinuousEventsToLatestValue() async {
        let mailbox = RemoteEventMailbox(
            controlCapacity: 2,
            maximumConsecutiveDrops: 10
        )
        let first = RemoteMeterSnapshot(
            left: 0,
            right: 0,
            peak: 0,
            sequence: 1,
            timestamp: .testReference
        )
        var second = first
        second.sequence = 2

        let acceptedFirst = await mailbox.enqueue(.meters(first))
        let acceptedSecond = await mailbox.enqueue(.meters(second))
        XCTAssertTrue(acceptedFirst)
        XCTAssertTrue(acceptedSecond)

        guard case .meters(let delivered) = await mailbox.next() else {
            return XCTFail("Expected a coalesced meter event")
        }
        XCTAssertEqual(delivered.sequence, 2)
        await mailbox.close()
    }

    func testRepeatedSlowClientDropsCloseBoundedMailbox() async {
        let mailbox = RemoteEventMailbox(
            controlCapacity: 1,
            maximumConsecutiveDrops: 2
        )
        let first = await mailbox.enqueue(.snapshot(.fixture(revision: 1)))
        let second = await mailbox.enqueue(.state(.fixture(revision: 2)))
        let third = await mailbox.enqueue(.state(.fixture(revision: 3)))

        XCTAssertTrue(first)
        XCTAssertTrue(second)
        XCTAssertFalse(third)
        let event = await mailbox.next()
        XCTAssertNil(event)
    }

    func testServerSentEventEncodingIncludesIDNameAnd64BytePayload() throws {
        let expected = RemoteSpectrogramColumn(
            sequence: 99,
            timestamp: .testReference,
            intensities: Array(0..<64)
        )
        let bytes = try RemoteServerEvent.spectrum(expected).serverSentEventData()
        let text = try XCTUnwrap(String(data: bytes, encoding: .utf8))

        XCTAssertTrue(text.hasPrefix("id: 99\nevent: spectrogram\ndata: "))
        XCTAssertTrue(text.hasSuffix("\n\n"))
        let dataLine = try XCTUnwrap(
            text.split(separator: "\n")
                .first { $0.hasPrefix("data: ") }
        )
        let payload = Data(dataLine.dropFirst("data: ".count).utf8)
        let decoded = try RemoteJSON.decoder().decode(
            RemoteSpectrogramColumn.self,
            from: payload
        )
        XCTAssertEqual(decoded, expected)
    }

    private func principal(
        id: String = "session",
        expiresAt: Date = .testReference.addingTimeInterval(3_600)
    ) -> RemoteSessionPrincipal {
        RemoteSessionPrincipal(
            sessionID: id,
            expiresAt: expiresAt
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        predicate: () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        repeat {
            if await predicate() {
                return true
            }
            await Task.yield()
        } while clock.now < deadline
        return false
    }
}
