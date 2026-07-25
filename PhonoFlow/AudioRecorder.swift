//
//  AudioRecorder.swift
//  PhonoFlow
//
//  Records interleaved stereo 32-bit float PCM to WAV files.
//
//  The real-time audio thread only copies into a preallocated bounded SPSC
//  queue. Data creation, file I/O, header finalization, and closing happen on
//  the recorder worker.
//

import Darwin
import Foundation
import Synchronization

nonisolated protocol RecorderFileSink: AnyObject, Sendable {
    /// Writes the complete buffer or throws. Implementations that append only
    /// part of the buffer must still throw so finalization can truncate it.
    func write(_ data: Data) throws
    func seek(toOffset offset: UInt64) throws
    func truncate(atOffset offset: UInt64) throws
    func synchronize() throws
    func close() throws
}

nonisolated struct RecorderCreatedFile: Sendable {
    let url: URL
    let sink: any RecorderFileSink
}

nonisolated protocol RecorderFileSystem: Sendable {
    func createRecordingFile() throws -> RecorderCreatedFile
    func removeRecordingFile(at url: URL) throws
    func quarantineRecordingFile(at url: URL) throws -> URL
}

nonisolated final class AudioRecorder: @unchecked Sendable {
    fileprivate static let channels: UInt16 = 2
    fileprivate static let bitsPerSample: UInt16 = 32
    fileprivate static let bytesPerFrame =
        UInt64(channels) * UInt64(bitsPerSample / 8)
    /// RIFF's 32-bit chunk length includes the 36 bytes before PCM payload.
    /// Round down to a whole stereo Float32 frame so the final data chunk is
    /// valid as well as representable.
    fileprivate static let maximumWAVDataByteCount =
        (UInt64(UInt32.max) - 36) / bytesPerFrame * bytesPerFrame

    /// 64 × 2,048 stereo frames is roughly 2.7 seconds at 48 kHz. The queue is
    /// intentionally bounded so a slow disk can never grow process memory.
    private let bufferPool: RecorderBufferPool
    private let workerQueue = DispatchQueue(label: "PhonoFlow.recorder", qos: .userInitiated)
    private let fileSystem: any RecorderFileSystem
    private let terminalBox = RecorderTerminalBox()
    private let lifecycleLock = NSLock()

    private var fileSink: (any RecorderFileSink)?
    private var filePath: URL?
    private let sampleRateValue = Atomic<Double>(44_100)

    init(
        fileSystem: any RecorderFileSystem = SystemRecorderFileSystem(),
        maximumWAVDataByteCount: UInt64 = AudioRecorder.maximumWAVDataByteCount
    ) {
        self.fileSystem = fileSystem
        bufferPool = RecorderBufferPool(
            blockCount: 64,
            framesPerBlock: 2_048,
            maximumWAVDataByteCount: maximumWAVDataByteCount
        )
    }

    deinit {
        _ = stop()
    }

    /// `true` only while callback-side writes are accepted.
    var isRecording: Bool {
        bufferPool.isAccepting
    }

    /// Number of fixed-size blocks discarded because the disk queue was full.
    var droppedBlockCount: UInt64 {
        bufferPool.droppedBlocks
    }

    /// Number of stereo frames lost anywhere before they reached disk.
    var droppedFrameCount: UInt64 {
        bufferPool.droppedFrames
    }

    /// Current number of blocks awaiting disk I/O.
    var queuedBlockCount: Int {
        bufferPool.queueDepth
    }

    /// `true` after this session filled the largest representable RIFF file.
    var reachedFileSizeLimit: Bool {
        bufferPool.reachedFileSizeLimit
    }

    /// Start recording to a new WAV file.
    func start(sampleRate: Double) throws -> URL {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        guard !isRecording, fileSink == nil else {
            throw RecorderError.alreadyRecording
        }
        guard sampleRate.isFinite, sampleRate > 0, sampleRate <= Double(UInt32.max) else {
            throw RecorderError.invalidSampleRate
        }

        var createdFile: RecorderCreatedFile?
        do {
            let file = try fileSystem.createRecordingFile()
            createdFile = file
            try file.sink.write(
                Self.buildWAVHeader(dataSize: 0, sampleRate: sampleRate)
            )
        } catch {
            if let createdFile {
                try? createdFile.sink.close()
                let failure = TerminalFailure(
                    phase: .initialHeaderWrite,
                    fileURL: createdFile.url,
                    reason: String(describing: error),
                    disposition: Self.disposeCorruptFile(
                        at: createdFile.url,
                        using: fileSystem
                    ),
                    droppedFrameCount: 0
                )
                throw RecorderError.initializationFailed(failure)
            }
            throw RecorderError.cannotCreateFile
        }
        guard let createdFile else {
            throw RecorderError.cannotCreateFile
        }

        sampleRateValue.store(sampleRate, ordering: .relaxed)
        fileSink = createdFile.sink
        filePath = createdFile.url
        terminalBox.reset()
        bufferPool.beginSession()

        let completion = DispatchSemaphore(value: 0)
        workerQueue.async { [bufferPool, createdFile, fileSystem, terminalBox] in
            let result = Self.drainToDisk(
                bufferPool: bufferPool,
                createdFile: createdFile,
                sampleRate: sampleRate,
                fileSystem: fileSystem
            )
            terminalBox.store(result)
            completion.signal()
        }
        bufferPool.startAccepting(completion: completion)

        return createdFile.url
    }

    /// Write interleaved stereo samples from the audio thread.
    ///
    /// This method performs no allocation, lock acquisition, file I/O, or
    /// dispatch. If the bounded queue is full, the remaining frames are
    /// dropped and reflected in `droppedBlockCount` / `droppedFrameCount`.
    func write(_ samples: UnsafePointer<Float>, frameCount: Int) {
        guard frameCount > 0 else { return }
        bufferPool.enqueue(samples, frameCount: frameCount)
    }

    /// Reports loss in the bounded recording lane upstream of this recorder.
    ///
    /// The pipeline calls this from its serial recording worker after fencing
    /// the real-time producer. It is intentionally synchronous: any loss must
    /// be visible before `stop()` decides whether the WAV can be kept.
    func reportUpstreamDroppedFrames(_ frameCount: UInt64) {
        guard frameCount > 0 else { return }

        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        guard fileSink != nil, !bufferPool.reachedFileSizeLimit else { return }
        bufferPool.reportUpstreamDroppedFrames(frameCount)
    }

    /// Stop recording, drain every accepted block, and finalize the WAV header.
    ///
    /// The return remains synchronous so that callers can safely react to an
    /// unplug or terminate immediately after this method returns without
    /// leaving a placeholder header behind.
    func stop() -> TerminalResult? {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        guard fileSink != nil, let url = filePath else { return nil }

        bufferPool.stopAcceptingAndWaitForProducer()
        bufferPool.requestWorkerStop()
        bufferPool.waitForWorker()

        fileSink = nil
        filePath = nil

        if let result = terminalBox.take() {
            switch result {
            case .success:
                return result
            case .failure(let failure):
                return .failure(
                    TerminalFailure(
                        phase: failure.phase,
                        fileURL: failure.fileURL,
                        reason: failure.reason,
                        disposition: failure.disposition,
                        droppedFrameCount: bufferPool.droppedFrames
                    )
                )
            }
        }

        let disposition = Self.disposeCorruptFile(
            at: url,
            using: fileSystem
        )
        return .failure(
            TerminalFailure(
                phase: .workerCompletion,
                fileURL: url,
                reason: "The recorder worker completed without a terminal result.",
                disposition: disposition,
                droppedFrameCount: bufferPool.droppedFrames
            )
        )
    }

    /// Duration of accepted audio in seconds.
    var durationSeconds: Double {
        let sampleRate = sampleRateValue.load(ordering: .relaxed)
        guard sampleRate > 0 else { return 0 }
        return Double(bufferPool.acceptedFrames) / sampleRate
    }

    // MARK: - Worker

    private static func drainToDisk(
        bufferPool: RecorderBufferPool,
        createdFile: RecorderCreatedFile,
        sampleRate: Double,
        fileSystem: any RecorderFileSystem
    ) -> TerminalResult {
        let sink = createdFile.sink
        var firstFailure: (phase: TerminalFailure.Phase, reason: String)?

        while true {
            bufferPool.waitForWork()

            if let block = bufferPool.nextReadableBlock() {
                if firstFailure == nil {
                    let byteCount =
                        block.frameCount
                        * Int(channels)
                        * MemoryLayout<Float>.size
                    let data = Data(bytes: block.samples, count: byteCount)
                    do {
                        try sink.write(data)
                        bufferPool.recordWrittenFrames(block.frameCount)
                    } catch {
                        firstFailure = (
                            .audioWrite,
                            String(describing: error)
                        )
                        bufferPool.recordDiscardedFrames(block.frameCount)
                        bufferPool.abortAfterWorkerFailure()
                    }
                } else {
                    bufferPool.recordDiscardedFrames(block.frameCount)
                }
                bufferPool.finishReadingBlock()
            } else if bufferPool.shouldWorkerStop {
                break
            }
        }

        // The callback-side cap makes this conversion exact. Bounding it again
        // here keeps header finalization safe even if a future queue change
        // violates that invariant.
        let headerFrameCount = min(
            bufferPool.writtenFrames,
            maximumWAVDataByteCount / bytesPerFrame
        )
        let dataSize = UInt32(headerFrameCount * bytesPerFrame)

        if firstFailure == nil, bufferPool.droppedFrames > 0 {
            firstFailure = (
                .queueOverflow,
                "\(bufferPool.droppedFrames) stereo frames were dropped before disk write."
            )
        }

        let completedFileSize = UInt64(44) + UInt64(dataSize)
        do {
            try sink.truncate(atOffset: completedFileSize)
        } catch {
            recordFirstFailure(
                &firstFailure,
                phase: .truncate,
                error: error
            )
        }

        do {
            try sink.seek(toOffset: 0)
            try sink.write(buildWAVHeader(dataSize: dataSize, sampleRate: sampleRate))
        } catch {
            recordFirstFailure(
                &firstFailure,
                phase: .headerWrite,
                error: error
            )
        }

        do {
            try sink.synchronize()
        } catch {
            recordFirstFailure(
                &firstFailure,
                phase: .synchronize,
                error: error
            )
        }

        do {
            try sink.close()
        } catch {
            recordFirstFailure(
                &firstFailure,
                phase: .close,
                error: error
            )
        }

        if let firstFailure {
            return .failure(
                TerminalFailure(
                    phase: firstFailure.phase,
                    fileURL: createdFile.url,
                    reason: firstFailure.reason,
                    disposition: disposeCorruptFile(
                        at: createdFile.url,
                        using: fileSystem
                    ),
                    droppedFrameCount: bufferPool.droppedFrames
                )
            )
        }

        return .success(
            CompletedRecording(
                url: createdFile.url,
                frameCount: headerFrameCount,
                droppedFrameCount: bufferPool.droppedFrames,
                sampleRate: sampleRate,
                terminationReason: bufferPool.reachedFileSizeLimit
                    ? .riffSizeLimit
                    : .requested
            )
        )
    }

    private static func recordFirstFailure(
        _ firstFailure: inout (phase: TerminalFailure.Phase, reason: String)?,
        phase: TerminalFailure.Phase,
        error: Error
    ) {
        guard firstFailure == nil else { return }
        firstFailure = (phase, String(describing: error))
    }

    private static func disposeCorruptFile(
        at url: URL,
        using fileSystem: any RecorderFileSystem
    ) -> TerminalFailure.FileDisposition {
        do {
            try fileSystem.removeRecordingFile(at: url)
            return .removed
        } catch {
            let removeReason = String(describing: error)
            do {
                let quarantinedURL = try fileSystem.quarantineRecordingFile(at: url)
                return .quarantined(quarantinedURL)
            } catch {
                return .cleanupFailed(
                    originalURL: url,
                    reason: "remove: \(removeReason); quarantine: \(String(describing: error))"
                )
            }
        }
    }

    // MARK: - WAV Format

    static func buildWAVHeader(dataSize: UInt32, sampleRate: Double) -> Data {
        var header = Data(capacity: 44)

        let blockAlign = channels * (bitsPerSample / 8)
        let integerSampleRate = UInt32(sampleRate.rounded())
        let byteRate = integerSampleRate.multipliedReportingOverflow(by: UInt32(blockAlign))
        let safeByteRate = byteRate.overflow ? UInt32.max : byteRate.partialValue
        let safeDataSize = min(dataSize, UInt32(maximumWAVDataByteCount))

        // RIFF chunk
        header.append(contentsOf: "RIFF".utf8)
        header.appendLE32(safeDataSize + 36)
        header.append(contentsOf: "WAVE".utf8)

        // fmt sub-chunk
        header.append(contentsOf: "fmt ".utf8)
        header.appendLE32(16)
        header.appendLE16(3)  // IEEE Float
        header.appendLE16(channels)
        header.appendLE32(integerSampleRate)
        header.appendLE32(safeByteRate)
        header.appendLE16(blockAlign)
        header.appendLE16(bitsPerSample)

        // data sub-chunk
        header.append(contentsOf: "data".utf8)
        header.appendLE32(safeDataSize)

        return header
    }

    // MARK: - Results and Errors

    struct CompletedRecording: Equatable, Sendable {
        enum TerminationReason: Equatable, Sendable {
            case requested
            case riffSizeLimit
        }

        let url: URL
        let frameCount: UInt64
        let droppedFrameCount: UInt64
        let sampleRate: Double
        let terminationReason: TerminationReason

        init(
            url: URL,
            frameCount: UInt64,
            droppedFrameCount: UInt64,
            sampleRate: Double,
            terminationReason: TerminationReason = .requested
        ) {
            self.url = url
            self.frameCount = frameCount
            self.droppedFrameCount = droppedFrameCount
            self.sampleRate = sampleRate
            self.terminationReason = terminationReason
        }

        var durationSeconds: Double {
            guard sampleRate > 0 else { return 0 }
            return Double(frameCount) / sampleRate
        }
    }

    typealias TerminalResult = Result<CompletedRecording, TerminalFailure>

    struct TerminalFailure: Error, Equatable, LocalizedError, Sendable {
        enum Phase: String, Equatable, Sendable {
            case initialHeaderWrite
            case audioWrite
            case queueOverflow
            case truncate
            case headerWrite
            case synchronize
            case close
            case workerCompletion
        }

        enum FileDisposition: Equatable, Sendable {
            case removed
            case quarantined(URL)
            case cleanupFailed(originalURL: URL, reason: String)
        }

        let phase: Phase
        let fileURL: URL
        let reason: String
        let disposition: FileDisposition
        let droppedFrameCount: UInt64

        var errorDescription: String? {
            let operation: String
            switch phase {
            case .initialHeaderWrite:
                operation = "creating the WAV header"
            case .audioWrite:
                operation = "writing audio"
            case .queueOverflow:
                operation = "keeping up with the audio input"
            case .truncate:
                operation = "removing an incomplete audio frame"
            case .headerWrite:
                operation = "finalizing the WAV header"
            case .synchronize:
                operation = "synchronizing the recording"
            case .close:
                operation = "closing the recording"
            case .workerCompletion:
                operation = "finishing the recorder worker"
            }

            let recovery: String
            switch disposition {
            case .removed:
                recovery = "The incomplete file was removed."
            case .quarantined(let url):
                recovery = "The incomplete file was marked as \(url.lastPathComponent)."
            case .cleanupFailed(let originalURL, _):
                recovery =
                    "The incomplete file could not be removed; do not use "
                    + originalURL.lastPathComponent + "."
            }
            return "Recording failed while \(operation). \(recovery)"
        }
    }

    enum RecorderError: Error, LocalizedError {
        case alreadyRecording
        case cannotCreateFile
        case initializationFailed(TerminalFailure)
        case invalidSampleRate

        var errorDescription: String? {
            switch self {
            case .alreadyRecording:
                return "A recording is already in progress."
            case .cannotCreateFile:
                return "Could not create recording file."
            case .initializationFailed(let failure):
                return failure.localizedDescription
            case .invalidSampleRate:
                return "The recording sample rate is invalid."
            }
        }
    }
}

