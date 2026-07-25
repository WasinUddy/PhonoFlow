import AudioToolbox
import CoreAudio
import Foundation
import XCTest

@testable import PhonoFlow

/// Exercises coordinator-owned lifecycle transitions that are intentionally
/// absent from the smaller command-surface tests. Listener lifecycles use
/// injected in-memory transports; the loopback ports are identifiers only.
@MainActor
final class AppCoordinatorLifecycleCoverageTests: XCTestCase {
    func testPairedAccessStartsReconfiguresDisablesAndShutsDownCleanly()
        async throws
    {
        let port: UInt16 = 19_201
        let harness = LifecycleCoordinatorHarness()
        addTeardownBlock { @MainActor [harness] in
            await harness.shutdownAndWait()
        }
        harness.settings.remoteAccessPort = port
        harness.settings.radioPort = 19_202
        harness.settings.remoteAccessEnabled = true
        harness.settings.allowLegacyUnauthenticatedStream = false

        harness.coordinator.activate()
        await assertCoordinatorState {
            if case .running(_, let runningPort) =
                harness.coordinator.remoteAccessState
            {
                return runningPort == port
            }
            return false
        }
        XCTAssertEqual(harness.monitor.remoteAttachURLs.count, 1)
        XCTAssertEqual(
            harness.coordinator.remoteAccessURL?.host,
            "127.0.0.1"
        )
        XCTAssertTrue(
            harness.coordinator.remoteAccessStatusText.contains(
                String(port)
            )
        )

        // Repeated activation while active is a deliberate no-op.
        harness.coordinator.activate()
        harness.coordinator.activate()
        XCTAssertEqual(harness.monitor.remoteAttachURLs.count, 1)

        let pairing = try await harness.coordinator.issuePairingCode()
        XCTAssertEqual(pairing.code.count, 6)
        XCTAssertEqual(harness.coordinator.pairingCode, pairing)
        try await harness.coordinator.revokeAllBrowsers()
        XCTAssertNil(harness.coordinator.pairingCode)
        XCTAssertEqual(
            harness.coordinator.listenerCounts,
            RemoteListenerCounts(eventStreams: 0, audioStreams: 0)
        )

        // Changing the configured source policy forces an orderly stop/start
        // without touching the capture engine.
        harness.settings.allowedHosts = ["127.0.0.1"]
        await assertCoordinatorState {
            harness.monitor.remoteAttachURLs.count >= 2
                && harness.monitor.remoteDetachCount >= 1
        }
        XCTAssertTrue(harness.monitor.isMonitoring)

        harness.settings.remoteAccessEnabled = false
        await assertCoordinatorState {
            harness.coordinator.remoteAccessState == .disabled
        }
        XCTAssertNil(harness.coordinator.remoteEndpoint)
        XCTAssertNil(harness.coordinator.pairingCode)
        XCTAssertNil(harness.coordinator.remoteAccessError)
        XCTAssertGreaterThanOrEqual(harness.monitor.remoteDetachCount, 2)
        XCTAssertFalse(harness.monitor.remoteSpectrumVisible)
        XCTAssertFalse(harness.monitor.remoteAudioVisible)

        harness.coordinator.shutdown()
        XCTAssertEqual(harness.coordinator.remoteAccessState, .stopping)
        XCTAssertEqual(harness.coordinator.legacyStreamState, .stopping)
        XCTAssertEqual(harness.coordinator.remoteAccessStatusText, "Stopping")
        XCTAssertNil(harness.coordinator.remoteEndpoint)
        XCTAssertNil(harness.coordinator.legacyStreamEndpoint)
        XCTAssertEqual(
            harness.coordinator.listenerCounts,
            RemoteListenerCounts(eventStreams: 0, audioStreams: 0)
        )
        await assertCoordinatorState {
            harness.coordinator.remoteAccessState == .disabled
                && harness.coordinator.legacyStreamState == .disabled
        }
        XCTAssertNil(harness.coordinator.remoteAccessError)
        XCTAssertNil(harness.coordinator.legacyStreamError)
        XCTAssertEqual(harness.monitor.stopMonitoringCount, 1)

        // Repeated lifecycle commands are deliberate no-ops.
        await harness.shutdownAndWait()
    }

