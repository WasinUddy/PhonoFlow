import CoreAudio
import Foundation
import XCTest

@testable import PhonoFlow

@MainActor
final class AudioDeviceManagerEdgeCaseTests: XCTestCase {
    func testDefaultDeviceIDsWinOverAlphabeticalOrdering() throws {
        let alpha = Self.device(id: 101, uid: "alpha", name: "Alpha", inputs: 2, outputs: 2)
        let zulu = Self.device(id: 202, uid: "zulu", name: "Zulu", inputs: 2, outputs: 2)
        let hal = MutableCoreAudioHAL(
            devices: [zulu, alpha],
            defaultInputID: zulu.id,
            defaultOutputID: zulu.id
        )

        let manager = AudioDeviceManager(
            hal: hal,
            preferences: InMemoryAudioDevicePreferences()
        )

        XCTAssertEqual(manager.inputDevices.map(\.name), ["Alpha", "Zulu"])
        XCTAssertEqual(manager.outputDevices.map(\.name), ["Alpha", "Zulu"])
        XCTAssertEqual(manager.selectedInputDeviceID, zulu.id)
        XCTAssertEqual(manager.selectedOutputDeviceID, zulu.id)
        XCTAssertEqual(manager.selectedInputRouteID, "channels-1-2")
    }

    func testDevicesWithoutAnyChannelsAreFilteredFromBothLists() {
        let silent = Self.device(id: 1, uid: "silent", name: "Silent", inputs: 0, outputs: 0)
        let input = Self.device(id: 2, uid: "input", name: "Input", inputs: 1, outputs: 0)
        let output = Self.device(id: 3, uid: "output", name: "Output", inputs: 0, outputs: 2)
        let hal = MutableCoreAudioHAL(
            devices: [silent, input, output],
            defaultInputID: input.id,
            defaultOutputID: output.id
        )

        let manager = AudioDeviceManager(
            hal: hal,
            preferences: InMemoryAudioDevicePreferences()
        )

        XCTAssertEqual(manager.inputDevices.map(\.uid), ["input"])
        XCTAssertEqual(manager.outputDevices.map(\.uid), ["output"])
        XCTAssertEqual(manager.selectedInputDeviceID, input.id)
        XCTAssertEqual(manager.selectedOutputDeviceID, output.id)
    }

    func testSavedMissingUIDRemainsDisconnectedInsteadOfSilentlySelectingDefault() {
        let preferences = InMemoryAudioDevicePreferences(values: [
            "selectedInputDeviceUID": "missing-input",
            "selectedInputDeviceName": "Travel Interface",
            "selectedOutputDeviceUID": "missing-output",
            "selectedOutputDeviceName": "Studio Speakers",
        ])
        let present = Self.device(id: 10, uid: "present", name: "Present Device", inputs: 2, outputs: 2)
        let hal = MutableCoreAudioHAL(
            devices: [present],
            defaultInputID: present.id,
            defaultOutputID: present.id
        )

        let manager = AudioDeviceManager(hal: hal, preferences: preferences)

        XCTAssertNil(manager.selectedInputDeviceID)
        XCTAssertNil(manager.selectedOutputDeviceID)
        XCTAssertEqual(manager.selectedInputDisplayName, "Travel Interface")
        XCTAssertEqual(manager.selectedOutputDisplayName, "Studio Speakers")
        XCTAssertFalse(manager.isInputAvailable)
        XCTAssertFalse(manager.isOutputAvailable)
    }

    func testInvalidPersistedRouteFallsBackToFirstValidRoute() throws {
        let uid = "four-input"
        let preferences = InMemoryAudioDevicePreferences(values: [
            "selectedInputDeviceUID": uid,
            "selectedInputDeviceName": "Four Input",
            "selectedInputRoute.\(uid)": "channels-99-100",
        ])
        let device = Self.device(id: 55, uid: uid, name: "Four Input", inputs: 4, outputs: 0)
        let hal = MutableCoreAudioHAL(devices: [device], defaultInputID: device.id)

        let manager = AudioDeviceManager(hal: hal, preferences: preferences)

        XCTAssertEqual(manager.selectedInputRouteID, "channels-1-2")
        XCTAssertEqual(try XCTUnwrap(manager.selectedInputRoute).channelMap, [0, 1])
        XCTAssertEqual(manager.availableInputRoutes.map(\.id), ["channels-1-2", "channels-3-4"])
        XCTAssertEqual(
            preferences.snapshot["selectedInputRoute.\(uid)"],
            "channels-1-2"
        )
    }

