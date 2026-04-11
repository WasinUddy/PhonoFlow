//
//  AudioMonitor.swift
//  PhonoFlow
//
//  High-fidelity stereo audio monitoring with real-time DSP:
//  - 10-band parametric EQ (biquad, Transposed Direct Form II)
//  - Soft limiter (tanh-based, transparent below threshold)
//  - Clock drift compensation (Catmull-Rom cubic resampling, same-device bypass)
//  - DC offset removal (first-order high-pass)
//  - Output sample rate matching (eliminates HAL resampling)
//

import Accelerate
import AudioToolbox
import CoreAudio
import Foundation
import os.lock

// MARK: - Configuration

private enum AudioConfig {
    static let eqBandCount = 10
    static let eqFrequencies: [Float] = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    static let eqQ: Float = 1.414 // sqrt(2), standard graphic EQ bandwidth
    static let softLimitThreshold: Float = 0.891 // -1 dBFS
    static let ringCapacity = 4096
    static let workCapacity = 4096
    static let driftTarget = 1024  // ~23 ms at 44.1 kHz — tighter for lower latency
    static let driftThreshold = 128 // correct drift early and often
    static let targetBufferFrames: UInt32 = 256
}

// MARK: - Audio Monitor

@Observable
class AudioMonitor {
    var peakLevel: Float = 0
    var gain: Float = 1.0
    var isMonitoring = false
    var isPassthroughEnabled = false
    var isStreamingEnabled = false
    var streamURL: String = ""
    var isAutoGainEnabled: Bool = false {
        didSet {
            if isAutoGainEnabled {
                startAutoGain()
            } else {
                stopAutoGain()
            }
        }
    }

    // Visualization data
    var leftWaveform: [Float] = Array(repeating: 0, count: 200)
    var rightWaveform: [Float] = Array(repeating: 0, count: 200)
    var phasePoints: [(x: Float, y: Float)] = []
    var leftLevel: Float = 0
    var rightLevel: Float = 0
    var spectrogramData: [[Float]] = []

    @MainActor var eqBands: [Float] = Array(repeating: 0, count: AudioConfig.eqBandCount) {
        didSet {
            sharedState.updateEQCoefficients(bands: eqBands, sampleRate: Float(captureSampleRate))
        }
    }

    private var inputUnit: AudioUnit?
    private var outputUnit: AudioUnit?
    private var inputDeviceID: AudioDeviceID = 0
    private var outputDeviceID: AudioDeviceID = 0

    private let sharedState = SharedAudioState()
    private let streamServer = AudioStreamServer()
    private(set) var captureSampleRate: Double = 44100

    var isMeteringEnabled: Bool = false {
        didSet {
            sharedState.setMeteringEnabled(isMeteringEnabled)
        }
    }

    func startMonitoring(deviceID: AudioDeviceID, outputDeviceID: AudioDeviceID?) {
        stopMonitoring()

        inputDeviceID = deviceID
        self.outputDeviceID = outputDeviceID ?? deviceID

        guard setupInputUnit(deviceID: deviceID),
              setupOutputUnit(deviceID: self.outputDeviceID) else {
            stopMonitoring()
            return
        }

        sharedState.sameDevice = (inputDeviceID == self.outputDeviceID)
        sharedState.setGain(gain)
        sharedState.setVolume(isPassthroughEnabled ? gain : 0)
        sharedState.setMeteringEnabled(isMeteringEnabled)

        AudioOutputUnitStart(inputUnit!)
        if isPassthroughEnabled {
            AudioOutputUnitStart(outputUnit!)
        }

        isMonitoring = true

        // Always start UI update timer for visualizations and metering
        startUIUpdateTimer()
    }

    func stopMonitoring() {
        stopUIUpdateTimer()
        isPassthroughEnabled = false
        stopStreaming()

        if let unit = inputUnit {
            AudioOutputUnitStop(unit)
            AudioComponentInstanceDispose(unit)
            inputUnit = nil
        }

        if let unit = outputUnit {
            AudioOutputUnitStop(unit)
            AudioComponentInstanceDispose(unit)
            outputUnit = nil
        }

        isMonitoring = false
        peakLevel = 0
        sharedState.reset()
    }

    // MARK: - Passthrough

    func enablePassthrough() {
        guard outputUnit != nil else { return }
        isPassthroughEnabled = true
        sharedState.setVolume(gain)
        sharedState.setGain(gain)
        AudioOutputUnitStart(outputUnit!)
    }

    func disablePassthrough() {
        guard outputUnit != nil else { return }
        isPassthroughEnabled = false
        sharedState.setVolume(0)
        AudioOutputUnitStop(outputUnit!)
    }

    func updatePassthroughOutput(deviceID: AudioDeviceID) {
        guard isMonitoring else { return }
        outputDeviceID = deviceID

        if let unit = outputUnit {
            AudioOutputUnitStop(unit)
            AudioComponentInstanceDispose(unit)
        }

        if setupOutputUnit(deviceID: deviceID), isPassthroughEnabled {
            AudioOutputUnitStart(outputUnit!)
        }
    }

    func updatePassthroughVolume() {
        sharedState.setVolume(isPassthroughEnabled ? gain : 0)
        sharedState.setGain(gain)
    }

    // MARK: - Streaming