    func testDedicatedLegacyListenerReconfiguresStopsAndRestarts()
        async
    {
        let remotePort: UInt16 = 19_211
        let firstRadioPort: UInt16 = 19_212
        let secondRadioPort: UInt16 = 19_213
        let harness = LifecycleCoordinatorHarness(streaming: true)
        addTeardownBlock { @MainActor [harness] in
            await harness.shutdownAndWait()
        }
        harness.settings.remoteAccessEnabled = false
        harness.settings.remoteAccessPort = remotePort
        harness.settings.radioPort = firstRadioPort
        harness.settings.allowedHosts = []
        harness.settings.allowLegacyUnauthenticatedStream = true

        harness.coordinator.activate()
        await assertCoordinatorState {
            harness.coordinator.legacyStreamEndpoint?.port
                == firstRadioPort
                && harness.coordinator.legacyStreamError == nil
        }
        XCTAssertEqual(
            harness.coordinator.legacyStreamState,
            .running(
                host: "127.0.0.1",
                port: firstRadioPort
            ))
        XCTAssertEqual(harness.monitor.legacyAttachURLs.count, 1)
        XCTAssertTrue(
            harness.monitor.legacyAttachURLs[0].hasSuffix(
                ":\(firstRadioPort)"
            )
        )

        harness.settings.allowedHosts = ["127.0.0.1"]
        await assertCoordinatorState {
            harness.monitor.legacyAttachURLs.count >= 2
                && harness.monitor.legacyDetachCount >= 1
        }

        harness.settings.radioPort = secondRadioPort
        await assertCoordinatorState {
            harness.coordinator.legacyStreamEndpoint?.port
                == secondRadioPort
                && harness.monitor.legacyAttachURLs.count >= 3
        }

        harness.monitor.isStreamingEnabled = false
        await assertCoordinatorState {
            harness.coordinator.legacyStreamState == .disabled
                && harness.coordinator.legacyStreamEndpoint == nil
        }
        XCTAssertNil(harness.coordinator.legacyStreamError)

        harness.monitor.isStreamingEnabled = true
        await assertCoordinatorState {
            harness.coordinator.legacyStreamEndpoint?.port
                == secondRadioPort
                && harness.monitor.legacyAttachURLs.count >= 4
        }

        await harness.shutdownAndWait()
        XCTAssertEqual(harness.coordinator.legacyStreamState, .disabled)
    }

    func testRadioDoesNotBindDedicatedListenerWithoutCompatibilityOptIn()
        async
    {
        let harness = LifecycleCoordinatorHarness(streaming: true)
        addTeardownBlock { @MainActor [harness] in
            await harness.shutdownAndWait()
        }
        harness.settings.remoteAccessEnabled = false
        harness.settings.radioPort = 19_214
        harness.settings.allowLegacyUnauthenticatedStream = false

        harness.coordinator.activate()
        await assertCoordinatorState {
            harness.monitor.legacyDetachCount > 0
        }

        let dedicatedStarts = await harness.legacyTransport.startCount()
        XCTAssertEqual(dedicatedStarts, 0)
        XCTAssertTrue(
            harness.monitor.isStreamingEnabled,
            "Radio may remain logically enabled without exposing an unauthenticated socket."
        )
        XCTAssertEqual(harness.coordinator.legacyStreamState, .disabled)
        XCTAssertNil(harness.coordinator.legacyStreamEndpoint)
        XCTAssertTrue(harness.monitor.legacyAttachURLs.isEmpty)
    }

    func testDisablingCompatibilityStopsDedicatedListenerWhileRadioRemainsOn()
        async
    {
        let port: UInt16 = 19_215
        let harness = LifecycleCoordinatorHarness(streaming: true)
        addTeardownBlock { @MainActor [harness] in
            await harness.shutdownAndWait()
        }
        harness.settings.remoteAccessEnabled = false
        harness.settings.radioPort = port
        harness.settings.allowLegacyUnauthenticatedStream = true

        harness.coordinator.activate()
        await assertCoordinatorState {
            harness.coordinator.legacyStreamEndpoint?.port == port
        }
        let startsBeforeOptOut = await harness.legacyTransport.startCount()
        XCTAssertEqual(startsBeforeOptOut, 1)

        harness.settings.allowLegacyUnauthenticatedStream = false
        await assertCoordinatorState {
            harness.coordinator.legacyStreamState == .disabled
                && harness.coordinator.legacyStreamEndpoint == nil
                && harness.monitor.legacyDetachCount > 0
        }

        let startsAfterOptOut = await harness.legacyTransport.startCount()
        XCTAssertEqual(startsAfterOptOut, startsBeforeOptOut)
        XCTAssertTrue(harness.monitor.isStreamingEnabled)
    }

