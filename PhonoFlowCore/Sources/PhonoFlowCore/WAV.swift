import Foundation

public enum WAVEncoding: UInt16, Codable, Sendable {
    /// Signed little-endian 16-bit linear PCM (WAVE format code 1).
    case pcmInt16 = 1
    /// Native Float32 payload represented by WAVE format code 3.
    case ieeeFloat32 = 3

    public var bitsPerSample: UInt16 {
        switch self {
        case .pcmInt16:
            16
        case .ieeeFloat32:
            32
        }
    }
}

public enum WAVError: Error, Equatable, Sendable {
    case invalidSampleRate(UInt32)
    case invalidChannelCount(UInt16)
    case formatValueOverflow
    case dataTooLarge(UInt64)
    case mismatchedChannelCounts(left: Int, right: Int)
    case destinationTooSmall(required: Int, actual: Int)
}

public struct WAVFormat: Codable, Equatable, Sendable {
    public let sampleRate: UInt32
    public let channelCount: UInt16
    public let encoding: WAVEncoding

    public init(
        sampleRate: UInt32,
        channelCount: UInt16,
        encoding: WAVEncoding
    ) throws {
        guard sampleRate > 0 else {
            throw WAVError.invalidSampleRate(sampleRate)
        }
        guard channelCount > 0 else {
            throw WAVError.invalidChannelCount(channelCount)
        }

        let blockAlign = UInt64(channelCount) * UInt64(encoding.bitsPerSample / 8)
        let byteRate = UInt64(sampleRate) * blockAlign
        guard blockAlign <= UInt64(UInt16.max), byteRate <= UInt64(UInt32.max) else {
            throw WAVError.formatValueOverflow
        }

        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.encoding = encoding
    }

    private enum CodingKeys: String, CodingKey {
        case sampleRate
        case channelCount
        case encoding
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                sampleRate: container.decode(UInt32.self, forKey: .sampleRate),
                channelCount: container.decode(UInt16.self, forKey: .channelCount),
                encoding: container.decode(WAVEncoding.self, forKey: .encoding)
            )
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .sampleRate,
                in: container,
                debugDescription: error.localizedDescription
            )
        }
    }

    public var bitsPerSample: UInt16 {
        encoding.bitsPerSample
    }

    public var blockAlign: UInt16 {
        UInt16(channelCount * (bitsPerSample / 8))
    }

    public var byteRate: UInt32 {
        sampleRate * UInt32(blockAlign)
    }
}

/// Generates canonical 44-byte RIFF/WAVE headers.
public enum WAVHeader {
    public static let byteCount = 44
    public static let defaultStreamingDataByteCount: UInt32 = 0x7fff_ffff

    public static func make(
        format: WAVFormat,
        dataByteCount: UInt64
    ) throws -> Data {
        guard dataByteCount <= UInt64(UInt32.max) - 36 else {
            throw WAVError.dataTooLarge(dataByteCount)
        }

        let payloadSize = UInt32(dataByteCount)
        var data = Data()
        data.reserveCapacity(byteCount)
        data.appendASCII("RIFF")
        data.appendLittleEndian(36 + payloadSize)
        data.appendASCII("WAVE")
        data.appendASCII("fmt ")
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(format.encoding.rawValue)
        data.appendLittleEndian(format.channelCount)
        data.appendLittleEndian(format.sampleRate)
        data.appendLittleEndian(format.byteRate)
        data.appendLittleEndian(format.blockAlign)
        data.appendLittleEndian(format.bitsPerSample)
        data.appendASCII("data")
        data.appendLittleEndian(payloadSize)
        return data
    }

    /// Generates a header for an open-ended HTTP response. The declared size
    /// is a compatibility placeholder; streaming terminates with the response.
    public static func streaming(
        format: WAVFormat,
        declaredDataByteCount: UInt32 = defaultStreamingDataByteCount
    ) throws -> Data {
        try make(format: format, dataByteCount: UInt64(declaredDataByteCount))
    }
}