    func startStreaming(port: UInt16 = 7865, allowedHosts: [String] = []) {
        guard !isStreamingEnabled else { return }
        do {
            streamServer.allowedHosts = allowedHosts
            try streamServer.start(port: port, sampleRate: captureSampleRate)
            isStreamingEnabled = true
            let ip = AudioStreamServer.localIPAddress() ?? "localhost"
            streamURL = "http://\(ip):\(port)"
        } catch {
            isStreamingEnabled = false
            streamURL = ""
        }
    }

    func stopStreaming() {
        streamServer.stop()
        isStreamingEnabled = false
        streamURL = ""
    }

    // MARK: - Audio Unit Setup

    private func setupInputUnit(deviceID: AudioDeviceID) -> Bool {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        guard let component = AudioComponentFindNext(nil, &desc) else { return false }

        var unit: AudioUnit?
        guard AudioComponentInstanceNew(component, &unit) == noErr,
              let unit = unit else { return false }

        var enableIO: UInt32 = 1
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO,
                           kAudioUnitScope_Input, 1, &enableIO, UInt32(MemoryLayout<UInt32>.size))
        enableIO = 0
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO,
                           kAudioUnitScope_Output, 0, &enableIO, UInt32(MemoryLayout<UInt32>.size))

        var deviceIDVar = deviceID
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                           kAudioUnitScope_Global, 0, &deviceIDVar, UInt32(MemoryLayout<AudioDeviceID>.size))

        setDeviceBufferSize(deviceID)

        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat,
                           kAudioUnitScope_Input, 1, &asbd, &size)

        captureSampleRate = asbd.mSampleRate
        let channelCount = asbd.mChannelsPerFrame

        asbd.mFormatID = kAudioFormatLinearPCM
        asbd.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved
        asbd.mBitsPerChannel = 32
        asbd.mBytesPerFrame = 4
        asbd.mBytesPerPacket = 4
        asbd.mFramesPerPacket = 1
        asbd.mChannelsPerFrame = channelCount

        AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat,
                           kAudioUnitScope_Output, 1, &asbd, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))

        sharedState.channelCount = Int(channelCount)
        sharedState.updateDCFilterCoefficient(sampleRate: Float(captureSampleRate))
        sharedState.updateEQCoefficients(bands: Array(repeating: 0, count: AudioConfig.eqBandCount),
                                         sampleRate: Float(captureSampleRate))

        let state = Unmanaged.passUnretained(sharedState).toOpaque()

        var callbackStruct = AURenderCallbackStruct(
            inputProc: inputRenderCallback,
            inputProcRefCon: UnsafeMutableRawPointer(mutating: state)
        )
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback,
                           kAudioUnitScope_Global, 0, &callbackStruct, UInt32(MemoryLayout<AURenderCallbackStruct>.size))

        sharedState.streamServerPtr = Unmanaged.passUnretained(streamServer).toOpaque()
        sharedState.inputUnit = unit

        AudioUnitInitialize(unit)
        inputUnit = unit
        return true
    }

    private func setupOutputUnit(deviceID: AudioDeviceID) -> Bool {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        guard let component = AudioComponentFindNext(nil, &desc) else { return false }

        var unit: AudioUnit?
        guard AudioComponentInstanceNew(component, &unit) == noErr,
              let unit = unit else { return false }

        var deviceIDVar = deviceID
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                           kAudioUnitScope_Global, 0, &deviceIDVar, UInt32(MemoryLayout<AudioDeviceID>.size))

        // Match output device sample rate to input — eliminates HAL resampling
        setOutputDeviceSampleRate(deviceID, sampleRate: captureSampleRate)
        setDeviceBufferSize(deviceID)

        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat,
                           kAudioUnitScope_Input, 0, &asbd, &size)

        let channelCount = asbd.mChannelsPerFrame
        asbd.mFormatID = kAudioFormatLinearPCM
        asbd.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved
        asbd.mSampleRate = captureSampleRate
        asbd.mBitsPerChannel = 32
        asbd.mBytesPerFrame = 4
        asbd.mBytesPerPacket = 4
        asbd.mFramesPerPacket = 1
        asbd.mChannelsPerFrame = channelCount

        AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat,
                           kAudioUnitScope_Input, 0, &asbd, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))

        let state = Unmanaged.passUnretained(sharedState).toOpaque()
        var callbackStruct = AURenderCallbackStruct(
            inputProc: outputRenderCallback,
            inputProcRefCon: UnsafeMutableRawPointer(mutating: state)
        )
        AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback,
                           kAudioUnitScope_Input, 0, &callbackStruct, UInt32(MemoryLayout<AURenderCallbackStruct>.size))

        AudioUnitInitialize(unit)
        outputUnit = unit
        return true
    }

    private func setOutputDeviceSampleRate(_ deviceID: AudioDeviceID, sampleRate: Double) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate = sampleRate
        AudioObjectSetPropertyData(deviceID, &address, 0, nil,
                                  UInt32(MemoryLayout<Double>.size), &rate)
    }

    private func setDeviceBufferSize(_ deviceID: AudioDeviceID) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var newSize = AudioConfig.targetBufferFrames
        AudioObjectSetPropertyData(deviceID, &address, 0, nil,
                                  UInt32(MemoryLayout<UInt32>.size), &newSize)
    }

    // MARK: - UI Updates

    private var uiUpdateTimer: Timer?

    func startUIUpdateTimer() {
        // Prevent stacking multiple timers
        uiUpdateTimer?.invalidate()

        uiUpdateTimer = Timer.scheduledTimer(withTimeInterval: 1.0/20.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }

            // Update peak level only if metering is enabled
            if self.isMeteringEnabled {
                self.peakLevel = self.sharedState.getPeakLevel()
            }

            // Always update visualization data (works in all modes)
            self.updateVisualizationData()
        }
        if let timer = uiUpdateTimer {
            RunLoop.current.add(timer, forMode: .common)
        }
    }

    // FFT setup (reused across calls)
    private var fftSetup: FFTSetup?
    private let fftLog2N: vDSP_Length = 8  // 256 samples
    private let fftSize = 256

    private func updateVisualizationData() {
        let bufferSize = 512
        let leftBuf = UnsafeMutablePointer<Float>.allocate(capacity: bufferSize)
        let rightBuf = UnsafeMutablePointer<Float>.allocate(capacity: bufferSize)
        defer {
            leftBuf.deallocate()
            rightBuf.deallocate()
        }

        let count = sharedState.peekStereoRecent(left: leftBuf, right: rightBuf, count: bufferSize)
        guard count > 0 else { return }

        // Update waveform data (first 200 samples)
        let waveformCount = min(200, count)
        leftWaveform = Array(UnsafeBufferPointer(start: leftBuf, count: waveformCount))
        rightWaveform = Array(UnsafeBufferPointer(start: rightBuf, count: waveformCount))

        // Update phase scope points (downsample to 100 points)
        let step = max(waveformCount / 100, 1)
        phasePoints = stride(from: 0, to: waveformCount, by: step).map { i in
            (x: leftBuf[i], y: rightBuf[i])
        }

        // Update separate L/R levels — scale RMS to 0-1 meter range with smoothing
        var leftRms: Float = 0, rightRms: Float = 0
        vDSP_rmsqv(leftBuf, 1, &leftRms, vDSP_Length(count))
        vDSP_rmsqv(rightBuf, 1, &rightRms, vDSP_Length(count))

        let scaledLeft = min(leftRms * 4.0 * gain, 1.0)
        let scaledRight = min(rightRms * 4.0 * gain, 1.0)

        // Smooth: fast attack (0.85), slow decay (0.25)
        let attackL: Float = scaledLeft > leftLevel ? 0.85 : 0.25
        let attackR: Float = scaledRight > rightLevel ? 0.85 : 0.25
        leftLevel += attackL * (scaledLeft - leftLevel)
        rightLevel += attackR * (scaledRight - rightLevel)

        // Update spectrogram with FFT
        if count >= fftSize {
            if fftSetup == nil {
                fftSetup = vDSP_create_fftsetup(fftLog2N, FFTRadix(kFFTRadix2))
            }

            if let setup = fftSetup {
                let spectrum = computeFFTSpectrum(samples: leftBuf, count: fftSize, setup: setup)

                // Add to spectrogram history (keep last 100 frames)
                spectrogramData.append(spectrum)
                if spectrogramData.count > 100 {
                    spectrogramData.removeFirst()
                }
            }
        }
    }

    private func computeFFTSpectrum(samples: UnsafePointer<Float>, count: Int, setup: FFTSetup) -> [Float] {
        let halfSize = count / 2

        var realp = [Float](repeating: 0, count: halfSize)
        var imagp = [Float](repeating: 0, count: halfSize)

        return realp.withUnsafeMutableBufferPointer { realBuffer in
            imagp.withUnsafeMutableBufferPointer { imagBuffer in
                var output = DSPSplitComplex(realp: realBuffer.baseAddress!, imagp: imagBuffer.baseAddress!)

                // Convert samples to split complex format
                samples.withMemoryRebound(to: DSPComplex.self, capacity: halfSize) { complexSamples in
                    vDSP_ctoz(complexSamples, 2, &output, 1, vDSP_Length(halfSize))
                }

                // Perform FFT
                vDSP_fft_zrip(setup, &output, 1, fftLog2N, FFTDirection(FFT_FORWARD))

                // Compute magnitude
                var magnitudes = [Float](repeating: 0, count: halfSize)
                vDSP_zvabs(&output, 1, &magnitudes, 1, vDSP_Length(halfSize))

                // Convert to dB and normalize
                var normalizedMagnitudes = [Float](repeating: 0, count: halfSize)
                for i in 0..<halfSize {
                    let db = 20 * log10(max(magnitudes[i], 0.00001))
                    normalizedMagnitudes[i] = max(0, min(1, (db + 80) / 80))  // Map -80dB to 0dB → 0 to 1
                }

                return normalizedMagnitudes
            }
        }
    }

    deinit {
        if let setup = fftSetup {
            vDSP_destroy_fftsetup(setup)
        }
    }

    private func stopUIUpdateTimer() {
        uiUpdateTimer?.invalidate()
        uiUpdateTimer = nil
    }

    // MARK: - Auto-Gain

    private var autoGainTimer: Timer?
    private let autoGainTargetLevel: Float = 0.5  // -6 dBFS (safe headroom)
    private let autoGainMinLevel: Float = 0.01    // -40 dBFS (ignore very quiet signals)
    private let autoGainSmoothingFactor: Float = 0.1  // Slow, smooth adjustments

    func startAutoGain() {
        autoGainTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.adjustAutoGain()
        }
        if let timer = autoGainTimer {
            RunLoop.current.add(timer, forMode: .common)
        }
    }

    func stopAutoGain() {
        autoGainTimer?.invalidate()
        autoGainTimer = nil
    }

    private func adjustAutoGain() {
        guard isAutoGainEnabled, peakLevel > autoGainMinLevel else { return }

        // Calculate target gain: scale current peak to target level
        let targetGain = autoGainTargetLevel / peakLevel

        // Clamp to reasonable range (0.1x to 4.0x)
        let clampedTarget = max(0.1, min(4.0, targetGain))

        // Smoothly interpolate current gain toward target
        gain += autoGainSmoothingFactor * (clampedTarget - gain)

        // Update passthrough volume if enabled
        if isPassthroughEnabled {
            sharedState.setGain(gain)
            sharedState.setVolume(gain)
        }
    }
}

