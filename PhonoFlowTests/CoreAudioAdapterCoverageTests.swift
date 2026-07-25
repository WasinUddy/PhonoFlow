import CoreAudio
import Foundation
import XCTest

@testable import PhonoFlow

@MainActor
final class AudioDeviceManagerAdapterCoverageTests: XCTestCase {
    func testRefreshFiltersSortsSelectsAndMapsDeviceMetadata() async throws {
        let hal = AdapterCoverageHAL(
            devices: [
                .fixture(
                    id: 4,
                    uid: "output",
                    name: "Beta Output",
                    inputChannels: 0,
                    outputChannels: 2,
                    rate: 800
                ),
                .fixture(
                    id: 3,
                    uid: "duplex",
                    name: "Alpha Duplex",
                    inputChannels: 3,
                    outputChannels: 2,
                    channelNames: ["Analog 1", "Analog 2", "Loopback"]
                ),
                .fixture(
                    id: 1,
                    uid: "empty",
                    name: "Filtered Device",
                    inputChannels: 0,
                    outputChannels: 0
                ),
                .fixture(
                    id: 2,
                    uid: "input",
                    name: "Zed Input",
                    inputChannels: 1,
                    outputChannels: 0
                ),
            ],
            defaultInputID: 2,
            defaultOutputID: 4
        )
        let preferences = InMemoryAudioDevicePreferences()
        let manager = AudioDeviceManager(
            hal: hal,
            preferences: preferences
        )

        XCTAssertEqual(
            manager.inputDevices.map(\.name),
            [
                "Alpha Duplex", "Zed Input",
            ])
        XCTAssertEqual(
            manager.outputDevices.map(\.name),
            [
                "Alpha Duplex", "Beta Output",
            ])
        XCTAssertEqual(manager.selectedInputDeviceID, 2)
        XCTAssertEqual(manager.selectedOutputDeviceID, 4)
        XCTAssertEqual(manager.selectedInputRoute?.channelMap, [0, 0])
        XCTAssertEqual(manager.availableInputRoutes.count, 1)
        XCTAssertTrue(manager.isInputAvailable)
        XCTAssertTrue(manager.isOutputAvailable)
        XCTAssertEqual(manager.selectedInputDisplayName, "Zed Input")
        XCTAssertEqual(manager.selectedOutputDisplayName, "Beta Output")

        manager.selectedInputDeviceID = 3
        manager.selectedInputRouteID = "not-a-route"
        XCTAssertEqual(manager.selectedInputRoute?.id, "channels-1-2")
        XCTAssertEqual(manager.availableInputRoutes.count, 2)
        try manager.refreshDevices()
        XCTAssertEqual(manager.selectedInputRouteID, "channels-1-2")

        let duplex = try XCTUnwrap(manager.selectedInputDevice)
        XCTAssertEqual(duplex.formatSummary, "3 in / 2 out · 48.0 kHz")
        XCTAssertEqual(duplex.transport, .usb)
        XCTAssertEqual(duplex.bufferFrameRange, 32...1_024)
        XCTAssertEqual(
            duplex.availableSampleRates.map(\.displayName),
            ["44.1 kHz", "48.0 kHz–96.0 kHz"]
        )
        XCTAssertEqual(
            manager.outputDevices.last?.formatSummary,
            "2 out · 800 Hz"
        )
        XCTAssertEqual(
            manager.inputDevices.last?.formatSummary,
            "1 in · 48.0 kHz"
        )
        XCTAssertEqual(
            AudioSampleRateRange(minimum: 800, maximum: 800).displayName,
            "800 Hz"
        )

        manager.selectedInputRouteID = "channels-3-3"
        XCTAssertEqual(
            manager.savedInputRouteID(forDeviceUID: "duplex"),
            "channels-3-3"
        )

        let callsBeforePermissionRequest = hal.devicesCallCount
        manager.requestMicrophonePermission()
        XCTAssertGreaterThan(hal.devicesCallCount, callsBeforePermissionRequest)
        XCTAssertTrue(manager.microphonePermissionGranted)
        XCTAssertFalse(manager.permissionDenied)

        manager.microphonePermissionGranted = false
        let callsBeforeSuppressedRefresh = hal.devicesCallCount
        hal.fireDeviceListObserver()
        await yieldToMainActor()
        XCTAssertEqual(hal.devicesCallCount, callsBeforeSuppressedRefresh)

        manager.microphonePermissionGranted = true
        hal.replaceDevices([])
        hal.fireDeviceListObserver()
        await yieldToMainActor()
        XCTAssertTrue(manager.inputDevices.isEmpty)
        XCTAssertTrue(manager.outputDevices.isEmpty)
    }

    func testSavedDisconnectedSelectionsReconnectAndInvalidRouteFallsBack()
        throws
    {
        let preferences = InMemoryAudioDevicePreferences(values: [
            "selectedInputDeviceUID": "persisted-duplex",
            "selectedInputDeviceName": "Remembered Input",
            "selectedOutputDeviceUID": "persisted-duplex",
            "selectedOutputDeviceName": "Remembered Output",
            "selectedInputRoute.persisted-duplex": "removed-route",
        ])
        let hal = AdapterCoverageHAL(devices: [])
        let manager = AudioDeviceManager(
            hal: hal,
            preferences: preferences
        )

        XCTAssertNil(manager.selectedInputDevice)
        XCTAssertNil(manager.selectedOutputDevice)
        XCTAssertNil(manager.selectedInputRoute)
        XCTAssertTrue(manager.availableInputRoutes.isEmpty)
        XCTAssertEqual(manager.selectedInputDisplayName, "Remembered Input")
        XCTAssertEqual(manager.selectedOutputDisplayName, "Remembered Output")
        XCTAssertFalse(manager.isInputAvailable)
        XCTAssertFalse(manager.isOutputAvailable)

        hal.replaceDevices([
            .fixture(
                id: 55,
                uid: "persisted-duplex",
                name: "Reconnected Interface",
                inputChannels: 4,
                outputChannels: 2
            )
        ])
        try manager.refreshDevices()

        XCTAssertEqual(manager.selectedInputDeviceID, 55)
        XCTAssertEqual(manager.selectedOutputDeviceID, 55)
        XCTAssertEqual(manager.selectedInputRouteID, "channels-1-2")
        XCTAssertEqual(
            manager.selectedInputDisplayName,
            "Reconnected Interface"
        )
        XCTAssertEqual(
            manager.selectedOutputDisplayName,
            "Reconnected Interface"
        )
        XCTAssertTrue(manager.isInputAvailable)
        XCTAssertTrue(manager.isOutputAvailable)

        manager.selectedInputRouteID = "channels-3-4"
        XCTAssertEqual(
            preferences.string(
                forKey: "selectedInputRoute.persisted-duplex"
            ),
            "channels-3-4"
        )

        manager.selectedInputDeviceID = nil
        manager.selectedOutputDeviceID = nil
        XCTAssertTrue(manager.isInputAvailable)
        XCTAssertTrue(manager.isOutputAvailable)
        XCTAssertNil(manager.selectedInputDisplayName)
        XCTAssertNil(manager.selectedOutputDisplayName)
    }