    func testPairedStreamStaysAuthenticatedUntilSharedPortCompatibilityOptIn()
        async throws
    {
        let remotePort: UInt16 = 19_216
        let radioPort: UInt16 = 19_217
        let harness = LifecycleCoordinatorHarness(streaming: true)
        addTeardownBlock { @MainActor [harness] in
            await harness.shutdownAndWait()
        }
        harness.settings.remoteAccessEnabled = true
        harness.settings.remoteAccessPort = remotePort
        harness.settings.radioPort = radioPort
        harness.settings.allowLegacyUnauthenticatedStream = false

        harness.coordinator.activate()
        await assertCoordinatorState(timeout: .seconds(8)) {
            harness.coordinator.remoteEndpoint?.port == remotePort
                && harness.coordinator.legacyStreamEndpoint?.port == remotePort
        }

        var dedicatedStarts = await harness.legacyTransport.startCount()
        XCTAssertEqual(
            dedicatedStarts,
            0,
            "The separate Radio port must stay closed without the explicit compatibility preference."
        )
        let authenticatedOnlyResult = await harness.remoteTransport.handle(
            RemoteHTTPRequest(
                method: .get,
                target: "/stream",
                headers: ["Host": "localhost:\(remotePort)"],
                remoteAddress: "127.0.0.1"
            )
        )
        let authenticatedOnly = try XCTUnwrap(authenticatedOnlyResult)
        XCTAssertEqual(
            try requireHTTPResponse(authenticatedOnly).status,
            401
        )

        // Sharing the port is not itself consent to bypass pairing.
        harness.settings.radioPort = remotePort
        try await Task.sleep(for: .milliseconds(250))
        dedicatedStarts = await harness.legacyTransport.startCount()
        XCTAssertEqual(dedicatedStarts, 0)
        let sharedButAuthenticatedResult =
            await harness.remoteTransport.handle(
                RemoteHTTPRequest(
                    method: .get,
                    target: "/stream",
                    headers: ["Host": "localhost:\(remotePort)"],
                    remoteAddress: "127.0.0.1"
                )
            )
        let sharedButAuthenticated =
            try XCTUnwrap(sharedButAuthenticatedResult)
        XCTAssertEqual(
            try requireHTTPResponse(sharedButAuthenticated).status,
            401
        )

        harness.settings.allowLegacyUnauthenticatedStream = true
        await assertCoordinatorState(timeout: .seconds(8)) {
            harness.monitor.remoteAttachURLs.count >= 2
                && harness.coordinator.remoteEndpoint?.port == remotePort
                && harness.coordinator.legacyStreamEndpoint?.port == remotePort
        }
        dedicatedStarts = await harness.legacyTransport.startCount()
        XCTAssertEqual(
            dedicatedStarts,
            0,
            "The paired server must remain the sole socket owner on a shared port."
        )

        let explicitlyUnauthenticatedResult =
            await harness.remoteTransport.handle(
                RemoteHTTPRequest(
                    method: .get,
                    target: "/stream",
                    headers: ["Host": "localhost:\(remotePort)"],
                    remoteAddress: "127.0.0.1"
                )
            )
        let explicitlyUnauthenticated =
            try XCTUnwrap(explicitlyUnauthenticatedResult)
        guard
            case .legacyFloat32Audio(let subscription) =
                explicitlyUnauthenticated
        else {
            return XCTFail("Expected the explicit compatibility stream.")
        }
        await subscription.cancel()
    }

    func testSeparateCompatibilityPortDoesNotAnonymousPairedStream()
        async throws
    {
        let remotePort: UInt16 = 19_218
        let radioPort: UInt16 = 19_219
        let harness = LifecycleCoordinatorHarness(streaming: true)
        addTeardownBlock { @MainActor [harness] in
            await harness.shutdownAndWait()
        }
        harness.settings.remoteAccessEnabled = true
        harness.settings.remoteAccessPort = remotePort
        harness.settings.radioPort = radioPort
        harness.settings.allowLegacyUnauthenticatedStream = true

        harness.coordinator.activate()
        await assertCoordinatorState(timeout: .seconds(8)) {
            harness.coordinator.remoteEndpoint?.port == remotePort
                && harness.coordinator.legacyStreamEndpoint?.port == radioPort
        }

        let pairedResult = await harness.remoteTransport.handle(
            RemoteHTTPRequest(
                method: .get,
                target: "/stream",
                headers: ["Host": "localhost:\(remotePort)"],
                remoteAddress: "127.0.0.1"
            )
        )
        let pairedResponse = try requireHTTPResponse(
            XCTUnwrap(pairedResult)
        )
        XCTAssertEqual(
            pairedResponse.status,
            401,
            "Compatibility consent for a separate Radio port must not anonymize the paired Bonjour route."
        )

        let dedicatedResult = await harness.legacyTransport.handle(
            RemoteHTTPRequest(
                method: .get,
                target: "/stream",
                headers: [:],
                remoteAddress: "127.0.0.1"
            )
        )
        guard
            case .legacyFloat32Audio(let subscription) =
                try XCTUnwrap(dedicatedResult)
        else {
            return XCTFail("Expected the explicitly enabled dedicated stream.")
        }
        await subscription.cancel()
    }

    func testLegacyListenerMigratesBetweenDedicatedAndPairedSockets()
        async throws
    {
        let pairedPort: UInt16 = 19_221
        let dedicatedPort: UInt16 = 19_222
        let finalDedicatedPort: UInt16 = 19_223
        let harness = LifecycleCoordinatorHarness(streaming: true)
        addTeardownBlock { @MainActor [harness] in
            await harness.shutdownAndWait()
        }
        harness.settings.remoteAccessEnabled = true
        harness.settings.remoteAccessPort = pairedPort
        harness.settings.radioPort = dedicatedPort
        // Keep the paired configuration stable while radioPort changes.
        harness.settings.allowLegacyUnauthenticatedStream = true

        harness.coordinator.activate()
        await assertCoordinatorState(timeout: .seconds(8)) {
            guard case .running = harness.coordinator.remoteAccessState else {
                return false
            }
            return harness.coordinator.legacyStreamEndpoint?.port
                == dedicatedPort
                && harness.monitor.legacyAttachURLs.count == 1
        }
        let pairedEndpoint = try XCTUnwrap(
            harness.coordinator.remoteEndpoint
        )
        XCTAssertEqual(pairedEndpoint.port, pairedPort)

        harness.settings.radioPort = pairedPort
        await assertCoordinatorState {
            harness.coordinator.legacyStreamEndpoint == pairedEndpoint
                && harness.monitor.legacyAttachURLs.count >= 2
                && harness.monitor.legacyDetachCount >= 1
        }
        XCTAssertEqual(
            harness.coordinator.legacyStreamState,
            harness.coordinator.remoteAccessState
        )
        XCTAssertTrue(
            harness.monitor.legacyAttachURLs.last?.contains(
                ":\(pairedPort)"
            ) == true
        )

        // Moving away from the shared port starts a fresh dedicated listener.
        harness.settings.radioPort = finalDedicatedPort
        await assertCoordinatorState {
            harness.coordinator.legacyStreamEndpoint?.port
                == finalDedicatedPort
                && harness.monitor.legacyAttachURLs.count >= 3
        }
        XCTAssertEqual(harness.coordinator.remoteEndpoint, pairedEndpoint)

        await harness.shutdownAndWait()
        XCTAssertEqual(harness.coordinator.remoteAccessState, .disabled)
        XCTAssertEqual(harness.coordinator.legacyStreamState, .disabled)
    }

