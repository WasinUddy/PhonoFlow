//
//  AudioPipelineWorker.swift
//  PhonoFlow
//
//  Bounded, off-real-time audio fanout and continuous spectrogram processing.
//

import CoreGraphics
import Darwin
import Foundation
import PhonoFlowCore
import Synchronization

/// App-local names retained for call-site and test compatibility. Both aliases
/// resolve to the instrumented core implementation used by release benchmarks.
typealias NativeSpectrogramFrame = SpectrogramRenderFrame

/// Owns every operation that may allocate or block after the Core Audio input
/// callback: sample-rate conversion, interleaving, WAV conversion, recording
/// enqueueing, FFT analysis, image creation, and actor/network fanout.
nonisolated final class AudioPipelineWorker: @unchecked Sendable {
    private static let ringCapacity = 65_536
    private static let drainFrames = 2_048

    private let nativeMailbox = NativeSpectrogramMailbox()
    private let analysisLane: AnalysisPipelineLane
    private let recordingLane: RecordingPipelineLane
    private let networkLane: NetworkPipelineLane
    private var analysisTask: Task<Void, Never>?
    private var networkTask: Task<Void, Never>?

    init(
        analysisBlockDelayNanoseconds: UInt64 = 0,
        networkBlockDelayNanoseconds: UInt64 = 0,
        ringCapacity: Int = AudioPipelineWorker.ringCapacity
    ) {
        analysisLane = AnalysisPipelineLane(
            ringCapacity: ringCapacity,
            drainFrames: Self.drainFrames,
            nativeMailbox: nativeMailbox,
            blockDelayNanoseconds: analysisBlockDelayNanoseconds
        )
        recordingLane = RecordingPipelineLane(
            ringCapacity: ringCapacity,
            drainFrames: Self.drainFrames
        )
        networkLane = NetworkPipelineLane(
            ringCapacity: ringCapacity,
            drainFrames: Self.drainFrames,
            blockDelayNanoseconds: networkBlockDelayNanoseconds
        )

        let analysisLane = analysisLane
        analysisTask = Task.detached(priority: .userInitiated) {
            await analysisLane.run()
        }
        let networkLane = networkLane
        networkTask = Task.detached(priority: .userInitiated) {
            await networkLane.run()
        }
    }

    deinit {
        recordingLane.shutdown()
        analysisLane.shutdown()
        networkLane.shutdown()
        analysisTask?.cancel()
        networkTask?.cancel()
    }

    // MARK: - Real-time producer

    /// Called only by the input callback. Each interested consumer receives an
    /// independent bounded copy, so an FFT or slow network client can never
    /// delay recording. No allocation, actor hop, or lock occurs here.
    func enqueue(
        left: UnsafePointer<Float>,
        right: UnsafePointer<Float>,
        count: Int,
        captureTimestampNanoseconds: UInt64 = 0
    ) {
        analysisLane.enqueue(
            left: left,
            right: right,
            count: count,
            captureTimestampNanoseconds: captureTimestampNanoseconds
        )
        recordingLane.enqueue(left: left, right: right, count: count)
        networkLane.enqueue(left: left, right: right, count: count)
    }

    // MARK: - Main/coordinator configuration

    func configure(sampleRate: Double) {
        guard sampleRate.isFinite, sampleRate > 0 else { return }
        let uptime = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        analysisLane.configure(
            sampleRate: sampleRate,
            wallClockAnchor: Date(),
            uptimeAnchorNanoseconds: uptime
        )
        networkLane.configure(sampleRate: sampleRate)
    }

    func attach(
        remoteAudio: RemoteAudioFanout?,
        remoteServer: RemoteAccessServer?
    ) {
        analysisLane.setRemoteServer(remoteServer)
        networkLane.attach(remoteAudio)
    }

    func setNativePublisher(
        _ publisher: (@MainActor @Sendable (NativeSpectrogramFrame) -> Void)?
    ) {
        nativeMailbox.setPublisher(publisher)
    }

    func setNativeVisualizationEnabled(_ enabled: Bool) {
        analysisLane.setNativeVisualizationEnabled(enabled)
    }

    func setRemoteSpectrumSubscribersVisible(_ visible: Bool) {
        analysisLane.setRemoteSpectrumSubscribersVisible(visible)
    }

    func setRemoteAudioSubscribersVisible(_ visible: Bool) {
        networkLane.setBrowserSubscribersVisible(visible)
    }

    func setLegacyStreamingEnabled(_ enabled: Bool) {
        networkLane.setLegacyStreamingEnabled(enabled)
    }

    /// The call is synchronous so starting/stopping a recording establishes a
    /// precise boundary after every already-accepted worker block.
    func setRecorder(_ recorder: AudioRecorder?) {
        recordingLane.setRecorder(recorder)
    }

    func clearNativeHistory() {
        analysisLane.clearHistory()
        nativeMailbox.clear()
    }

    func stopAndDrain() {
        // Recording is fenced first so finalization never waits behind
        // analysis or a suspended network actor.
        recordingLane.setRecorder(nil)
        networkLane.drainAndDisableLegacyStreaming()
        analysisLane.waitUntilDrained()
    }

    // MARK: - Diagnostics

    var analysisDroppedFrames: UInt64 {
        analysisLane.droppedFrames
    }

    var fanoutDroppedFrames: UInt64 {
        recordingLane.droppedFrames &+ networkLane.droppedFrames
    }

    var analysisQueueDepth: Int {
        analysisLane.queueDepth
    }

    var fanoutQueueDepth: Int {
        recordingLane.queueDepth + networkLane.queueDepth
    }

    var recordingQueueDepth: Int {
        recordingLane.queueDepth
    }

    var recordingDroppedFrames: UInt64 {
        recordingLane.droppedFrames
    }

    var networkQueueDepth: Int {
        networkLane.queueDepth
    }

    var networkDroppedFrames: UInt64 {
        networkLane.droppedFrames
    }

    var skippedNativeFrames: UInt64 {
        nativeMailbox.skippedFrames
    }
}