// MARK: - Ring Buffer (no internal locking — caller synchronizes)

private class RingBuffer {
    private let buffer: UnsafeMutablePointer<Float>
    private let capacity: Int
    private var writePos = 0
    private var readPos = 0
    private(set) var available = 0

    init(capacity: Int) {
        self.capacity = capacity
        buffer = .allocate(capacity: capacity)
        buffer.initialize(repeating: 0, count: capacity)
    }

    deinit { buffer.deallocate() }

    func reset() {
        writePos = 0
        readPos = 0
        available = 0
    }

    func write(_ data: UnsafePointer<Float>, count: Int) {
        let toWrite = min(count, capacity)
        let firstChunk = min(toWrite, capacity - writePos)
        memcpy(buffer + writePos, data, firstChunk * MemoryLayout<Float>.stride)
        if firstChunk < toWrite {
            memcpy(buffer, data + firstChunk, (toWrite - firstChunk) * MemoryLayout<Float>.stride)
        }
        writePos = (writePos + toWrite) % capacity

        // Advance read pointer if we overwrote unread data
        available += toWrite
        if available > capacity {
            let overflow = available - capacity
            readPos = (readPos + overflow) % capacity
            available = capacity
        }
    }

    func read(_ data: UnsafeMutablePointer<Float>, count: Int) -> Int {
        let toRead = min(count, available)
        let firstChunk = min(toRead, capacity - readPos)
        memcpy(data, buffer + readPos, firstChunk * MemoryLayout<Float>.stride)
        if firstChunk < toRead {
            memcpy(data + firstChunk, buffer, (toRead - firstChunk) * MemoryLayout<Float>.stride)
        }
        readPos = (readPos + toRead) % capacity
        available -= toRead
        if toRead < count {
            memset(data + toRead, 0, (count - toRead) * MemoryLayout<Float>.stride)
        }
        return toRead
    }

