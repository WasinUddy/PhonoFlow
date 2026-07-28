import CoreAudio
import Foundation
import XCTest

@testable import PhonoFlow

@MainActor
final class AudioDeviceManagerTests: XCTestCase {
    func testFakeFourInputDeviceDiscoversAnalogAndLoopbackPairs() throws {
        let hal = FakeCoreAudioHAL()
        let manager = AudioDeviceManager(
            hal: hal,
            preferences: InMemoryAudioDevicePreferences()
        )

        XCTAssertTrue(manager.microphonePermissionGranted)
        XCTAssertFalse(manager.permissionDenied)
        XCTAssertEqual(manager.inputDevices.count, 1)
        XCTAssertEqual(manager.outputDevices.count, 1)
        let input = try XCTUnwrap(manager.selectedInputDevice)
        XCTAssertEqual(input.transport, .usb)
        XCTAssertEqual(input.inputChannelCount, 4)
        XCTAssertEqual(
            input.inputRoutes.map(\.id),
            ["channels-1-2", "channels-3-4"]
        )
        XCTAssertEqual(input.inputRoutes[0].channelMap, [0, 1])
        XCTAssertEqual(input.inputRoutes[1].channelMap, [2, 3])
        XCTAssertEqual(manager.selectedInputRouteID, "channels-1-2")
    }

    func testSelectionAndRoutePersistByStableUIDAcrossChangedCoreAudioIDs() throws {
        let preferences = InMemoryAudioDevicePreferences()
        let firstHAL = FixtureCoreAudioHAL(deviceID: 101)
        let firstManager = AudioDeviceManager(
            hal: firstHAL,
            preferences: preferences
        )
        firstManager.selectedInputDeviceID = nil
        firstManager.selectedInputDeviceID = firstHAL.deviceID
        firstManager.selectedOutputDeviceID = nil
        firstManager.selectedOutputDeviceID = firstHAL.deviceID
        firstManager.selectedInputRouteID = "channels-3-4"
        let uid = try XCTUnwrap(firstManager.selectedInputDevice?.uid)

        let secondHAL = FixtureCoreAudioHAL(deviceID: 9_999)
        let restored = AudioDeviceManager(
            hal: secondHAL,
            preferences: preferences
        )

        XCTAssertEqual(restored.selectedInputDeviceID, 9_999)
        XCTAssertEqual(restored.selectedOutputDeviceID, 9_999)
        XCTAssertEqual(restored.selectedInputDevice?.uid, uid)
        XCTAssertEqual(restored.selectedInputRouteID, "channels-3-4")
        XCTAssertEqual(
            preferences.snapshot["selectedInputRoute.\(uid)"],
            "channels-3-4"
        )
    }

    func testDisconnectPreservesUIDAndReconnectRestoresSelection() async throws {
        let hal = FakeCoreAudioHAL()
        let preferences = InMemoryAudioDevicePreferences()
        let manager = AudioDeviceManager(
            hal: hal,
            preferences: preferences
        )
        manager.selectedInputDeviceID = try XCTUnwrap(
            manager.selectedInputDeviceID
        )
        manager.selectedInputRouteID = "channels-3-4"
        let selectedUID = try XCTUnwrap(manager.selectedInputDevice?.uid)

        hal.setConnected(false)
        await Task.yield()
        try manager.refreshDevices()

        XCTAssertTrue(manager.inputDevices.isEmpty)
        XCTAssertNil(manager.selectedInputDeviceID)
        XCTAssertEqual(manager.savedInputUID, selectedUID)
        XCTAssertFalse(manager.isInputAvailable)
        XCTAssertEqual(manager.selectedInputDisplayName, "Scarlett 2i2 (Fake)")

        hal.setConnected(true)
        await Task.yield()
        try manager.refreshDevices()

        XCTAssertEqual(manager.selectedInputDevice?.uid, selectedUID)
        XCTAssertEqual(manager.selectedInputRouteID, "channels-3-4")
        XCTAssertTrue(manager.isInputAvailable)
    }

