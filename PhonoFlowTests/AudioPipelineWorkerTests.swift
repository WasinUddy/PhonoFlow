import CoreGraphics
import Darwin
import Foundation
import PhonoFlowCore
import XCTest

@testable import PhonoFlow

@MainActor
final class AudioPipelineWorkerTests: XCTestCase {
    func testProducerGenerationRejectsCallbackPausedAcrossReattachment() throws {
        let gate = PipelineProducerGate()
        gate.setAccepting(true)
        let staleEpoch = try XCTUnwrap(gate.captureEpochIfAccepting())

        gate.closeAndFence()
        gate.setAccepting(true)

        XCTAssertFalse(gate.registerProducer(epoch: staleEpoch))
        let currentEpoch = try XCTUnwrap(gate.captureEpochIfAccepting())
        XCTAssertTrue(gate.registerProducer(epoch: currentEpoch))
        gate.endProducing()
    }

    func testProducerFenceWaitsForARegisteredCallback() throws {
        let gate = PipelineProducerGate()
        gate.setAccepting(true)
        let epoch = try XCTUnwrap(gate.captureEpochIfAccepting())
        XCTAssertTrue(gate.registerProducer(epoch: epoch))

        let closed = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            gate.closeAndFence()
            closed.signal()
        }
        XCTAssertEqual(closed.wait(timeout: .now() + 0.05), .timedOut)

