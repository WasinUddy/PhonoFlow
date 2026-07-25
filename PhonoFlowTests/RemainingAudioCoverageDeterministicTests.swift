import CoreGraphics
import Foundation
import XCTest

@testable import PhonoFlow

final class RemainingRecorderCoverageDeterministicTests: XCTestCase {
    func testProductionFileSystemSinkLifecycleAndClosedErrors() throws {
        let sandbox = try TemporaryRecordingSandbox()
        defer { sandbox.remove() }
        let fileSystem = sandbox.makeFileSystem()
        let created = try fileSystem.createRecordingFile()
        defer {
            try? created.sink.close()
            try? fileSystem.removeRecordingFile(at: created.url)
        }

        XCTAssertTrue(created.url.path.hasPrefix(sandbox.rootURL.path))
        XCTAssertEqual(
            created.url.deletingLastPathComponent(),
            sandbox.rootURL
                .appendingPathComponent("PhonoFlow", isDirectory: true)
                .appendingPathComponent("Recordings", isDirectory: true)
        )
        XCTAssertEqual(created.url.pathExtension, "wav")

        try created.sink.write(Data([0x10, 0x20, 0x30, 0x40]))
        try created.sink.seek(toOffset: 1)
        try created.sink.write(Data([0xAA, 0xBB]))
        try created.sink.truncate(atOffset: 3)
        try created.sink.synchronize()
        try created.sink.close()
        try created.sink.close()

        XCTAssertThrowsError(try created.sink.write(Data([0xFF])))
        XCTAssertThrowsError(try created.sink.seek(toOffset: 0))
        XCTAssertThrowsError(try created.sink.truncate(atOffset: 0))
        XCTAssertThrowsError(try created.sink.synchronize())

        let bytes = try Data(contentsOf: created.url)
        XCTAssertEqual(bytes, Data([0x10, 0xAA, 0xBB]))
        try fileSystem.removeRecordingFile(at: created.url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: created.url.path))
        try fileSystem.removeRecordingFile(at: created.url)
    }

    func testProductionFileSystemQuarantineUsesCollisionSafeSuffix() throws {
        let sandbox = try TemporaryRecordingSandbox()
        defer { sandbox.remove() }
        let manager = sandbox.fileManager
        let directory = sandbox.rootURL

        let original = directory.appendingPathComponent("capture.wav")
        let collision = directory.appendingPathComponent(
            "capture.incomplete.corrupt"
        )
        try Data([1, 2, 3]).write(to: original)
        try Data([9]).write(to: collision)

        let quarantined = try sandbox.makeFileSystem()
            .quarantineRecordingFile(at: original)

        XCTAssertEqual(
            quarantined.lastPathComponent,
            "capture.incomplete-2.corrupt"
        )
        XCTAssertEqual(try Data(contentsOf: quarantined), Data([1, 2, 3]))
        XCTAssertFalse(manager.fileExists(atPath: original.path))
    }

    func testRecorderResultAndErrorDescriptionsCoverEveryTerminalPhase() {
        let url = URL(fileURLWithPath: "/tmp/coverage-recording.wav")
        let phases: [AudioRecorder.TerminalFailure.Phase] = [
            .initialHeaderWrite,
            .audioWrite,
            .queueOverflow,
            .truncate,
            .headerWrite,
            .synchronize,
            .close,
            .workerCompletion,
        ]

        for phase in phases {
            let failure = AudioRecorder.TerminalFailure(
                phase: phase,
                fileURL: url,
                reason: "fixture",
                disposition: .removed,
                droppedFrameCount: 0
            )
            XCTAssertTrue(
                failure.localizedDescription.hasPrefix(
                    "Recording failed while"
                )
            )
        }

        let quarantinedURL = URL(
            fileURLWithPath: "/tmp/coverage-recording.incomplete.corrupt"
        )
        let quarantined = AudioRecorder.TerminalFailure(
            phase: .audioWrite,
            fileURL: url,
            reason: "fixture",
            disposition: .quarantined(quarantinedURL),
            droppedFrameCount: 2
        )
        XCTAssertTrue(
            quarantined.localizedDescription.contains(
                quarantinedURL.lastPathComponent
            )
        )

        let cleanupFailed = AudioRecorder.TerminalFailure(
            phase: .close,
            fileURL: url,
            reason: "fixture",
            disposition: .cleanupFailed(
                originalURL: url,
                reason: "fixture"
            ),
            droppedFrameCount: 3
        )
        XCTAssertTrue(
            cleanupFailed.localizedDescription.contains("do not use")
        )

        let recorderErrors: [AudioRecorder.RecorderError] = [
            .alreadyRecording,
            .cannotCreateFile,
            .initializationFailed(quarantined),
            .invalidSampleRate,
        ]
        for error in recorderErrors {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }

        let empty = AudioRecorder.CompletedRecording(
            url: url,
            frameCount: 10,
            droppedFrameCount: 0,
            sampleRate: 0
        )
        XCTAssertEqual(empty.durationSeconds, 0)
    }

    func testMaximumSampleRateSaturatesWAVByteRate() throws {
        let sandbox = try TemporaryRecordingSandbox()
        defer { sandbox.remove() }
        let recorder = AudioRecorder(fileSystem: sandbox.makeFileSystem())
        let url = try recorder.start(sampleRate: Double(UInt32.max))
        defer {
            _ = recorder.stop()
        }

        XCTAssertTrue(url.path.hasPrefix(sandbox.rootURL.path))
        let samples: [Float] = [0, 0]
        samples.withUnsafeBufferPointer { buffer in
            recorder.write(buffer.baseAddress!, frameCount: 0)
            recorder.write(buffer.baseAddress!, frameCount: 1)
        }

        let terminalResult = try XCTUnwrap(recorder.stop())
        let completed = try terminalResult.get()
        XCTAssertEqual(completed.frameCount, 1)
        let wav = try Data(contentsOf: url)
        XCTAssertEqual(readLittleEndianUInt32(wav, at: 24), UInt32.max)
        XCTAssertEqual(readLittleEndianUInt32(wav, at: 28), UInt32.max)
    }
}