    // Peek at most recent data without consuming it
    func peekRecent(_ data: UnsafeMutablePointer<Float>, count: Int) -> Int {
        let toPeek = min(count, available)
        guard toPeek > 0 else { return 0 }

        // Calculate starting position for most recent samples
        let peekStart = (writePos - toPeek + capacity) % capacity
        let firstChunk = min(toPeek, capacity - peekStart)
        memcpy(data, buffer + peekStart, firstChunk * MemoryLayout<Float>.stride)
        if firstChunk < toPeek {
            memcpy(data + firstChunk, buffer, (toPeek - firstChunk) * MemoryLayout<Float>.stride)
        }
        return toPeek
    }
}

// MARK: - Shared Audio State

private class SharedAudioState {
    // Stereo ring buffers with a single lock for atomic L/R access
    private var ringLock = os_unfair_lock()
    private var leftRing = RingBuffer(capacity: AudioConfig.ringCapacity)
    private var rightRing = RingBuffer(capacity: AudioConfig.ringCapacity)

    // Parameter lock — protects gain, volume, metering, peak, and EQ coefficient transfer
    private var paramLock = os_unfair_lock()
    private var _smoothedPeak: Float = 0
    private var _volume: Float = 0
    private var _gain: Float = 1.0
    private var _meteringEnabled: Bool = false

    // EQ coefficient staging area — written by main thread, read by audio thread
    // Layout: band * 5 + coeff_index → [b0, b1, b2, a1, a2] per band
    private let eqCoeffsStaging: UnsafeMutablePointer<Float>
    private var eqVersion: UInt32 = 0
    private var eqActive: Bool = false

    // EQ processing state — only touched by the input callback thread
    let eqCoeffs: UnsafeMutablePointer<Float>      // 10 bands × 5 coefficients = 50 floats
    let eqStateL: UnsafeMutablePointer<Float>       // 10 bands × 2 state vars = 20 floats
    let eqStateR: UnsafeMutablePointer<Float>       // 10 bands × 2 state vars = 20 floats
    var cachedEqVersion: UInt32 = 0
    var cachedEqActive: Bool = false

    var streamServerPtr: UnsafeMutableRawPointer?
    var inputUnit: AudioUnit?
    var channelCount: Int = 2
    var sameDevice: Bool = false

