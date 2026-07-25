//
//  CoreAudioHAL.swift
//  PhonoFlow
//
//  Injectable Core Audio discovery and listener boundary.
//

import CoreAudio
import Foundation
import os

nonisolated struct CoreAudioHALError: LocalizedError, Equatable, Sendable {
    let operation: String
    let status: OSStatus

    var errorDescription: String? {
        let code = Self.fourCharacterCode(status)
        if let code {
            return "\(operation) failed (\(code), \(status))."
        }
        return "\(operation) failed (OSStatus \(status))."
    }

    private static func fourCharacterCode(_ status: OSStatus) -> String? {
        let raw = UInt32(bitPattern: status)
        let bytes: [UInt8] = [
            UInt8((raw >> 24) & 0xff),
            UInt8((raw >> 16) & 0xff),
            UInt8((raw >> 8) & 0xff),
            UInt8(raw & 0xff),
        ]
        guard bytes.allSatisfy({ (32...126).contains($0) }) else {
            return nil
        }
        return String(bytes: bytes, encoding: .ascii)
    }
}

/// A hardware description at one discovery instant. Numeric Core Audio IDs
/// stay on this app-internal boundary; stable UIDs are used by persistence and
/// remote APIs.
nonisolated struct CoreAudioHALDevice: Hashable, Sendable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let inputChannelCount: Int
    let outputChannelCount: Int
    let inputChannelNames: [String]
    let nominalSampleRate: Double
    let availableSampleRates: [AudioSampleRateRange]
    let bufferFrameRange: ClosedRange<UInt32>?
    let transport: AudioDeviceTransport
    let isAlive: Bool
}

nonisolated protocol CoreAudioHALListener: AnyObject, Sendable {
    func cancel()
}

nonisolated protocol CoreAudioHAL: AnyObject, Sendable {
    /// Only deterministic test backends may bypass the TCC prompt.
    var bypassesMicrophonePermission: Bool { get }

    func devices() throws -> [CoreAudioHALDevice]
    func defaultInputDeviceID() throws -> AudioDeviceID?
    func defaultOutputDeviceID() throws -> AudioDeviceID?

    func observeDeviceList(
        _ observer: @escaping @Sendable () -> Void
    ) throws -> any CoreAudioHALListener

    func observeAlive(
        deviceID: AudioDeviceID,
        _ observer: @escaping @Sendable () -> Void
    ) throws -> any CoreAudioHALListener
}

nonisolated extension CoreAudioHAL {
    var bypassesMicrophonePermission: Bool { false }
}

nonisolated protocol AudioDevicePreferences: Sendable {
    func string(forKey key: String) -> String?
    func set(_ value: String, forKey key: String)
    func removeObject(forKey key: String)
}

nonisolated final class UserDefaultsAudioDevicePreferences:
    AudioDevicePreferences,
    @unchecked Sendable
{
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func string(forKey key: String) -> String? {
        defaults.string(forKey: key)
    }

    func set(_ value: String, forKey key: String) {
        defaults.set(value, forKey: key)
    }

    func removeObject(forKey key: String) {
        defaults.removeObject(forKey: key)
    }
}

/// A deterministic preference store for unit and acceptance harnesses.
nonisolated final class InMemoryAudioDevicePreferences:
    AudioDevicePreferences,
    AppSettingsPreferences,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var values: [String: Any]

    init(values: [String: Any] = [:]) {
        self.values = values
    }

    func string(forKey key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[key] as? String
    }

    func set(_ value: String, forKey key: String) {
        lock.lock()
        values[key] = value
        lock.unlock()
    }

    func array(forKey key: String) -> [Any]? {
        lock.lock()
        defer { lock.unlock() }
        return values[key] as? [Any]
    }

    func integer(forKey key: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        if let number = values[key] as? NSNumber {
            return number.intValue
        }
        if let value = values[key] as? String {
            return Int(value) ?? 0
        }
        return 0
    }

    func bool(forKey key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let number = values[key] as? NSNumber {
            return number.boolValue
        }
        if let value = values[key] as? String {
            return (value as NSString).boolValue
        }
        return false
    }

    func object(forKey key: String) -> Any? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }

    func set(_ value: Any?, forKey key: String) {
        lock.lock()
        if let value {
            values[key] = value
        } else {
            values.removeValue(forKey: key)
        }
        lock.unlock()
    }

    func removeObject(forKey key: String) {
        lock.lock()
        values.removeValue(forKey: key)
        lock.unlock()
    }

    var snapshot: [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return values.compactMapValues { $0 as? String }
    }

    func removeAll() {
        lock.lock()
        values.removeAll(keepingCapacity: false)
        lock.unlock()
    }
}