    func testAliveTransitionKeepsStableSelectionButMarksDeviceUnavailable()
        async throws
    {
        let hal = FakeCoreAudioHAL()
        let manager = AudioDeviceManager(
            hal: hal,
            preferences: InMemoryAudioDevicePreferences()
        )
        let selectedUID = try XCTUnwrap(manager.selectedInputDevice?.uid)

        hal.setAlive(false)
        await Task.yield()
        try manager.refreshDevices()

        XCTAssertEqual(manager.selectedInputDevice?.uid, selectedUID)
        XCTAssertEqual(manager.selectedInputDevice?.isAlive, false)
        XCTAssertFalse(manager.isInputAvailable)

        hal.setAlive(true)
        await Task.yield()
        try manager.refreshDevices()
        XCTAssertTrue(manager.isInputAvailable)
    }

    func testExplicitlyClearingSelectionRemovesPersistedUID() {
        let preferences = InMemoryAudioDevicePreferences()
        let manager = AudioDeviceManager(
            hal: FakeCoreAudioHAL(),
            preferences: preferences
        )
        manager.selectedInputDeviceID = manager.selectedInputDeviceID
        manager.selectedOutputDeviceID = manager.selectedOutputDeviceID

        XCTAssertNotNil(preferences.snapshot["selectedInputDeviceUID"])
        XCTAssertNotNil(preferences.snapshot["selectedOutputDeviceUID"])

        manager.selectedInputDeviceID = nil
        manager.selectedOutputDeviceID = nil

        XCTAssertNil(manager.savedInputUID)
        XCTAssertNil(manager.savedOutputUID)
        XCTAssertNil(preferences.snapshot["selectedInputDeviceUID"])
        XCTAssertNil(preferences.snapshot["selectedOutputDeviceUID"])
        XCTAssertEqual(
            preferences.snapshot["selectedInputDeviceSelectionMode"],
            "none"
        )
        XCTAssertEqual(
            preferences.snapshot["selectedOutputDeviceSelectionMode"],
            "none"
        )
    }

    func testExplicitNoneSurvivesRefreshAndRelaunch() throws {
        let preferences = InMemoryAudioDevicePreferences()
        let hal = FixtureCoreAudioHAL(deviceID: 101)
        let manager = AudioDeviceManager(
            hal: hal,
            preferences: preferences
        )

        manager.selectedInputDeviceID = nil
        manager.selectedOutputDeviceID = nil
        try manager.refreshDevices()

        XCTAssertNil(manager.selectedInputDeviceID)
        XCTAssertNil(manager.selectedOutputDeviceID)
        XCTAssertEqual(manager.inputSelectionPreference, .none)
        XCTAssertEqual(manager.outputSelectionPreference, .none)

        let restored = AudioDeviceManager(
            hal: FixtureCoreAudioHAL(deviceID: 9_999),
            preferences: preferences
        )

        XCTAssertNil(restored.selectedInputDeviceID)
        XCTAssertNil(restored.selectedOutputDeviceID)
        XCTAssertEqual(restored.inputSelectionPreference, .none)
        XCTAssertEqual(restored.outputSelectionPreference, .none)
    }

    func testLegacyUIDPreferencesMigrateToDeviceSelectionMode() {
        let preferences = InMemoryAudioDevicePreferences(values: [
            "selectedInputDeviceUID": "stable-focusrite-uid",
            "selectedOutputDeviceUID": "stable-focusrite-uid",
        ])

        let manager = AudioDeviceManager(
            hal: FixtureCoreAudioHAL(deviceID: 101),
            preferences: preferences
        )

        XCTAssertEqual(
            manager.inputSelectionPreference,
            .device(uid: "stable-focusrite-uid")
        )
        XCTAssertEqual(
            manager.outputSelectionPreference,
            .device(uid: "stable-focusrite-uid")
        )
        XCTAssertEqual(
            preferences.snapshot["selectedInputDeviceSelectionMode"],
            "device"
        )
        XCTAssertEqual(
            preferences.snapshot["selectedOutputDeviceSelectionMode"],
            "device"
        )
    }

