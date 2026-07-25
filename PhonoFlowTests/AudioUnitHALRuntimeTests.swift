import AudioToolbox
import CoreAudio
import Foundation
import XCTest

@testable import PhonoFlow

@MainActor
final class AudioUnitHALRuntimeTests: XCTestCase {
    private let injectedStatus = OSStatus(-7_777)

    func testEveryInputSetupAndStartFailureBecomesTypedEngineFailure() {
        let cases: [(FakeAudioUnitHALRuntime.Operation, String)] = [
            (.findComponent, "Find AUHAL input component"),
            (.instantiate, "Create input AudioUnit"),
            (
                .setProperty(
                    kAudioOutputUnitProperty_EnableIO,
                    kAudioUnitScope_Input,
                    1
                ),
                "Enable input I/O"
            ),
            (
                .setProperty(
                    kAudioOutputUnitProperty_EnableIO,
                    kAudioUnitScope_Output,
                    0
                ),
                "Disable input-unit output I/O"
            ),
            (
                .setProperty(
                    kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global,
                    0
                ),
                "Select input device"
            ),
            (
                .getObjectProperty(kAudioDevicePropertyBufferFrameSizeRange),
                "Read device buffer range"
            ),
            (
                .setObjectProperty(kAudioDevicePropertyBufferFrameSize),
                "Set device buffer size"
            ),
            (
                .getObjectProperty(kAudioDevicePropertyBufferFrameSize),
                "Read device buffer size"
            ),
            (
                .getProperty(
                    kAudioUnitProperty_StreamFormat,
                    kAudioUnitScope_Input,
                    1
                ),
                "Read input device format"
            ),
            (
                .setProperty(
                    kAudioUnitProperty_StreamFormat,
                    kAudioUnitScope_Output,
                    1
                ),
                "Set two-channel input client format"
            ),
            (
                .setProperty(
                    kAudioOutputUnitProperty_ChannelMap,
                    kAudioUnitScope_Output,
                    1
                ),
                "Apply input channel map"
            ),
            (
                .getProperty(
                    kAudioUnitProperty_MaximumFramesPerSlice,
                    kAudioUnitScope_Global,
                    0
                ),
                "Read input maximum frames"
            ),
            (
                .setProperty(
                    kAudioOutputUnitProperty_SetInputCallback,
                    kAudioUnitScope_Global,
                    0
                ),
                "Install input callback"
            ),
            (.initialize, "Initialize input AudioUnit"),
            (.start, "Start input"),
        ]

        for (operation, expectedOperation) in cases {
            let runtime = FakeAudioUnitHALRuntime()
            runtime.failNext(operation, status: injectedStatus)
            let monitor = AudioMonitor(audioUnitRuntime: runtime)

            monitor.startMonitoring(
                deviceID: 41,
                outputDeviceID: nil,
                inputChannelMap: [2, 3]
            )

            assertFailure(
                monitor,
                operation: expectedOperation,
                deviceID: 41,
                status: operation == .findComponent
                    ? kAudio_ParamError
                    : injectedStatus
            )
            XCTAssertFalse(monitor.isMonitoring)
            runtime.clearFailure()
            monitor.stopMonitoring()
        }
    }