    func testDefaultDeviceFailuresAreWarningsAndSelectionFallsBack() {
        let inputFailure = AdapterCoverageError("Input default unavailable")
        let outputFailure = AdapterCoverageError("Output default unavailable")
        let devices: [CoreAudioHALDevice] = [
            .fixture(
                id: 10,
                uid: "fallback-input",
                name: "Fallback Input",
                inputChannels: 2,
                outputChannels: 0
            ),
            .fixture(
                id: 11,
                uid: "fallback-output",
                name: "Fallback Output",
                inputChannels: 0,
                outputChannels: 2
            ),
        ]

        let bothFail = AdapterCoverageHAL(
            devices: devices,
            defaultInputFailure: inputFailure,
            defaultOutputFailure: outputFailure
        )
        let manager = AudioDeviceManager(
            hal: bothFail,
            preferences: InMemoryAudioDevicePreferences()
        )
        XCTAssertEqual(manager.selectedInputDeviceID, 10)
        XCTAssertEqual(manager.selectedOutputDeviceID, 11)
        XCTAssertEqual(manager.lastDiscoveryError, inputFailure.description)

        let outputOnlyFailure = AdapterCoverageHAL(
            devices: devices,
            defaultInputID: 99_999,
            defaultOutputFailure: outputFailure
        )
        let secondManager = AudioDeviceManager(
            hal: outputOnlyFailure,
            preferences: InMemoryAudioDevicePreferences()
        )
        XCTAssertEqual(secondManager.selectedInputDeviceID, 10)
        XCTAssertEqual(secondManager.selectedOutputDeviceID, 11)
        XCTAssertEqual(
            secondManager.lastDiscoveryError,
            outputFailure.description
        )
    }

    func testListenerRegistrationFailuresAndRefreshCancellationAreTyped()
        throws
    {
        let device = CoreAudioHALDevice.fixture(
            id: 77,
            uid: "listener-device",
            name: "Listener Device",
            inputChannels: 2,
            outputChannels: 2
        )
        let aliveFailure = AdapterCoverageError(
            "Alive listener registration failed"
        )
        let hal = AdapterCoverageHAL(
            devices: [device],
            aliveRegistrationFailures: [device.id: aliveFailure]
        )
        let manager = AudioDeviceManager(
            hal: hal,
            preferences: InMemoryAudioDevicePreferences()
        )

        XCTAssertEqual(manager.lastDiscoveryError, aliveFailure.description)

        hal.clearAliveRegistrationFailures()
        try manager.refreshDevices()
        XCTAssertEqual(hal.aliveListenerCount, 1)
        try manager.refreshDevices()
        XCTAssertGreaterThanOrEqual(hal.listenerCancellationCount, 1)

        let listFailure = AdapterCoverageError(
            "Device list registration failed"
        )
        let discoveryFailure = AdapterCoverageError("Discovery failed")
        let failingHAL = AdapterCoverageHAL(
            devices: [],
            devicesFailure: discoveryFailure,
            deviceListRegistrationFailure: listFailure
        )
        let failingManager = AudioDeviceManager(
            hal: failingHAL,
            preferences: InMemoryAudioDevicePreferences()
        )
        XCTAssertEqual(
            failingManager.lastDiscoveryError,
            discoveryFailure.description
        )
    }

    func testAliveObserverRefreshes() async {
        let device = CoreAudioHALDevice.fixture(
            id: 88,
            uid: "alive-device",
            name: "Alive Device",
            inputChannels: 2,
            outputChannels: 0
        )
        let hal = AdapterCoverageHAL(devices: [device])
        let manager = AudioDeviceManager(
            hal: hal,
            preferences: InMemoryAudioDevicePreferences()
        )
        XCTAssertEqual(manager.inputDevices.count, 1)
        let callCount = hal.devicesCallCount

        hal.fireAliveObserver(deviceID: device.id)
        await yieldToMainActor()
        XCTAssertGreaterThan(hal.devicesCallCount, callCount)
    }

    private func yieldToMainActor() async {
        for _ in 0..<4 {
            await Task.yield()
        }
    }
}

final class ProductionCoreAudioHALInjectedRuntimeTests: XCTestCase {
    private let deviceID = AudioDeviceID(101)
    private let fixtureStatus = OSStatus(-71_001)

    func testDecodesInjectedDeviceGraphAndSkipsUnreadableDevice() throws {
        let runtime = FakeCoreAudioSystemRuntime()
        runtime.setDeviceList([deviceID, 202])
        runtime.setScalar(
            deviceID,
            objectID: runtime.systemObject,
            selector: kAudioHardwarePropertyDefaultInputDevice
        )
        runtime.setScalar(
            kAudioObjectUnknown,
            objectID: runtime.systemObject,
            selector: kAudioHardwarePropertyDefaultOutputDevice
        )
        configureCompleteDevice(runtime, id: deviceID)
        runtime.setReadFailure(
            fixtureStatus,
            objectID: 202,
            selector: kAudioDevicePropertyDeviceUID
        )

        let hal = ProductionCoreAudioHAL(runtime: runtime)
        let devices = try hal.devices()

        XCTAssertEqual(devices.count, 1)
        let device = try XCTUnwrap(devices.first)
        XCTAssertEqual(device.id, deviceID)
        XCTAssertEqual(device.uid, "fixture-101")
        XCTAssertEqual(device.name, "Studio Interface")
        XCTAssertEqual(device.inputChannelCount, 3)
        XCTAssertEqual(device.outputChannelCount, 2)
        XCTAssertEqual(
            device.inputChannelNames,
            ["Mic A", "Input 2", "Input 3"]
        )
        XCTAssertEqual(device.nominalSampleRate, 48_000)
        XCTAssertEqual(
            device.availableSampleRates,
            [
                AudioSampleRateRange(minimum: 44_100, maximum: 44_100),
                AudioSampleRateRange(minimum: 48_000, maximum: 96_000),
            ]
        )
        XCTAssertEqual(device.bufferFrameRange, 32...2_048)
        XCTAssertEqual(device.transport, .usb)
        XCTAssertFalse(device.isAlive)
        XCTAssertEqual(try hal.defaultInputDeviceID(), deviceID)
        XCTAssertNil(try hal.defaultOutputDeviceID())
        XCTAssertEqual(try hal.deviceUID(for: deviceID), "fixture-101")
    }

