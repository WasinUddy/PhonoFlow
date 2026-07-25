import Foundation
import Testing

@testable import PhonoFlowCore

@Suite("Continuous spectrogram processing")
struct SpectrogramProcessorTests {
    @Test("Configuration matches the transport contract")
    func configuration() {
        #expect(SpectrogramProcessor.analysisSampleRate == 48_000)
        #expect(SpectrogramProcessor.fftSize == 2_048)
        #expect(SpectrogramProcessor.hopSize == 1_024)
        #expect(SpectrogramProcessor.rowCount == 64)
        #expect(SpectrogramProcessor.historyCapacity == 64)
        #expect(SpectrogramProcessor.columnsPerSecond == 15)
        #expect(SpectrogramProcessor.decibelFloor == -96)
    }

    @Test("One second produces exactly fifteen ordered columns")
    func cadenceAndTimestamps() async throws {
        let processor = try SpectrogramProcessor()
        let samples = sine(frequency: 1_000, sampleRate: 48_000, frameCount: 48_000)
        let start: UInt64 = 2_000_000_000

        var columns = try await processor.process(
            left: samples,
            sourceSampleRate: 48_000,
            timestampNanoseconds: start
        )
        columns += try await processor.finish()

        #expect(columns.count == 15)
        #expect(columns.map(\.sequence) == Array(0..<15).map(UInt64.init))
        #expect(columns[0].timestampNanoseconds == start + 66_666_667)
        #expect(columns[14].timestampNanoseconds == start + 1_000_000_000)
        #expect(columns.allSatisfy { $0.intensities.count == 64 })
    }

    @Test("Silence maps to the -96 dB floor")
    func silenceFixture() async throws {
        let columns = try await analyze(
            [Float](repeating: 0, count: 9_600),
            sampleRate: 48_000,
            chunkSizes: [137, 509, 1_024, 73]
        )

        #expect(!columns.isEmpty)
        #expect(columns.allSatisfy { $0.intensities.allSatisfy { $0 == 0 } })
    }