    func testEveryOutputSetupAndStartFailureBecomesTypedEngineFailure() {
        let cases: [(FakeAudioUnitHALRuntime.Operation, String)] = [
            (.findComponent, "Find AUHAL output component"),
            (.instantiate, "Create output AudioUnit"),
            (
                .setProperty(
                    kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global,
                    0
                ),
                "Select output device"
            ),
            (
                .getObjectProperty(kAudioDevicePropertyBufferFrameSizeRange),
                "Read device buffer range"
            ),
            (
                .setObjectProperty(kAudioDevicePropertyBufferFrameSize),
                "Set device buffer size"
            ),
            (
                .getObjectProperty(kAudioDevicePropertyBufferFrameSize),
                "Read device buffer size"
            ),
            (
                .getProperty(
                    kAudioUnitProperty_StreamFormat,
                    kAudioUnitScope_Input,
                    0
                ),
                "Read output device format"
            ),
            (
                .setProperty(
                    kAudioUnitProperty_StreamFormat,
                    kAudioUnitScope_Input,
                    0
                ),
                "Set output client format"
            ),
            (
                .getProperty(
                    kAudioUnitProperty_MaximumFramesPerSlice,
                    kAudioUnitScope_Global,
                    0
                ),
                "Read output maximum frames"
            ),
            (
                .setProperty(
                    kAudioUnitProperty_SetRenderCallback,
                    kAudioUnitScope_Input,
                    0
                ),
                "Install output callback"
            ),
            (.initialize, "Initialize output AudioUnit"),
            (.start, "Start output"),
        ]

        for (operation, expectedOperation) in cases {
            let runtime = FakeAudioUnitHALRuntime()
            let monitor = AudioMonitor(audioUnitRuntime: runtime)
            monitor.startMonitoring(
                deviceID: 51,
                outputDeviceID: 52,
                inputChannelMap: [0, 1]
            )
            XCTAssertTrue(monitor.isMonitoring)

            runtime.failNext(operation, status: injectedStatus)
            monitor.enablePassthrough()

            assertFailure(
                monitor,
                operation: expectedOperation,
                deviceID: 52,
                status: operation == .findComponent
                    ? kAudio_ParamError
                    : injectedStatus
            )
            XCTAssertFalse(monitor.isPassthroughEnabled)
            runtime.clearFailure()
            monitor.stopMonitoring()
        }
    }

    func testInputStopAndDisposeFailuresAreReported() {
        for (operation, expectedOperation) in [
            (FakeAudioUnitHALRuntime.Operation.stop, "Stop input"),
            (.dispose, "Dispose input AudioUnit"),
        ] {
            let runtime = FakeAudioUnitHALRuntime()
            let monitor = AudioMonitor(audioUnitRuntime: runtime)
            monitor.startMonitoring(
                deviceID: 61,
                outputDeviceID: nil
            )
            XCTAssertTrue(monitor.isMonitoring)

            runtime.failNext(operation, status: injectedStatus)
            monitor.stopMonitoring()

            assertFailure(
                monitor,
                operation: expectedOperation,
                deviceID: 61,
                status: injectedStatus
            )
            runtime.clearFailure()
        }
    }

    func testOutputStopAndDisposeFailuresAreReported() {
        do {
            let runtime = FakeAudioUnitHALRuntime()
            let monitor = runningMonitor(runtime: runtime)
            monitor.enablePassthrough()
            XCTAssertTrue(monitor.isPassthroughEnabled)

            runtime.failNext(.stop, status: injectedStatus)
            monitor.disablePassthrough()

            assertFailure(
                monitor,
                operation: "Stop output",
                deviceID: 72,
                status: injectedStatus
            )
            runtime.clearFailure()
            monitor.stopMonitoring()
        }

        do {
            let runtime = FakeAudioUnitHALRuntime()
            let monitor = runningMonitor(runtime: runtime)
            monitor.enablePassthrough()
            XCTAssertTrue(monitor.isPassthroughEnabled)

            runtime.failNext(.dispose, status: injectedStatus)
            monitor.clearPassthroughOutput()

            assertFailure(
                monitor,
                operation: "Dispose output AudioUnit",
                deviceID: 72,
                status: injectedStatus
            )
            runtime.clearFailure()
            monitor.stopMonitoring()
        }
    }

    func testRenderFailureReturnsStatusAndPublishesTypedFailure() async {
        let runtime = FakeAudioUnitHALRuntime()
        let monitor = AudioMonitor(audioUnitRuntime: runtime)
        monitor.startMonitoring(deviceID: 81, outputDeviceID: nil)
        XCTAssertTrue(monitor.isMonitoring)

        runtime.failNext(.render, status: injectedStatus)
        XCTAssertEqual(
            runtime.invokeInputCallback(frameCount: 128),
            injectedStatus
        )

        let published = await eventually {
            guard case .failed(let failure) = monitor.engineStatus else {
                return false
            }
            return failure.operation == "Render input"
                && failure.status == self.injectedStatus
        }
        XCTAssertTrue(published)
        monitor.stopMonitoring()
    }