    func testOptionalFallbacksAndEveryTransportMapping() throws {
        let runtime = FakeCoreAudioSystemRuntime()
        let mappings: [(UInt32?, AudioDeviceTransport)] = [
            (nil, .other),
            (kAudioDeviceTransportTypeBuiltIn, .builtIn),
            (kAudioDeviceTransportTypeUSB, .usb),
            (kAudioDeviceTransportTypeBluetooth, .bluetooth),
            (kAudioDeviceTransportTypeBluetoothLE, .bluetooth),
            (kAudioDeviceTransportTypeHDMI, .hdmi),
            (kAudioDeviceTransportTypeDisplayPort, .displayPort),
            (kAudioDeviceTransportTypeAggregate, .aggregate),
            (kAudioDeviceTransportTypeVirtual, .virtual),
            (0xFFFF_FFFF, .other),
        ]
        let ids = mappings.indices.map { AudioDeviceID(300 + $0) }
        runtime.setDeviceList(ids)

        for (index, mapping) in mappings.enumerated() {
            let id = ids[index]
            configureMinimalDevice(runtime, id: id)
            if let transport = mapping.0 {
                runtime.setScalar(
                    transport,
                    objectID: id,
                    selector: kAudioDevicePropertyTransportType
                )
            }
        }
        runtime.setScalar(
            UInt32.zero,
            objectID: ids[0],
            selector: kAudioDevicePropertyDeviceIsAlive
        )
        runtime.setArray(
            [AudioValueRange](),
            objectID: ids[1],
            selector: kAudioDevicePropertyAvailableNominalSampleRates
        )

        let devices = try ProductionCoreAudioHAL(runtime: runtime).devices()

        XCTAssertEqual(devices.map(\.transport), mappings.map(\.1))
        XCTAssertFalse(devices[0].isAlive)
        XCTAssertTrue(devices[1].isAlive)
        XCTAssertEqual(devices[0].inputChannelCount, 0)
        XCTAssertEqual(devices[0].outputChannelCount, 0)
        XCTAssertTrue(devices[0].inputChannelNames.isEmpty)
        XCTAssertTrue(devices[0].availableSampleRates.isEmpty)
        XCTAssertNil(devices[0].bufferFrameRange)
    }

    func testDeviceListAndDefaultDeviceFailuresAreTyped() throws {
        let sizeFailure = FakeCoreAudioSystemRuntime()
        sizeFailure.setDeviceList([])
        sizeFailure.setSizeFailure(
            fixtureStatus,
            objectID: sizeFailure.systemObject,
            selector: kAudioHardwarePropertyDevices
        )
        assertDevicesFailure(
            sizeFailure,
            operation: "Enumerate Core Audio devices",
            status: fixtureStatus
        )

        let malformedSize = FakeCoreAudioSystemRuntime()
        malformedSize.setPayload(
            .bytes([]),
            objectID: malformedSize.systemObject,
            selector: kAudioHardwarePropertyDevices,
            reportedSize: 3
        )
        assertDevicesFailure(
            malformedSize,
            operation: "Validate Core Audio device-list size",
            status: kAudio_ParamError
        )

        let readFailure = FakeCoreAudioSystemRuntime()
        readFailure.setDeviceList([deviceID])
        readFailure.setReadFailure(
            fixtureStatus,
            objectID: readFailure.systemObject,
            selector: kAudioHardwarePropertyDevices
        )
        assertDevicesFailure(
            readFailure,
            operation: "Read Core Audio device list",
            status: fixtureStatus
        )

        let empty = FakeCoreAudioSystemRuntime()
        empty.setDeviceList([])
        XCTAssertTrue(
            try ProductionCoreAudioHAL(runtime: empty).devices().isEmpty
        )
        XCTAssertEqual(empty.readCount, 0)

        let defaultFailure = FakeCoreAudioSystemRuntime()
        defaultFailure.setReadFailure(
            fixtureStatus,
            objectID: defaultFailure.systemObject,
            selector: kAudioHardwarePropertyDefaultInputDevice
        )
        XCTAssertThrowsError(
            try ProductionCoreAudioHAL(runtime: defaultFailure)
                .defaultInputDeviceID()
        ) { error in
            XCTAssertEqual(
                error as? CoreAudioHALError,
                CoreAudioHALError(
                    operation: "Read Core Audio default device",
                    status: self.fixtureStatus
                )
            )
        }

        let wrongScalarSize = FakeCoreAudioSystemRuntime()
        wrongScalarSize.setScalar(
            deviceID,
            objectID: wrongScalarSize.systemObject,
            selector: kAudioHardwarePropertyDefaultOutputDevice,
            returnedSize: 1
        )
        XCTAssertThrowsError(
            try ProductionCoreAudioHAL(runtime: wrongScalarSize)
                .defaultOutputDeviceID()
        ) { error in
            XCTAssertEqual(
                error as? CoreAudioHALError,
                CoreAudioHALError(
                    operation:
                        "Validate read core audio default device size",
                    status: kAudio_ParamError
                )
            )
        }
    }

    func testVariableLengthReadsHonorReturnedByteCounts() throws {
        let runtime = FakeCoreAudioSystemRuntime()
        let ids = [deviceID, AudioDeviceID(202)]
        let idBytes = ids.withUnsafeBytes { Array($0) }
        runtime.setPayload(
            .bytes(idBytes),
            objectID: runtime.systemObject,
            selector: kAudioHardwarePropertyDevices,
            reportedSize: UInt32(idBytes.count),
            returnedSize: UInt32(MemoryLayout<AudioDeviceID>.stride)
        )
        configureMinimalDevice(runtime, id: deviceID)

        let ranges = [
            AudioValueRange(mMinimum: 44_100, mMaximum: 44_100),
            AudioValueRange(mMinimum: 48_000, mMaximum: 96_000),
        ]
        let rangeBytes = ranges.withUnsafeBytes { Array($0) }
        runtime.setPayload(
            .bytes(rangeBytes),
            objectID: deviceID,
            selector: kAudioDevicePropertyAvailableNominalSampleRates,
            reportedSize: UInt32(rangeBytes.count),
            returnedSize: UInt32(MemoryLayout<AudioValueRange>.stride)
        )

        let devices = try ProductionCoreAudioHAL(runtime: runtime).devices()

        XCTAssertEqual(devices.map(\.id), [deviceID])
        XCTAssertEqual(
            devices[0].availableSampleRates,
            [AudioSampleRateRange(minimum: 44_100, maximum: 44_100)]
        )
    }