    func testHardwareTransitionAndRecordingFinalizationFailuresAreAtomic() {
        let outputHarness = LifecycleCoordinatorHarness()
        defer { outputHarness.settingsStore.reset() }
        outputHarness.addSecondaryOutput()
        outputHarness.monitor.isPassthroughEnabled = true
        outputHarness.monitor.failNextOutputSwitch = true
        let originalOutputUID =
            outputHarness.manager.selectedOutputDevice?.uid

        XCTAssertFalse(
            outputHarness.coordinator.selectNativeOutputDevice(
                uid: LifecycleCoordinatorHarness.secondaryOutputUID
            )
        )
        XCTAssertEqual(
            outputHarness.manager.selectedOutputDevice?.uid,
            originalOutputUID
        )
        XCTAssertEqual(
            outputHarness.coordinator.nativeCommandError,
            "Core Audio could not switch to the selected output."
        )
        XCTAssertEqual(outputHarness.monitor.outputUpdates.count, 2)
        XCTAssertTrue(outputHarness.monitor.isPassthroughEnabled)

        let routeHarness = LifecycleCoordinatorHarness()
        defer { routeHarness.settingsStore.reset() }
        routeHarness.monitor.isPassthroughEnabled = true
        routeHarness.monitor.restartDropsServices = true
        routeHarness.monitor.failPassthroughStarts = 1
        XCTAssertFalse(
            routeHarness.coordinator.selectNativeInputRoute(
                id: "channels-3-4"
            )
        )
        XCTAssertEqual(
            routeHarness.manager.selectedInputRouteID,
            "channels-1-2"
        )
        XCTAssertEqual(routeHarness.monitor.startRequests.count, 2)
        XCTAssertTrue(routeHarness.monitor.isMonitoring)
        XCTAssertTrue(routeHarness.monitor.isPassthroughEnabled)
        XCTAssertEqual(
            routeHarness.coordinator.nativeCommandError,
            "Core Audio could not restart output monitoring."
        )

        let recordingHarness = LifecycleCoordinatorHarness()
        defer { recordingHarness.settingsStore.reset() }
        recordingHarness.monitor.isRecording = true
        recordingHarness.monitor.failRecordingFinalization = true
        XCTAssertFalse(
            recordingHarness.coordinator.setNativeRecordingEnabled(false)
        )
        XCTAssertEqual(recordingHarness.monitor.stopRecordingCount, 1)
        XCTAssertTrue(
            recordingHarness.coordinator.nativeCommandError?.contains(
                "Recording failed while closing the recording"
            ) == true
        )
    }

    func testDiscoveryAndRoutelessDeviceFailuresRemainActionable() {
        let failingManager = AudioDeviceManager(
            hal: ThrowingLifecycleHAL(),
            preferences: InMemoryAudioDevicePreferences()
        )
        let failingSettings = LifecycleSettingsStore()
        defer { failingSettings.reset() }
        let failingCoordinator = AppCoordinator(
            audioManager: failingManager,
            audioMonitor: LifecycleAudioMonitor(),
            settings: failingSettings.settings
        )
        XCTAssertFalse(failingCoordinator.refreshNativeAudioDevices())
        XCTAssertEqual(
            failingCoordinator.nativeCommandError,
            "Synthetic device discovery failure"
        )

        let harness = LifecycleCoordinatorHarness()
        defer { harness.settingsStore.reset() }
        harness.manager.inputDevices = [
            AudioDevice(
                id: 9_001,
                uid: "routeless-input",
                name: "Routeless Input",
                isInput: true,
                isOutput: false,
                inputChannelCount: 1,
                outputChannelCount: 0,
                inputRoutes: [],
                nominalSampleRate: 48_000,
                availableSampleRates: [],
                bufferFrameRange: 32...256,
                transport: .virtual,
                isAlive: true
            )
        ]
        XCTAssertFalse(
            harness.coordinator.selectNativeInputDevice(
                uid: "routeless-input"
            )
        )
        XCTAssertEqual(
            harness.coordinator.nativeCommandError,
            "The selected input does not expose a usable channel route."
        )
    }

