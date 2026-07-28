import Darwin
import Foundation
import XCTest

@testable import PhonoFlow

/// Runs only on the protected, trusted self-hosted hardware runner. The
/// runtime guard is intentional: normal CI and local unit-test runs must never
/// prompt for microphone access or require an attached interface.
@MainActor
final class FocusriteHardwareSoakTests: XCTestCase {
    private static let pipelineQueueCapacity = 65_536
    private static let maximumLegacyChunkBytes =
        2_048 * 2 * MemoryLayout<Float>.stride
    private static let memorySampleIntervalSeconds = 10

    func testFocusriteCaptureSoak() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["PHONOFLOW_FOCUSRITE_REQUIRED"] == "1" else {
            throw XCTSkip(
                "Protected Focusrite soak is disabled. Set "
                    + "PHONOFLOW_FOCUSRITE_REQUIRED=1 only on the hardware runner."
            )
        }

        let requestedSeconds = max(
            1,
            environment["PHONOFLOW_FOCUSRITE_SOAK_SECONDS"].flatMap(Int.init)
                ?? 1_800
        )
        let resultPath = try XCTUnwrap(
            environment["PHONOFLOW_HARDWARE_RESULT_PATH"],
            "The protected workflow must provide PHONOFLOW_HARDWARE_RESULT_PATH."
        )

        let hal = ProductionCoreAudioHAL()
        let devices = try hal.devices()
        let input = try XCTUnwrap(
            devices.first(where: Self.isFocusriteInput),
            "No connected USB Focusrite/Scarlett input was found through Core Audio."
        )
        XCTAssertGreaterThanOrEqual(
            input.inputChannelCount,
            2,
            "The hardware contract requires at least one stereo input pair."
        )
        let output = try XCTUnwrap(
            devices.first(where: {
                $0.outputChannelCount > 0
                    && $0.isAlive
                    && ($0.id == input.id
                        || Self.hasFocusriteName($0.name))
            }),
            "A Focusrite output is required to continuously drain the monitor ring."
        )

        let monitor = AudioMonitor()
        let audioFanout = RemoteAudioFanout()
        monitor.attachLegacyStream(
            audioFanout: audioFanout,
            baseURL: "http://127.0.0.1:7865"
        )
        let streamSubscription = try await audioFanout.subscribe(
            kind: .legacyFloat32,
            principal: nil,
            remoteAddress: "focusrite-hardware-soak",
            origin: .dedicatedLegacyListener
        )
        let maximumLegacyChunkBytes = Self.maximumLegacyChunkBytes
        let streamDrainTask = Task.detached(priority: .utility) {
            var iterator = streamSubscription.stream.makeAsyncIterator()
            var metrics = StreamDrainMetrics()
            while let chunk = await iterator.next() {
                metrics.record(
                    chunk,
                    maximumChunkBytes: maximumLegacyChunkBytes
                )
            }
            return metrics
        }
        addTeardownBlock { @MainActor in
            monitor.stopStreaming()
            monitor.detachLegacyStream()
            streamDrainTask.cancel()
            await streamSubscription.cancel()
            _ = await streamDrainTask.value
            await audioFanout.closeAll()
            monitor.disablePassthrough()
            monitor.spectrogramEnabled = false
            monitor.stopMonitoring()
        }

        monitor.isMeteringEnabled = true
        monitor.spectrogramEnabled = true
        monitor.startMonitoring(
            deviceID: input.id,
            outputDeviceID: output.id,
            inputChannelMap: [0, 1]
        )
        monitor.enablePassthrough()
        monitor.startStreaming()

        guard case .running(let format) = monitor.engineStatus else {
            return XCTFail(
                "Core Audio did not reach running state: \(monitor.engineStatus)"
            )
        }
        XCTAssertEqual(format.channelCount, 2)
        XCTAssertEqual(format.inputChannelMap, [0, 1])
        XCTAssertTrue(monitor.isPassthroughEnabled)

        let start = DispatchTime.now().uptimeNanoseconds
        var maximumQueueDepth = 0
        var memorySamples: [UInt64] = [Self.residentMemoryBytes()]
        var nextMemorySampleSecond = Self.memorySampleIntervalSeconds
        var streamSubscriberEvicted = false