    func testStreamAndSampleRateFailuresAreTyped() {
        let streamSizeFailure = baseRuntime()
        streamSizeFailure.setStreamChannels(
            [2],
            objectID: deviceID,
            scope: kAudioDevicePropertyScopeInput
        )
        streamSizeFailure.setSizeFailure(
            fixtureStatus,
            objectID: deviceID,
            selector: kAudioDevicePropertyStreamConfiguration,
            scope: kAudioDevicePropertyScopeInput
        )
        assertDevicesFailure(
            streamSizeFailure,
            operation: "Read Core Audio stream-configuration size",
            status: fixtureStatus
        )

        let shortStream = baseRuntime()
        shortStream.setPayload(
            .streamChannels([]),
            objectID: deviceID,
            selector: kAudioDevicePropertyStreamConfiguration,
            scope: kAudioDevicePropertyScopeInput,
            reportedSize: 1
        )
        assertDevicesFailure(
            shortStream,
            operation: "Validate Core Audio stream configuration",
            status: kAudio_ParamError
        )

        let streamReadFailure = baseRuntime()
        streamReadFailure.setStreamChannels(
            [2],
            objectID: deviceID,
            scope: kAudioDevicePropertyScopeInput
        )
        streamReadFailure.setReadFailure(
            fixtureStatus,
            objectID: deviceID,
            selector: kAudioDevicePropertyStreamConfiguration,
            scope: kAudioDevicePropertyScopeInput
        )
        assertDevicesFailure(
            streamReadFailure,
            operation: "Read Core Audio stream configuration",
            status: fixtureStatus
        )

        let sampleSizeFailure = baseRuntime()
        sampleSizeFailure.setArray(
            [AudioValueRange(mMinimum: 44_100, mMaximum: 48_000)],
            objectID: deviceID,
            selector: kAudioDevicePropertyAvailableNominalSampleRates
        )
        sampleSizeFailure.setSizeFailure(
            fixtureStatus,
            objectID: deviceID,
            selector: kAudioDevicePropertyAvailableNominalSampleRates
        )
        assertDevicesFailure(
            sampleSizeFailure,
            operation: "Read Core Audio sample-rate-list size",
            status: fixtureStatus
        )

        let malformedSamples = baseRuntime()
        malformedSamples.setPayload(
            .bytes([]),
            objectID: deviceID,
            selector: kAudioDevicePropertyAvailableNominalSampleRates,
            reportedSize: 1
        )
        assertDevicesFailure(
            malformedSamples,
            operation: "Validate Core Audio sample-rate-list size",
            status: kAudio_ParamError
        )

        let sampleReadFailure = baseRuntime()
        sampleReadFailure.setArray(
            [AudioValueRange(mMinimum: 44_100, mMaximum: 48_000)],
            objectID: deviceID,
            selector: kAudioDevicePropertyAvailableNominalSampleRates
        )
        sampleReadFailure.setReadFailure(
            fixtureStatus,
            objectID: deviceID,
            selector: kAudioDevicePropertyAvailableNominalSampleRates
        )
        assertDevicesFailure(
            sampleReadFailure,
            operation: "Read Core Audio available sample rates",
            status: fixtureStatus
        )
    }

    func testStreamConfigurationRejectsTruncatedAndOversizedLayouts() {
        let bufferOffset =
            MemoryLayout<AudioBufferList>.offset(of: \.mBuffers)
            ?? MemoryLayout<UInt32>.size

        let truncated = baseRuntime()
        truncated.setPayload(
            .streamChannels([2]),
            objectID: deviceID,
            selector: kAudioDevicePropertyStreamConfiguration,
            scope: kAudioDevicePropertyScopeInput,
            returnedSize: UInt32(bufferOffset)
        )
        assertDevicesFailure(
            truncated,
            operation: "Validate Core Audio stream configuration",
            status: kAudio_ParamError
        )

        let oversizedCount = baseRuntime()
        var impossibleBufferCount = UInt32.max
        let header = withUnsafeBytes(of: &impossibleBufferCount) { Array($0) }
        oversizedCount.setPayload(
            .bytes(header),
            objectID: deviceID,
            selector: kAudioDevicePropertyStreamConfiguration,
            scope: kAudioDevicePropertyScopeInput,
            reportedSize: UInt32(MemoryLayout<AudioBufferList>.size),
            returnedSize: UInt32(MemoryLayout<AudioBufferList>.size)
        )
        assertDevicesFailure(
            oversizedCount,
            operation: "Validate Core Audio stream configuration",
            status: kAudio_ParamError
        )
    }

    func testStringScalarAndBufferRangeValidationFailuresAreTyped() {
        let nilUID = baseRuntime()
        nilUID.setString(
            nil,
            objectID: deviceID,
            selector: kAudioDevicePropertyDeviceUID
        )
        assertDevicesFailure(
            nilUID,
            operation: "Read Core Audio device UID",
            status: kAudio_ParamError
        )

        let wrongRateSize = baseRuntime()
        wrongRateSize.setScalar(
            48_000.0,
            objectID: deviceID,
            selector: kAudioDevicePropertyNominalSampleRate,
            returnedSize: 1
        )
        assertDevicesFailure(
            wrongRateSize,
            operation:
                "Validate read core audio nominal sample rate size",
            status: kAudio_ParamError
        )

        for range in [
            AudioValueRange(mMinimum: -1, mMaximum: 128),
            AudioValueRange(mMinimum: 512, mMaximum: 128),
            AudioValueRange(
                mMinimum: 1,
                mMaximum: Double(UInt32.max) + 1
            ),
        ] {
            let runtime = baseRuntime()
            runtime.setScalar(
                range,
                objectID: deviceID,
                selector: kAudioDevicePropertyBufferFrameSizeRange
            )
            assertDevicesFailure(
                runtime,
                operation: "Validate Core Audio buffer-frame range",
                status: kAudio_ParamError
            )
        }

        let firstFailure = FakeCoreAudioSystemRuntime()
        firstFailure.setDeviceList([1, 2])
        firstFailure.setReadFailure(
            fixtureStatus,
            objectID: 1,
            selector: kAudioDevicePropertyDeviceUID
        )
        firstFailure.setReadFailure(
            fixtureStatus - 1,
            objectID: 2,
            selector: kAudioDevicePropertyDeviceUID
        )
        assertDevicesFailure(
            firstFailure,
            operation: "Read Core Audio device UID",
            status: fixtureStatus
        )
    }

