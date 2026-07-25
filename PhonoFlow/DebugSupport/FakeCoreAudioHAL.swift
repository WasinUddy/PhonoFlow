//
//  FakeCoreAudioHAL.swift
//  PhonoFlow
//
//  Deterministic Core Audio fixture for tests and acceptance harnesses.
//

#if DEBUG
    import CoreAudio
    import Foundation

    /// Deterministic, class-compliant four-input USB fixture. It intentionally
    /// models two stereo routes: analog channels 1–2 and loopback channels 3–4.
    nonisolated final class FakeCoreAudioHAL: CoreAudioHAL, @unchecked Sendable {
        private static let fakeDeviceID = AudioDeviceID(0x5046_0001)

        private let lock = NSLock()
        private var connected: Bool
        private var alive: Bool
        private var deviceListObservers: [UUID: @Sendable () -> Void] = [:]
        private var aliveObservers: [UUID: @Sendable () -> Void] = [:]

        init(connected: Bool = true, alive: Bool = true) {
            self.connected = connected
            self.alive = alive
        }

        var bypassesMicrophonePermission: Bool { true }

        func devices() throws -> [CoreAudioHALDevice] {
            lock.lock()
            let isConnected = connected
            let isAlive = alive
            lock.unlock()
            guard isConnected else { return [] }
            return [
                CoreAudioHALDevice(
                    id: Self.fakeDeviceID,
                    uid: "com.phonoflow.fake.scarlett-2i2",
                    name: "Scarlett 2i2 (Fake)",
                    inputChannelCount: 4,
                    outputChannelCount: 2,
                    inputChannelNames: [
                        "Input 1",
                        "Input 2",
                        "Loopback 1",
                        "Loopback 2",
                    ],
                    nominalSampleRate: 48_000,
                    availableSampleRates: [
                        AudioSampleRateRange(minimum: 44_100, maximum: 44_100),
                        AudioSampleRateRange(minimum: 48_000, maximum: 48_000),
                        AudioSampleRateRange(minimum: 96_000, maximum: 96_000),
                        AudioSampleRateRange(minimum: 192_000, maximum: 192_000),
                    ],
                    bufferFrameRange: 32...1_024,
                    transport: .usb,
                    isAlive: isAlive
                )
            ]
        }

        func defaultInputDeviceID() throws -> AudioDeviceID? {
            isConnected ? Self.fakeDeviceID : nil
        }

        func defaultOutputDeviceID() throws -> AudioDeviceID? {
            isConnected ? Self.fakeDeviceID : nil
        }

        func observeDeviceList(
            _ observer: @escaping @Sendable () -> Void
        ) throws -> any CoreAudioHALListener {
            let id = UUID()
            lock.lock()
            deviceListObservers[id] = observer
            lock.unlock()
            return ClosureCoreAudioHALListener { [weak self] in
                self?.removeDeviceListObserver(id)
            }
        }

        func observeAlive(
            deviceID: AudioDeviceID,
            _ observer: @escaping @Sendable () -> Void
        ) throws -> any CoreAudioHALListener {
            guard deviceID == Self.fakeDeviceID else {
                throw CoreAudioHALError(
                    operation: "Register fake device-alive listener",
                    status: kAudioHardwareBadDeviceError
                )
            }
            let id = UUID()
            lock.lock()
            aliveObservers[id] = observer
            lock.unlock()
            return ClosureCoreAudioHALListener { [weak self] in
                self?.removeAliveObserver(id)
            }
        }

        /// Simulates physical USB removal or attachment.
        func setConnected(_ value: Bool) {
            lock.lock()
            guard connected != value else {
                lock.unlock()
                return
            }
            connected = value
            let observers = Array(deviceListObservers.values)
            lock.unlock()
            for observer in observers {
                observer()
            }
        }

        /// Simulates Core Audio's device-alive transition without removing it.
        func setAlive(_ value: Bool) {
            lock.lock()
            guard alive != value else {
                lock.unlock()
                return
            }
            alive = value
            let observers = Array(aliveObservers.values)
            lock.unlock()
            for observer in observers {
                observer()
            }
        }

        var deviceListListenerCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return deviceListObservers.count
        }

        var aliveListenerCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return aliveObservers.count
        }

        private var isConnected: Bool {
            lock.lock()
            defer { lock.unlock() }
            return connected
        }

        private func removeDeviceListObserver(_ id: UUID) {
            lock.lock()
            deviceListObservers.removeValue(forKey: id)
            lock.unlock()
        }

        private func removeAliveObserver(_ id: UUID) {
            lock.lock()
            aliveObservers.removeValue(forKey: id)
            lock.unlock()
        }
    }

    nonisolated private final class ClosureCoreAudioHALListener:
        CoreAudioHALListener,
        @unchecked Sendable
    {
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
#endif
