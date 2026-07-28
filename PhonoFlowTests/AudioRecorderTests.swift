import Darwin
import Foundation
import Synchronization
import XCTest

@testable import PhonoFlow

final class AudioRecorderTests: XCTestCase {
    func testInvalidSampleRatesFailBeforeCreatingAFile() {
        for sampleRate in [0, -1, .nan, .infinity] {
            let recorder = AudioRecorder()
            XCTAssertThrowsError(try recorder.start(sampleRate: sampleRate)) { error in
                guard case AudioRecorder.RecorderError.invalidSampleRate = error else {
                    return XCTFail("Unexpected error for \(sampleRate): \(error)")
                }
            }
            XCTAssertFalse(recorder.isRecording)
            XCTAssertNil(recorder.stop())
        }
    }

    func testIdleWritesAreIgnoredWithoutGrowingQueueOrDropCounters() {
        let recorder = AudioRecorder()
        let samples: [Float] = [0.25, -0.25, 0.5, -0.5]

        samples.withUnsafeBufferPointer {
            recorder.write($0.baseAddress!, frameCount: 2)
        }

        XCTAssertEqual(recorder.queuedBlockCount, 0)
        XCTAssertEqual(recorder.droppedBlockCount, 0)
        XCTAssertEqual(recorder.droppedFrameCount, 0)
        XCTAssertEqual(recorder.durationSeconds, 0)
    }

    func testStopDrainsSamplesAndFinalizesFloat32WAVHeader() throws {
        let recorder = AudioRecorder()
        let url = try recorder.start(sampleRate: 48_000)
        defer {
            _ = recorder.stop()
            try? FileManager.default.removeItem(at: url)
        }
        let samples: [Float] = [
            -1, 1,
            -0.5, 0.5,
            0, 0.25,
            0.75, -0.75,
        ]
        samples.withUnsafeBufferPointer {
            recorder.write($0.baseAddress!, frameCount: 4)
        }

        let stoppedRecording = try XCTUnwrap(recorder.stop()).get()
        XCTAssertEqual(stoppedRecording.url, url)
        XCTAssertEqual(stoppedRecording.frameCount, 4)
        XCTAssertEqual(stoppedRecording.droppedFrameCount, 0)
        XCTAssertEqual(stoppedRecording.sampleRate, 48_000)
        XCTAssertEqual(stoppedRecording.terminationReason, .requested)
        XCTAssertEqual(stoppedRecording.durationSeconds, 4.0 / 48_000, accuracy: 1e-12)
        XCTAssertFalse(recorder.isRecording)
        XCTAssertEqual(recorder.durationSeconds, 4.0 / 48_000, accuracy: 1e-12)

        let wav = try Data(contentsOf: url)
        XCTAssertEqual(wav.count, 44 + samples.count * MemoryLayout<Float>.size)
        XCTAssertEqual(String(data: wav[0..<4], encoding: .ascii), "RIFF")
        XCTAssertEqual(littleEndianUInt32(wav, at: 4), 36 + 32)
        XCTAssertEqual(String(data: wav[8..<12], encoding: .ascii), "WAVE")
        XCTAssertEqual(littleEndianUInt16(wav, at: 20), 3)
        XCTAssertEqual(littleEndianUInt16(wav, at: 22), 2)
        XCTAssertEqual(littleEndianUInt32(wav, at: 24), 48_000)
        XCTAssertEqual(littleEndianUInt32(wav, at: 28), 384_000)
        XCTAssertEqual(littleEndianUInt16(wav, at: 32), 8)
        XCTAssertEqual(littleEndianUInt16(wav, at: 34), 32)
        XCTAssertEqual(String(data: wav[36..<40], encoding: .ascii), "data")
        XCTAssertEqual(littleEndianUInt32(wav, at: 40), 32)

        let recorded = samples.indices.map {
            Float(bitPattern: littleEndianUInt32(wav, at: 44 + $0 * 4))
        }
        XCTAssertEqual(recorded, samples)
        XCTAssertNil(recorder.stop())
    }