/// Production Core Audio implementation. Every HAL status is checked at the
/// point of use and property-listener registrations own their exact matching
/// removal operation.
nonisolated final class ProductionCoreAudioHAL:
    CoreAudioHAL,
    @unchecked Sendable
{
    private static let logger = Logger(
        subsystem: "com.phonoflow",
        category: "CoreAudioHAL"
    )

    private let runtime: any CoreAudioSystemRuntime
    private let listenerQueue: DispatchQueue

    init(
        runtime: any CoreAudioSystemRuntime = SystemCoreAudioRuntime.shared
    ) {
        self.runtime = runtime
        listenerQueue = DispatchQueue(
            label: "com.phonoflow.coreaudio.device-listeners",
            qos: .utility
        )
    }

    func devices() throws -> [CoreAudioHALDevice] {
        let ids = try deviceIDs()
        var result: [CoreAudioHALDevice] = []
        result.reserveCapacity(ids.count)
        var firstFailure: Error?

        for id in ids {
            do {
                result.append(try device(id))
            } catch {
                if firstFailure == nil {
                    firstFailure = error
                }
                Self.logger.error(
                    "Skipping an unreadable Core Audio device: \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        if result.isEmpty, !ids.isEmpty, let firstFailure {
            throw firstFailure
        }
        return result
    }

    func defaultInputDeviceID() throws -> AudioDeviceID? {
        try defaultDevice(selector: kAudioHardwarePropertyDefaultInputDevice)
    }

    func defaultOutputDeviceID() throws -> AudioDeviceID? {
        try defaultDevice(selector: kAudioHardwarePropertyDefaultOutputDevice)
    }

    func observeDeviceList(
        _ observer: @escaping @Sendable () -> Void
    ) throws -> any CoreAudioHALListener {
        let address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        return try observe(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            address: address,
            operation: "Register Core Audio device-list listener",
            observer: observer
        )
    }

    func observeAlive(
        deviceID: AudioDeviceID,
        _ observer: @escaping @Sendable () -> Void
    ) throws -> any CoreAudioHALListener {
        let address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        return try observe(
            objectID: deviceID,
            address: address,
            operation: "Register Core Audio device-alive listener",
            observer: observer
        )
    }

    func deviceUID(for deviceID: AudioDeviceID) throws -> String {
        try requiredString(
            objectID: deviceID,
            selector: kAudioDevicePropertyDeviceUID,
            scope: kAudioObjectPropertyScopeGlobal,
            element: kAudioObjectPropertyElementMain,
            operation: "Read Core Audio device UID"
        )
    }

    private func device(_ deviceID: AudioDeviceID) throws -> CoreAudioHALDevice {
        let inputChannels = try channelCount(
            deviceID: deviceID,
            scope: kAudioDevicePropertyScopeInput
        )
        let outputChannels = try channelCount(
            deviceID: deviceID,
            scope: kAudioDevicePropertyScopeOutput
        )
        let names = try (0..<inputChannels).map { channel in
            try channelName(deviceID: deviceID, channel: channel)
        }

        return try CoreAudioHALDevice(
            id: deviceID,
            uid: deviceUID(for: deviceID),
            name: requiredString(
                objectID: deviceID,
                selector: kAudioObjectPropertyName,
                scope: kAudioObjectPropertyScopeGlobal,
                element: kAudioObjectPropertyElementMain,
                operation: "Read Core Audio device name"
            ),
            inputChannelCount: inputChannels,
            outputChannelCount: outputChannels,
            inputChannelNames: names,
            nominalSampleRate: scalar(
                objectID: deviceID,
                selector: kAudioDevicePropertyNominalSampleRate,
                scope: kAudioObjectPropertyScopeGlobal,
                element: kAudioObjectPropertyElementMain,
                initialValue: Double.zero,
                operation: "Read Core Audio nominal sample rate"
            ),
            availableSampleRates: availableSampleRates(deviceID: deviceID),
            bufferFrameRange: bufferFrameRange(deviceID: deviceID),
            transport: transport(deviceID: deviceID),
            isAlive: deviceIsAlive(deviceID: deviceID)
        )
    }

    private func deviceIDs() throws -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        try requireNoErr(
            runtime.getPropertyDataSize(
                objectID: AudioObjectID(kAudioObjectSystemObject),
                address: &address,
                qualifierDataSize: 0,
                qualifierData: nil,
                dataSize: &dataSize
            ),
            operation: "Enumerate Core Audio devices"
        )
        guard
            dataSize.isMultiple(
                of: UInt32(MemoryLayout<AudioDeviceID>.stride)
            )
        else {
            throw CoreAudioHALError(
                operation: "Validate Core Audio device-list size",
                status: kAudio_ParamError
            )
        }

        let elementStride = MemoryLayout<AudioDeviceID>.stride
        let count = Int(dataSize) / elementStride
        guard count > 0 else { return [] }
        var result = [AudioDeviceID](repeating: 0, count: count)
        let writableDataSize = dataSize
        let status = result.withUnsafeMutableBufferPointer { buffer in
            runtime.getPropertyData(
                objectID: AudioObjectID(kAudioObjectSystemObject),
                address: &address,
                qualifierDataSize: 0,
                qualifierData: nil,
                dataSize: &dataSize,
                data: buffer.baseAddress!
            )
        }
        try requireNoErr(status, operation: "Read Core Audio device list")
        guard dataSize <= writableDataSize,
            dataSize.isMultiple(of: UInt32(elementStride))
        else {
            throw CoreAudioHALError(
                operation: "Validate Core Audio device-list size",
                status: kAudio_ParamError
            )
        }
        let returnedCount = Int(dataSize) / elementStride
        return Array(result.prefix(returnedCount))
    }

    private func defaultDevice(
        selector: AudioObjectPropertySelector
    ) throws -> AudioDeviceID? {
        let value: AudioDeviceID = try scalar(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            selector: selector,
            scope: kAudioObjectPropertyScopeGlobal,
            element: kAudioObjectPropertyElementMain,
            initialValue: AudioDeviceID.zero,
            operation: "Read Core Audio default device"
        )
        return value == kAudioObjectUnknown ? nil : value
    }

    private func channelCount(
        deviceID: AudioDeviceID,
        scope: AudioObjectPropertyScope
    ) throws -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        guard
            runtime.hasProperty(objectID: deviceID, address: &address)
        else { return 0 }
        var dataSize: UInt32 = 0
        try requireNoErr(
            runtime.getPropertyDataSize(
                objectID: deviceID,
                address: &address,
                qualifierDataSize: 0,
                qualifierData: nil,
                dataSize: &dataSize
            ),
            operation: "Read Core Audio stream-configuration size"
        )
        guard
            let bufferOffset = MemoryLayout<AudioBufferList>.offset(
                of: \.mBuffers
            ),
            dataSize >= UInt32(bufferOffset)
        else {
            throw CoreAudioHALError(
                operation: "Validate Core Audio stream configuration",
                status: kAudio_ParamError
            )
        }

        let writableDataSize = dataSize
        let allocationSize = max(
            Int(writableDataSize),
            MemoryLayout<AudioBufferList>.size
        )
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: allocationSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { storage.deallocate() }
        let list = storage.assumingMemoryBound(to: AudioBufferList.self)
        try requireNoErr(
            runtime.getPropertyData(
                objectID: deviceID,
                address: &address,
                qualifierDataSize: 0,
                qualifierData: nil,
                dataSize: &dataSize,
                data: list
            ),
            operation: "Read Core Audio stream configuration"
        )
        let returnedDataSize = Int(dataSize)
        let bufferCount = Int(list.pointee.mNumberBuffers)
        let (bufferBytes, bufferBytesOverflow) =
            bufferCount.multipliedReportingOverflow(
                by: MemoryLayout<AudioBuffer>.stride
            )
        let (requiredDataSize, requiredSizeOverflow) =
            bufferOffset.addingReportingOverflow(bufferBytes)
        guard dataSize <= writableDataSize,
            returnedDataSize >= bufferOffset,
            !bufferBytesOverflow,
            !requiredSizeOverflow,
            requiredDataSize <= returnedDataSize,
            requiredDataSize <= allocationSize
        else {
            throw CoreAudioHALError(
                operation: "Validate Core Audio stream configuration",
                status: kAudio_ParamError
            )
        }
        return UnsafeMutableAudioBufferListPointer(list).reduce(0) {
            $0 + Int($1.mNumberChannels)
        }
    }

    private func channelName(
        deviceID: AudioDeviceID,
        channel: Int
    ) throws -> String {
        let element = AudioObjectPropertyElement(channel + 1)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyElementName,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: element
        )
        guard
            runtime.hasProperty(objectID: deviceID, address: &address)
        else {
            return "Input \(channel + 1)"
        }
        do {
            return try requiredString(
                objectID: deviceID,
                selector: address.mSelector,
                scope: address.mScope,
                element: address.mElement,
                operation: "Read Core Audio input-channel name"
            )
        } catch {
            Self.logger.error(
                "Using a generic input-channel name: \(error.localizedDescription, privacy: .public)"
            )
            return "Input \(channel + 1)"
        }
    }

    private func availableSampleRates(
        deviceID: AudioDeviceID
    ) throws -> [AudioSampleRateRange] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyAvailableNominalSampleRates,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard
            runtime.hasProperty(objectID: deviceID, address: &address)
        else { return [] }
        var dataSize: UInt32 = 0
        try requireNoErr(
            runtime.getPropertyDataSize(
                objectID: deviceID,
                address: &address,
                qualifierDataSize: 0,
                qualifierData: nil,
                dataSize: &dataSize
            ),
            operation: "Read Core Audio sample-rate-list size"
        )
        guard
            dataSize.isMultiple(
                of: UInt32(MemoryLayout<AudioValueRange>.stride)
            )
        else {
            throw CoreAudioHALError(
                operation: "Validate Core Audio sample-rate-list size",
                status: kAudio_ParamError
            )
        }
        let elementStride = MemoryLayout<AudioValueRange>.stride
        let count = Int(dataSize) / elementStride
        guard count > 0 else { return [] }
        var values = [AudioValueRange](
            repeating: AudioValueRange(),
            count: count
        )
        let writableDataSize = dataSize
        let status = values.withUnsafeMutableBufferPointer { buffer in
            runtime.getPropertyData(
                objectID: deviceID,
                address: &address,
                qualifierDataSize: 0,
                qualifierData: nil,
                dataSize: &dataSize,
                data: buffer.baseAddress!
            )
        }
        try requireNoErr(
            status,
            operation: "Read Core Audio available sample rates"
        )
        guard dataSize <= writableDataSize,
            dataSize.isMultiple(of: UInt32(elementStride))
        else {
            throw CoreAudioHALError(
                operation: "Validate Core Audio sample-rate-list size",
                status: kAudio_ParamError
            )
        }
        let returnedCount = Int(dataSize) / elementStride
        return values.prefix(returnedCount).map {
            AudioSampleRateRange(minimum: $0.mMinimum, maximum: $0.mMaximum)
        }
    }

    private func bufferFrameRange(
        deviceID: AudioDeviceID
    ) throws -> ClosedRange<UInt32>? {
        let selector = kAudioDevicePropertyBufferFrameSizeRange
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard
            runtime.hasProperty(objectID: deviceID, address: &address)
        else { return nil }
        let value: AudioValueRange = try scalar(
            objectID: deviceID,
            selector: selector,
            scope: kAudioObjectPropertyScopeGlobal,
            element: kAudioObjectPropertyElementMain,
            initialValue: AudioValueRange(),
            operation: "Read Core Audio buffer-frame range"
        )
        guard value.mMinimum >= 0,
            value.mMaximum >= value.mMinimum,
            value.mMaximum <= Double(UInt32.max)
        else {
            throw CoreAudioHALError(
                operation: "Validate Core Audio buffer-frame range",
                status: kAudio_ParamError
            )
        }
        return UInt32(value.mMinimum)...UInt32(value.mMaximum)
    }

    private func transport(
        deviceID: AudioDeviceID
    ) throws -> AudioDeviceTransport {
        let selector = kAudioDevicePropertyTransportType
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard
            runtime.hasProperty(objectID: deviceID, address: &address)
        else { return .other }
        let value: UInt32 = try scalar(
            objectID: deviceID,
            selector: selector,
            scope: kAudioObjectPropertyScopeGlobal,
            element: kAudioObjectPropertyElementMain,
            initialValue: 0,
            operation: "Read Core Audio device transport"
        )
        switch value {
        case kAudioDeviceTransportTypeBuiltIn: return .builtIn
        case kAudioDeviceTransportTypeUSB: return .usb
        case kAudioDeviceTransportTypeBluetooth,
            kAudioDeviceTransportTypeBluetoothLE:
            return .bluetooth
        case kAudioDeviceTransportTypeHDMI: return .hdmi
        case kAudioDeviceTransportTypeDisplayPort: return .displayPort
        case kAudioDeviceTransportTypeAggregate: return .aggregate
        case kAudioDeviceTransportTypeVirtual: return .virtual
        default: return .other
        }
    }

    private func deviceIsAlive(deviceID: AudioDeviceID) throws -> Bool {
        let selector = kAudioDevicePropertyDeviceIsAlive
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard
            runtime.hasProperty(objectID: deviceID, address: &address)
        else { return true }
        let value: UInt32 = try scalar(
            objectID: deviceID,
            selector: selector,
            scope: kAudioObjectPropertyScopeGlobal,
            element: kAudioObjectPropertyElementMain,
            initialValue: 0,
            operation: "Read Core Audio device-alive state"
        )
        return value != 0
    }

    private func requiredString(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement,
        operation: String
    ) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: element
        )
        var value: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try requireNoErr(
            runtime.getPropertyData(
                objectID: objectID,
                address: &address,
                qualifierDataSize: 0,
                qualifierData: nil,
                dataSize: &dataSize,
                data: &value
            ),
            operation: operation
        )
        guard let value else {
            throw CoreAudioHALError(
                operation: operation,
                status: kAudio_ParamError
            )
        }
        return value.takeRetainedValue() as String
    }

    private func scalar<Value: BitwiseCopyable>(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement,
        initialValue: Value,
        operation: String
    ) throws -> Value {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: element
        )
        var value = initialValue
        var dataSize = UInt32(MemoryLayout<Value>.size)
        try requireNoErr(
            runtime.getPropertyData(
                objectID: objectID,
                address: &address,
                qualifierDataSize: 0,
                qualifierData: nil,
                dataSize: &dataSize,
                data: &value
            ),
            operation: operation
        )
        guard dataSize == UInt32(MemoryLayout<Value>.size) else {
            throw CoreAudioHALError(
                operation: "Validate \(operation.lowercased()) size",
                status: kAudio_ParamError
            )
        }
        return value
    }

    private func observe(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress,
        operation: String,
        observer: @escaping @Sendable () -> Void
    ) throws -> any CoreAudioHALListener {
        let registration = CoreAudioListenerRegistration { _, _ in
            observer()
        }
        var mutableAddress = address
        try requireNoErr(
            runtime.addPropertyListener(
                objectID: objectID,
                address: &mutableAddress,
                queue: listenerQueue,
                registration: registration
            ),
            operation: operation
        )
        return CoreAudioPropertyListenerToken(
            runtime: runtime,
            objectID: objectID,
            address: address,
            queue: listenerQueue,
            registration: registration
        )
    }

    private func requireNoErr(
        _ status: OSStatus,
        operation: String
    ) throws {
        guard status == noErr else {
            throw CoreAudioHALError(operation: operation, status: status)
        }
    }
}

