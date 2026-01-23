//
//  Utilities.swift
//  DoubaoVoice
//
//  Core utilities, models, extensions, and constants
//

import Foundation
import Compression
import zlib
import Combine
import AppKit
import OSLog

// MARK: - Constants

enum DoubaoConstants: Sendable {
    static nonisolated let apiURL = "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async"
    static nonisolated let sampleRate: Double = 16000
    static nonisolated let channels: UInt32 = 1
    static nonisolated let segmentDuration: TimeInterval = 0.2 // 200ms
    static nonisolated let segmentSampleCount = Int(sampleRate * segmentDuration) // 3200 samples
    static nonisolated let bytesPerSample = 2 // int16
    static nonisolated let segmentByteSize = segmentSampleCount * bytesPerSample // 6400 bytes
    static nonisolated let shutdownTimeout: TimeInterval = 1.5
    static nonisolated let resourceID = "volc.seedasr.sauc.duration"
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
    nonisolated func toFullRequestJSON() -> [String: Any] {
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

    nonisolated var isSuccess: Bool {
        code == 0 || code == 1000
    }

    nonisolated init(text: String = "", isLastPackage: Bool = false, sequence: Int = 0, code: Int = 0, message: String = "") {
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

/// Window position mode
enum WindowPositionMode: String, Codable, CaseIterable {
    case rememberLast = "remember_last"
    case nearMouse = "near_mouse"
    case topCenter = "top_center"
    case bottomCenter = "bottom_center"

    var displayName: String {
        switch self {
        case .rememberLast: return "Remember Last Position"
        case .nearMouse: return "Near Mouse Cursor"
        case .topCenter: return "Top of Screen"
        case .bottomCenter: return "Bottom of Screen"
        }
    }

    var displayNameChinese: String {
        switch self {
        case .rememberLast: return "记忆上次的位置"
        case .nearMouse: return "出现在鼠标的附近"
        case .topCenter: return "屏幕的上方"
        case .bottomCenter: return "屏幕的下方"
        }
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
    enum MessageTypeFlags: Sendable {
        static nonisolated let noSequence: UInt8 = 0b0000
        static nonisolated let posSequence: UInt8 = 0b0001       // Positive sequence number present
        static nonisolated let negSequence: UInt8 = 0b0010       // Negative sequence (final packet)
        static nonisolated let negWithSequence: UInt8 = 0b0011   // Both flags set
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

    nonisolated init(messageType: MessageType, flags: UInt8 = 0b0000, compression: Compression = .gzip) {
        self.messageType = messageType
        self.flags = flags
        self.compression = compression
    }

    nonisolated func encode() -> Data {
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
    nonisolated mutating func appendInt32BE(_ value: Int32) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { buffer in
            self.append(contentsOf: buffer)
        }
    }

    /// Append UInt32 in big-endian format
    nonisolated mutating func appendUInt32BE(_ value: UInt32) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { buffer in
            self.append(contentsOf: buffer)
        }
    }

    /// Append UInt32 in little-endian format
    nonisolated mutating func appendUInt32LE(_ value: UInt32) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { buffer in
            self.append(contentsOf: buffer)
        }
    }

    /// Read Int32 from big-endian format
    nonisolated func readInt32BE(at offset: Int) -> Int32? {
        guard offset + 4 <= count else { return nil }
        let bytes = self[offset..<offset+4]
        return bytes.withUnsafeBytes { buffer in
            buffer.load(as: Int32.self).bigEndian
        }
    }

    /// Read UInt32 from big-endian format
    nonisolated func readUInt32BE(at offset: Int) -> UInt32? {
        guard offset + 4 <= count else { return nil }
        let bytes = self[offset..<offset+4]
        return bytes.withUnsafeBytes { buffer in
            buffer.load(as: UInt32.self).bigEndian
        }
    }

    /// GZIP compress data using zlib (RFC 1952 compliant)
    nonisolated func gzipCompressed() -> Data? {
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
                outputBuffer.withUnsafeMutableBufferPointer { bufferPtr in
                    stream.avail_out = uInt(chunkSize)
                    stream.next_out = bufferPtr.baseAddress

                    status = deflate(&stream, Z_FINISH)
                }

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
    nonisolated func gzipDecompressed() -> Data? {
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
                outputBuffer.withUnsafeMutableBufferPointer { bufferPtr in
                    stream.avail_out = uInt(chunkSize)
                    stream.next_out = bufferPtr.baseAddress

                    status = inflate(&stream, Z_NO_FLUSH)
                }

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

/// Log levels for categorizing log messages
enum LogLevel {
    case debug, info, warning, error

    nonisolated var prefix: String {
        switch self {
        case .debug: return "🔍"
        case .info: return "ℹ️"
        case .warning: return "⚠️"
        case .error: return "❌"
        }
    }
}

/// Logger extensions with categorized loggers for different subsystems
extension Logger {
    private static nonisolated let subsystem = Bundle.main.bundleIdentifier ?? "com.doubaovoice"

    /// Logger for audio recording and processing
    static nonisolated let audio = Logger(subsystem: subsystem, category: "Audio")

    /// Logger for ASR (Automatic Speech Recognition) operations
    static nonisolated let asr = Logger(subsystem: subsystem, category: "ASR")

    /// Logger for UI and window management
    static nonisolated let ui = Logger(subsystem: subsystem, category: "UI")

    /// Logger for network/WebSocket operations
    static nonisolated let network = Logger(subsystem: subsystem, category: "Network")

    /// Logger for hotkey and system events
    static nonisolated let hotkey = Logger(subsystem: subsystem, category: "Hotkey")

    /// Logger for general/uncategorized logs
    static nonisolated let general = Logger(subsystem: subsystem, category: "General")
}

/// Unified logging function using Apple's OSLog framework
///
/// This function provides backward compatibility while using the modern Logger API.
/// Logs are integrated with macOS Console.app and can be filtered by subsystem and category.
///
/// Usage:
/// ```swift
/// log(.info, "Starting transcription session...")
/// log(.error, "Failed to connect: \(error)")
/// log(.debug, "Audio buffer size: \(bufferSize) bytes")
/// ```
///
/// To view logs in Console.app:
/// 1. Open Console.app
/// 2. Filter by process: "DoubaoVoice"
/// 3. Filter by subsystem: "com.doubaovoice"
///
/// To view logs in terminal:
/// ```bash
/// log stream --predicate 'subsystem == "com.doubaovoice"'
/// log stream --predicate 'subsystem == "com.doubaovoice" AND category == "ASR"'
/// ```
nonisolated func log(_ level: LogLevel, _ message: String, file: String = #file, line: Int = #line) {
    let filename = (file as NSString).lastPathComponent
    let logger = Logger.general

    // Format the message with file and line information
    let formattedMessage = "\(filename):\(line) - \(message)"

    switch level {
    case .debug:
        logger.debug("\(formattedMessage, privacy: .public)")
    case .info:
        logger.info("\(formattedMessage, privacy: .public)")
    case .warning:
        logger.warning("\(formattedMessage, privacy: .public)")
    case .error:
        logger.error("\(formattedMessage, privacy: .public)")
    }

    // Also print to console for development convenience
    #if DEBUG
    print("[\(level.prefix)] \(formattedMessage)")
    #endif
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

    /// Remove trailing punctuation (both full-width and half-width)
    /// Full-width: 。！？；：，、
    /// Half-width: . ! ? ; : ,
    func removingTrailingPunctuation() -> String {
        let fullWidthPunctuation: Set<Character> = ["。", "！", "？", "；", "：", "，", "、"]
        let halfWidthPunctuation: Set<Character> = [".", "!", "?", ";", ":", ","]
        let allPunctuation = fullWidthPunctuation.union(halfWidthPunctuation)

        var result = self
        while let lastChar = result.last, allPunctuation.contains(lastChar) {
            result.removeLast()
        }
        return result
    }
}

// MARK: - UserDefaults Keys

enum UserDefaultsKeys {
    static let appKey = "DoubaoVoice.AppKey"
    static let accessKey = "DoubaoVoice.AccessKey"
    static let resourceID = "DoubaoVoice.ResourceID"
    static let httpPort = "DoubaoVoice.HTTPPort"
    static let enableVAD = "DoubaoVoice.EnableVAD"
    static let globalHotkeyKeyCode = "DoubaoVoice.GlobalHotkeyKeyCode"
    static let globalHotkeyModifiers = "DoubaoVoice.GlobalHotkeyModifiers"
    static let rememberWindowPosition = "DoubaoVoice.RememberWindowPosition"
    static let windowPositionMode = "DoubaoVoice.WindowPositionMode"
    static let windowPositionX = "DoubaoVoice.WindowPositionX"
    static let windowPositionY = "DoubaoVoice.WindowPositionY"
    static let finishHotkeyKeyCode = "DoubaoVoice.FinishHotkeyKeyCode"
    static let finishHotkeyModifiers = "DoubaoVoice.FinishHotkeyModifiers"
    static let autoPasteAfterClose = "DoubaoVoice.AutoPasteAfterClose"
    static let removeTrailingPunctuation = "DoubaoVoice.RemoveTrailingPunctuation"

    // Long-press modifier key settings
    static let longPressEnabled = "DoubaoVoice.LongPressEnabled"
    static let longPressModifierKey = "DoubaoVoice.LongPressModifierKey"
    static let longPressMinDuration = "DoubaoVoice.LongPressMinDuration"
    static let longPressAutoSubmit = "DoubaoVoice.LongPressAutoSubmit"

    static let defaultPort = 18888
}

// MARK: - Long-Press Modifier Key

/// Available modifier keys for long-press activation
enum LongPressModifierKey: String, Codable, CaseIterable {
    case option
    case command
    case control
    case shift
    case fn

    var displayName: String {
        switch self {
        case .option: return "Option"
        case .command: return "Command"
        case .control: return "Control"
        case .shift: return "Shift"
        case .fn: return "Fn"
        }
    }

    var symbol: String {
        switch self {
        case .option: return "⌥"
        case .command: return "⌘"
        case .control: return "⌃"
        case .shift: return "⇧"
        case .fn: return "fn"
        }
    }

    /// The NSEvent.ModifierFlags corresponding to this key
    var modifierFlag: NSEvent.ModifierFlags {
        switch self {
        case .option: return .option
        case .command: return .command
        case .control: return .control
        case .shift: return .shift
        case .fn: return .function
        }
    }
}

/// Configuration for long-press modifier key activation
struct LongPressConfig: Codable, Equatable {
    var enabled: Bool
    var modifierKey: LongPressModifierKey
    var minimumPressDuration: TimeInterval
    var autoSubmitOnRelease: Bool

    static let `default` = LongPressConfig(
        enabled: false,
        modifierKey: .option,
        minimumPressDuration: 0.15,
        autoSubmitOnRelease: true
    )
}

// MARK: - Hotkey Configuration

struct HotkeyConfig: Codable, Equatable {
    let keyCode: UInt32
    let modifiers: UInt32

    // Default: Option+Command+V
    static let `default` = HotkeyConfig(
        keyCode: 9,  // V key
        modifiers: UInt32(optionKey | cmdKey)
    )

    // Default finish hotkey: Enter key with no modifiers (local scope)
    static let defaultFinish = HotkeyConfig(
        keyCode: 36,  // Enter key
        modifiers: 0  // No modifiers required (local scope)
    )

    // Unset hotkey (no binding)
    static let unset = HotkeyConfig(
        keyCode: 0,
        modifiers: 0
    )

    var isUnset: Bool {
        return keyCode == 0 && modifiers == 0
    }

    var displayString: String {
        // Show "Not Set" for unset hotkeys
        if isUnset {
            return "Not Set"
        }

        var parts: [String] = []

        if modifiers & UInt32(controlKey) != 0 {
            parts.append("⌃")
        }
        if modifiers & UInt32(optionKey) != 0 {
            parts.append("⌥")
        }
        if modifiers & UInt32(shiftKey) != 0 {
            parts.append("⇧")
        }
        if modifiers & UInt32(cmdKey) != 0 {
            parts.append("⌘")
        }

        // Map common key codes to symbols
        let keyString = keyCodeToString(keyCode)
        parts.append(keyString)

        // No spaces at all
        return parts.joined()
    }

    private func keyCodeToString(_ code: UInt32) -> String {
        switch code {
        case 0: return "A"
        case 1: return "S"
        case 2: return "D"
        case 3: return "F"
        case 4: return "H"
        case 5: return "G"
        case 6: return "Z"
        case 7: return "X"
        case 8: return "C"
        case 9: return "V"
        case 11: return "B"
        case 12: return "Q"
        case 13: return "W"
        case 14: return "E"
        case 15: return "R"
        case 16: return "Y"
        case 17: return "T"
        case 31: return "O"
        case 32: return "U"
        case 34: return "I"
        case 35: return "P"
        case 37: return "L"
        case 38: return "J"
        case 40: return "K"
        case 45: return "N"
        case 46: return "M"
        case 49: return "Space"
        case 36: return "⏎"
        case 51: return "⌫"
        case 53: return "⎋"
        default: return "[\(code)]"
        }
    }
}

// Carbon key modifier constants
let controlKey: Int = 1 << 12
let optionKey: Int = 1 << 11
let shiftKey: Int = 1 << 9
let cmdKey: Int = 1 << 8

// MARK: - App Settings

class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    @Published var appKey: String {
        didSet { defaults.set(appKey, forKey: UserDefaultsKeys.appKey) }
    }

    @Published var accessKey: String {
        didSet { defaults.set(accessKey, forKey: UserDefaultsKeys.accessKey) }
    }

    var resourceID: String {
        DoubaoConstants.resourceID
    }

    @Published var enableVAD: Bool {
        didSet { defaults.set(enableVAD, forKey: UserDefaultsKeys.enableVAD) }
    }

    @Published var globalHotkey: HotkeyConfig {
        didSet {
            defaults.set(globalHotkey.keyCode, forKey: UserDefaultsKeys.globalHotkeyKeyCode)
            defaults.set(globalHotkey.modifiers, forKey: UserDefaultsKeys.globalHotkeyModifiers)
            // Notify that hotkey has changed so AppDelegate can re-register
            NotificationCenter.default.post(name: .globalHotkeyChanged, object: nil)
        }
    }

    @Published var finishHotkey: HotkeyConfig {
        didSet {
            defaults.set(finishHotkey.keyCode, forKey: UserDefaultsKeys.finishHotkeyKeyCode)
            defaults.set(finishHotkey.modifiers, forKey: UserDefaultsKeys.finishHotkeyModifiers)
        }
    }

    @Published var windowPositionMode: WindowPositionMode {
        didSet {
            if let encoded = try? JSONEncoder().encode(windowPositionMode) {
                defaults.set(encoded, forKey: UserDefaultsKeys.windowPositionMode)
            }
        }
    }

    @Published var autoPasteAfterClose: Bool {
        didSet { defaults.set(autoPasteAfterClose, forKey: UserDefaultsKeys.autoPasteAfterClose) }
    }

    @Published var removeTrailingPunctuation: Bool {
        didSet { defaults.set(removeTrailingPunctuation, forKey: UserDefaultsKeys.removeTrailingPunctuation) }
    }

    @Published var longPressConfig: LongPressConfig {
        didSet {
            if let encoded = try? JSONEncoder().encode(longPressConfig) {
                defaults.set(encoded, forKey: UserDefaultsKeys.longPressEnabled)
            }
            // Notify that long-press config has changed
            NotificationCenter.default.post(name: .longPressConfigChanged, object: nil)
        }
    }

    private init() {
        // Load saved values or use defaults (from reference.py credentials)
        self.appKey = defaults.string(forKey: UserDefaultsKeys.appKey) ?? "3254061168"
        self.accessKey = defaults.string(forKey: UserDefaultsKeys.accessKey) ?? "1jFY86tc4aNrg-8K69dIM43HSjJ_jhyb"
        self.enableVAD = defaults.object(forKey: UserDefaultsKeys.enableVAD) as? Bool ?? true

        // Load hotkey config
        let keyCode = defaults.object(forKey: UserDefaultsKeys.globalHotkeyKeyCode) as? UInt32 ?? HotkeyConfig.default.keyCode
        let modifiers = defaults.object(forKey: UserDefaultsKeys.globalHotkeyModifiers) as? UInt32 ?? HotkeyConfig.default.modifiers
        self.globalHotkey = HotkeyConfig(keyCode: keyCode, modifiers: modifiers)

        // Load finish hotkey config
        let finishKeyCode = defaults.object(forKey: UserDefaultsKeys.finishHotkeyKeyCode) as? UInt32 ?? HotkeyConfig.defaultFinish.keyCode
        let finishModifiers = defaults.object(forKey: UserDefaultsKeys.finishHotkeyModifiers) as? UInt32 ?? HotkeyConfig.defaultFinish.modifiers
        self.finishHotkey = HotkeyConfig(keyCode: finishKeyCode, modifiers: finishModifiers)

        // Load window position mode with migration from old boolean setting
        if let modeData = defaults.data(forKey: UserDefaultsKeys.windowPositionMode),
           let mode = try? JSONDecoder().decode(WindowPositionMode.self, from: modeData) {
            self.windowPositionMode = mode
        } else if let oldRememberPosition = defaults.object(forKey: UserDefaultsKeys.rememberWindowPosition) as? Bool {
            // Migrate from old boolean setting: true -> rememberLast, false -> topCenter
            let migratedMode: WindowPositionMode = oldRememberPosition ? .rememberLast : .topCenter
            self.windowPositionMode = migratedMode
            log(.info, "Migrated window position setting from boolean to mode: \(migratedMode.rawValue)")
            // Remove old key after migration
            defaults.removeObject(forKey: UserDefaultsKeys.rememberWindowPosition)
        } else {
            // Default to rememberLast for new installations
            self.windowPositionMode = .rememberLast
        }

        self.autoPasteAfterClose = defaults.object(forKey: UserDefaultsKeys.autoPasteAfterClose) as? Bool ?? true

        self.removeTrailingPunctuation = defaults.object(forKey: UserDefaultsKeys.removeTrailingPunctuation) as? Bool ?? false

        // Load long-press config
        if let configData = defaults.data(forKey: UserDefaultsKeys.longPressEnabled),
           let config = try? JSONDecoder().decode(LongPressConfig.self, from: configData) {
            self.longPressConfig = config
        } else {
            self.longPressConfig = .default
        }

        // Migrate: Remove deprecated resourceID setting
        if defaults.object(forKey: UserDefaultsKeys.resourceID) != nil {
            defaults.removeObject(forKey: UserDefaultsKeys.resourceID)
            log(.info, "Migrated: Removed deprecated resourceID from UserDefaults")
        }
    }

    // Get saved window position if available
    func getSavedWindowPosition() -> NSPoint? {
        // Only return saved position if in rememberLast mode
        guard windowPositionMode == .rememberLast else { return nil }

        let x = defaults.object(forKey: UserDefaultsKeys.windowPositionX) as? CGFloat
        let y = defaults.object(forKey: UserDefaultsKeys.windowPositionY) as? CGFloat

        if let x = x, let y = y {
            return NSPoint(x: x, y: y)
        }
        return nil
    }

    // Save window position
    func saveWindowPosition(_ position: NSPoint) {
        // Only save position if in rememberLast mode
        guard windowPositionMode == .rememberLast else { return }
        defaults.set(position.x, forKey: UserDefaultsKeys.windowPositionX)
        defaults.set(position.y, forKey: UserDefaultsKeys.windowPositionY)
    }
}