    func testSnapshotMapsEveryTransportAndDisconnectedSavedSelections() {
        let savedInputUID = "missing-saved-input"
        let savedOutputUID = "missing-saved-output"
        let preferences = InMemoryAudioDevicePreferences(values: [
            "selectedInputDeviceUID": savedInputUID,
            "selectedInputDeviceName": "Travel Interface",
            "selectedInputRoute.\(savedInputUID)": "channels-7-8",
            "selectedOutputDeviceUID": savedOutputUID,
            "selectedOutputDeviceName": "Studio Speakers",
        ])
        let devices = [
            lifecycleHALDevice(
                id: 101,
                uid: "built-in",
                name: "Built-in",
                inputs: 2,
                outputs: 2,
                nominalRate: 0,
                ranges: [
                    AudioSampleRateRange(minimum: 0, maximum: 48_000),
                    AudioSampleRateRange(minimum: 44_100, maximum: 96_000),
                ],
                transport: .builtIn
            ),
            lifecycleHALDevice(
                id: 102,
                uid: "bluetooth",
                name: "Bluetooth",
                outputs: 2,
                transport: .bluetooth
            ),
            lifecycleHALDevice(
                id: 103,
                uid: "aggregate",
                name: "Aggregate",
                inputs: 1,
                transport: .aggregate
            ),
            lifecycleHALDevice(
                id: 104,
                uid: "virtual",
                name: "Virtual",
                outputs: 2,
                transport: .virtual
            ),
            lifecycleHALDevice(
                id: 105,
                uid: "hdmi",
                name: "HDMI",
                outputs: 2,
                transport: .hdmi
            ),
            lifecycleHALDevice(
                id: 106,
                uid: "display-port",
                name: "DisplayPort",
                outputs: 2,
                transport: .displayPort
            ),
            lifecycleHALDevice(
                id: 107,
                uid: "other",
                name: "Other",
                inputs: 2,
                transport: .other,
                alive: false
            ),
        ]
        let manager = AudioDeviceManager(
            hal: StaticLifecycleHAL(devices: devices),
            preferences: preferences
        )
        let settings = LifecycleSettingsStore()
        defer { settings.reset() }
        let coordinator = AppCoordinator(
            audioManager: manager,
            audioMonitor: LifecycleAudioMonitor(),
            settings: settings.settings
        )

        let snapshot = coordinator.remoteStateSnapshot()
        XCTAssertEqual(snapshot.engine.phase, .disconnected)
        XCTAssertEqual(snapshot.engine.problem?.code, "input_disconnected")
        XCTAssertEqual(
            snapshot.selection,
            RemoteAudioSelection(
                inputUID: savedInputUID,
                inputRouteID: "channels-7-8",
                outputUID: savedOutputUID
            )
        )
        XCTAssertEqual(snapshot.devices.count, devices.count + 2)
        XCTAssertEqual(
            snapshot.devices.first(where: { $0.uid == savedInputUID })?
                .inputRoutes.first?.label,
            "Saved input route"
        )
        XCTAssertEqual(
            snapshot.devices.first(where: { $0.uid == savedOutputUID })?
                .name,
            "Studio Speakers"
        )
        XCTAssertEqual(
            snapshot.devices.first(where: { $0.uid == "built-in" })?
                .supportedSampleRates,
            [44_100, 48_000, 96_000]
        )
        XCTAssertEqual(
            snapshot.devices.first(where: { $0.uid == "other" })?
                .connectionState,
            .disconnected
        )

        let transports = Dictionary(
            uniqueKeysWithValues: snapshot.devices.map {
                ($0.uid, $0.transport)
            }
        )
        XCTAssertEqual(transports["built-in"], .builtIn)
        XCTAssertEqual(transports["bluetooth"], .bluetooth)
        XCTAssertEqual(transports["aggregate"], .aggregate)
        XCTAssertEqual(transports["virtual"], .virtual)
        XCTAssertEqual(transports["hdmi"], .unknown)
        XCTAssertEqual(transports["display-port"], .unknown)
        XCTAssertEqual(transports["other"], .unknown)
        XCTAssertEqual(transports[savedInputUID], .unknown)
    }

