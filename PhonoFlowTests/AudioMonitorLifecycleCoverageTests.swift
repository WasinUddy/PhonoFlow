import AudioToolbox
import CoreAudio
import Darwin
import Foundation
import XCTest

@testable import PhonoFlow

@MainActor
final class AudioMonitorLifecycleCoverageTests: XCTestCase {
    func testFormattingIdleCleanupAndPrintableCoreAudioStatus() {
        XCTAssertEqual(
            AudioRuntimeFormat(
                sampleRate: 999,
                channelCount: 1,
                bufferFrames: 64,
                inputChannelMap: [0, 0]
            ).summary,
            "999 Hz · 1 ch · 64 frames"
        )

        let printableStatus = OSStatus(bitPattern: 0x6661_696C)
        let failure = AudioEngineFailure(
            operation: "Test",
            status: printableStatus,
            deviceID: nil,
            detail: "Printable status"
        )
        XCTAssertTrue(failure.localizedDescription.contains("'fail'"))

        let monitor = makeMonitor()
        monitor.disablePassthrough()
        monitor.updatePassthroughVolume()
        XCTAssertFalse(monitor.isPassthroughEnabled)
        XCTAssertEqual(monitor.engineStatus, .idle)
    }

    func testRemoteAndLegacyAttachmentsReconcileStreamingURLPrecedence() {
        let monitor = makeMonitor()
        let fanout = RemoteAudioFanout()
        let server = RemoteAccessServer(
            coordinator: FakeRemoteCoordinator(),
            pairing: RemotePairingService(
                store: InMemoryRemoteCredentialStore()
            ),
            audio: fanout,
            assets: InMemoryRemoteStaticAssetProvider(assets: [:]),
            bonjour: DisabledRemoteBonjourAdvertiser(),
            transport: UnavailableRemoteHTTPTransport(),
            localAuthorityProvider: { [] },
            usesAcceptanceEnvironment: false
        )
        defer {
            monitor.stopStreaming()
            monitor.detachRemoteAccess()
            monitor.detachLegacyStream()
        }

        monitor.attachRemoteAccess(
            audioFanout: fanout,
            server: server,
            baseURL: "http://paired.test:19112/"
        )
        monitor.startStreaming(port: 19_111, allowedHosts: ["127.0.0.1"])
        XCTAssertEqual(
            monitor.streamURL,
            "http://paired.test:19112/stream"
        )
        monitor.setRemoteSpectrumSubscribersVisible(true)
        monitor.setRemoteAudioSubscribersVisible(false)

        monitor.attachLegacyStream(
            audioFanout: fanout,
            baseURL: "http://legacy.test:19113///"
        )
        XCTAssertEqual(
            monitor.streamURL,
            "http://legacy.test:19113/stream"
        )

        monitor.detachRemoteAccess()
        XCTAssertEqual(
            monitor.streamURL,
            "http://legacy.test:19113/stream"
        )

        monitor.detachLegacyStream()
        XCTAssertTrue(monitor.streamURL.hasSuffix(":7865/stream"))

        monitor.attachRemoteAccess(
            audioFanout: fanout,
            server: server,
            baseURL: "http://paired-again.test:19114"
        )
        monitor.stopStreaming()
        monitor.startStreaming(port: 19_115)
        XCTAssertEqual(
            monitor.streamURL,
            "http://paired-again.test:19114/stream"
        )
        monitor.detachLegacyStream()
        monitor.detachRemoteAccess()
        XCTAssertTrue(monitor.streamURL.hasSuffix(":7865/stream"))
    }