    func testRIFFSizeLimitFinalizesAndPreservesTheRepresentableAudio() throws {
        let storage = InMemoryRecorderFileSystem()
        let recorder = AudioRecorder(
            fileSystem: storage,
            maximumWAVDataByteCount: 35
        )
        _ = try recorder.start(sampleRate: 48_000)
        let samples: [Float] = [
            -1, 1,
            -0.5, 0.5,
            0, 0.25,
            0.75, -0.75,
            0.125, -0.125,
            0.625, -0.625,
        ]

        samples.withUnsafeBufferPointer {
            recorder.write($0.baseAddress!, frameCount: 6)
        }

        XCTAssertFalse(recorder.isRecording)
        XCTAssertTrue(recorder.reachedFileSizeLimit)
        XCTAssertEqual(recorder.droppedBlockCount, 0)
        XCTAssertEqual(recorder.droppedFrameCount, 0)

        // Further callback data after the format limit is ignored rather than
        // misreported as disk-queue loss.
        writeFourFrames(to: recorder)
        XCTAssertEqual(recorder.droppedFrameCount, 0)

        let recording = try XCTUnwrap(recorder.stop()).get()
        XCTAssertEqual(recording.frameCount, 4)
        XCTAssertEqual(recording.droppedFrameCount, 0)
        XCTAssertEqual(recording.terminationReason, .riffSizeLimit)
        XCTAssertEqual(storage.sink.truncateOffsets, [76])
        XCTAssertEqual(storage.sink.data.count, 76)
        XCTAssertEqual(littleEndianUInt32(storage.sink.data, at: 4), 68)
        XCTAssertEqual(littleEndianUInt32(storage.sink.data, at: 40), 32)
        XCTAssertTrue(storage.removedURLs.isEmpty)
        XCTAssertTrue(storage.quarantinedURLs.isEmpty)
    }

    func testWAVHeaderClampsAnUnrepresentableRIFFPayloadWithoutOverflow() {
        let header = AudioRecorder.buildWAVHeader(
            dataSize: UInt32.max,
            sampleRate: 48_000
        )

        XCTAssertEqual(
            littleEndianUInt32(header, at: 4),
            UInt32.max - 3
        )
        XCTAssertEqual(
            littleEndianUInt32(header, at: 40),
            UInt32.max - 39
        )
    }

