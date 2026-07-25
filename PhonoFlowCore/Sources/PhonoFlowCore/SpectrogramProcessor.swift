import Accelerate
import Foundation

/// Errors reported by the streaming spectrogram pipeline.
public enum SpectrogramError: Error, Equatable, Sendable {
    case invalidSampleRate(Double)
    case mismatchedChannelCounts(left: Int, right: Int)
    case invalidIntensityCount(Int)
    case transformUnavailable
}

/// A single display-ready spectrogram column.
///
/// Intensities are ordered from low to high frequency. Zero represents the
/// configured noise floor and 255 represents 0 dBFS.
public struct SpectrogramColumn: Codable, Equatable, Sendable {
    public static let intensityCount = 64

    public let sequence: UInt64
    public let timestampNanoseconds: UInt64
    public let intensities: [UInt8]

    public init(
        sequence: UInt64,
        timestampNanoseconds: UInt64,
        intensities: [UInt8]
    ) throws {
        guard intensities.count == Self.intensityCount else {
            throw SpectrogramError.invalidIntensityCount(intensities.count)
        }
        self.sequence = sequence
        self.timestampNanoseconds = timestampNanoseconds
        self.intensities = intensities
    }

    private enum CodingKeys: String, CodingKey {
        case sequence
        case timestampNanoseconds
        case intensities
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let intensities = try container.decode([UInt8].self, forKey: .intensities)
        do {
            try self.init(
                sequence: container.decode(UInt64.self, forKey: .sequence),
                timestampNanoseconds: container.decode(
                    UInt64.self,
                    forKey: .timestampNanoseconds
                ),
                intensities: intensities
            )
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .intensities,
                in: container,
                debugDescription: "A spectrogram column must contain exactly \(Self.intensityCount) intensities"
            )
        }
    }

    fileprivate init(
        uncheckedSequence sequence: UInt64,
        timestampNanoseconds: UInt64,
        intensities: [UInt8]
    ) {
        self.sequence = sequence
        self.timestampNanoseconds = timestampNanoseconds
        self.intensities = intensities
    }
}

public struct SpectrogramProcessorMetrics: Codable, Equatable, Sendable {
    public let isAnalysisEnabled: Bool
    public let normalizedSamplesConsumed: UInt64
    public let transformOperations: UInt64
    public let emittedColumns: UInt64
    public let ignoredInputSamples: UInt64
    /// PhonoFlow-owned allocations of the persistent FFT/window scratch arrays.
    ///
    /// Consumers can take a before/after delta around steady-state processing.
    /// Output column payloads and injected normalizer storage are intentionally
    /// outside this STFT-specific counter.
    public let stftScratchAllocationEvents: UInt64

    public init(
        isAnalysisEnabled: Bool,
        normalizedSamplesConsumed: UInt64,
        transformOperations: UInt64,
        emittedColumns: UInt64,
        ignoredInputSamples: UInt64,
        stftScratchAllocationEvents: UInt64 = 0
    ) {
        self.isAnalysisEnabled = isAnalysisEnabled
        self.normalizedSamplesConsumed = normalizedSamplesConsumed
        self.transformOperations = transformOperations
        self.emittedColumns = emittedColumns
        self.ignoredInputSamples = ignoredInputSamples
        self.stftScratchAllocationEvents = stftScratchAllocationEvents
    }
}

/// A stateful seam for converting arbitrary device rates to the fixed
/// spectrogram analysis rate.
///
/// Implementations retain boundary samples between calls so feeding the same
/// signal in differently sized chunks produces the same normalized stream.
public protocol SpectrogramSampleRateNormalizing: Sendable {
    mutating func normalize(
        _ samples: [Float],
        sourceSampleRate: Double,
        targetSampleRate: Double
    ) throws -> [Float]

    mutating func finish() throws -> [Float]
    mutating func reset()
}

extension SpectrogramSampleRateNormalizing {
    public mutating func finish() throws -> [Float] {
        []
    }
}