    func testPassthroughRouteSwitchStopsDisposesAndRestartsOutput() {
        let runtime = AudioMonitorCoverageHALRuntime()
        let monitor = makeMonitor(runtime)
        defer { monitor.stopMonitoring() }

        monitor.startMonitoring(
            deviceID: 101,
            outputDeviceID: 202,
            inputChannelMap: [0, 1]
        )
        XCTAssertTrue(monitor.isMonitoring)
        XCTAssertEqual(runtime.startCount, 1)
        XCTAssertEqual(runtime.selectedDevices.first, 101)
        monitor.enablePassthrough()
        XCTAssertTrue(monitor.isPassthroughEnabled)

        let startsBeforeSwitch = runtime.startCount
        let stopsBeforeSwitch = runtime.stopCount
        let disposalsBeforeSwitch = runtime.disposeCount
        monitor.updatePassthroughOutput(deviceID: 303)

        XCTAssertTrue(monitor.isPassthroughEnabled)
        XCTAssertEqual(runtime.startCount, startsBeforeSwitch + 1)
        XCTAssertEqual(runtime.stopCount, stopsBeforeSwitch + 1)
        XCTAssertEqual(runtime.disposeCount, disposalsBeforeSwitch + 1)
        XCTAssertEqual(
            runtime.selectedDevices.suffix(2),
            [202, 303]
        )

        monitor.clearPassthroughOutput()
        XCTAssertFalse(monitor.isPassthroughEnabled)
        let startsAfterClear = runtime.startCount
        monitor.updatePassthroughOutput(deviceID: 404)
        XCTAssertEqual(runtime.startCount, startsAfterClear)
    }

    func testInvalidRouteAndZeroRateProduceSpecificInputFailures() {
        do {
            let runtime = AudioMonitorCoverageHALRuntime()
            runtime.inputChannelCount = 2
            let monitor = makeMonitor(runtime)
            defer { monitor.stopMonitoring() }

            monitor.startMonitoring(
                deviceID: 501,
                outputDeviceID: nil,
                inputChannelMap: [2, 3]
            )

            guard case .failed(let failure) = monitor.engineStatus else {
                return XCTFail("Expected unavailable input channels to fail")
            }
            XCTAssertEqual(failure.operation, "Select input channels")
            XCTAssertEqual(failure.status, kAudio_ParamError)
            XCTAssertTrue(failure.detail.contains("2-channel"))
            XCTAssertFalse(monitor.isMonitoring)
        }

        do {
            let runtime = AudioMonitorCoverageHALRuntime()
            runtime.sampleRate = 0
            let monitor = makeMonitor(runtime)
            defer { monitor.stopMonitoring() }

            monitor.startMonitoring(
                deviceID: 502,
                outputDeviceID: nil
            )

            guard case .failed(let failure) = monitor.engineStatus else {
                return XCTFail("Expected a zero hardware sample rate to fail")
            }
            XCTAssertEqual(failure.operation, "Read input device format")
            XCTAssertEqual(failure.status, kAudio_ParamError)
            XCTAssertFalse(monitor.isMonitoring)
        }
    }