    // DC offset filter state (input callback thread only)
    var dcLeftPrevX: Float = 0
    var dcLeftPrevY: Float = 0
    var dcRightPrevX: Float = 0
    var dcRightPrevY: Float = 0
    var dcFilterR: Float = 0.9972

    // Pre-allocated work buffers
    private static let cap = AudioConfig.workCapacity
    let workLeft: UnsafeMutablePointer<Float>
    let workRight: UnsafeMutablePointer<Float>
    let workInterleaved: UnsafeMutablePointer<Float>
    let workOutL: UnsafeMutablePointer<Float>
    let workOutR: UnsafeMutablePointer<Float>

    init() {
        let c = SharedAudioState.cap
        workLeft = .allocate(capacity: c); workLeft.initialize(repeating: 0, count: c)
        workRight = .allocate(capacity: c); workRight.initialize(repeating: 0, count: c)
        workInterleaved = .allocate(capacity: c * 2); workInterleaved.initialize(repeating: 0, count: c * 2)
        workOutL = .allocate(capacity: c); workOutL.initialize(repeating: 0, count: c)
        workOutR = .allocate(capacity: c); workOutR.initialize(repeating: 0, count: c)

        let coeffCount = AudioConfig.eqBandCount * 5
        let stateCount = AudioConfig.eqBandCount * 2
        eqCoeffsStaging = .allocate(capacity: coeffCount); eqCoeffsStaging.initialize(repeating: 0, count: coeffCount)
        eqCoeffs = .allocate(capacity: coeffCount); eqCoeffs.initialize(repeating: 0, count: coeffCount)
        eqStateL = .allocate(capacity: stateCount); eqStateL.initialize(repeating: 0, count: stateCount)
        eqStateR = .allocate(capacity: stateCount); eqStateR.initialize(repeating: 0, count: stateCount)

        // Initialize all bands to unity passthrough: b0=1, rest=0
        for i in 0..<AudioConfig.eqBandCount {
            eqCoeffsStaging[i * 5] = 1.0
            eqCoeffs[i * 5] = 1.0
        }
    }

    deinit {
        workLeft.deallocate(); workRight.deallocate()
        workInterleaved.deallocate()
        workOutL.deallocate(); workOutR.deallocate()
        eqCoeffsStaging.deallocate(); eqCoeffs.deallocate()
        eqStateL.deallocate(); eqStateR.deallocate()
    }

    // MARK: - DC Filter

    func updateDCFilterCoefficient(sampleRate: Float) {
        dcFilterR = expf(-2.0 * Float.pi * 20.0 / sampleRate)
    }

    // MARK: - EQ Coefficient Computation

    func updateEQCoefficients(bands: [Float], sampleRate: Float) {
        guard sampleRate > 0 else { return }
        let active = !bands.allSatisfy { $0 == 0 }

        os_unfair_lock_lock(&paramLock)
        for i in 0..<min(bands.count, AudioConfig.eqBandCount) {
            let (b0, b1, b2, a1, a2) = computePeakingEQ(
                freq: AudioConfig.eqFrequencies[i],
                gainDB: bands[i],
                Q: AudioConfig.eqQ,
                sampleRate: sampleRate
            )
            let base = i * 5
            eqCoeffsStaging[base]     = b0
            eqCoeffsStaging[base + 1] = b1
            eqCoeffsStaging[base + 2] = b2
            eqCoeffsStaging[base + 3] = a1
            eqCoeffsStaging[base + 4] = a2
        }
        eqVersion &+= 1
        eqActive = active
        os_unfair_lock_unlock(&paramLock)
    }

    /// Audio EQ Cookbook peaking EQ — Robert Bristow-Johnson
    private func computePeakingEQ(
        freq: Float, gainDB: Float, Q: Float, sampleRate: Float
    ) -> (Float, Float, Float, Float, Float) {
        if gainDB == 0 { return (1, 0, 0, 0, 0) }
        let A = powf(10, gainDB / 40.0)
        let w0 = 2.0 * Float.pi * freq / sampleRate
        let sinW0 = sinf(w0)
        let cosW0 = cosf(w0)
        let alpha = sinW0 / (2.0 * Q)

        let b0 =  1.0 + alpha * A
        let b1 = -2.0 * cosW0
        let b2 =  1.0 - alpha * A
        let a0 =  1.0 + alpha / A
        let a1 = -2.0 * cosW0
        let a2 =  1.0 - alpha / A

        let invA0 = 1.0 / a0
        return (b0 * invA0, b1 * invA0, b2 * invA0, a1 * invA0, a2 * invA0)
    }

    // Called from input callback to sync coefficients if version changed
    func syncEQCoefficients() {
        os_unfair_lock_lock(&paramLock)
        let version = eqVersion
        let active = eqActive
        if version != cachedEqVersion {
            memcpy(eqCoeffs, eqCoeffsStaging, AudioConfig.eqBandCount * 5 * MemoryLayout<Float>.stride)
            cachedEqVersion = version
        }
        cachedEqActive = active
        os_unfair_lock_unlock(&paramLock)
    }

    // MARK: - Parameter Access