// MARK: - Production file storage

nonisolated final class SystemRecorderFileSystem: RecorderFileSystem, @unchecked Sendable {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func createRecordingFile() throws -> RecorderCreatedFile {
        let directory = recordingDirectory()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss-SSS"
        let stem = "PhonoFlow_\(formatter.string(from: Date()))"

        var suffix = 1
        while true {
            let suffixText = suffix == 1 ? "" : "-\(suffix)"
            let url = directory.appendingPathComponent("\(stem)\(suffixText).wav")
            let descriptor = url.path.withCString {
                Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
            }
            guard descriptor >= 0 else {
                if errno == EEXIST {
                    suffix += 1
                    continue
                }
                throw AudioRecorder.RecorderError.cannotCreateFile
            }
            return RecorderCreatedFile(
                url: url,
                sink: FileHandleRecorderSink(
                    handle: FileHandle(
                        fileDescriptor: descriptor,
                        closeOnDealloc: true
                    )
                )
            )
        }
    }

    func removeRecordingFile(at url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    func quarantineRecordingFile(at url: URL) throws -> URL {
        let directory = url.deletingLastPathComponent()
        let stem = url.deletingPathExtension().lastPathComponent
        var suffix = 1

        while true {
            let suffixText = suffix == 1 ? "" : "-\(suffix)"
            let candidate = directory.appendingPathComponent(
                "\(stem).incomplete\(suffixText).corrupt"
            )
            guard !fileManager.fileExists(atPath: candidate.path) else {
                suffix += 1
                continue
            }
            try fileManager.moveItem(at: url, to: candidate)
            return candidate
        }
    }

    private func recordingDirectory() -> URL {
        let applicationSupportDirectory = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first
        let documentsDirectory = fileManager.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first
        let baseDirectory =
            applicationSupportDirectory
            ?? documentsDirectory
            ?? fileManager.temporaryDirectory
        return
            baseDirectory
            .appendingPathComponent("PhonoFlow", isDirectory: true)
            .appendingPathComponent("Recordings", isDirectory: true)
    }
}

nonisolated private final class FileHandleRecorderSink: RecorderFileSink, @unchecked Sendable {
    private var handle: FileHandle?

    init(handle: FileHandle) {
        self.handle = handle
    }

    func write(_ data: Data) throws {
        try openHandle().write(contentsOf: data)
    }

    func seek(toOffset offset: UInt64) throws {
        try openHandle().seek(toOffset: offset)
    }

    func truncate(atOffset offset: UInt64) throws {
        try openHandle().truncate(atOffset: offset)
    }

    func synchronize() throws {
        try openHandle().synchronize()
    }

    func close() throws {
        guard let handle else { return }
        try handle.close()
        self.handle = nil
    }

    private func openHandle() throws -> FileHandle {
        guard let handle else {
            throw SinkError.closed
        }
        return handle
    }

    private enum SinkError: Error {
        case closed
    }
}

nonisolated private final class RecorderTerminalBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result: AudioRecorder.TerminalResult?

    func reset() {
        lock.lock()
        result = nil
        lock.unlock()
    }

    func store(_ result: AudioRecorder.TerminalResult) {
        lock.lock()
        self.result = result
        lock.unlock()
    }

    func take() -> AudioRecorder.TerminalResult? {
        lock.lock()
        let result = result
        self.result = nil
        lock.unlock()
        return result
    }
}