    func testListenerRegistrationCallbackAndCancellationAreInjected()
        throws
    {
        let runtime = FakeCoreAudioSystemRuntime()
        let hal = ProductionCoreAudioHAL(runtime: runtime)
        let listCallbacks = AdapterCoverageCounter()
        let listCallback = expectation(description: "Device-list callback")
        let listToken = try hal.observeDeviceList {
            listCallbacks.increment()
            listCallback.fulfill()
        }

        let listAdd = try XCTUnwrap(runtime.listenerAdds.first)
        XCTAssertEqual(listAdd.key.objectID, runtime.systemObject)
        XCTAssertEqual(
            listAdd.key.selector,
            kAudioHardwarePropertyDevices
        )
        XCTAssertEqual(
            listAdd.queueLabel,
            "com.phonoflow.coreaudio.device-listeners"
        )
        XCTAssertTrue(runtime.fireListener(at: 0))
        wait(for: [listCallback], timeout: 1)
        XCTAssertEqual(listCallbacks.value, 1)

        listToken.cancel()
        listToken.cancel()
        XCTAssertEqual(runtime.listenerRemoves.count, 1)
        XCTAssertEqual(runtime.activeListenerCount, 0)
        XCTAssertFalse(runtime.fireListener(at: 0))
        let listRemove = try XCTUnwrap(runtime.listenerRemoves.first)
        XCTAssertTrue(listAdd.registration === listRemove.registration)
        XCTAssertTrue(listAdd.queue === listRemove.queue)
        XCTAssertEqual(listAdd.key, listRemove.key)

        let aliveCallbacks = AdapterCoverageCounter()
        let aliveCallback = expectation(description: "Device-alive callback")
        let aliveToken = try hal.observeAlive(deviceID: deviceID) {
            aliveCallbacks.increment()
            aliveCallback.fulfill()
        }
        let aliveAdd = try XCTUnwrap(runtime.listenerAdds.last)
        XCTAssertEqual(aliveAdd.key.objectID, deviceID)
        XCTAssertEqual(
            aliveAdd.key.selector,
            kAudioDevicePropertyDeviceIsAlive
        )
        XCTAssertTrue(runtime.fireListener(at: 1))
        wait(for: [aliveCallback], timeout: 1)
        XCTAssertEqual(aliveCallbacks.value, 1)
        aliveToken.cancel()
        XCTAssertEqual(runtime.listenerRemoves.count, 2)
        XCTAssertEqual(runtime.activeListenerCount, 0)
        XCTAssertFalse(runtime.fireListener(at: 1))

        let failingRuntime = FakeCoreAudioSystemRuntime()
        failingRuntime.listenerAddStatus = fixtureStatus
        let failingHAL = ProductionCoreAudioHAL(runtime: failingRuntime)
        XCTAssertThrowsError(try failingHAL.observeDeviceList {}) { error in
            XCTAssertEqual(
                error as? CoreAudioHALError,
                CoreAudioHALError(
                    operation:
                        "Register Core Audio device-list listener",
                    status: self.fixtureStatus
                )
            )
        }
        XCTAssertThrowsError(
            try failingHAL.observeAlive(deviceID: deviceID) {}
        ) { error in
            XCTAssertEqual(
                error as? CoreAudioHALError,
                CoreAudioHALError(
                    operation:
                        "Register Core Audio device-alive listener",
                    status: self.fixtureStatus
                )
            )
        }
        XCTAssertTrue(failingRuntime.listenerRemoves.isEmpty)

        let removeFailure = FakeCoreAudioSystemRuntime()
        removeFailure.listenerRemoveStatus = fixtureStatus
        let failureToken = try ProductionCoreAudioHAL(
            runtime: removeFailure
        ).observeDeviceList {}
        failureToken.cancel()
        XCTAssertEqual(removeFailure.listenerRemoves.count, 1)
        XCTAssertEqual(removeFailure.activeListenerCount, 1)
        removeFailure.listenerRemoveStatus = noErr
        failureToken.cancel()
        failureToken.cancel()
        XCTAssertEqual(removeFailure.listenerRemoves.count, 2)
        XCTAssertEqual(removeFailure.activeListenerCount, 0)
    }

    func testInjectedRuntimeRequiresExactListenerRemovalTuple() throws {
        let runtime = FakeCoreAudioSystemRuntime()
        let queue = DispatchQueue(label: "com.phonoflow.tests.listener")
        let queueKey = DispatchSpecificKey<Bool>()
        queue.setSpecific(key: queueKey, value: true)
        let callback = expectation(description: "Injected listener callback")
        let matchingQueueCallbacks = AdapterCoverageCounter()
        let registration = CoreAudioListenerRegistration { _, _ in
            if DispatchQueue.getSpecific(key: queueKey) == true {
                matchingQueueCallbacks.increment()
            }
            callback.fulfill()
        }
        let otherRegistration = CoreAudioListenerRegistration { _, _ in }
        let otherQueue = DispatchQueue(
            label: "com.phonoflow.tests.listener"
        )
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        XCTAssertEqual(
            runtime.addPropertyListener(
                objectID: runtime.systemObject,
                address: &address,
                queue: queue,
                registration: registration
            ),
            noErr
        )
        XCTAssertEqual(runtime.activeListenerCount, 1)

        XCTAssertEqual(
            runtime.removePropertyListener(
                objectID: runtime.systemObject,
                address: &address,
                queue: otherQueue,
                registration: registration
            ),
            kAudioHardwareIllegalOperationError
        )
        XCTAssertEqual(
            runtime.removePropertyListener(
                objectID: runtime.systemObject,
                address: &address,
                queue: queue,
                registration: otherRegistration
            ),
            kAudioHardwareIllegalOperationError
        )
        XCTAssertEqual(runtime.activeListenerCount, 1)
        XCTAssertTrue(runtime.fireListener(at: 0))
        wait(for: [callback], timeout: 1)
        XCTAssertEqual(matchingQueueCallbacks.value, 1)

        XCTAssertEqual(
            runtime.removePropertyListener(
                objectID: runtime.systemObject,
                address: &address,
                queue: queue,
                registration: registration
            ),
            noErr
        )
        XCTAssertEqual(runtime.activeListenerCount, 0)
        XCTAssertFalse(runtime.fireListener(at: 0))
    }

    private func baseRuntime() -> FakeCoreAudioSystemRuntime {
        let runtime = FakeCoreAudioSystemRuntime()
        runtime.setDeviceList([deviceID])
        configureMinimalDevice(runtime, id: deviceID)
        return runtime
    }

    private func configureCompleteDevice(
        _ runtime: FakeCoreAudioSystemRuntime,
        id: AudioDeviceID
    ) {
        runtime.setStreamChannels(
            [1, 2],
            objectID: id,
            scope: kAudioDevicePropertyScopeInput
        )
        runtime.setStreamChannels(
            [2],
            objectID: id,
            scope: kAudioDevicePropertyScopeOutput
        )
        runtime.setString(
            "fixture-101",
            objectID: id,
            selector: kAudioDevicePropertyDeviceUID
        )
        runtime.setString(
            "Studio Interface",
            objectID: id,
            selector: kAudioObjectPropertyName
        )
        runtime.setString(
            "Mic A",
            objectID: id,
            selector: kAudioObjectPropertyElementName,
            scope: kAudioDevicePropertyScopeInput,
            element: 1
        )
        runtime.setReadFailure(
            fixtureStatus,
            objectID: id,
            selector: kAudioObjectPropertyElementName,
            scope: kAudioDevicePropertyScopeInput,
            element: 2
        )
        runtime.setScalar(
            48_000.0,
            objectID: id,
            selector: kAudioDevicePropertyNominalSampleRate
        )
        runtime.setArray(
            [
                AudioValueRange(mMinimum: 44_100, mMaximum: 44_100),
                AudioValueRange(mMinimum: 48_000, mMaximum: 96_000),
            ],
            objectID: id,
            selector: kAudioDevicePropertyAvailableNominalSampleRates
        )
        runtime.setScalar(
            AudioValueRange(mMinimum: 32, mMaximum: 2_048),
            objectID: id,
            selector: kAudioDevicePropertyBufferFrameSizeRange
        )
        runtime.setScalar(
            kAudioDeviceTransportTypeUSB,
            objectID: id,
            selector: kAudioDevicePropertyTransportType
        )
        runtime.setScalar(
            UInt32.zero,
            objectID: id,
            selector: kAudioDevicePropertyDeviceIsAlive
        )
    }

