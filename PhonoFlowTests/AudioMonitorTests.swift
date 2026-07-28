import CoreAudio
import Darwin
import Foundation
import XCTest

@testable import PhonoFlow

@MainActor
final class AudioMonitorTests: XCTestCase {
    func testFakeCaptureStartRestartAndStopAreSafeAndIdempotent() async {
        let monitor = AudioMonitor()
        defer { monitor.stopMonitoring() }

        XCTAssertEqual(monitor.engineStatus, .idle)
        XCTAssertFalse(monitor.isMonitoring)
        XCTAssertNil(monitor.lastError)

        startFake(
            monitor,
            deviceID: 501,
            outputDeviceID: 502,
            channelMap: [2, 3]
        )

        assertRunning(
            monitor,
            deviceID: 501,
            expectedChannelMap: [2, 3]
        )
        let firstCaptureProducedSamples = await eventually {
            monitor.callbackCount >= 3
        }
        XCTAssertTrue(firstCaptureProducedSamples)

        // A repeated desired-state start first tears down the old callback
        // source and then reaches the same authoritative running state.
        startFake(
            monitor,
            deviceID: 501,
            outputDeviceID: 502,
            channelMap: [2, 3]
        )
        assertRunning(
            monitor,
            deviceID: 501,
            expectedChannelMap: [2, 3]
        )
        let restartedCaptureProducedSamples = await eventually {
            monitor.callbackCount >= 3
        }
        XCTAssertTrue(restartedCaptureProducedSamples)

        monitor.stopMonitoring()
        XCTAssertEqual(monitor.engineStatus, .idle)
        XCTAssertFalse(monitor.isMonitoring)
        XCTAssertFalse(monitor.isPassthroughEnabled)
        XCTAssertFalse(monitor.isStreamingEnabled)
        XCTAssertFalse(monitor.isRecording)
        XCTAssertEqual(monitor.peakLevel, 0)

        monitor.stopMonitoring()
        XCTAssertEqual(monitor.engineStatus, .idle)
        XCTAssertFalse(monitor.isMonitoring)
    }

    func testChannelMapNormalizationAndFakeFourInputRouteSelection() {
        XCTAssertEqual(AudioMonitor.normalizedChannelMap([]), [0, 0])
        XCTAssertEqual(AudioMonitor.normalizedChannelMap([3]), [3, 3])
        XCTAssertEqual(AudioMonitor.normalizedChannelMap([-2]), [0, 0])
        XCTAssertEqual(AudioMonitor.normalizedChannelMap([-1, 2]), [0, 2])
        XCTAssertEqual(AudioMonitor.normalizedChannelMap([2, 3, 99]), [2, 3])

        let monitor = AudioMonitor()
        defer { monitor.stopMonitoring() }

        startFake(
            monitor,
            deviceID: 601,
            outputDeviceID: nil,
            channelMap: [2, 3]
        )

        XCTAssertEqual(monitor.inputChannelMap, [2, 3])
        guard case .running(let format) = monitor.engineStatus else {
            return XCTFail("Expected the fake four-input route to be running")
        }
        XCTAssertEqual(format.inputChannelMap, [2, 3])

        startFake(
            monitor,
            deviceID: 601,
            outputDeviceID: nil,
            channelMap: [3]
        )
        XCTAssertEqual(monitor.inputChannelMap, [3, 3])
        guard case .running(let monoFormat) = monitor.engineStatus else {
            return XCTFail("Expected the duplicated mono route to be running")
        }
        XCTAssertEqual(monoFormat.inputChannelMap, [3, 3])
    }

