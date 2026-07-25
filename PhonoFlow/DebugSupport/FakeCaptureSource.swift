//
//  FakeCaptureSource.swift
//  PhonoFlow
//
//  Deterministic capture fixture for tests and acceptance harnesses.
//

#if DEBUG
    import Accelerate
    import Darwin
    import Foundation

    /// Deterministic acceptance-only source. The complete implementation is
    /// compiled out of Release builds, so environment variables cannot select
    /// fake capture in production.
    nonisolated final class FakeCaptureSource: @unchecked Sendable {
        private let sharedState: SharedAudioState
        private let sampleRate: Double
        private let frameCount: Int
        private let left: UnsafeMutablePointer<Float>
        private let right: UnsafeMutablePointer<Float>
        private let queue = DispatchQueue(
            label: "com.phonoflow.fake-capture",
            qos: .userInitiated
        )
        private var timer: DispatchSourceTimer?
        private var sampleCursor: UInt64 = 0

        static var isRequestedByEnvironment: Bool {
            let environment = ProcessInfo.processInfo.environment
            return environment["PHONOFLOW_ACCEPTANCE"] == "1"
                && environment["PHONOFLOW_AUDIO_BACKEND"] == "fake"
        }

        init(
            sharedState: SharedAudioState,
            sampleRate: Double,
            frameCount: Int
        ) {
            self.sharedState = sharedState
            self.sampleRate = sampleRate
            self.frameCount = frameCount
            left = .allocate(capacity: frameCount)
            right = .allocate(capacity: frameCount)
            left.initialize(repeating: 0, count: frameCount)
            right.initialize(repeating: 0, count: frameCount)
        }

        deinit {
            timer?.setEventHandler {}
            timer?.cancel()
            left.deallocate()
            right.deallocate()
        }

        func start() {
            guard timer == nil else { return }
            let source = DispatchSource.makeTimerSource(queue: queue)
            let interval = max(
                1,
                Int((Double(frameCount) / sampleRate) * 1_000_000_000)
            )
            source.schedule(
                deadline: .now(),
                repeating: .nanoseconds(interval),
                leeway: .microseconds(100)
            )
            source.setEventHandler { [weak self] in
                self?.produce()
            }
            timer = source
            source.resume()
        }

        func stop() {
            guard let timer else { return }
            timer.setEventHandler {}
            timer.cancel()
            self.timer = nil
            queue.sync {}
        }

        private func produce() {
            let callbackStart = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            defer {
                sharedState.recordCallbackDuration(
                    nanoseconds: clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                        &- callbackStart
                )
            }
            let leftIncrement = 2 * Double.pi * 440 / sampleRate
            let rightIncrement = 2 * Double.pi * 660 / sampleRate
            for frame in 0..<frameCount {
                let position = Double(sampleCursor + UInt64(frame))
                left[frame] = Float(sin(position * leftIncrement) * 0.08)
                right[frame] = Float(sin(position * rightIncrement) * 0.06)
            }
            sampleCursor &+= UInt64(frameCount)

            let parameters = sharedState.getParams()
            if parameters.gain != 1 {
                var gain = parameters.gain
                vDSP_vsmul(
                    left,
                    1,
                    &gain,
                    left,
                    1,
                    vDSP_Length(frameCount)
                )
                vDSP_vsmul(
                    right,
                    1,
                    &gain,
                    right,
                    1,
                    vDSP_Length(frameCount)
                )
            }
            if parameters.meteringEnabled {
                var leftRMS: Float = 0
                var rightRMS: Float = 0
                vDSP_rmsqv(left, 1, &leftRMS, vDSP_Length(frameCount))
                vDSP_rmsqv(right, 1, &rightRMS, vDSP_Length(frameCount))
                sharedState.updatePeak(
                    rms: max(leftRMS, rightRMS),
                    gain: 1
                )
            }
            sharedState.writeStereo(
                left: left,
                right: right,
                count: frameCount,
                captureTimestampNanoseconds: callbackStart
            )
        }
    }
#endif
