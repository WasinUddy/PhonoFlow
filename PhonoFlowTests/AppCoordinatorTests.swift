import CoreAudio
import Foundation
import XCTest

@testable import PhonoFlow

@MainActor
final class AppCoordinatorTests: XCTestCase {
    func testSnapshotUsesStableDeviceIdentityAndReadDoesNotAdvanceRevision()
        throws
    {
        let harness = try CoordinatorHarness()

        let first = harness.coordinator.remoteStateSnapshot()
        let second = harness.coordinator.remoteStateSnapshot()

        XCTAssertEqual(first.revision, 1)
        XCTAssertEqual(second.revision, first.revision)
        XCTAssertEqual(
            first.selection,
            RemoteAudioSelection(
                inputUID: CoordinatorHarness.deviceUID,
                inputRouteID: "channels-1-2",
                outputUID: CoordinatorHarness.deviceUID
            )
        )
        XCTAssertEqual(first.engine.phase, .idle)

        let device = try XCTUnwrap(first.devices.first)
        XCTAssertEqual(device.uid, CoordinatorHarness.deviceUID)
        XCTAssertEqual(device.name, "Scarlett 2i2 (Fake)")
        XCTAssertEqual(device.inputChannelCount, 4)
        XCTAssertEqual(device.outputChannelCount, 2)
        XCTAssertEqual(device.transport, .usb)
        XCTAssertEqual(device.connectionState, .connected)
        XCTAssertEqual(
            device.inputRoutes.map(\.id),
            ["channels-1-2", "channels-3-4"]
        )
        XCTAssertEqual(device.inputRoutes.map(\.channels), [[0, 1], [2, 3]])
        XCTAssertEqual(
            device.supportedSampleRates,
            [44_100, 48_000, 96_000, 192_000]
        )
        XCTAssertEqual(first.equalizer.bands.count, 10)
        XCTAssertTrue(first.equalizer.bands.allSatisfy { $0.gainDB == 0 })
    }

    func testProcessingCommandsAdvanceOnceAndRemainIdempotent() async throws {
        let harness = try CoordinatorHarness()
        let initialRevision = harness.coordinator.revision
        let desired = RemoteProcessingCommand(
            gain: 2.5,
            autoGainEnabled: true,
            enabled: true
        )

        let changed = try await harness.coordinator.applyRemoteCommand(
            .setProcessing(desired)
        )

        XCTAssertEqual(changed.revision, initialRevision + 1)
        XCTAssertEqual(changed.processing.gain, 2.5)
        XCTAssertTrue(changed.processing.autoGainEnabled)
        XCTAssertTrue(changed.processing.enabled)
        XCTAssertEqual(harness.monitor.gain, 2.5)
        XCTAssertTrue(harness.monitor.isAutoGainEnabled)

        let repeated = try await harness.coordinator.applyRemoteCommand(
            .setProcessing(desired)
        )
        XCTAssertEqual(repeated.revision, changed.revision)

        let disabled = try await harness.coordinator.applyRemoteCommand(
            .setProcessing(RemoteProcessingCommand(enabled: false))
        )
        XCTAssertEqual(disabled.revision, changed.revision + 1)
        XCTAssertFalse(disabled.processing.enabled)
        XCTAssertEqual(disabled.processing.gain, 2.5)
        XCTAssertEqual(harness.monitor.gain, 1)
        XCTAssertFalse(harness.monitor.isAutoGainEnabled)
        XCTAssertEqual(harness.monitor.eqBands, Array(repeating: 0, count: 10))

        let configuredWhileDisabled =
            try await harness.coordinator.applyRemoteCommand(
                .setProcessing(
                    RemoteProcessingCommand(
                        gain: 3.25,
                        autoGainEnabled: false
                    )
                )
            )
        XCTAssertEqual(configuredWhileDisabled.processing.gain, 3.25)
        XCTAssertEqual(harness.monitor.gain, 1)

        let reenabled = try await harness.coordinator.applyRemoteCommand(
            .setProcessing(RemoteProcessingCommand(enabled: true))
        )
        XCTAssertTrue(reenabled.processing.enabled)
        XCTAssertEqual(harness.monitor.gain, 3.25)
        XCTAssertGreaterThanOrEqual(harness.monitor.volumeUpdateCount, 5)
    }

    func testInvalidProcessingAndEqualizerCommandsAreAtomic() async throws {
        let harness = try CoordinatorHarness()
        let baseline = harness.coordinator.remoteStateSnapshot()

        let invalidGain = await captureFailure {
            try await harness.coordinator.applyRemoteCommand(
                .setProcessing(RemoteProcessingCommand(gain: .infinity))
            )
        }
        assertFailure(
            invalidGain,
            kind: .invalid,
            code: "gain_invalid"
        )

        let wrongBandCount = await captureFailure {
            try await harness.coordinator.applyRemoteCommand(
                .setEqualizer(
                    RemoteEqualizerCommand(
                        bands: [
                            RemoteEqualizerBand(
                                frequencyHz: 31,
                                gainDB: 1
                            )
                        ]
                    )
                )
            )
        }
        assertFailure(
            wrongBandCount,
            kind: .invalid,
            code: "equalizer_band_count"
        )

        var invalidBands = makeEqualizerBands()
        invalidBands[7].gainDB = 12.01
        let invalidBand = await captureFailure {
            try await harness.coordinator.applyRemoteCommand(
                .setEqualizer(
                    RemoteEqualizerCommand(
                        enabled: false,
                        bands: invalidBands
                    )
                )
            )
        }
        assertFailure(
            invalidBand,
            kind: .invalid,
            code: "equalizer_band_invalid"
        )

        let unchanged = harness.coordinator.remoteStateSnapshot()
        XCTAssertEqual(unchanged.revision, baseline.revision)
        XCTAssertEqual(unchanged.processing, baseline.processing)
        XCTAssertEqual(unchanged.equalizer, baseline.equalizer)
    }