    @Test(
        "Tone fixtures land in logarithmic frequency rows",
        arguments: [1_000.0, 10_000.0, 18_000.0]
    )
    func toneFixtures(frequency: Double) async throws {
        let samples = sine(
            frequency: frequency,
            sampleRate: 48_000,
            frameCount: 19_200
        )
        let columns = try await analyze(
            samples,
            sampleRate: 48_000,
            chunkSizes: [1, 31, 257, 2_047, 19]
        )
        let column = try #require(
            columns.max {
                ($0.intensities.max() ?? 0) < ($1.intensities.max() ?? 0)
            })
        let peakRow = try #require(
            column.intensities.indices.max {
                column.intensities[$0] < column.intensities[$1]
            })
        let expectedRow = logarithmicRow(for: frequency)

        #expect(abs(peakRow - expectedRow) <= 1)
        #expect(column.intensities[peakRow] > 245)
    }

    @Test("Signals present in either stereo channel are analyzed")
    func singleStereoChannelFixtures() async throws {
        let tone = sine(
            frequency: 1_000,
            sampleRate: 48_000,
            frameCount: 12_800
        )
        var channelPeaks: [UInt8] = []
        let expectedRow = logarithmicRow(for: 1_000)
        for signalIsLeft in [true, false] {
            let processor = try SpectrogramProcessor()
            let silence = [Float](repeating: 0, count: tone.count)
            var columns = try await processor.process(
                left: signalIsLeft ? tone : silence,
                right: signalIsLeft ? silence : tone,
                sourceSampleRate: 48_000,
                timestampNanoseconds: 0
            )
            columns += try await processor.finish()
            channelPeaks.append(
                columns.map { $0.intensities[expectedRow] }.max() ?? 0
            )
        }

        #expect(channelPeaks.allSatisfy { $0 > 230 })
        #expect(channelPeaks[0] == channelPeaks[1])
    }

    @Test("Anti-phase stereo is combined in the power domain")
    func antiPhaseStereoFixture() async throws {
        let left = sine(
            frequency: 1_000,
            sampleRate: 48_000,
            frameCount: 12_800
        )
        let right = left.map(-)
        let processor = try SpectrogramProcessor()
        var columns = try await processor.process(
            left: left,
            right: right,
            sourceSampleRate: 48_000,
            timestampNanoseconds: 0
        )
        columns += try await processor.finish()

        let expectedRow = logarithmicRow(for: 1_000)
        let peak = columns.map { $0.intensities[expectedRow] }.max() ?? 0
        #expect(peak > 245)
    }

    @Test("Every logarithmic row receives deterministic broadband energy")
    func everyLogarithmicRowIsCovered() async throws {
        let columns = try await analyze(
            seededNoise(count: 19_200),
            sampleRate: 48_000,
            chunkSizes: [17, 509, 2_047, 31]
        )
        let rowPeaks = (0..<SpectrogramProcessor.rowCount).map { row in
            columns.map { $0.intensities[row] }.max() ?? 0
        }

        #expect(rowPeaks.count == 64)
        #expect(rowPeaks.allSatisfy { $0 > 0 })
    }

    @Test("Band-limited normalization retains tone amplitude across device rates")
    func crossRateAmplitudeConsistency() async throws {
        for frequency in [1_000.0, 10_000.0, 18_000.0] {
            let reference = try await tonePeakIntensity(
                frequency: frequency,
                sampleRate: 48_000
            )

            for sampleRate in [44_100.0, 96_000.0, 192_000.0] {
                let converted = try await tonePeakIntensity(
                    frequency: frequency,
                    sampleRate: sampleRate
                )
                #expect(
                    abs(Int(converted) - Int(reference)) <= 5,
                    "Expected \(frequency) Hz at \(sampleRate) Hz to remain within about 2 dB of the 48 kHz reference"
                )
            }
        }
    }

    @Test("Arbitrary callback boundaries do not change output")
    func chunkBoundaryIndependence() async throws {
        var samples = seededNoise(count: 28_117)
        let tone = sine(
            frequency: 3_200,
            sampleRate: 44_100,
            frameCount: samples.count,
            amplitude: 0.6
        )
        for index in samples.indices {
            samples[index] = samples[index] * 0.05 + tone[index]
        }

        let contiguous = try await analyze(
            samples,
            sampleRate: 44_100,
            chunkSizes: [samples.count]
        )
        let fragmented = try await analyze(
            samples,
            sampleRate: 44_100,
            chunkSizes: [1, 2, 7, 63, 511, 4_096, 17]
        )

        #expect(fragmented == contiguous)
    }

    @Test(
        "The 48 kHz normalization seam supports common hardware rates",
        arguments: [44_100.0, 48_000.0, 96_000.0, 192_000.0]
    )
    func sourceRates(sourceRate: Double) async throws {
        let samples = sine(
            frequency: 1_000,
            sampleRate: sourceRate,
            frameCount: Int(sourceRate * 0.4)
        )
        let columns = try await analyze(
            samples,
            sampleRate: sourceRate,
            chunkSizes: [113, 1_023, 4_097, 29]
        )
        let expectedRow = logarithmicRow(for: 1_000)
        let peak = columns.map { $0.intensities[expectedRow] }.max() ?? 0

        #expect(columns.count == 6)
        #expect(peak > 240)
    }

    @Test("DC and impulse fixtures remain finite and bounded")
    func edgeFixtures() async throws {
        let dcColumns = try await analyze(
            [Float](repeating: 0.5, count: 9_600),
            sampleRate: 48_000,
            chunkSizes: [2_048]
        )
        // Centered STFT padding intentionally creates an edge at both ends.
        #expect(
            dcColumns.dropFirst().dropLast().allSatisfy { column in
                let lowFrequencyPeak = column.intensities.prefix(8).max() ?? 0
                let remainingPeak = column.intensities.dropFirst(8).max() ?? 0
                return lowFrequencyPeak > remainingPeak && remainingPeak < 64
            })

        var impulse = [Float](repeating: 0, count: 4_800)
        impulse[1_024] = 1
        let impulseColumns = try await analyze(
            impulse,
            sampleRate: 48_000,
            chunkSizes: [333]
        )
        let activeRows =
            impulseColumns
            .flatMap(\.intensities)
            .filter { $0 > 0 }
            .count
        #expect(activeRows > 16)
    }

    @Test("Multitone fixture preserves separated peaks")
    func multitoneFixture() async throws {
        let frameCount = 19_200
        let low = sine(
            frequency: 250,
            sampleRate: 48_000,
            frameCount: frameCount,
            amplitude: 0.7
        )
        let high = sine(
            frequency: 8_000,
            sampleRate: 48_000,
            frameCount: frameCount,
            amplitude: 0.7
        )
        let samples = zip(low, high).map(+)
        let columns = try await analyze(
            samples,
            sampleRate: 48_000,
            chunkSizes: [2_401, 97]
        )

        let lowRow = logarithmicRow(for: 250)
        let highRow = logarithmicRow(for: 8_000)
        #expect(columns.map { $0.intensities[lowRow] }.max() ?? 0 > 235)
        #expect(columns.map { $0.intensities[highRow] }.max() ?? 0 > 235)
    }

    @Test("History retains only the newest sixty-four columns")
    func boundedHistory() async throws {
        let processor = try SpectrogramProcessor()
        let samples = sine(
            frequency: 440,
            sampleRate: 48_000,
            frameCount: 48_000 * 5
        )
        _ = try await processor.process(
            left: samples,
            sourceSampleRate: 48_000,
            timestampNanoseconds: 0
        )
        _ = try await processor.finish()

        let history = await processor.history()
        #expect(history.count == 64)
        #expect(history.first?.sequence == 11)
        #expect(history.last?.sequence == 74)
    }

    @Test("Suspended analysis performs no normalization or transforms")
    func suspendedAnalysis() async throws {
        let processor = try SpectrogramProcessor()
        await processor.setAnalysisEnabled(false)
        let samples = sine(
            frequency: 1_000,
            sampleRate: 48_000,
            frameCount: 48_000
        )

        #expect(
            try await processor.process(
                left: samples,
                sourceSampleRate: 48_000,
                timestampNanoseconds: 0
            ).isEmpty
        )
        let suspended = await processor.metrics()
        #expect(!suspended.isAnalysisEnabled)
        #expect(suspended.normalizedSamplesConsumed == 0)
        #expect(suspended.transformOperations == 0)
        #expect(suspended.emittedColumns == 0)
        #expect(suspended.ignoredInputSamples == 48_000)

        await processor.setAnalysisEnabled(true)
        _ = try await processor.process(
            left: samples,
            sourceSampleRate: 48_000,
            timestampNanoseconds: 0
        )
        #expect(await processor.metrics().transformOperations > 0)
    }

    @Test("Centered padding preserves impulses at both stream boundaries")
    func boundarySamplesAreCovered() async throws {
        for impulseIndex in [0, 1_023] {
            var samples = [Float](repeating: 0, count: 1_024)
            samples[impulseIndex] = 1
            let columns = try await analyze(
                samples,
                sampleRate: 48_000,
                chunkSizes: [17, 509, 1]
            )

            #expect(
                columns
                    .flatMap(\.intensities)
                    .contains { $0 > 0 }
            )
        }
    }

    @Test(
        "Ultrasonic input is rejected before high-rate decimation",
        arguments: [96_000.0, 192_000.0]
    )
    func downsamplingIsAntiAliased(sourceRate: Double) async throws {
        let duration = 0.6
        let aliasedCandidate = try await analyze(
            sine(
                frequency: 30_000,
                sampleRate: sourceRate,
                frameCount: Int(sourceRate * duration)
            ),
            sampleRate: sourceRate,
            chunkSizes: [113, 1_023, 4_097, 29]
        )
        let audibleControl = try await analyze(
            sine(
                frequency: 18_000,
                sampleRate: sourceRate,
                frameCount: Int(sourceRate * duration)
            ),
            sampleRate: sourceRate,
            chunkSizes: [257, 2_049, 31]
        )
        let aliasRow = logarithmicRow(for: 18_000)
        let aliasLevel =
            aliasedCandidate.dropFirst(2).dropLast(2)
            .map { $0.intensities[aliasRow] }
            .max() ?? 0
        let controlLevel =
            audibleControl.dropFirst(2).dropLast(2)
            .map { $0.intensities[aliasRow] }
            .max() ?? 0

        #expect(aliasLevel < 64)
        #expect(controlLevel > 220)
    }

    @Test("Steady-state transforms reuse all owned STFT scratch storage")
    func steadyStateSTFTScratchIsAllocationFree() async throws {
        let processor = try SpectrogramProcessor()
        let before = await processor.metrics()
        #expect(before.stftScratchAllocationEvents > 0)

        for block in 0..<20 {
            _ = try await processor.process(
                left: sine(
                    frequency: 1_000,
                    sampleRate: 48_000,
                    frameCount: 2_048
                ),
                sourceSampleRate: 48_000,
                timestampNanoseconds: UInt64(block) * 42_666_667
            )
        }
        _ = try await processor.finish()
        let after = await processor.metrics()

        #expect(
            after.stftScratchAllocationEvents
                == before.stftScratchAllocationEvents
        )
        #expect(after.transformOperations > before.transformOperations)
    }

    @Test("Invalid channel and sample-rate inputs report typed errors")
    func validation() async throws {
        let processor = try SpectrogramProcessor()

        await #expect(throws: SpectrogramError.invalidSampleRate(0)) {
            try await processor.process(
                left: [0],
                sourceSampleRate: 0,
                timestampNanoseconds: 0
            )
        }
        await #expect(
            throws: SpectrogramError.mismatchedChannelCounts(left: 2, right: 1)
        ) {
            try await processor.process(
                left: [0, 0],
                right: [0],
                sourceSampleRate: 48_000,
                timestampNanoseconds: 0
            )
        }
    }

    @Test("Column decoding enforces the sixty-four-byte payload")
    func columnCodableInvariant() throws {
        let valid = try SpectrogramColumn(
            sequence: 7,
            timestampNanoseconds: 42,
            intensities: [UInt8](repeating: 8, count: 64)
        )
        let encoded = try JSONEncoder().encode(valid)
        #expect(try JSONDecoder().decode(SpectrogramColumn.self, from: encoded) == valid)

        let invalid = Data(
            #"{"sequence":0,"timestampNanoseconds":0,"intensities":[1,2]}"#.utf8
        )
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(SpectrogramColumn.self, from: invalid)
        }
    }
}

