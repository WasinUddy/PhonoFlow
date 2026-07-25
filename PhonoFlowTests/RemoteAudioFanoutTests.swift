import Foundation
import XCTest

@testable import PhonoFlow

@MainActor
final class RemoteAudioFanoutTests: XCTestCase {
    func testClientAndPerAddressCapacityAreBounded() async throws {
        let fanout = RemoteAudioFanout(
            maximumClients: 2,
            maximumClientsPerAddress: 1,
            clock: TestRemoteClock(.testReference)
        )
        let first = try await fanout.subscribe(
            kind: .pcm16Browser,
            principal: principal(id: "one"),
            remoteAddress: "CLIENT-A"
        )

        do {
            _ = try await fanout.subscribe(
                kind: .pcm16Browser,
                principal: principal(id: "two"),
                remoteAddress: "client-a"
            )
            XCTFail("Canonical address should be limited to one stream")
        } catch let error as RemoteAudioSubscriptionError {
            XCTAssertEqual(error, .addressCapacity)
        }

        let second = try await fanout.subscribe(
            kind: .legacyFloat32,
            principal: nil,
            remoteAddress: "client-b"
        )
        do {
            _ = try await fanout.subscribe(
                kind: .legacyFloat32,
                principal: nil,
                remoteAddress: "client-c"
            )
            XCTFail("Third stream should exceed total capacity")
        } catch let error as RemoteAudioSubscriptionError {
            XCTAssertEqual(error, .clientCapacity)
        }

        let count = await fanout.listenerCount()
        XCTAssertEqual(count, 2)
        await first.cancel()
        await second.cancel()
    }

    func testStreamFormatsAreExplicitAndKindsReceiveOnlyMatchingChunks() async throws {
        let fanout = RemoteAudioFanout(
            legacySampleRate: 96_000,
            clock: TestRemoteClock(.testReference)
        )
        let browser = try await fanout.subscribe(
            kind: .pcm16Browser,
            principal: principal(),
            remoteAddress: "browser"
        )
        let legacy = try await fanout.subscribe(
            kind: .legacyFloat32,
            principal: nil,
            remoteAddress: "player"
        )

        XCTAssertEqual(
            browser.format,
            RemoteAudioStreamFormat(encoding: .pcm16, sampleRate: 48_000)
        )
        XCTAssertEqual(
            legacy.format,
            RemoteAudioStreamFormat(encoding: .float32, sampleRate: 96_000)
        )

        var browserIterator = browser.stream.makeAsyncIterator()
        var legacyIterator = legacy.stream.makeAsyncIterator()
        let browserChunk = Data([1, 2, 3, 4])
        let legacyChunk = Data([5, 6, 7, 8])
        await fanout.publishPCM16(browserChunk)
        await fanout.publishLegacyFloat32(legacyChunk)

        let receivedBrowserChunk = await browserIterator.next()
        let receivedLegacyChunk = await legacyIterator.next()
        XCTAssertEqual(receivedBrowserChunk, browserChunk)
        XCTAssertEqual(receivedLegacyChunk, legacyChunk)
        await browser.cancel()
        await legacy.cancel()
    }

    func testSlowClientIsEvictedWhenItsBoundedQueueFills() async throws {
        let fanout = RemoteAudioFanout(
            queueCapacity: 1,
            clock: TestRemoteClock(.testReference)
        )
        let subscription = try await fanout.subscribe(
            kind: .pcm16Browser,
            principal: principal(),
            remoteAddress: "slow"
        )
        var iterator = subscription.stream.makeAsyncIterator()

        await fanout.publishPCM16(Data([1]))
        await fanout.publishPCM16(Data([2]))

        let count = await fanout.listenerCount()
        XCTAssertEqual(count, 0)
        let next = await iterator.next()
        XCTAssertNil(next)
    }