// MARK: - Independent analysis lane

nonisolated private struct AnalysisPipelineConfiguration: Sendable {
    var sourceSampleRate: Double = 44_100
    var wallClockAnchor = Date()
    var uptimeAnchorNanoseconds = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    var remoteServer: RemoteAccessServer?
    var analysisEnabled = false
    var streamRevision: UInt64 = 0
    var clearHistoryRevision: UInt64 = 0
}

nonisolated private final class AnalysisPipelineLane: @unchecked Sendable {
    private static let blockBudget = 4
    private static let activePollNanoseconds: UInt64 = 1_000_000
    private static let inactivePollNanoseconds: UInt64 = 5_000_000

    private let ring: PipelineStereoRing
    private let drainFrames: Int
    private let nativeMailbox: NativeSpectrogramMailbox
    private let processor: SpectrogramProcessor?
    private let blockDelayNanoseconds: UInt64
    private let nativeWanted = Atomic<Bool>(false)
    private let remoteWanted = Atomic<Bool>(false)
    private let producerGate = PipelineProducerGate()
    private let firstCaptureTimestamp = Atomic<UInt64>(0)
    private let discontinuityPending = Atomic<Bool>(false)
    private let droppedFrameCount = Atomic<UInt64>(0)
    private let stopped = Atomic<Bool>(false)
    private let processing = Atomic<Bool>(false)
    private let appliedStreamRevision = Atomic<UInt64>(0)
    private let configuration = Mutex(AnalysisPipelineConfiguration())
    private let stateCondition = PipelineStateCondition()
    private let controlLock = NSLock()
    private let leftScratch: UnsafeMutablePointer<Float>
    private let rightScratch: UnsafeMutablePointer<Float>
    private var leftBlock: [Float]
    private var rightBlock: [Float]
    private var history: [SpectrogramColumn] = []

    init(
        ringCapacity: Int,
        drainFrames: Int,
        nativeMailbox: NativeSpectrogramMailbox,
        blockDelayNanoseconds: UInt64
    ) {
        ring = PipelineStereoRing(capacity: ringCapacity)
        self.drainFrames = drainFrames
        self.nativeMailbox = nativeMailbox
        self.blockDelayNanoseconds = blockDelayNanoseconds
        processor = try? SpectrogramProcessor()
        leftScratch = .allocate(capacity: drainFrames)
        rightScratch = .allocate(capacity: drainFrames)
        leftScratch.initialize(repeating: 0, count: drainFrames)
        rightScratch.initialize(repeating: 0, count: drainFrames)
        leftBlock = [Float](repeating: 0, count: drainFrames)
        rightBlock = [Float](repeating: 0, count: drainFrames)
        history.reserveCapacity(SpectrogramProcessor.historyCapacity)
    }

    deinit {
        leftScratch.deallocate()
        rightScratch.deallocate()
    }

    func enqueue(
        left: UnsafePointer<Float>,
        right: UnsafePointer<Float>,
        count: Int,
        captureTimestampNanoseconds: UInt64
    ) {
        guard count > 0 else { return }
        guard producerGate.beginProducing() else {
            if nativeWanted.load(ordering: .acquiring)
                || remoteWanted.load(ordering: .acquiring)
            {
                droppedFrameCount.wrappingAdd(
                    UInt64(count),
                    ordering: .relaxed
                )
                discontinuityPending.store(true, ordering: .releasing)
            }
            return
        }
        defer { producerGate.endProducing() }
        guard !discontinuityPending.load(ordering: .acquiring) else {
            droppedFrameCount.wrappingAdd(UInt64(count), ordering: .relaxed)
            return
        }
        let timestamp =
            captureTimestampNanoseconds == 0
            ? clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            : captureTimestampNanoseconds
        _ = firstCaptureTimestamp.compareExchange(
            expected: 0,
            desired: timestamp,
            ordering: .acquiringAndReleasing
        )
        let result = ring.writeResult(left: left, right: right, count: count)
        if result.droppedFrames > 0 {
            droppedFrameCount.wrappingAdd(
                result.droppedFrames,
                ordering: .relaxed
            )
            discontinuityPending.store(true, ordering: .releasing)
        }
    }

    func configure(
        sampleRate: Double,
        wallClockAnchor: Date,
        uptimeAnchorNanoseconds: UInt64
    ) {
        controlLock.lock()
        defer { controlLock.unlock() }
        let enabled = producerGate.isAccepting
        producerGate.closeAndFence()
        let revision = configuration.withLock { value -> UInt64 in
            value.sourceSampleRate = sampleRate
            value.wallClockAnchor = wallClockAnchor
            value.uptimeAnchorNanoseconds = uptimeAnchorNanoseconds
            value.analysisEnabled = enabled
            value.streamRevision &+= 1
            return value.streamRevision
        }
        waitForStreamRevision(revision)
        producerGate.setAccepting(enabled)
    }

    func setRemoteServer(_ server: RemoteAccessServer?) {
        controlLock.lock()
        defer { controlLock.unlock() }
        guard
            configuration.withLock({ $0.remoteServer !== server })
        else {
            return
        }
        let enabled = producerGate.isAccepting
        producerGate.closeAndFence()
        let revision = configuration.withLock { value -> UInt64 in
            value.remoteServer = server
            value.streamRevision &+= 1
            return value.streamRevision
        }
        waitForStreamRevision(revision)
        producerGate.setAccepting(enabled)
    }

    func setNativeVisualizationEnabled(_ enabled: Bool) {
        nativeWanted.store(enabled, ordering: .releasing)
        updateDemand()
    }

    func setRemoteSpectrumSubscribersVisible(_ visible: Bool) {
        remoteWanted.store(visible, ordering: .releasing)
        updateDemand()
    }

    func clearHistory() {
        configuration.withLock {
            $0.clearHistoryRevision &+= 1
        }
    }

    func waitUntilDrained() {
        controlLock.lock()
        defer { controlLock.unlock() }
        let reopen = producerGate.isAccepting
        producerGate.closeAndFence()
        stateCondition.wait {
            ring.fillLevel > 0
                || processing.load(ordering: .acquiring)
                || discontinuityPending.load(ordering: .acquiring)
        }
        producerGate.setAccepting(reopen)
    }

    func shutdown() {
        controlLock.lock()
        defer { controlLock.unlock() }
        producerGate.closeAndFence()
        stopped.store(true, ordering: .releasing)
        stateCondition.notifyAll()
    }

    var droppedFrames: UInt64 {
        droppedFrameCount.load(ordering: .relaxed)
    }

    var queueDepth: Int {
        ring.fillLevel
    }

    func run() async {
        var streamRevision: UInt64 = .max
        var historyRevision: UInt64 = .max
        while !stopped.load(ordering: .acquiring) {
            processing.store(true, ordering: .releasing)

            let snapshot = configuration.withLock { $0 }
            if streamRevision != snapshot.streamRevision {
                let discarded = ring.discardPending()
                if discarded > 0 {
                    droppedFrameCount.wrappingAdd(
                        discarded,
                        ordering: .relaxed
                    )
                }
                firstCaptureTimestamp.store(0, ordering: .releasing)
                discontinuityPending.store(false, ordering: .releasing)
                if let processor {
                    await processor.setAnalysisEnabled(false)
                    await processor.setAnalysisEnabled(
                        snapshot.analysisEnabled
                    )
                }
                streamRevision = snapshot.streamRevision
                appliedStreamRevision.store(
                    streamRevision,
                    ordering: .releasing
                )
                stateCondition.notifyAll()
            }
            if historyRevision != snapshot.clearHistoryRevision {
                history.removeAll(keepingCapacity: true)
                historyRevision = snapshot.clearHistoryRevision
            }

            if snapshot.analysisEnabled, processor != nil {
                await drainBudget(configuration: snapshot)
                if ring.fillLevel == 0,
                    discontinuityPending.load(ordering: .acquiring)
                {
                    await restartAfterDiscontinuity(
                        analysisEnabled: snapshot.analysisEnabled
                    )
                }
            } else {
                ring.discardPending()
                discontinuityPending.store(false, ordering: .releasing)
                firstCaptureTimestamp.store(0, ordering: .releasing)
            }
            processing.store(false, ordering: .releasing)
            stateCondition.notifyAll()

            if ring.fillLevel > 0 {
                await Task.yield()
            } else {
                let interval =
                    snapshot.analysisEnabled
                    ? Self.activePollNanoseconds
                    : Self.inactivePollNanoseconds
                try? await Task.sleep(nanoseconds: interval)
            }
        }
        processing.store(false, ordering: .releasing)
        stateCondition.notifyAll()
    }

    private func updateDemand() {
        controlLock.lock()
        defer { controlLock.unlock() }
        let wanted =
            nativeWanted.load(ordering: .acquiring)
            || remoteWanted.load(ordering: .acquiring)
        let old = producerGate.isAccepting
        guard old != wanted else { return }
        producerGate.closeAndFence()
        let revision = configuration.withLock { value -> UInt64 in
            value.analysisEnabled = wanted
            value.streamRevision &+= 1
            return value.streamRevision
        }
        waitForStreamRevision(revision)
        producerGate.setAccepting(wanted)
    }

    private func drainBudget(
        configuration: AnalysisPipelineConfiguration
    ) async {
        guard let processor else { return }
        for _ in 0..<Self.blockBudget {
            let frameCount = ring.read(
                left: leftScratch,
                right: rightScratch,
                maximumCount: drainFrames
            )
            guard frameCount > 0 else { break }

            resizeReusableBlock(&leftBlock, to: frameCount)
            resizeReusableBlock(&rightBlock, to: frameCount)
            leftBlock.withUnsafeMutableBufferPointer { destination in
                guard let baseAddress = destination.baseAddress else { return }
                memcpy(
                    baseAddress,
                    leftScratch,
                    frameCount * MemoryLayout<Float>.stride
                )
            }
            rightBlock.withUnsafeMutableBufferPointer { destination in
                guard let baseAddress = destination.baseAddress else { return }
                memcpy(
                    baseAddress,
                    rightScratch,
                    frameCount * MemoryLayout<Float>.stride
                )
            }

            if blockDelayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: blockDelayNanoseconds)
            }
            let captureTimestamp = firstCaptureTimestamp.load(
                ordering: .acquiring
            )
            let columns =
                (try? await processor.process(
                    left: leftBlock,
                    right: rightBlock,
                    sourceSampleRate: configuration.sourceSampleRate,
                    timestampNanoseconds: captureTimestamp
                )) ?? []
            for column in columns {
                await publish(column, configuration: configuration)
            }
        }
    }

    private func publish(
        _ column: SpectrogramColumn,
        configuration: AnalysisPipelineConfiguration
    ) async {
        if history.count == SpectrogramProcessor.historyCapacity {
            history.removeFirst()
        }
        history.append(column)

        if nativeWanted.load(ordering: .acquiring),
            let image = SpectrogramImageRenderer.makeImage(columns: history)
        {
            nativeMailbox.offer(
                NativeSpectrogramFrame(column: column, image: image)
            )
        }

        if remoteWanted.load(ordering: .acquiring),
            let remoteServer = configuration.remoteServer
        {
            let delta =
                column.timestampNanoseconds
                    >= configuration.uptimeAnchorNanoseconds
                ? column.timestampNanoseconds
                    - configuration.uptimeAnchorNanoseconds
                : 0
            await remoteServer.publish(
                spectrogram: RemoteSpectrogramColumn(
                    sequence: column.sequence,
                    timestamp: configuration.wallClockAnchor.addingTimeInterval(
                        Double(delta) / 1_000_000_000
                    ),
                    intensities: column.intensities
                )
            )
        }
    }

    private func waitForStreamRevision(_ revision: UInt64) {
        stateCondition.wait {
            appliedStreamRevision.load(ordering: .acquiring) != revision
                && !stopped.load(ordering: .acquiring)
        }
    }

    private func restartAfterDiscontinuity(
        analysisEnabled: Bool
    ) async {
        guard discontinuityPending.load(ordering: .acquiring) else { return }
        if let processor {
            await processor.setAnalysisEnabled(false)
            await processor.setAnalysisEnabled(analysisEnabled)
        }
        firstCaptureTimestamp.store(0, ordering: .releasing)
        discontinuityPending.store(false, ordering: .releasing)
    }
}