    func testEqualizerDesiredStateIsAppliedDisabledAndReenabled()
        async throws
    {
        let harness = try CoordinatorHarness()
        let bands = makeEqualizerBands()

        let configured = try await harness.coordinator.applyRemoteCommand(
            .setEqualizer(
                RemoteEqualizerCommand(enabled: true, bands: bands)
            )
        )
        XCTAssertEqual(configured.equalizer.bands, bands)
        XCTAssertEqual(harness.monitor.eqBands, bands.map(\.gainDB))

        let repeated = try await harness.coordinator.applyRemoteCommand(
            .setEqualizer(
                RemoteEqualizerCommand(enabled: true, bands: bands)
            )
        )
        XCTAssertEqual(repeated.revision, configured.revision)

        let disabled = try await harness.coordinator.applyRemoteCommand(
            .setEqualizer(RemoteEqualizerCommand(enabled: false))
        )
        XCTAssertFalse(disabled.equalizer.enabled)
        XCTAssertEqual(disabled.equalizer.bands, bands)
        XCTAssertEqual(harness.monitor.eqBands, Array(repeating: 0, count: 10))

        let reenabled = try await harness.coordinator.applyRemoteCommand(
            .setEqualizer(RemoteEqualizerCommand(enabled: true))
        )
        XCTAssertTrue(reenabled.equalizer.enabled)
        XCTAssertEqual(harness.monitor.eqBands, bands.map(\.gainDB))
    }

    func testStableSelectionIsIdempotentAndRecordingOnlyLocksCaptureChanges()
        async throws
    {
        let harness = try CoordinatorHarness(monitoring: true)
        let analog = RemoteAudioSelection(
            inputUID: CoordinatorHarness.deviceUID,
            inputRouteID: "channels-1-2",
            outputUID: CoordinatorHarness.deviceUID
        )
        let initialRevision = harness.coordinator.revision

        let unchanged = try await harness.coordinator.applyRemoteCommand(
            .selectAudio(analog)
        )
        XCTAssertEqual(unchanged.revision, initialRevision)
        XCTAssertTrue(harness.monitor.startRequests.isEmpty)

        let loopback = RemoteAudioSelection(
            inputUID: CoordinatorHarness.deviceUID,
            inputRouteID: "channels-3-4",
            outputUID: CoordinatorHarness.deviceUID
        )
        let changed = try await harness.coordinator.applyRemoteCommand(
            .selectAudio(loopback)
        )
        XCTAssertEqual(changed.revision, initialRevision + 1)
        XCTAssertEqual(changed.selection, loopback)
        XCTAssertEqual(harness.monitor.startRequests.count, 1)
        XCTAssertEqual(harness.monitor.startRequests[0].channelMap, [2, 3])

        let repeated = try await harness.coordinator.applyRemoteCommand(
            .selectAudio(loopback)
        )
        XCTAssertEqual(repeated.revision, changed.revision)
        XCTAssertEqual(harness.monitor.startRequests.count, 1)

        harness.monitor.isRecording = true
        let inputOnly = RemoteAudioSelection(
            inputUID: CoordinatorHarness.deviceUID,
            inputRouteID: "channels-3-4",
            outputUID: nil
        )
        let outputChanged = try await harness.coordinator.applyRemoteCommand(
            .selectAudio(inputOnly)
        )
        XCTAssertEqual(outputChanged.selection, inputOnly)
        XCTAssertTrue(outputChanged.recording.enabled)
        XCTAssertEqual(harness.monitor.startRequests.count, 1)
        XCTAssertEqual(harness.monitor.clearOutputCount, 1)

        let conflict = await captureFailure {
            try await harness.coordinator.applyRemoteCommand(
                .selectAudio(analog)
            )
        }
        assertFailure(
            conflict,
            kind: .conflict,
            code: "recording_locks_capture"
        )
        let afterConflict = harness.coordinator.remoteStateSnapshot()
        XCTAssertEqual(afterConflict.revision, outputChanged.revision)
        XCTAssertEqual(afterConflict.selection, inputOnly)
        XCTAssertEqual(harness.manager.selectedInputRouteID, "channels-3-4")
    }

    func testInvalidSelectionsReturnStructuredFailuresWithoutMutation()
        async throws
    {
        let harness = try CoordinatorHarness(monitoring: true)
        let baseline = harness.coordinator.remoteStateSnapshot()
        let cases: [(RemoteAudioSelection, String)] = [
            (
                RemoteAudioSelection(
                    inputUID: "missing-input",
                    inputRouteID: "channels-1-2",
                    outputUID: CoordinatorHarness.deviceUID
                ),
                "input_device_invalid"
            ),
            (
                RemoteAudioSelection(
                    inputUID: CoordinatorHarness.deviceUID,
                    inputRouteID: "channels-9-10",
                    outputUID: CoordinatorHarness.deviceUID
                ),
                "input_route_invalid"
            ),
            (
                RemoteAudioSelection(
                    inputUID: CoordinatorHarness.deviceUID,
                    inputRouteID: "channels-1-2",
                    outputUID: "missing-output"
                ),
                "output_device_invalid"
            ),
        ]

        for (selection, code) in cases {
            let failure = await captureFailure {
                try await harness.coordinator.applyRemoteCommand(
                    .selectAudio(selection)
                )
            }
            assertFailure(failure, kind: .invalid, code: code)
        }

        let unchanged = harness.coordinator.remoteStateSnapshot()
        XCTAssertEqual(unchanged.revision, baseline.revision)
        XCTAssertEqual(unchanged.selection, baseline.selection)
        XCTAssertTrue(harness.monitor.startRequests.isEmpty)
    }