    func testCancellingPendingReadReleasesCapacityWithoutAudio() async throws {
        let fanout = RemoteAudioFanout(
            maximumClients: 1,
            maximumClientsPerAddress: 1,
            clock: TestRemoteClock(.testReference)
        )
        let subscription = try await fanout.subscribe(
            kind: .pcm16Browser,
            principal: principal(),
            remoteAddress: "idle-client"
        )
        let pendingRead = Task { () -> Data? in
            var iterator = subscription.stream.makeAsyncIterator()
            return await iterator.next()
        }

        let installedWaiter = await waitUntil {
            await subscription.stream.hasWaitingConsumer()
        }
        XCTAssertTrue(installedWaiter)

        pendingRead.cancel()
        let releasedCapacity = await waitUntil {
            await fanout.listenerCount() == 0
        }
        if !releasedCapacity {
            await subscription.cancel()
        }
        let cancelledValue = await pendingRead.value

        XCTAssertTrue(releasedCapacity)
        XCTAssertNil(cancelledValue)

        let replacement = try await fanout.subscribe(
            kind: .pcm16Browser,
            principal: principal(id: "replacement"),
            remoteAddress: "idle-client"
        )
        await replacement.cancel()
    }

    func testReadCancellationRacingExplicitCancelIsIdempotent() async throws {
        let fanout = RemoteAudioFanout(
            maximumClients: 1,
            maximumClientsPerAddress: 1,
            clock: TestRemoteClock(.testReference)
        )
        let subscription = try await fanout.subscribe(
            kind: .pcm16Browser,
            principal: principal(),
            remoteAddress: "racing-client"
        )
        let pendingRead = Task { () -> Data? in
            var iterator = subscription.stream.makeAsyncIterator()
            return await iterator.next()
        }

        let installedWaiter = await waitUntil {
            await subscription.stream.hasWaitingConsumer()
        }
        XCTAssertTrue(installedWaiter)

        pendingRead.cancel()
        async let explicitCancellation: Void = subscription.cancel()
        let cancelledValue = await pendingRead.value
        await explicitCancellation

        XCTAssertNil(cancelledValue)
        let listenerCount = await fanout.listenerCount()
        XCTAssertEqual(listenerCount, 0)

        let replacement = try await fanout.subscribe(
            kind: .pcm16Browser,
            principal: principal(id: "replacement"),
            remoteAddress: "racing-client"
        )
        var replacementIterator = replacement.stream.makeAsyncIterator()
        let replacementChunk = Data([0xCA, 0xFE])
        await fanout.publishPCM16(replacementChunk)
        let receivedChunk = await replacementIterator.next()
        XCTAssertEqual(receivedChunk, replacementChunk)
        await replacement.cancel()
    }

    func testMultipleAudioIteratorsDoNotOverwritePendingReads() async throws {
        let fanout = RemoteAudioFanout(
            clock: TestRemoteClock(.testReference)
        )
        let subscription = try await fanout.subscribe(
            kind: .pcm16Browser,
            principal: principal(),
            remoteAddress: "multi-reader"
        )
        let firstRead = Task { () -> Data? in
            var iterator = subscription.stream.makeAsyncIterator()
            return await iterator.next()
        }
        let secondRead = Task { () -> Data? in
            var iterator = subscription.stream.makeAsyncIterator()
            return await iterator.next()
        }
        let bothWaiting = await waitUntil {
            await subscription.stream.waitingConsumerCount() == 2
        }
        XCTAssertTrue(bothWaiting)

        let firstChunk = Data([1])
        let secondChunk = Data([2])
        await fanout.publishPCM16(firstChunk)
        await fanout.publishPCM16(secondChunk)
        let received = [await firstRead.value, await secondRead.value].compactMap {
            $0
        }

        XCTAssertEqual(Set(received), Set([firstChunk, secondChunk]))
        await subscription.cancel()
    }