    func testInputConfigurationUsesPlanarStereoAndExplicitChannelMap() {
        let runtime = FakeAudioUnitHALRuntime()
        let monitor = AudioMonitor(audioUnitRuntime: runtime)
        monitor.startMonitoring(
            deviceID: 91,
            outputDeviceID: nil,
            inputChannelMap: [2, 3]
        )

        XCTAssertTrue(monitor.isMonitoring)
        XCTAssertEqual(monitor.captureSampleRate, 48_000)
        XCTAssertEqual(monitor.negotiatedBufferFrames, 256)
        XCTAssertEqual(runtime.lastChannelMap, [2, 3])
        let format = runtime.lastInputClientFormat
        XCTAssertEqual(format?.mSampleRate, 48_000)
        XCTAssertEqual(format?.mChannelsPerFrame, 2)
        XCTAssertEqual(
            format?.mFormatFlags,
            kAudioFormatFlagIsFloat
                | kAudioFormatFlagIsPacked
                | kAudioFormatFlagIsNonInterleaved
        )

        monitor.stopMonitoring()
    }

    func testInactivePlaybackNeverAccumulatesOverflow() async {
        let runtime = FakeAudioUnitHALRuntime()
        let monitor = AudioMonitor(audioUnitRuntime: runtime)
        monitor.startMonitoring(deviceID: 101, outputDeviceID: nil)

        for _ in 0..<100 {
            XCTAssertEqual(
                runtime.invokeInputCallback(frameCount: 256),
                noErr
            )
        }

        let diagnosticsPublished = await eventually {
            monitor.callbackCount >= 100
        }
        XCTAssertTrue(diagnosticsPublished)
        XCTAssertEqual(monitor.playbackOverflowCount, 0)
        monitor.stopMonitoring()
    }

    func testGainOnlyCaptureIsLimitedAndAutoGainPublishesHeadlessly() async {
        let runtime = FakeAudioUnitHALRuntime()
        runtime.renderLeft = 0.6
        runtime.renderRight = -0.6
        let monitor = AudioMonitor(audioUnitRuntime: runtime)
        monitor.gain = 4
        monitor.startMonitoring(deviceID: 111, outputDeviceID: nil)

        XCTAssertEqual(
            runtime.invokeInputCallback(frameCount: 256),
            noErr
        )
        let waveformPublished = await eventually {
            monitor.leftWaveform.contains(where: { $0 != 0 })
        }
        XCTAssertTrue(waveformPublished)
        XCTAssertLessThanOrEqual(
            monitor.leftWaveform.map(abs).max() ?? 0,
            1
        )

        monitor.gain = 1
        monitor.updatePassthroughVolume()
        monitor.isMeteringEnabled = true
        runtime.renderLeft = 0.05
        runtime.renderRight = 0
        XCTAssertEqual(runtime.invokeInputCallback(frameCount: 256), noErr)
        monitor.isAutoGainEnabled = true
        let autoGainPublished = await eventually(timeout: 1) {
            monitor.testingCallbackGain > 1
        }
        XCTAssertTrue(autoGainPublished)
        monitor.isAutoGainEnabled = false
        monitor.stopMonitoring()
    }

    func testMonoOutputCallbackDoesNotTrapAndProducesAudio() {
        let runtime = FakeAudioUnitHALRuntime()
        runtime.renderRight = 0.5
        let monitor = runningMonitor(runtime: runtime)
        monitor.enablePassthrough()
        XCTAssertTrue(monitor.isPassthroughEnabled)
        XCTAssertEqual(runtime.invokeInputCallback(frameCount: 256), noErr)

        let result = runtime.invokeMonoOutputCallback(frameCount: 128)
        XCTAssertEqual(result.status, noErr)
        XCTAssertTrue(result.samples.allSatisfy(\.isFinite))
        XCTAssertTrue(result.samples.contains(where: { $0 != 0 }))
        monitor.stopMonitoring()
    }

    func testRapidEQPublicationWhileRenderingDoesNotTearOrFail() async {
        let runtime = FakeAudioUnitHALRuntime()
        let monitor = AudioMonitor(audioUnitRuntime: runtime)
        monitor.startMonitoring(deviceID: 121, outputDeviceID: nil)

        let renderTask = Task.detached {
            var statuses: [OSStatus] = []
            statuses.reserveCapacity(500)
            for _ in 0..<500 {
                statuses.append(
                    runtime.invokeInputCallback(frameCount: 64)
                )
            }
            return statuses
        }
        for iteration in 0..<500 {
            let value = Float((iteration % 25) - 12)
            monitor.eqBands = Array(repeating: value, count: 10)
            await Task.yield()
        }
        let statuses = await renderTask.value

        XCTAssertEqual(statuses.count, 500)
        XCTAssertTrue(statuses.allSatisfy { $0 == noErr })
        monitor.stopMonitoring()
    }