    func setVolume(_ vol: Float) {
        os_unfair_lock_lock(&paramLock); _volume = vol; os_unfair_lock_unlock(&paramLock)
    }
    func setGain(_ gain: Float) {
        os_unfair_lock_lock(&paramLock); _gain = gain; os_unfair_lock_unlock(&paramLock)
    }
    func setMeteringEnabled(_ enabled: Bool) {
        os_unfair_lock_lock(&paramLock); _meteringEnabled = enabled; os_unfair_lock_unlock(&paramLock)
    }

    struct AudioParams {
        var gain: Float
        var volume: Float
        var meteringEnabled: Bool
    }

    func getParams() -> AudioParams {
        os_unfair_lock_lock(&paramLock)
        let p = AudioParams(gain: _gain, volume: _volume, meteringEnabled: _meteringEnabled)
        os_unfair_lock_unlock(&paramLock)
        return p
    }

    func getPeakLevel() -> Float {
        os_unfair_lock_lock(&paramLock); let p = _smoothedPeak; os_unfair_lock_unlock(&paramLock)
        return p
    }

    func updatePeak(rms: Float, gain: Float) {
        let rawLevel = min(rms * 4.0, 1.0)
        let level = min(rawLevel * gain, 1.0)
        os_unfair_lock_lock(&paramLock)
        let coeff: Float = level > _smoothedPeak ? 0.85 : 0.25
        _smoothedPeak += coeff * (level - _smoothedPeak)
        os_unfair_lock_unlock(&paramLock)
    }

    // MARK: - Stereo Ring Buffer (atomic L/R operations)

    func writeStereo(left: UnsafePointer<Float>, right: UnsafePointer<Float>, count: Int) {
        os_unfair_lock_lock(&ringLock)
        leftRing.write(left, count: count)
        rightRing.write(right, count: count)
        os_unfair_lock_unlock(&ringLock)
    }

    func readStereo(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, count: Int) -> Int {
        os_unfair_lock_lock(&ringLock)
        let avail = min(leftRing.available, rightRing.available)
        let toRead = min(count, avail)
        _ = leftRing.read(left, count: toRead)
        _ = rightRing.read(right, count: toRead)
        os_unfair_lock_unlock(&ringLock)
        if toRead < count {
            memset(left + toRead, 0, (count - toRead) * MemoryLayout<Float>.stride)
            memset(right + toRead, 0, (count - toRead) * MemoryLayout<Float>.stride)
        }
        return toRead
    }

    func ringFillLevel() -> Int {
        os_unfair_lock_lock(&ringLock)
        let fill = min(leftRing.available, rightRing.available)
        os_unfair_lock_unlock(&ringLock)
        return fill
    }

    func peekStereoRecent(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, count: Int) -> Int {
        os_unfair_lock_lock(&ringLock)
        let avail = min(leftRing.available, rightRing.available)
        let toPeek = min(count, avail)
        _ = leftRing.peekRecent(left, count: toPeek)
        _ = rightRing.peekRecent(right, count: toPeek)
        os_unfair_lock_unlock(&ringLock)
        if toPeek < count {
            memset(left + toPeek, 0, (count - toPeek) * MemoryLayout<Float>.stride)
            memset(right + toPeek, 0, (count - toPeek) * MemoryLayout<Float>.stride)
        }
        return toPeek
    }

    func reset() {
        os_unfair_lock_lock(&paramLock)
        _smoothedPeak = 0
        _volume = 0
        os_unfair_lock_unlock(&paramLock)

        os_unfair_lock_lock(&ringLock)
        leftRing.reset()
        rightRing.reset()
        os_unfair_lock_unlock(&ringLock)

        inputUnit = nil
        dcLeftPrevX = 0; dcLeftPrevY = 0
        dcRightPrevX = 0; dcRightPrevY = 0

        // Reset EQ filter state
        let stateCount = AudioConfig.eqBandCount * 2
        eqStateL.initialize(repeating: 0, count: stateCount)
        eqStateR.initialize(repeating: 0, count: stateCount)
    }
}

// MARK: - DSP Free Functions

/// Process a single biquad section (Transposed Direct Form II)
/// Coefficients at coeffs[0..4] = [b0, b1, b2, a1, a2]
/// State at state[0..1] = [z1, z2]
private func processBiquad(
    _ buffer: UnsafeMutablePointer<Float>,
    count: Int,
    coeffs: UnsafePointer<Float>,
    state: UnsafeMutablePointer<Float>
) {
    let b0 = coeffs[0], b1 = coeffs[1], b2 = coeffs[2]
    let a1 = coeffs[3], a2 = coeffs[4]
    var z1 = state[0], z2 = state[1]

    for i in 0..<count {
        let x = buffer[i]
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        buffer[i] = y
    }

    // Flush denormals to zero to prevent CPU spikes
    if z1.isSubnormal { z1 = 0 }
    if z2.isSubnormal { z2 = 0 }

    state[0] = z1
    state[1] = z2
}

/// Apply 10-band parametric EQ (cascade of biquad sections)
private func applyEQ(
    _ buffer: UnsafeMutablePointer<Float>,
    count: Int,
    coeffs: UnsafePointer<Float>,
    state: UnsafeMutablePointer<Float>
) {
    for band in 0..<AudioConfig.eqBandCount {
        processBiquad(buffer, count: count,
                     coeffs: coeffs + band * 5,
                     state: state + band * 2)
    }
}