    func testSnapshotsExposeRunningAndTypedFailedEngineFormats() {
        let runningManager = AudioDeviceManager(
            hal: FakeCoreAudioHAL(),
            preferences: InMemoryAudioDevicePreferences()
        )
        let runningMonitor = AudioMonitor(
            acceptanceAudioBackendOverride: true
        )
        let inputID = runningManager.selectedInputDeviceID
        runningMonitor.startMonitoring(
            deviceID: inputID ?? 0,
            outputDeviceID: nil,
            inputChannelMap: [2, 3]
        )
        let runningSettings = LifecycleSettingsStore()
        defer { runningSettings.reset() }
        let runningCoordinator = AppCoordinator(
            audioManager: runningManager,
            audioMonitor: runningMonitor,
            settings: runningSettings.settings
        )
        let running = runningCoordinator.remoteStateSnapshot()
        XCTAssertEqual(running.engine.phase, .running)
        XCTAssertEqual(running.engine.format?.sampleRate, 48_000)
        XCTAssertEqual(running.engine.format?.channelCount, 2)
        XCTAssertEqual(running.engine.format?.bufferFrameCount, 256)
        runningMonitor.stopMonitoring()

        let failureMonitor = AudioMonitor(
            audioUnitRuntime: MissingComponentLifecycleRuntime()
        )
        failureMonitor.startMonitoring(
            deviceID: 44,
            outputDeviceID: nil
        )
        let failedSettings = LifecycleSettingsStore()
        defer { failedSettings.reset() }
        let failedCoordinator = AppCoordinator(
            audioManager: runningManager,
            audioMonitor: failureMonitor,
            settings: failedSettings.settings
        )
        let failed = failedCoordinator.remoteStateSnapshot()
        XCTAssertEqual(failed.engine.phase, .failed)
        XCTAssertEqual(failed.engine.problem?.code, "coreaudio_failure")
        XCTAssertEqual(
            failed.engine.problem?.title,
            "Find AUHAL input component"
        )
        XCTAssertTrue(
            failed.engine.problem?.detail.contains("AUHAL") == true
        )
        failureMonitor.stopMonitoring()
    }
}

@MainActor
private final class LifecycleCoordinatorHarness {
    static let secondaryOutputUID = "com.phonoflow.test.secondary-output"

    let settingsStore: LifecycleSettingsStore
    let manager: AudioDeviceManager
    let monitor: LifecycleAudioMonitor
    let settings: AppSettings
    let coordinator: AppCoordinator
    let remoteTransport: LifecycleRemoteTransport
    let legacyTransport: LifecycleRemoteTransport

    init(streaming: Bool = false) {
        settingsStore = LifecycleSettingsStore()
        manager = AudioDeviceManager(
            hal: FakeCoreAudioHAL(),
            preferences: InMemoryAudioDevicePreferences()
        )
        monitor = LifecycleAudioMonitor()
        monitor.isMonitoring = true
        monitor.isStreamingEnabled = streaming
        settings = settingsStore.settings
        remoteTransport = LifecycleRemoteTransport()
        legacyTransport = LifecycleRemoteTransport()
        coordinator = AppCoordinator(
            audioManager: manager,
            audioMonitor: monitor,
            settings: settings,
            remoteDependencies: AppCoordinatorRemoteDependencies(
                bindHost: "127.0.0.1",
                legacyBindHost: "127.0.0.1",
                pairing: RemotePairingService(
                    store: InMemoryRemoteCredentialStore(),
                    clock: TestRemoteClock(.testReference),
                    random: CountingRemoteRandom()
                ),
                bonjour: LifecycleBonjourAdvertiser(),
                remoteTransport: remoteTransport,
                legacyTransport: legacyTransport,
                localAuthorityProvider: {
                    ["localhost", "127.0.0.1", "::1"]
                },
                usesAcceptanceEnvironment: false
            )
        )
    }

    func shutdownAndWait() async {
        coordinator.shutdown()
        let stopped = await waitForCoordinatorState(timeout: .seconds(5)) {
            coordinator.remoteAccessState == .disabled
                && coordinator.legacyStreamState == .disabled
        }
        XCTAssertTrue(
            stopped,
            "AppCoordinator listeners did not stop within five seconds."
        )
        if stopped {
            // Exercise the awaited API after the bounded state transition. The
            // state is published only after both injected transports stop.
            await coordinator.shutdownAndWait()
        }
        settingsStore.reset()
    }

    func addSecondaryOutput() {
        manager.outputDevices.append(
            AudioDevice(
                id: 0xCAFE,
                uid: Self.secondaryOutputUID,
                name: "Secondary Output",
                isInput: false,
                isOutput: true,
                inputChannelCount: 0,
                outputChannelCount: 2,
                inputRoutes: [],
                nominalSampleRate: 48_000,
                availableSampleRates: [
                    AudioSampleRateRange(
                        minimum: 48_000,
                        maximum: 48_000
                    )
                ],
                bufferFrameRange: 32...1_024,
                transport: .usb,
                isAlive: true
            )
        )
    }
}

@MainActor
private final class LifecycleAudioMonitor: AudioMonitor {
    struct StartRequest: Equatable {
        let deviceID: AudioDeviceID
        let outputDeviceID: AudioDeviceID?
        let channelMap: [Int32]
    }