@MainActor
final class RemainingPipelineCoverageDeterministicTests: XCTestCase {
    func testBrowserLaneResamplesAcrossBlocksAndQuantizesEdgeValues()
        async throws
    {
        let fanout = RemoteAudioFanout(
            queueCapacity: 8,
            clock: TestRemoteClock(.testReference)
        )
        let subscription = try await fanout.subscribe(
            kind: .pcm16Browser,
            principal: coveragePrincipal(),
            remoteAddress: "browser"
        )

        let worker = AudioPipelineWorker()
        defer {
            worker.setRemoteAudioSubscribersVisible(false)
            worker.attach(remoteAudio: nil, remoteServer: nil)
        }
        worker.attach(remoteAudio: fanout, remoteServer: nil)
        worker.setRemoteAudioSubscribersVisible(true)
        worker.configure(sampleRate: 44_100)
        worker.configure(sampleRate: .nan)
        worker.configure(sampleRate: 0)
        worker.configure(sampleRate: .infinity)

        let sampleCount = 4_096
        let left = (0..<sampleCount).map {
            Float(sin(2 * Double.pi * Double($0) / 97))
        }
        let right = left.map { -$0 }
        enqueuePipeline(worker, left: left, right: right)
        worker.stopAndDrain()

        let first: Data
        let second: Data
        do {
            let nextFirst = try await boundedNext(from: subscription)
            first = try XCTUnwrap(nextFirst)
            let nextSecond = try await boundedNext(from: subscription)
            second = try XCTUnwrap(nextSecond)
        } catch {
            await subscription.cancel()
            throw error
        }
        let resampledFrameCount = (first.count + second.count) / 4
        XCTAssertTrue((4_457...4_459).contains(resampledFrameCount))

        worker.configure(sampleRate: 48_000)
        let edgeLeft: [Float] = [.nan, -2, 2, 0.5]
        let edgeRight: [Float] = [.infinity, -.infinity, -0.5, 0]
        enqueuePipeline(worker, left: edgeLeft, right: edgeRight)
        worker.stopAndDrain()

        let edgeBytes: Data
        do {
            let nextEdgeBytes = try await boundedNext(from: subscription)
            edgeBytes = try XCTUnwrap(nextEdgeBytes)
        } catch {
            await subscription.cancel()
            throw error
        }
        XCTAssertEqual(
            stride(from: 0, to: edgeBytes.count, by: 2).map {
                readLittleEndianInt16(edgeBytes, at: $0)
            },
            [0, 0, -32_768, 0, 32_767, -16_384, 16_384, 0]
        )

        await subscription.cancel()
    }