@Suite("Streaming sample-rate normalizer")
struct LinearSampleRateNormalizerTests {
    @Test("Chunking does not affect normalized samples")
    func chunking() throws {
        let input = (0..<1_001).map { Float($0) / 1_000 }
        var contiguous = LinearSampleRateNormalizer()
        var fragmented = LinearSampleRateNormalizer()

        var expected = try contiguous.normalize(
            input,
            sourceSampleRate: 44_100,
            targetSampleRate: 48_000
        )
        expected += try contiguous.finish()

        var actual: [Float] = []
        var offset = 0
        let sizes = [1, 17, 128, 3, 509]
        var sizeIndex = 0
        while offset < input.count {
            let size = min(sizes[sizeIndex % sizes.count], input.count - offset)
            actual += try fragmented.normalize(
                Array(input[offset..<(offset + size)]),
                sourceSampleRate: 44_100,
                targetSampleRate: 48_000
            )
            offset += size
            sizeIndex += 1
        }
        actual += try fragmented.finish()

        #expect(actual == expected)
    }

    @Test(
        "Band-limited downsampling is callback-boundary independent",
        arguments: [96_000.0, 192_000.0]
    )
    func downsampleChunking(sourceRate: Double) throws {
        let input = seededNoise(count: Int(sourceRate * 0.1))
        var contiguous = LinearSampleRateNormalizer()
        var fragmented = LinearSampleRateNormalizer()

        var expected = try contiguous.normalize(
            input,
            sourceSampleRate: sourceRate,
            targetSampleRate: 48_000
        )
        expected += try contiguous.finish()

        var actual: [Float] = []
        var offset = 0
        let sizes = [1, 31, 257, 2_047, 19]
        var sizeIndex = 0
        while offset < input.count {
            let size = min(sizes[sizeIndex % sizes.count], input.count - offset)
            actual += try fragmented.normalize(
                Array(input[offset..<(offset + size)]),
                sourceSampleRate: sourceRate,
                targetSampleRate: 48_000
            )
            offset += size
            sizeIndex += 1
        }
        actual += try fragmented.finish()

        #expect(actual == expected)
    }