    private(set) var startRequests: [StartRequest] = []
    private(set) var outputUpdates: [AudioDeviceID] = []
    private(set) var stopMonitoringCount = 0
    private(set) var enablePassthroughCount = 0
    private(set) var stopStreamingCount = 0
    private(set) var stopRecordingCount = 0
    private(set) var remoteAttachURLs: [String?] = []
    private(set) var remoteDetachCount = 0
    private(set) var legacyAttachURLs: [String] = []
    private(set) var legacyDetachCount = 0
    private(set) var remoteSpectrumVisible = false
    private(set) var remoteAudioVisible = false
    var failNextOutputSwitch = false
    var failPassthroughStarts = 0
    var failRecordingFinalization = false
    var restartDropsServices = false
    var preserveStreamingOnStop = false

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
        if restartDropsServices {
            isPassthroughEnabled = false
            isStreamingEnabled = false
        }
        isMonitoring = true
    }

    override func stopMonitoring() {
        stopMonitoringCount += 1
        isMonitoring = false
        isPassthroughEnabled = false
        isStreamingEnabled = false
        isRecording = false
    }

    override func enablePassthrough() {
        enablePassthroughCount += 1
        if failPassthroughStarts > 0 {
            failPassthroughStarts -= 1
            isPassthroughEnabled = false
        } else {
            isPassthroughEnabled = isMonitoring
        }
    }

    override func disablePassthrough() {
        isPassthroughEnabled = false
    }

    override func updatePassthroughOutput(deviceID: AudioDeviceID) {
        outputUpdates.append(deviceID)
        if failNextOutputSwitch {
            failNextOutputSwitch = false
            isPassthroughEnabled = false
        }
    }

    override func clearPassthroughOutput() {
        isPassthroughEnabled = false
    }

    override func startStreaming(
        port _: UInt16 = 7865,
        allowedHosts _: [String] = []
    ) {
        isStreamingEnabled = isMonitoring
    }

    override func stopStreaming() {
        stopStreamingCount += 1
        if !preserveStreamingOnStop {
            isStreamingEnabled = false
        }
    }

    override func stopRecording() -> AudioRecorder.TerminalResult? {
        stopRecordingCount += 1
        isRecording = false
        guard failRecordingFinalization else { return nil }
        return .failure(
            AudioRecorder.TerminalFailure(
                phase: .close,
                fileURL: URL(fileURLWithPath: "/tmp/failed-recording.wav"),
                reason: "Synthetic close failure",
                disposition: .removed,
                droppedFrameCount: 0
            )
        )
    }

    override func attachRemoteAccess(
        audioFanout _: RemoteAudioFanout,
        server _: RemoteAccessServer,
        baseURL: String? = nil
    ) {
        remoteAttachURLs.append(baseURL)
    }

    override func detachRemoteAccess() {
        remoteDetachCount += 1
        remoteSpectrumVisible = false
        remoteAudioVisible = false
    }

    override func attachLegacyStream(
        audioFanout _: RemoteAudioFanout,
        baseURL: String
    ) {
        legacyAttachURLs.append(baseURL)
    }

    override func detachLegacyStream() {
        legacyDetachCount += 1
    }

    override func setRemoteSpectrumSubscribersVisible(_ visible: Bool) {
        remoteSpectrumVisible = visible
    }

    override func setRemoteAudioSubscribersVisible(_ visible: Bool) {
        remoteAudioVisible = visible
    }
}

@MainActor
private final class LifecycleSettingsStore {
    private let preferences: InMemoryAudioDevicePreferences
    let settings: AppSettings

    init() {
        preferences = InMemoryAudioDevicePreferences()
        settings = AppSettings(defaults: preferences)
    }

    func reset() {
        preferences.removeAll()
    }
}

private actor LifecycleRemoteTransport: RemoteHTTPTransport {
    private var handler: (@Sendable (RemoteHTTPRequest) async -> RemoteRouteResult)?
    private var starts = 0

    func start(
        configuration: RemoteTransportConfiguration,
        handler:
            @escaping @Sendable (RemoteHTTPRequest) async
            -> RemoteRouteResult
    ) async throws -> RemoteBoundEndpoint {
        self.handler = handler
        starts += 1
        return RemoteBoundEndpoint(
            host: configuration.bindHost,
            port: configuration.port
        )
    }

    func stop() async {
        handler = nil
    }

    func startCount() -> Int {
        starts
    }

    func handle(
        _ request: RemoteHTTPRequest
    ) async -> RemoteRouteResult? {
        guard let handler else { return nil }
        return await handler(request)
    }
}

private actor LifecycleBonjourAdvertiser: RemoteBonjourAdvertising {
    func start(
        serviceName _: String,
        serviceType _: String,
        port _: UInt16,
        txt _: [String: String]
    ) async throws {}

    func stop() async {}
}

@MainActor
private func assertCoordinatorState(
    timeout: Duration = .seconds(5),
    file: StaticString = #filePath,
    line: UInt = #line,
    condition: @MainActor () -> Bool
) async {
    let reachedState = await waitForCoordinatorState(
        timeout: timeout,
        condition: condition
    )
    XCTAssertTrue(reachedState, file: file, line: line)
}