    func testStartingWhileActiveReturnsAlreadyRecordingAndPreservesFirstFile() throws {
        let recorder = AudioRecorder()
        let url = try recorder.start(sampleRate: 44_100)
        defer {
            _ = recorder.stop()
            try? FileManager.default.removeItem(at: url)
        }

        XCTAssertThrowsError(try recorder.start(sampleRate: 48_000)) { error in
            guard case AudioRecorder.RecorderError.alreadyRecording = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertTrue(recorder.isRecording)
        let stoppedRecording = try XCTUnwrap(recorder.stop()).get()
        XCTAssertEqual(stoppedRecording.url, url)

        let wav = try Data(contentsOf: url)
        XCTAssertEqual(littleEndianUInt32(wav, at: 4), 36)
        XCTAssertEqual(littleEndianUInt32(wav, at: 40), 0)
    }

    func testInitialHeaderFailureClosesAndRemovesTheFile() {
        let storage = InMemoryRecorderFileSystem()
        storage.sink.partialWriteFailures = [1: 7]
        let recorder = AudioRecorder(fileSystem: storage)

        XCTAssertThrowsError(try recorder.start(sampleRate: 48_000)) { error in
            guard case .initializationFailed(let failure) = error as? AudioRecorder.RecorderError
            else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(failure.phase, .initialHeaderWrite)
            XCTAssertEqual(failure.disposition, .removed)
        }

        XCTAssertEqual(storage.sink.closeCallCount, 1)
        XCTAssertEqual(storage.removedURLs, [storage.url])
        XCTAssertFalse(recorder.isRecording)
        XCTAssertNil(recorder.stop())
    }

    func testInitialHeaderFailureQuarantinesWhenRemovalFails() {
        let storage = InMemoryRecorderFileSystem()
        storage.sink.partialWriteFailures = [1: 7]
        storage.sink.failClose = true
        storage.failRemove = true
        let recorder = AudioRecorder(fileSystem: storage)

        XCTAssertThrowsError(try recorder.start(sampleRate: 48_000)) { error in
            guard case .initializationFailed(let failure) = error as? AudioRecorder.RecorderError
            else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(failure.phase, .initialHeaderWrite)
            XCTAssertEqual(failure.disposition, .quarantined(storage.quarantineURL))
        }

        XCTAssertEqual(storage.sink.closeCallCount, 1)
        XCTAssertEqual(storage.quarantinedURLs, [storage.url])
    }

    func testStorageCreationFailureDoesNotAttemptCleanup() {
        let storage = InMemoryRecorderFileSystem()
        storage.failCreate = true
        let recorder = AudioRecorder(fileSystem: storage)

        XCTAssertThrowsError(try recorder.start(sampleRate: 48_000)) { error in
            guard case AudioRecorder.RecorderError.cannotCreateFile = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertEqual(storage.sink.closeCallCount, 0)
        XCTAssertTrue(storage.removedURLs.isEmpty)
        XCTAssertTrue(storage.quarantinedURLs.isEmpty)
    }

    func testPartialAudioWriteIsTruncatedAndReportedAsFailure() throws {
        let storage = InMemoryRecorderFileSystem()
        storage.sink.partialWriteFailures = [2: 3]
        let recorder = AudioRecorder(fileSystem: storage)
        _ = try recorder.start(sampleRate: 48_000)
        writeFourFrames(to: recorder)

        let failure = try terminalFailure(from: recorder.stop())

        XCTAssertEqual(failure.phase, .audioWrite)
        XCTAssertEqual(failure.fileURL, storage.url)
        XCTAssertEqual(failure.disposition, .removed)
        XCTAssertEqual(storage.sink.truncateOffsets, [44])
        XCTAssertEqual(storage.sink.data.count, 44)
        XCTAssertEqual(storage.removedURLs, [storage.url])
        XCTAssertFalse(recorder.isRecording)
        XCTAssertNil(recorder.stop())
    }

    func testAudioWriteFailureStopsAcceptanceAndIgnoresPostTerminalWrites() throws {
        let storage = InMemoryRecorderFileSystem()
        storage.sink.partialWriteFailures = [2: 3]
        let recorder = AudioRecorder(fileSystem: storage)
        _ = try recorder.start(sampleRate: 48_000)
        writeFourFrames(to: recorder)

        let deadline = Date().addingTimeInterval(1)
        while recorder.isRecording, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.001)
        }
        XCTAssertFalse(recorder.isRecording)

        let droppedAtFailure = recorder.droppedFrameCount
        writeFourFrames(to: recorder)
        XCTAssertEqual(recorder.droppedFrameCount, droppedAtFailure)
        let failure = try terminalFailure(from: recorder.stop())

        XCTAssertEqual(failure.phase, .audioWrite)
        XCTAssertEqual(failure.droppedFrameCount, recorder.droppedFrameCount)
        XCTAssertEqual(recorder.durationSeconds, 4.0 / 48_000, accuracy: 1e-12)
    }

    func testQueueSaturationIsAFailedRecordingRatherThanSilentSuccess() throws {
        let storage = InMemoryRecorderFileSystem()
        storage.sink.blockedWriteCall = 2
        let recorder = AudioRecorder(fileSystem: storage)
        _ = try recorder.start(sampleRate: 48_000)

        let firstFrame: [Float] = [0.25, -0.25]
        firstFrame.withUnsafeBufferPointer {
            recorder.write($0.baseAddress!, frameCount: 1)
        }
        XCTAssertEqual(
            storage.sink.blockedWriteEntered.wait(timeout: .now() + 1),
            .success
        )

        let bulkFrameCount = 64 * 2_048
        let bulk = [Float](repeating: 0.125, count: bulkFrameCount * 2)
        bulk.withUnsafeBufferPointer {
            recorder.write($0.baseAddress!, frameCount: bulkFrameCount)
        }
        XCTAssertGreaterThan(recorder.droppedFrameCount, 0)
        XCTAssertFalse(
            recorder.isRecording,
            "A queue overflow must stop callback acceptance immediately."
        )

        storage.sink.releaseBlockedWrite.signal()
        let failure = try terminalFailure(from: recorder.stop())

        XCTAssertEqual(failure.phase, .queueOverflow)
        XCTAssertEqual(failure.droppedFrameCount, recorder.droppedFrameCount)
        XCTAssertEqual(failure.disposition, .removed)
    }