/// Streaming sample-rate normalization used by the spectrogram.
///
/// The public type name is retained for source compatibility, but every
/// non-native conversion now uses a band-limited, 129-tap polyphase sinc
/// kernel. Coefficients are generated once for each configured rate pair and
/// reused for every output sample. The implementation retains the required
/// lookahead and history across calls, making its output independent of
/// callback boundaries.
public struct LinearSampleRateNormalizer: SpectrogramSampleRateNormalizing {
    private static let kernelRadius = 64
    private static let fallbackPhaseCount = 2_048
    private static let maximumExactPhaseCount = 4_096

    private var configuredSourceRate: Double?
    private var configuredTargetRate: Double?
    private var nextOutputPosition: Double = 0
    private var isPassthrough = false
    private var phaseCount = 1
    private var coefficients: [Float] = []
    private var sourceBuffer: [Float] = []
    private var sourceBufferHead = 0
    private var sourceBufferStart: Int64 = 0
    private var totalSourceSamples: Int64 = 0

    public init() {}

    public mutating func normalize(
        _ samples: [Float],
        sourceSampleRate: Double,
        targetSampleRate: Double
    ) throws -> [Float] {
        guard sourceSampleRate.isFinite, sourceSampleRate > 0 else {
            throw SpectrogramError.invalidSampleRate(sourceSampleRate)
        }
        guard targetSampleRate.isFinite, targetSampleRate > 0 else {
            throw SpectrogramError.invalidSampleRate(targetSampleRate)
        }
        guard !samples.isEmpty else {
            return []
        }

        if configuredSourceRate != sourceSampleRate || configuredTargetRate != targetSampleRate {
            reset()
            configuredSourceRate = sourceSampleRate
            configuredTargetRate = targetSampleRate
            isPassthrough = sourceSampleRate == targetSampleRate
            if !isPassthrough {
                let cutoffScale =
                    sourceSampleRate > targetSampleRate
                    ? 0.94 * targetSampleRate / sourceSampleRate
                    : 1
                phaseCount = Self.polyphaseCount(
                    sourceSampleRate: sourceSampleRate,
                    targetSampleRate: targetSampleRate
                )
                coefficients = Self.makeCoefficientTable(
                    phaseCount: phaseCount,
                    cutoffScale: cutoffScale
                )
            }
        }

        if isPassthrough {
            return samples
        }

        sourceBuffer.append(contentsOf: samples)
        totalSourceSamples += Int64(samples.count)
        return emitBandLimitedSamples(allowFuturePadding: false)
    }

    public mutating func reset() {
        configuredSourceRate = nil
        configuredTargetRate = nil
        nextOutputPosition = 0
        isPassthrough = false
        phaseCount = 1
        coefficients.removeAll(keepingCapacity: true)
        sourceBuffer.removeAll(keepingCapacity: true)
        sourceBufferHead = 0
        sourceBufferStart = 0
        totalSourceSamples = 0
    }

    public mutating func finish() throws -> [Float] {
        guard
            configuredSourceRate != nil,
            configuredTargetRate != nil
        else {
            return []
        }

        if isPassthrough {
            return []
        }
        return emitBandLimitedSamples(allowFuturePadding: true)
    }

    private mutating func emitBandLimitedSamples(
        allowFuturePadding: Bool
    ) -> [Float] {
        guard
            let sourceRate = configuredSourceRate,
            let targetRate = configuredTargetRate,
            totalSourceSamples > 0
        else {
            return []
        }

        let sourceStep = sourceRate / targetRate
        let lastPosition = Double(totalSourceSamples - 1)
        let radius = Self.kernelRadius
        let kernelLength = radius * 2 + 1
        var output: [Float] = []
        output.reserveCapacity(
            max(Int(ceil(Double(sourceBuffer.count) / sourceStep)), 0)
        )

        while nextOutputPosition <= lastPosition + 1e-10 {
            var center = Int64(floor(nextOutputPosition))
            let fraction = nextOutputPosition - Double(center)
            var phase = Int((fraction * Double(phaseCount)).rounded())
            if phase == phaseCount {
                phase = 0
                center += 1
            }
            let requiredUpperIndex = center + Int64(radius)
            if !allowFuturePadding, requiredUpperIndex >= totalSourceSamples {
                break
            }

            output.append(
                filteredSample(
                    center: center,
                    phase: phase,
                    kernelLength: kernelLength
                )
            )
            nextOutputPosition += sourceStep
        }

        discardBandLimitedHistory(before: Int64(floor(nextOutputPosition)) - Int64(radius) - 1)
        return output
    }