    func testRoutePreferenceSurvivesDeselectionAndIsRestoredForSameUID() throws {
        let hal = FakeCoreAudioHAL()
        let preferences = InMemoryAudioDevicePreferences()
        let manager = AudioDeviceManager(hal: hal, preferences: preferences)
        let deviceID = try XCTUnwrap(manager.selectedInputDeviceID)
        let uid = try XCTUnwrap(manager.selectedInputDevice?.uid)

        manager.selectedInputRouteID = "channels-3-4"
        manager.selectedInputDeviceID = nil

        XCTAssertEqual(preferences.snapshot["selectedInputRoute.\(uid)"], "channels-3-4")
        XCTAssertNil(manager.selectedInputRouteID)

        manager.selectedInputDeviceID = deviceID

        XCTAssertEqual(manager.selectedInputRouteID, "channels-3-4")
        XCTAssertEqual(manager.selectedInputRoute?.channelMap, [2, 3])
    }

    func testDeviceListCallbackAutomaticallyDisconnectsAndReconnectsStableUID() async throws {
        let hal = FakeCoreAudioHAL()
        let manager = AudioDeviceManager(
            hal: hal,
            preferences: InMemoryAudioDevicePreferences()
        )
        let uid = try XCTUnwrap(manager.selectedInputDevice?.uid)
        manager.selectedInputDeviceID = try XCTUnwrap(manager.selectedInputDeviceID)
        manager.selectedInputRouteID = "channels-3-4"

        hal.setConnected(false)
        try await eventually {
            manager.inputDevices.isEmpty && manager.selectedInputDeviceID == nil
        }

        XCTAssertEqual(manager.savedInputUID, uid)
        XCTAssertFalse(manager.isInputAvailable)
        XCTAssertEqual(hal.aliveListenerCount, 0)

        hal.setConnected(true)
        try await eventually {
            manager.selectedInputDevice?.uid == uid
                && manager.selectedInputRouteID == "channels-3-4"
        }

        XCTAssertTrue(manager.isInputAvailable)
        XCTAssertEqual(hal.aliveListenerCount, 1)
    }

    func testAliveCallbackAutomaticallyUpdatesAvailability() async throws {
        let hal = FakeCoreAudioHAL()
        let manager = AudioDeviceManager(
            hal: hal,
            preferences: InMemoryAudioDevicePreferences()
        )

        hal.setAlive(false)
        try await eventually {
            manager.selectedInputDevice?.isAlive == false
        }
        XCTAssertFalse(manager.isInputAvailable)
        XCTAssertFalse(manager.isOutputAvailable)

        hal.setAlive(true)
        try await eventually {
            manager.selectedInputDevice?.isAlive == true
        }
        XCTAssertTrue(manager.isInputAvailable)
        XCTAssertTrue(manager.isOutputAvailable)
    }

    func testDefaultLookupFailuresUseFirstDevicesAndExposeWarning() {
        let firstInput = Self.device(id: 1, uid: "input-a", name: "A Input", inputs: 2, outputs: 0)
        let firstOutput = Self.device(id: 2, uid: "output-a", name: "A Output", inputs: 0, outputs: 2)
        let hal = MutableCoreAudioHAL(
            devices: [firstOutput, firstInput],
            defaultInputID: nil,
            defaultOutputID: nil
        )
        hal.defaultInputError = FixtureError(message: "Default input unavailable")
        hal.defaultOutputError = FixtureError(message: "Default output unavailable")

        let manager = AudioDeviceManager(
            hal: hal,
            preferences: InMemoryAudioDevicePreferences()
        )

        XCTAssertEqual(manager.selectedInputDeviceID, firstInput.id)
        XCTAssertEqual(manager.selectedOutputDeviceID, firstOutput.id)
        XCTAssertEqual(manager.lastDiscoveryError, "Default input unavailable")
    }

    func testFailedRefreshPreservesLastKnownDevicesAndSelection() throws {
        let initial = Self.device(id: 700, uid: "stable", name: "Stable Device", inputs: 2, outputs: 2)
        let hal = MutableCoreAudioHAL(
            devices: [initial],
            defaultInputID: initial.id,
            defaultOutputID: initial.id
        )
        let manager = AudioDeviceManager(
            hal: hal,
            preferences: InMemoryAudioDevicePreferences()
        )
        let selectedID = try XCTUnwrap(manager.selectedInputDeviceID)

        hal.devicesError = FixtureError(message: "HAL temporarily unavailable")
        XCTAssertThrowsError(try manager.refreshDevices()) { error in
            XCTAssertEqual(
                error as? AudioDeviceRefreshError,
                .discoveryFailed("HAL temporarily unavailable")
            )
        }

        XCTAssertEqual(manager.inputDevices.map(\.uid), ["stable"])
        XCTAssertEqual(manager.outputDevices.map(\.uid), ["stable"])
        XCTAssertEqual(manager.selectedInputDeviceID, selectedID)
        XCTAssertEqual(manager.lastDiscoveryError, "HAL temporarily unavailable")
    }