    func testMonitorRadioAndRecordingCommandsValidateThenRemainIdempotent()
        async throws
    {
        let harness = try CoordinatorHarness()

        for (command, code) in [
            (
                RemoteControlCommand.setMonitor(
                    RemoteBooleanCommand(enabled: true)
                ),
                "capture_not_running"
            ),
            (
                RemoteControlCommand.setRadio(
                    RemoteBooleanCommand(enabled: true)
                ),
                "capture_not_running"
            ),
            (
                RemoteControlCommand.setRecording(
                    RemoteBooleanCommand(enabled: true)
                ),
                "capture_not_running"
            ),
        ] {
            let failure = await captureFailure {
                try await harness.coordinator.applyRemoteCommand(command)
            }
            assertFailure(failure, kind: .unavailable, code: code)
        }

        harness.monitor.isMonitoring = true
        let monitorOn = try await harness.coordinator.applyRemoteCommand(
            .setMonitor(RemoteBooleanCommand(enabled: true))
        )
        let monitorOnAgain = try await harness.coordinator.applyRemoteCommand(
            .setMonitor(RemoteBooleanCommand(enabled: true))
        )
        XCTAssertTrue(monitorOn.monitor.enabled)
        XCTAssertEqual(monitorOnAgain.revision, monitorOn.revision)
        XCTAssertEqual(harness.monitor.enablePassthroughCount, 1)

        let radioOn = try await harness.coordinator.applyRemoteCommand(
            .setRadio(RemoteBooleanCommand(enabled: true))
        )
        let radioOnAgain = try await harness.coordinator.applyRemoteCommand(
            .setRadio(RemoteBooleanCommand(enabled: true))
        )
        XCTAssertTrue(radioOn.radio.enabled)
        XCTAssertEqual(radioOnAgain.revision, radioOn.revision)
        XCTAssertEqual(harness.monitor.startStreamingCount, 1)

        let recordingOn = try await harness.coordinator.applyRemoteCommand(
            .setRecording(RemoteBooleanCommand(enabled: true))
        )
        let recordingOnAgain =
            try await harness.coordinator.applyRemoteCommand(
                .setRecording(RemoteBooleanCommand(enabled: true))
            )
        XCTAssertTrue(recordingOn.recording.enabled)
        XCTAssertNotNil(recordingOn.recording.fileName)
        XCTAssertEqual(recordingOnAgain.revision, recordingOn.revision)
        XCTAssertEqual(harness.monitor.startRecordingCount, 1)

        let recordingOff = try await harness.coordinator.applyRemoteCommand(
            .setRecording(RemoteBooleanCommand(enabled: false))
        )
        let radioOff = try await harness.coordinator.applyRemoteCommand(
            .setRadio(RemoteBooleanCommand(enabled: false))
        )
        let monitorOff = try await harness.coordinator.applyRemoteCommand(
            .setMonitor(RemoteBooleanCommand(enabled: false))
        )
        XCTAssertFalse(recordingOff.recording.enabled)
        XCTAssertFalse(radioOff.radio.enabled)
        XCTAssertFalse(monitorOff.monitor.enabled)
        XCTAssertEqual(harness.monitor.stopRecordingCount, 1)
        XCTAssertEqual(harness.monitor.stopStreamingCount, 1)
        XCTAssertEqual(harness.monitor.disablePassthroughCount, 1)
    }

    func testMonitorRequiresAnOutputEvenWhenCaptureIsRunning() async throws {
        let harness = try CoordinatorHarness(monitoring: true)
        let inputOnly = RemoteAudioSelection(
            inputUID: CoordinatorHarness.deviceUID,
            inputRouteID: "channels-1-2",
            outputUID: nil
        )
        _ = try await harness.coordinator.applyRemoteCommand(
            .selectAudio(inputOnly)
        )

        let failure = await captureFailure {
            try await harness.coordinator.applyRemoteCommand(
                .setMonitor(RemoteBooleanCommand(enabled: true))
            )
        }

        assertFailure(failure, kind: .invalid, code: "output_required")
        XCTAssertFalse(harness.monitor.isPassthroughEnabled)
        XCTAssertEqual(harness.monitor.enablePassthroughCount, 0)
    }

    func testDisconnectFinalizesRecordingAndReconnectsUsingSavedRoute()
        async throws
    {
        let harness = try CoordinatorHarness(
            routeID: "channels-3-4",
            monitoring: true
        )
        harness.monitor.isRecording = true
        let stableSelection = try XCTUnwrap(
            harness.coordinator.remoteStateSnapshot().selection
        )

        harness.hal.setConnected(false)
        await Task.yield()
        let disconnected = try await harness.coordinator.applyRemoteCommand(
            .refreshDevices
        )

        XCTAssertEqual(disconnected.engine.phase, .disconnected)
        XCTAssertEqual(disconnected.engine.problem?.code, "input_disconnected")
        XCTAssertEqual(disconnected.selection, stableSelection)
        XCTAssertEqual(disconnected.devices.count, 1)
        XCTAssertEqual(disconnected.devices[0].connectionState, .disconnected)
        XCTAssertFalse(harness.monitor.isMonitoring)
        XCTAssertFalse(harness.monitor.isRecording)
        XCTAssertEqual(harness.monitor.stopMonitoringCount, 1)
        XCTAssertEqual(harness.monitor.stopRecordingCount, 1)

        harness.hal.setConnected(true)
        await Task.yield()
        let reconnected = try await harness.coordinator.applyRemoteCommand(
            .refreshDevices
        )

        XCTAssertEqual(reconnected.selection, stableSelection)
        XCTAssertEqual(reconnected.devices[0].connectionState, .connected)
        XCTAssertTrue(harness.monitor.isMonitoring)
        XCTAssertEqual(harness.monitor.startRequests.last?.channelMap, [2, 3])
    }

    func testNativeRouteMutationIsRolledBackWhileRecording() async throws {
        let harness = try CoordinatorHarness(
            routeID: "channels-1-2",
            monitoring: true
        )
        harness.monitor.isRecording = true
        harness.manager.selectedInputRouteID = "channels-3-4"

        let snapshot = try await harness.coordinator.applyRemoteCommand(
            .refreshDevices
        )

        XCTAssertEqual(harness.manager.selectedInputRouteID, "channels-1-2")
        XCTAssertEqual(snapshot.selection?.inputRouteID, "channels-1-2")
        XCTAssertTrue(harness.monitor.startRequests.isEmpty)
        XCTAssertTrue(harness.monitor.isRecording)
    }

    func testCoreAudioNumericIDChangeDoesNotChangePublicSelectionOrRevision()
        async throws
    {
        let preferences = InMemoryAudioDevicePreferences()
        let hal = MutableStableUIDHAL(deviceID: 101)
        let manager = AudioDeviceManager(
            hal: hal,
            preferences: preferences
        )
        manager.selectedInputDeviceID = try XCTUnwrap(
            manager.selectedInputDeviceID
        )
        manager.selectedOutputDeviceID = try XCTUnwrap(
            manager.selectedOutputDeviceID
        )
        manager.selectedInputRouteID = "channels-3-4"
        let monitor = CoordinatorAudioMonitor()
        monitor.isMonitoring = true
        let coordinator = AppCoordinator(
            audioManager: manager,
            audioMonitor: monitor,
            settings: makeIsolatedAppSettings()
        )
        let before = coordinator.remoteStateSnapshot()

        hal.setDeviceID(9_999)
        let after = try await coordinator.applyRemoteCommand(.refreshDevices)

        XCTAssertEqual(manager.selectedInputDeviceID, 9_999)
        XCTAssertEqual(manager.selectedOutputDeviceID, 9_999)
        XCTAssertEqual(after.selection, before.selection)
        XCTAssertEqual(after.devices, before.devices)
        XCTAssertEqual(after.revision, before.revision)
        XCTAssertEqual(monitor.startRequests.count, 1)
        XCTAssertEqual(monitor.startRequests.last?.deviceID, 9_999)
        XCTAssertEqual(monitor.startRequests.last?.outputDeviceID, 9_999)
        XCTAssertEqual(monitor.startRequests.last?.channelMap, [2, 3])
    }

