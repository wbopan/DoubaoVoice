//
//  Utilities.swift
//  DoubaoVoice
//
//  Core utilities, models, extensions, and constants
//

import Foundation
import Compression
import zlib

// MARK: - Constants

enum DoubaoConstants {
    static let apiURL = "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async"
    static let sampleRate: Double = 16000
    static let channels: UInt32 = 1
    static let segmentDuration: TimeInterval = 0.2 // 200ms
    static let segmentSampleCount = Int(sampleRate * segmentDuration) // 3200 samples
    static let bytesPerSample = 2 // int16
    static let segmentByteSize = segmentSampleCount * bytesPerSample // 6400 bytes
    static let shutdownTimeout: TimeInterval = 1.5
    static let resourceID = "volc.seedasr.sauc.duration"
}

// MARK: - Models

/// ASR configuration
struct ASRConfig: Sendable {
    let appKey: String
    let accessKey: String
    let resourceID: String
    let enableVAD: Bool
    let language: String
    let format: String
    let sampleRate: Int
    let bits: Int

    init(
        appKey: String,
        accessKey: String,
        resourceID: String = DoubaoConstants.resourceID,
        enableVAD: Bool = true,
        language: String = "zh-CN",
        format: String = "pcm",
        sampleRate: Int = Int(DoubaoConstants.sampleRate),
        bits: Int = 16
    ) {
        self.appKey = appKey
        self.accessKey = accessKey
        self.resourceID = resourceID
        self.enableVAD = enableVAD
        self.language = language
        self.format = format
        self.sampleRate = sampleRate
        self.bits = bits
    }

    /// Generate full JSON payload for initial request (matches Python reference)
    func toFullRequestJSON() -> [String: Any] {
        return [
            "user": [
                "uid": "doubaovoice_user"
            ],
            "audio": [
                "format": "pcm",
                "codec": "raw",
                "rate": sampleRate,
                "bits": bits,
                "channel": 1
            ],
            "request": [
                "model_name": "bigmodel",
                "enable_itn": true,
                "enable_punc": true,
                "enable_ddc": true,
                "show_utterances": true,
                "enable_nonstream": true,
                "end_window_size": 1000
            ]
        ]
    }
}

/// ASR result from server
struct ASRResult: Sendable {
    let text: String
    let isLastPackage: Bool
    let sequence: Int
    let code: Int
    let message: String

    var isSuccess: Bool {
        code == 0 || code == 1000
    }

    init(text: String = "", isLastPackage: Bool = false, sequence: Int = 0, code: Int = 0, message: String = "") {
        self.text = text
        self.isLastPackage = isLastPackage
        self.sequence = sequence
        self.code = code
        self.message = message
    }
}

/// Recording session result
struct RecordingSession {
    let text: String
    let duration: TimeInterval
    let timestamp: Date

    init(text: String, duration: TimeInterval, timestamp: Date = Date()) {
        self.text = text
        self.duration = duration
        self.timestamp = timestamp
    }
}

/// HTTP API response
struct APIResponse: Codable {
    let status: String
    let text: String?
    let duration: Double?
    let message: String?

    init(status: String, text: String? = nil, duration: Double? = nil, message: String? = nil) {
        self.status = status
        self.text = text
        self.duration = duration
        self.message = message
    }

    func toJSON() -> Data? {
        try? JSONEncoder().encode(self)
    }
}

// MARK: - Binary Protocol Header

/// Binary protocol header (4 bytes)
/// [Version:4bits|HeaderSize:4bits][MessageType:4bits|Flags:4bits][Serialization:4bits|Compression:4bits][Reserved:8bits]
struct ProtocolHeader {
    static let size = 4

    // Byte 0: Version (4 bits) | Header Size (4 bits)
    let version: UInt8 = 0b0001  // Version 1
    let headerSize: UInt8 = 0b0001  // Header size = 1 (meaning 4 bytes)