// MARK: - Independent recording lane

nonisolated private final class RecordingPipelineLane: @unchecked Sendable {
    private static let blockBudget = 8
    private static let pollInterval = DispatchTimeInterval.microseconds(1_000)

    private let ring: PipelineStereoRing
    private let drainFrames: Int
    private let queue = DispatchQueue(
        label: "com.phonoflow.audio-pipeline.recording",
        qos: .userInitiated,
        autoreleaseFrequency: .workItem
    )
    private let pollTimer: DispatchSourceTimer
    private let producerGate = PipelineProducerGate()
    private let pendingDroppedFrames = Atomic<UInt64>(0)
    private let stopped = Atomic<Bool>(false)
    private let controlLock = NSLock()
    private let leftScratch: UnsafeMutablePointer<Float>
    private let rightScratch: UnsafeMutablePointer<Float>
    private let interleaved: UnsafeMutablePointer<Float>
    private var recorder: AudioRecorder?

    init(ringCapacity: Int, drainFrames: Int) {
        ring = PipelineStereoRing(capacity: ringCapacity)
        self.drainFrames = drainFrames
        leftScratch = .allocate(capacity: drainFrames)
        rightScratch = .allocate(capacity: drainFrames)
        interleaved = .allocate(capacity: drainFrames * 2)
        leftScratch.initialize(repeating: 0, count: drainFrames)
        rightScratch.initialize(repeating: 0, count: drainFrames)
        interleaved.initialize(repeating: 0, count: drainFrames * 2)

        let timer = DispatchSource.makeTimerSource(queue: queue)
        pollTimer = timer
        timer.schedule(deadline: .distantFuture)
        timer.setEventHandler { [weak self] in
            self?.drainBudget()
        }
        timer.resume()
    }

    deinit {
        shutdown()
        leftScratch.deallocate()
        rightScratch.deallocate()
        interleaved.deallocate()
    }

    func enqueue(
        left: UnsafePointer<Float>,
        right: UnsafePointer<Float>,
        count: Int
    ) {
        guard producerGate.beginProducing() else { return }
        defer { producerGate.endProducing() }
        let result = ring.writeResult(left: left, right: right, count: count)
        if result.droppedFrames > 0 {
            pendingDroppedFrames.wrappingAdd(
                result.droppedFrames,
                ordering: .relaxed
            )
        }
    }

    func setRecorder(_ recorder: AudioRecorder?) {
        controlLock.lock()
        defer { controlLock.unlock() }
        guard !stopped.load(ordering: .acquiring) else { return }
        producerGate.closeAndFence()
        queue.sync {
            drainAll()
            reportPendingDrops()
            self.recorder = recorder
            schedulePolling(enabled: recorder != nil)
        }
        producerGate.setAccepting(recorder != nil)
    }

    func shutdown() {
        controlLock.lock()
        defer { controlLock.unlock() }
        let transition = stopped.compareExchange(
            expected: false,
            desired: true,
            ordering: .acquiringAndReleasing
        )
        guard transition.exchanged else { return }
        producerGate.closeAndFence()
        queue.sync {
            schedulePolling(enabled: false)
            drainAll()
            reportPendingDrops()
            recorder = nil
        }
        pollTimer.setEventHandler {}
        pollTimer.cancel()
        queue.sync {}
    }

    var droppedFrames: UInt64 {
        ring.droppedFrames
    }

    var queueDepth: Int {
        ring.fillLevel
    }

    private func drainBudget() {
        reportPendingDrops()
        for _ in 0..<Self.blockBudget {
            guard drainOneBlock() else { return }
        }
    }

    private func drainAll() {
        while drainOneBlock() {}
    }

    private func reportPendingDrops() {
        let dropped = pendingDroppedFrames.exchange(0, ordering: .acquiringAndReleasing)
        if dropped > 0 {
            recorder?.reportUpstreamDroppedFrames(dropped)
        }
    }

    private func schedulePolling(enabled: Bool) {
        if enabled {
            pollTimer.schedule(
                deadline: .now(),
                repeating: Self.pollInterval,
                leeway: .microseconds(250)
            )
        } else {
            pollTimer.schedule(deadline: .distantFuture)
        }
    }

    private func drainOneBlock() -> Bool {
        let frameCount = ring.read(
            left: leftScratch,
            right: rightScratch,
            maximumCount: drainFrames
        )
        guard frameCount > 0 else { return false }
        for index in 0..<frameCount {
            interleaved[index * 2] = leftScratch[index]
            interleaved[index * 2 + 1] = rightScratch[index]
        }
        recorder?.write(interleaved, frameCount: frameCount)
        return true
    }
}