        gate.endProducing()
        XCTAssertEqual(closed.wait(timeout: .now() + 1), .success)
        XCTAssertFalse(gate.isAccepting)
    }

    func testConcurrentConfigurationsAreSerializedAndAcknowledged() async {
        let worker = AudioPipelineWorker()
        let first = expectation(description: "first configuration")
        let second = expectation(description: "second configuration")

        DispatchQueue.global(qos: .userInitiated).async {
            worker.configure(sampleRate: 44_100)
            first.fulfill()
        }
        DispatchQueue.global(qos: .userInitiated).async {
            worker.configure(sampleRate: 96_000)
            second.fulfill()
        }

        await fulfillment(of: [first, second], timeout: 2)
        XCTAssertEqual(worker.analysisQueueDepth, 0)
        XCTAssertEqual(worker.networkQueueDepth, 0)
    }

    func testHiddenAnalysisDoesNoWorkAndOneSecondPublishesLatestFifteenHertzFrame()
        async
    {
        let worker = AudioPipelineWorker()
        worker.configure(sampleRate: 48_000)
        var published: [NativeSpectrogramFrame] = []
        let publication = expectation(description: "coalesced native frame")
        worker.setNativePublisher { frame in
            published.append(frame)
            publication.fulfill()
        }

        let hidden = sineWave(frameCount: 8_192, frequency: 1_000)
        enqueue(worker, left: hidden, right: hidden, blockSizes: [127, 509, 2_048])
        worker.stopAndDrain()

        XCTAssertTrue(published.isEmpty)
        XCTAssertEqual(worker.analysisQueueDepth, 0)
        XCTAssertEqual(worker.analysisDroppedFrames, 0)

        worker.setNativeVisualizationEnabled(true)
        worker.configure(sampleRate: 48_000)
        let visible = sineWave(frameCount: 48_000, frequency: 1_000)
        enqueue(
            worker,
            left: visible,
            right: visible,
            blockSizes: [137, 1_024, 333, 2_048]
        )
        worker.stopAndDrain()

        await fulfillment(of: [publication], timeout: 2)
        let frame = try? XCTUnwrap(published.single)
        XCTAssertEqual(frame?.column.sequence, 13)
        XCTAssertEqual(frame?.column.intensities.count, 64)
        XCTAssertEqual(frame?.image.width, 64)
        XCTAssertEqual(frame?.image.height, 64)
        XCTAssertEqual(
            worker.skippedNativeFrames,
            13,
            "Fourteen 15 Hz columns should collapse to one pending main-actor publish"
        )

        worker.setNativeVisualizationEnabled(false)
        worker.configure(sampleRate: 48_000)
        enqueue(worker, left: hidden, right: hidden, blockSizes: [256])
        worker.stopAndDrain()
        await Task.yield()

        XCTAssertEqual(published.count, 1)
        XCTAssertEqual(worker.analysisQueueDepth, 0)
    }

    func testRemoteSpectrumDemandPublishesWithoutNativeVisualization() async throws {
        let coordinator = FakeRemoteCoordinator()
        let eventHub = RemoteEventHub(clock: TestRemoteClock(.testReference))
        let server = RemoteAccessServer(
            coordinator: coordinator,
            eventHub: eventHub
        )
        let subscription = try await eventHub.subscribe(
            principal: principal(),
            snapshot: .fixture()
        )
        var iterator = subscription.stream.makeAsyncIterator()
        guard case .snapshot = await iterator.next() else {
            await subscription.cancel()
            return XCTFail("Expected the subscription snapshot")
        }

        let worker = AudioPipelineWorker()
        worker.attach(remoteAudio: nil, remoteServer: server)
        worker.setRemoteSpectrumSubscribersVisible(true)
        worker.configure(sampleRate: 48_000)
        let tone = sineWave(frameCount: 7_000, frequency: 10_000)
        enqueue(worker, left: tone, right: tone, blockSizes: [511, 2_048, 73])
        worker.stopAndDrain()

        guard case .spectrum(let column) = await iterator.next() else {
            await subscription.cancel()
            return XCTFail("Expected a remote spectrogram column")
        }
        XCTAssertEqual(column.sequence, 0)
        XCTAssertEqual(column.intensities.count, 64)
        XCTAssertGreaterThan(column.intensities.max() ?? 0, 0)
        XCTAssertEqual(worker.skippedNativeFrames, 0)

        worker.setRemoteSpectrumSubscribersVisible(false)
        worker.attach(remoteAudio: nil, remoteServer: nil)
        await subscription.cancel()
    }

    func testBrowserAndLegacyFanoutReceiveDeterministicWorkerConversions()
        async throws
    {
        let fanout = RemoteAudioFanout(
            maximumClients: 2,
            maximumClientsPerAddress: 2,
            queueCapacity: 2,
            clock: TestRemoteClock(.testReference)
        )
        let worker = AudioPipelineWorker()
        worker.configure(sampleRate: 48_000)
        worker.attach(remoteAudio: fanout, remoteServer: nil)
        worker.setRemoteAudioSubscribersVisible(true)
        worker.setLegacyStreamingEnabled(true)

        let browser = try await fanout.subscribe(
            kind: .pcm16Browser,
            principal: principal(id: "browser"),
            remoteAddress: "browser"
        )
        let legacy = try await fanout.subscribe(
            kind: .legacyFloat32,
            principal: nil,
            remoteAddress: "legacy"
        )
        var browserIterator = browser.stream.makeAsyncIterator()
        var legacyIterator = legacy.stream.makeAsyncIterator()

        let left: [Float] = [0, 0.5, -1, 1]
        let right: [Float] = [1, -0.5, 0, 0.25]
        enqueue(worker, left: left, right: right, blockSizes: [4])
        worker.stopAndDrain()

        let nextBrowserData = await browserIterator.next()
        let browserData = try XCTUnwrap(nextBrowserData)
        XCTAssertEqual(browserData.count, 16)
        XCTAssertEqual(
            stride(from: 0, to: browserData.count, by: 2).map {
                littleEndianInt16(browserData, at: $0)
            },
            [0, 32_767, 16_384, -16_384, -32_768, 0, 32_767, 8_192]
        )

        let nextLegacyData = await legacyIterator.next()
        let legacyData = try XCTUnwrap(nextLegacyData)
        XCTAssertEqual(legacyData.count, 32)
        XCTAssertEqual(
            stride(from: 0, to: legacyData.count, by: 4).map {
                Float(
                    bitPattern: littleEndianUInt32(
                        legacyData,
                        at: $0
                    )
                )
            },
            [0, 1, 0.5, -0.5, -1, 0, 1, 0.25]
        )
        XCTAssertEqual(worker.fanoutQueueDepth, 0)
        XCTAssertEqual(worker.fanoutDroppedFrames, 0)

        worker.setRemoteAudioSubscribersVisible(false)
        worker.attach(remoteAudio: nil, remoteServer: nil)
        await browser.cancel()
        await legacy.cancel()
    }

    func testFanoutRingBoundsAndStopDisableLegacyOnlyDemand() {
        let worker = AudioPipelineWorker()
        worker.attach(remoteAudio: RemoteAudioFanout(), remoteServer: nil)
        worker.setLegacyStreamingEnabled(true)
        let samples = [Float](repeating: 0.25, count: 70_000)

        enqueue(worker, left: samples, right: samples, blockSizes: [samples.count])
        XCTAssertGreaterThanOrEqual(worker.fanoutDroppedFrames, 4_464)
        worker.stopAndDrain()
        XCTAssertEqual(worker.fanoutQueueDepth, 0)

        let dropsAfterStop = worker.fanoutDroppedFrames
        enqueue(worker, left: samples, right: samples, blockSizes: [samples.count])

        XCTAssertEqual(worker.fanoutDroppedFrames, dropsAfterStop)
        XCTAssertEqual(worker.fanoutQueueDepth, 0)
    }

    func testRecorderBoundaryDrainsAcceptedAudioAndRejectsPostDetachFrames() throws {
        let recorder = AudioRecorder()
        let url = try recorder.start(sampleRate: 48_000)
        defer {
            _ = recorder.stop()
            try? FileManager.default.removeItem(at: url)
        }

        let worker = AudioPipelineWorker()
        worker.configure(sampleRate: 48_000)
        worker.setRecorder(recorder)
        let acceptedLeft: [Float] = [-1, -0.5, 0, 0.5]
        let acceptedRight: [Float] = [1, 0.5, 0.25, -0.25]
        enqueue(
            worker,
            left: acceptedLeft,
            right: acceptedRight,
            blockSizes: [1, 3]
        )
        worker.setRecorder(nil)

        let rejected = [Float](repeating: 0.75, count: 4)
        enqueue(worker, left: rejected, right: rejected, blockSizes: [4])
        worker.stopAndDrain()
        let terminalResult = try XCTUnwrap(recorder.stop())
        switch terminalResult {
        case .success(let recording):
            XCTAssertEqual(recording.url, url)
            XCTAssertEqual(recording.frameCount, 4)
            XCTAssertEqual(recording.droppedFrameCount, 0)
        case .failure(let failure):
            XCTFail("Recorder finalization failed: \(failure)")
        }

        let wav = try Data(contentsOf: url)
        XCTAssertEqual(wav.count, 44 + 8 * MemoryLayout<Float>.size)
        XCTAssertEqual(
            stride(from: 44, to: wav.count, by: 4).map {
                Float(bitPattern: littleEndianUInt32(wav, at: $0))
            },
            [-1, 1, -0.5, 0.5, 0, 0.25, 0.5, -0.25]
        )
    }

    func testRecordingLaneOverflowFailsInsteadOfSavingTruncatedWAV() throws {
        let recorder = AudioRecorder()
        let url = try recorder.start(sampleRate: 48_000)
        defer {
            _ = recorder.stop()
            try? FileManager.default.removeItem(at: url)
        }

        let worker = AudioPipelineWorker(ringCapacity: 8)
        worker.setRecorder(recorder)
        let samples = [Float](repeating: 0.25, count: 32)
        enqueue(worker, left: samples, right: samples, blockSizes: [32])
        worker.setRecorder(nil)

        XCTAssertEqual(worker.recordingDroppedFrames, 24)
        let terminal = try XCTUnwrap(recorder.stop())
        guard case .failure(let failure) = terminal else {
            return XCTFail("A recording with upstream loss must not be saved.")
        }
        XCTAssertEqual(failure.phase, .queueOverflow)
        XCTAssertEqual(failure.droppedFrameCount, 24)
    }

    func testRecordingLaneDrainsWithoutWaitingForAnalysisOrNetwork() throws {
        let recorder = AudioRecorder()
        let url = try recorder.start(sampleRate: 48_000)
        defer {
            _ = recorder.stop()
            try? FileManager.default.removeItem(at: url)
        }

        let worker = AudioPipelineWorker(
            analysisBlockDelayNanoseconds: 80_000_000,
            networkBlockDelayNanoseconds: 80_000_000
        )
        worker.configure(sampleRate: 48_000)
        worker.setNativeVisualizationEnabled(true)
        worker.attach(remoteAudio: RemoteAudioFanout(), remoteServer: nil)
        worker.setLegacyStreamingEnabled(true)
        worker.setRecorder(recorder)

        let samples = sineWave(frameCount: 32_768, frequency: 1_000)
        enqueue(
            worker,
            left: samples,
            right: samples,
            blockSizes: [samples.count]
        )
        usleep(20_000)
        XCTAssertGreaterThan(
            worker.analysisQueueDepth,
            0,
            "The test must establish an FFT backlog before fencing recording."
        )
        XCTAssertGreaterThan(
            worker.networkQueueDepth,
            0,
            "The test must establish a network backlog before fencing recording."
        )

        let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        worker.setRecorder(nil)
        let elapsed =
            Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start)
            / 1_000_000_000

        XCTAssertLessThan(
            elapsed,
            0.6,
            "Recorder fencing must not wait for slow FFT or network lanes."
        )
        let terminalResult = try XCTUnwrap(recorder.stop())
        switch terminalResult {
        case .success(let recording):
            XCTAssertEqual(recording.frameCount, UInt64(samples.count))
            XCTAssertEqual(recording.droppedFrameCount, 0)
        case .failure(let failure):
            XCTFail("Recorder finalization failed: \(failure)")
        }

        worker.setNativeVisualizationEnabled(false)
        worker.stopAndDrain()
    }

    func testSpectrogramTimestampStartsAtCaptureInsteadOfWorkerDrain() async throws {
        let worker = AudioPipelineWorker()
        worker.configure(sampleRate: 48_000)
        worker.setNativeVisualizationEnabled(true)
        let publication = expectation(description: "captured timestamp")
        var published: NativeSpectrogramFrame?
        worker.setNativePublisher { frame in
            published = frame
            publication.fulfill()
        }

        let captureTimestamp: UInt64 = 4_000_000_000
        let samples = sineWave(frameCount: 7_000, frequency: 1_000)
        enqueue(
            worker,
            left: samples,
            right: samples,
            blockSizes: [127, 509, 2_048],
            captureStartNanoseconds: captureTimestamp
        )
        worker.stopAndDrain()
        await fulfillment(of: [publication], timeout: 2)

        let frame = try XCTUnwrap(published)
        XCTAssertEqual(
            frame.column.timestampNanoseconds,
            captureTimestamp + 66_666_667,
            "The first 15 Hz column must be based on the first captured sample."
        )
    }

    func testAnalysisOverflowRestartsAtNextAcceptedCaptureTimestamp()
        async throws
    {
        let worker = AudioPipelineWorker(ringCapacity: 7_000)
        worker.configure(sampleRate: 48_000)
        worker.setNativeVisualizationEnabled(true)

        var firstFrame: NativeSpectrogramFrame?
        let firstPublication = expectation(description: "pre-gap spectrum")
        worker.setNativePublisher { frame in
            firstFrame = frame
            firstPublication.fulfill()
        }
        let firstCapture: UInt64 = 4_000_000_000
        let overflowing = sineWave(frameCount: 8_000, frequency: 1_000)
        enqueue(
            worker,
            left: overflowing,
            right: overflowing,
            blockSizes: [8_000],
            captureStartNanoseconds: firstCapture
        )
        worker.stopAndDrain()
        await fulfillment(of: [firstPublication], timeout: 2)

        XCTAssertEqual(worker.analysisDroppedFrames, 1_000)
        XCTAssertEqual(
            firstFrame?.column.timestampNanoseconds,
            firstCapture + 66_666_667
        )

        var resumedFrame: NativeSpectrogramFrame?
        let resumedPublication = expectation(description: "post-gap spectrum")
        worker.setNativePublisher { frame in
            resumedFrame = frame
            resumedPublication.fulfill()
        }
        let resumedCapture: UInt64 = 10_000_000_000
        let resumed = sineWave(frameCount: 7_000, frequency: 1_000)
        enqueue(
            worker,
            left: resumed,
            right: resumed,
            blockSizes: [7_000],
            captureStartNanoseconds: resumedCapture
        )
        worker.stopAndDrain()
        await fulfillment(of: [resumedPublication], timeout: 2)

        XCTAssertEqual(resumedFrame?.column.sequence, 1)
        XCTAssertEqual(
            resumedFrame?.column.timestampNanoseconds,
            resumedCapture + 66_666_667,
            "Post-overflow samples must start a new capture-time epoch."
        )
    }

    func testBrowserResamplingAtEightKilohertzDoesNotTruncateOrStall()
        async throws
    {
        let fanout = RemoteAudioFanout(
            queueCapacity: 8,
            clock: TestRemoteClock(.testReference)
        )
        let browser = try await fanout.subscribe(
            kind: .pcm16Browser,
            principal: principal(id: "low-rate"),
            remoteAddress: "low-rate"
        )
        var iterator = browser.stream.makeAsyncIterator()

        let worker = AudioPipelineWorker()
        worker.configure(sampleRate: 8_000)
        worker.attach(remoteAudio: fanout, remoteServer: nil)
        worker.setRemoteAudioSubscribersVisible(true)
        let first = sineWave(
            frameCount: 2_048,
            frequency: 1_000,
            sampleRate: 8_000
        )
        let second = sineWave(
            frameCount: 2_048,
            frequency: 1_000,
            sampleRate: 8_000
        )
        enqueue(worker, left: first, right: first, blockSizes: [2_048])
        enqueue(worker, left: second, right: second, blockSizes: [2_048])
        worker.stopAndDrain()

        let nextFirstChunk = await iterator.next()
        let firstChunk = try XCTUnwrap(nextFirstChunk)
        let nextSecondChunk = await iterator.next()
        let secondChunk = try XCTUnwrap(nextSecondChunk)
        XCTAssertGreaterThan(firstChunk.count / 4, 8_192)
        XCTAssertGreaterThan(secondChunk.count / 4, 8_192)
        XCTAssertEqual((firstChunk.count + secondChunk.count) / 4, 24_571)

        worker.setRemoteAudioSubscribersVisible(false)
        worker.attach(remoteAudio: nil, remoteServer: nil)
        await browser.cancel()
    }

    private func sineWave(
        frameCount: Int,
        frequency: Double,
        sampleRate: Double = 48_000
    ) -> [Float] {
        (0..<frameCount).map { index in
            Float(
                0.8
                    * sin(
                        2 * Double.pi * frequency * Double(index) / sampleRate
                    )
            )
        }
    }

    private func principal(id: String = "pipeline") -> RemoteSessionPrincipal {
        RemoteSessionPrincipal(
            sessionID: id,
            expiresAt: .testReference.addingTimeInterval(3_600)
        )
    }

    private func enqueue(
        _ worker: AudioPipelineWorker,
        left: [Float],
        right: [Float],
        blockSizes: [Int],
        captureStartNanoseconds: UInt64? = nil
    ) {
        precondition(left.count == right.count)
        precondition(!blockSizes.isEmpty)
        left.withUnsafeBufferPointer { leftBuffer in
            right.withUnsafeBufferPointer { rightBuffer in
                var offset = 0
                var blockIndex = 0
                while offset < left.count {
                    let frameCount = min(
                        blockSizes[blockIndex % blockSizes.count],
                        left.count - offset
                    )
                    worker.enqueue(
                        left: leftBuffer.baseAddress!.advanced(by: offset),
                        right: rightBuffer.baseAddress!.advanced(by: offset),
                        count: frameCount,
                        captureTimestampNanoseconds:
                            captureStartNanoseconds.map {
                                $0
                                    + UInt64(
                                        (Double(offset) / 48_000
                                            * 1_000_000_000).rounded()
                                    )
                            } ?? 0
                    )
                    offset += frameCount
                    blockIndex += 1
                }
            }
        }
    }
}