    // Byte 1: Message Type (4 bits) | Flags (4 bits)
    enum MessageType: UInt8 {
        case full = 0b0001              // Full request with JSON payload
        case audio = 0b0010             // Audio-only request
        case serverFull = 0b1001        // Server full response
        case serverError = 0b1111       // Server error response
    }
    let messageType: MessageType
    let flags: UInt8  // Message type specific flags

    // Message type specific flags (matches Python reference)
    enum MessageTypeFlags {
        static let noSequence: UInt8 = 0b0000
        static let posSequence: UInt8 = 0b0001       // Positive sequence number present
        static let negSequence: UInt8 = 0b0010       // Negative sequence (final packet)
        static let negWithSequence: UInt8 = 0b0011   // Both flags set
    }

    // Byte 2: Serialization (4 bits) | Compression (4 bits)
    enum Serialization: UInt8 {
        case json = 0b0001
    }
    enum Compression: UInt8 {
        case none = 0b0000
        case gzip = 0b0001
    }
    let serialization: Serialization = .json
    let compression: Compression  // Compression type for this message

    // Byte 3: Reserved
    let reserved: UInt8 = 0x00

    init(messageType: MessageType, flags: UInt8 = 0b0000, compression: Compression = .gzip) {
        self.messageType = messageType
        self.flags = flags
        self.compression = compression
    }

    func encode() -> Data {
        var data = Data(capacity: 4)

        // Byte 0: [Version:4|HeaderSize:4]
        let byte0 = (version << 4) | headerSize
        data.append(byte0)

        // Byte 1: [MessageType:4|Flags:4]
        let byte1 = (messageType.rawValue << 4) | flags
        data.append(byte1)

        // Byte 2: [Serialization:4|Compression:4]
        let byte2 = (serialization.rawValue << 4) | compression.rawValue
        data.append(byte2)

        // Byte 3: Reserved
        data.append(reserved)

        return data
    }

    nonisolated static func decode(from data: Data) -> ProtocolHeader? {
        guard data.count >= 4 else { return nil }

        let byte1 = data[1]
        let messageTypeRaw = (byte1 >> 4) & 0x0F

        guard let messageType = MessageType(rawValue: messageTypeRaw) else {
            return nil
        }

        return ProtocolHeader(messageType: messageType)
    }
}

// MARK: - Data Extensions