    func testFailedInputDisposeRetainsQuiescedUnitUntilRetry() {
        let runtime = FakeAudioUnitHALRuntime()
        let monitor = AudioMonitor(audioUnitRuntime: runtime)
        monitor.startMonitoring(deviceID: 131, outputDeviceID: nil)
        XCTAssertEqual(runtime.invokeInputCallback(frameCount: 64), noErr)
        let rendersBeforeStop = runtime.renderCount

        runtime.failNext(.dispose, status: injectedStatus)
        monitor.stopMonitoring()

        assertFailure(
            monitor,
            operation: "Dispose input AudioUnit",
            deviceID: 131,
            status: injectedStatus
        )
        XCTAssertEqual(runtime.disposeCount, 1)
        XCTAssertEqual(runtime.invokeInputCallback(frameCount: 64), noErr)
        XCTAssertEqual(
            runtime.renderCount,
            rendersBeforeStop,
            "A retained unit must route late callbacks through the closed gate"
        )

        runtime.clearFailure()
        monitor.stopMonitoring()
        XCTAssertEqual(runtime.disposeCount, 2)
        XCTAssertEqual(
            runtime.invokeInputCallback(frameCount: 64),
            kAudio_ParamError,
            "A successful retry must release and unregister the callback"
        )
        assertFailure(
            monitor,
            operation: "Dispose input AudioUnit",
            deviceID: 131,
            status: injectedStatus
        )
    }

    func testFailedOutputStopQuiescesCallbackWithoutResetRace() async {
        let runtime = FakeAudioUnitHALRuntime()
        let monitor = runningMonitor(runtime: runtime)
        monitor.enablePassthrough()
        XCTAssertEqual(runtime.invokeInputCallback(frameCount: 256), noErr)
        let underrunsBeforeStop = monitor.playbackUnderrunCount

        runtime.failNext(.stop, status: injectedStatus)
        monitor.disablePassthrough()

        assertFailure(
            monitor,
            operation: "Stop output",
            deviceID: 72,
            status: injectedStatus
        )
        let lateOutput = runtime.invokeMonoOutputCallback(frameCount: 128)
        XCTAssertEqual(lateOutput.status, noErr)
        XCTAssertTrue(lateOutput.samples.allSatisfy { $0 == 0 })
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(monitor.playbackUnderrunCount, underrunsBeforeStop)

        runtime.clearFailure()
        monitor.enablePassthrough()
        XCTAssertTrue(monitor.isPassthroughEnabled)
        XCTAssertNil(monitor.lastError)
        guard case .running = monitor.engineStatus else {
            return XCTFail("Output recovery must restore the running capture state")
        }
        monitor.stopMonitoring()
        XCTAssertEqual(runtime.stopCount, 3)
        XCTAssertEqual(runtime.disposeCount, 2)
    }

    func testPartiallyConfiguredOutputIsDisposedBeforeSuccessfulRetry() {
        let runtime = FakeAudioUnitHALRuntime()
        let monitor = runningMonitor(runtime: runtime)

        runtime.failNext(
            .setProperty(
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0
            ),
            status: injectedStatus
        )
        runtime.failNext(.dispose, status: injectedStatus)
        monitor.enablePassthrough()

        XCTAssertFalse(monitor.isPassthroughEnabled)
        assertFailure(
            monitor,
            operation: "Dispose output AudioUnit",
            deviceID: 72,
            status: injectedStatus
        )
        XCTAssertEqual(runtime.disposeCount, 1)

        runtime.clearFailure()
        monitor.enablePassthrough()

        XCTAssertTrue(monitor.isPassthroughEnabled)
        XCTAssertNil(monitor.lastError)
        XCTAssertEqual(runtime.disposeCount, 2)
        guard case .running = monitor.engineStatus else {
            return XCTFail("A clean output rebuild must restore capture status")
        }
        monitor.stopMonitoring()
    }

