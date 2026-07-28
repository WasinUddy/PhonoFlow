import CoreAudio
import Dispatch

/// Thin platform forwarding shim. Behavioral tests inject a fake runtime and
/// leave these five direct C calls to protected platform acceptance.
nonisolated final class SystemCoreAudioRuntime:
    CoreAudioSystemRuntime,
    @unchecked Sendable
{
    static let shared = SystemCoreAudioRuntime()

    private init() {}

    func hasProperty(
        objectID: AudioObjectID,
        address: UnsafePointer<AudioObjectPropertyAddress>
    ) -> Bool {
        AudioObjectHasProperty(objectID, address)
    }

    func getPropertyDataSize(
        objectID: AudioObjectID,
        address: UnsafePointer<AudioObjectPropertyAddress>,
        qualifierDataSize: UInt32,
        qualifierData: UnsafeRawPointer?,
        dataSize: UnsafeMutablePointer<UInt32>
    ) -> OSStatus {
        AudioObjectGetPropertyDataSize(
            objectID,
            address,
            qualifierDataSize,
            qualifierData,
            dataSize
        )
    }

    func getPropertyData(
        objectID: AudioObjectID,
        address: UnsafePointer<AudioObjectPropertyAddress>,
        qualifierDataSize: UInt32,
        qualifierData: UnsafeRawPointer?,
        dataSize: UnsafeMutablePointer<UInt32>,
        data: UnsafeMutableRawPointer
    ) -> OSStatus {
        AudioObjectGetPropertyData(
            objectID,
            address,
            qualifierDataSize,
            qualifierData,
            dataSize,
            data
        )
    }

    func addPropertyListener(
        objectID: AudioObjectID,
        address: UnsafePointer<AudioObjectPropertyAddress>,
        queue: DispatchQueue,
        registration: CoreAudioListenerRegistration
    ) -> OSStatus {
        AudioObjectAddPropertyListenerBlock(
            objectID,
            address,
            queue,
            registration.block
        )
    }

    func removePropertyListener(
        objectID: AudioObjectID,
        address: UnsafePointer<AudioObjectPropertyAddress>,
        queue: DispatchQueue,
        registration: CoreAudioListenerRegistration
    ) -> OSStatus {
        AudioObjectRemovePropertyListenerBlock(
            objectID,
            address,
            queue,
            registration.block
        )
    }
}
