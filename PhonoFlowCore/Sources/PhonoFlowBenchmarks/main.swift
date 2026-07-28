import Foundation
import PhonoFlowCore
import Synchronization

private struct BenchmarkMetrics: Codable {
    let spectrogramThroughput: Double
    let nonNativeSpectrogramThroughput: Double
    let spectrumFramesPerSecond: Double
    let captureToPixelP95Milliseconds: Double
    let mainThreadStallMaximumMilliseconds: Double
    let hiddenAnalysisOperations: UInt64
    let maximumPendingFrames: Int
    let steadyStateSTFTAllocations: Int

    private enum CodingKeys: String, CodingKey {
        case spectrogramThroughput = "spectrogram_throughput_x"
        case nonNativeSpectrogramThroughput =
            "non_native_spectrogram_throughput_x"
        case spectrumFramesPerSecond = "spectrum_fps"
        case captureToPixelP95Milliseconds = "capture_to_pixel_p95_ms"
        case mainThreadStallMaximumMilliseconds = "main_thread_stall_max_ms"
        case hiddenAnalysisOperations = "hidden_analysis_operations"
        case maximumPendingFrames = "max_pending_frames"
        case steadyStateSTFTAllocations = "stft_steady_state_allocations"
    }
}

private struct MeasurementDescription: Codable {
    let kind: String
    let source: String
}

private struct BenchmarkReport: Codable {
    let formatVersion: Int
    let metrics: BenchmarkMetrics
    let measurements: [String: MeasurementDescription]
}

private struct Options {
    let outputPath: String
    let iterations: Int

    static func parse(_ arguments: [String]) throws -> Self {
        var outputPath: String?
        var iterations = 5
        var index = 0

        while index < arguments.count {
            switch arguments[index] {
            case "--output":
                index += 1
                guard index < arguments.count else {
                    throw BenchmarkError.missingValue("--output")
                }
                outputPath = arguments[index]

            case "--iterations":
                index += 1
                guard index < arguments.count else {
                    throw BenchmarkError.missingValue("--iterations")
                }
                guard
                    let parsed = Int(arguments[index]),
                    (1...1_000).contains(parsed)
                else {
                    throw BenchmarkError.invalidIterations(arguments[index])
                }
                iterations = parsed

            case "--help", "-h":
                throw BenchmarkError.helpRequested

            default:
                throw BenchmarkError.unknownArgument(arguments[index])
            }
            index += 1
        }

        guard let outputPath else {
            throw BenchmarkError.missingArgument("--output")
        }
        return Self(outputPath: outputPath, iterations: iterations)
    }
}

private enum BenchmarkError: Error, LocalizedError {
    case helpRequested
    case missingArgument(String)
    case missingValue(String)
    case invalidIterations(String)
    case unknownArgument(String)
    case cadence(Double)
    case hiddenAnalysis(UInt64)
    case imageRenderingUnavailable
    case noCaptureToPixelSamples
    case noMainThreadStallSamples
    case noPendingFrameSamples

    var errorDescription: String? {
        switch self {
        case .helpRequested:
            usage
        case .missingArgument(let argument):
            "Missing required argument \(argument).\n\(usage)"
        case .missingValue(let argument):
            "Missing value for \(argument).\n\(usage)"
        case .invalidIterations(let value):
            "Iterations must be an integer from 1 through 1000; received \(value)."
        case .unknownArgument(let argument):
            "Unknown argument \(argument).\n\(usage)"
        case .cadence(let framesPerSecond):
            "Spectrogram cadence was \(framesPerSecond) fps instead of 15 fps."
        case .hiddenAnalysis(let operations):
            "Disabled analysis unexpectedly performed \(operations) transforms."
        case .imageRenderingUnavailable:
            "The shared native spectrogram renderer did not produce an image."
        case .noCaptureToPixelSamples:
            "No capture-to-pixel latency samples were observed."
        case .noMainThreadStallSamples:
            "The main-queue stall probe did not observe a timer tick."
        case .noPendingFrameSamples:
            "The coalesced native-frame mailbox did not observe a publication."
        }
    }

    private var usage: String {
        "Usage: PhonoFlowBenchmarks --output <JSON path or -> --iterations <n>"
    }
}

private struct MainThreadStallMeasurement {
    let maximumStallMilliseconds: Double
    let sampleCount: Int
}