    func testDeinitSynchronouslyStopsDisposesAndUnregistersCallbacks() {
        let runtime = FakeAudioUnitHALRuntime()
        weak var weakMonitor: AudioMonitor?

        do {
            var monitor: AudioMonitor? = runningMonitor(runtime: runtime)
            monitor?.enablePassthrough()
            weakMonitor = monitor
            monitor = nil
        }

        XCTAssertNil(weakMonitor)
        XCTAssertEqual(runtime.stopCount, 2)
        XCTAssertEqual(runtime.disposeCount, 2)
        XCTAssertEqual(
            runtime.invokeInputCallback(frameCount: 64),
            kAudio_ParamError
        )
        XCTAssertEqual(
            runtime.invokeMonoOutputCallback(frameCount: 64).status,
            kAudio_ParamError
        )
    }

    func testDeinitDisposalFailureLeavesSafeDetachedCallbackSentinel() {
        let runtime = FakeAudioUnitHALRuntime()
        weak var weakMonitor: AudioMonitor?
        var rendersBeforeDeinit = 0

        do {
            var monitor: AudioMonitor? = AudioMonitor(
                audioUnitRuntime: runtime
            )
            monitor?.startMonitoring(deviceID: 133, outputDeviceID: nil)
            XCTAssertEqual(runtime.invokeInputCallback(frameCount: 64), noErr)
            rendersBeforeDeinit = runtime.renderCount
            runtime.failNext(.dispose, status: injectedStatus)
            weakMonitor = monitor
            monitor = nil
        }

        XCTAssertNil(weakMonitor)
        XCTAssertEqual(runtime.invokeInputCallback(frameCount: 64), noErr)
        XCTAssertEqual(runtime.renderCount, rendersBeforeDeinit)
    }

    func testAutoGainIsIdempotentUsesPostGainRatioAndRecoversFromZero() {
        let runtime = FakeAudioUnitHALRuntime()
        runtime.renderLeft = 0.125
        runtime.renderRight = 0
        let monitor = AudioMonitor(audioUnitRuntime: runtime)
        monitor.gain = 2
        monitor.isMeteringEnabled = true
        monitor.startMonitoring(deviceID: 132, outputDeviceID: nil)
        XCTAssertEqual(runtime.invokeInputCallback(frameCount: 64), noErr)
        XCTAssertEqual(monitor.testingAutoGainPeak, 0.25, accuracy: 0.000_01)

        monitor.isAutoGainEnabled = true
        let firstTimer = monitor.testingAutoGainTimerIdentity
        XCTAssertNotNil(firstTimer)

        monitor.isAutoGainEnabled = true
        XCTAssertEqual(monitor.testingAutoGainTimerIdentity, firstTimer)

        monitor.testingAdjustAutoGain()
        XCTAssertEqual(monitor.gain, 2.2, accuracy: 0.000_01)
        XCTAssertEqual(
            monitor.testingCallbackGain,
            monitor.gain,
            accuracy: 0.000_01
        )

        monitor.gain = 0
        monitor.updatePassthroughVolume()
        runtime.renderLeft = 0.005
        XCTAssertEqual(runtime.invokeInputCallback(frameCount: 64), noErr)
        XCTAssertEqual(monitor.testingAutoGainPeak, 0, accuracy: 0.000_01)
        monitor.testingAdjustAutoGain()
        XCTAssertEqual(monitor.gain, 1, accuracy: 0.000_01)
        XCTAssertEqual(monitor.testingCallbackGain, 1, accuracy: 0.000_01)
        XCTAssertEqual(runtime.invokeInputCallback(frameCount: 64), noErr)
        XCTAssertEqual(monitor.testingAutoGainPeak, 0.005, accuracy: 0.000_01)
        monitor.testingAdjustAutoGain()
        XCTAssertGreaterThan(monitor.gain, 1)

        monitor.isAutoGainEnabled = false
        XCTAssertNil(monitor.testingAutoGainTimerIdentity)
        monitor.stopMonitoring()
    }

