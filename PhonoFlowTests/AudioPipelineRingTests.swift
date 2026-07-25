import XCTest

@testable import PhonoFlow

final class AudioPipelineRingTests: XCTestCase {
    func testStereoRingPreservesChannelOrderAcrossWriteAndReadWraparound() {
        let ring = PipelineStereoRing(capacity: 5)

        XCTAssertTrue(
            write(
                ring,
                left: [0, 1, 2, 3],
                right: [100, 101, 102, 103]
            )
        )
        XCTAssertEqual(ring.fillLevel, 4)
        XCTAssertEqual(
            read(ring, maximumCount: 3),
            StereoSamples(
                left: [0, 1, 2],
                right: [100, 101, 102]
            )
        )

        XCTAssertTrue(
            write(
                ring,
                left: [4, 5, 6, 7],
                right: [104, 105, 106, 107]
            )
        )
        XCTAssertEqual(ring.fillLevel, 5)
        XCTAssertEqual(
            read(ring, maximumCount: 5),
            StereoSamples(
                left: [3, 4, 5, 6, 7],
                right: [103, 104, 105, 106, 107]
            )
        )
        XCTAssertEqual(ring.fillLevel, 0)
        XCTAssertEqual(ring.droppedFrames, 0)
    }

    func testStereoRingIsBoundedAndCountsEveryRejectedNewestFrame() {
        let ring = PipelineStereoRing(capacity: 1)

        XCTAssertTrue(
            write(ring, left: [1, 2, 3], right: [11, 12, 13])
        )
        XCTAssertEqual(ring.fillLevel, 2, "The ring enforces a minimum capacity of two")
        XCTAssertEqual(ring.droppedFrames, 1)

        XCTAssertFalse(write(ring, left: [4], right: [14]))
        XCTAssertEqual(ring.droppedFrames, 2)
        XCTAssertEqual(
            read(ring, maximumCount: 8),
            StereoSamples(left: [1, 2], right: [11, 12])
        )
    }

    func testStereoRingRejectsEmptyOperationsAndDiscardAdvancesConsumer() {
        let ring = PipelineStereoRing(capacity: 4)

        XCTAssertFalse(write(ring, left: [], right: []))
        XCTAssertEqual(read(ring, maximumCount: 0), .empty)
        XCTAssertTrue(
            write(ring, left: [1, 2, 3], right: [4, 5, 6])
        )
        XCTAssertEqual(ring.fillLevel, 3)

        ring.discardPending()

        XCTAssertEqual(ring.fillLevel, 0)
        XCTAssertEqual(read(ring, maximumCount: 4), .empty)
        XCTAssertEqual(ring.droppedFrames, 0)
    }

    func testStereoRingWriteResultReportsAcceptedAndDroppedFramesExactly() {
        let ring = PipelineStereoRing(capacity: 4)

        XCTAssertEqual(
            writeResult(
                ring,
                left: [1, 2, 3],
                right: [11, 12, 13]
            ),
            PipelineRingWriteResult(
                acceptedFrames: 3,
                droppedFrames: 0
            )
        )
        XCTAssertEqual(
            writeResult(
                ring,
                left: [4, 5, 6],
                right: [14, 15, 16]
            ),
            PipelineRingWriteResult(
                acceptedFrames: 1,
                droppedFrames: 2
            )
        )
        XCTAssertEqual(
            writeResult(ring, left: [7], right: [17]),
            PipelineRingWriteResult(
                acceptedFrames: 0,
                droppedFrames: 1
            )
        )
        XCTAssertEqual(ring.droppedFrames, 3)
        XCTAssertEqual(ring.discardPending(), 4)
        XCTAssertEqual(ring.discardPending(), 0)
    }

    private func write(
        _ ring: PipelineStereoRing,
        left: [Float],
        right: [Float]
    ) -> Bool {
        precondition(left.count == right.count)
        if left.isEmpty {
            var placeholder: Float = 0
            return withUnsafePointer(to: &placeholder) { pointer in
                ring.write(
                    left: pointer,
                    right: pointer,
                    count: 0
                )
            }
        }
        return left.withUnsafeBufferPointer { leftBuffer in
            right.withUnsafeBufferPointer { rightBuffer in
                ring.write(
                    left: leftBuffer.baseAddress!,
                    right: rightBuffer.baseAddress!,
                    count: left.count
                )
            }
        }
    }

    private func read(
        _ ring: PipelineStereoRing,
        maximumCount: Int
    ) -> StereoSamples {
        guard maximumCount > 0 else {
            var placeholder: Float = 0
            let count = withUnsafeMutablePointer(to: &placeholder) { pointer in
                ring.read(
                    left: pointer,
                    right: pointer,
                    maximumCount: maximumCount
                )
            }
            XCTAssertEqual(count, 0)
            return .empty
        }

        var left = [Float](repeating: 0, count: maximumCount)
        var right = [Float](repeating: 0, count: maximumCount)
        let count = left.withUnsafeMutableBufferPointer { leftBuffer in
            right.withUnsafeMutableBufferPointer { rightBuffer in
                ring.read(
                    left: leftBuffer.baseAddress!,
                    right: rightBuffer.baseAddress!,
                    maximumCount: maximumCount
                )
            }
        }
        return StereoSamples(
            left: Array(left.prefix(count)),
            right: Array(right.prefix(count))
        )
    }

    private func writeResult(
        _ ring: PipelineStereoRing,
        left: [Float],
        right: [Float]
    ) -> PipelineRingWriteResult {
        precondition(left.count == right.count)
        return left.withUnsafeBufferPointer { leftBuffer in
            right.withUnsafeBufferPointer { rightBuffer in
                ring.writeResult(
                    left: leftBuffer.baseAddress!,
                    right: rightBuffer.baseAddress!,
                    count: left.count
                )
            }
        }
    }
}

private struct StereoSamples: Equatable {
    var left: [Float]
    var right: [Float]

    static let empty = StereoSamples(left: [], right: [])
}