        while Self.elapsedSeconds(since: start) < Double(requestedSeconds) {
            let remaining =
                Double(requestedSeconds)
                - Self.elapsedSeconds(since: start)
            let sleepNanoseconds = UInt64(
                min(max(remaining, 0.01), 1.0) * 1_000_000_000
            )
            try await Task.sleep(
                for: .nanoseconds(Int64(sleepNanoseconds))
            )

            let elapsed = Self.elapsedSeconds(since: start)
            switch monitor.engineStatus {
            case .running:
                break
            default:
                XCTFail(
                    "Audio engine left running state after " + "\(String(format: "%.1f", elapsed)) seconds: "
                        + "\(monitor.engineStatus)"
                )
            }

            let queueDepth = max(
                monitor.analysisQueueDepth,
                monitor.fanoutQueueDepth
            )
            maximumQueueDepth = max(maximumQueueDepth, queueDepth)
            XCTAssertLessThanOrEqual(
                queueDepth,
                Self.pipelineQueueCapacity,
                "A bounded worker queue exceeded its fixed capacity."
            )

            let listenerCount = await audioFanout.listenerCount(
                kind: .legacyFloat32
            )
            if listenerCount != 1, !streamSubscriberEvicted {
                XCTFail(
                    "The bounded fanout evicted its actively drained stream subscriber."
                )
                streamSubscriberEvicted = true
            }

            if Int(elapsed) >= nextMemorySampleSecond {
                memorySamples.append(Self.residentMemoryBytes())
                nextMemorySampleSecond += Self.memorySampleIntervalSeconds
            }
        }

        let durationSeconds = Self.elapsedSeconds(since: start)
        memorySamples.append(Self.residentMemoryBytes())
        let xrunCount =
            monitor.callbackOverflowCount
            &+ monitor.playbackUnderrunCount
        let ringOverflowCount =
            monitor.analysisDroppedFrameCount
            &+ monitor.fanoutDroppedFrameCount
        let sustainedMemoryGrowth = Self.hasSustainedMemoryGrowth(
            memorySamples
        )
        let finalStreamListenerCount = await audioFanout.listenerCount(
            kind: .legacyFloat32
        )
        streamSubscriberEvicted =
            streamSubscriberEvicted || finalStreamListenerCount != 1
        monitor.stopStreaming()
        monitor.detachLegacyStream()
        await streamSubscription.cancel()
        streamDrainTask.cancel()
        let streamMetrics = await streamDrainTask.value
        let remainingStreamListenerCount = await audioFanout.listenerCount(
            kind: .legacyFloat32
        )
        await audioFanout.closeAll()

        let metrics = HardwareMetrics(
            durationSeconds: durationSeconds,
            deviceName: input.name,
            deviceUID: input.uid,
            inputChannelCount: input.inputChannelCount,
            sampleRate: format.sampleRate,
            bufferFrames: Int(format.bufferFrames),
            callbackOverflowCount: monitor.callbackOverflowCount,
            playbackUnderrunCount: monitor.playbackUnderrunCount,
            xrunCount: xrunCount,
            ringOverflowCount: ringOverflowCount,
            sustainedMemoryGrowth: sustainedMemoryGrowth,
            queueCapacity: Self.pipelineQueueCapacity,
            maximumQueueDepth: maximumQueueDepth,
            streamChunkCount: streamMetrics.chunkCount,
            streamByteCount: streamMetrics.byteCount,
            maximumStreamChunkBytes: streamMetrics.maximumChunkBytes,
            invalidStreamChunkCount: streamMetrics.invalidChunkCount,
            streamSubscriberEvicted: streamSubscriberEvicted
        )
        try Self.write(metrics: metrics, to: URL(fileURLWithPath: resultPath))

