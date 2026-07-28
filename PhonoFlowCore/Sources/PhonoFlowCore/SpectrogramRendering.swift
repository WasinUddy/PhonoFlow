import CoreGraphics
import Foundation
import Synchronization

/// The immutable native frame published to SwiftUI after off-main rendering.
public struct SpectrogramRenderFrame: @unchecked Sendable {
    public let column: SpectrogramColumn
    public let image: CGImage

    public init(column: SpectrogramColumn, image: CGImage) {
        self.column = column
        self.image = image
    }
}

/// Renders the canonical 64-column spectrogram history used by the app.
///
/// Keeping this renderer in the core package lets the release benchmark run
/// the exact same pixel-generation path as the native audio worker.
public enum SpectrogramImageRenderer {
    private static let size = SpectrogramProcessor.rowCount
    private static let colorLUT: [(UInt8, UInt8, UInt8)] = (0..<256).map {
        color(Float($0) / 255)
    }

    public static func makeImage(columns: [SpectrogramColumn]) -> CGImage? {
        let visible = columns.suffix(SpectrogramProcessor.historyCapacity)
        let leadingBlankColumns = size - visible.count
        var pixels = [UInt8](repeating: 0, count: size * size * 4)

        for (offset, column) in visible.enumerated() {
            let x = leadingBlankColumns + offset
            for row in 0..<size {
                let intensity = Int(column.intensities[row])
                let (red, green, blue) = colorLUT[intensity]
                let y = size - 1 - row
                let index = (y * size + x) * 4
                pixels[index] = red
                pixels[index + 1] = green
                pixels[index + 2] = blue
                pixels[index + 3] = 255
            }
        }

        let data = Data(pixels)
        guard let provider = CGDataProvider(data: data as CFData) else {
            return nil
        }
        return CGImage(
            width: size,
            height: size,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: size * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(
                rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
            ),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    private static func color(_ intensity: Float) -> (UInt8, UInt8, UInt8) {
        let value = min(max(intensity, 0), 1)
        let red: Float
        let green: Float
        let blue: Float

        switch value {
        case ..<0.2:
            let t = value / 0.2
            red = 0.03 * t
            green = 0.04 * t
            blue = 0.28 * t
        case ..<0.4:
            let t = (value - 0.2) / 0.2
            red = 0.03
            green = 0.04 + 0.58 * t
            blue = 0.28 + 0.62 * t
        case ..<0.6:
            let t = (value - 0.4) / 0.2
            red = 0.03 + 0.08 * t
            green = 0.62 + 0.34 * t
            blue = 0.9 - 0.38 * t
        case ..<0.8:
            let t = (value - 0.6) / 0.2
            red = 0.11 + 0.89 * t
            green = 0.96
            blue = 0.52 - 0.48 * t
        default:
            let t = (value - 0.8) / 0.2
            red = 1
            green = 0.96 - 0.82 * t
            blue = 0.04 * (1 - t)
        }

        return (
            UInt8(min(max(red * 255, 0), 255)),
            UInt8(min(max(green * 255, 0), 255)),
            UInt8(min(max(blue * 255, 0), 255))
        )
    }
}

/// Coalesces native-frame publication to at most one pending main-queue job.
///
/// The counters are instrumentation, not inferred constants: the benchmark
/// reads the observed high-water mark after driving this same mailbox.
public final class CoalescedSpectrogramFrameMailbox: @unchecked Sendable {
    public typealias Publisher =
        @MainActor @Sendable (SpectrogramRenderFrame) -> Void

    private let latest = Mutex<SpectrogramRenderFrame?>(nil)
    private let publisher = Mutex<Publisher?>(nil)
    private let publicationPending = Atomic<Bool>(false)
    private let skipCount = Atomic<UInt64>(0)
    private let pendingDepth = Atomic<Int>(0)
    private let maximumPendingDepth = Atomic<Int>(0)

    public init() {}

    public func setPublisher(_ publisher: Publisher?) {
        self.publisher.withLock { $0 = publisher }
    }

    public func offer(_ frame: SpectrogramRenderFrame) {
        let replaced = latest.withLock { value -> Bool in
            let hadValue = value != nil
            value = frame
            return hadValue
        }
        if replaced {
            skipCount.wrappingAdd(1, ordering: .relaxed)
        }

        let result = publicationPending.compareExchange(
            expected: false,
            desired: true,
            ordering: .acquiringAndReleasing
        )
        guard result.exchanged else {
            return
        }
        pendingDepth.store(1, ordering: .releasing)
        recordPendingDepth(pendingDepth.load(ordering: .acquiring))
        DispatchQueue.main.async { [weak self] in
            self?.deliver()
        }
    }

    public func clear() {
        latest.withLock { $0 = nil }
    }

    public var skippedFrames: UInt64 {
        skipCount.load(ordering: .relaxed)
    }

    public var maximumPendingFrames: Int {
        maximumPendingDepth.load(ordering: .acquiring)
    }

    public var pendingFrames: Int {
        pendingDepth.load(ordering: .acquiring)
    }

    public var hasPendingFrame: Bool {
        publicationPending.load(ordering: .acquiring)
            || latest.withLock { $0 != nil }
    }

    public func waitUntilIdle() async {
        while hasPendingFrame {
            await Task.yield()
        }
    }

    @MainActor
    private func deliver() {
        if let frame = latest.withLock({ value -> SpectrogramRenderFrame? in
            defer { value = nil }
            return value
        }) {
            publisher.withLock { $0 }?(frame)
        }

        pendingDepth.store(0, ordering: .releasing)
        publicationPending.store(false, ordering: .releasing)
        let hasAnotherFrame = latest.withLock { $0 != nil }
        guard hasAnotherFrame else {
            return
        }

        let result = publicationPending.compareExchange(
            expected: false,
            desired: true,
            ordering: .acquiringAndReleasing
        )
        if result.exchanged {
            pendingDepth.store(1, ordering: .releasing)
            recordPendingDepth(pendingDepth.load(ordering: .acquiring))
            DispatchQueue.main.async { [weak self] in
                self?.deliver()
            }
        }
    }

    private func recordPendingDepth(_ depth: Int) {
        var current = maximumPendingDepth.load(ordering: .relaxed)
        while depth > current {
            let result = maximumPendingDepth.compareExchange(
                expected: current,
                desired: depth,
                ordering: .relaxed
            )
            if result.exchanged {
                return
            }
            current = result.original
        }
    }
}