    func testFakeMetersWaveformsSpectrogramAndVisibilityDemand() async {
        let monitor = AudioMonitor()
        defer { monitor.stopMonitoring() }

        monitor.isMeteringEnabled = true
        monitor.enableSpectrogram()
        startFake(
            monitor,
            deviceID: 701,
            outputDeviceID: nil,
            channelMap: [0, 1]
        )

        let metersUpdated = await eventually {
            monitor.callbackCount > 0
                && monitor.maximumCallbackDurationMicroseconds > 0
                && monitor.peakLevel > 0
                && monitor.leftLevel > 0
                && monitor.rightLevel > 0
                && monitor.leftWaveform.contains(where: { $0 != 0 })
                && monitor.rightWaveform.contains(where: { $0 != 0 })
        }
        XCTAssertTrue(metersUpdated)

        let spectrogramPublished = await eventually(timeout: 4) {
            monitor.spectrogramImage != nil
                && monitor.spectrogramImageAgeMilliseconds >= 0
        }
        XCTAssertTrue(spectrogramPublished)
        XCTAssertEqual(monitor.callbackOverflowCount, 0)
        XCTAssertEqual(monitor.analysisDroppedFrameCount, 0)
        XCTAssertEqual(monitor.fanoutDroppedFrameCount, 0)

        let callbacksBeforePause = monitor.callbackCount
        monitor.pauseVisualizations()
        XCTAssertTrue(monitor.visualizationsPaused)
        XCTAssertFalse(monitor.spectrogramEnabled)
        XCTAssertNil(monitor.spectrogramImage)

        let captureContinuedWhileHidden = await eventually {
            monitor.callbackCount > callbacksBeforePause
        }
        XCTAssertTrue(captureContinuedWhileHidden)

        monitor.resumeVisualizations()
        XCTAssertFalse(monitor.visualizationsPaused)
        XCTAssertTrue(monitor.spectrogramEnabled)
        let spectrogramResumed = await eventually(timeout: 4) {
            monitor.spectrogramImage != nil
        }
        XCTAssertTrue(spectrogramResumed)

        monitor.disableSpectrogram()
        XCTAssertFalse(monitor.spectrogramEnabled)
        XCTAssertNil(monitor.spectrogramImage)
    }

    func testStreamingPassthroughAndRecordingStateUseFakeCapture() async throws {
        let monitor = AudioMonitor()
        var filesToRemove: [URL] = []
        defer {
            monitor.stopMonitoring()
            for url in filesToRemove {
                try? FileManager.default.removeItem(at: url)
            }
        }

        startFake(
            monitor,
            deviceID: 801,
            outputDeviceID: 802,
            channelMap: [0, 1]
        )

        monitor.startStreaming(port: 19_876)
        let firstStreamURL = monitor.streamURL
        XCTAssertTrue(monitor.isStreamingEnabled)
        XCTAssertTrue(firstStreamURL.hasSuffix(":19876/stream"))

        monitor.startStreaming(port: 19_877)
        XCTAssertEqual(monitor.streamURL, firstStreamURL)
        monitor.stopStreaming()
        monitor.stopStreaming()
        XCTAssertFalse(monitor.isStreamingEnabled)
        XCTAssertEqual(monitor.streamURL, "")

        withFakeAcceptanceEnvironment {
            monitor.enablePassthrough()
        }
        XCTAssertTrue(monitor.isPassthroughEnabled)

        withFakeAcceptanceEnvironment {
            monitor.updatePassthroughOutput(deviceID: 803)
        }
        XCTAssertTrue(monitor.isMonitoring)
        XCTAssertTrue(monitor.isPassthroughEnabled)

        withFakeAcceptanceEnvironment {
            monitor.disablePassthrough()
        }
        XCTAssertFalse(monitor.isPassthroughEnabled)

        monitor.startRecording()
        let firstRecording = try XCTUnwrap(monitor.recordingURL)
        filesToRemove.append(firstRecording)
        XCTAssertTrue(monitor.isRecording)

        monitor.startRecording()
        XCTAssertEqual(monitor.recordingURL, firstRecording)

        let recordingReceivedAudio = await eventually {
            monitor.recordingDuration > 0
        }
        XCTAssertTrue(recordingReceivedAudio)

        monitor.stopRecording()
        monitor.stopRecording()
        XCTAssertFalse(monitor.isRecording)
        XCTAssertEqual(monitor.recordingURL, firstRecording)
        let firstWAV = try Data(contentsOf: firstRecording)
        XCTAssertGreaterThan(firstWAV.count, 44)
        XCTAssertEqual(String(data: firstWAV.prefix(4), encoding: .ascii), "RIFF")

        monitor.startRecording()
        let secondRecording = try XCTUnwrap(monitor.recordingURL)
        filesToRemove.append(secondRecording)
        let secondRecordingReceivedAudio = await eventually {
            monitor.recordingDuration > 0
        }
        XCTAssertTrue(secondRecordingReceivedAudio)

        // Capture shutdown is the unplug/termination boundary: it must drain
        // and finalize an active recording before returning.
        monitor.stopMonitoring()
        XCTAssertFalse(monitor.isRecording)
        XCTAssertEqual(monitor.recordingURL, secondRecording)
        let secondWAV = try Data(contentsOf: secondRecording)
        XCTAssertGreaterThan(secondWAV.count, 44)
        XCTAssertEqual(String(data: secondWAV.prefix(4), encoding: .ascii), "RIFF")
    }