// MARK: - Independent network lane

nonisolated private struct NetworkPipelineConfiguration: Sendable {
    var sourceSampleRate: Double = 44_100
    var remoteAudio: RemoteAudioFanout?
    var browserSubscribersVisible = false
    var legacyStreamingEnabled = false
    var revision: UInt64 = 0

    var wantsAudio: Bool {
        remoteAudio != nil
            && (browserSubscribersVisible || legacyStreamingEnabled)
    }
}

nonisolated private final class NetworkPipelineLane: @unchecked Sendable {
    private static let blockBudget = 4
    private static let initialResampledFrameCapacity = 8_192
    private static let activePollNanoseconds: UInt64 = 1_000_000
    private static let inactivePollNanoseconds: UInt64 = 5_000_000

    private let ring: PipelineStereoRing
    private let drainFrames: Int
    private let blockDelayNanoseconds: UInt64
    private let producerGate = PipelineProducerGate()
    private let stopped = Atomic<Bool>(false)
    private let processing = Atomic<Bool>(false)
    private let appliedRevision = Atomic<UInt64>(0)
    private let configuration = Mutex(NetworkPipelineConfiguration())
    private let stateCondition = PipelineStateCondition()
    private let controlLock = NSLock()
    private let leftScratch: UnsafeMutablePointer<Float>
    private let rightScratch: UnsafeMutablePointer<Float>
    private let interleaved: UnsafeMutablePointer<Float>
    private var normalizedLeft: UnsafeMutablePointer<Float>
    private var normalizedRight: UnsafeMutablePointer<Float>
    private var pcm16: UnsafeMutablePointer<Int16>
    private var resampledFrameCapacity: Int
    private var leftNormalizer = PointerLinearSampleRateNormalizer()
    private var rightNormalizer = PointerLinearSampleRateNormalizer()

    init(
        ringCapacity: Int,
        drainFrames: Int,
        blockDelayNanoseconds: UInt64
    ) {
        ring = PipelineStereoRing(capacity: ringCapacity)
        self.drainFrames = drainFrames
        self.blockDelayNanoseconds = blockDelayNanoseconds
        leftScratch = .allocate(capacity: drainFrames)
        rightScratch = .allocate(capacity: drainFrames)
        interleaved = .allocate(capacity: drainFrames * 2)
        resampledFrameCapacity = Self.initialResampledFrameCapacity
        normalizedLeft = .allocate(capacity: resampledFrameCapacity)
        normalizedRight = .allocate(capacity: resampledFrameCapacity)
        pcm16 = .allocate(capacity: resampledFrameCapacity * 2)
        leftScratch.initialize(repeating: 0, count: drainFrames)
        rightScratch.initialize(repeating: 0, count: drainFrames)
        interleaved.initialize(repeating: 0, count: drainFrames * 2)
        normalizedLeft.initialize(
            repeating: 0,
            count: resampledFrameCapacity
        )
        normalizedRight.initialize(
            repeating: 0,
            count: resampledFrameCapacity
        )
        pcm16.initialize(
            repeating: 0,
            count: resampledFrameCapacity * 2
        )
    }

    deinit {
        leftScratch.deallocate()
        rightScratch.deallocate()
        interleaved.deallocate()
        normalizedLeft.deallocate()
        normalizedRight.deallocate()
        pcm16.deallocate()
    }

    func enqueue(
        left: UnsafePointer<Float>,
        right: UnsafePointer<Float>,
        count: Int
    ) {
        guard producerGate.beginProducing() else { return }
        defer { producerGate.endProducing() }
        _ = ring.writeResult(left: left, right: right, count: count)
    }

    func configure(sampleRate: Double) {
        controlLock.lock()
        defer { controlLock.unlock() }
        guard
            configuration.withLock({ $0.sourceSampleRate != sampleRate })
        else {
            return
        }
        suspendProducerAndDrain()
        let revision = configuration.withLock { value -> UInt64 in
            value.sourceSampleRate = sampleRate
            value.revision &+= 1
            return value.revision
        }
        waitForRevision(revision)
        refreshDemand()
    }

    func attach(_ remoteAudio: RemoteAudioFanout?) {
        controlLock.lock()
        defer { controlLock.unlock() }
        guard
            configuration.withLock({ configured in
                configured.remoteAudio !== remoteAudio
            })
        else {
            return
        }
        suspendProducerAndDrain()
        let revision = configuration.withLock { value -> UInt64 in
            value.remoteAudio = remoteAudio
            value.revision &+= 1
            return value.revision
        }
        waitForRevision(revision)
        refreshDemand()
    }

    func setBrowserSubscribersVisible(_ visible: Bool) {
        updateDemand(
            \.browserSubscribersVisible,
            value: visible
        )
    }

    func setLegacyStreamingEnabled(_ enabled: Bool) {
        updateDemand(
            \.legacyStreamingEnabled,
            value: enabled
        )
    }

    func drainAndDisableLegacyStreaming() {
        controlLock.lock()
        defer { controlLock.unlock() }
        suspendProducerAndDrain()
        configuration.withLock { $0.legacyStreamingEnabled = false }
        refreshDemand()
    }

    func shutdown() {
        controlLock.lock()
        defer { controlLock.unlock() }
        producerGate.closeAndFence()
        waitUntilDrained()
        stopped.store(true, ordering: .releasing)
        stateCondition.notifyAll()
    }

    var droppedFrames: UInt64 {
        ring.droppedFrames
    }

    var queueDepth: Int {
        ring.fillLevel
    }

    func run() async {
        var revision: UInt64 = .max
        while !stopped.load(ordering: .acquiring) {
            processing.store(true, ordering: .releasing)

            let snapshot = configuration.withLock { $0 }
            if revision != snapshot.revision {
                leftNormalizer.reset()
                rightNormalizer.reset()
                if let remoteAudio = snapshot.remoteAudio {
                    await remoteAudio.setLegacySampleRate(
                        UInt32(snapshot.sourceSampleRate.rounded())
                    )
                }
                revision = snapshot.revision
                appliedRevision.store(revision, ordering: .releasing)
                stateCondition.notifyAll()
            }
            await drainBudget()
            processing.store(false, ordering: .releasing)
            stateCondition.notifyAll()

            if ring.fillLevel > 0 {
                await Task.yield()
            } else {
                let interval =
                    snapshot.wantsAudio
                    ? Self.activePollNanoseconds
                    : Self.inactivePollNanoseconds
                try? await Task.sleep(nanoseconds: interval)
            }
        }
        processing.store(false, ordering: .releasing)
        stateCondition.notifyAll()
    }

    private func updateDemand(
        _ keyPath: WritableKeyPath<NetworkPipelineConfiguration, Bool>,
        value: Bool
    ) {
        controlLock.lock()
        defer { controlLock.unlock() }
        guard
            configuration.withLock({ $0[keyPath: keyPath] != value })
        else {
            return
        }
        suspendProducerAndDrain()
        configuration.withLock { $0[keyPath: keyPath] = value }
        refreshDemand()
    }

    private func refreshDemand() {
        let wanted = configuration.withLock(\.wantsAudio)
        producerGate.setAccepting(wanted)
    }

    private func suspendProducerAndDrain() {
        producerGate.closeAndFence()
        waitUntilDrained()
    }

    private func waitUntilDrained() {
        stateCondition.wait {
            ring.fillLevel > 0 || processing.load(ordering: .acquiring)
        }
    }

    private func drainBudget() async {
        for _ in 0..<Self.blockBudget {
            let frameCount = ring.read(
                left: leftScratch,
                right: rightScratch,
                maximumCount: drainFrames
            )
            guard frameCount > 0 else { break }
            let snapshot = configuration.withLock { $0 }
            guard let remoteAudio = snapshot.remoteAudio else { continue }
            if blockDelayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: blockDelayNanoseconds)
            }

            let legacyData: Data?
            if snapshot.legacyStreamingEnabled {
                for index in 0..<frameCount {
                    interleaved[index * 2] = leftScratch[index]
                    interleaved[index * 2 + 1] = rightScratch[index]
                }
                legacyData = Data(
                    bytes: interleaved,
                    count: frameCount * 2 * MemoryLayout<Float>.stride
                )
            } else {
                legacyData = nil
            }

            let browserData: Data?
            if snapshot.browserSubscribersVisible {
                ensureResampledCapacity(
                    sourceFrameCount: frameCount,
                    sourceSampleRate: snapshot.sourceSampleRate
                )
                let leftCount = leftNormalizer.process(
                    leftScratch,
                    count: frameCount,
                    sourceSampleRate: snapshot.sourceSampleRate,
                    targetSampleRate: 48_000,
                    output: normalizedLeft,
                    outputCapacity: resampledFrameCapacity
                )
                let rightCount = rightNormalizer.process(
                    rightScratch,
                    count: frameCount,
                    sourceSampleRate: snapshot.sourceSampleRate,
                    targetSampleRate: 48_000,
                    output: normalizedRight,
                    outputCapacity: resampledFrameCapacity
                )
                let outputCount = min(leftCount, rightCount)
                for index in 0..<outputCount {
                    pcm16[index * 2] = quantizePCM16(normalizedLeft[index])
                    pcm16[index * 2 + 1] =
                        quantizePCM16(normalizedRight[index])
                }
                browserData = Data(
                    bytes: pcm16,
                    count: outputCount * 2 * MemoryLayout<Int16>.stride
                )
            } else {
                browserData = nil
            }

            if let browserData, !browserData.isEmpty {
                await remoteAudio.publishPCM16(browserData)
            }
            if let legacyData {
                await remoteAudio.publishLegacyFloat32(legacyData)
            }
        }
    }

    private func waitForRevision(_ revision: UInt64) {
        stateCondition.wait {
            appliedRevision.load(ordering: .acquiring) != revision
                && !stopped.load(ordering: .acquiring)
        }
    }

    private func ensureResampledCapacity(
        sourceFrameCount: Int,
        sourceSampleRate: Double
    ) {
        guard
            sourceFrameCount > 0,
            sourceSampleRate.isFinite,
            sourceSampleRate > 0
        else {
            return
        }
        let estimate =
            ceil(Double(sourceFrameCount) * 48_000 / sourceSampleRate) + 2
        guard estimate.isFinite, estimate <= Double(Int.max / 2) else {
            return
        }
        let required = max(Int(estimate), Self.initialResampledFrameCapacity)
        guard required > resampledFrameCapacity else { return }

        let newCapacity = required
        let newLeft = UnsafeMutablePointer<Float>.allocate(
            capacity: newCapacity
        )
        let newRight = UnsafeMutablePointer<Float>.allocate(
            capacity: newCapacity
        )
        let newPCM16 = UnsafeMutablePointer<Int16>.allocate(
            capacity: newCapacity * 2
        )
        normalizedLeft.deallocate()
        normalizedRight.deallocate()
        pcm16.deallocate()
        normalizedLeft = newLeft
        normalizedRight = newRight
        pcm16 = newPCM16
        resampledFrameCapacity = newCapacity
    }
}