    private func filteredSample(
        center: Int64,
        phase: Int,
        kernelLength: Int
    ) -> Float {
        let firstSourceIndex = center - Int64(Self.kernelRadius)
        let firstBufferIndex =
            sourceBufferHead + Int(firstSourceIndex - sourceBufferStart)
        let coefficientOffset = phase * kernelLength
        let hasContiguousInput =
            firstSourceIndex >= 0
            && firstSourceIndex + Int64(kernelLength) <= totalSourceSamples
            && firstBufferIndex >= sourceBufferHead
            && firstBufferIndex + kernelLength <= sourceBuffer.count

        if hasContiguousInput {
            var result: Float = 0
            sourceBuffer.withUnsafeBufferPointer { source in
                coefficients.withUnsafeBufferPointer { table in
                    guard
                        let sourceBase = source.baseAddress,
                        let coefficientBase = table.baseAddress
                    else {
                        return
                    }
                    vDSP_dotpr(
                        sourceBase.advanced(by: firstBufferIndex),
                        1,
                        coefficientBase.advanced(by: coefficientOffset),
                        1,
                        &result,
                        vDSP_Length(kernelLength)
                    )
                }
            }
            return result
        }

        var result: Float = 0
        for tap in 0..<kernelLength {
            let sourceIndex = firstSourceIndex + Int64(tap)
            guard sourceIndex >= 0, sourceIndex < totalSourceSamples else {
                continue
            }
            let bufferIndex =
                sourceBufferHead + Int(sourceIndex - sourceBufferStart)
            guard sourceBuffer.indices.contains(bufferIndex) else {
                continue
            }
            result +=
                sourceBuffer[bufferIndex]
                * coefficients[coefficientOffset + tap]
        }
        return result
    }

    private mutating func discardBandLimitedHistory(before sourceIndex: Int64) {
        let discardThrough = max(0, min(sourceIndex, totalSourceSamples))
        guard discardThrough > sourceBufferStart else {
            return
        }

        let count = Int(discardThrough - sourceBufferStart)
        sourceBufferHead += count
        sourceBufferStart = discardThrough
        if sourceBufferHead >= 4_096 {
            sourceBuffer.removeFirst(sourceBufferHead)
            sourceBufferHead = 0
        }
    }

    private static func polyphaseCount(
        sourceSampleRate: Double,
        targetSampleRate: Double
    ) -> Int {
        let roundedSource = sourceSampleRate.rounded()
        let roundedTarget = targetSampleRate.rounded()
        guard
            abs(sourceSampleRate - roundedSource) < 1e-6,
            abs(targetSampleRate - roundedTarget) < 1e-6,
            roundedSource > 0,
            roundedTarget > 0,
            roundedSource <= Double(Int.max),
            roundedTarget <= Double(Int.max)
        else {
            return fallbackPhaseCount
        }

        let source = Int(roundedSource)
        let target = Int(roundedTarget)
        let exactPhaseCount = target / greatestCommonDivisor(source, target)
        return exactPhaseCount <= maximumExactPhaseCount
            ? max(exactPhaseCount, 1)
            : fallbackPhaseCount
    }

    private static func greatestCommonDivisor(_ lhs: Int, _ rhs: Int) -> Int {
        var a = lhs
        var b = rhs
        while b != 0 {
            (a, b) = (b, a % b)
        }
        return max(a, 1)
    }