// MARK: - Bounded callback-to-worker queue

nonisolated private final class RecorderBufferPool: @unchecked Sendable {
    struct ReadableBlock {
        let samples: UnsafePointer<Float>
        let frameCount: Int
    }

    private let blockCount: UInt64
    private let framesPerBlock: Int
    private let samplesPerBlock: Int
    private let maximumWAVFrames: UInt64
    private let samples: UnsafeMutablePointer<Float>
    private let frameCounts: UnsafeMutablePointer<UInt32>

    private let readSequence = Atomic<UInt64>(0)
    private let writeSequence = Atomic<UInt64>(0)
    private let producerGate = RecorderProducerGate()
    private let fileSizeLimitReached = Atomic<Bool>(false)
    private let terminalFaulted = Atomic<Bool>(false)
    private let stopping = Atomic<Bool>(false)
    private let acceptedFrameCounter = Atomic<UInt64>(0)
    private let writtenFrameCounter = Atomic<UInt64>(0)
    private let droppedBlockCounter = Atomic<UInt64>(0)
    private let droppedFrameCounter = Atomic<UInt64>(0)

    private let workAvailable = DispatchSemaphore(value: 0)
    private var workerCompletion: DispatchSemaphore?

    init(
        blockCount: Int,
        framesPerBlock: Int,
        maximumWAVDataByteCount: UInt64
    ) {
        precondition(blockCount > 1)
        precondition(framesPerBlock > 0)

        self.blockCount = UInt64(blockCount)
        self.framesPerBlock = framesPerBlock
        maximumWAVFrames =
            min(
                maximumWAVDataByteCount,
                AudioRecorder.maximumWAVDataByteCount
            ) / AudioRecorder.bytesPerFrame
        samplesPerBlock = framesPerBlock * Int(AudioRecorder.channels)
        samples = .allocate(capacity: blockCount * samplesPerBlock)
        frameCounts = .allocate(capacity: blockCount)
        samples.initialize(repeating: 0, count: blockCount * samplesPerBlock)
        frameCounts.initialize(repeating: 0, count: blockCount)
    }

    deinit {
        samples.deinitialize(count: Int(blockCount) * samplesPerBlock)
        samples.deallocate()
        frameCounts.deinitialize(count: Int(blockCount))
        frameCounts.deallocate()
    }

    var isAccepting: Bool {
        producerGate.isOpen
    }

    var reachedFileSizeLimit: Bool {
        fileSizeLimitReached.load(ordering: .acquiring)
    }

    var acceptedFrames: UInt64 {
        acceptedFrameCounter.load(ordering: .relaxed)
    }

    var writtenFrames: UInt64 {
        writtenFrameCounter.load(ordering: .relaxed)
    }

    var droppedBlocks: UInt64 {
        droppedBlockCounter.load(ordering: .relaxed)
    }

    var droppedFrames: UInt64 {
        droppedFrameCounter.load(ordering: .relaxed)
    }

    var queueDepth: Int {
        let read = readSequence.load(ordering: .acquiring)
        let write = writeSequence.load(ordering: .acquiring)
        return Int(min(write &- read, blockCount))
    }

    var shouldWorkerStop: Bool {
        stopping.load(ordering: .acquiring)
            && queueDepth == 0
            && producerGate.activeProducerCount == 0
    }

    func beginSession() {
        precondition(!producerGate.isOpen)
        precondition(producerGate.activeProducerCount == 0)
        fileSizeLimitReached.store(false, ordering: .releasing)
        terminalFaulted.store(false, ordering: .releasing)
        stopping.store(false, ordering: .releasing)
        readSequence.store(0, ordering: .releasing)
        writeSequence.store(0, ordering: .releasing)
        acceptedFrameCounter.store(0, ordering: .relaxed)
        writtenFrameCounter.store(0, ordering: .relaxed)
        droppedBlockCounter.store(0, ordering: .relaxed)
        droppedFrameCounter.store(0, ordering: .relaxed)

        // Each published block consumes one wake token. A stop request adds
        // one final token, which a completed worker normally consumes.
        while workAvailable.wait(timeout: .now()) == .success {}
        workerCompletion = nil
    }

    func startAccepting(completion: DispatchSemaphore) {
        workerCompletion = completion
        producerGate.open()
    }

    func enqueue(_ source: UnsafePointer<Float>, frameCount: Int) {
        guard producerGate.beginProducing() else { return }
        defer {
            producerGate.endProducing()
            if stopping.load(ordering: .acquiring) {
                workAvailable.signal()
            }
        }

        var remainingFrames = frameCount
        var sourceOffset = 0
        while remainingFrames > 0 {
            let acceptedFrames = acceptedFrameCounter.load(ordering: .relaxed)
            guard acceptedFrames < maximumWAVFrames else {
                reachFileSizeLimit()
                return
            }

            let availableWAVFrames = Int(
                min(maximumWAVFrames - acceptedFrames, UInt64(Int.max))
            )
            let framesToCopy = min(
                remainingFrames,
                framesPerBlock,
                availableWAVFrames
            )
            let write = writeSequence.load(ordering: .relaxed)
            let read = readSequence.load(ordering: .acquiring)

            guard write &- read < blockCount else {
                recordDropped(frames: remainingFrames)
                latchQueueOverflow()
                return
            }

            let slot = Int(write % blockCount)
            let destination = samples.advanced(by: slot * samplesPerBlock)
            let sourceSamples = source.advanced(
                by: sourceOffset * Int(AudioRecorder.channels)
            )
            let sampleCount = framesToCopy * Int(AudioRecorder.channels)
            memcpy(
                destination,
                sourceSamples,
                sampleCount * MemoryLayout<Float>.size
            )
            frameCounts[slot] = UInt32(framesToCopy)

            writeSequence.store(write &+ 1, ordering: .releasing)
            acceptedFrameCounter.wrappingAdd(
                UInt64(framesToCopy),
                ordering: .relaxed
            )
            workAvailable.signal()

            remainingFrames -= framesToCopy
            sourceOffset += framesToCopy

            if acceptedFrames + UInt64(framesToCopy) == maximumWAVFrames {
                reachFileSizeLimit()
                return
            }
        }
    }

    func stopAcceptingAndWaitForProducer() {
        producerGate.closeAndWait()
    }

    func requestWorkerStop() {
        stopping.store(true, ordering: .releasing)
        workAvailable.signal()
    }

    func abortAfterWorkerFailure() {
        _ = terminalFaulted.exchange(true, ordering: .acquiringAndReleasing)
        producerGate.closeAndWait()
        stopping.store(true, ordering: .releasing)
        workAvailable.signal()
    }

    func waitForWorker() {
        workerCompletion?.wait()
        workerCompletion = nil
    }

    func waitForWork() {
        workAvailable.wait()
    }

    func nextReadableBlock() -> ReadableBlock? {
        let read = readSequence.load(ordering: .relaxed)
        let write = writeSequence.load(ordering: .acquiring)
        guard read != write else { return nil }

        let slot = Int(read % blockCount)
        return ReadableBlock(
            samples: UnsafePointer(samples.advanced(by: slot * samplesPerBlock)),
            frameCount: Int(frameCounts[slot])
        )
    }

    func finishReadingBlock() {
        let read = readSequence.load(ordering: .relaxed)
        readSequence.store(read &+ 1, ordering: .releasing)
    }

    func recordWrittenFrames(_ frameCount: Int) {
        writtenFrameCounter.wrappingAdd(UInt64(frameCount), ordering: .relaxed)
    }

    func recordDiscardedFrames(_ frameCount: Int) {
        recordDropped(frames: frameCount)
    }

    func reportUpstreamDroppedFrames(_ frameCount: UInt64) {
        guard frameCount > 0 else { return }
        droppedFrameCounter.wrappingAdd(frameCount, ordering: .relaxed)
        latchQueueOverflow()
    }

    private func recordDropped(frames: Int) {
        let droppedBlocks = UInt64((frames + framesPerBlock - 1) / framesPerBlock)
        droppedBlockCounter.wrappingAdd(droppedBlocks, ordering: .relaxed)
        droppedFrameCounter.wrappingAdd(UInt64(frames), ordering: .relaxed)
    }

    private func reachFileSizeLimit() {
        fileSizeLimitReached.store(true, ordering: .releasing)
        producerGate.close()
        stopping.store(true, ordering: .releasing)
        workAvailable.signal()
    }

    private func latchQueueOverflow() {
        let wasFaulted = terminalFaulted.exchange(
            true,
            ordering: .acquiringAndReleasing
        )
        producerGate.close()
        guard !wasFaulted else { return }
        stopping.store(true, ordering: .releasing)
        workAvailable.signal()
    }
}