    func testLargeCapacityRingWrapOverflowAndOutputGuards() async {
        let runtime = AudioMonitorCoverageHALRuntime()
        runtime.maximumFramesPerSlice = 32_768
        let rampScale: Float = 0.000_01
        let rightOffset: Float = 0.25
        runtime.configureRamp(
            scale: rampScale,
            rightOffset: rightOffset
        )
        let monitor = makeMonitor(runtime)
        defer { monitor.stopMonitoring() }

        monitor.isMeteringEnabled = true
        monitor.startMonitoring(
            deviceID: 601,
            outputDeviceID: 601
        )
        monitor.enablePassthrough()
        XCTAssertTrue(monitor.isPassthroughEnabled)

        XCTAssertEqual(runtime.invokeInputCallback(frameCount: 12_000), noErr)
        let firstRead = runtime.invokeOutputCallback(
            frameCount: 10_000,
            channelCount: 2
        )
        XCTAssertEqual(firstRead.status, noErr)
        let firstExpected = expectedRamp(
            startingAt: 0,
            count: 10_000,
            scale: rampScale
        )
        XCTAssertEqual(firstRead.channels[0], firstExpected)
        XCTAssertEqual(
            firstRead.channels[1],
            firstExpected.map { $0 + rightOffset }
        )

        // The second write and read cross the physical end of both playback
        // arrays while preserving the logical SPSC sequence.
        XCTAssertEqual(runtime.invokeInputCallback(frameCount: 8_000), noErr)
        let wrappedRead = runtime.invokeOutputCallback(
            frameCount: 10_000,
            channelCount: 2
        )
        XCTAssertEqual(wrappedRead.status, noErr)
        let wrappedExpected = expectedRamp(
            startingAt: 10_000,
            count: 10_000,
            scale: rampScale
        )
        XCTAssertEqual(wrappedRead.channels[0], wrappedExpected)
        XCTAssertEqual(
            wrappedRead.channels[1],
            wrappedExpected.map { $0 + rightOffset }
        )

        // A request larger than the fixed playback ring first partially fits,
        // then a second request exercises the fully-saturated fast path.
        XCTAssertEqual(runtime.invokeInputCallback(frameCount: 20_000), noErr)
        XCTAssertEqual(runtime.invokeInputCallback(frameCount: 1), noErr)

        let extraChannels = runtime.invokeOutputCallback(
            frameCount: 1_024,
            channelCount: 3
        )
        XCTAssertEqual(extraChannels.status, noErr)
        let overflowExpected = expectedRamp(
            startingAt: 20_000,
            count: 1_024,
            scale: rampScale
        )
        XCTAssertEqual(extraChannels.channels[0], overflowExpected)
        XCTAssertEqual(
            extraChannels.channels[1],
            overflowExpected.map { $0 + rightOffset }
        )
        XCTAssertTrue(extraChannels.channels[2].allSatisfy { $0 == 0 })

        let oversizedActiveOutput = runtime.invokeOutputCallback(
            frameCount: 32_770,
            channelCount: 2
        )
        XCTAssertEqual(oversizedActiveOutput.status, kAudio_ParamError)
        XCTAssertTrue(
            oversizedActiveOutput.channels.joined().allSatisfy { $0 == 0 }
        )

        monitor.disablePassthrough()
        let silentStereo = runtime.invokeOutputCallback(
            frameCount: 128,
            channelCount: 2
        )
        XCTAssertEqual(silentStereo.status, noErr)
        XCTAssertTrue(silentStereo.channels.joined().allSatisfy { $0 == 0 })

        let silentMono = runtime.invokeOutputCallback(
            frameCount: 128,
            channelCount: 1
        )
        XCTAssertEqual(silentMono.status, noErr)
        XCTAssertTrue(silentMono.channels[0].allSatisfy { $0 == 0 })

        XCTAssertEqual(
            runtime.invokeOutputCallback(
                frameCount: 32,
                channelCount: 0
            ).status,
            noErr
        )
        XCTAssertEqual(
            runtime.invokeOutputCallback(
                frameCount: 32,
                channelCount: 1,
                provideFirstBuffer: false
            ).status,
            noErr
        )

        // Once passthrough has stopped, the callback gate deliberately avoids
        // touching the detached playback state regardless of frame count.
        let oversizedQuiescedOutput = runtime.invokeOutputCallback(
            frameCount: 32_770,
            channelCount: 2
        )
        XCTAssertEqual(oversizedQuiescedOutput.status, noErr)
        XCTAssertTrue(
            oversizedQuiescedOutput.channels.joined().allSatisfy { $0 == 0 }
        )
        XCTAssertEqual(
            runtime.invokeInputCallback(frameCount: 32_770),
            kAudio_ParamError
        )

        let diagnosticsPublished = await eventually {
            monitor.playbackOverflowCount == 3_617
                && monitor.playbackUnderrunCount == 0
                && monitor.callbackOverflowCount >= 7_234
                && monitor.callbackCount == 5
                && monitor.peakLevel > 0
        }
        XCTAssertTrue(diagnosticsPublished)
        XCTAssertEqual(runtime.renderedInputFrameCount, 40_001)
    }