    private static func makeCoefficientTable(
        phaseCount: Int,
        cutoffScale: Double
    ) -> [Float] {
        let radius = kernelRadius
        let kernelLength = radius * 2 + 1
        var table = [Float](repeating: 0, count: phaseCount * kernelLength)

        for phase in 0..<phaseCount {
            let fraction = Double(phase) / Double(phaseCount)
            let tableOffset = phase * kernelLength
            var weightSum = 0.0

            for tap in 0..<kernelLength {
                let sourceOffset = tap - radius
                let distance = fraction - Double(sourceOffset)
                let normalizedDistance = abs(distance) / Double(radius)
                guard normalizedDistance <= 1 else {
                    continue
                }

                let blackman =
                    0.42
                    + 0.5 * cos(Double.pi * normalizedDistance)
                    + 0.08 * cos(2 * Double.pi * normalizedDistance)
                let scaledDistance = cutoffScale * distance
                let sinc =
                    abs(scaledDistance) < 1e-12
                    ? 1
                    : sin(Double.pi * scaledDistance)
                        / (Double.pi * scaledDistance)
                let weight = cutoffScale * sinc * blackman
                table[tableOffset + tap] = Float(weight)
                weightSum += weight
            }

            guard abs(weightSum) > .leastNonzeroMagnitude else {
                continue
            }
            var reciprocal = Float(1 / weightSum)
            table.withUnsafeMutableBufferPointer { coefficients in
                guard let baseAddress = coefficients.baseAddress else {
                    return
                }
                vDSP_vsmul(
                    baseAddress.advanced(by: tableOffset),
                    1,
                    &reciprocal,
                    baseAddress.advanced(by: tableOffset),
                    1,
                    vDSP_Length(kernelLength)
                )
            }
        }
        return table
    }
}