    func testReportedUpstreamDropsLatchFailureAndRemoveIncompleteFile() throws {
        let storage = InMemoryRecorderFileSystem()
        let recorder = AudioRecorder(fileSystem: storage)
        _ = try recorder.start(sampleRate: 48_000)
        writeFourFrames(to: recorder)

        recorder.reportUpstreamDroppedFrames(4_464)

        XCTAssertFalse(recorder.isRecording)
        XCTAssertEqual(recorder.droppedBlockCount, 0)
        XCTAssertEqual(recorder.droppedFrameCount, 4_464)

        let failure = try terminalFailure(from: recorder.stop())
        XCTAssertEqual(failure.phase, .queueOverflow)
        XCTAssertEqual(failure.droppedFrameCount, 4_464)
        XCTAssertEqual(failure.disposition, .removed)
        XCTAssertEqual(storage.removedURLs, [storage.url])
    }

    func testUpstreamDropReportsRespectSessionBoundariesAndReset() throws {
        let storage = InMemoryRecorderFileSystem()
        let recorder = AudioRecorder(fileSystem: storage)

        recorder.reportUpstreamDroppedFrames(3)
        XCTAssertEqual(recorder.droppedFrameCount, 0)

        _ = try recorder.start(sampleRate: 48_000)
        recorder.reportUpstreamDroppedFrames(7)
        let firstFailure = try terminalFailure(from: recorder.stop())
        XCTAssertEqual(firstFailure.droppedFrameCount, 7)

        recorder.reportUpstreamDroppedFrames(11)
        XCTAssertEqual(recorder.droppedFrameCount, 7)

        _ = try recorder.start(sampleRate: 96_000)
        XCTAssertEqual(recorder.droppedFrameCount, 0)
        let second = try XCTUnwrap(recorder.stop()).get()
        XCTAssertEqual(second.droppedFrameCount, 0)
        XCTAssertEqual(second.terminationReason, .requested)
    }

    func testProducerGateFencesPriorSessionBeforeReopening() {
        let gate = RecorderProducerGate()
        gate.open()
        XCTAssertTrue(gate.beginProducing())

        let closeStarted = DispatchSemaphore(value: 0)
        let closeFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            closeStarted.signal()
            gate.closeAndWait()
            closeFinished.signal()
        }

        XCTAssertEqual(closeStarted.wait(timeout: .now() + 1), .success)
        let closeDeadline = Date().addingTimeInterval(1)
        while gate.isOpen, Date() < closeDeadline {
            sched_yield()
        }
        XCTAssertFalse(gate.isOpen)
        XCTAssertFalse(gate.beginProducing())
        XCTAssertEqual(
            closeFinished.wait(timeout: .now() + 0.05),
            .timedOut,
            "Closing must wait for the prior session's registered producer."
        )

        gate.endProducing()
        XCTAssertEqual(closeFinished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(gate.activeProducerCount, 0)

        gate.open()
        XCTAssertTrue(gate.beginProducing())
        gate.endProducing()
        gate.closeAndWait()
        XCTAssertEqual(gate.activeProducerCount, 0)
    }

    func testEachFinalizationFailureIsTypedAndRemovesTheArtifact() throws {
        let cases: [(AudioRecorder.TerminalFailure.Phase, (InMemoryRecorderSink) -> Void)] = [
            (.truncate, { $0.failTruncate = true }),
            (.headerWrite, { $0.failSeek = true }),
            (.headerWrite, { $0.partialWriteFailures = [3: 5] }),
            (.synchronize, { $0.failSynchronize = true }),
            (.close, { $0.failClose = true }),
        ]

        for (expectedPhase, configure) in cases {
            let storage = InMemoryRecorderFileSystem()
            configure(storage.sink)
            let recorder = AudioRecorder(fileSystem: storage)
            _ = try recorder.start(sampleRate: 44_100)
            writeFourFrames(to: recorder)

            let failure = try terminalFailure(from: recorder.stop())

            XCTAssertEqual(failure.phase, expectedPhase)
            XCTAssertEqual(failure.disposition, .removed)
            XCTAssertEqual(storage.removedURLs, [storage.url])
            XCTAssertEqual(storage.sink.closeCallCount, 1)
            XCTAssertFalse(recorder.isRecording)
        }
    }