    func testClearNativeHistoryCanPrecedeAndFollowAnalysis() async throws {
        let worker = AudioPipelineWorker()
        worker.clearNativeHistory()
        worker.configure(sampleRate: 48_000)
        worker.setNativeVisualizationEnabled(true)

        var fullHistoryFrame: NativeSpectrogramFrame?
        let fullHistoryPublication = expectation(
            description: "full native spectrum history"
        )
        worker.setNativePublisher { frame in
            fullHistoryFrame = frame
            fullHistoryPublication.fulfill()
        }
        let samples = [Float](repeating: 0.25, count: 48_000)
        for _ in 0..<5 {
            enqueuePipeline(worker, left: samples, right: samples)
            worker.stopAndDrain()
        }

        await fulfillment(of: [fullHistoryPublication], timeout: 2)
        let fullFrame = try XCTUnwrap(fullHistoryFrame)
        XCTAssertGreaterThanOrEqual(fullFrame.column.sequence, 64)
        XCTAssertEqual(fullFrame.image.width, 64)
        XCTAssertEqual(fullFrame.image.height, 64)
        XCTAssertEqual(alpha(in: fullFrame.image, x: 0, y: 0), 255)
        XCTAssertEqual(alpha(in: fullFrame.image, x: 63, y: 63), 255)
        XCTAssertGreaterThan(worker.skippedNativeFrames, 0)
        XCTAssertEqual(worker.analysisDroppedFrames, 0)

        worker.clearNativeHistory()
        var clearedHistoryFrame: NativeSpectrogramFrame?
        let clearedHistoryPublication = expectation(
            description: "cleared native spectrum history"
        )
        worker.setNativePublisher { frame in
            clearedHistoryFrame = frame
            clearedHistoryPublication.fulfill()
        }
        let shortSamples = [Float](repeating: 0.5, count: 7_000)
        enqueuePipeline(
            worker,
            left: shortSamples,
            right: shortSamples
        )
        worker.stopAndDrain()
        await fulfillment(of: [clearedHistoryPublication], timeout: 2)

        let clearedFrame = try XCTUnwrap(clearedHistoryFrame)
        XCTAssertEqual(alpha(in: clearedFrame.image, x: 0, y: 0), 0)
        XCTAssertEqual(alpha(in: clearedFrame.image, x: 63, y: 63), 255)

        worker.setNativeVisualizationEnabled(false)
        worker.stopAndDrain()
        XCTAssertEqual(worker.analysisQueueDepth, 0)
        XCTAssertEqual(worker.recordingQueueDepth, 0)
        XCTAssertEqual(worker.networkQueueDepth, 0)
        XCTAssertEqual(worker.analysisDroppedFrames, 0)
    }
}

@MainActor
final class RemainingFanoutCoverageDeterministicTests: XCTestCase {
    func testMailboxDirectDeliveryQueueOverflowAndIdempotentClose()
        async throws
    {
        let waitingMailbox = RemoteAudioMailbox(capacity: 1)
        let waiting = Task { await waitingMailbox.next() }
        try await waitForMailboxWaiter(waitingMailbox)
        let delivered = await waitingMailbox.enqueue(Data([0x11]))
        XCTAssertTrue(delivered)
        let waitingValue = try await withCoverageDeadline(
            onTimeout: { await waitingMailbox.close() },
            operation: { await waiting.value }
        )
        XCTAssertEqual(waitingValue, Data([0x11]))

        let queuedMailbox = RemoteAudioMailbox(capacity: 0)
        let queued = await queuedMailbox.enqueue(Data([0x22]))
        XCTAssertTrue(queued)
        let queuedValue = await queuedMailbox.next()
        XCTAssertEqual(queuedValue, Data([0x22]))
        let filled = await queuedMailbox.enqueue(Data([0x33]))
        XCTAssertTrue(filled)
        let overflowed = await queuedMailbox.enqueue(Data([0x44]))
        XCTAssertFalse(overflowed)
        let overflowValue = await queuedMailbox.next()
        XCTAssertNil(overflowValue)
        await queuedMailbox.close()
        let closedEnqueue = await queuedMailbox.enqueue(Data([0x55]))
        XCTAssertFalse(closedEnqueue)
    }

    func testCancelledIteratorClosesMailboxAndPublishEvictsClient()
        async throws
    {
        let fanout = RemoteAudioFanout(clock: TestRemoteClock(.testReference))
        let subscription = try await fanout.subscribe(
            kind: .pcm16Browser,
            principal: coveragePrincipal(),
            remoteAddress: "cancelled"
        )
        let cancelledRead = Task { () -> Data? in
            while !Task.isCancelled {
                await Task.yield()
            }
            var iterator = subscription.stream.makeAsyncIterator()
            return await iterator.next()
        }
        cancelledRead.cancel()

        let cancelledValue = try await withCoverageDeadline(
            onTimeout: { await subscription.cancel() },
            operation: { await cancelledRead.value }
        )
        XCTAssertNil(cancelledValue)
        await fanout.publishPCM16(Data([1]))
        let listenerCount = await fanout.listenerCount()
        XCTAssertEqual(listenerCount, 0)
    }