/// A continuous, chunk-boundary-independent spectrogram analyzer.
///
/// The processor normalizes each independent channel to 48 kHz, performs a
/// 2,048-point Hann-windowed FFT every 1,024 samples, combines stereo in the
/// power domain, and aggregates the maximum power observed in each frequency
/// row into 15 columns per second. Actor isolation ensures one producer can
/// safely be fed from a worker while native and remote clients independently
/// read snapshots.
public actor SpectrogramProcessor {
    public static let analysisSampleRate: Double = 48_000
    public static let fftSize = 2_048
    public static let hopSize = 1_024
    public static let rowCount = 64
    public static let historyCapacity = 64
    public static let columnsPerSecond = 15
    public static let minimumFrequency: Double = 20
    public static let maximumFrequency: Double = 20_000
    public static let decibelFloor: Float = -96

    private static let samplesPerColumn = Int(analysisSampleRate) / columnsPerSecond

    private var leftNormalizer: any SpectrogramSampleRateNormalizing
    private var rightNormalizer: any SpectrogramSampleRateNormalizing
    private let transform: RealDFT

    private var sampleRing: [Float]
    private var rightSampleRing: [Float]
    /// Includes the leading half-window of zero padding.
    private var normalizedSampleCount: UInt64 = UInt64(fftSize / 2)
    private var realNormalizedSampleCount: UInt64 = 0
    private var timelineStartNanoseconds: UInt64?
    private var configuredSourceRate: Double?
    private var hasIndependentRightChannel = false

    private var window: [Float]
    private var windowed: [Float]
    private var evenInput: [Float]
    private var oddInput: [Float]
    private var realOutput: [Float]
    private var imaginaryOutput: [Float]
    private var binPower: [Float]
    private var rowPower: [Float]
    private var aggregatePower: [Float]
    private var aggregateBucket: UInt64?
    private let coherentGain: Float

    private var nextSequence: UInt64 = 0
    private var storedHistory: [SpectrogramColumn] = []
    private var analysisEnabled = true
    private var totalNormalizedSamples: UInt64 = 0
    private var totalTransformOperations: UInt64 = 0
    private var totalEmittedColumns: UInt64 = 0
    private var totalIgnoredInputSamples: UInt64 = 0
    private var totalSTFTScratchAllocationEvents: UInt64

    public init(
        normalizer: any SpectrogramSampleRateNormalizing = LinearSampleRateNormalizer(),
        rightChannelNormalizer: any SpectrogramSampleRateNormalizing =
            LinearSampleRateNormalizer()
    ) throws {
        guard let transform = RealDFT(length: Self.fftSize) else {
            throw SpectrogramError.transformUnavailable
        }
        leftNormalizer = normalizer
        rightNormalizer = rightChannelNormalizer
        self.transform = transform

        var scratchAllocations: UInt64 = 0
        func allocateScratch(count: Int) -> [Float] {
            scratchAllocations &+= 1
            return [Float](repeating: 0, count: count)
        }
        sampleRing = allocateScratch(count: Self.fftSize)
        rightSampleRing = allocateScratch(count: Self.fftSize)
        window = allocateScratch(count: Self.fftSize)
        windowed = allocateScratch(count: Self.fftSize)
        evenInput = allocateScratch(count: Self.fftSize / 2)
        oddInput = allocateScratch(count: Self.fftSize / 2)
        realOutput = allocateScratch(count: Self.fftSize / 2)
        imaginaryOutput = allocateScratch(count: Self.fftSize / 2)
        binPower = allocateScratch(count: Self.fftSize / 2)
        rowPower = allocateScratch(count: Self.rowCount)
        aggregatePower = allocateScratch(count: Self.rowCount)
        totalSTFTScratchAllocationEvents = scratchAllocations

        let denominator = Float(Self.fftSize - 1)
        var gain: Float = 0
        for index in 0..<Self.fftSize {
            let phase = (2 * Float.pi * Float(index)) / denominator
            let value = 0.5 * (1 - cos(phase))
            window[index] = value
            gain += value
        }
        coherentGain = gain
        storedHistory.reserveCapacity(Self.historyCapacity)
    }

    /// Feeds planar audio into the processor and returns any completed
    /// display columns. If `right` is nil, the mono input is used directly.
    ///
    /// `timestampNanoseconds` identifies the first source sample. Subsequent
    /// calls in the same continuous stream derive timestamps from the 48 kHz
    /// normalized sample clock, preventing callback jitter from reaching the
    /// visualization.
    @discardableResult
    public func process(
        left: [Float],
        right: [Float]? = nil,
        sourceSampleRate: Double,
        timestampNanoseconds: UInt64
    ) throws -> [SpectrogramColumn] {
        guard sourceSampleRate.isFinite, sourceSampleRate > 0 else {
            throw SpectrogramError.invalidSampleRate(sourceSampleRate)
        }
        if let right, right.count != left.count {
            throw SpectrogramError.mismatchedChannelCounts(
                left: left.count,
                right: right.count
            )
        }
        guard !left.isEmpty else {
            return []
        }
        guard analysisEnabled else {
            totalIgnoredInputSamples &+= UInt64(left.count)
            return []
        }

        let hasRightChannel = right != nil
        if configuredSourceRate != sourceSampleRate
            || configuredSourceRate != nil
                && hasIndependentRightChannel != hasRightChannel
        {
            resetStreamState(keepingHistory: true)
            configuredSourceRate = sourceSampleRate
            hasIndependentRightChannel = hasRightChannel
        }
        if timelineStartNanoseconds == nil {
            timelineStartNanoseconds = timestampNanoseconds
        }

        let normalizedLeft = try leftNormalizer.normalize(
            left,
            sourceSampleRate: sourceSampleRate,
            targetSampleRate: Self.analysisSampleRate
        )
        let normalizedRight: [Float]?
        if let right {
            normalizedRight = try rightNormalizer.normalize(
                right,
                sourceSampleRate: sourceSampleRate,
                targetSampleRate: Self.analysisSampleRate
            )
            guard normalizedRight?.count == normalizedLeft.count else {
                throw SpectrogramError.mismatchedChannelCounts(
                    left: normalizedLeft.count,
                    right: normalizedRight?.count ?? 0
                )
            }
        } else {
            normalizedRight = nil
        }
        return consume(
            normalizedLeft,
            right: normalizedRight,
            isPadding: false
        )
    }

    /// Emits the final partial time bucket and resets the streaming state.
    ///
    /// Zero-padding is applied only far enough to ensure trailing real samples
    /// participate in an FFT window. History and sequence numbering remain
    /// intact so a reconnect can retain the most recent visualization.
    @discardableResult
    public func finish() throws -> [SpectrogramColumn] {
        guard analysisEnabled else {
            resetStreamState(keepingHistory: true)
            return []
        }
        var columns: [SpectrogramColumn] = []

        let trailingLeft = try leftNormalizer.finish()
        let trailingRight =
            hasIndependentRightChannel
            ? try rightNormalizer.finish()
            : nil
        if !trailingLeft.isEmpty {
            guard
                (trailingRight?.count ?? trailingLeft.count)
                    == trailingLeft.count
            else {
                throw SpectrogramError.mismatchedChannelCounts(
                    left: trailingLeft.count,
                    right: trailingRight?.count ?? 0
                )
            }
            columns.append(
                contentsOf: consume(
                    trailingLeft,
                    right: trailingRight,
                    isPadding: false
                )
            )
        }

        if realNormalizedSampleCount > 0 {
            let lastRealSample = realNormalizedSampleCount - 1
            let hop = UInt64(Self.hopSize)
            let requiredCenter = ((lastRealSample + hop - 1) / hop) * hop
            let requiredTransformEnd = requiredCenter + UInt64(Self.fftSize)
            if requiredTransformEnd > normalizedSampleCount {
                columns.append(
                    contentsOf: consume(
                        [Float](
                            repeating: 0,
                            count: Int(requiredTransformEnd - normalizedSampleCount)
                        ),
                        right: hasIndependentRightChannel
                            ? [Float](
                                repeating: 0,
                                count: Int(requiredTransformEnd - normalizedSampleCount)
                            )
                            : nil,
                        isPadding: true
                    ))
            }
        }

        if aggregateBucket != nil {
            columns.append(emitAggregate())
        }
        resetStreamState(keepingHistory: true)
        return columns
    }

    public func history() -> [SpectrogramColumn] {
        storedHistory
    }

    /// Enables or suspends analysis. Changing this state discards only the
    /// partial current window; history and sequence numbering remain intact.
    public func setAnalysisEnabled(_ enabled: Bool) {
        guard analysisEnabled != enabled else {
            return
        }
        resetStreamState(keepingHistory: true)
        analysisEnabled = enabled
    }

    public func metrics() -> SpectrogramProcessorMetrics {
        SpectrogramProcessorMetrics(
            isAnalysisEnabled: analysisEnabled,
            normalizedSamplesConsumed: totalNormalizedSamples,
            transformOperations: totalTransformOperations,
            emittedColumns: totalEmittedColumns,
            ignoredInputSamples: totalIgnoredInputSamples,
            stftScratchAllocationEvents: totalSTFTScratchAllocationEvents
        )
    }

    /// Clears pending samples, history, and sequence numbering.
    public func reset() {
        resetStreamState(keepingHistory: false)
        totalNormalizedSamples = 0
        totalTransformOperations = 0
        totalEmittedColumns = 0
        totalIgnoredInputSamples = 0
    }

    private func consume(
        _ samples: [Float],
        right: [Float]?,
        isPadding: Bool
    ) -> [SpectrogramColumn] {
        if !isPadding {
            totalNormalizedSamples &+= UInt64(samples.count)
            realNormalizedSampleCount &+= UInt64(samples.count)
        }
        var emitted: [SpectrogramColumn] = []
        emitted.reserveCapacity(max(samples.count / Self.samplesPerColumn, 1))

        for index in samples.indices {
            let sample = samples[index]
            sampleRing[Int(normalizedSampleCount % UInt64(Self.fftSize))] = sample
            rightSampleRing[Int(normalizedSampleCount % UInt64(Self.fftSize))] =
                right?[index] ?? sample
            normalizedSampleCount += 1

            guard normalizedSampleCount >= UInt64(Self.fftSize) else {
                continue
            }
            guard
                (normalizedSampleCount - UInt64(Self.fftSize))
                    % UInt64(Self.hopSize) == 0
            else {
                continue
            }

            calculateRowPower()
            totalTransformOperations &+= hasIndependentRightChannel ? 2 : 1

            let windowCenter = normalizedSampleCount - UInt64(Self.fftSize)
            let finalRealSample =
                realNormalizedSampleCount > 0
                ? realNormalizedSampleCount - 1
                : 0
            let bucket =
                min(windowCenter, finalRealSample)
                / UInt64(Self.samplesPerColumn)
            if let existingBucket = aggregateBucket, bucket != existingBucket {
                emitted.append(emitAggregate())
            }
            aggregateBucket = bucket
            for row in 0..<Self.rowCount {
                aggregatePower[row] = max(aggregatePower[row], rowPower[row])
            }
        }
        return emitted
    }

    private func copyCurrentWindow(from ring: [Float]) {
        let oldestIndex = Int(normalizedSampleCount % UInt64(Self.fftSize))
        let tailCount = Self.fftSize - oldestIndex

        ring.withUnsafeBufferPointer { ringBuffer in
            windowed.withUnsafeMutableBufferPointer { destination in
                guard
                    let ringBase = ringBuffer.baseAddress,
                    let destinationBase = destination.baseAddress
                else {
                    return
                }
                destinationBase.update(
                    from: ringBase.advanced(by: oldestIndex),
                    count: tailCount
                )
                if oldestIndex > 0 {
                    destinationBase.advanced(by: tailCount).update(
                        from: ringBase,
                        count: oldestIndex
                    )
                }
            }
        }

        windowed.withUnsafeMutableBufferPointer { samples in
            window.withUnsafeBufferPointer { coefficients in
                guard
                    let sampleBase = samples.baseAddress,
                    let coefficientBase = coefficients.baseAddress
                else {
                    return
                }
                vDSP_vmul(
                    sampleBase,
                    1,
                    coefficientBase,
                    1,
                    sampleBase,
                    1,
                    vDSP_Length(Self.fftSize)
                )
            }
        }
    }

    private func calculateRowPower() {
        for index in binPower.indices {
            binPower[index] = 0
        }

        copyCurrentWindow(from: sampleRing)
        calculateBinPower(accumulationScale: hasIndependentRightChannel ? 0.5 : 1)
        if hasIndependentRightChannel {
            copyCurrentWindow(from: rightSampleRing)
            calculateBinPower(accumulationScale: 0.5)
        }
        integrateBinPowerIntoRows()
    }

    private func calculateBinPower(accumulationScale: Float) {
        for index in 0..<(Self.fftSize / 2) {
            evenInput[index] = windowed[index * 2]
            oddInput[index] = windowed[index * 2 + 1]
        }

        transform.execute(
            even: &evenInput,
            odd: &oddInput,
            real: &realOutput,
            imaginary: &imaginaryOutput
        )

        let maximumBin = min(
            Self.fftSize / 2 - 1,
            Int(
                ceil(
                    Self.maximumFrequency * Double(Self.fftSize)
                        / Self.analysisSampleRate
                ))
        )
        let normalization = coherentGain * coherentGain

        guard maximumBin >= 1, normalization > 0 else {
            return
        }

        for bin in 1...maximumBin {
            let real = realOutput[bin]
            let imaginary = imaginaryOutput[bin]
            let power =
                (real * real + imaginary * imaginary) / normalization
            binPower[bin] += power * accumulationScale
        }
    }

    /// Integrates a linearly interpolated, non-DC spectrum over each
    /// logarithmic display band.
    ///
    /// Bands narrower than one FFT bin receive the average interpolated
    /// spectral density, while wider bands receive energy normalized to one
    /// bin width. This retains coherent-tone amplitude, gives every low
    /// frequency row a meaningful estimate at 23.4375 Hz resolution, and
    /// never aliases the DC coefficient into the visible 20 Hz row.
    private func integrateBinPowerIntoRows() {
        let binWidth = Self.analysisSampleRate / Double(Self.fftSize)
        let logarithmicRange = log(Self.maximumFrequency / Self.minimumFrequency)

        for row in 0..<Self.rowCount {
            let lowerFrequency =
                Self.minimumFrequency
                * exp(logarithmicRange * Double(row) / Double(Self.rowCount))
            let upperFrequency =
                Self.minimumFrequency
                * exp(logarithmicRange * Double(row + 1) / Double(Self.rowCount))
            let bandWidth = upperFrequency - lowerFrequency
            var integral = 0.0
            var segmentStart = lowerFrequency

            while segmentStart < upperFrequency {
                let nextBinBoundary =
                    (floor(segmentStart / binWidth) + 1) * binWidth
                let segmentEnd = min(upperFrequency, nextBinBoundary)
                let startPower = interpolatedNonDCPower(at: segmentStart)
                let endPower = interpolatedNonDCPower(at: segmentEnd)
                integral +=
                    0.5 * Double(startPower + endPower)
                    * (segmentEnd - segmentStart)
                segmentStart = segmentEnd
            }

            rowPower[row] = Float(
                integral / max(min(bandWidth, binWidth), .leastNonzeroMagnitude)
            )
        }
    }

    private func interpolatedNonDCPower(at frequency: Double) -> Float {
        let binWidth = Self.analysisSampleRate / Double(Self.fftSize)
        let position = frequency / binWidth
        guard position > 1 else {
            return binPower[1]
        }

        let lowerBin = min(
            binPower.count - 1,
            max(1, Int(floor(position)))
        )
        let upperBin = min(binPower.count - 1, lowerBin + 1)
        guard upperBin != lowerBin else {
            return binPower[lowerBin]
        }
        let fraction = Float(position - Double(lowerBin))
        return binPower[lowerBin]
            + fraction * (binPower[upperBin] - binPower[lowerBin])
    }

    private func emitAggregate() -> SpectrogramColumn {
        let bucket = aggregateBucket ?? 0
        let floorPower = pow(10, Self.decibelFloor / 10)
        var intensities = [UInt8](repeating: 0, count: Self.rowCount)

        for row in 0..<Self.rowCount {
            let power = max(aggregatePower[row], floorPower)
            let decibels = max(Self.decibelFloor, min(0, 10 * log10(power)))
            let normalized = (decibels - Self.decibelFloor) / -Self.decibelFloor
            intensities[row] = UInt8(
                max(0, min(255, Int((normalized * 255).rounded())))
            )
            aggregatePower[row] = 0
        }

        let relativeNanoseconds = UInt64(
            (Double((bucket + 1) * UInt64(Self.samplesPerColumn))
                / Self.analysisSampleRate
                * 1_000_000_000).rounded()
        )
        let timestamp = (timelineStartNanoseconds ?? 0)
            .addingReportingOverflow(relativeNanoseconds)
        let column = SpectrogramColumn(
            uncheckedSequence: nextSequence,
            timestampNanoseconds: timestamp.overflow ? UInt64.max : timestamp.partialValue,
            intensities: intensities
        )
        nextSequence &+= 1

        if storedHistory.count == Self.historyCapacity {
            storedHistory.removeFirst()
        }
        storedHistory.append(column)
        totalEmittedColumns &+= 1
        aggregateBucket = nil
        return column
    }

    private func resetStreamState(keepingHistory: Bool) {
        leftNormalizer.reset()
        rightNormalizer.reset()
        for index in sampleRing.indices {
            sampleRing[index] = 0
            rightSampleRing[index] = 0
        }
        for index in aggregatePower.indices {
            aggregatePower[index] = 0
        }
        normalizedSampleCount = UInt64(Self.fftSize / 2)
        realNormalizedSampleCount = 0
        timelineStartNanoseconds = nil
        configuredSourceRate = nil
        hasIndependentRightChannel = false
        aggregateBucket = nil

        if !keepingHistory {
            storedHistory.removeAll(keepingCapacity: true)
            nextSequence = 0
        }
    }
}

