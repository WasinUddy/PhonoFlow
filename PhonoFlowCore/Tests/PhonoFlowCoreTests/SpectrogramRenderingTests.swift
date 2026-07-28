import CoreGraphics
import Foundation
import Testing

@testable import PhonoFlowCore

@Suite("Native spectrogram rendering")
struct SpectrogramRenderingTests {
    @Test("Renderer produces the canonical pixel dimensions and history layout")
    func imageLayout() throws {
        let column = try SpectrogramColumn(
            sequence: 0,
            timestampNanoseconds: 1,
            intensities: [UInt8](repeating: 255, count: 64)
        )
        let image = try #require(
            SpectrogramImageRenderer.makeImage(columns: [column])
        )

        #expect(image.width == 64)
        #expect(image.height == 64)
        let bytes = try #require(image.dataProvider?.data)
        let pixels = Data(bytes as Data)
        #expect(pixels[3] == 0)
        #expect(pixels[(63 * 4) + 3] == 255)
    }

    @Test("Mailbox measures a single pending publication and coalesces frames")
    @MainActor
    func mailboxInstrumentation() async throws {
        let mailbox = CoalescedSpectrogramFrameMailbox()
        var deliveredSequences: [UInt64] = []
        mailbox.setPublisher { frame in
            deliveredSequences.append(frame.column.sequence)
        }

        for sequence in 0..<3 {
            let column = try SpectrogramColumn(
                sequence: UInt64(sequence),
                timestampNanoseconds: UInt64(sequence),
                intensities: [UInt8](repeating: UInt8(sequence), count: 64)
            )
            let image = try #require(
                SpectrogramImageRenderer.makeImage(columns: [column])
            )
            mailbox.offer(
                SpectrogramRenderFrame(column: column, image: image)
            )
        }

        await mailbox.waitUntilIdle()
        #expect(deliveredSequences == [2])
        #expect(mailbox.skippedFrames == 2)
        #expect(mailbox.pendingFrames == 0)
        #expect(mailbox.maximumPendingFrames == 1)
    }
}