    func testMissingPreferencesMigrateToSystemDefaultMode() {
        let preferences = InMemoryAudioDevicePreferences()
        let manager = AudioDeviceManager(
            hal: FixtureCoreAudioHAL(deviceID: 101),
            preferences: preferences
        )

        XCTAssertEqual(manager.inputSelectionPreference, .systemDefault)
        XCTAssertEqual(manager.outputSelectionPreference, .systemDefault)
        XCTAssertEqual(manager.selectedInputDeviceID, 101)
        XCTAssertEqual(manager.selectedOutputDeviceID, 101)
        XCTAssertEqual(
            preferences.snapshot["selectedInputDeviceSelectionMode"],
            "systemDefault"
        )
        XCTAssertEqual(
            preferences.snapshot["selectedOutputDeviceSelectionMode"],
            "systemDefault"
        )
    }

    func testListenersAreOwnedForManagerLifetime() {
        let hal = FakeCoreAudioHAL()
        weak var weakManager: AudioDeviceManager?

        do {
            let manager = AudioDeviceManager(
                hal: hal,
                preferences: InMemoryAudioDevicePreferences()
            )
            weakManager = manager
            XCTAssertEqual(hal.deviceListListenerCount, 1)
            XCTAssertEqual(hal.aliveListenerCount, 1)
        }

        XCTAssertNil(weakManager)
        XCTAssertEqual(hal.deviceListListenerCount, 0)
        XCTAssertEqual(hal.aliveListenerCount, 0)
    }

    func testHALDiscoveryErrorIsActionableAndDoesNotInventDevices() {
        let manager = AudioDeviceManager(
            hal: FailingCoreAudioHAL(),
            preferences: InMemoryAudioDevicePreferences()
        )

        XCTAssertTrue(manager.inputDevices.isEmpty)
        XCTAssertTrue(manager.outputDevices.isEmpty)
        XCTAssertEqual(manager.lastDiscoveryError, "Deterministic HAL failure")
    }
}

private final class FixtureCoreAudioHAL: CoreAudioHAL, @unchecked Sendable {
    let deviceID: AudioDeviceID

    init(deviceID: AudioDeviceID) {
        self.deviceID = deviceID
    }

    var bypassesMicrophonePermission: Bool { true }

    func devices() throws -> [CoreAudioHALDevice] {
        [
            CoreAudioHALDevice(
                id: deviceID,
                uid: "stable-focusrite-uid",
                name: "Fixture Scarlett",
                inputChannelCount: 4,
                outputChannelCount: 2,
                inputChannelNames: [
                    "Analog 1",
                    "Analog 2",
                    "Loopback 1",
                    "Loopback 2",
                ],
                nominalSampleRate: 48_000,
                availableSampleRates: [
                    AudioSampleRateRange(minimum: 48_000, maximum: 48_000)
                ],
                bufferFrameRange: 32...1_024,
                transport: .usb,
                isAlive: true
            )
        ]
    }

    func defaultInputDeviceID() throws -> AudioDeviceID? {
        deviceID
    }

    func defaultOutputDeviceID() throws -> AudioDeviceID? {
        deviceID
    }

    func observeDeviceList(
        _ observer: @escaping @Sendable () -> Void
    ) throws -> any CoreAudioHALListener {
        NoopCoreAudioHALListener()
    }

    func observeAlive(
        deviceID: AudioDeviceID,
        _ observer: @escaping @Sendable () -> Void
    ) throws -> any CoreAudioHALListener {
        NoopCoreAudioHALListener()
    }
}

private final class FailingCoreAudioHAL: CoreAudioHAL, @unchecked Sendable {
    var bypassesMicrophonePermission: Bool { true }

    func devices() throws -> [CoreAudioHALDevice] {
        throw FailingCoreAudioHALError()
    }

    func defaultInputDeviceID() throws -> AudioDeviceID? { nil }
    func defaultOutputDeviceID() throws -> AudioDeviceID? { nil }

    func observeDeviceList(
        _ observer: @escaping @Sendable () -> Void
    ) throws -> any CoreAudioHALListener {
        NoopCoreAudioHALListener()
    }

    func observeAlive(
        deviceID: AudioDeviceID,
        _ observer: @escaping @Sendable () -> Void
    ) throws -> any CoreAudioHALListener {
        NoopCoreAudioHALListener()
    }
}

private struct FailingCoreAudioHALError: LocalizedError {
    var errorDescription: String? { "Deterministic HAL failure" }
}

private final class NoopCoreAudioHALListener:
    CoreAudioHALListener,
    @unchecked Sendable
{
    func cancel() {}
}