@MainActor
final class NativeSpectrogramMailboxTests: XCTestCase {
    func testMailboxCoalescesPendingFramesAndDeliversOnlyTheLatest() async throws {
        let mailbox = NativeSpectrogramMailbox()
        var received: [NativeSpectrogramFrame] = []
        let publication = expectation(description: "latest frame")
        mailbox.setPublisher { frame in
            received.append(frame)
            publication.fulfill()
        }

        mailbox.offer(try frame(sequence: 0, intensity: 16))
        mailbox.offer(try frame(sequence: 1, intensity: 96))
        mailbox.offer(try frame(sequence: 2, intensity: 224))

        await fulfillment(of: [publication], timeout: 1)
        XCTAssertEqual(received.map(\.column.sequence), [2])
        XCTAssertEqual(mailbox.skippedFrames, 2)
    }

    func testClearRemovesPendingFrameBeforeMainActorDelivery() async throws {
        let mailbox = NativeSpectrogramMailbox()
        let unexpected = expectation(description: "no delivery after clear")
        unexpected.isInverted = true
        mailbox.setPublisher { _ in
            unexpected.fulfill()
        }

        mailbox.offer(try frame(sequence: 9, intensity: 255))
        mailbox.clear()

        await fulfillment(of: [unexpected], timeout: 0.05)
        XCTAssertEqual(mailbox.skippedFrames, 0)
    }