    func testReconnectGenerationRebindsEvenWhenNumericIDIsReused()
        async throws
    {
        let hal = MutableStableUIDHAL(deviceID: 101)
        let manager = AudioDeviceManager(
            hal: hal,
            preferences: InMemoryAudioDevicePreferences()
        )
        manager.selectedInputDeviceID = try XCTUnwrap(
            manager.selectedInputDeviceID
        )
        manager.selectedOutputDeviceID = try XCTUnwrap(
            manager.selectedOutputDeviceID
        )
        let monitor = CoordinatorAudioMonitor()
        monitor.isMonitoring = true
        let coordinator = AppCoordinator(
            audioManager: manager,
            audioMonitor: monitor,
            settings: makeIsolatedAppSettings()
        )

        hal.setAlive(false)
        try manager.refreshDevices()
        hal.setAlive(true)
        try manager.refreshDevices()
        _ = try await coordinator.applyRemoteCommand(.refreshDevices)

        XCTAssertEqual(monitor.startRequests.count, 1)
        XCTAssertEqual(monitor.startRequests[0].deviceID, 101)
        XCTAssertEqual(monitor.startRequests[0].outputDeviceID, 101)
    }

    func testIdempotentCommandCannotMaskPendingNumericIDRebind()
        async throws
    {
        let hal = MutableStableUIDHAL(deviceID: 101)
        let manager = AudioDeviceManager(
            hal: hal,
            preferences: InMemoryAudioDevicePreferences()
        )
        manager.selectedInputDeviceID = try XCTUnwrap(
            manager.selectedInputDeviceID
        )
        manager.selectedOutputDeviceID = try XCTUnwrap(
            manager.selectedOutputDeviceID
        )
        let monitor = CoordinatorAudioMonitor()
        monitor.isMonitoring = true
        let coordinator = AppCoordinator(
            audioManager: manager,
            audioMonitor: monitor,
            settings: makeIsolatedAppSettings()
        )
        let selection = try XCTUnwrap(
            coordinator.remoteStateSnapshot().selection
        )

        hal.setDeviceID(9_999)
        try manager.refreshDevices()
        _ = try await coordinator.applyRemoteCommand(
            .selectAudio(selection)
        )

        XCTAssertEqual(monitor.startRequests.count, 1)
        XCTAssertEqual(monitor.startRequests[0].deviceID, 9_999)
        XCTAssertEqual(monitor.startRequests[0].outputDeviceID, 9_999)
    }

    func testOutputOnlyGenerationChangeDoesNotRestartCaptureOrRecording()
        async throws
    {
        let hal = MutableStableUIDHAL(deviceID: 101)
        let manager = AudioDeviceManager(
            hal: hal,
            preferences: InMemoryAudioDevicePreferences()
        )
        manager.selectedInputDeviceID = try XCTUnwrap(
            manager.selectedInputDeviceID
        )
        manager.selectedOutputDeviceID = try XCTUnwrap(
            manager.selectedOutputDeviceID
        )
        let monitor = CoordinatorAudioMonitor()
        monitor.isMonitoring = true
        monitor.isRecording = true
        let coordinator = AppCoordinator(
            audioManager: manager,
            audioMonitor: monitor,
            settings: makeIsolatedAppSettings()
        )

        hal.setOutputChannelCount(4)
        _ = try await coordinator.applyRemoteCommand(.refreshDevices)

        XCTAssertTrue(monitor.startRequests.isEmpty)
        XCTAssertEqual(monitor.outputUpdates, [101])
        XCTAssertTrue(monitor.isRecording)
        XCTAssertEqual(monitor.stopRecordingCount, 0)
    }

    func testAliveFalseFinalizesRecordingAndReportsDisconnected()
        async throws
    {
        let hal = MutableStableUIDHAL(deviceID: 101)
        let manager = AudioDeviceManager(
            hal: hal,
            preferences: InMemoryAudioDevicePreferences()
        )
        manager.selectedInputDeviceID = try XCTUnwrap(
            manager.selectedInputDeviceID
        )
        let monitor = CoordinatorAudioMonitor()
        monitor.isMonitoring = true
        monitor.isRecording = true
        let coordinator = AppCoordinator(
            audioManager: manager,
            audioMonitor: monitor,
            settings: makeIsolatedAppSettings()
        )

        hal.setAlive(false)
        let snapshot = try await coordinator.applyRemoteCommand(
            .refreshDevices
        )

        XCTAssertEqual(snapshot.engine.phase, .disconnected)
        XCTAssertEqual(snapshot.engine.problem?.code, "input_disconnected")
        XCTAssertFalse(monitor.isMonitoring)
        XCTAssertFalse(monitor.isRecording)
        XCTAssertEqual(monitor.stopRecordingCount, 1)
    }

    func testFailedRecordingSelectionRestoreFinalizesCapture()
        async throws
    {
        let hal = SwitchingDefaultHAL()
        let manager = AudioDeviceManager(
            hal: hal,
            preferences: InMemoryAudioDevicePreferences()
        )
        let monitor = CoordinatorAudioMonitor()
        monitor.isMonitoring = true
        monitor.isRecording = true
        let coordinator = AppCoordinator(
            audioManager: manager,
            audioMonitor: monitor,
            settings: makeIsolatedAppSettings()
        )

        hal.removeOriginalDefault()
        let snapshot = try await coordinator.applyRemoteCommand(
            .refreshDevices
        )

        XCTAssertNil(manager.selectedInputDevice)
        XCTAssertEqual(manager.savedInputUID, "original-device")
        XCTAssertEqual(
            manager.inputSelectionPreference,
            .device(uid: "original-device")
        )
        XCTAssertEqual(snapshot.engine.phase, .disconnected)
        XCTAssertEqual(snapshot.selection?.inputUID, "original-device")
        XCTAssertFalse(monitor.isMonitoring)
        XCTAssertFalse(monitor.isRecording)
        XCTAssertEqual(monitor.stopMonitoringCount, 1)
        XCTAssertEqual(monitor.stopRecordingCount, 1)
    }