    func testLegacyRateChangeRevokesStaleStreamsAndKeepsBrowserAudio()
        async throws
    {
        let fanout = RemoteAudioFanout(
            legacySampleRate: 44_100,
            clock: TestRemoteClock(.testReference)
        )
        let legacy = try await fanout.subscribe(
            kind: .legacyFloat32,
            principal: nil,
            remoteAddress: "legacy"
        )
        var legacyIterator = legacy.stream.makeAsyncIterator()
        let browser = try await fanout.subscribe(
            kind: .pcm16Browser,
            principal: principal(),
            remoteAddress: "browser"
        )
        var browserIterator = browser.stream.makeAsyncIterator()

        await fanout.setLegacySampleRate(96_000)

        let closedLegacyChunk = await legacyIterator.next()
        let legacyListenerCount = await fanout.listenerCount(
            kind: .legacyFloat32
        )
        let browserListenerCount = await fanout.listenerCount(
            kind: .pcm16Browser
        )
        XCTAssertNil(closedLegacyChunk)
        XCTAssertEqual(legacyListenerCount, 0)
        XCTAssertEqual(browserListenerCount, 1)

        let browserChunk = Data([3, 4])
        await fanout.publishPCM16(browserChunk)
        let receivedBrowserChunk = await browserIterator.next()
        XCTAssertEqual(receivedBrowserChunk, browserChunk)

        let replacement = try await fanout.subscribe(
            kind: .legacyFloat32,
            principal: nil,
            remoteAddress: "legacy"
        )
        XCTAssertEqual(replacement.format.sampleRate, 96_000)
        await replacement.cancel()
        await browser.cancel()
    }

    func testFanoutDeinitClosesPendingAudioReads() async throws {
        var fanout: RemoteAudioFanout? = RemoteAudioFanout(
            clock: TestRemoteClock(.testReference)
        )
        weak let releasedFanout = fanout
        let subscription = try await XCTUnwrap(fanout).subscribe(
            kind: .pcm16Browser,
            principal: principal(),
            remoteAddress: "deinit"
        )
        let pendingRead = Task { () -> Data? in
            var iterator = subscription.stream.makeAsyncIterator()
            return await iterator.next()
        }
        let installedWaiter = await waitUntil {
            await subscription.stream.waitingConsumerCount() == 1
        }
        XCTAssertTrue(installedWaiter)

        fanout = nil
        let released = await waitUntil {
            releasedFanout == nil
        }
        let closedByDeinit = await waitUntil {
            await subscription.stream.waitingConsumerCount() == 0
        }
        if !closedByDeinit {
            pendingRead.cancel()
        }
        let finalChunk = await pendingRead.value

        XCTAssertTrue(released)
        XCTAssertTrue(closedByDeinit)
        XCTAssertNil(finalChunk)
    }

    func testRevokingSessionClosesOnlyItsAuthenticatedStreams() async throws {
        let fanout = RemoteAudioFanout(clock: TestRemoteClock(.testReference))
        let revoked = try await fanout.subscribe(
            kind: .pcm16Browser,
            principal: principal(id: "revoke-me"),
            remoteAddress: "one"
        )
        let retained = try await fanout.subscribe(
            kind: .pcm16Browser,
            principal: principal(id: "keep-me"),
            remoteAddress: "two"
        )
        var revokedIterator = revoked.stream.makeAsyncIterator()
        var retainedIterator = retained.stream.makeAsyncIterator()

        await fanout.revoke(sessionID: "revoke-me")
        let revokedChunk = await revokedIterator.next()
        XCTAssertNil(revokedChunk)
        let count = await fanout.listenerCount()
        XCTAssertEqual(count, 1)

        let chunk = Data([42])
        await fanout.publishPCM16(chunk)
        let retainedChunk = await retainedIterator.next()
        XCTAssertEqual(retainedChunk, chunk)
        await retained.cancel()
    }

