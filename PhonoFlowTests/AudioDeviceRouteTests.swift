import XCTest

@testable import PhonoFlow

@MainActor
final class AudioDeviceRouteTests: XCTestCase {
    func testZeroChannelDeviceHasNoRoutes() {
        XCTAssertEqual(
            AudioDeviceManager.makeInputRoutes(channelCount: 0, channelNames: []),
            []
        )
    }

    func testMonoDeviceDuplicatesChannelIntoStereoClientFormat() throws {
        let routes = AudioDeviceManager.makeInputRoutes(
            channelCount: 1,
            channelNames: ["Mic"]
        )

        let route = try XCTUnwrap(routes.first)
        XCTAssertEqual(routes.count, 1)
        XCTAssertEqual(route.id, "channels-1-1")
        XCTAssertEqual(route.name, "Mic (Mono)")
        XCTAssertEqual(route.channelMap, [0, 0])
        XCTAssertEqual(route.channelNames, ["Mic", "Mic"])
    }

    func testStereoDeviceDefaultsToFirstPair() throws {
        let routes = AudioDeviceManager.makeInputRoutes(
            channelCount: 2,
            channelNames: []
        )

        let route = try XCTUnwrap(routes.first)
        XCTAssertEqual(routes.count, 1)
        XCTAssertEqual(route.id, "channels-1-2")
        XCTAssertEqual(route.name, "Inputs 1–2")
        XCTAssertEqual(route.channelMap, [0, 1])
        XCTAssertEqual(route.channelNames, ["Input 1", "Input 2"])
    }

    func testFourInputDeviceOffersBothStereoPairsWithoutVendorSpecialCases() {
        let routes = AudioDeviceManager.makeInputRoutes(
            channelCount: 4,
            channelNames: []
        )

        XCTAssertEqual(routes.map(\.id), ["channels-1-2", "channels-3-4"])
        XCTAssertEqual(routes.map(\.channelMap), [[0, 1], [2, 3]])
        XCTAssertEqual(routes.map(\.name), ["Inputs 1–2", "Inputs 3–4"])
    }

    func testOddChannelCountDuplicatesLastChannel() throws {
        let routes = AudioDeviceManager.makeInputRoutes(
            channelCount: 3,
            channelNames: []
        )

        XCTAssertEqual(routes.count, 2)
        let finalRoute = try XCTUnwrap(routes.last)
        XCTAssertEqual(finalRoute.id, "channels-3-3")
        XCTAssertEqual(finalRoute.name, "Input 3 (Mono)")
        XCTAssertEqual(finalRoute.channelMap, [2, 2])
        XCTAssertEqual(finalRoute.channelNames, ["Input 3", "Input 3"])
    }

    func testCoreAudioChannelNamesAreIncludedInPairLabel() throws {
        let routes = AudioDeviceManager.makeInputRoutes(
            channelCount: 4,
            channelNames: ["Analog 1", "Analog 2", "Loopback L", "Loopback R"]
        )

        let first = try XCTUnwrap(routes.first)
        let last = try XCTUnwrap(routes.last)
        XCTAssertEqual(first.name, "Inputs 1–2 · Analog 1 / Analog 2")
        XCTAssertEqual(last.name, "Inputs 3–4 · Loopback L / Loopback R")
    }

    func testMissingChannelNamesFallBackIndividually() throws {
        let routes = AudioDeviceManager.makeInputRoutes(
            channelCount: 3,
            channelNames: ["Named 1"]
        )

        let first = try XCTUnwrap(routes.first)
        let last = try XCTUnwrap(routes.last)
        XCTAssertEqual(first.channelNames, ["Named 1", "Input 2"])
        XCTAssertEqual(last.channelNames, ["Input 3", "Input 3"])
    }
}