    func testDifferentClockDomainsExerciseBothDriftResamplingEdges() async {
        let runtime = AudioMonitorCoverageHALRuntime()
        runtime.maximumFramesPerSlice = 4_096
        let rampScale: Float = 0.000_1
        let rightOffset: Float = 0.25
        runtime.configureRamp(
            scale: rampScale,
            rightOffset: rightOffset
        )
        let monitor = makeMonitor(runtime)
        defer { monitor.stopMonitoring() }

        monitor.startMonitoring(
            deviceID: 701,
            outputDeviceID: 702
        )
        monitor.enablePassthrough()

        XCTAssertEqual(runtime.invokeInputCallback(frameCount: 4_096), noErr)
        let highFill = runtime.invokeOutputCallback(
            frameCount: 256,
            channelCount: 2
        )
        XCTAssertEqual(highFill.status, noErr)
        XCTAssertEqual(highFill.channels[0][0], 0)
        XCTAssertEqual(
            highFill.channels[0][255],
            Float(256) * rampScale,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            highFill.channels[0][128],
            Float(128) * Float(256) / Float(255) * rampScale,
            accuracy: 0.000_001
        )
        XCTAssertEqual(highFill.channels[1][0], rightOffset)
        XCTAssertEqual(
            highFill.channels[1][255],
            rightOffset + Float(256) * rampScale,
            accuracy: 0.000_001
        )

        monitor.disablePassthrough()
        monitor.enablePassthrough()
        XCTAssertEqual(runtime.invokeInputCallback(frameCount: 256), noErr)
        let lowFill = runtime.invokeOutputCallback(
            frameCount: 256,
            channelCount: 1
        )
        XCTAssertEqual(lowFill.status, noErr)
        XCTAssertEqual(
            lowFill.channels[0][0],
            Float(4_096) * rampScale + rightOffset * 0.5,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            lowFill.channels[0][255],
            Float(4_350) * rampScale + rightOffset * 0.5,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            lowFill.channels[0][128],
            (Float(4_096) + Float(128) * Float(254) / Float(255))
                * rampScale + rightOffset * 0.5,
            accuracy: 0.000_001
        )

        // Low-fill correction consumes 255 frames for a 256-frame request,
        // leaving the final ramp sample for the next callback.
        let remainingFrame = runtime.invokeOutputCallback(
            frameCount: 1,
            channelCount: 1
        )
        XCTAssertEqual(remainingFrame.status, noErr)
        XCTAssertEqual(remainingFrame.channels[0].count, 1)
        XCTAssertEqual(
            remainingFrame.channels[0][0],
            Float(4_351) * rampScale + rightOffset * 0.5,
            accuracy: 0.000_001
        )

        let diagnosticsPublished = await eventually {
            monitor.callbackCount == 2
                && monitor.callbackOverflowCount == 0
                && monitor.playbackOverflowCount == 0
                && monitor.playbackUnderrunCount == 0
        }
        XCTAssertTrue(diagnosticsPublished)
        XCTAssertEqual(runtime.renderedInputFrameCount, 4_352)
    }

    func testAutoGainUpdatesLivePassthroughParameters() async {
        let runtime = AudioMonitorCoverageHALRuntime()
        let monitor = makeMonitor(runtime)
        defer {
            monitor.isAutoGainEnabled = false
            monitor.stopMonitoring()
        }

        monitor.startMonitoring(
            deviceID: 801,
            outputDeviceID: 801
        )
        monitor.enablePassthrough()
        monitor.isMeteringEnabled = true
        runtime.renderLeft = 1
        runtime.renderRight = 0
        XCTAssertEqual(runtime.invokeInputCallback(frameCount: 64), noErr)
        monitor.isAutoGainEnabled = true

        let adjusted = await eventually {
            monitor.testingCallbackGain < 1
        }
        XCTAssertTrue(adjusted)
        XCTAssertTrue(monitor.isPassthroughEnabled)
    }

    private func makeMonitor(
        _ runtime: AudioMonitorCoverageHALRuntime =
            AudioMonitorCoverageHALRuntime()
    ) -> AudioMonitor {
        AudioMonitor(
            audioUnitRuntime: runtime,
            // A forced local acceptance request still cannot supersede the
            // injected HAL. This simulates ambient acceptance configuration
            // without mutating process-global environment variables.
            acceptanceAudioBackendOverride: true
        )
    }