    func testSoleSystemDefaultUnplugPinsDisconnectedRecordingDevice()
        async throws
    {
        let hal = MutableStableUIDHAL(deviceID: 101)
        let manager = AudioDeviceManager(
            hal: hal,
            preferences: InMemoryAudioDevicePreferences()
        )
        let monitor = CoordinatorAudioMonitor()
        monitor.isMonitoring = true
        monitor.isRecording = true
        let coordinator = AppCoordinator(
            audioManager: manager,
            audioMonitor: monitor,
            settings: makeIsolatedAppSettings()
        )

        hal.setPresent(false)
        let snapshot = try await coordinator.applyRemoteCommand(
            .refreshDevices
        )

        XCTAssertEqual(snapshot.engine.phase, .disconnected)
        XCTAssertEqual(snapshot.selection?.inputUID, "stable-focusrite-uid")
        XCTAssertEqual(
            manager.inputSelectionPreference,
            .device(uid: "stable-focusrite-uid")
        )
        XCTAssertFalse(monitor.isRecording)
        XCTAssertEqual(monitor.stopRecordingCount, 1)
    }

    func testRemoteDeviceRefreshFailureIsUnavailableAndPreservesState()
        async throws
    {
        let hal = MutableStableUIDHAL(deviceID: 101)
        let manager = AudioDeviceManager(
            hal: hal,
            preferences: InMemoryAudioDevicePreferences()
        )
        let coordinator = AppCoordinator(
            audioManager: manager,
            audioMonitor: CoordinatorAudioMonitor(),
            settings: makeIsolatedAppSettings()
        )
        let before = coordinator.remoteStateSnapshot()

        hal.setDiscoveryFailure("HAL temporarily unavailable")
        let failure = await captureFailure {
            try await coordinator.applyRemoteCommand(.refreshDevices)
        }

        assertFailure(
            failure,
            kind: .unavailable,
            code: "device_discovery_failed"
        )
        XCTAssertEqual(failure?.detail, "HAL temporarily unavailable")
        XCTAssertEqual(manager.lastDiscoveryError, "HAL temporarily unavailable")
        var after = coordinator.remoteStateSnapshot()
        after.generatedAt = before.generatedAt
        XCTAssertEqual(after, before)
    }

    func testNativeCommandSurfaceUsesTheSameValidatedAuthority() throws {
        let harness = try CoordinatorHarness(monitoring: true)

        XCTAssertFalse(
            harness.coordinator.selectNativeInputDevice(uid: "missing")
        )
        XCTAssertEqual(
            harness.coordinator.nativeCommandError,
            "The selected input device is not connected."
        )

        XCTAssertTrue(
            harness.coordinator.selectNativeInputDevice(
                uid: CoordinatorHarness.deviceUID
            )
        )
        XCTAssertNil(harness.coordinator.nativeCommandError)
        XCTAssertTrue(
            harness.coordinator.selectNativeInputRoute(id: "channels-3-4")
        )
        XCTAssertEqual(
            harness.manager.selectedInputRouteID,
            "channels-3-4"
        )

        XCTAssertTrue(harness.coordinator.setNativeGain(1.75))
        XCTAssertTrue(
            harness.coordinator.setNativeAutoGainEnabled(true)
        )
        XCTAssertEqual(harness.monitor.gain, 1.75)
        XCTAssertTrue(harness.monitor.isAutoGainEnabled)

        XCTAssertFalse(
            harness.coordinator.setNativeEqualizerBands([1, 2])
        )
        XCTAssertEqual(
            harness.coordinator.nativeCommandError,
            "The equalizer requires exactly ten bands."
        )
        let gains = (0..<10).map { Float($0) - 4.5 }
        XCTAssertTrue(
            harness.coordinator.setNativeEqualizerBands(gains)
        )
        XCTAssertEqual(harness.monitor.eqBands, gains)

        XCTAssertTrue(
            harness.coordinator.setNativeMonitorEnabled(true)
        )
        XCTAssertTrue(harness.coordinator.setNativeRadioEnabled(true))
        XCTAssertTrue(
            harness.coordinator.setNativeRecordingEnabled(true)
        )
        XCTAssertTrue(harness.monitor.isPassthroughEnabled)
        XCTAssertTrue(harness.monitor.isStreamingEnabled)
        XCTAssertTrue(harness.monitor.isRecording)

        XCTAssertFalse(
            harness.coordinator.selectNativeInputRoute(id: "channels-1-2")
        )
        XCTAssertTrue(
            harness.coordinator.nativeCommandError?.contains(
                "Stop recording"
            ) == true
        )
        XCTAssertFalse(
            harness.coordinator.selectNativeInputDevice(uid: nil)
        )
        XCTAssertTrue(
            harness.coordinator.nativeCommandError?.contains(
                "Stop recording"
            ) == true
        )

        XCTAssertTrue(
            harness.coordinator.setNativeRecordingEnabled(false)
        )
        XCTAssertTrue(harness.coordinator.setNativeRadioEnabled(false))
        XCTAssertTrue(
            harness.coordinator.setNativeMonitorEnabled(false)
        )
        XCTAssertTrue(
            harness.coordinator.selectNativeInputDevice(uid: nil)
        )
        XCTAssertNil(harness.manager.selectedInputDeviceID)
        XCTAssertFalse(harness.monitor.isMonitoring)

        XCTAssertFalse(
            harness.coordinator.selectNativeInputRoute(id: nil)
        )
        XCTAssertEqual(
            harness.coordinator.nativeCommandError,
            "Select an input device before choosing a channel route."
        )
        XCTAssertTrue(
            harness.coordinator.selectNativeOutputDevice(uid: nil)
        )
        XCTAssertNil(harness.manager.selectedOutputDeviceID)
        XCTAssertTrue(
            harness.coordinator.selectNativeOutputDevice(
                uid: CoordinatorHarness.deviceUID
            )
        )
        XCTAssertNotNil(harness.manager.selectedOutputDeviceID)

        XCTAssertTrue(
            harness.coordinator.selectNativeInputDevice(
                uid: CoordinatorHarness.deviceUID
            )
        )
        XCTAssertTrue(harness.monitor.isMonitoring)
        XCTAssertEqual(
            harness.coordinator.remoteStateSnapshot().selection?.inputUID,
            CoordinatorHarness.deviceUID
        )
    }

