//
//  AudioMonitor.swift
//  PhonoFlow
//
//  Rewritten with Core Audio for maximum stability and real-time performance
//

import Accelerate
import AudioToolbox
import CoreAudio
import Foundation
import os.lock

@Observable
class AudioMonitor {
    var peakLevel: Float = 0
    var gain: Float = 1.0
    var isMonitoring = false
    var isPassthroughEnabled = false
    var isStreamingEnabled = false
    var streamURL: String = ""
    
    // 10-band Equalizer parameters
    @MainActor var eqBands: [Float] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0] {
        didSet { 
            sharedState.setEqualizerBands(eqBands)
        }
    }

    private var inputUnit: AudioUnit?
    private var outputUnit: AudioUnit?
    private var inputDeviceID: AudioDeviceID = 0
    private var outputDeviceID: AudioDeviceID = 0

    // Atomic state shared between real-time thread and main thread
    private let sharedState = SharedAudioState()
    private let streamServer = AudioStreamServer()
    private var captureSampleRate: Double = 44100
    private var audioFormat = AudioStreamBasicDescription()

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

        // Initialize gain in shared state
        sharedState.setGain(gain)
        sharedState.setVolume(isPassthroughEnabled ? gain : 0)
        sharedState.setMeteringEnabled(isMeteringEnabled)

        // Start the audio units
        AudioOutputUnitStart(inputUnit!)
        if isPassthroughEnabled {
            AudioOutputUnitStart(outputUnit!)
        }

        isMonitoring = true

        // Start periodic UI updates only if metering is enabled
        if isMeteringEnabled {
            startUIUpdateTimer()
        }
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

        // Recreate output unit with new device
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
        sharedState.setGain(gain)  // Update gain for metering
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

        // Enable input, disable output
        var enableIO: UInt32 = 1
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO,
                           kAudioUnitScope_Input, 1, &enableIO, UInt32(MemoryLayout<UInt32>.size))
        enableIO = 0
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO,
                           kAudioUnitScope_Output, 0, &enableIO, UInt32(MemoryLayout<UInt32>.size))

        // Set device
        var deviceIDVar = deviceID
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                           kAudioUnitScope_Global, 0, &deviceIDVar, UInt32(MemoryLayout<AudioDeviceID>.size))

        // Get input format
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat,
                           kAudioUnitScope_Input, 1, &asbd, &size)

        // Store sample rate and channel count
        captureSampleRate = asbd.mSampleRate
        let channelCount = asbd.mChannelsPerFrame

        // Set format to Float32 (keep original channel count)
        asbd.mFormatID = kAudioFormatLinearPCM
        asbd.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved
        asbd.mBitsPerChannel = 32
        asbd.mBytesPerFrame = 4
        asbd.mBytesPerPacket = 4
        asbd.mFramesPerPacket = 1
        asbd.mChannelsPerFrame = channelCount

        AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat,
                           kAudioUnitScope_Output, 1, &asbd, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))

        // Store channel count for callback
        sharedState.channelCount = Int(channelCount)

        // Store format for callback
        audioFormat = asbd

        // Set render callback
        let state = Unmanaged.passUnretained(sharedState).toOpaque()
        let server = Unmanaged.passUnretained(streamServer).toOpaque()

        var callbackStruct = AURenderCallbackStruct(
            inputProc: inputRenderCallback,
            inputProcRefCon: UnsafeMutableRawPointer(mutating: state)
        )
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback,
                           kAudioUnitScope_Global, 0, &callbackStruct, UInt32(MemoryLayout<AURenderCallbackStruct>.size))

        // Store pointers for callback
        sharedState.streamServerPtr = server
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

        // Set device
        var deviceIDVar = deviceID
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                           kAudioUnitScope_Global, 0, &deviceIDVar, UInt32(MemoryLayout<AudioDeviceID>.size))

        // Get device format
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat,
                           kAudioUnitScope_Input, 0, &asbd, &size)

        // Set format to match input (preserve channel count)
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

        // Set render callback to feed from input
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

    // MARK: - UI Updates

    private var uiUpdateTimer: Timer?

    func startUIUpdateTimer() {
        // Reduce from 30Hz to 20Hz to save CPU
        uiUpdateTimer = Timer.scheduledTimer(withTimeInterval: 1.0/20.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.peakLevel = self.sharedState.getPeakLevel()
        }
        // Add to common run loop mode so it continues firing during UI tracking (slider dragging)
        if let timer = uiUpdateTimer {
            RunLoop.current.add(timer, forMode: .common)
        }
    }

    private func stopUIUpdateTimer() {
        uiUpdateTimer?.invalidate()
        uiUpdateTimer = nil
    }
}

// MARK: - Shared State (Thread-Safe)