    private func expectedRamp(
        startingAt start: Int,
        count: Int,
        scale: Float
    ) -> [Float] {
        (start..<(start + count)).map { Float($0) * scale }
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

nonisolated private final class AudioMonitorCoverageHALRuntime:
    AudioUnitHALRuntime, @unchecked Sendable
{
    private let lock = NSLock()
    private var nextUnitAddress = 0xB000
    private var inputCallback: AURenderCallbackStruct?
    private var outputCallback: AURenderCallbackStruct?
    private var starts = 0
    private var stops = 0
    private var disposals = 0
    private var deviceSelections: [AudioDeviceID] = []
    private var rampScale: Float?
    private var rampRightOffset: Float = 0
    private var renderFrameCursor: UInt64 = 0

    var sampleRate: Double = 48_000
    var inputChannelCount: UInt32 = 4
    var outputChannelCount: UInt32 = 2
    var maximumFramesPerSlice: UInt32 = 512
    var bufferFrameSize: UInt32 = 256
    var renderLeft: Float = 0.25
    var renderRight: Float = -0.125

    var startCount: Int {
        lock.withLock { starts }
    }

    var stopCount: Int {
        lock.withLock { stops }
    }

    var disposeCount: Int {
        lock.withLock { disposals }
    }

    var selectedDevices: [AudioDeviceID] {
        lock.withLock { deviceSelections }
    }

    var renderedInputFrameCount: UInt64 {
        lock.withLock { renderFrameCursor }
    }

    func configureRamp(
        scale: Float,
        rightOffset: Float,
        startingAt frame: UInt64 = 0
    ) {
        lock.withLock {
            rampScale = scale
            rampRightOffset = rightOffset
            renderFrameCursor = frame
        }
    }

    func findComponent(
        matching description: AudioComponentDescription
    ) -> AudioComponent? {
        _ = description
        return AudioComponent(bitPattern: 0xCAFE)
    }

    func instantiate(
        _ component: AudioComponent,
        unit: UnsafeMutablePointer<AudioUnit?>
    ) -> OSStatus {
        _ = component
        lock.withLock {
            unit.pointee = AudioUnit(bitPattern: nextUnitAddress)
            nextUnitAddress += 1
        }
        return noErr
    }

    func dispose(_ unit: AudioUnit) -> OSStatus {
        _ = unit
        lock.withLock {
            disposals += 1
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
        _ = scope
        _ = element
        guard let data else { return kAudio_ParamError }

        lock.withLock {
            if id == kAudioOutputUnitProperty_CurrentDevice {
                deviceSelections.append(
                    data.load(as: AudioDeviceID.self)
                )
            } else if id == kAudioOutputUnitProperty_SetInputCallback {
                inputCallback = data.load(
                    as: AURenderCallbackStruct.self
                )
            } else if id == kAudioUnitProperty_SetRenderCallback {
                outputCallback = data.load(
                    as: AURenderCallbackStruct.self
                )
            }
        }
        _ = byteCount
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
        _ = scope
        if id == kAudioUnitProperty_StreamFormat {
            let channels =
                element == 1 ? inputChannelCount : outputChannelCount
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
                    mChannelsPerFrame: channels,
                    mBitsPerChannel: 32,
                    mReserved: 0
                ),
                as: AudioStreamBasicDescription.self
            )
            byteCount.pointee = UInt32(
                MemoryLayout<AudioStreamBasicDescription>.size
            )
        } else if id == kAudioUnitProperty_MaximumFramesPerSlice {
            data.storeBytes(
                of: maximumFramesPerSlice,
                as: UInt32.self
            )
            byteCount.pointee = UInt32(MemoryLayout<UInt32>.size)
        }
        return noErr
    }

    func initialize(_ unit: AudioUnit) -> OSStatus {
        _ = unit
        return noErr
    }

    func start(_ unit: AudioUnit) -> OSStatus {
        _ = unit
        lock.withLock {
            starts += 1
        }
        return noErr
    }

    func stop(_ unit: AudioUnit) -> OSStatus {
        _ = unit
        lock.withLock {
            stops += 1
        }
        return noErr
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
        let fixture = lock.withLock {
            () -> (scale: Float?, rightOffset: Float, start: UInt64) in
            let start = renderFrameCursor
            renderFrameCursor &+= UInt64(frameCount)
            return (rampScale, rampRightOffset, start)
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
            if let scale = fixture.scale {
                for frame in 0..<count {
                    let value =
                        Float(fixture.start + UInt64(frame)) * scale
                    samples[frame] =
                        index == 0
                        ? value
                        : value + fixture.rightOffset
                }
            } else {
                samples.initialize(
                    repeating: index == 0 ? renderLeft : renderRight,
                    count: count
                )
            }
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
        if address.pointee.mSelector
            == kAudioDevicePropertyBufferFrameSizeRange
        {
            data.storeBytes(
                of: AudioValueRange(
                    mMinimum: 64,
                    mMaximum: Double(maximumFramesPerSlice)
                ),
                as: AudioValueRange.self
            )
            dataSize.pointee = UInt32(
                MemoryLayout<AudioValueRange>.size
            )
        } else if address.pointee.mSelector
            == kAudioDevicePropertyBufferFrameSize
        {
            data.storeBytes(of: bufferFrameSize, as: UInt32.self)
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
        _ = address
        _ = qualifierDataSize
        _ = qualifierData
        _ = dataSize
        bufferFrameSize = data.load(as: UInt32.self)
        return noErr
    }

    func invokeInputCallback(frameCount: UInt32) -> OSStatus {
        guard let callback = lock.withLock({ inputCallback }) else {
            return kAudio_ParamError
        }
        guard
            let procedure = callback.inputProc,
            let reference = callback.inputProcRefCon
        else {
            return kAudio_ParamError
        }
        var flags: AudioUnitRenderActionFlags = []
        var timestamp = AudioTimeStamp()
        return procedure(
            reference,
            &flags,
            &timestamp,
            1,
            frameCount,
            nil
        )
    }

    func invokeOutputCallback(
        frameCount: UInt32,
        channelCount: Int,
        provideFirstBuffer: Bool = true
    ) -> (status: OSStatus, channels: [[Float]]) {
        guard let callback = lock.withLock({ outputCallback }) else {
            return (kAudio_ParamError, [])
        }
        guard
            let procedure = callback.inputProc,
            let reference = callback.inputProcRefCon
        else {
            return (kAudio_ParamError, [])
        }

        let list = AudioBufferList.allocate(
            maximumBuffers: max(channelCount, 1)
        )
        list.count = channelCount
        let sampleCount = Int(frameCount)
        var allocations: [UnsafeMutablePointer<Float>] = []
        allocations.reserveCapacity(channelCount)
        for index in 0..<channelCount {
            let samples = UnsafeMutablePointer<Float>.allocate(
                capacity: max(sampleCount, 1)
            )
            samples.initialize(
                repeating: -0.75,
                count: max(sampleCount, 1)
            )
            allocations.append(samples)
            list[index] = AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: UInt32(
                    sampleCount * MemoryLayout<Float>.stride
                ),
                mData: !provideFirstBuffer && index == 0
                    ? nil
                    : UnsafeMutableRawPointer(samples)
            )
        }

        var flags: AudioUnitRenderActionFlags = []
        var timestamp = AudioTimeStamp()
        let status = procedure(
            reference,
            &flags,
            &timestamp,
            0,
            frameCount,
            list.unsafeMutablePointer
        )
        let channels = allocations.map { samples in
            Array(
                UnsafeBufferPointer(
                    start: samples,
                    count: sampleCount
                )
            )
        }
        for samples in allocations {
            samples.deinitialize(count: max(sampleCount, 1))
            samples.deallocate()
        }
        free(list.unsafeMutablePointer)
        return (status, channels)
    }
}