    func testRendererKeepsOnlySixtyFourColumnsAndMarksBlankHistoryTransparent()
        throws
    {
        let oneColumn = try frame(sequence: 0, intensity: 255).image
        XCTAssertEqual(pixel(in: oneColumn, x: 0, y: 0)[3], 0)
        XCTAssertEqual(pixel(in: oneColumn, x: 63, y: 0)[3], 255)

        let columns = try (0..<65).map { index in
            try SpectrogramColumn(
                sequence: UInt64(index),
                timestampNanoseconds: UInt64(index),
                intensities: [UInt8](
                    repeating: UInt8((index * 4) % 256),
                    count: SpectrogramColumn.intensityCount
                )
            )
        }
        let fullImage = try XCTUnwrap(
            SpectrogramImageRenderer.makeImage(columns: columns)
        )

        XCTAssertEqual(fullImage.width, 64)
        XCTAssertEqual(fullImage.height, 64)
        XCTAssertEqual(pixel(in: fullImage, x: 0, y: 0)[3], 255)
        XCTAssertEqual(pixel(in: fullImage, x: 63, y: 63)[3], 255)
        XCTAssertNotEqual(
            Array(pixel(in: fullImage, x: 0, y: 0).prefix(3)),
            Array(pixel(in: fullImage, x: 63, y: 0).prefix(3))
        )
    }

    private func frame(
        sequence: UInt64,
        intensity: UInt8
    ) throws -> NativeSpectrogramFrame {
        let column = try SpectrogramColumn(
            sequence: sequence,
            timestampNanoseconds: sequence * 1_000,
            intensities: [UInt8](
                repeating: intensity,
                count: SpectrogramColumn.intensityCount
            )
        )
        return NativeSpectrogramFrame(
            column: column,
            image: try XCTUnwrap(
                SpectrogramImageRenderer.makeImage(columns: [column])
            )
        )
    }

    private func pixel(
        in image: CGImage,
        x: Int,
        y: Int
    ) -> ArraySlice<UInt8> {
        let data = image.dataProvider?.data
        let bytes = data.map { Data($0 as Data) } ?? Data()
        let index = (y * image.width + x) * 4
        return Array(bytes[index..<(index + 4)])[...]
    }
}

extension Array {
    fileprivate var single: Element? {
        count == 1 ? first : nil
    }
}