private class SharedAudioState {
    private var lock = os_unfair_lock()
    private var _smoothedPeak: Float = 0
    private var _volume: Float = 0
    private var _gain: Float = 1.0
    private var _meteringEnabled: Bool = false
    private var _eqBands: [Float] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
    private var bufferCounter = 0
    var streamServerPtr: UnsafeMutableRawPointer?
    var inputUnit: AudioUnit?
    var channelCount: Int = 2

    // Ring buffer for passthrough
    private var ringBuffer = RingBuffer(capacity: 8192)

    // Pre-allocated working buffers to avoid allocations in audio callback
    private var workBuffer1 = [Float](repeating: 0, count: 4096)
    private var workBuffer2 = [Float](repeating: 0, count: 4096)

    func reset() {
        os_unfair_lock_lock(&lock)
        _smoothedPeak = 0
        _volume = 0
        bufferCounter = 0
        inputUnit = nil
        ringBuffer.reset()
        os_unfair_lock_unlock(&lock)
    }

    func setVolume(_ vol: Float) {
        os_unfair_lock_lock(&lock)
        _volume = vol
        os_unfair_lock_unlock(&lock)
    }

    func setGain(_ gain: Float) {
        os_unfair_lock_lock(&lock)
        _gain = gain
        os_unfair_lock_unlock(&lock)
    }

    func setMeteringEnabled(_ enabled: Bool) {
        os_unfair_lock_lock(&lock)
        _meteringEnabled = enabled
        os_unfair_lock_unlock(&lock)
    }

    func isMeteringEnabled() -> Bool {
        os_unfair_lock_lock(&lock)
        let enabled = _meteringEnabled
        os_unfair_lock_unlock(&lock)
        return enabled
    }

    func setEqualizerBands(_ bands: [Float]) {
        os_unfair_lock_lock(&lock)
        _eqBands = bands
        os_unfair_lock_unlock(&lock)
    }

    func getEqualizerBands() -> [Float] {
        os_unfair_lock_lock(&lock)
        let bands = _eqBands
        os_unfair_lock_unlock(&lock)
        return bands
    }

    func getPeakLevel() -> Float {
        os_unfair_lock_lock(&lock)
        let peak = _smoothedPeak
        os_unfair_lock_unlock(&lock)
        return peak
    }

    // Called from real-time thread - MUST be lock-free where possible
    func updatePeak(rms: Float, gain: Float) {
        let rawLevel = min(rms * 4.0, 1.0)
        let level = min(rawLevel * gain, 1.0)

        os_unfair_lock_lock(&lock)
        let coeff: Float = level > _smoothedPeak ? 0.85 : 0.25
        _smoothedPeak += coeff * (level - _smoothedPeak)
        os_unfair_lock_unlock(&lock)
    }

    func writeAudio(_ buffer: UnsafePointer<Float>, count: Int) {
        ringBuffer.write(buffer, count: count)
    }

    func readAudio(_ buffer: UnsafeMutablePointer<Float>, count: Int) -> Int {
        return ringBuffer.read(buffer, count: count)
    }

    func getVolume() -> Float {
        os_unfair_lock_lock(&lock)
        let vol = _volume
        os_unfair_lock_unlock(&lock)
        return vol
    }

    func getGain() -> Float {
        os_unfair_lock_lock(&lock)
        let g = _gain
        os_unfair_lock_unlock(&lock)
        return g
    }

    func getWorkBuffers() -> (UnsafeMutablePointer<Float>, UnsafeMutablePointer<Float>) {
        return (workBuffer1.withUnsafeMutableBufferPointer { $0.baseAddress! },
                workBuffer2.withUnsafeMutableBufferPointer { $0.baseAddress! })
    }

    func applyEqualizer(_ buffer: UnsafeMutablePointer<Float>, count: Int) {
        let bands = getEqualizerBands()

        // If all EQ values are at 0, skip processing
        if bands.allSatisfy({ $0 == 0 }) {
            return
        }

        // Convert dB to linear gain and calculate average
        var totalGain: Float = 0
        for bandLevel in bands {
            let gain = pow(10.0, (bandLevel / 20.0))
            totalGain += gain
        }
        
        let avgGain = totalGain / Float(bands.count)
        var gain = Float(avgGain)

        // Apply the gain adjustment to the buffer
        vDSP_vsmul(buffer, 1, &gain, buffer, 1, vDSP_Length(count))
    }
}

// MARK: - Ring Buffer

private class RingBuffer {
    private var buffer: [Float]
    private var writePos = 0
    private var readPos = 0
    private var availableFrames = 0
    private let capacity: Int
    private var lock = os_unfair_lock()

    init(capacity: Int) {
        self.capacity = capacity
        self.buffer = [Float](repeating: 0, count: capacity)
    }