    func testFailedRemovalQuarantinesTheIncompleteArtifact() throws {
        let storage = InMemoryRecorderFileSystem()
        storage.sink.failSynchronize = true
        storage.failRemove = true
        let recorder = AudioRecorder(fileSystem: storage)
        _ = try recorder.start(sampleRate: 48_000)
        writeFourFrames(to: recorder)

        let failure = try terminalFailure(from: recorder.stop())

        XCTAssertEqual(failure.phase, .synchronize)
        XCTAssertEqual(failure.disposition, .quarantined(storage.quarantineURL))
        XCTAssertEqual(storage.quarantinedURLs, [storage.url])
        XCTAssertTrue(failure.localizedDescription.contains("marked as"))
    }

    func testCleanupFailurePreservesTheUnsafePathInTheTypedResult() throws {
        let storage = InMemoryRecorderFileSystem()
        storage.sink.failClose = true
        storage.failRemove = true
        storage.failQuarantine = true
        let recorder = AudioRecorder(fileSystem: storage)
        _ = try recorder.start(sampleRate: 48_000)
        writeFourFrames(to: recorder)

        let failure = try terminalFailure(from: recorder.stop())

        guard case .cleanupFailed(let originalURL, let reason) = failure.disposition else {
            return XCTFail("Expected cleanup failure, received \(failure.disposition)")
        }
        XCTAssertEqual(originalURL, storage.url)
        XCTAssertTrue(reason.contains("removeFailure"))
        XCTAssertTrue(reason.contains("quarantineFailure"))
        XCTAssertTrue(failure.localizedDescription.contains("do not use"))
    }

    func testConcurrentStartsHaveExactlyOneWinner() {
        let storage = InMemoryRecorderFileSystem()
        let recorder = AudioRecorder(fileSystem: storage)
        let successes = Atomic<Int>(0)
        let alreadyRecordingFailures = Atomic<Int>(0)
        let unexpectedFailures = Atomic<Int>(0)

        DispatchQueue.concurrentPerform(iterations: 2) { _ in
            do {
                _ = try recorder.start(sampleRate: 48_000)
                successes.wrappingAdd(1, ordering: .relaxed)
            } catch AudioRecorder.RecorderError.alreadyRecording {
                alreadyRecordingFailures.wrappingAdd(1, ordering: .relaxed)
            } catch {
                unexpectedFailures.wrappingAdd(1, ordering: .relaxed)
            }
        }

        XCTAssertEqual(successes.load(ordering: .relaxed), 1)
        XCTAssertEqual(alreadyRecordingFailures.load(ordering: .relaxed), 1)
        XCTAssertEqual(unexpectedFailures.load(ordering: .relaxed), 0)
        _ = recorder.stop()
    }

    func testSequentialSessionsResetCountersAndTerminalResult() throws {
        let storage = InMemoryRecorderFileSystem()
        let recorder = AudioRecorder(fileSystem: storage)
        _ = try recorder.start(sampleRate: 48_000)
        writeFourFrames(to: recorder)
        let first = try XCTUnwrap(recorder.stop()).get()
        XCTAssertEqual(first.frameCount, 4)

        _ = try recorder.start(sampleRate: 96_000)
        let second = try XCTUnwrap(recorder.stop()).get()

        XCTAssertEqual(second.frameCount, 0)
        XCTAssertEqual(second.droppedFrameCount, 0)
        XCTAssertEqual(second.sampleRate, 96_000)
        XCTAssertEqual(recorder.durationSeconds, 0)
    }

    func testDeinitFinalizesAnActiveRecording() throws {
        let storage = InMemoryRecorderFileSystem()
        var recorder: AudioRecorder? = AudioRecorder(fileSystem: storage)
        _ = try recorder?.start(sampleRate: 48_000)
        if let recorder {
            writeFourFrames(to: recorder)
        }

        recorder = nil

        XCTAssertEqual(storage.sink.synchronizeCallCount, 1)
        XCTAssertEqual(storage.sink.closeCallCount, 1)
        XCTAssertEqual(storage.sink.truncateOffsets, [76])
    }