    func testAliveListenerFailureKeepsDiscoveredDeviceAndSurfacesError() {
        let input = Self.device(id: 44, uid: "input", name: "Input", inputs: 2, outputs: 0)
        let hal = MutableCoreAudioHAL(devices: [input], defaultInputID: input.id)
        hal.aliveListenerError = FixtureError(message: "Alive listener registration failed")

        let manager = AudioDeviceManager(
            hal: hal,
            preferences: InMemoryAudioDevicePreferences()
        )

        XCTAssertEqual(manager.selectedInputDeviceID, input.id)
        XCTAssertEqual(manager.lastDiscoveryError, "Alive listener registration failed")
        XCTAssertEqual(hal.aliveListenerCount, 0)
    }

    private static func device(
        id: AudioDeviceID,
        uid: String,
        name: String,
        inputs: Int,
        outputs: Int,
        alive: Bool = true
    ) -> CoreAudioHALDevice {
        CoreAudioHALDevice(
            id: id,
            uid: uid,
            name: name,
            inputChannelCount: inputs,
            outputChannelCount: outputs,
            inputChannelNames: (0..<max(inputs, 0)).map { "Input \($0 + 1)" },
            nominalSampleRate: 48_000,
            availableSampleRates: [
                AudioSampleRateRange(minimum: 44_100, maximum: 96_000)
            ],
            bufferFrameRange: 32...1_024,
            transport: .usb,
            isAlive: alive
        )
    }

    private func eventually(
        timeout: Duration = .seconds(1),
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else {
                XCTFail("Condition did not become true before timeout")
                return
            }
            await Task.yield()
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private final class MutableCoreAudioHAL: CoreAudioHAL, @unchecked Sendable {
    private let lock = NSLock()
    private var currentDevices: [CoreAudioHALDevice]
    private var inputID: AudioDeviceID?
    private var outputID: AudioDeviceID?
    private var listObservers: [UUID: @Sendable () -> Void] = [:]
    private var aliveObservers: [UUID: @Sendable () -> Void] = [:]

    var devicesError: Error?
    var defaultInputError: Error?
    var defaultOutputError: Error?
    var aliveListenerError: Error?

    init(
        devices: [CoreAudioHALDevice],
        defaultInputID: AudioDeviceID? = nil,
        defaultOutputID: AudioDeviceID? = nil
    ) {
        currentDevices = devices
        inputID = defaultInputID
        outputID = defaultOutputID
    }

    var bypassesMicrophonePermission: Bool { true }

    var aliveListenerCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return aliveObservers.count
    }

    func devices() throws -> [CoreAudioHALDevice] {
        lock.lock()
        defer { lock.unlock() }
        if let devicesError {
            throw devicesError
        }
        return currentDevices
    }

    func defaultInputDeviceID() throws -> AudioDeviceID? {
        lock.lock()
        defer { lock.unlock() }
        if let defaultInputError {
            throw defaultInputError
        }
        return inputID
    }

    func defaultOutputDeviceID() throws -> AudioDeviceID? {
        lock.lock()
        defer { lock.unlock() }
        if let defaultOutputError {
            throw defaultOutputError
        }
        return outputID
    }

    func observeDeviceList(
        _ observer: @escaping @Sendable () -> Void
    ) throws -> any CoreAudioHALListener {
        let id = UUID()
        lock.lock()
        listObservers[id] = observer
        lock.unlock()
        return ManagerTestListener { [weak self] in
            self?.removeListObserver(id)
        }
    }

    func observeAlive(
        deviceID: AudioDeviceID,
        _ observer: @escaping @Sendable () -> Void
    ) throws -> any CoreAudioHALListener {
        lock.lock()
        if let aliveListenerError {
            lock.unlock()
            throw aliveListenerError
        }
        let id = UUID()
        aliveObservers[id] = observer
        lock.unlock()
        return ManagerTestListener { [weak self] in
            self?.removeAliveObserver(id)
        }
    }

    private func removeListObserver(_ id: UUID) {
        lock.lock()
        listObservers.removeValue(forKey: id)
        lock.unlock()
    }

    private func removeAliveObserver(_ id: UUID) {
        lock.lock()
        aliveObservers.removeValue(forKey: id)
        lock.unlock()
    }
}

private final class ManagerTestListener: CoreAudioHALListener, @unchecked Sendable {
    private let lock = NSLock()
    private var cancellation: (@Sendable () -> Void)?

    init(cancellation: @escaping @Sendable () -> Void) {
        self.cancellation = cancellation
    }

    deinit {
        cancel()
    }

    func cancel() {
        lock.lock()
        let cancellation = cancellation
        self.cancellation = nil
        lock.unlock()
        cancellation?()
    }
}

private struct FixtureError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}