nonisolated private struct PointerLinearSampleRateNormalizer {
    private var configuredSourceRate: Double?
    private var configuredTargetRate: Double?
    private var sourceSampleOffset: UInt64 = 0
    private var nextOutputPosition: Double = 0
    private var previousSample: Float?

    mutating func process(
        _ samples: UnsafePointer<Float>,
        count: Int,
        sourceSampleRate: Double,
        targetSampleRate: Double,
        output: UnsafeMutablePointer<Float>,
        outputCapacity: Int
    ) -> Int {
        guard
            count > 0,
            sourceSampleRate.isFinite,
            sourceSampleRate > 0,
            targetSampleRate.isFinite,
            targetSampleRate > 0,
            outputCapacity > 0
        else {
            return 0
        }
        if configuredSourceRate != sourceSampleRate
            || configuredTargetRate != targetSampleRate
        {
            reset()
            configuredSourceRate = sourceSampleRate
            configuredTargetRate = targetSampleRate
        }

        let blockStart = sourceSampleOffset
        let blockEnd = blockStart + UInt64(count - 1)
        let sourceStep = sourceSampleRate / targetSampleRate
        let epsilon = 1e-10
        var written = 0

        while nextOutputPosition <= Double(blockEnd) + epsilon,
            written < outputCapacity
        {
            let lowerPosition = floor(nextOutputPosition)
            let lowerIndex = UInt64(max(lowerPosition, 0))
            let fraction = nextOutputPosition - lowerPosition
            let needsUpperSample = fraction > epsilon
            if needsUpperSample, lowerIndex >= blockEnd {
                break
            }

            let lower: Float
            if lowerIndex < blockStart {
                guard lowerIndex + 1 == blockStart, let previousSample else {
                    break
                }
                lower = previousSample
            } else {
                lower = samples[Int(lowerIndex - blockStart)]
            }

            if needsUpperSample {
                let upperIndex = lowerIndex + 1
                let upper = samples[Int(upperIndex - blockStart)]
                output[written] =
                    lower + Float(fraction) * (upper - lower)
            } else {
                output[written] = lower
            }
            written += 1
            nextOutputPosition += sourceStep
        }

        sourceSampleOffset += UInt64(count)
        previousSample = samples[count - 1]
        return written
    }

    mutating func reset() {
        configuredSourceRate = nil
        configuredTargetRate = nil
        sourceSampleOffset = 0
        nextOutputPosition = 0
        previousSample = nil
    }
}