private final class RealDFT: @unchecked Sendable {
    private let setup: vDSP_DFT_Setup

    init?(length: Int) {
        guard
            let setup = vDSP_DFT_zrop_CreateSetup(
                nil,
                vDSP_Length(length),
                vDSP_DFT_Direction.FORWARD
            )
        else {
            return nil
        }
        self.setup = setup
    }

    deinit {
        vDSP_DFT_DestroySetup(setup)
    }

    func execute(
        even: inout [Float],
        odd: inout [Float],
        real: inout [Float],
        imaginary: inout [Float]
    ) {
        even.withUnsafeMutableBufferPointer { evenBuffer in
            odd.withUnsafeMutableBufferPointer { oddBuffer in
                real.withUnsafeMutableBufferPointer { realBuffer in
                    imaginary.withUnsafeMutableBufferPointer { imaginaryBuffer in
                        guard
                            let evenBase = evenBuffer.baseAddress,
                            let oddBase = oddBuffer.baseAddress,
                            let realBase = realBuffer.baseAddress,
                            let imaginaryBase = imaginaryBuffer.baseAddress
                        else {
                            return
                        }
                        vDSP_DFT_Execute(
                            setup,
                            evenBase,
                            oddBase,
                            realBase,
                            imaginaryBase
                        )
                    }
                }
            }
        }
    }
}
