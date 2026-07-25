import CoreAudio
import Foundation
import XCTest

@testable import PhonoFlow

final class CoreAudioHALContractTests: XCTestCase {
    func testFakeHALDescribesClassCompliantFourInputUSBDevice() throws {
        let hal = FakeCoreAudioHAL()

        let device = try XCTUnwrap(try hal.devices().only)

        XCTAssertTrue(hal.bypassesMicrophonePermission)
        XCTAssertEqual(try hal.defaultInputDeviceID(), device.id)
        XCTAssertEqual(try hal.defaultOutputDeviceID(), device.id)
        XCTAssertEqual(device.uid, "com.phonoflow.fake.scarlett-2i2")
        XCTAssertEqual(device.name, "Scarlett 2i2 (Fake)")
        XCTAssertEqual(device.inputChannelCount, 4)
        XCTAssertEqual(device.outputChannelCount, 2)
        XCTAssertEqual(
            device.inputChannelNames,
            ["Input 1", "Input 2", "Loopback 1", "Loopback 2"]
        )
        XCTAssertEqual(device.nominalSampleRate, 48_000)
        XCTAssertEqual(
            device.availableSampleRates.map(\.minimum),
            [44_100, 48_000, 96_000, 192_000]
        )
        XCTAssertEqual(device.bufferFrameRange, 32...1_024)
        XCTAssertEqual(device.transport, .usb)
        XCTAssertTrue(device.isAlive)
    }

    func testDisconnectedFakeHALHasNoDevicesOrDefaults() throws {
        let hal = FakeCoreAudioHAL(connected: false)

        XCTAssertEqual(try hal.devices(), [])
        XCTAssertNil(try hal.defaultInputDeviceID())
        XCTAssertNil(try hal.defaultOutputDeviceID())
    }

    func testDeviceListListenerFiresOnlyForTransitionsAndCancelIsIdempotent() throws {
        let hal = FakeCoreAudioHAL()
        let calls = LockedCounter()
        let listener = try hal.observeDeviceList {
            calls.increment()
        }

        XCTAssertEqual(hal.deviceListListenerCount, 1)

        hal.setConnected(true)
        XCTAssertEqual(calls.value, 0)

        hal.setConnected(false)
        hal.setConnected(false)
        hal.setConnected(true)
        XCTAssertEqual(calls.value, 2)

        listener.cancel()
        listener.cancel()
        XCTAssertEqual(hal.deviceListListenerCount, 0)

        hal.setConnected(false)
        XCTAssertEqual(calls.value, 2)
    }

    func testAliveListenerFiresOnlyForTransitionsAndCancelStopsDelivery() throws {
        let hal = FakeCoreAudioHAL()
        let deviceID = try XCTUnwrap(try hal.defaultInputDeviceID())
        let calls = LockedCounter()
        let listener = try hal.observeAlive(deviceID: deviceID) {
            calls.increment()
        }

        XCTAssertEqual(hal.aliveListenerCount, 1)

        hal.setAlive(true)
        hal.setAlive(false)
        hal.setAlive(false)
        hal.setAlive(true)
        XCTAssertEqual(calls.value, 2)
        XCTAssertTrue(try XCTUnwrap(try hal.devices().only).isAlive)

        listener.cancel()
        XCTAssertEqual(hal.aliveListenerCount, 0)

        hal.setAlive(false)
        XCTAssertEqual(calls.value, 2)
    }

    func testListenerLifetimeAutomaticallyCancelsRegistration() throws {
        let hal = FakeCoreAudioHAL()
        var listener: (any CoreAudioHALListener)? = try hal.observeDeviceList {}

        XCTAssertNotNil(listener)
        XCTAssertEqual(hal.deviceListListenerCount, 1)

        listener = nil

        XCTAssertNil(listener)
        XCTAssertEqual(hal.deviceListListenerCount, 0)
    }

    func testUnknownDeviceAliveListenerReturnsTypedHALFailure() {
        let hal = FakeCoreAudioHAL()

        XCTAssertThrowsError(try hal.observeAlive(deviceID: 0xDEAD_BEEF) {}) { error in
            guard let halError = error as? CoreAudioHALError else {
                return XCTFail("Expected CoreAudioHALError, received \(error)")
            }
            XCTAssertEqual(halError.operation, "Register fake device-alive listener")
            XCTAssertEqual(halError.status, kAudioHardwareBadDeviceError)
            XCTAssertTrue(halError.localizedDescription.contains("Register fake device-alive listener"))
        }
    }

    func testHALFailureDescriptionFormatsPrintableAndNumericStatuses() {
        let printableStatus = OSStatus(bitPattern: 0x7465_7374)
        let printable = CoreAudioHALError(operation: "Read fixture", status: printableStatus)
        let numeric = CoreAudioHALError(operation: "Read fixture", status: -1)

        XCTAssertEqual(printable.localizedDescription, "Read fixture failed (test, \(printableStatus)).")
        XCTAssertEqual(numeric.localizedDescription, "Read fixture failed (OSStatus -1).")
    }

    func testInMemoryPreferencesSupportSeedMutationSnapshotAndRemoval() {
        let preferences = InMemoryAudioDevicePreferences(values: ["seed": "initial"])

        XCTAssertEqual(preferences.string(forKey: "seed"), "initial")
        XCTAssertNil(preferences.string(forKey: "missing"))

        preferences.set("updated", forKey: "seed")
        preferences.set("value", forKey: "new")
        XCTAssertEqual(preferences.snapshot, ["seed": "updated", "new": "value"])

        preferences.removeObject(forKey: "seed")
        preferences.removeObject(forKey: "missing")
        XCTAssertEqual(preferences.snapshot, ["new": "value"])
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

extension Array {
    fileprivate var only: Element? {
        count == 1 ? first : nil
    }
}