/// Atomically couples admission with the number of active real-time writers.
///
/// Closing the gate and observing a zero producer count forms an epoch
/// boundary: a writer from the prior recording can neither register after the
/// boundary nor decrement a counter reset for the next recording.
nonisolated final class RecorderProducerGate: @unchecked Sendable {
    private static let openMask: UInt64 = 1 << 63
    private static let producerMask = ~openMask

    private let state = Atomic<UInt64>(0)

    var isOpen: Bool {
        state.load(ordering: .acquiring) & Self.openMask != 0
    }

    var activeProducerCount: UInt64 {
        state.load(ordering: .acquiring) & Self.producerMask
    }

    func open() {
        let result = state.compareExchange(
            expected: 0,
            desired: Self.openMask,
            ordering: .acquiringAndReleasing
        )
        precondition(result.exchanged)
    }

    func beginProducing() -> Bool {
        var current = state.load(ordering: .acquiring)
        while current & Self.openMask != 0 {
            let producerCount = current & Self.producerMask
            guard producerCount < Self.producerMask else { return false }

            let result = state.compareExchange(
                expected: current,
                desired: current &+ 1,
                ordering: .acquiringAndReleasing
            )
            if result.exchanged {
                return true
            }
            current = result.original
        }
        return false
    }

    func endProducing() {
        let previous = state.wrappingSubtract(1, ordering: .releasing)
        precondition(previous.oldValue & Self.producerMask > 0)
    }

    func close() {
        var current = state.load(ordering: .acquiring)
        while current & Self.openMask != 0 {
            let result = state.compareExchange(
                expected: current,
                desired: current & Self.producerMask,
                ordering: .acquiringAndReleasing
            )
            if result.exchanged {
                return
            }
            current = result.original
        }
    }

    func closeAndWait() {
        close()
        while activeProducerCount != 0 {
            sched_yield()
        }
    }
}

// MARK: - Data Helpers

nonisolated extension Data {
    fileprivate mutating func appendLE16(_ value: UInt16) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    fileprivate mutating func appendLE32(_ value: UInt32) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