    private func configureMinimalDevice(
        _ runtime: FakeCoreAudioSystemRuntime,
        id: AudioDeviceID
    ) {
        runtime.setString(
            "fixture-\(id)",
            objectID: id,
            selector: kAudioDevicePropertyDeviceUID
        )
        runtime.setString(
            "Device \(id)",
            objectID: id,
            selector: kAudioObjectPropertyName
        )
        runtime.setScalar(
            48_000.0,
            objectID: id,
            selector: kAudioDevicePropertyNominalSampleRate
        )
    }

    private func assertDevicesFailure(
        _ runtime: FakeCoreAudioSystemRuntime,
        operation: String,
        status: OSStatus,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try ProductionCoreAudioHAL(runtime: runtime).devices(),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(
                error as? CoreAudioHALError,
                CoreAudioHALError(operation: operation, status: status),
                file: file,
                line: line
            )
        }
    }
}

final class CoreAudioAdapterValueCoverageTests: XCTestCase {
    func testTypedErrorFormatsPrintableAndNumericStatuses() {
        let printableStatus = OSStatus(bitPattern: 0x7465_7374)
        let printable = CoreAudioHALError(
            operation: "Read fixture",
            status: printableStatus
        )
        XCTAssertEqual(
            printable.errorDescription,
            "Read fixture failed (test, \(printableStatus))."
        )

        let numeric = CoreAudioHALError(
            operation: "Read fixture",
            status: -1
        )
        XCTAssertEqual(
            numeric.errorDescription,
            "Read fixture failed (OSStatus -1)."
        )
    }

    func testUserDefaultsPreferenceAdapterUsesOnlyItsInjectedSuite() throws {
        let suiteName = "com.phonoflow.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = UserDefaultsAudioDevicePreferences(
            defaults: defaults
        )

        XCTAssertNil(preferences.string(forKey: "route"))
        preferences.set("channels-3-4", forKey: "route")
        XCTAssertEqual(
            preferences.string(forKey: "route"),
            "channels-3-4"
        )
        preferences.removeObject(forKey: "route")
        XCTAssertNil(preferences.string(forKey: "route"))
    }
}

private struct FakeCoreAudioPropertyKey: Hashable, Sendable {
    let objectID: AudioObjectID
    let selector: AudioObjectPropertySelector
    let scope: AudioObjectPropertyScope
    let element: AudioObjectPropertyElement

    init(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement
    ) {
        self.objectID = objectID
        self.selector = selector
        self.scope = scope
        self.element = element
    }

    init(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress
    ) {
        self.init(
            objectID: objectID,
            selector: address.mSelector,
            scope: address.mScope,
            element: address.mElement
        )
    }

    var address: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: element
        )
    }
}

private enum FakeCoreAudioPayload {
    case bytes([UInt8])
    case string(CFString?)
    case streamChannels([UInt32])

    var size: UInt32 {
        switch self {
        case .bytes(let bytes):
            return UInt32(bytes.count)
        case .string:
            return UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        case .streamChannels(let channels):
            let bufferOffset =
                MemoryLayout<AudioBufferList>.offset(of: \.mBuffers) ?? 0
            return UInt32(
                bufferOffset
                    + max(channels.count, 1)
                    * MemoryLayout<AudioBuffer>.stride
            )
        }
    }
}

private struct FakeCoreAudioPropertyStub {
    var payload: FakeCoreAudioPayload
    var sizeStatus: OSStatus = noErr
    var reportedSize: UInt32?
    var readStatus: OSStatus = noErr
    var returnedSize: UInt32?
}

private struct FakeCoreAudioListenerCall: @unchecked Sendable {
    let key: FakeCoreAudioPropertyKey
    let queue: DispatchQueue
    let registration: CoreAudioListenerRegistration

    var queueLabel: String { queue.label }
}