    func testEQBypassesAtAndAboveNyquistButKeepsValidBand() {
        for sampleRate in [24_000.0, 32_000.0] {
            let runtime = FakeAudioUnitHALRuntime()
            runtime.sampleRate = sampleRate
            runtime.renderLeft = 0.2
            runtime.renderRight = 0.2
            let monitor = AudioMonitor(audioUnitRuntime: runtime)
            monitor.eqBands = Array(repeating: 0, count: 9) + [12]
            monitor.startMonitoring(
                deviceID: 141,
                outputDeviceID: 142
            )
            XCTAssertFalse(monitor.testingEQIsActive)
            monitor.enablePassthrough()
            XCTAssertEqual(runtime.invokeInputCallback(frameCount: 64), noErr)
            let rendered = runtime.invokeMonoOutputCallback(frameCount: 64)
            XCTAssertEqual(rendered.status, noErr)
            XCTAssertTrue(
                rendered.samples.allSatisfy {
                    abs($0 - 0.2) < 0.000_01
                }
            )
            monitor.stopMonitoring()
        }

        let validRuntime = FakeAudioUnitHALRuntime()
        validRuntime.sampleRate = 48_000
        validRuntime.renderLeft = 0.2
        validRuntime.renderRight = 0.2
        let validMonitor = AudioMonitor(audioUnitRuntime: validRuntime)
        validMonitor.eqBands = Array(repeating: 0, count: 9) + [12]
        validMonitor.startMonitoring(
            deviceID: 143,
            outputDeviceID: 144
        )
        XCTAssertTrue(validMonitor.testingEQIsActive)
        validMonitor.enablePassthrough()
        XCTAssertEqual(
            validRuntime.invokeInputCallback(frameCount: 64),
            noErr
        )
        let validRendered =
            validRuntime.invokeMonoOutputCallback(frameCount: 64)
        XCTAssertEqual(validRendered.status, noErr)
        XCTAssertTrue(validRendered.samples.allSatisfy(\.isFinite))
        validMonitor.stopMonitoring()
    }

    private func runningMonitor(
        runtime: FakeAudioUnitHALRuntime
    ) -> AudioMonitor {
        let monitor = AudioMonitor(audioUnitRuntime: runtime)
        monitor.startMonitoring(
            deviceID: 71,
            outputDeviceID: 72
        )
        XCTAssertTrue(monitor.isMonitoring)
        return monitor
    }

    private func assertFailure(
        _ monitor: AudioMonitor,
        operation: String,
        deviceID: AudioDeviceID,
        status: OSStatus,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .failed(let failure) = monitor.engineStatus else {
            return XCTFail(
                "Expected a typed engine failure",
                file: file,
                line: line
            )
        }
        XCTAssertEqual(failure.operation, operation, file: file, line: line)
        XCTAssertEqual(failure.deviceID, deviceID, file: file, line: line)
        XCTAssertEqual(failure.status, status, file: file, line: line)
        XCTAssertEqual(monitor.lastError, failure, file: file, line: line)
    }

    private func eventually(
        timeout: TimeInterval = 2,
        _ predicate: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return predicate()
    }
}