    @Test("Invalid rates are rejected")
    func rates() {
        var normalizer = LinearSampleRateNormalizer()
        #expect(throws: SpectrogramError.invalidSampleRate(.infinity)) {
            try normalizer.normalize(
                [0],
                sourceSampleRate: .infinity,
                targetSampleRate: 48_000
            )
        }
    }
}

private func analyze(
    _ samples: [Float],
    sampleRate: Double,
    chunkSizes: [Int]
) async throws -> [SpectrogramColumn] {
    let processor = try SpectrogramProcessor()
    var columns: [SpectrogramColumn] = []
    var offset = 0
    var chunkIndex = 0

    while offset < samples.count {
        let requested = max(chunkSizes[chunkIndex % chunkSizes.count], 1)
        let count = min(requested, samples.count - offset)
        columns += try await processor.process(
            left: Array(samples[offset..<(offset + count)]),
            sourceSampleRate: sampleRate,
            timestampNanoseconds: UInt64(
                (Double(offset) / sampleRate * 1_000_000_000).rounded()
            )
        )
        offset += count
        chunkIndex += 1
    }
    columns += try await processor.finish()
    return columns
}

private func sine(
    frequency: Double,
    sampleRate: Double,
    frameCount: Int,
    amplitude: Float = 1
) -> [Float] {
    (0..<frameCount).map { index in
        amplitude * Float(sin(2 * Double.pi * frequency * Double(index) / sampleRate))
    }
}