        XCTAssertGreaterThan(
            monitor.callbackCount,
            0,
            "No Core Audio callbacks completed during the soak."
        )
        XCTAssertEqual(xrunCount, 0, "The capture callback reported an XRUN.")
        XCTAssertEqual(
            ringOverflowCount,
            0,
            "An analysis or fanout ring dropped frames."
        )
        XCTAssertFalse(
            streamSubscriberEvicted,
            "The fanout subscriber was evicted while continuously draining."
        )
        XCTAssertEqual(
            remainingStreamListenerCount,
            0,
            "Stream teardown left a fanout subscriber registered."
        )
        XCTAssertGreaterThan(
            streamMetrics.chunkCount,
            0,
            "No legacy Float32 chunks reached the in-process stream subscriber."
        )
        XCTAssertGreaterThan(
            streamMetrics.byteCount,
            0,
            "The in-process stream subscriber received no audio bytes."
        )
        XCTAssertEqual(
            streamMetrics.invalidChunkCount,
            0,
            "The fanout emitted an empty, oversized, or misaligned Float32 chunk."
        )
        XCTAssertLessThanOrEqual(
            streamMetrics.maximumChunkBytes,
            Self.maximumLegacyChunkBytes,
            "The fanout emitted a chunk larger than its worker drain bound."
        )
        XCTAssertFalse(
            sustainedMemoryGrowth,
            "Resident memory grew continuously after the warm-up interval."
        )
        XCTAssertGreaterThanOrEqual(
            durationSeconds,
            Double(requestedSeconds) - 0.25
        )
    }

    private static func isFocusriteInput(_ device: CoreAudioHALDevice) -> Bool {
        device.isAlive
            && device.transport == .usb
            && device.inputChannelCount > 0
            && hasFocusriteName(device.name)
    }

    private static func hasFocusriteName(_ name: String) -> Bool {
        let normalized = name.lowercased()
        return normalized.contains("focusrite")
            || normalized.contains("scarlett")
    }

    private static func elapsedSeconds(since start: UInt64) -> Double {
        let now = DispatchTime.now().uptimeNanoseconds
        return Double(now &- start) / 1_000_000_000
    }

    private static func residentMemoryBytes() -> UInt64 {
        var information = proc_taskinfo()
        let expectedSize = Int32(MemoryLayout<proc_taskinfo>.size)
        let actualSize = proc_pidinfo(
            getpid(),
            PROC_PIDTASKINFO,
            0,
            &information,
            expectedSize
        )
        guard actualSize == expectedSize else { return 0 }
        return information.pti_resident_size
    }

    /// Ignore allocator warm-up, then require both substantial net growth and
    /// growth in most sample intervals before classifying it as sustained.
    private static func hasSustainedMemoryGrowth(
        _ samples: [UInt64]
    ) -> Bool {
        guard samples.count >= 6 else { return false }
        let stable = Array(samples.dropFirst(max(1, samples.count / 5)))
        guard let first = stable.first, let last = stable.last else {
            return false
        }
        let growth = last > first ? last - first : 0
        let substantialGrowth = UInt64(32 * 1_024 * 1_024)
        guard growth > substantialGrowth else { return false }

        let meaningfulStep = UInt64(256 * 1_024)
        let increasingIntervals = zip(stable, stable.dropFirst()).filter {
            older, newer in
            newer > older && newer - older > meaningfulStep
        }.count
        let intervalCount = stable.count - 1
        return increasingIntervals * 4 >= intervalCount * 3
    }

    private static func write(
        metrics: HardwareMetrics,
        to destination: URL
    ) throws {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(metrics).write(to: destination, options: .atomic)
    }
}

private struct StreamDrainMetrics: Sendable {
    private(set) var chunkCount: UInt64 = 0
    private(set) var byteCount: UInt64 = 0
    private(set) var maximumChunkBytes = 0
    private(set) var invalidChunkCount: UInt64 = 0

    mutating func record(_ chunk: Data, maximumChunkBytes: Int) {
        chunkCount &+= 1
        byteCount &+= UInt64(chunk.count)
        self.maximumChunkBytes = max(self.maximumChunkBytes, chunk.count)
        let frameBytes = 2 * MemoryLayout<Float>.stride
        if chunk.isEmpty
            || chunk.count > maximumChunkBytes
            || !chunk.count.isMultiple(of: frameBytes)
        {
            invalidChunkCount &+= 1
        }
    }
}

private struct HardwareMetrics: Codable {
    let durationSeconds: Double
    let deviceName: String
    let deviceUID: String
    let inputChannelCount: Int
    let sampleRate: Double
    let bufferFrames: Int
    let callbackOverflowCount: UInt64
    let playbackUnderrunCount: UInt64
    let xrunCount: UInt64
    let ringOverflowCount: UInt64
    let sustainedMemoryGrowth: Bool
    let queueCapacity: Int
    let maximumQueueDepth: Int
    let streamChunkCount: UInt64
    let streamByteCount: UInt64
    let maximumStreamChunkBytes: Int
    let invalidStreamChunkCount: UInt64
    let streamSubscriberEvicted: Bool
}