/// Soft limiter: transparent below threshold, tanh compression above
/// Approaches but never reaches ±1.0
private func applySoftLimiter(_ buffer: UnsafeMutablePointer<Float>, count: Int) {
    // Fast path: skip if no samples exceed threshold
    var maxVal: Float = 0
    vDSP_maxmgv(buffer, 1, &maxVal, vDSP_Length(count))
    guard maxVal > AudioConfig.softLimitThreshold else { return }

    let threshold = AudioConfig.softLimitThreshold
    let headroom = 1.0 - threshold

    for i in 0..<count {
        let x = buffer[i]
        let absX = abs(x)
        if absX > threshold {
            let sign: Float = x >= 0 ? 1.0 : -1.0
            let excess = absX - threshold
            buffer[i] = sign * (threshold + headroom * tanhf(excess / headroom))
        }
    }
}

/// Catmull-Rom cubic resample srcCount samples → dstCount samples
/// Much higher quality than linear interpolation — preserves high-frequency detail
private func cubicResample(
    src: UnsafePointer<Float>, srcCount: Int,
    dst: UnsafeMutablePointer<Float>, dstCount: Int
) {
    if srcCount == dstCount {
        memcpy(dst, src, dstCount * MemoryLayout<Float>.stride)
        return
    }
    guard srcCount > 1, dstCount > 0 else {
        if dstCount > 0 { memset(dst, 0, dstCount * MemoryLayout<Float>.stride) }
        return
    }

    let ratio = Float(srcCount - 1) / Float(max(dstCount - 1, 1))
    for i in 0..<dstCount {
        let srcPos = Float(i) * ratio
        let idx = Int(srcPos)
        let frac = srcPos - Float(idx)

        // Catmull-Rom spline with clamped boundary indices
        let p0 = src[max(idx - 1, 0)]
        let p1 = src[min(idx, srcCount - 1)]
        let p2 = src[min(idx + 1, srcCount - 1)]
        let p3 = src[min(idx + 2, srcCount - 1)]

        let a = -0.5 * p0 + 1.5 * p1 - 1.5 * p2 + 0.5 * p3
        let b =       p0 - 2.5 * p1 + 2.0 * p2 - 0.5 * p3
        let c = -0.5 * p0            + 0.5 * p2
        let d =                  p1

        dst[i] = ((a * frac + b) * frac + c) * frac + d
    }
}

// MARK: - Input Render Callback

private func inputRenderCallback(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {

    let state = Unmanaged<SharedAudioState>.fromOpaque(inRefCon).takeUnretainedValue()
    guard let unit = state.inputUnit else { return noErr }

    let channelCount = state.channelCount
    let frameCount = Int(inNumberFrames)
    let byteSize = inNumberFrames * UInt32(MemoryLayout<Float>.stride)
    let leftBuf = state.workLeft
    let rightBuf = state.workRight

    // Render from hardware
    if channelCount >= 2 {
        var stereoABL: (AudioBufferList, AudioBuffer) = (
            AudioBufferList(
                mNumberBuffers: 2,
                mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: byteSize,
                                      mData: UnsafeMutableRawPointer(leftBuf))
            ),
            AudioBuffer(mNumberChannels: 1, mDataByteSize: byteSize,
                        mData: UnsafeMutableRawPointer(rightBuf))
        )
        var renderStatus: OSStatus = noErr
        withUnsafeMutablePointer(to: &stereoABL) { ptr in
            let ablPtr = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: AudioBufferList.self)
            renderStatus = AudioUnitRender(unit, ioActionFlags, inTimeStamp, 1, inNumberFrames, ablPtr)
        }
        guard renderStatus == noErr else { return renderStatus }
    } else {
        var bufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: byteSize,
                                  mData: UnsafeMutableRawPointer(leftBuf))
        )
        let status = AudioUnitRender(unit, ioActionFlags, inTimeStamp, 1, inNumberFrames, &bufferList)
        guard status == noErr else { return status }
        memcpy(rightBuf, leftBuf, frameCount * MemoryLayout<Float>.stride)
    }

    // Batch-read parameters (single lock acquisition)
    let params = state.getParams()

    // Sync EQ state to check if DSP is needed
    state.syncEQCoefficients()
    let eqActive = state.cachedEqActive
    let gainActive = params.gain != 1.0

    // Clean passthrough when no processing is engaged (Audacity-style transparent wire).
    // DC filter + limiter only run when EQ is active, since EQ boosts can cause DC
    // offset and clipping. Without EQ, the signal passes through bit-perfect.
    if eqActive {
        // DC offset removal — first-order high-pass (~20 Hz)
        // Only needed when EQ is active (boosted bands can amplify DC from preamp)
        let R = state.dcFilterR
        var lpx = state.dcLeftPrevX, lpy = state.dcLeftPrevY
        var rpx = state.dcRightPrevX, rpy = state.dcRightPrevY

        for i in 0..<frameCount {
            let lx = leftBuf[i]; lpy = lx - lpx + R * lpy; lpx = lx; leftBuf[i] = lpy
            let rx = rightBuf[i]; rpy = rx - rpx + R * rpy; rpx = rx; rightBuf[i] = rpy
        }
        state.dcLeftPrevX = lpx; state.dcLeftPrevY = lpy
        state.dcRightPrevX = rpx; state.dcRightPrevY = rpy
    }

    // Apply gain
    if gainActive {
        var g = params.gain
        vDSP_vsmul(leftBuf, 1, &g, leftBuf, 1, vDSP_Length(frameCount))
        vDSP_vsmul(rightBuf, 1, &g, rightBuf, 1, vDSP_Length(frameCount))
    }

    // Apply 10-band parametric EQ
    if eqActive {
        applyEQ(leftBuf, count: frameCount, coeffs: state.eqCoeffs, state: state.eqStateL)
        applyEQ(rightBuf, count: frameCount, coeffs: state.eqCoeffs, state: state.eqStateR)

        // Soft limiter — only needed when EQ is active (boosts can clip)
        applySoftLimiter(leftBuf, count: frameCount)
        applySoftLimiter(rightBuf, count: frameCount)
    }

    // Metering — average RMS of both channels
    if params.meteringEnabled {
        var leftRms: Float = 0, rightRms: Float = 0
        vDSP_rmsqv(leftBuf, 1, &leftRms, vDSP_Length(frameCount))
        vDSP_rmsqv(rightBuf, 1, &rightRms, vDSP_Length(frameCount))
        state.updatePeak(rms: (leftRms + rightRms) * 0.5, gain: params.gain)
    }

    // Write to ring buffers (atomic stereo write)
    state.writeStereo(left: leftBuf, right: rightBuf, count: frameCount)

    // Broadcast to stream clients
    if let serverPtr = state.streamServerPtr {
        let server = Unmanaged<AudioStreamServer>.fromOpaque(serverPtr).takeUnretainedValue()
        let interleavedBuf = state.workInterleaved
        for i in 0..<frameCount {
            interleavedBuf[i * 2] = leftBuf[i]
            interleavedBuf[i * 2 + 1] = rightBuf[i]
        }
        server.broadcast(interleavedBuf, frameCount: frameCount)
    }

    return noErr
}