private func tonePeakIntensity(
    frequency: Double,
    sampleRate: Double
) async throws -> UInt8 {
    let columns = try await analyze(
        sine(
            frequency: frequency,
            sampleRate: sampleRate,
            frameCount: Int(sampleRate * 0.6),
            amplitude: 0.1
        ),
        sampleRate: sampleRate,
        chunkSizes: [113, 1_023, 4_097, 29]
    )
    let stableColumns = columns.dropFirst(2).dropLast(2)
    let row = logarithmicRow(for: frequency)
    return stableColumns.map { $0.intensities[row] }.max() ?? 0
}

private func logarithmicRow(for frequency: Double) -> Int {
    let position =
        log(
            frequency / SpectrogramProcessor.minimumFrequency
        )
        / log(
            SpectrogramProcessor.maximumFrequency
                / SpectrogramProcessor.minimumFrequency
        )
    return min(
        SpectrogramProcessor.rowCount - 1,
        max(0, Int(floor(position * Double(SpectrogramProcessor.rowCount))))
    )
}

private func seededNoise(count: Int) -> [Float] {
    var state: UInt64 = 0xC0FFEE
    return (0..<count).map { _ in
        state = state &* 6_364_136_223_846_793_005 &+ 1
        let unit = Float(state >> 40) / Float(1 << 24)
        return unit * 2 - 1
    }
}