private final class FakeCoreAudioSystemRuntime:
    CoreAudioSystemRuntime,
    @unchecked Sendable
{
    let systemObject = AudioObjectID(kAudioObjectSystemObject)

    private let lock = NSLock()
    private var stubs:
        [FakeCoreAudioPropertyKey:
            FakeCoreAudioPropertyStub] = [:]
    private var additions: [FakeCoreAudioListenerCall] = []
    private var activeListeners: [FakeCoreAudioListenerCall] = []
    private var removals: [FakeCoreAudioListenerCall] = []
    private var reads = 0
    private var addStatus: OSStatus = noErr
    private var removeStatus: OSStatus = noErr

    var readCount: Int {
        lock.withLock { reads }
    }

    var listenerAdds: [FakeCoreAudioListenerCall] {
        lock.withLock { additions }
    }

    var listenerRemoves: [FakeCoreAudioListenerCall] {
        lock.withLock { removals }
    }

    var activeListenerCount: Int {
        lock.withLock { activeListeners.count }
    }

    var listenerAddStatus: OSStatus {
        get { lock.withLock { addStatus } }
        set { lock.withLock { addStatus = newValue } }
    }

    var listenerRemoveStatus: OSStatus {
        get { lock.withLock { removeStatus } }
        set { lock.withLock { removeStatus = newValue } }
    }

    func setDeviceList(_ ids: [AudioDeviceID]) {
        setArray(
            ids,
            objectID: systemObject,
            selector: kAudioHardwarePropertyDevices
        )
    }

    func setScalar<Value: BitwiseCopyable>(
        _ value: Value,
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope =
            kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement =
            kAudioObjectPropertyElementMain,
        returnedSize: UInt32? = nil
    ) {
        let bytes = withUnsafeBytes(of: value) { Array($0) }
        setPayload(
            .bytes(bytes),
            objectID: objectID,
            selector: selector,
            scope: scope,
            element: element,
            returnedSize: returnedSize
        )
    }

    func setArray<Value: BitwiseCopyable>(
        _ values: [Value],
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope =
            kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement =
            kAudioObjectPropertyElementMain
    ) {
        let bytes = values.withUnsafeBytes { Array($0) }
        setPayload(
            .bytes(bytes),
            objectID: objectID,
            selector: selector,
            scope: scope,
            element: element
        )
    }

    func setString(
        _ value: String?,
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope =
            kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement =
            kAudioObjectPropertyElementMain
    ) {
        setPayload(
            .string(value.map { $0 as CFString }),
            objectID: objectID,
            selector: selector,
            scope: scope,
            element: element
        )
    }

    func setStreamChannels(
        _ channels: [UInt32],
        objectID: AudioObjectID,
        scope: AudioObjectPropertyScope
    ) {
        setPayload(
            .streamChannels(channels),
            objectID: objectID,
            selector: kAudioDevicePropertyStreamConfiguration,
            scope: scope
        )
    }

    func setPayload(
        _ payload: FakeCoreAudioPayload,
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope =
            kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement =
            kAudioObjectPropertyElementMain,
        reportedSize: UInt32? = nil,
        returnedSize: UInt32? = nil
    ) {
        let key = FakeCoreAudioPropertyKey(
            objectID: objectID,
            selector: selector,
            scope: scope,
            element: element
        )
        lock.withLock {
            stubs[key] = FakeCoreAudioPropertyStub(
                payload: payload,
                reportedSize: reportedSize,
                returnedSize: returnedSize
            )
        }
    }

    func setSizeFailure(
        _ status: OSStatus,
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope =
            kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement =
            kAudioObjectPropertyElementMain
    ) {
        mutateStub(
            objectID: objectID,
            selector: selector,
            scope: scope,
            element: element
        ) {
            $0.sizeStatus = status
        }
    }

    func setReadFailure(
        _ status: OSStatus,
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope =
            kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement =
            kAudioObjectPropertyElementMain
    ) {
        mutateStub(
            objectID: objectID,
            selector: selector,
            scope: scope,
            element: element
        ) {
            $0.readStatus = status
        }
    }

    func hasProperty(
        objectID: AudioObjectID,
        address: UnsafePointer<AudioObjectPropertyAddress>
    ) -> Bool {
        let key = FakeCoreAudioPropertyKey(
            objectID: objectID,
            address: address.pointee
        )
        return lock.withLock { stubs[key] != nil }
    }

    func getPropertyDataSize(
        objectID: AudioObjectID,
        address: UnsafePointer<AudioObjectPropertyAddress>,
        qualifierDataSize: UInt32,
        qualifierData: UnsafeRawPointer?,
        dataSize: UnsafeMutablePointer<UInt32>
    ) -> OSStatus {
        _ = qualifierDataSize
        _ = qualifierData
        let key = FakeCoreAudioPropertyKey(
            objectID: objectID,
            address: address.pointee
        )
        guard let stub = lock.withLock({ stubs[key] }) else {
            return kAudioHardwareUnknownPropertyError
        }
        guard stub.sizeStatus == noErr else {
            return stub.sizeStatus
        }
        dataSize.pointee = stub.reportedSize ?? stub.payload.size
        return noErr
    }

    func getPropertyData(
        objectID: AudioObjectID,
        address: UnsafePointer<AudioObjectPropertyAddress>,
        qualifierDataSize: UInt32,
        qualifierData: UnsafeRawPointer?,
        dataSize: UnsafeMutablePointer<UInt32>,
        data: UnsafeMutableRawPointer
    ) -> OSStatus {
        _ = qualifierDataSize
        _ = qualifierData
        let key = FakeCoreAudioPropertyKey(
            objectID: objectID,
            address: address.pointee
        )
        let stub = lock.withLock { () -> FakeCoreAudioPropertyStub? in
            reads += 1
            return stubs[key]
        }
        guard let stub else {
            return kAudioHardwareUnknownPropertyError
        }
        guard stub.readStatus == noErr else {
            return stub.readStatus
        }

        let capacity = Int(dataSize.pointee)
        switch stub.payload {
        case .bytes(let bytes):
            guard capacity >= bytes.count else {
                return kAudio_ParamError
            }
            bytes.withUnsafeBytes { source in
                guard let baseAddress = source.baseAddress else { return }
                data.copyMemory(
                    from: baseAddress,
                    byteCount: source.count
                )
            }
        case .string(let value):
            let required =
                MemoryLayout<Unmanaged<CFString>?>.size
            guard capacity >= required else {
                return kAudio_ParamError
            }
            // Core Audio's CFString-valued object properties are returned
            // retained; mirror that ownership contract so production consumes
            // the +1 reference with takeRetainedValue().
            let unmanaged = value.map { Unmanaged.passRetained($0) }
            data.assumingMemoryBound(
                to: Optional<Unmanaged<CFString>>.self
            ).pointee = unmanaged
        case .streamChannels(let channels):
            guard capacity >= Int(stub.payload.size) else {
                return kAudio_ParamError
            }
            let list = data.assumingMemoryBound(
                to: AudioBufferList.self
            )
            list.pointee.mNumberBuffers = UInt32(channels.count)
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            for (index, channelCount) in channels.enumerated() {
                buffers[index] = AudioBuffer(
                    mNumberChannels: channelCount,
                    mDataByteSize: 0,
                    mData: nil
                )
            }
        }
        dataSize.pointee = stub.returnedSize ?? stub.payload.size
        return noErr
    }

    func addPropertyListener(
        objectID: AudioObjectID,
        address: UnsafePointer<AudioObjectPropertyAddress>,
        queue: DispatchQueue,
        registration: CoreAudioListenerRegistration
    ) -> OSStatus {
        let key = FakeCoreAudioPropertyKey(
            objectID: objectID,
            address: address.pointee
        )
        return lock.withLock {
            guard addStatus == noErr else { return addStatus }
            additions.append(
                FakeCoreAudioListenerCall(
                    key: key,
                    queue: queue,
                    registration: registration
                )
            )
            activeListeners.append(additions[additions.count - 1])
            return noErr
        }
    }

    func removePropertyListener(
        objectID: AudioObjectID,
        address: UnsafePointer<AudioObjectPropertyAddress>,
        queue: DispatchQueue,
        registration: CoreAudioListenerRegistration
    ) -> OSStatus {
        let key = FakeCoreAudioPropertyKey(
            objectID: objectID,
            address: address.pointee
        )
        return lock.withLock {
            let removal = FakeCoreAudioListenerCall(
                key: key,
                queue: queue,
                registration: registration
            )
            removals.append(removal)
            guard removeStatus == noErr else { return removeStatus }
            guard
                let index = activeListeners.firstIndex(where: {
                    $0.key == key
                        && $0.queue === queue
                        && $0.registration === registration
                })
            else {
                return kAudioHardwareIllegalOperationError
            }
            activeListeners.remove(at: index)
            return noErr
        }
    }

    @discardableResult
    func fireListener(at index: Int) -> Bool {
        let call = lock.withLock { () -> FakeCoreAudioListenerCall? in
            let call = additions[index]
            return activeListeners.contains {
                $0.key == call.key
                    && $0.queue === call.queue
                    && $0.registration === call.registration
            } ? call : nil
        }
        guard let call else { return false }
        call.queue.async {
            var address = call.key.address
            withUnsafePointer(to: &address) { pointer in
                call.registration.block(1, pointer)
            }
        }
        return true
    }

    private func mutateStub(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement,
        _ mutation: (inout FakeCoreAudioPropertyStub) -> Void
    ) {
        let key = FakeCoreAudioPropertyKey(
            objectID: objectID,
            selector: selector,
            scope: scope,
            element: element
        )
        lock.withLock {
            var stub =
                stubs[key]
                ?? FakeCoreAudioPropertyStub(payload: .bytes([]))
            mutation(&stub)
            stubs[key] = stub
        }
    }
}

