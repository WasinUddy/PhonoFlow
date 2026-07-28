import CoreAudio
import Dispatch

nonisolated final class CoreAudioListenerRegistration:
    @unchecked Sendable
{
    let block: AudioObjectPropertyListenerBlock

    init(_ block: @escaping AudioObjectPropertyListenerBlock) {
        self.block = block
    }
}

/// Injectable boundary around the Core Audio object-property C API.
///
/// Keeping the raw forwarding implementation in this file lets the production
/// discovery logic be exercised with deterministic data and failure statuses
/// without registering listeners or inspecting audio hardware in ordinary CI.
nonisolated protocol CoreAudioSystemRuntime: AnyObject, Sendable {
    func hasProperty(
        objectID: AudioObjectID,
        address: UnsafePointer<AudioObjectPropertyAddress>
    ) -> Bool

    func getPropertyDataSize(
        objectID: AudioObjectID,
        address: UnsafePointer<AudioObjectPropertyAddress>,
        qualifierDataSize: UInt32,
        qualifierData: UnsafeRawPointer?,
        dataSize: UnsafeMutablePointer<UInt32>
    ) -> OSStatus

    func getPropertyData(
        objectID: AudioObjectID,
        address: UnsafePointer<AudioObjectPropertyAddress>,
        qualifierDataSize: UInt32,
        qualifierData: UnsafeRawPointer?,
        dataSize: UnsafeMutablePointer<UInt32>,
        data: UnsafeMutableRawPointer
    ) -> OSStatus

    func addPropertyListener(
        objectID: AudioObjectID,
        address: UnsafePointer<AudioObjectPropertyAddress>,
        queue: DispatchQueue,
        registration: CoreAudioListenerRegistration
    ) -> OSStatus

    func removePropertyListener(
        objectID: AudioObjectID,
        address: UnsafePointer<AudioObjectPropertyAddress>,
        queue: DispatchQueue,
        registration: CoreAudioListenerRegistration
    ) -> OSStatus
}