@MainActor
private func waitForCoordinatorState(
    timeout: Duration = .seconds(5),
    condition: @MainActor () -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if condition() {
            return true
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

nonisolated private final class StaticLifecycleHAL:
    CoreAudioHAL,
    @unchecked Sendable
{
    let fixtureDevices: [CoreAudioHALDevice]

    init(devices: [CoreAudioHALDevice]) {
        fixtureDevices = devices
    }

    var bypassesMicrophonePermission: Bool { true }

    func devices() throws -> [CoreAudioHALDevice] {
        fixtureDevices
    }

    func defaultInputDeviceID() throws -> AudioDeviceID? {
        fixtureDevices.first(where: { $0.inputChannelCount > 0 })?.id
    }

    func defaultOutputDeviceID() throws -> AudioDeviceID? {
        fixtureDevices.first(where: { $0.outputChannelCount > 0 })?.id
    }

    func observeDeviceList(
        _ observer: @escaping @Sendable () -> Void
    ) throws -> any CoreAudioHALListener {
        _ = observer
        return LifecycleNoopHALListener()
    }

    func observeAlive(
        deviceID: AudioDeviceID,
        _ observer: @escaping @Sendable () -> Void
    ) throws -> any CoreAudioHALListener {
        _ = deviceID
        _ = observer
        return LifecycleNoopHALListener()
    }
}

nonisolated private final class ThrowingLifecycleHAL:
    CoreAudioHAL,
    @unchecked Sendable
{
    var bypassesMicrophonePermission: Bool { true }

    func devices() throws -> [CoreAudioHALDevice] {
        throw NSError(
            domain: "AppCoordinatorLifecycleCoverageTests",
            code: 7,
            userInfo: [
                NSLocalizedDescriptionKey: "Synthetic device discovery failure"
            ]
        )
    }

    func defaultInputDeviceID() throws -> AudioDeviceID? { nil }

    func defaultOutputDeviceID() throws -> AudioDeviceID? { nil }

    func observeDeviceList(
        _ observer: @escaping @Sendable () -> Void
    ) throws -> any CoreAudioHALListener {
        _ = observer
        return LifecycleNoopHALListener()
    }

    func observeAlive(
        deviceID: AudioDeviceID,
        _ observer: @escaping @Sendable () -> Void
    ) throws -> any CoreAudioHALListener {
        _ = deviceID
        _ = observer
        return LifecycleNoopHALListener()
    }
}

nonisolated private final class LifecycleNoopHALListener:
    CoreAudioHALListener,
    @unchecked Sendable
{
    func cancel() {}
}

nonisolated private final class MissingComponentLifecycleRuntime:
    AudioUnitHALRuntime,
    @unchecked Sendable
{
    func findComponent(
        matching _: AudioComponentDescription
    ) -> AudioComponent? {
        nil
    }

    func instantiate(
        _: AudioComponent,
        unit _: UnsafeMutablePointer<AudioUnit?>
    ) -> OSStatus {
        kAudio_ParamError
    }

    func dispose(_: AudioUnit) -> OSStatus { noErr }

    func setProperty(
        _: AudioUnit,
        id _: AudioUnitPropertyID,
        scope _: AudioUnitScope,
        element _: AudioUnitElement,
        data _: UnsafeRawPointer?,
        byteCount _: UInt32
    ) -> OSStatus {
        kAudio_ParamError
    }

    func getProperty(
        _: AudioUnit,
        id _: AudioUnitPropertyID,
        scope _: AudioUnitScope,
        element _: AudioUnitElement,
        data _: UnsafeMutableRawPointer,
        byteCount _: UnsafeMutablePointer<UInt32>
    ) -> OSStatus {
        kAudio_ParamError
    }

    func initialize(_: AudioUnit) -> OSStatus { kAudio_ParamError }

    func start(_: AudioUnit) -> OSStatus { kAudio_ParamError }

    func stop(_: AudioUnit) -> OSStatus { noErr }

    func render(
        _: AudioUnit,
        actionFlags _: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timestamp _: UnsafePointer<AudioTimeStamp>,
        bus _: AudioUnitElement,
        frameCount _: UInt32,
        data _: UnsafeMutablePointer<AudioBufferList>
    ) -> OSStatus {
        kAudio_ParamError
    }

    func getObjectPropertyData(
        objectID _: AudioObjectID,
        address _: UnsafePointer<AudioObjectPropertyAddress>,
        qualifierDataSize _: UInt32,
        qualifierData _: UnsafeRawPointer?,
        dataSize _: UnsafeMutablePointer<UInt32>,
        data _: UnsafeMutableRawPointer
    ) -> OSStatus {
        kAudio_ParamError
    }

    func setObjectPropertyData(
        objectID _: AudioObjectID,
        address _: UnsafePointer<AudioObjectPropertyAddress>,
        qualifierDataSize _: UInt32,
        qualifierData _: UnsafeRawPointer?,
        dataSize _: UInt32,
        data _: UnsafeRawPointer
    ) -> OSStatus {
        kAudio_ParamError
    }
}

nonisolated private func lifecycleHALDevice(
    id: AudioDeviceID,
    uid: String,
    name: String,
    inputs: Int = 0,
    outputs: Int = 0,
    nominalRate: Double = 48_000,
    ranges: [AudioSampleRateRange] = [
        AudioSampleRateRange(minimum: 48_000, maximum: 48_000)
    ],
    transport: AudioDeviceTransport,
    alive: Bool = true
) -> CoreAudioHALDevice {
    CoreAudioHALDevice(
        id: id,
        uid: uid,
        name: name,
        inputChannelCount: inputs,
        outputChannelCount: outputs,
        inputChannelNames: (0..<inputs).map { "Input \($0 + 1)" },
        nominalSampleRate: nominalRate,
        availableSampleRates: ranges,
        bufferFrameRange: 32...1_024,
        transport: transport,
        isAlive: alive
    )
}
