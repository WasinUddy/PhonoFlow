import Foundation
import Testing

@testable import PhonoFlowCore

@Suite("Audio models")
struct AudioModelsTests {
    @Test("Default channel maps duplicate mono and select the first stereo pair")
    func defaultChannelMaps() throws {
        #expect(try AudioChannelMap.defaultMap(inputChannelCount: 1).sourceChannels == [0, 0])
        #expect(try AudioChannelMap.defaultMap(inputChannelCount: 2).sourceChannels == [0, 1])
        #expect(try AudioChannelMap.defaultMap(inputChannelCount: 18).sourceChannels == [0, 1])
    }

    @Test("Route maps use consecutive pairs and preserve an odd trailing mono input")
    func pairedChannelMaps() throws {
        #expect(
            try AudioChannelMap.route(startingAt: 2, inputChannelCount: 4).sourceChannels
                == [2, 3]
        )
        #expect(
            try AudioChannelMap.route(startingAt: 4, inputChannelCount: 5).sourceChannels
                == [4, 4]
        )
    }

    @Test("Invalid channel maps and ranges are rejected")
    func invalidChannelMaps() {
        #expect(throws: AudioModelValidationError.self) {
            try AudioChannelMap(sourceChannels: [0])
        }
        #expect(throws: AudioModelValidationError.self) {
            try AudioChannelMap(sourceChannels: [0, -1])
        }
        #expect(throws: AudioModelValidationError.self) {
            try AudioChannelMap.defaultMap(inputChannelCount: 0)
        }
        #expect(throws: AudioModelValidationError.self) {
            try AudioChannelMap.route(startingAt: 4, inputChannelCount: 4)
        }
    }

    @Test("Fallback input routes have stable IDs and readable labels")
    func generatedFallbackRoutes() throws {
        let routes = try AudioInputRoute.generate(inputChannelCount: 5)

        #expect(routes.map(\.id) == ["channels-1-2", "channels-3-4", "channels-5-5"])
        #expect(routes.map(\.name) == ["Inputs 1–2", "Inputs 3–4", "Input 5"])
        #expect(routes.map(\.channelMap.sourceChannels) == [[0, 1], [2, 3], [4, 4]])
    }

    @Test("Hardware channel names are used in route labels")
    func generatedNamedRoutes() throws {
        let routes = try AudioInputRoute.generate(
            inputChannelCount: 4,
            channelNames: ["Analogue 1", "Analogue 2", "Loopback L", "Loopback R"]
        )

        #expect(routes[0].name == "Analogue 1 / Analogue 2")
        #expect(routes[1].name == "Loopback L / Loopback R")
        #expect(routes[1].channelMap.sourceChannels == [2, 3])
    }

    @Test("Device descriptors normalize names, sample rates, and routes")
    func deviceDescriptorNormalization() throws {
        let descriptor = try AudioDeviceDescriptor(
            uid: "focusrite-usb-1",
            name: "Scarlett 2i2",
            inputChannelCount: 4,
            outputChannelCount: 2,
            inputChannelNames: ["Analogue 1", "Analogue 2"],
            supportedSampleRates: [96_000, 44_100, 48_000, 48_000],
            bufferFrameRange: try AudioBufferFrameRange(minimum: 32, maximum: 1_024),
            transport: .usb
        )

        #expect(descriptor.id == "focusrite-usb-1")
        #expect(
            descriptor.inputChannelNames == [
                "Analogue 1",
                "Analogue 2",
                "Input 3",
                "Input 4",
            ])
        #expect(descriptor.outputChannelNames == ["Output 1", "Output 2"])
        #expect(descriptor.inputRoutes.map(\.id) == ["channels-1-2", "channels-3-4"])
        #expect(descriptor.supportedSampleRates == [44_100, 48_000, 96_000])
        #expect(descriptor.isInputCapable)
        #expect(descriptor.isOutputCapable)
        #expect(descriptor.inputRoute(id: "channels-3-4")?.channelMap.sourceChannels == [2, 3])
    }

    @Test("Device descriptors reject duplicate and out-of-range routes")
    func invalidDeviceRoutes() throws {
        let validMap = try AudioChannelMap(sourceChannels: [0, 1])
        let invalidMap = try AudioChannelMap(sourceChannels: [2, 3])
        let firstRoute = try AudioInputRoute(id: "pair", name: "Pair", channelMap: validMap)
        let duplicateRoute = try AudioInputRoute(id: "pair", name: "Again", channelMap: validMap)
        let invalidRoute = try AudioInputRoute(id: "other", name: "Other", channelMap: invalidMap)

        #expect(throws: AudioModelValidationError.self) {
            try AudioDeviceDescriptor(
                uid: "device",
                name: "Device",
                inputChannelCount: 2,
                outputChannelCount: 0,
                inputRoutes: [firstRoute, duplicateRoute]
            )
        }
        #expect(throws: AudioModelValidationError.self) {
            try AudioDeviceDescriptor(
                uid: "device",
                name: "Device",
                inputChannelCount: 2,
                outputChannelCount: 0,
                inputRoutes: [invalidRoute]
            )
        }
    }

    @Test("Stable device selection uses UID and route ID on the wire")
    func selectionCodableRoundTrip() throws {
        let selection = try AudioDeviceSelection(
            inputUID: "focusrite-usb-1",
            inputRouteID: "channels-3-4",
            outputUID: nil
        )

        let data = try JSONEncoder().encode(selection)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["inputUID"] as? String == "focusrite-usb-1")
        #expect(object["inputRouteID"] as? String == "channels-3-4")
        #expect(object["outputUID"] == nil)
        #expect(try JSONDecoder().decode(AudioDeviceSelection.self, from: data) == selection)
    }

    @Test("Stream format validates negotiated parameters")
    func streamFormatValidation() throws {
        let format = try AudioStreamFormat(
            sampleRate: 48_000,
            channelCount: 2,
            maximumFramesPerSlice: 512
        )

        #expect(format.sampleFormat == .float32)
        #expect(!format.isInterleaved)
        #expect(format.sampleFormat.bitsPerSample == 32)
        #expect(try roundTrip(format) == format)

        #expect(throws: AudioModelValidationError.self) {
            try AudioStreamFormat(
                sampleRate: .infinity,
                channelCount: 2,
                maximumFramesPerSlice: 512
            )
        }
        #expect(throws: AudioModelValidationError.self) {
            try AudioStreamFormat(
                sampleRate: 48_000,
                channelCount: 0,
                maximumFramesPerSlice: 512
            )
        }
        #expect(throws: AudioModelValidationError.self) {
            try AudioStreamFormat(
                sampleRate: 48_000,
                channelCount: 2,
                maximumFramesPerSlice: 0
            )
        }
    }

    @Test("Engine state has a stable discriminated Codable representation")
    func engineStateCodableRoundTrip() throws {
        let format = try AudioStreamFormat(
            sampleRate: 96_000,
            channelCount: 2,
            maximumFramesPerSlice: 1_024
        )
        let running = AudioEngineState.running(format)
        let runningData = try JSONEncoder().encode(running)
        let runningObject = try #require(
            JSONSerialization.jsonObject(with: runningData) as? [String: Any]
        )

        #expect(runningObject["state"] as? String == "running")
        #expect(runningObject["format"] != nil)
        #expect(try JSONDecoder().decode(AudioEngineState.self, from: runningData) == running)
        #expect(running.isRunning)
        #expect(running.runningFormat == format)

        let failure = AudioEngineFailure(
            code: .audioUnitStartFailed,
            message: "Could not start input.",
            recoverySuggestion: "Reconnect the device.",
            osStatus: -50,
            deviceUID: "focusrite-usb-1"
        )
        let failed = AudioEngineState.failed(failure)

        #expect(try roundTrip(failed) == failed)
        #expect(failed.failure == failure)
        #expect(!failed.isRunning)
    }

    @Test("Problem details provide typed status-specific responses")
    func apiProblems() throws {
        let conflict = APIProblem.conflict(
            detail: "Stop recording before changing the input device."
        )
        #expect(conflict.status == 409)
        #expect(conflict.code == .recordingInProgress)

        let validation = APIProblem.unprocessableEntity(
            detail: "The route is invalid.",
            violations: [
                APIFieldViolation(field: "inputRouteID", reason: "Route is unavailable.")
            ]
        )
        #expect(validation.status == 422)
        #expect(validation.violations.first?.field == "inputRouteID")
        #expect(try roundTrip(validation) == validation)
    }

    @Test("Model decoding preserves validation invariants")
    func decodingValidation() {
        let invalidMap = Data(#"{"sourceChannels":[0]}"#.utf8)
        let invalidSelection = Data(
            #"{"inputUID":"","inputRouteID":"channels-1-2"}"#.utf8
        )

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(AudioChannelMap.self, from: invalidMap)
        }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(AudioDeviceSelection.self, from: invalidSelection)
        }
    }

    @Test("Public models satisfy strict concurrency boundaries")
    func modelsAreSendable() throws {
        requireSendable(try AudioChannelMap(sourceChannels: [0, 1]))
        requireSendable(
            try AudioDeviceSelection(inputUID: "input", inputRouteID: "channels-1-2")
        )
        requireSendable(AudioEngineState.idle)
        requireSendable(APIProblem.unauthorized())
    }
}

private func roundTrip<Value>(_ value: Value) throws -> Value
where Value: Codable {
    try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(value))
}

private func requireSendable<Value: Sendable>(_ value: Value) {
    _ = value
}
