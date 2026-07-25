import Foundation
import Testing

@testable import PhonoFlowCore

@Suite("WAV helpers")
struct WAVTests {
    @Test("PCM16 header contains canonical RIFF fields")
    func pcmHeader() throws {
        let format = try WAVFormat(
            sampleRate: 48_000,
            channelCount: 2,
            encoding: .pcmInt16
        )
        let header = try WAVHeader.make(format: format, dataByteCount: 192_000)

        #expect(header.count == 44)
        #expect(String(decoding: header[0..<4], as: UTF8.self) == "RIFF")
        #expect(readUInt32(header, at: 4) == 192_036)
        #expect(String(decoding: header[8..<12], as: UTF8.self) == "WAVE")
        #expect(String(decoding: header[12..<16], as: UTF8.self) == "fmt ")
        #expect(readUInt32(header, at: 16) == 16)
        #expect(readUInt16(header, at: 20) == WAVEncoding.pcmInt16.rawValue)
        #expect(readUInt16(header, at: 22) == 2)
        #expect(readUInt32(header, at: 24) == 48_000)
        #expect(readUInt32(header, at: 28) == 192_000)
        #expect(readUInt16(header, at: 32) == 4)
        #expect(readUInt16(header, at: 34) == 16)
        #expect(String(decoding: header[36..<40], as: UTF8.self) == "data")
        #expect(readUInt32(header, at: 40) == 192_000)
    }

    @Test("Float32 and streaming headers retain legacy format semantics")
    func floatAndStreamingHeader() throws {
        let format = try WAVFormat(
            sampleRate: 96_000,
            channelCount: 2,
            encoding: .ieeeFloat32
        )
        let header = try WAVHeader.streaming(format: format)

        #expect(readUInt16(header, at: 20) == 3)
        #expect(readUInt16(header, at: 34) == 32)
        #expect(readUInt16(header, at: 32) == 8)
        #expect(readUInt32(header, at: 28) == 768_000)
        #expect(readUInt32(header, at: 40) == 0x7fff_ffff)
        #expect(readUInt32(header, at: 4) == 0x8000_0023)
    }

    @Test("Header and decoded format validation reject unsafe values")
    func validation() throws {
        #expect(throws: WAVError.invalidSampleRate(0)) {
            try WAVFormat(sampleRate: 0, channelCount: 2, encoding: .pcmInt16)
        }
        #expect(throws: WAVError.invalidChannelCount(0)) {
            try WAVFormat(sampleRate: 48_000, channelCount: 0, encoding: .pcmInt16)
        }

        let format = try WAVFormat(
            sampleRate: 48_000,
            channelCount: 2,
            encoding: .pcmInt16
        )
        #expect(throws: WAVError.dataTooLarge(UInt64(UInt32.max))) {
            try WAVHeader.make(format: format, dataByteCount: UInt64(UInt32.max))
        }

        let invalidJSON = Data(
            #"{"sampleRate":0,"channelCount":2,"encoding":1}"#.utf8
        )
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(WAVFormat.self, from: invalidJSON)
        }
    }

    @Test("PCM conversion clips, rounds, and sanitizes non-finite input")
    func conversionEdges() {
        let samples: [Float] = [
            -.infinity, -1, -0.5, -0.000_01, 0, 0.000_01, 0.5, 1, .infinity, .nan,
        ]
        let data = Float32PCMConverter.data(from: samples)
        let converted = stride(from: 0, to: data.count, by: 2).map {
            Int16(bitPattern: readUInt16(data, at: $0))
        }

        #expect(
            converted == [
                .min, .min, -16_384, 0, 0, 0, 16_384, .max, .max, 0,
            ])
    }

    @Test("Planar stereo conversion produces LRLR little-endian PCM")
    func stereoInterleaving() throws {
        let left: [Float] = [-1, 0.5, 1]
        let right: [Float] = [1, -0.5, 0]
        let data = try Float32PCMConverter.interleavedStereoData(
            left: left,
            right: right
        )
        let converted = stride(from: 0, to: data.count, by: 2).map {
            Int16(bitPattern: readUInt16(data, at: $0))
        }

        #expect(
            converted == [
                .min, .max, 16_384, -16_384, .max, 0,
            ])
    }

    @Test("Caller-owned conversion validates channel and destination sizes")
    func callerOwnedBuffers() {
        let left: [Float] = [0, 1]
        let shortRight: [Float] = [0]
        var destination = [Int16](repeating: 0, count: 4)

        #expect(throws: WAVError.mismatchedChannelCounts(left: 2, right: 1)) {
            try left.withUnsafeBufferPointer { leftBuffer in
                try shortRight.withUnsafeBufferPointer { rightBuffer in
                    try destination.withUnsafeMutableBufferPointer { destinationBuffer in
                        try Float32PCMConverter.convertInterleavedStereo(
                            left: leftBuffer,
                            right: rightBuffer,
                            into: destinationBuffer
                        )
                    }
                }
            }
        }

        var tooSmall = [Int16](repeating: 0, count: 1)
        #expect(throws: WAVError.destinationTooSmall(required: 2, actual: 1)) {
            try left.withUnsafeBufferPointer { source in
                try tooSmall.withUnsafeMutableBufferPointer { destination in
                    try Float32PCMConverter.convert(source, into: destination)
                }
            }
        }
    }
}

private func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
    UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
}

private func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
    UInt32(data[offset])
        | (UInt32(data[offset + 1]) << 8)
        | (UInt32(data[offset + 2]) << 16)
        | (UInt32(data[offset + 3]) << 24)
}