/// Measures actual main-queue scheduling lateness while the benchmark drives
/// the native render/mailbox path. A missing timer sample is an error rather
/// than an assumed zero.
private final class MainThreadStallProbe: @unchecked Sendable {
    private struct State {
        var expectedUptimeNanoseconds: UInt64 = 0
        var maximumStallMilliseconds: Double = 0
        var sampleCount = 0
    }

    private static let intervalNanoseconds: UInt64 = 5_000_000
    private let state = Mutex(State())
    private let timer = Mutex<DispatchSourceTimer?>(nil)

    func start() {
        let firstDeadline =
            DispatchTime.now().uptimeNanoseconds
            + Self.intervalNanoseconds
        state.withLock {
            $0.expectedUptimeNanoseconds = firstDeadline
            $0.maximumStallMilliseconds = 0
            $0.sampleCount = 0
        }

        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(
            deadline: DispatchTime(uptimeNanoseconds: firstDeadline),
            repeating: .nanoseconds(Int(Self.intervalNanoseconds)),
            leeway: .microseconds(100)
        )
        source.setEventHandler { [weak self] in
            self?.recordTick()
        }
        timer.withLock { $0 = source }
        source.resume()
    }

    func stop() -> MainThreadStallMeasurement {
        let source = timer.withLock { value -> DispatchSourceTimer? in
            defer { value = nil }
            return value
        }
        source?.cancel()
        return state.withLock {
            MainThreadStallMeasurement(
                maximumStallMilliseconds: $0.maximumStallMilliseconds,
                sampleCount: $0.sampleCount
            )
        }
    }

    private func recordTick() {
        let now = DispatchTime.now().uptimeNanoseconds
        state.withLock { state in
            guard state.expectedUptimeNanoseconds > 0 else {
                return
            }
            if now > state.expectedUptimeNanoseconds {
                let delay = now - state.expectedUptimeNanoseconds
                state.maximumStallMilliseconds = max(
                    state.maximumStallMilliseconds,
                    Double(delay) / 1_000_000
                )
            }
            state.sampleCount += 1
            state.expectedUptimeNanoseconds &+= Self.intervalNanoseconds
            while state.expectedUptimeNanoseconds <= now {
                state.expectedUptimeNanoseconds &+= Self.intervalNanoseconds
            }
        }
    }
}