nonisolated private final class FakeAudioUnitHALRuntime:
    AudioUnitHALRuntime, @unchecked Sendable
{
    enum Operation: Hashable {
        case findComponent
        case instantiate
        case dispose
        case initialize
        case start
        case stop
        case render
        case setProperty(
            AudioUnitPropertyID,
            AudioUnitScope,
            AudioUnitElement
        )
        case getProperty(
            AudioUnitPropertyID,
            AudioUnitScope,
            AudioUnitElement
        )
        case getObjectProperty(AudioObjectPropertySelector)
        case setObjectProperty(AudioObjectPropertySelector)
    }

    private let lock = NSLock()
    private var failures: [(operation: Operation, status: OSStatus)] = []
    private var nextUnitAddress = 0x10_000
    private var inputCallback: AURenderCallbackStruct?
    private var outputCallback: AURenderCallbackStruct?
    private var inputCallbackUnit: AudioUnit?
    private var outputCallbackUnit: AudioUnit?
    private var stops = 0
    private var disposals = 0
    private var renders = 0

    private(set) var lastChannelMap: [Int32]?
    private(set) var lastInputClientFormat: AudioStreamBasicDescription?
    var sampleRate: Double = 48_000
    var renderLeft: Float = 0.25
    var renderRight: Float = -0.25

    var stopCount: Int {
        lock.withLock { stops }
    }

    var disposeCount: Int {
        lock.withLock { disposals }
    }

    var renderCount: Int {
        lock.withLock { renders }
    }

    func failNext(_ operation: Operation, status: OSStatus) {
        lock.withLock {
            failures.append((operation, status))
        }
    }

    func clearFailure() {
        lock.withLock {
            failures.removeAll(keepingCapacity: true)
        }
    }

    func findComponent(
        matching description: AudioComponentDescription
    ) -> AudioComponent? {
        _ = description
        if consumeFailure(.findComponent) != nil {
            return nil
        }
        return AudioComponent(bitPattern: 0xCAFE)
    }

    func instantiate(
        _ component: AudioComponent,
        unit: UnsafeMutablePointer<AudioUnit?>
    ) -> OSStatus {
        _ = component
        if let status = consumeFailure(.instantiate) {
            return status
        }
        lock.withLock {
            unit.pointee = AudioUnit(bitPattern: nextUnitAddress)
            nextUnitAddress += 1
        }
        return noErr
    }

    func dispose(_ unit: AudioUnit) -> OSStatus {
        lock.withLock {
            disposals += 1
        }
        if let status = consumeFailure(.dispose) {
            return status
        }
        lock.withLock {
            if unit == inputCallbackUnit {
                inputCallback = nil
                inputCallbackUnit = nil
            }
            if unit == outputCallbackUnit {
                outputCallback = nil
                outputCallbackUnit = nil
            }
        }
        return noErr
    }

    func setProperty(
        _ unit: AudioUnit,
        id: AudioUnitPropertyID,
        scope: AudioUnitScope,
        element: AudioUnitElement,
        data: UnsafeRawPointer?,
        byteCount: UInt32
    ) -> OSStatus {
        _ = unit
        _ = byteCount
        let operation = Operation.setProperty(id, scope, element)
        if let status = consumeFailure(operation) {
            return status
        }
        guard let data else { return kAudio_ParamError }

        lock.withLock {
            if id == kAudioOutputUnitProperty_ChannelMap {
                let count = Int(byteCount) / MemoryLayout<Int32>.stride
                let values = data.assumingMemoryBound(to: Int32.self)
                lastChannelMap = (0..<count).map { values[$0] }
            } else if id == kAudioUnitProperty_StreamFormat,
                scope == kAudioUnitScope_Output,
                element == 1
            {
                lastInputClientFormat =
                    data.load(as: AudioStreamBasicDescription.self)
            } else if id == kAudioOutputUnitProperty_SetInputCallback {
                inputCallback = data.load(as: AURenderCallbackStruct.self)
                inputCallbackUnit = unit
            } else if id == kAudioUnitProperty_SetRenderCallback {
                outputCallback = data.load(as: AURenderCallbackStruct.self)
                outputCallbackUnit = unit
            }
        }
        return noErr
    }

    func getProperty(
        _ unit: AudioUnit,
        id: AudioUnitPropertyID,
        scope: AudioUnitScope,
        element: AudioUnitElement,
        data: UnsafeMutableRawPointer,
        byteCount: UnsafeMutablePointer<UInt32>
    ) -> OSStatus {
        _ = unit
        let operation = Operation.getProperty(id, scope, element)
        if let status = consumeFailure(operation) {
            return status
        }
        if id == kAudioUnitProperty_StreamFormat {
            let channelCount: UInt32 = element == 1 ? 4 : 2
            data.storeBytes(
                of: AudioStreamBasicDescription(
                    mSampleRate: sampleRate,
                    mFormatID: kAudioFormatLinearPCM,
                    mFormatFlags: kAudioFormatFlagIsFloat
                        | kAudioFormatFlagIsPacked
                        | kAudioFormatFlagIsNonInterleaved,
                    mBytesPerPacket: 4,
                    mFramesPerPacket: 1,
                    mBytesPerFrame: 4,
                    mChannelsPerFrame: channelCount,
                    mBitsPerChannel: 32,
                    mReserved: 0
                ),
                as: AudioStreamBasicDescription.self
            )
            byteCount.pointee = UInt32(
                MemoryLayout<AudioStreamBasicDescription>.size
            )
        } else if id == kAudioUnitProperty_MaximumFramesPerSlice {
            data.storeBytes(of: UInt32(512), as: UInt32.self)
            byteCount.pointee = UInt32(MemoryLayout<UInt32>.size)
        }
        return noErr
    }

    func initialize(_ unit: AudioUnit) -> OSStatus {
        _ = unit
        return consumeFailure(.initialize) ?? noErr
    }

    func start(_ unit: AudioUnit) -> OSStatus {
        _ = unit
        return consumeFailure(.start) ?? noErr
    }

    func stop(_ unit: AudioUnit) -> OSStatus {
        _ = unit
        lock.withLock {
            stops += 1
        }
        return consumeFailure(.stop) ?? noErr
    }

    func render(
        _ unit: AudioUnit,
        actionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timestamp: UnsafePointer<AudioTimeStamp>,
        bus: AudioUnitElement,
        frameCount: UInt32,
        data: UnsafeMutablePointer<AudioBufferList>
    ) -> OSStatus {
        _ = unit
        _ = actionFlags
        _ = timestamp
        _ = bus
        if let status = consumeFailure(.render) {
            return status
        }
        lock.withLock {
            renders += 1
        }

        let buffers = UnsafeMutableAudioBufferListPointer(data)
        for (index, buffer) in buffers.enumerated() {
            guard
                let samples = buffer.mData?.assumingMemoryBound(
                    to: Float.self
                )
            else {
                continue
            }
            let count = min(
                Int(frameCount),
                Int(buffer.mDataByteSize) / MemoryLayout<Float>.stride
            )
            let value = index == 0 ? renderLeft : renderRight
            samples.initialize(repeating: value, count: count)
        }
        return noErr
    }

    func getObjectPropertyData(
        objectID: AudioObjectID,
        address: UnsafePointer<AudioObjectPropertyAddress>,
        qualifierDataSize: UInt32,
        qualifierData: UnsafeRawPointer?,
        dataSize: UnsafeMutablePointer<UInt32>,
        data: UnsafeMutableRawPointer
    ) -> OSStatus {
        _ = objectID
        _ = qualifierDataSize
        _ = qualifierData
        let selector = address.pointee.mSelector
        if let status = consumeFailure(.getObjectProperty(selector)) {
            return status
        }
        if selector == kAudioDevicePropertyBufferFrameSizeRange {
            data.storeBytes(
                of: AudioValueRange(mMinimum: 64, mMaximum: 1_024),
                as: AudioValueRange.self
            )
            dataSize.pointee = UInt32(MemoryLayout<AudioValueRange>.size)
        } else if selector == kAudioDevicePropertyBufferFrameSize {
            data.storeBytes(of: UInt32(256), as: UInt32.self)
            dataSize.pointee = UInt32(MemoryLayout<UInt32>.size)
        }
        return noErr
    }

    func setObjectPropertyData(
        objectID: AudioObjectID,
        address: UnsafePointer<AudioObjectPropertyAddress>,
        qualifierDataSize: UInt32,
        qualifierData: UnsafeRawPointer?,
        dataSize: UInt32,
        data: UnsafeRawPointer
    ) -> OSStatus {
        _ = objectID
        _ = qualifierDataSize
        _ = qualifierData
        _ = dataSize
        _ = data
        return consumeFailure(
            .setObjectProperty(address.pointee.mSelector)
        ) ?? noErr
    }

    func invokeInputCallback(frameCount: UInt32) -> OSStatus {
        guard let callback = lock.withLock({ inputCallback }) else {
            return kAudio_ParamError
        }
        var flags: AudioUnitRenderActionFlags = []
        var timestamp = AudioTimeStamp()
        guard
            let procedure = callback.inputProc,
            let reference = callback.inputProcRefCon
        else {
            return kAudio_ParamError
        }
        return procedure(
            reference,
            &flags,
            &timestamp,
            1,
            frameCount,
            nil
        )
    }

    func invokeMonoOutputCallback(
        frameCount: UInt32
    ) -> (status: OSStatus, samples: [Float]) {
        guard let callback = lock.withLock({ outputCallback }) else {
            return (kAudio_ParamError, [])
        }
        var samples = Array(repeating: Float.zero, count: Int(frameCount))
        var flags: AudioUnitRenderActionFlags = []
        var timestamp = AudioTimeStamp()
        guard
            let procedure = callback.inputProc,
            let reference = callback.inputProcRefCon
        else {
            return (kAudio_ParamError, samples)
        }
        let status = samples.withUnsafeMutableBytes { bytes in
            var list = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: 1,
                    mDataByteSize: UInt32(bytes.count),
                    mData: bytes.baseAddress
                )
            )
            return procedure(
                reference,
                &flags,
                &timestamp,
                0,
                frameCount,
                &list
            )
        }
        return (status, samples)
    }

    private func consumeFailure(_ operation: Operation) -> OSStatus? {
        lock.withLock {
            guard
                let index = failures.firstIndex(where: {
                    $0.operation == operation
                })
            else {
                return nil
            }
            return failures.remove(at: index).status
        }
    }
}
