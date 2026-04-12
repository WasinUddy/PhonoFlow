//
//  AudioRecorder.swift
//  PhonoFlow
//
//  Records interleaved stereo 32-bit float PCM to WAV files.
//  Non-blocking: audio thread copies data, dispatch queue writes to disk.
//

import Foundation

class AudioRecorder {
    private var fileHandle: FileHandle?
    private var filePath: URL?
    private var totalFramesWritten: UInt32 = 0
    private var sampleRate: Double = 44100
    private let channels: UInt16 = 2
    private let bitsPerSample: UInt16 = 32

    private let queue = DispatchQueue(label: "PhonoFlow.recorder", qos: .userInitiated)
    private(set) var isRecording = false

    /// Start recording to a new WAV file.
    func start(sampleRate: Double) throws -> URL {
        let filename = recordingFilename()
        let dir = recordingDirectory()

        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(filename)

        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: url.path) else {
            throw RecorderError.cannotCreateFile
        }

        self.sampleRate = sampleRate
        self.fileHandle = handle
        self.filePath = url
        self.totalFramesWritten = 0

        // Write placeholder WAV header (will be finalized on stop)
        let header = buildWAVHeader(dataSize: 0)
        handle.write(header)

        isRecording = true
        return url
    }

    /// Write interleaved stereo samples from the audio thread. Non-blocking.
    func write(_ samples: UnsafePointer<Float>, frameCount: Int) {
        guard isRecording else { return }

        let byteCount = frameCount * Int(channels) * MemoryLayout<Float>.size
        let data = Data(bytes: samples, count: byteCount)

        queue.async { [weak self] in
            self?.fileHandle?.write(data)
        }

        totalFramesWritten += UInt32(frameCount)
    }

    /// Stop recording and finalize the WAV header.
    func stop() -> URL? {
        guard isRecording else { return nil }
        isRecording = false

        let url = filePath

        queue.async { [weak self] in
            self?.finalizeWAV()
            self?.fileHandle?.closeFile()
            self?.fileHandle = nil
        }

        return url
    }

    /// Duration of current recording in seconds.
    var durationSeconds: Double {
        guard sampleRate > 0 else { return 0 }
        return Double(totalFramesWritten) / sampleRate
    }

    // MARK: - WAV Format

    private func buildWAVHeader(dataSize: UInt32) -> Data {
        var header = Data(capacity: 44)

        let blockAlign = channels * (bitsPerSample / 8)
        let byteRate = UInt32(sampleRate) * UInt32(blockAlign)

        // RIFF chunk
        header.append(contentsOf: "RIFF".utf8)
        header.appendLE32(dataSize + 36)          // File size - 8
        header.append(contentsOf: "WAVE".utf8)

        // fmt sub-chunk
        header.append(contentsOf: "fmt ".utf8)
        header.appendLE32(16)                      // Sub-chunk size
        header.appendLE16(3)                       // Audio format: IEEE float
        header.appendLE16(channels)
        header.appendLE32(UInt32(sampleRate))
        header.appendLE32(byteRate)
        header.appendLE16(blockAlign)
        header.appendLE16(bitsPerSample)

        // data sub-chunk
        header.append(contentsOf: "data".utf8)
        header.appendLE32(dataSize)

        return header
    }

    private func finalizeWAV() {
        guard let handle = fileHandle else { return }

        let dataSize = totalFramesWritten * UInt32(channels) * UInt32(bitsPerSample / 8)
        let header = buildWAVHeader(dataSize: dataSize)

        handle.seek(toFileOffset: 0)
        handle.write(header)
    }

    // MARK: - File Naming

    private func recordingFilename() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return "PhonoFlow_\(formatter.string(from: Date())).wav"
    }

    private func recordingDirectory() -> URL {
        let musicDir = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return musicDir.appendingPathComponent("PhonoFlow Recordings")
    }

    // MARK: - Errors

    enum RecorderError: Error, LocalizedError {
        case cannotCreateFile

        var errorDescription: String? {
            switch self {
            case .cannotCreateFile: return "Could not create recording file."
            }
        }
    }
}

// MARK: - Data Helpers

private extension Data {
    mutating func appendLE16(_ value: UInt16) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }
    mutating func appendLE32(_ value: UInt32) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }
}
