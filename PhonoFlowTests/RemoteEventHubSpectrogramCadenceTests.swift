import Foundation
import XCTest

@testable import PhonoFlow

@MainActor
final class RemoteEventHubSpectrogramCadenceTests: XCTestCase {
    func testRoundedProcessorSchedulePublishesExactlyFifteenColumnsPerSecond() async throws {
        let hub = RemoteEventHub(clock: TestRemoteClock(.testReference))
        let subscription = try await hub.subscribe(
            principal: RemoteSessionPrincipal(
                sessionID: "cadence",
                expiresAt: .testReference.addingTimeInterval(3_600)
            ),
            snapshot: .fixture()
        )
        var iterator = subscription.stream.makeAsyncIterator()
        _ = await iterator.next()
        let start = Date.testReference

        for columnIndex in 1...15 {
            let relativeNanoseconds = UInt64(
                (Double(columnIndex) / 15 * 1_000_000_000).rounded()
            )
            let column = RemoteSpectrogramColumn(
                sequence: UInt64(columnIndex),
                timestamp: start.addingTimeInterval(
                    Double(relativeNanoseconds) / 1_000_000_000
                ),
                intensities: Array(repeating: UInt8(columnIndex), count: 64)
            )

            let accepted = await hub.publish(spectrogram: column)
            XCTAssertTrue(
                accepted,
                "The rounded 15 Hz timestamp for column \(columnIndex) was rejected."
            )
            guard case .spectrum(let received) = await iterator.next() else {
                await subscription.cancel()
                return XCTFail("Expected spectrogram column \(columnIndex).")
            }
            XCTAssertEqual(received.sequence, UInt64(columnIndex))
        }

        let tooEarly = RemoteSpectrogramColumn(
            sequence: 16,
            timestamp: start.addingTimeInterval(1.01),
            intensities: Array(repeating: 16, count: 64)
        )
        let acceptedTooEarly = await hub.publish(spectrogram: tooEarly)
        XCTAssertFalse(acceptedTooEarly)

        await subscription.cancel()
    }
}