    func testAuthenticatedAudioExpiresWithoutClosingUnauthenticatedLegacyStream() async throws {
        let fanout = RemoteAudioFanout()
        let browser = try await fanout.subscribe(
            kind: .pcm16Browser,
            principal: principal(
                expiresAt: Date().addingTimeInterval(0.1)
            ),
            remoteAddress: "browser"
        )
        let legacy = try await fanout.subscribe(
            kind: .legacyFloat32,
            principal: nil,
            remoteAddress: "player"
        )
        var browserIterator = browser.stream.makeAsyncIterator()
        var legacyIterator = legacy.stream.makeAsyncIterator()

        let browserChunkAfterExpiry = await browserIterator.next()
        let listenerCountAfterExpiry = await fanout.listenerCount()
        XCTAssertNil(browserChunkAfterExpiry)
        XCTAssertEqual(listenerCountAfterExpiry, 1)

        let chunk = Data([0xAA, 0x55])
        await fanout.publishLegacyFloat32(chunk)
        let receivedLegacyChunk = await legacyIterator.next()
        XCTAssertEqual(receivedLegacyChunk, chunk)
        await legacy.cancel()
    }

    func testStreamingPCM16WAVHeaderFields() {
        let header = RemoteWAV.streamingHeader(
            format: RemoteAudioStreamFormat(
                encoding: .pcm16,
                sampleRate: 48_000,
                channelCount: 2
            )
        )

        XCTAssertEqual(header.count, 44)
        XCTAssertEqual(String(data: header[0..<4], encoding: .ascii), "RIFF")
        XCTAssertEqual(littleEndianUInt32(header, at: 4), 0x7FFF_FFFF)
        XCTAssertEqual(String(data: header[8..<12], encoding: .ascii), "WAVE")
        XCTAssertEqual(String(data: header[12..<16], encoding: .ascii), "fmt ")
        XCTAssertEqual(littleEndianUInt32(header, at: 16), 16)
        XCTAssertEqual(littleEndianUInt16(header, at: 20), 1)
        XCTAssertEqual(littleEndianUInt16(header, at: 22), 2)
        XCTAssertEqual(littleEndianUInt32(header, at: 24), 48_000)
        XCTAssertEqual(littleEndianUInt32(header, at: 28), 192_000)
        XCTAssertEqual(littleEndianUInt16(header, at: 32), 4)
        XCTAssertEqual(littleEndianUInt16(header, at: 34), 16)
        XCTAssertEqual(String(data: header[36..<40], encoding: .ascii), "data")
        XCTAssertEqual(littleEndianUInt32(header, at: 40), 0x7FFF_FFFF - 36)
    }

    func testStreamingFloat32WAVHeaderPreservesLegacyFormat() {
        let header = RemoteWAV.streamingHeader(
            format: RemoteAudioStreamFormat(
                encoding: .float32,
                sampleRate: 44_100,
                channelCount: 2
            )
        )

        XCTAssertEqual(littleEndianUInt16(header, at: 20), 3)
        XCTAssertEqual(littleEndianUInt32(header, at: 24), 44_100)
        XCTAssertEqual(littleEndianUInt32(header, at: 28), 352_800)
        XCTAssertEqual(littleEndianUInt16(header, at: 32), 8)
        XCTAssertEqual(littleEndianUInt16(header, at: 34), 32)
    }

    func testPCM16QuantizationClampsRoundsAndSilencesNonFiniteValues() {
        let bytes = RemoteWAV.pcm16Interleaved(
            left: [-1, -0.5, 0, 0.5, 1, .nan],
            right: [1, 0.25, -0.25, .infinity, -.infinity, .nan]
        )
        let decoded = stride(from: 0, to: bytes.count, by: 2).map {
            littleEndianInt16(bytes, at: $0)
        }

        XCTAssertEqual(
            decoded,
            [
                -32_768, 32_767,
                -16_384, 8_192,
                0, -8_192,
                16_384, 0,
                32_767, 0,
                0, 0,
            ]
        )
    }

    func testPCMConversionUsesShortestStereoChannel() {
        let bytes = RemoteWAV.pcm16Interleaved(
            left: [0, 0, 0],
            right: [0]
        )
        XCTAssertEqual(bytes.count, 4)
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