private final class AdapterCoverageCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock {
            count += 1
        }
    }
}

private struct AdapterCoverageError:
    LocalizedError,
    Sendable,
    CustomStringConvertible
{
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
    var description: String { message }
}

private final class AdapterCoverageHAL: CoreAudioHAL, @unchecked Sendable {
    private let lock = NSLock()
    private var currentDevices: [CoreAudioHALDevice]
    private let defaultInputID: AudioDeviceID?
    private let defaultOutputID: AudioDeviceID?
    private let defaultInputFailure: AdapterCoverageError?
    private let defaultOutputFailure: AdapterCoverageError?
    private let devicesFailure: AdapterCoverageError?
    private let deviceListRegistrationFailure: AdapterCoverageError?
    private var aliveRegistrationFailures: [AudioDeviceID: AdapterCoverageError]
    private var deviceListObserver: (@Sendable () -> Void)?
    private var aliveObservers: [AudioDeviceID: @Sendable () -> Void] = [:]
    private var deviceCalls = 0
    private var cancellations = 0

    let bypassesMicrophonePermission: Bool

    init(
        devices: [CoreAudioHALDevice],
        defaultInputID: AudioDeviceID? = nil,
        defaultOutputID: AudioDeviceID? = nil,
        defaultInputFailure: AdapterCoverageError? = nil,
        defaultOutputFailure: AdapterCoverageError? = nil,
        devicesFailure: AdapterCoverageError? = nil,
        deviceListRegistrationFailure: AdapterCoverageError? = nil,
        aliveRegistrationFailures:
            [AudioDeviceID: AdapterCoverageError] = [:],
        bypassesMicrophonePermission: Bool = true
    ) {
        currentDevices = devices
        self.defaultInputID = defaultInputID
        self.defaultOutputID = defaultOutputID
        self.defaultInputFailure = defaultInputFailure
        self.defaultOutputFailure = defaultOutputFailure
        self.devicesFailure = devicesFailure
        self.deviceListRegistrationFailure =
            deviceListRegistrationFailure
        self.aliveRegistrationFailures = aliveRegistrationFailures
        self.bypassesMicrophonePermission = bypassesMicrophonePermission
    }

    var devicesCallCount: Int {
        lock.withLock { deviceCalls }
    }

    var aliveListenerCount: Int {
        lock.withLock { aliveObservers.count }
    }

    var listenerCancellationCount: Int {
        lock.withLock { cancellations }
    }

    func devices() throws -> [CoreAudioHALDevice] {
        try lock.withLock {
            deviceCalls += 1
            if let devicesFailure {
                throw devicesFailure
            }
            return currentDevices
        }
    }

    func defaultInputDeviceID() throws -> AudioDeviceID? {
        if let defaultInputFailure {
            throw defaultInputFailure
        }
        return defaultInputID
    }

    func defaultOutputDeviceID() throws -> AudioDeviceID? {
        if let defaultOutputFailure {
            throw defaultOutputFailure
        }
        return defaultOutputID
    }

    func observeDeviceList(
        _ observer: @escaping @Sendable () -> Void
    ) throws -> any CoreAudioHALListener {
        if let deviceListRegistrationFailure {
            throw deviceListRegistrationFailure
        }
        lock.withLock {
            deviceListObserver = observer
        }
        return AdapterCoverageListener { [weak self] in
            self?.lock.withLock {
                self?.deviceListObserver = nil
                self?.cancellations += 1
            }
        }
    }

    func observeAlive(
        deviceID: AudioDeviceID,
        _ observer: @escaping @Sendable () -> Void
    ) throws -> any CoreAudioHALListener {
        if let failure = lock.withLock({
            aliveRegistrationFailures[deviceID]
        }) {
            throw failure
        }
        lock.withLock {
            aliveObservers[deviceID] = observer
        }
        return AdapterCoverageListener { [weak self] in
            self?.lock.withLock {
                self?.aliveObservers.removeValue(forKey: deviceID)
                self?.cancellations += 1
            }
        }
    }

    func replaceDevices(_ devices: [CoreAudioHALDevice]) {
        lock.withLock {
            currentDevices = devices
        }
    }

    func clearAliveRegistrationFailures() {
        lock.withLock {
            aliveRegistrationFailures.removeAll()
        }
    }

    func fireDeviceListObserver() {
        let observer = lock.withLock { deviceListObserver }
        observer?()
    }

    func fireAliveObserver(deviceID: AudioDeviceID) {
        let observer = lock.withLock { aliveObservers[deviceID] }
        observer?()
    }
}

private final class AdapterCoverageListener:
    CoreAudioHALListener,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var cancellation: (@Sendable () -> Void)?

    init(_ cancellation: @escaping @Sendable () -> Void) {
        self.cancellation = cancellation
    }

    deinit {
        cancel()
    }

    func cancel() {
        let action = lock.withLock {
            let action = cancellation
            cancellation = nil
            return action
        }
        action?()
    }
}

extension CoreAudioHALDevice {
    fileprivate static func fixture(
        id: AudioDeviceID,
        uid: String,
        name: String,
        inputChannels: Int,
        outputChannels: Int,
        channelNames: [String] = [],
        rate: Double = 48_000
    ) -> Self {
        CoreAudioHALDevice(
            id: id,
            uid: uid,
            name: name,
            inputChannelCount: inputChannels,
            outputChannelCount: outputChannels,
            inputChannelNames: channelNames,
            nominalSampleRate: rate,
            availableSampleRates: [
                AudioSampleRateRange(minimum: 44_100, maximum: 44_100),
                AudioSampleRateRange(minimum: 48_000, maximum: 96_000),
            ],
            bufferFrameRange: 32...1_024,
            transport: .usb,
            isAlive: true
        )
    }
}