    func reset() {
        os_unfair_lock_lock(&lock)
        writePos = 0
        readPos = 0
        availableFrames = 0
        os_unfair_lock_unlock(&lock)
    }

    func write(_ data: UnsafePointer<Float>, count: Int) {
        os_unfair_lock_lock(&lock)
        let toWrite = min(count, capacity - availableFrames)

        for i in 0..<toWrite {
            buffer[writePos] = data[i]
            writePos = (writePos + 1) % capacity
        }

        availableFrames = min(availableFrames + toWrite, capacity)
        os_unfair_lock_unlock(&lock)
    }

    func read(_ data: UnsafeMutablePointer<Float>, count: Int) -> Int {
        os_unfair_lock_lock(&lock)
        let toRead = min(count, availableFrames)

        for i in 0..<toRead {
            data[i] = buffer[readPos]
            readPos = (readPos + 1) % capacity
        }

        availableFrames -= toRead
        os_unfair_lock_unlock(&lock)

        // Fill remainder with silence
        if toRead < count {
            memset(data + toRead, 0, (count - toRead) * MemoryLayout<Float>.size)
        }

        return toRead
    }
}

// MARK: - Audio Callbacks

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
    let byteSize = inNumberFrames * UInt32(MemoryLayout<Float>.size)

    // Use pre-allocated work buffers (no allocations!)
    let (monoBuffer, gainedBuffer) = state.getWorkBuffers()

    if channelCount == 2 {
        // AudioBufferList only has inline storage for 1 AudioBuffer.
        // Use a tuple to get contiguous stack memory for the second buffer,
        // avoiding heap allocation in this real-time callback.
        var stereoABL: (AudioBufferList, AudioBuffer) = (
            AudioBufferList(
                mNumberBuffers: 2,
                mBuffers: AudioBuffer(
                    mNumberChannels: 1,
                    mDataByteSize: byteSize,
                    mData: UnsafeMutableRawPointer(monoBuffer)
                )
            ),
            AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: byteSize,
                mData: UnsafeMutableRawPointer(gainedBuffer)
            )
        )
        withUnsafeMutablePointer(to: &stereoABL) { ptr in
            let ablPtr = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: AudioBufferList.self)
            let status = AudioUnitRender(unit, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, ablPtr)
            guard status == noErr else { return }

            vDSP_vadd(monoBuffer, 1, gainedBuffer, 1, monoBuffer, 1, vDSP_Length(frameCount))
            var divisor: Float = 2.0
            vDSP_vsdiv(monoBuffer, 1, &divisor, monoBuffer, 1, vDSP_Length(frameCount))
        }
    } else {
        var bufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: byteSize,
                mData: UnsafeMutableRawPointer(monoBuffer)
            )
        )
        AudioUnitRender(unit, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, &bufferList)
    }

    // Get current gain for processing
    let currentGain = state.getGain()

    // Only calculate RMS and update meter if metering is enabled
    if state.isMeteringEnabled() {
        var rms: Float = 0
        vDSP_rmsqv(monoBuffer, 1, &rms, vDSP_Length(frameCount))
        state.updatePeak(rms: rms, gain: currentGain)
    }

    // Apply gain for passthrough and streaming (reuse gainedBuffer)
    if currentGain != 1.0 {
        var gain = currentGain
        vDSP_vsmul(monoBuffer, 1, &gain, gainedBuffer, 1, vDSP_Length(frameCount))
    } else {
        // Just copy if gain is 1.0
        memcpy(gainedBuffer, monoBuffer, frameCount * MemoryLayout<Float>.size)
    }

    // Apply equalizer
    state.applyEqualizer(gainedBuffer, count: frameCount)

    // Write to ring buffer for passthrough (with gain applied)
    state.writeAudio(gainedBuffer, count: frameCount)

    // Send to stream server if streaming (with gain applied)
    if let serverPtr = state.streamServerPtr {
        let server = Unmanaged<AudioStreamServer>.fromOpaque(serverPtr).takeUnretainedValue()
        server.broadcast(gainedBuffer, count: frameCount)
    }

    return noErr
}

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

    // Use pre-allocated work buffer (no allocations!)
    let (monoBuffer, _) = state.getWorkBuffers()

    // Read mono audio from ring buffer
    _ = state.readAudio(monoBuffer, count: frameCount)

    // Apply volume/gain
    let volume = state.getVolume()
    if volume != 1.0 {
        var vol = volume
        vDSP_vsmul(monoBuffer, 1, &vol, monoBuffer, 1, vDSP_Length(frameCount))
    }

    // Copy mono to all output channels
    for i in 0..<bufferList.count {
        guard let channelData = bufferList[i].mData?.assumingMemoryBound(to: Float.self) else { continue }
        channelData.update(from: monoBuffer, count: frameCount)
    }

    return noErr
}