    func testActionableErrorIsPreservedThenClearedBySuccessfulRestart() {
        let monitor = AudioMonitor()
        defer { monitor.stopMonitoring() }

        monitor.enablePassthrough()
        let initialFailure = tryFailure(monitor)
        XCTAssertEqual(initialFailure.operation, "Enable monitor")
        XCTAssertEqual(initialFailure.status, kAudio_ParamError)
        XCTAssertNil(initialFailure.deviceID)
        XCTAssertFalse(monitor.isMonitoring)

        monitor.stopMonitoring()
        XCTAssertEqual(monitor.lastError, initialFailure)
        XCTAssertEqual(monitor.engineStatus, .failed(initialFailure))

        startFake(
            monitor,
            deviceID: 901,
            outputDeviceID: nil,
            channelMap: [0, 1]
        )
        XCTAssertTrue(monitor.isMonitoring)
        XCTAssertNil(monitor.lastError)
        guard case .running = monitor.engineStatus else {
            return XCTFail("Expected a successful restart to clear the failure")
        }

        monitor.enablePassthrough()
        let missingOutputFailure = tryFailure(monitor)
        XCTAssertEqual(missingOutputFailure.operation, "Enable monitor")
        XCTAssertNil(missingOutputFailure.deviceID)
        XCTAssertTrue(monitor.isMonitoring)

        startFake(
            monitor,
            deviceID: 901,
            outputDeviceID: 902,
            channelMap: [0, 1]
        )
        XCTAssertNil(monitor.lastError)
        guard case .running = monitor.engineStatus else {
            return XCTFail("Expected the recovered engine to be running")
        }

        withFakeAcceptanceEnvironment {
            monitor.enablePassthrough()
        }
        XCTAssertTrue(monitor.isPassthroughEnabled)
        monitor.stopMonitoring()
        XCTAssertEqual(monitor.engineStatus, .idle)
    }

    func testRecordingInitializationFailureIsPublishedAndOtherStartErrorsClearIt() {
        let storage = AudioMonitorFailingRecorderFileSystem()
        let monitor = AudioMonitor(
            acceptanceAudioBackendOverride: true,
            recorder: AudioRecorder(fileSystem: storage)
        )

        monitor.startRecording()
        XCTAssertFalse(monitor.isRecording)
        XCTAssertNil(monitor.recordingURL)
        XCTAssertEqual(
            monitor.lastRecordingFailure?.phase,
            .initialHeaderWrite
        )
        XCTAssertEqual(
            monitor.lastRecordingFailure?.disposition,
            .removed
        )

        storage.failCreate = true
        monitor.startRecording()
        XCTAssertFalse(monitor.isRecording)
        XCTAssertNil(monitor.recordingURL)
        XCTAssertNil(
            monitor.lastRecordingFailure,
            "A non-terminal creation error must not leave a stale typed failure"
        )
    }

    private func startFake(
        _ monitor: AudioMonitor,
        deviceID: AudioDeviceID,
        outputDeviceID: AudioDeviceID?,
        channelMap: [Int32]
    ) {
        withFakeAcceptanceEnvironment {
            monitor.startMonitoring(
                deviceID: deviceID,
                outputDeviceID: outputDeviceID,
                inputChannelMap: channelMap
            )
        }
    }

