import AudioToolbox
import CoreAudio

/// Injectable boundary around the Core Audio functions used by `AudioMonitor`.
///
/// The protocol intentionally mirrors the C API and accepts caller-owned
/// pointers. Production calls therefore add no allocation to an audio callback,
/// while deterministic tests can return any `OSStatus` without audio hardware.
nonisolated protocol AudioUnitHALRuntime: AnyObject, Sendable {
    func findComponent(
        matching description: AudioComponentDescription
    ) -> AudioComponent?

    func instantiate(
        _ component: AudioComponent,
        unit: UnsafeMutablePointer<AudioUnit?>
    ) -> OSStatus

    func dispose(_ unit: AudioUnit) -> OSStatus

    func setProperty(
        _ unit: AudioUnit,
        id: AudioUnitPropertyID,
        scope: AudioUnitScope,
        element: AudioUnitElement,
        data: UnsafeRawPointer?,
        byteCount: UInt32
    ) -> OSStatus

    func getProperty(
        _ unit: AudioUnit,
        id: AudioUnitPropertyID,
        scope: AudioUnitScope,
        element: AudioUnitElement,
        data: UnsafeMutableRawPointer,
        byteCount: UnsafeMutablePointer<UInt32>
    ) -> OSStatus

    func initialize(_ unit: AudioUnit) -> OSStatus
    func start(_ unit: AudioUnit) -> OSStatus
    func stop(_ unit: AudioUnit) -> OSStatus

    func render(
        _ unit: AudioUnit,
        actionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timestamp: UnsafePointer<AudioTimeStamp>,
        bus: AudioUnitElement,
        frameCount: UInt32,
        data: UnsafeMutablePointer<AudioBufferList>
    ) -> OSStatus

    func getObjectPropertyData(
        objectID: AudioObjectID,
        address: UnsafePointer<AudioObjectPropertyAddress>,
        qualifierDataSize: UInt32,
        qualifierData: UnsafeRawPointer?,
        dataSize: UnsafeMutablePointer<UInt32>,
        data: UnsafeMutableRawPointer
    ) -> OSStatus

    func setObjectPropertyData(
        objectID: AudioObjectID,
        address: UnsafePointer<AudioObjectPropertyAddress>,
        qualifierDataSize: UInt32,
        qualifierData: UnsafeRawPointer?,
        dataSize: UInt32,
        data: UnsafeRawPointer
    ) -> OSStatus
}