nonisolated private func quantizePCM16(_ sample: Float) -> Int16 {
    guard sample.isFinite else { return 0 }
    if sample <= -1 { return .min }
    if sample >= 1 { return .max }
    return Int16((sample * 32_767).rounded())
}

nonisolated private func resizeReusableBlock(
    _ block: inout [Float],
    to count: Int
) {
    if block.count > count {
        block.removeLast(block.count - count)
    } else if block.count < count {
        block.append(
            contentsOf: repeatElement(0, count: count - block.count)
        )
    }
}

/// A callback-safe admission fence. Capturing the generation before
/// registration closes the ABA hole where a callback pauses while a consumer
/// detaches and reattaches a lane.
nonisolated final class PipelineProducerGate: @unchecked Sendable {
    private static let acceptingBit: UInt64 = 1
    /// The low bit is acceptance and the remaining bits are the generation.
    /// Keeping both in one atomic prevents a callback from observing a mixed
    /// state while a control transition closes and advances the epoch.
    private let state = Atomic<UInt64>(0)
    private let activeProducers = Atomic<UInt64>(0)

    var isAccepting: Bool {
        state.load(ordering: .acquiring) & Self.acceptingBit != 0
    }

    func beginProducing() -> Bool {
        guard let epoch = captureEpochIfAccepting() else { return false }
        return registerProducer(epoch: epoch)
    }

    func captureEpochIfAccepting() -> UInt64? {
        let snapshot = state.load(ordering: .acquiring)
        guard snapshot & Self.acceptingBit != 0 else { return nil }
        return snapshot
    }

    func registerProducer(epoch: UInt64) -> Bool {
        activeProducers.wrappingAdd(
            1,
            ordering: .acquiringAndReleasing
        )
        guard
            state.load(ordering: .acquiring) == epoch,
            epoch & Self.acceptingBit != 0
        else {
            activeProducers.wrappingSubtract(1, ordering: .releasing)
            return false
        }
        return true
    }

    func endProducing() {
        activeProducers.wrappingSubtract(1, ordering: .releasing)
    }

    func setAccepting(_ enabled: Bool) {
        while true {
            let old = state.load(ordering: .acquiring)
            let desired =
                enabled
                ? old | Self.acceptingBit
                : old & ~Self.acceptingBit
            let result = state.compareExchange(
                expected: old,
                desired: desired,
                ordering: .acquiringAndReleasing
            )
            if result.exchanged { return }
        }
    }

    func closeAndFence() {
        while true {
            let old = state.load(ordering: .acquiring)
            let desired =
                ((old & ~Self.acceptingBit) &+ 2)
                & ~Self.acceptingBit
            let result = state.compareExchange(
                expected: old,
                desired: desired,
                ordering: .acquiringAndReleasing
            )
            if result.exchanged { break }
        }
        // A registered callback owns only bounded memcpy/atomic work. Polling
        // here is deliberately limited to that RT section; worker backlogs use
        // PipelineStateCondition instead of spinning the main actor.
        while activeProducers.load(ordering: .acquiring) != 0 {
            sched_yield()
        }
    }
}