// MARK: - Output Render Callback

private func outputRenderCallback(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {

    let state = Unmanaged<SharedAudioState>.fromOpaque(inRefCon).takeUnretainedValue()
    guard let bufferListPtr = ioData else { return noErr }

    let frameCount = Int(inNumberFrames)
    let bufferList = UnsafeMutableAudioBufferListPointer(bufferListPtr)

    guard bufferList.count >= 1,
          let ch0 = bufferList[0].mData?.assumingMemoryBound(to: Float.self) else {
        return noErr
    }

    let volume = state.getParams().volume

    // Drift compensation: only needed when input/output are on different devices
    // (different clock domains). Same-device shares one clock — no drift possible.
    var framesToRead = frameCount
    if !state.sameDevice {
        let fill = state.ringFillLevel()
        if fill > AudioConfig.driftTarget + AudioConfig.driftThreshold {
            framesToRead = frameCount + 1
        } else if fill > 0, fill < AudioConfig.driftTarget - AudioConfig.driftThreshold {
            framesToRead = max(frameCount - 1, 1)
        }
    }

    let tempL = state.workOutL
    let tempR = state.workOutR

    if bufferList.count >= 2, let ch1 = bufferList[1].mData?.assumingMemoryBound(to: Float.self) {
        // Stereo output
        let read = state.readStereo(left: tempL, right: tempR, count: framesToRead)

        if read == frameCount {
            memcpy(ch0, tempL, frameCount * MemoryLayout<Float>.stride)
            memcpy(ch1, tempR, frameCount * MemoryLayout<Float>.stride)
        } else if read > 0 {
            cubicResample(src: tempL, srcCount: read, dst: ch0, dstCount: frameCount)
            cubicResample(src: tempR, srcCount: read, dst: ch1, dstCount: frameCount)
        } else {
            memset(ch0, 0, frameCount * MemoryLayout<Float>.stride)
            memset(ch1, 0, frameCount * MemoryLayout<Float>.stride)
        }

        if volume != 1.0 {
            var vol = volume
            vDSP_vsmul(ch0, 1, &vol, ch0, 1, vDSP_Length(frameCount))
            vDSP_vsmul(ch1, 1, &vol, ch1, 1, vDSP_Length(frameCount))
        }
    } else {
        // Mono output — read stereo and sum
        let read = state.readStereo(left: tempL, right: tempR, count: framesToRead)

        if read > 0 {
            vDSP_vadd(tempL, 1, tempR, 1, tempL, 1, vDSP_Length(read))
            var half: Float = 0.5
            vDSP_vsmul(tempL, 1, &half, tempL, 1, vDSP_Length(read))

            if read == frameCount {
                memcpy(ch0, tempL, frameCount * MemoryLayout<Float>.stride)
            } else {
                cubicResample(src: tempL, srcCount: read, dst: ch0, dstCount: frameCount)
            }
        } else {
            memset(ch0, 0, frameCount * MemoryLayout<Float>.stride)
        }

        if volume != 1.0 {
            var vol = volume
            vDSP_vsmul(ch0, 1, &vol, ch0, 1, vDSP_Length(frameCount))
        }
    }

    // Silence extra channels
    for i in 2..<bufferList.count {
        if let chData = bufferList[i].mData {
            memset(chData, 0, Int(bufferList[i].mDataByteSize))
        }
    }

    return noErr
}