    private func assertRunning(
        _ monitor: AudioMonitor,
        deviceID: AudioDeviceID,
        expectedChannelMap: [Int32],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(monitor.isMonitoring, file: file, line: line)
        XCTAssertNil(monitor.lastError, file: file, line: line)
        XCTAssertEqual(monitor.captureSampleRate, 48_000, file: file, line: line)
        XCTAssertEqual(monitor.negotiatedBufferFrames, 256, file: file, line: line)
        XCTAssertEqual(monitor.inputChannelMap, expectedChannelMap, file: file, line: line)

        guard case .running(let format) = monitor.engineStatus else {
            return XCTFail("Expected running engine state", file: file, line: line)
        }
        XCTAssertEqual(format.sampleRate, 48_000, file: file, line: line)
        XCTAssertEqual(format.channelCount, 2, file: file, line: line)
        XCTAssertEqual(format.bufferFrames, 256, file: file, line: line)
        XCTAssertEqual(format.inputChannelMap, expectedChannelMap, file: file, line: line)
        XCTAssertTrue(format.summary.contains("48.0 kHz"), file: file, line: line)
        _ = deviceID
    }

    private func tryFailure(
        _ monitor: AudioMonitor,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> AudioEngineFailure {
        guard case .failed(let failure) = monitor.engineStatus else {
            XCTFail("Expected failed engine state", file: file, line: line)
            return AudioEngineFailure(
                operation: "missing",
                status: noErr,
                deviceID: nil,
                detail: "Missing expected failure"
            )
        }
        XCTAssertEqual(monitor.lastError, failure, file: file, line: line)
        XCTAssertFalse(failure.localizedDescription.isEmpty, file: file, line: line)
        return failure
    }

    private func eventually(
        timeout: TimeInterval = 2,
        pollInterval: TimeInterval = 0.02,
        _ predicate: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() {
                return true
            }
            try? await Task.sleep(
                for: .seconds(pollInterval)
            )
        }
        return predicate()
    }

    private func withFakeAcceptanceEnvironment<T>(
        _ body: () throws -> T
    ) rethrows -> T {
        let priorAcceptance = ProcessInfo.processInfo.environment[
            "PHONOFLOW_ACCEPTANCE"
        ]
        let priorBackend = ProcessInfo.processInfo.environment[
            "PHONOFLOW_AUDIO_BACKEND"
        ]
        setenv("PHONOFLOW_ACCEPTANCE", "1", 1)
        setenv("PHONOFLOW_AUDIO_BACKEND", "fake", 1)
        defer {
            restoreEnvironment(
                key: "PHONOFLOW_ACCEPTANCE",
                value: priorAcceptance
            )
            restoreEnvironment(
                key: "PHONOFLOW_AUDIO_BACKEND",
                value: priorBackend
            )
        }
        return try body()
    }

    private func restoreEnvironment(key: String, value: String?) {
        if let value {
            setenv(key, value, 1)
        } else {
            unsetenv(key)
        }
    }
}

nonisolated private final class AudioMonitorFailingRecorderFileSystem:
    RecorderFileSystem, @unchecked Sendable
{
    let url = URL(fileURLWithPath: "/tmp/phonoflow-monitor-init-failure.wav")
    let sink = AudioMonitorFailingRecorderSink()
    var failCreate = false

    func createRecordingFile() throws -> RecorderCreatedFile {
        if failCreate {
            throw AudioMonitorRecorderTestError.create
        }
        return RecorderCreatedFile(url: url, sink: sink)
    }

    func removeRecordingFile(at url: URL) throws {
        _ = url
    }

    func quarantineRecordingFile(at url: URL) throws -> URL {
        url.appendingPathExtension("corrupt")
    }
}

nonisolated private final class AudioMonitorFailingRecorderSink:
    RecorderFileSink, @unchecked Sendable
{
    func write(_ data: Data) throws {
        _ = data
        throw AudioMonitorRecorderTestError.write
    }

    func seek(toOffset offset: UInt64) throws {
        _ = offset
    }

    func truncate(atOffset offset: UInt64) throws {
        _ = offset
    }

    func synchronize() throws {}
    func close() throws {}
}

nonisolated private enum AudioMonitorRecorderTestError: Error {
    case create
    case write
}