/// Parks non-real-time control callers until a worker changes observable
/// state. The capture callback never touches this lock or condition.
nonisolated private final class PipelineStateCondition: @unchecked Sendable {
    private let condition = NSCondition()

    func wait(while predicate: () -> Bool) {
        condition.lock()
        while predicate() {
            condition.wait()
        }
        condition.unlock()
    }

    func notifyAll() {
        condition.lock()
        condition.broadcast()
        condition.unlock()
    }
}

// MARK: - Bounded SPSC queue

nonisolated struct PipelineRingWriteResult: Equatable, Sendable {
    let acceptedFrames: UInt64
    let droppedFrames: UInt64

    var wroteAny: Bool {
        acceptedFrames > 0
    }
}

/// A single-producer/single-consumer planar stereo queue. When full it drops
/// the newest frames rather than allowing the producer to move the consumer's
/// cursor, preserving ownership and preventing partially overwritten reads.
nonisolated final class PipelineStereoRing: @unchecked Sendable {
    private let left: UnsafeMutablePointer<Float>
    private let right: UnsafeMutablePointer<Float>
    private let capacity: UInt64
    private let writeSequence = Atomic<UInt64>(0)
    private let readSequence = Atomic<UInt64>(0)
    private let dropCount = Atomic<UInt64>(0)

    init(capacity: Int) {
        self.capacity = UInt64(max(capacity, 2))
        left = .allocate(capacity: Int(self.capacity))
        right = .allocate(capacity: Int(self.capacity))
        left.initialize(repeating: 0, count: Int(self.capacity))
        right.initialize(repeating: 0, count: Int(self.capacity))
    }

    deinit {
        left.deallocate()
        right.deallocate()
    }

    @discardableResult
    func write(
        left sourceLeft: UnsafePointer<Float>,
        right sourceRight: UnsafePointer<Float>,
        count: Int
    ) -> Bool {
        writeResult(
            left: sourceLeft,
            right: sourceRight,
            count: count
        ).wroteAny
    }

    @discardableResult
    func writeResult(
        left sourceLeft: UnsafePointer<Float>,
        right sourceRight: UnsafePointer<Float>,
        count: Int
    ) -> PipelineRingWriteResult {
        guard count > 0 else {
            return PipelineRingWriteResult(
                acceptedFrames: 0,
                droppedFrames: 0
            )
        }
        let write = writeSequence.load(ordering: .relaxed)
        let read = readSequence.load(ordering: .acquiring)
        let used = min(write &- read, capacity)
        let available = capacity &- used
        let accepted = min(UInt64(count), available)
        guard accepted > 0 else {
            dropCount.wrappingAdd(UInt64(count), ordering: .relaxed)
            return PipelineRingWriteResult(
                acceptedFrames: 0,
                droppedFrames: UInt64(count)
            )
        }

        copyIntoRing(
            destination: left,
            source: sourceLeft,
            sequence: write,
            count: Int(accepted)
        )
        copyIntoRing(
            destination: right,
            source: sourceRight,
            sequence: write,
            count: Int(accepted)
        )
        writeSequence.store(write &+ accepted, ordering: .releasing)

        if accepted < UInt64(count) {
            dropCount.wrappingAdd(
                UInt64(count) &- accepted,
                ordering: .relaxed
            )
        }
        return PipelineRingWriteResult(
            acceptedFrames: accepted,
            droppedFrames: UInt64(count) &- accepted
        )
    }

    func read(
        left destinationLeft: UnsafeMutablePointer<Float>,
        right destinationRight: UnsafeMutablePointer<Float>,
        maximumCount: Int
    ) -> Int {
        guard maximumCount > 0 else { return 0 }
        let read = readSequence.load(ordering: .relaxed)
        let write = writeSequence.load(ordering: .acquiring)
        let available = min(write &- read, capacity)
        let count = min(UInt64(maximumCount), available)
        guard count > 0 else { return 0 }

        copyFromRing(
            source: left,
            destination: destinationLeft,
            sequence: read,
            count: Int(count)
        )
        copyFromRing(
            source: right,
            destination: destinationRight,
            sequence: read,
            count: Int(count)
        )
        readSequence.store(read &+ count, ordering: .releasing)
        return Int(count)
    }

    @discardableResult
    func discardPending() -> UInt64 {
        let read = readSequence.load(ordering: .acquiring)
        let write = writeSequence.load(ordering: .acquiring)
        readSequence.store(write, ordering: .releasing)
        return min(write &- read, capacity)
    }

    var droppedFrames: UInt64 {
        dropCount.load(ordering: .relaxed)
    }

    var fillLevel: Int {
        let read = readSequence.load(ordering: .acquiring)
        let write = writeSequence.load(ordering: .acquiring)
        return Int(min(write &- read, capacity))
    }

    private func copyIntoRing(
        destination: UnsafeMutablePointer<Float>,
        source: UnsafePointer<Float>,
        sequence: UInt64,
        count: Int
    ) {
        let start = Int(sequence % capacity)
        let first = min(count, Int(capacity) - start)
        memcpy(
            destination + start,
            source,
            first * MemoryLayout<Float>.stride
        )
        if first < count {
            memcpy(
                destination,
                source + first,
                (count - first) * MemoryLayout<Float>.stride
            )
        }
    }

    private func copyFromRing(
        source: UnsafePointer<Float>,
        destination: UnsafeMutablePointer<Float>,
        sequence: UInt64,
        count: Int
    ) {
        let start = Int(sequence % capacity)
        let first = min(count, Int(capacity) - start)
        memcpy(
            destination,
            source + start,
            first * MemoryLayout<Float>.stride
        )
        if first < count {
            memcpy(
                destination + first,
                source,
                (count - first) * MemoryLayout<Float>.stride
            )
        }
    }
}

// MARK: - Coalesced native publishing

typealias NativeSpectrogramMailbox =
    CoalescedSpectrogramFrameMailbox