    func testNativePreparationRefreshesAndStartsThePersistedRoute() throws {
        let harness = try CoordinatorHarness()

        harness.coordinator.prepareNativeInterface()

        XCTAssertTrue(harness.monitor.isMeteringEnabled)
        XCTAssertTrue(harness.manager.microphonePermissionGranted)
        XCTAssertTrue(harness.monitor.isMonitoring)
        XCTAssertEqual(harness.monitor.startRequests.count, 1)
        XCTAssertEqual(
            harness.monitor.startRequests.first?.channelMap,
            [0, 1]
        )
        XCTAssertTrue(harness.coordinator.refreshNativeAudioDevices())
        XCTAssertNil(harness.coordinator.nativeCommandError)

        XCTAssertFalse(
            harness.coordinator.selectNativeInputRoute(
                id: "channels-9-10"
            )
        )
        XCTAssertEqual(
            harness.coordinator.nativeCommandError,
            "The selected input route is no longer available."
        )
        XCTAssertFalse(
            harness.coordinator.selectNativeOutputDevice(uid: "missing")
        )
        XCTAssertEqual(
            harness.coordinator.nativeCommandError,
            "The selected output device is not connected."
        )

        harness.coordinator.requestNativeMicrophoneAccess()
        XCTAssertNil(harness.coordinator.nativeCommandError)
        XCTAssertTrue(harness.manager.microphonePermissionGranted)

        // Both are safe no-ops before application activation.
        harness.coordinator.retryRemoteAccess()
        harness.coordinator.shutdown()
    }

    func testNativeVisualizationDemandRequiresVisibleAdvancedInterface()
        throws
    {
        let harness = try CoordinatorHarness(monitoring: true)

        harness.coordinator.setNativeInterfaceVisible(true)
        XCTAssertEqual(harness.monitor.pauseVisualizationsCount, 1)
        XCTAssertEqual(harness.monitor.resumeVisualizationsCount, 0)
        XCTAssertEqual(harness.monitor.startUIUpdateTimerCount, 1)
        XCTAssertTrue(harness.monitor.visualizationsPaused)
        XCTAssertFalse(harness.monitor.spectrogramEnabled)

        harness.coordinator.setNativeAdvancedVisualizationsVisible(true)
        XCTAssertEqual(harness.monitor.resumeVisualizationsCount, 1)
        XCTAssertFalse(harness.monitor.visualizationsPaused)
        XCTAssertTrue(harness.monitor.spectrogramEnabled)

        harness.coordinator.setNativeAdvancedVisualizationsVisible(true)
        harness.coordinator.setNativeInterfaceVisible(true)
        XCTAssertEqual(harness.monitor.resumeVisualizationsCount, 1)
        XCTAssertEqual(harness.monitor.startUIUpdateTimerCount, 1)

        harness.coordinator.setNativeInterfaceVisible(false)
        XCTAssertEqual(harness.monitor.pauseVisualizationsCount, 2)
        XCTAssertTrue(harness.monitor.visualizationsPaused)
        XCTAssertFalse(harness.monitor.spectrogramEnabled)

        harness.coordinator.setNativeAdvancedVisualizationsVisible(false)
        XCTAssertEqual(harness.monitor.pauseVisualizationsCount, 2)
    }

    func testNativeCaptureFailureRestoresPreviousSelectionAndServices()
        throws
    {
        let harness = try CoordinatorHarness(monitoring: true)
        harness.monitor.isPassthroughEnabled = true
        harness.monitor.isStreamingEnabled = true
        harness.monitor.captureStartsToFail = 1
        let before = harness.coordinator.remoteStateSnapshot()

        XCTAssertFalse(
            harness.coordinator.selectNativeInputRoute(id: "channels-3-4")
        )

        let after = harness.coordinator.remoteStateSnapshot()
        XCTAssertEqual(after.selection, before.selection)
        XCTAssertEqual(after.revision, before.revision)
        XCTAssertEqual(
            harness.manager.selectedInputRouteID,
            "channels-1-2"
        )
        XCTAssertEqual(harness.monitor.startRequests.count, 2)
        XCTAssertEqual(
            harness.monitor.startRequests.map(\.channelMap),
            [[2, 3], [0, 1]]
        )
        XCTAssertTrue(harness.monitor.isMonitoring)
        XCTAssertTrue(harness.monitor.isPassthroughEnabled)
        XCTAssertTrue(harness.monitor.isStreamingEnabled)
        XCTAssertEqual(harness.monitor.enablePassthroughCount, 1)
        XCTAssertEqual(harness.monitor.startStreamingCount, 1)
        XCTAssertEqual(
            harness.coordinator.nativeCommandError,
            "Core Audio could not start the selected input."
        )
    }

    func testNativeServiceStartFailuresAreActionableAndDoNotCommitState()
        throws
    {
        let harness = try CoordinatorHarness(monitoring: true)
        let baselineRevision = harness.coordinator.revision

        harness.monitor.failPassthroughStart = true
        XCTAssertFalse(
            harness.coordinator.setNativeMonitorEnabled(true)
        )
        XCTAssertEqual(
            harness.coordinator.nativeCommandError,
            "Core Audio could not start output monitoring."
        )
        XCTAssertFalse(harness.monitor.isPassthroughEnabled)

        harness.monitor.failStreamingStart = true
        XCTAssertFalse(harness.coordinator.setNativeRadioEnabled(true))
        XCTAssertEqual(
            harness.coordinator.nativeCommandError,
            "The legacy Radio listener could not bind to its configured port."
        )
        XCTAssertFalse(harness.monitor.isStreamingEnabled)

        harness.monitor.failRecordingStart = true
        XCTAssertFalse(
            harness.coordinator.setNativeRecordingEnabled(true)
        )
        XCTAssertEqual(
            harness.coordinator.nativeCommandError,
            "PhonoFlow could not create a recording file."
        )
        XCTAssertFalse(harness.monitor.isRecording)
        XCTAssertEqual(harness.coordinator.revision, baselineRevision)
    }

    func testPairingCodeRequiresRunningRemoteAccess() async throws {
        let harness = try CoordinatorHarness()

        do {
            _ = try await harness.coordinator.issuePairingCode()
            XCTFail("Expected disabled Remote Access to reject pairing")
        } catch let failure as RemoteControlFailure {
            assertFailure(
                failure,
                kind: .unavailable,
                code: "remote_access_not_running"
            )
        }

        XCTAssertNil(harness.coordinator.pairingCode)
        XCTAssertNil(harness.coordinator.remoteAccessURL)
        XCTAssertEqual(harness.coordinator.remoteAccessStatusText, "Off")
        XCTAssertEqual(
            harness.coordinator.remoteAccessError,
            "Enable Remote Access before creating a pairing code."
        )
    }