nonisolated private final class CoreAudioPropertyListenerToken:
    CoreAudioHALListener,
    @unchecked Sendable
{
    private static let logger = Logger(
        subsystem: "com.phonoflow",
        category: "CoreAudioHAL"
    )

    private let runtime: any CoreAudioSystemRuntime
    private let lock = NSLock()
    private let objectID: AudioObjectID
    private let address: AudioObjectPropertyAddress
    private let queue: DispatchQueue
    private var registration: CoreAudioListenerRegistration?

    init(
        runtime: any CoreAudioSystemRuntime,
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress,
        queue: DispatchQueue,
        registration: CoreAudioListenerRegistration
    ) {
        self.runtime = runtime
        self.objectID = objectID
        self.address = address
        self.queue = queue
        self.registration = registration
    }

    deinit {
        cancel()
    }

    func cancel() {
        lock.lock()
        guard let registration else {
            lock.unlock()
            return
        }
        var address = address
        let status = runtime.removePropertyListener(
            objectID: objectID,
            address: &address,
            queue: queue,
            registration: registration
        )
        if status == noErr {
            self.registration = nil
        }
        lock.unlock()

        guard status != noErr else { return }
        Self.logger.error(
            "Remove Core Audio listener failed with OSStatus \(status)"
        )
    }
}