public enum Float32PCMConverter {
    /// Converts samples into caller-owned initialized storage without
    /// allocating. Returns the number of converted samples.
    @discardableResult
    public static func convert(
        _ source: UnsafeBufferPointer<Float>,
        into destination: UnsafeMutableBufferPointer<Int16>
    ) throws -> Int {
        guard destination.count >= source.count else {
            throw WAVError.destinationTooSmall(
                required: source.count,
                actual: destination.count
            )
        }

        for index in source.indices {
            destination[index] = quantize(source[index])
        }
        return source.count
    }

    /// Converts mono or already-interleaved Float32 samples to little-endian
    /// PCM16 data for file/network worker paths.
    public static func data(from samples: [Float]) -> Data {
        var output = Data(count: samples.count * MemoryLayout<Int16>.size)
        output.withUnsafeMutableBytes { rawDestination in
            samples.withUnsafeBufferPointer { source in
                guard let sourceBase = source.baseAddress else {
                    return
                }
                for index in source.indices {
                    writeLittleEndian(
                        quantize(sourceBase[index]),
                        to: rawDestination,
                        byteOffset: index * 2
                    )
                }
            }
        }
        return output
    }

    /// Interleaves planar stereo while converting into caller-owned
    /// initialized Int16 storage.
    @discardableResult
    public static func convertInterleavedStereo(
        left: UnsafeBufferPointer<Float>,
        right: UnsafeBufferPointer<Float>,
        into destination: UnsafeMutableBufferPointer<Int16>
    ) throws -> Int {
        guard left.count == right.count else {
            throw WAVError.mismatchedChannelCounts(
                left: left.count,
                right: right.count
            )
        }
        let required = left.count * 2
        guard destination.count >= required else {
            throw WAVError.destinationTooSmall(
                required: required,
                actual: destination.count
            )
        }

        for frame in left.indices {
            destination[frame * 2] = quantize(left[frame])
            destination[frame * 2 + 1] = quantize(right[frame])
        }
        return required
    }

    public static func interleavedStereoData(
        left: [Float],
        right: [Float]
    ) throws -> Data {
        guard left.count == right.count else {
            throw WAVError.mismatchedChannelCounts(
                left: left.count,
                right: right.count
            )
        }

        var output = Data(count: left.count * 2 * MemoryLayout<Int16>.size)
        output.withUnsafeMutableBytes { rawDestination in
            left.withUnsafeBufferPointer { leftSource in
                right.withUnsafeBufferPointer { rightSource in
                    for frame in left.indices {
                        writeLittleEndian(
                            quantize(leftSource[frame]),
                            to: rawDestination,
                            byteOffset: frame * 4
                        )
                        writeLittleEndian(
                            quantize(rightSource[frame]),
                            to: rawDestination,
                            byteOffset: frame * 4 + 2
                        )
                    }
                }
            }
        }
        return output
    }

    @inline(__always)
    private static func quantize(_ sample: Float) -> Int16 {
        if sample.isNaN {
            return 0
        }
        if sample >= 1 {
            return Int16.max
        }
        if sample <= -1 {
            return Int16.min
        }
        if sample >= 0 {
            return Int16((sample * Float(Int16.max)).rounded())
        }
        return Int16((sample * Float(-Int(Int16.min))).rounded())
    }

    @inline(__always)
    private static func writeLittleEndian(
        _ sample: Int16,
        to destination: UnsafeMutableRawBufferPointer,
        byteOffset: Int
    ) {
        let value = UInt16(bitPattern: sample)
        destination[byteOffset] = UInt8(truncatingIfNeeded: value)
        destination[byteOffset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }
}

extension Data {
    fileprivate mutating func appendASCII(_ value: StaticString) {
        value.withUTF8Buffer { buffer in
            append(contentsOf: buffer)
        }
    }

    fileprivate mutating func appendLittleEndian<Value: FixedWidthInteger>(
        _ value: Value
    ) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { buffer in
            append(contentsOf: buffer)
        }
    }
}