extension Data {
    /// Append Int32 in big-endian format
    mutating func appendInt32BE(_ value: Int32) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { buffer in
            self.append(contentsOf: buffer)
        }
    }

    /// Append UInt32 in big-endian format
    mutating func appendUInt32BE(_ value: UInt32) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { buffer in
            self.append(contentsOf: buffer)
        }
    }

    /// Append UInt32 in little-endian format
    mutating func appendUInt32LE(_ value: UInt32) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { buffer in
            self.append(contentsOf: buffer)
        }
    }

    /// Read Int32 from big-endian format
    func readInt32BE(at offset: Int) -> Int32? {
        guard offset + 4 <= count else { return nil }
        let bytes = self[offset..<offset+4]
        return bytes.withUnsafeBytes { buffer in
            buffer.load(as: Int32.self).bigEndian
        }
    }

    /// Read UInt32 from big-endian format
    func readUInt32BE(at offset: Int) -> UInt32? {
        guard offset + 4 <= count else { return nil }
        let bytes = self[offset..<offset+4]
        return bytes.withUnsafeBytes { buffer in
            buffer.load(as: UInt32.self).bigEndian
        }
    }

    /// GZIP compress data using zlib (RFC 1952 compliant)
    func gzipCompressed() -> Data? {
        return self.withUnsafeBytes { (sourcePtr: UnsafeRawBufferPointer) -> Data? in
            guard let baseAddress = sourcePtr.baseAddress else { return nil }

            // Allocate z_stream
            var stream = z_stream()

            // Initialize for compression with GZIP format
            // windowBits = 15 (max) + 16 (GZIP format)
            let windowBits: Int32 = 15 + 16
            var status = deflateInit2_(
                &stream,
                Z_DEFAULT_COMPRESSION,
                Z_DEFLATED,
                windowBits,
                8,  // memLevel
                Z_DEFAULT_STRATEGY,
                ZLIB_VERSION,
                Int32(MemoryLayout<z_stream>.size)
            )

            guard status == Z_OK else { return nil }
            defer { deflateEnd(&stream) }

            // Set input
            stream.avail_in = uInt(self.count)
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: baseAddress.assumingMemoryBound(to: Bytef.self))

            // Prepare output buffer
            let chunkSize = 16384
            var outputData = Data()
            var outputBuffer = [UInt8](repeating: 0, count: chunkSize)

            repeat {
                stream.avail_out = uInt(chunkSize)
                stream.next_out = UnsafeMutablePointer<Bytef>(&outputBuffer)

                status = deflate(&stream, Z_FINISH)

                guard status >= 0 else { return nil }

                let bytesWritten = chunkSize - Int(stream.avail_out)
                if bytesWritten > 0 {
                    outputData.append(outputBuffer, count: bytesWritten)
                }

            } while status != Z_STREAM_END

            return outputData
        }
    }

    /// GZIP decompress data using zlib
    func gzipDecompressed() -> Data? {
        return self.withUnsafeBytes { (sourcePtr: UnsafeRawBufferPointer) -> Data? in
            guard let baseAddress = sourcePtr.baseAddress else { return nil }

            // Allocate z_stream
            var stream = z_stream()

            // Initialize for decompression with GZIP format
            // windowBits = 15 (max) + 16 (GZIP format)
            let windowBits: Int32 = 15 + 16
            var status = inflateInit2_(
                &stream,
                windowBits,
                ZLIB_VERSION,
                Int32(MemoryLayout<z_stream>.size)
            )

            guard status == Z_OK else { return nil }
            defer { inflateEnd(&stream) }

            // Set input
            stream.avail_in = uInt(self.count)
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: baseAddress.assumingMemoryBound(to: Bytef.self))

            // Prepare output buffer
            let chunkSize = 16384
            var outputData = Data()
            var outputBuffer = [UInt8](repeating: 0, count: chunkSize)

            repeat {
                stream.avail_out = uInt(chunkSize)
                stream.next_out = UnsafeMutablePointer<Bytef>(&outputBuffer)

                status = inflate(&stream, Z_NO_FLUSH)

                guard status >= 0 || status == Z_BUF_ERROR else { return nil }

                let bytesWritten = chunkSize - Int(stream.avail_out)
                if bytesWritten > 0 {
                    outputData.append(outputBuffer, count: bytesWritten)
                }

                if status == Z_STREAM_END { break }

            } while stream.avail_out == 0

            return outputData
        }
    }
}

// MARK: - Logging

enum LogLevel {
    case debug, info, warning, error

    var prefix: String {
        switch self {
        case .debug: return "🔍"
        case .info: return "ℹ️"
        case .warning: return "⚠️"
        case .error: return "❌"
        }
    }
}

nonisolated func log(_ level: LogLevel, _ message: String, file: String = #file, line: Int = #line) {
    let filename = (file as NSString).lastPathComponent
    print("[\(level.prefix)] \(filename):\(line) - \(message)")
}

// MARK: - Helper Extensions

extension Date {
    var timestamp: TimeInterval {
        return timeIntervalSince1970
    }
}

extension String {
    var isNotEmpty: Bool {
        return !isEmpty
    }
}

// MARK: - UserDefaults Keys

enum UserDefaultsKeys {
    static let appKey = "DoubaoVoice.AppKey"
    static let accessKey = "DoubaoVoice.AccessKey"
    static let resourceID = "DoubaoVoice.ResourceID"
    static let httpPort = "DoubaoVoice.HTTPPort"
    static let enableVAD = "DoubaoVoice.EnableVAD"

    static let defaultPort = 18888
}