    func testEveryRevocationDimensionAndCloseAllFinishStreams()
        async throws
    {
        let fanout = RemoteAudioFanout(
            maximumClients: 4,
            maximumClientsPerAddress: 4,
            clock: TestRemoteClock(.testReference)
        )
        await fanout.setLegacySampleRate(0)
        let browser = try await fanout.subscribe(
            kind: .pcm16Browser,
            principal: coveragePrincipal(id: "browser"),
            remoteAddress: "one",
            origin: .pairedRemoteAccess
        )
        let dedicated = try await fanout.subscribe(
            kind: .legacyFloat32,
            principal: nil,
            remoteAddress: "two",
            origin: .dedicatedLegacyListener
        )
        let authenticatedLegacy = try await fanout.subscribe(
            kind: .legacyFloat32,
            principal: coveragePrincipal(id: "legacy"),
            remoteAddress: "three",
            origin: .pairedRemoteAccess
        )
        XCTAssertEqual(dedicated.format.sampleRate, 1)
        let legacyCount = await fanout.listenerCount(kind: .legacyFloat32)
        XCTAssertEqual(legacyCount, 2)

        do {
            await fanout.publishPCM16(Data())
            await fanout.revoke(kind: .pcm16Browser)
            let browserValue = try await boundedNext(from: browser)
            XCTAssertNil(browserValue)

            await fanout.revoke(origin: .dedicatedLegacyListener)
            let dedicatedValue = try await boundedNext(from: dedicated)
            XCTAssertNil(dedicatedValue)

            await fanout.revokeAllAuthenticated()
            let authenticatedValue = try await boundedNext(
                from: authenticatedLegacy
            )
            XCTAssertNil(authenticatedValue)
            let remainingCount = await fanout.listenerCount()
            XCTAssertEqual(remainingCount, 0)

            await fanout.unsubscribe(authenticatedLegacy.id)
            let last = try await fanout.subscribe(
                kind: .legacyFloat32,
                principal: nil,
                remoteAddress: "four",
                origin: .dedicatedLegacyListener
            )
            await fanout.closeAll()
            let lastValue = try await boundedNext(from: last)
            XCTAssertNil(lastValue)
        } catch {
            await browser.cancel()
            await dedicated.cancel()
            await authenticatedLegacy.cancel()
            throw error
        }
    }

    func testFanoutDeinitCancelsOutstandingExpiryTask() async throws {
        var fanout: RemoteAudioFanout? = RemoteAudioFanout(
            clock: TestRemoteClock(.testReference)
        )
        weak let releasedFanout = fanout
        let subscription = try await XCTUnwrap(fanout).subscribe(
            kind: .pcm16Browser,
            principal: coveragePrincipal(id: "deinit"),
            remoteAddress: "deinit"
        )
        let listenerCount = await fanout?.listenerCount()
        XCTAssertEqual(listenerCount, 1)
        XCTAssertNotNil(releasedFanout)
        XCTAssertEqual(subscription.principal?.sessionID, "deinit")

        fanout = nil
        try await waitForRelease(of: { releasedFanout })
        XCTAssertNil(releasedFanout)
    }
}

final class RemainingRemoteValueCoverageDeterministicTests: XCTestCase {
    func testLocalAuthoritiesNormalizeInjectedAddressesAndHostname() {
        let addresses: Set<String> = [
            "192.0.2.40",
            "2001:db8::40",
        ]
        XCTAssertEqual(
            RemoteLocalInterfaces.authorities(
                addresses: addresses,
                hostname: "Studio-Mac."
            ),
            addresses.union(["studio-mac", "studio-mac.local"])
        )
        XCTAssertEqual(
            RemoteLocalInterfaces.authorities(
                addresses: addresses,
                hostname: "studio.example."
            ),
            addresses.union(["studio.example"])
        )
        XCTAssertEqual(
            RemoteLocalInterfaces.authorities(
                addresses: addresses,
                hostname: "..."
            ),
            addresses
        )
    }