    private func writeFourFrames(to recorder: AudioRecorder) {
        let samples: [Float] = [
            -1, 1,
            -0.5, 0.5,
            0, 0.25,
            0.75, -0.75,
        ]
        samples.withUnsafeBufferPointer {
            recorder.write($0.baseAddress!, frameCount: 4)
        }
    }

    private func terminalFailure(
        from result: AudioRecorder.TerminalResult?
    ) throws -> AudioRecorder.TerminalFailure {
        let result = try XCTUnwrap(result)
        switch result {
        case .success(let recording):
            XCTFail("Expected failure, completed \(recording.url)")
            throw RecorderTestError.expectedFailure
        case .failure(let failure):
            return failure
        }
    }
}

nonisolated private final class InMemoryRecorderFileSystem:
    RecorderFileSystem,
    @unchecked Sendable
{
    let url = URL(fileURLWithPath: "/recordings/test.wav")
    let quarantineURL = URL(fileURLWithPath: "/recordings/test.incomplete.corrupt")
    let sink = InMemoryRecorderSink()
    var failCreate = false
    var failRemove = false
    var failQuarantine = false
    private(set) var removedURLs: [URL] = []
    private(set) var quarantinedURLs: [URL] = []

    func createRecordingFile() throws -> RecorderCreatedFile {
        if failCreate {
            throw RecorderTestError.createFailure
        }
        return RecorderCreatedFile(url: url, sink: sink)
    }

    func removeRecordingFile(at url: URL) throws {
        if failRemove {
            throw RecorderTestError.removeFailure
        }
        removedURLs.append(url)
    }

    func quarantineRecordingFile(at url: URL) throws -> URL {
        if failQuarantine {
            throw RecorderTestError.quarantineFailure
        }
        quarantinedURLs.append(url)
        return quarantineURL
    }
}

nonisolated private final class InMemoryRecorderSink:
    RecorderFileSink,
    @unchecked Sendable
{
    var partialWriteFailures: [Int: Int] = [:]
    var failSeek = false
    var failTruncate = false
    var failSynchronize = false
    var failClose = false
    var blockedWriteCall: Int?
    let blockedWriteEntered = DispatchSemaphore(value: 0)
    let releaseBlockedWrite = DispatchSemaphore(value: 0)

    private(set) var data = Data()
    private(set) var truncateOffsets: [UInt64] = []
    private(set) var closeCallCount = 0
    private(set) var synchronizeCallCount = 0
    private var offset = 0
    private var writeCallCount = 0

    func write(_ incoming: Data) throws {
        writeCallCount += 1
        if writeCallCount == blockedWriteCall {
            blockedWriteEntered.signal()
            releaseBlockedWrite.wait()
        }
        if let partialByteCount = partialWriteFailures[writeCallCount] {
            writeBytes(incoming.prefix(partialByteCount))
            throw RecorderTestError.writeFailure
        }
        writeBytes(incoming)
    }

    func seek(toOffset offset: UInt64) throws {
        if failSeek {
            throw RecorderTestError.seekFailure
        }
        self.offset = Int(offset)
    }

    func truncate(atOffset offset: UInt64) throws {
        truncateOffsets.append(offset)
        if failTruncate {
            throw RecorderTestError.truncateFailure
        }
        let size = Int(offset)
        if data.count > size {
            data.removeSubrange(size..<data.count)
        } else if data.count < size {
            data.append(Data(repeating: 0, count: size - data.count))
        }
        self.offset = min(self.offset, size)
    }

    func synchronize() throws {
        synchronizeCallCount += 1
        if failSynchronize {
            throw RecorderTestError.synchronizeFailure
        }
    }

    func close() throws {
        closeCallCount += 1
        if failClose {
            throw RecorderTestError.closeFailure
        }
    }

    private func writeBytes<T: DataProtocol>(_ bytes: T) {
        let bytes = Data(bytes)
        let end = offset + bytes.count
        if data.count < end {
            data.append(Data(repeating: 0, count: end - data.count))
        }
        data.replaceSubrange(offset..<end, with: bytes)
        offset = end
    }
}

nonisolated private enum RecorderTestError: Error {
    case expectedFailure
    case createFailure
    case writeFailure
    case seekFailure
    case truncateFailure
    case synchronizeFailure
    case closeFailure
    case removeFailure
    case quarantineFailure
}
