//
//  AudioMonitor.swift
//  PhonoFlow
//
//  Stereo audio monitoring with DC offset removal and clip protection
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

    private let sharedState = SharedAudioState()
    private let streamServer = AudioStreamServer()
    private var captureSampleRate: Double = 44100

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

        sharedState.setGain(gain)
        sharedState.setVolume(isPassthroughEnabled ? gain : 0)
        sharedState.setMeteringEnabled(isMeteringEnabled)

        AudioOutputUnitStart(inputUnit!)
        if isPassthroughEnabled {
            AudioOutputUnitStart(outputUnit!)
        }

        isMonitoring = true

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

        optimizeDeviceBufferSize(deviceID)

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

        optimizeDeviceBufferSize(deviceID)

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

    private func optimizeDeviceBufferSize(_ deviceID: AudioDeviceID) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var currentSize: UInt32 = 0
        var propSize = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &propSize, &currentSize) == noErr else { return }

        if currentSize > 512 {
            var newSize: UInt32 = 512
            AudioObjectSetPropertyData(deviceID, &address, 0, nil,
                                      UInt32(MemoryLayout<UInt32>.size), &newSize)
        }
    }

    // MARK: - UI Updates

    private var uiUpdateTimer: Timer?

    func startUIUpdateTimer() {
        uiUpdateTimer = Timer.scheduledTimer(withTimeInterval: 1.0/20.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.peakLevel = self.sharedState.getPeakLevel()
        }
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
    var streamServerPtr: UnsafeMutableRawPointer?
    var inputUnit: AudioUnit?
    var channelCount: Int = 2

    // Stereo ring buffers (one per channel)
    private var leftRingBuffer = RingBuffer(capacity: 16384)
    private var rightRingBuffer = RingBuffer(capacity: 16384)

    // Pre-allocated work buffers for input callback (stable pointers, no ARC in RT thread)
    private static let bufferCapacity = 4096
    private let workLeft: UnsafeMutablePointer<Float>
    private let workRight: UnsafeMutablePointer<Float>
    private let workInterleaved: UnsafeMutablePointer<Float>
    // Separate buffer for output callback to avoid concurrent access
    private let workOutput: UnsafeMutablePointer<Float>

    // DC offset filter state (only touched by input callback thread)
    var dcLeftPrevX: Float = 0
    var dcLeftPrevY: Float = 0
    var dcRightPrevX: Float = 0
    var dcRightPrevY: Float = 0
    var dcFilterR: Float = 0.9972

    init() {
        let cap = SharedAudioState.bufferCapacity
        workLeft = .allocate(capacity: cap)
        workLeft.initialize(repeating: 0, count: cap)
        workRight = .allocate(capacity: cap)
        workRight.initialize(repeating: 0, count: cap)
        workInterleaved = .allocate(capacity: cap * 2)
        workInterleaved.initialize(repeating: 0, count: cap * 2)
        workOutput = .allocate(capacity: cap)
        workOutput.initialize(repeating: 0, count: cap)
    }

    deinit {
        workLeft.deallocate()
        workRight.deallocate()
        workInterleaved.deallocate()
        workOutput.deallocate()
    }

    func updateDCFilterCoefficient(sampleRate: Float) {
        dcFilterR = expf(-2.0 * Float.pi * 20.0 / sampleRate)
    }

    func reset() {
        os_unfair_lock_lock(&lock)
        _smoothedPeak = 0
        _volume = 0
        inputUnit = nil
        leftRingBuffer.reset()
        rightRingBuffer.reset()
        os_unfair_lock_unlock(&lock)
        dcLeftPrevX = 0
        dcLeftPrevY = 0
        dcRightPrevX = 0
        dcRightPrevY = 0
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

    func updatePeak(rms: Float, gain: Float) {
        let rawLevel = min(rms * 4.0, 1.0)
        let level = min(rawLevel * gain, 1.0)

        os_unfair_lock_lock(&lock)
        let coeff: Float = level > _smoothedPeak ? 0.85 : 0.25
        _smoothedPeak += coeff * (level - _smoothedPeak)
        os_unfair_lock_unlock(&lock)
    }

    func writeStereo(left: UnsafePointer<Float>, right: UnsafePointer<Float>, count: Int) {
        leftRingBuffer.write(left, count: count)
        rightRingBuffer.write(right, count: count)
    }

    func readStereo(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, count: Int) -> Int {
        let l = leftRingBuffer.read(left, count: count)
        let r = rightRingBuffer.read(right, count: count)
        return min(l, r)
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

    func getInputWorkBuffers() -> (left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, interleaved: UnsafeMutablePointer<Float>) {
        return (workLeft, workRight, workInterleaved)
    }

    func getOutputWorkBuffer() -> UnsafeMutablePointer<Float> {
        return workOutput
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
    private let buffer: UnsafeMutablePointer<Float>
    private var writePos = 0
    private var readPos = 0
    private var availableFrames = 0
    private let capacity: Int
    private var lock = os_unfair_lock()

    init(capacity: Int) {
        self.capacity = capacity
        buffer = .allocate(capacity: capacity)
        buffer.initialize(repeating: 0, count: capacity)
    }

    deinit {
        buffer.deallocate()
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

        let firstChunk = min(toWrite, capacity - writePos)
        memcpy(buffer + writePos, data, firstChunk * MemoryLayout<Float>.stride)
        if firstChunk < toWrite {
            memcpy(buffer, data + firstChunk, (toWrite - firstChunk) * MemoryLayout<Float>.stride)
        }

        writePos = (writePos + toWrite) % capacity
        availableFrames += toWrite
        os_unfair_lock_unlock(&lock)
    }

    func read(_ data: UnsafeMutablePointer<Float>, count: Int) -> Int {
        os_unfair_lock_lock(&lock)
        let toRead = min(count, availableFrames)

        let firstChunk = min(toRead, capacity - readPos)
        memcpy(data, buffer + readPos, firstChunk * MemoryLayout<Float>.stride)
        if firstChunk < toRead {
            memcpy(data + firstChunk, buffer, (toRead - firstChunk) * MemoryLayout<Float>.stride)
        }

        readPos = (readPos + toRead) % capacity
        availableFrames -= toRead
        os_unfair_lock_unlock(&lock)

        if toRead < count {
            memset(data + toRead, 0, (count - toRead) * MemoryLayout<Float>.stride)
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
    let byteSize = inNumberFrames * UInt32(MemoryLayout<Float>.stride)

    let (leftBuf, rightBuf, interleavedBuf) = state.getInputWorkBuffers()

    // Render audio — preserve stereo when available
    if channelCount >= 2 {
        var stereoABL: (AudioBufferList, AudioBuffer) = (
            AudioBufferList(
                mNumberBuffers: 2,
                mBuffers: AudioBuffer(
                    mNumberChannels: 1,
                    mDataByteSize: byteSize,
                    mData: UnsafeMutableRawPointer(leftBuf)
                )
            ),
            AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: byteSize,
                mData: UnsafeMutableRawPointer(rightBuf)
            )
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
            mBuffers: AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: byteSize,
                mData: UnsafeMutableRawPointer(leftBuf)
            )
        )
        let status = AudioUnitRender(unit, ioActionFlags, inTimeStamp, 1, inNumberFrames, &bufferList)
        guard status == noErr else { return status }
        memcpy(rightBuf, leftBuf, frameCount * MemoryLayout<Float>.stride)
    }

    // DC offset removal — one-pole high-pass (~20 Hz cutoff) removes turntable rumble
    // and DC bias without affecting audible content
    let R = state.dcFilterR
    var lpx = state.dcLeftPrevX, lpy = state.dcLeftPrevY
    var rpx = state.dcRightPrevX, rpy = state.dcRightPrevY

    for i in 0..<frameCount {
        let lx = leftBuf[i]
        lpy = lx - lpx + R * lpy
        lpx = lx
        leftBuf[i] = lpy

        let rx = rightBuf[i]
        rpy = rx - rpx + R * rpy
        rpx = rx
        rightBuf[i] = rpy
    }

    state.dcLeftPrevX = lpx; state.dcLeftPrevY = lpy
    state.dcRightPrevX = rpx; state.dcRightPrevY = rpy

    // Metering — average RMS of both channels for a single meter reading
    let currentGain = state.getGain()
    if state.isMeteringEnabled() {
        var leftRms: Float = 0, rightRms: Float = 0
        vDSP_rmsqv(leftBuf, 1, &leftRms, vDSP_Length(frameCount))
        vDSP_rmsqv(rightBuf, 1, &rightRms, vDSP_Length(frameCount))
        state.updatePeak(rms: (leftRms + rightRms) * 0.5, gain: currentGain)
    }

    // Apply gain to both channels
    if currentGain != 1.0 {
        var g = currentGain
        vDSP_vsmul(leftBuf, 1, &g, leftBuf, 1, vDSP_Length(frameCount))
        vDSP_vsmul(rightBuf, 1, &g, rightBuf, 1, vDSP_Length(frameCount))
    }

    // Apply equalizer to both stereo channels
    state.applyEqualizer(leftBuf, count: frameCount)
    state.applyEqualizer(rightBuf, count: frameCount)

    // Hard clip at ±1.0 as a safety net against digital overs
    var lo: Float = -1.0, hi: Float = 1.0
    vDSP_vclip(leftBuf, 1, &lo, &hi, leftBuf, 1, vDSP_Length(frameCount))
    vDSP_vclip(rightBuf, 1, &lo, &hi, rightBuf, 1, vDSP_Length(frameCount))

    // Write stereo to ring buffers for passthrough
    state.writeStereo(left: leftBuf, right: rightBuf, count: frameCount)

    // Broadcast interleaved stereo to stream clients
    if let serverPtr = state.streamServerPtr {
        let server = Unmanaged<AudioStreamServer>.fromOpaque(serverPtr).takeUnretainedValue()
        for i in 0..<frameCount {
            interleavedBuf[i * 2] = leftBuf[i]
            interleavedBuf[i * 2 + 1] = rightBuf[i]
        }
        server.broadcast(interleavedBuf, frameCount: frameCount)
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

    guard bufferList.count >= 1,
          let ch0 = bufferList[0].mData?.assumingMemoryBound(to: Float.self) else {
        return noErr
    }

    let volume = state.getVolume()

    if bufferList.count >= 2, let ch1 = bufferList[1].mData?.assumingMemoryBound(to: Float.self) {
        // Stereo output — read L/R directly into output buffers
        _ = state.readStereo(left: ch0, right: ch1, count: frameCount)

        if volume != 1.0 {
            var vol = volume
            vDSP_vsmul(ch0, 1, &vol, ch0, 1, vDSP_Length(frameCount))
            vDSP_vsmul(ch1, 1, &vol, ch1, 1, vDSP_Length(frameCount))
        }
    } else {
        // Mono output — read stereo and sum to mono
        let tempRight = state.getOutputWorkBuffer()
        _ = state.readStereo(left: ch0, right: tempRight, count: frameCount)
        vDSP_vadd(ch0, 1, tempRight, 1, ch0, 1, vDSP_Length(frameCount))
        var half: Float = 0.5
        vDSP_vsmul(ch0, 1, &half, ch0, 1, vDSP_Length(frameCount))

        if volume != 1.0 {
            var vol = volume
            vDSP_vsmul(ch0, 1, &vol, ch0, 1, vDSP_Length(frameCount))
        }
    }

    // Silence any extra channels beyond stereo
    for i in 2..<bufferList.count {
        if let chData = bufferList[i].mData {
            memset(chData, 0, Int(bufferList[i].mDataByteSize))
        }
    }

    return noErr
}