    func testInitialSnapshotNormalizesExternalDSPAndMeterValues() throws {
        let hal = FakeCoreAudioHAL()
        let manager = AudioDeviceManager(
            hal: hal,
            preferences: InMemoryAudioDevicePreferences()
        )
        let monitor = CoordinatorAudioMonitor()
        monitor.eqBands = [.nan, 24, -24]
        monitor.leftLevel = -1
        monitor.rightLevel = 2
        monitor.peakLevel = .nan
        let coordinator = AppCoordinator(
            audioManager: manager,
            audioMonitor: monitor,
            settings: makeIsolatedAppSettings()
        )

        let snapshot = coordinator.remoteStateSnapshot()

        XCTAssertEqual(
            snapshot.equalizer.bands.map(\.gainDB),
            [0, 12, -12, 0, 0, 0, 0, 0, 0, 0]
        )
        XCTAssertEqual(snapshot.meters.left, 0)
        XCTAssertEqual(snapshot.meters.right, 1)
        XCTAssertEqual(snapshot.meters.peak, 0)
    }

    private func makeEqualizerBands() -> [RemoteEqualizerBand] {
        let frequencies: [Float] = [
            31, 62, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000,
        ]
        return frequencies.enumerated().map { index, frequency in
            RemoteEqualizerBand(
                frequencyHz: frequency,
                gainDB: Float(index) - 4.5
            )
        }
    }

    private func captureFailure(
        _ operation: () async throws -> RemoteStateSnapshot
    ) async -> RemoteControlFailure? {
        do {
            _ = try await operation()
            XCTFail("Expected a RemoteControlFailure")
            return nil
        } catch let failure as RemoteControlFailure {
            return failure
        } catch {
            XCTFail("Expected RemoteControlFailure, received \(error)")
            return nil
        }
    }

    private func assertFailure(
        _ failure: RemoteControlFailure?,
        kind: RemoteControlFailure.Kind,
        code: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let failure else {
            XCTFail("Expected failure", file: file, line: line)
            return
        }
        XCTAssertTrue(
            failure.kind.matches(kind),
            "Expected \(kind), received \(failure.kind)",
            file: file,
            line: line
        )
        XCTAssertEqual(failure.code, code, file: file, line: line)
        XCTAssertFalse(failure.detail.isEmpty, file: file, line: line)
    }
}

@MainActor
private struct CoordinatorHarness {
    static let deviceUID = "com.phonoflow.fake.scarlett-2i2"

    let hal: FakeCoreAudioHAL
    let manager: AudioDeviceManager
    let monitor: CoordinatorAudioMonitor
    let coordinator: AppCoordinator

    init(
        routeID: String = "channels-1-2",
        monitoring: Bool = false
    ) throws {
        let hal = FakeCoreAudioHAL()
        let manager = AudioDeviceManager(
            hal: hal,
            preferences: InMemoryAudioDevicePreferences()
        )
        manager.selectedInputDeviceID = try XCTUnwrap(
            manager.selectedInputDeviceID
        )
        manager.selectedOutputDeviceID = try XCTUnwrap(
            manager.selectedOutputDeviceID
        )
        manager.selectedInputRouteID = routeID

        let monitor = CoordinatorAudioMonitor()
        monitor.isMonitoring = monitoring

        self.hal = hal
        self.manager = manager
        self.monitor = monitor
        coordinator = AppCoordinator(
            audioManager: manager,
            audioMonitor: monitor,
            settings: makeIsolatedAppSettings()
        )
    }
}

@MainActor
private func makeIsolatedAppSettings() -> AppSettings {
    let suiteName = "com.wasinuddy.PhonoFlow.AppCoordinatorTests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        preconditionFailure("Could not create isolated UserDefaults suite")
    }
    defaults.removePersistentDomain(forName: suiteName)
    return AppSettings(defaults: defaults)
}

@MainActor
private final class CoordinatorAudioMonitor: AudioMonitor {
    struct StartRequest: Equatable {
        let deviceID: AudioDeviceID
        let outputDeviceID: AudioDeviceID?
        let channelMap: [Int32]
    }

    private(set) var startRequests: [StartRequest] = []
    private(set) var stopMonitoringCount = 0
    private(set) var clearSpectrogramCount = 0
    private(set) var enablePassthroughCount = 0
    private(set) var disablePassthroughCount = 0
    private(set) var outputUpdates: [AudioDeviceID] = []
    private(set) var clearOutputCount = 0
    private(set) var volumeUpdateCount = 0
    private(set) var startStreamingCount = 0
    private(set) var stopStreamingCount = 0
    private(set) var startRecordingCount = 0
    private(set) var stopRecordingCount = 0
    private(set) var pauseVisualizationsCount = 0
    private(set) var resumeVisualizationsCount = 0
    private(set) var startUIUpdateTimerCount = 0
    var captureStartsToFail = 0
    var failPassthroughStart = false
    var failStreamingStart = false
    var failRecordingStart = false

    override func startMonitoring(
        deviceID: AudioDeviceID,
        outputDeviceID: AudioDeviceID?,
        inputChannelMap: [Int32] = [0, 1]
    ) {
        startRequests.append(
            StartRequest(
                deviceID: deviceID,
                outputDeviceID: outputDeviceID,
                channelMap: inputChannelMap
            )
        )
        isPassthroughEnabled = false
        isStreamingEnabled = false
        if captureStartsToFail > 0 {
            captureStartsToFail -= 1
            isMonitoring = false
        } else {
            isMonitoring = true
        }
    }

    override func stopMonitoring() {
        stopMonitoringCount += 1
        if isRecording {
            _ = stopRecording()
        }
        isMonitoring = false
        isPassthroughEnabled = false
        isStreamingEnabled = false
    }

    override func clearSpectrogram() {
        clearSpectrogramCount += 1
    }

    override func enablePassthrough() {
        enablePassthroughCount += 1
        isPassthroughEnabled =
            isMonitoring && !failPassthroughStart
    }

    override func disablePassthrough() {
        disablePassthroughCount += 1
        isPassthroughEnabled = false
    }

    override func updatePassthroughOutput(deviceID: AudioDeviceID) {
        outputUpdates.append(deviceID)
    }

    override func clearPassthroughOutput() {
        clearOutputCount += 1
        isPassthroughEnabled = false
    }

    override func updatePassthroughVolume() {
        volumeUpdateCount += 1
    }

    override func startStreaming(
        port: UInt16 = 7865,
        allowedHosts: [String] = []
    ) {
        _ = port
        _ = allowedHosts
        startStreamingCount += 1
        isStreamingEnabled =
            isMonitoring && !failStreamingStart
    }