    func testRemoteAudioDeviceIdentityIsItsStableUID() {
        let device = RemoteAudioDevice(
            uid: "stable-device-uid",
            name: "Coverage Interface",
            inputChannelCount: 4,
            outputChannelCount: 2,
            inputRoutes: [],
            supportedSampleRates: [48_000],
            transport: .usb,
            connectionState: .connected
        )

        XCTAssertEqual(device.id, device.uid)
    }
}

private func coveragePrincipal(
    id: String = "coverage"
) -> RemoteSessionPrincipal {
    RemoteSessionPrincipal(
        sessionID: id,
        expiresAt: .testReference.addingTimeInterval(3_600)
    )
}

private func enqueuePipeline(
    _ worker: AudioPipelineWorker,
    left: [Float],
    right: [Float]
) {
    precondition(left.count == right.count)
    left.withUnsafeBufferPointer { leftBuffer in
        right.withUnsafeBufferPointer { rightBuffer in
            worker.enqueue(
                left: leftBuffer.baseAddress!,
                right: rightBuffer.baseAddress!,
                count: left.count
            )
        }
    }
}

private enum CoverageDeadlineError: Error {
    case timedOut
}

private func withCoverageDeadline<Value: Sendable>(
    timeout: Duration = .seconds(1),
    onTimeout: @escaping @Sendable () async -> Void,
    operation: @escaping @Sendable () async -> Value
) async throws -> Value {
    try await withThrowingTaskGroup(of: Value.self) { group in
        group.addTask {
            await operation()
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            await onTimeout()
            throw CoverageDeadlineError.timedOut
        }
        defer { group.cancelAll() }
        guard let value = try await group.next() else {
            throw CoverageDeadlineError.timedOut
        }
        return value
    }
}

private func boundedNext(
    from subscription: RemoteAudioSubscription,
    timeout: Duration = .seconds(1)
) async throws -> Data? {
    try await withCoverageDeadline(
        timeout: timeout,
        onTimeout: { await subscription.cancel() },
        operation: {
            var iterator = subscription.stream.makeAsyncIterator()
            return await iterator.next()
        }
    )
}

private func waitForMailboxWaiter(
    _ mailbox: RemoteAudioMailbox,
    timeout: Duration = .seconds(1)
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !(await mailbox.hasWaitingConsumer()) {
        guard clock.now < deadline else {
            await mailbox.close()
            throw CoverageDeadlineError.timedOut
        }
        await Task.yield()
    }
}

private func waitForRelease<Instance: AnyObject>(
    of instance: () -> Instance?,
    timeout: Duration = .seconds(1)
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while instance() != nil {
        guard clock.now < deadline else {
            throw CoverageDeadlineError.timedOut
        }
        await Task.yield()
    }
}

private func alpha(
    in image: CGImage,
    x: Int,
    y: Int
) -> UInt8? {
    guard
        x >= 0,
        x < image.width,
        y >= 0,
        y < image.height,
        let providerData = image.dataProvider?.data
    else {
        return nil
    }
    let bytes = Data(providerData as Data)
    let index = (y * image.width + x) * 4 + 3
    guard index < bytes.count else { return nil }
    return bytes[index]
}

private final class RootedRecordingFileManager:
    FileManager, @unchecked Sendable
{
    private let recordingRootURL: URL

    init(recordingRootURL: URL) {
        self.recordingRootURL = recordingRootURL
        super.init()
    }

    override func urls(
        for directory: FileManager.SearchPathDirectory,
        in domainMask: FileManager.SearchPathDomainMask
    ) -> [URL] {
        if directory == .applicationSupportDirectory,
            domainMask.contains(.userDomainMask)
        {
            return [recordingRootURL]
        }
        return super.urls(for: directory, in: domainMask)
    }
}

private struct TemporaryRecordingSandbox {
    let rootURL: URL
    let fileManager: RootedRecordingFileManager

    init() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PhonoFlow-RecordingTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        self.rootURL = rootURL
        fileManager = RootedRecordingFileManager(
            recordingRootURL: rootURL
        )
    }

    func makeFileSystem() -> SystemRecorderFileSystem {
        SystemRecorderFileSystem(fileManager: fileManager)
    }

    func remove() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}

private func readLittleEndianUInt32(_ data: Data, at offset: Int) -> UInt32 {
    UInt32(data[offset])
        | (UInt32(data[offset + 1]) << 8)
        | (UInt32(data[offset + 2]) << 16)
        | (UInt32(data[offset + 3]) << 24)
}

private func readLittleEndianInt16(_ data: Data, at offset: Int) -> Int16 {
    let bits = UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    return Int16(bitPattern: bits)
}