@main
private enum PhonoFlowBenchmarks {
    static func main() async {
        do {
            let options = try Options.parse(Array(CommandLine.arguments.dropFirst()))
            let report = try await run(iterations: options.iterations)

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(report)
            if options.outputPath == "-" {
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data([0x0a]))
            } else {
                try data.write(
                    to: URL(fileURLWithPath: options.outputPath),
                    options: .atomic
                )
            }
        } catch BenchmarkError.helpRequested {
            print(BenchmarkError.helpRequested.localizedDescription)
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            Foundation.exit(EXIT_FAILURE)
        }
    }

    private static func run(iterations: Int) async throws -> BenchmarkReport {
        let sampleRate = Int(SpectrogramProcessor.analysisSampleRate)
        let secondsPerIteration = 2
        let frameCount = sampleRate * secondsPerIteration
        let samples = makeFixture(frameCount: frameCount, sampleRate: Double(sampleRate))
        let chunkSize = 1_024

        // Warm Accelerate, Core Graphics, and instruction/data caches outside
        // the measurement while exercising the same production renderer.
        let warmup = try SpectrogramProcessor()
        var warmupColumns = try await warmup.process(
            left: samples,
            sourceSampleRate: Double(sampleRate),
            timestampNanoseconds: 0
        )
        warmupColumns += try await warmup.finish()
        guard
            SpectrogramImageRenderer.makeImage(
                columns: Array(
                    warmupColumns.suffix(SpectrogramProcessor.historyCapacity)
                )
            ) != nil
        else {
            throw BenchmarkError.imageRenderingUnavailable
        }

        var emittedColumnCount = 0
        var captureToPixelDurations: [Double] = []
        captureToPixelDurations.reserveCapacity(
            iterations * secondsPerIteration * SpectrogramProcessor.columnsPerSecond
        )
        var stftScratchAllocationDelta: UInt64 = 0

        let mailbox = CoalescedSpectrogramFrameMailbox()
        mailbox.setPublisher { _ in }
        let mainThreadProbe = MainThreadStallProbe()
        mainThreadProbe.start()
        // Require the main queue to tick before measuring so a broken probe
        // cannot silently report a fabricated zero.
        try await Task.sleep(for: .milliseconds(20))

        let clock = ContinuousClock()
        let benchmarkStart = clock.now
        for _ in 0..<iterations {
            let processor = try SpectrogramProcessor()
            let allocationBaseline =
                await processor.metrics().stftScratchAllocationEvents
            var history: [SpectrogramColumn] = []
            history.reserveCapacity(SpectrogramProcessor.historyCapacity)
            var offset = 0
            var finalCaptureStart = clock.now
            while offset < samples.count {
                let captureStart = clock.now
                finalCaptureStart = captureStart
                let end = min(offset + chunkSize, samples.count)
                let chunk = Array(samples[offset..<end])
                let columns = try await processor.process(
                    left: chunk,
                    sourceSampleRate: Double(sampleRate),
                    timestampNanoseconds: UInt64(
                        Double(offset) / Double(sampleRate) * 1_000_000_000
                    )
                )
                emittedColumnCount += columns.count
                for column in columns {
                    if history.count == SpectrogramProcessor.historyCapacity {
                        history.removeFirst()
                    }
                    history.append(column)
                    guard
                        let image = SpectrogramImageRenderer.makeImage(
                            columns: history
                        )
                    else {
                        throw BenchmarkError.imageRenderingUnavailable
                    }
                    mailbox.offer(
                        SpectrogramRenderFrame(column: column, image: image)
                    )
                    captureToPixelDurations.append(
                        milliseconds(captureStart.duration(to: clock.now))
                    )
                }
                offset = end
            }

            let finalColumns = try await processor.finish()
            emittedColumnCount += finalColumns.count
            for column in finalColumns {
                if history.count == SpectrogramProcessor.historyCapacity {
                    history.removeFirst()
                }
                history.append(column)
                guard
                    let image = SpectrogramImageRenderer.makeImage(
                        columns: history
                    )
                else {
                    throw BenchmarkError.imageRenderingUnavailable
                }
                mailbox.offer(
                    SpectrogramRenderFrame(column: column, image: image)
                )
                captureToPixelDurations.append(
                    milliseconds(finalCaptureStart.duration(to: clock.now))
                )
            }
            let allocationAfter =
                await processor.metrics().stftScratchAllocationEvents
            stftScratchAllocationDelta &+=
                allocationAfter &- allocationBaseline
        }
        let benchmarkEnd = clock.now
        await mailbox.waitUntilIdle()
        let mainThreadMeasurement = mainThreadProbe.stop()

        let audioSeconds = Double(iterations * secondsPerIteration)
        let elapsedSeconds = seconds(benchmarkStart.duration(to: benchmarkEnd))
        let throughput = audioSeconds / max(elapsedSeconds, .leastNonzeroMagnitude)
        let framesPerSecond = Double(emittedColumnCount) / audioSeconds
        let nonNativeThroughput =
            try await measureNonNativeSpectrogramThroughput(
                iterations: iterations
            )

        let hiddenProcessor = try SpectrogramProcessor()
        await hiddenProcessor.setAnalysisEnabled(false)
        let beforeHidden = await hiddenProcessor.metrics()
        _ = try await hiddenProcessor.process(
            left: samples,
            sourceSampleRate: Double(sampleRate),
            timestampNanoseconds: 0
        )
        let afterHidden = await hiddenProcessor.metrics()
        let hiddenOperations =
            afterHidden.transformOperations &- beforeHidden.transformOperations

        guard abs(framesPerSecond - 15) < 0.001 else {
            throw BenchmarkError.cadence(framesPerSecond)
        }
        guard hiddenOperations == 0 else {
            throw BenchmarkError.hiddenAnalysis(hiddenOperations)
        }
        guard !captureToPixelDurations.isEmpty else {
            throw BenchmarkError.noCaptureToPixelSamples
        }
        guard mainThreadMeasurement.sampleCount > 0 else {
            throw BenchmarkError.noMainThreadStallSamples
        }
        guard mailbox.maximumPendingFrames > 0 else {
            throw BenchmarkError.noPendingFrameSamples
        }

        captureToPixelDurations.sort()
        let percentileIndex = min(
            captureToPixelDurations.count - 1,
            max(
                0,
                Int(ceil(Double(captureToPixelDurations.count) * 0.95)) - 1
            )
        )
        return BenchmarkReport(
            formatVersion: 2,
            metrics: BenchmarkMetrics(
                spectrogramThroughput: throughput,
                nonNativeSpectrogramThroughput: nonNativeThroughput,
                spectrumFramesPerSecond: framesPerSecond,
                captureToPixelP95Milliseconds:
                    captureToPixelDurations[percentileIndex],
                mainThreadStallMaximumMilliseconds:
                    mainThreadMeasurement.maximumStallMilliseconds,
                hiddenAnalysisOperations: hiddenOperations,
                maximumPendingFrames: mailbox.maximumPendingFrames,
                steadyStateSTFTAllocations: Int(
                    stftScratchAllocationDelta
                )
            ),
            measurements: [
                "spectrogram_throughput_x": MeasurementDescription(
                    kind: "duration",
                    source:
                        "ContinuousClock around SpectrogramProcessor plus shared native image rendering"
                ),
                "non_native_spectrogram_throughput_x": MeasurementDescription(
                    kind: "duration",
                    source:
                        "ContinuousClock around stereo SpectrogramProcessor conversion from 44.1, 96, and 192 kHz"
                ),
                "spectrum_fps": MeasurementDescription(
                    kind: "counter_delta",
                    source: "Emitted SpectrogramColumn count divided by fixture duration"
                ),
                "capture_to_pixel_p95_ms": MeasurementDescription(
                    kind: "duration_samples",
                    source:
                        "ContinuousClock from captured chunk through SpectrogramProcessor and SpectrogramImageRenderer"
                ),
                "main_thread_stall_max_ms": MeasurementDescription(
                    kind: "timer_lateness",
                    source: "Repeating DispatchSourceTimer scheduled on DispatchQueue.main"
                ),
                "hidden_analysis_operations": MeasurementDescription(
                    kind: "counter_delta",
                    source: "SpectrogramProcessor transform operation counters while disabled"
                ),
                "max_pending_frames": MeasurementDescription(
                    kind: "high_water_mark",
                    source:
                        "CoalescedSpectrogramFrameMailbox publication instrumentation"
                ),
                "stft_steady_state_allocations": MeasurementDescription(
                    kind: "counter_delta",
                    source:
                        "SpectrogramProcessor owned STFT scratch allocation event counters"
                ),
            ]
        )
    }

    private static func measureNonNativeSpectrogramThroughput(
        iterations: Int
    ) async throws -> Double {
        let sourceRates = [44_100.0, 96_000.0, 192_000.0]
        let durationSeconds = 1
        let fixtures = sourceRates.map { sampleRate in
            makeFixture(
                frameCount: Int(sampleRate) * durationSeconds,
                sampleRate: sampleRate
            )
        }
        let chunkSize = 2_048
        let clock = ContinuousClock()
        let start = clock.now

        for _ in 0..<iterations {
            for (fixtureIndex, sampleRate) in sourceRates.enumerated() {
                let samples = fixtures[fixtureIndex]
                let processor = try SpectrogramProcessor()
                var offset = 0
                while offset < samples.count {
                    let end = min(offset + chunkSize, samples.count)
                    let chunk = Array(samples[offset..<end])
                    _ = try await processor.process(
                        left: chunk,
                        right: chunk,
                        sourceSampleRate: sampleRate,
                        timestampNanoseconds: UInt64(
                            Double(offset) / sampleRate * 1_000_000_000
                        )
                    )
                    offset = end
                }
                _ = try await processor.finish()
            }
        }

        let elapsed = seconds(start.duration(to: clock.now))
        let audioSeconds =
            Double(iterations * sourceRates.count * durationSeconds)
        return audioSeconds / max(elapsed, .leastNonzeroMagnitude)
    }

    private static func makeFixture(frameCount: Int, sampleRate: Double) -> [Float] {
        (0..<frameCount).map { frame in
            let time = Double(frame) / sampleRate
            return Float(
                0.55 * sin(2 * Double.pi * 440 * time)
                    + 0.25 * sin(2 * Double.pi * 3_200 * time)
                    + 0.1 * sin(2 * Double.pi * 12_000 * time)
            )
        }
    }

    private static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        seconds(duration) * 1_000
    }
}
