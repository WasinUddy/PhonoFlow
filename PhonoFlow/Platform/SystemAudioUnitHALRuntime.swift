import AudioToolbox
import CoreAudio

/// The production adapter that forwards `AudioUnitHALRuntime` operations to
/// Core Audio's C API.
nonisolated final class SystemAudioUnitHALRuntime:
    AudioUnitHALRuntime, @unchecked Sendable
{
    static let shared = SystemAudioUnitHALRuntime()

    private init() {}

    func findComponent(
        matching description: AudioComponentDescription
    ) -> AudioComponent? {
        var description = description
        return AudioComponentFindNext(nil, &description)
    }

    func instantiate(
        _ component: AudioComponent,
        unit: UnsafeMutablePointer<AudioUnit?>
    ) -> OSStatus {
        AudioComponentInstanceNew(component, unit)
    }

    func dispose(_ unit: AudioUnit) -> OSStatus {
        AudioComponentInstanceDispose(unit)
    }

    func setProperty(
        _ unit: AudioUnit,
        id: AudioUnitPropertyID,
        scope: AudioUnitScope,
        element: AudioUnitElement,
        data: UnsafeRawPointer?,
        byteCount: UInt32
    ) -> OSStatus {
        AudioUnitSetProperty(
            unit,
            id,
            scope,
            element,
            data,
            byteCount
        )
    }

    func getProperty(
        _ unit: AudioUnit,
        id: AudioUnitPropertyID,
        scope: AudioUnitScope,
        element: AudioUnitElement,
        data: UnsafeMutableRawPointer,
        byteCount: UnsafeMutablePointer<UInt32>
    ) -> OSStatus {
        AudioUnitGetProperty(
            unit,
            id,
            scope,
            element,
            data,
            byteCount
        )
    }

    func initialize(_ unit: AudioUnit) -> OSStatus {
        AudioUnitInitialize(unit)
    }

    func start(_ unit: AudioUnit) -> OSStatus {
        AudioOutputUnitStart(unit)
    }

    func stop(_ unit: AudioUnit) -> OSStatus {
        AudioOutputUnitStop(unit)
    }

    func render(
        _ unit: AudioUnit,
        actionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timestamp: UnsafePointer<AudioTimeStamp>,
        bus: AudioUnitElement,
        frameCount: UInt32,
        data: UnsafeMutablePointer<AudioBufferList>
    ) -> OSStatus {
        AudioUnitRender(
            unit,
            actionFlags,
            timestamp,
            bus,
            frameCount,
            data
        )
    }

    func getObjectPropertyData(
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

    func setObjectPropertyData(
        objectID: AudioObjectID,
        address: UnsafePointer<AudioObjectPropertyAddress>,
        qualifierDataSize: UInt32,
        qualifierData: UnsafeRawPointer?,
        dataSize: UInt32,
        data: UnsafeRawPointer
    ) -> OSStatus {
        AudioObjectSetPropertyData(
            objectID,
            address,
            qualifierDataSize,
            qualifierData,
            dataSize,
            data
        )
    }
}