    override func stopStreaming() {
        stopStreamingCount += 1
        isStreamingEnabled = false
    }

    override func startRecording() {
        startRecordingCount += 1
        guard isMonitoring, !failRecordingStart else {
            isRecording = false
            return
        }
        isRecording = true
        recordingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("coordinator-test.wav")
    }

    override func stopRecording() -> AudioRecorder.TerminalResult? {
        stopRecordingCount += 1
        isRecording = false
        return nil
    }

    override func pauseVisualizations() {
        pauseVisualizationsCount += 1
        visualizationsPaused = true
        spectrogramEnabled = false
    }

    override func resumeVisualizations() {
        resumeVisualizationsCount += 1
        visualizationsPaused = false
        spectrogramEnabled = true
    }

    override func startUIUpdateTimer() {
        startUIUpdateTimerCount += 1
    }
}

nonisolated extension RemoteControlFailure.Kind {
    fileprivate func matches(_ other: Self) -> Bool {
        switch (self, other) {
        case (.conflict, .conflict),
            (.invalid, .invalid),
            (.unavailable, .unavailable),
            (.forbidden, .forbidden):
            return true
        default:
            return false
        }
    }
}

nonisolated private final class MutableStableUIDHAL:
    CoreAudioHAL,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var currentDeviceID: AudioDeviceID
    private var discoveryFailure: String?
    private var alive = true
    private var outputChannelCount = 2
    private var isPresent = true

    init(deviceID: AudioDeviceID) {
        currentDeviceID = deviceID
    }

    var bypassesMicrophonePermission: Bool { true }

    func setDeviceID(_ deviceID: AudioDeviceID) {
        lock.lock()
        currentDeviceID = deviceID
        lock.unlock()
    }

    func setDiscoveryFailure(_ detail: String?) {
        lock.lock()
        discoveryFailure = detail
        lock.unlock()
    }

    func setAlive(_ alive: Bool) {
        lock.lock()
        self.alive = alive
        lock.unlock()
    }

    func setOutputChannelCount(_ count: Int) {
        lock.lock()
        outputChannelCount = count
        lock.unlock()
    }

    func setPresent(_ present: Bool) {
        lock.lock()
        isPresent = present
        lock.unlock()
    }

    func devices() throws -> [CoreAudioHALDevice] {
        lock.lock()
        let deviceID = currentDeviceID
        let discoveryFailure = discoveryFailure
        let alive = alive
        let outputChannelCount = outputChannelCount
        let isPresent = isPresent
        lock.unlock()
        if let discoveryFailure {
            throw MutableStableUIDHALError(detail: discoveryFailure)
        }
        guard isPresent else { return [] }
        return [
            CoreAudioHALDevice(
                id: deviceID,
                uid: "stable-focusrite-uid",
                name: "Fixture Scarlett",
                inputChannelCount: 4,
                outputChannelCount: outputChannelCount,
                inputChannelNames: [
                    "Analog 1",
                    "Analog 2",
                    "Loopback 1",
                    "Loopback 2",
                ],
                nominalSampleRate: 48_000,
                availableSampleRates: [
                    AudioSampleRateRange(
                        minimum: 48_000,
                        maximum: 48_000
                    )
                ],
                bufferFrameRange: 32...1_024,
                transport: .usb,
                isAlive: alive
            )
        ]
    }

    func defaultInputDeviceID() throws -> AudioDeviceID? {
        lock.lock()
        defer { lock.unlock() }
        return isPresent ? currentDeviceID : nil
    }

    func defaultOutputDeviceID() throws -> AudioDeviceID? {
        try defaultInputDeviceID()
    }

    func observeDeviceList(
        _ observer: @escaping @Sendable () -> Void
    ) throws -> any CoreAudioHALListener {
        _ = observer
        return CoordinatorNoopHALListener()
    }

    func observeAlive(
        deviceID: AudioDeviceID,
        _ observer: @escaping @Sendable () -> Void
    ) throws -> any CoreAudioHALListener {
        _ = deviceID
        _ = observer
        return CoordinatorNoopHALListener()
    }

}

nonisolated private final class SwitchingDefaultHAL:
    CoreAudioHAL,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var originalIsPresent = true

    var bypassesMicrophonePermission: Bool { true }

    func removeOriginalDefault() {
        lock.lock()
        originalIsPresent = false
        lock.unlock()
    }

    func devices() throws -> [CoreAudioHALDevice] {
        lock.lock()
        let originalIsPresent = originalIsPresent
        lock.unlock()

        var devices = [
            Self.device(
                id: 202,
                uid: "fallback-device",
                name: "Fallback Device"
            )
        ]
        if originalIsPresent {
            devices.append(
                Self.device(
                    id: 101,
                    uid: "original-device",
                    name: "Original Device"
                )
            )
        }
        return devices
    }

    func defaultInputDeviceID() throws -> AudioDeviceID? {
        lock.lock()
        defer { lock.unlock() }
        return originalIsPresent ? 101 : 202
    }

    func defaultOutputDeviceID() throws -> AudioDeviceID? {
        try defaultInputDeviceID()
    }

    func observeDeviceList(
        _ observer: @escaping @Sendable () -> Void
    ) throws -> any CoreAudioHALListener {
        _ = observer
        return CoordinatorNoopHALListener()
    }

    func observeAlive(
        deviceID: AudioDeviceID,
        _ observer: @escaping @Sendable () -> Void
    ) throws -> any CoreAudioHALListener {
        _ = deviceID
        _ = observer
        return CoordinatorNoopHALListener()
    }

    private static func device(
        id: AudioDeviceID,
        uid: String,
        name: String
    ) -> CoreAudioHALDevice {
        CoreAudioHALDevice(
            id: id,
            uid: uid,
            name: name,
            inputChannelCount: 2,
            outputChannelCount: 2,
            inputChannelNames: ["Input 1", "Input 2"],
            nominalSampleRate: 48_000,
            availableSampleRates: [
                AudioSampleRateRange(minimum: 48_000, maximum: 48_000)
            ],
            bufferFrameRange: 32...1_024,
            transport: .usb,
            isAlive: true
        )
    }
}

nonisolated private struct MutableStableUIDHALError: LocalizedError {
    let detail: String

    var errorDescription: String? { detail }
}

nonisolated private final class CoordinatorNoopHALListener:
    CoreAudioHALListener,
    @unchecked Sendable
{
    func cancel() {}
}
