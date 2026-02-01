//
//  DocumentContentReader.swift
//  DoubaoVoice
//
//  Reads text content from document files when Accessibility API cannot capture text
//

import Foundation
import OSLog

/// Reads document content from file system as fallback when Accessibility API fails
actor DocumentContentReader {
    static let shared = DocumentContentReader()

    private let logger = Logger.accessibility

    /// Supported text file extensions
    private let supportedExtensions: Set<String> = [
        // Code files
        "swift", "py", "js", "ts", "go", "rs", "c", "cpp", "h", "java", "kt", "rb", "php",
        // Config and data files
        "md", "txt", "json", "yaml", "yml", "xml", "html", "css", "toml", "ini", "conf",
        // Scripts and logs
        "sh", "log", "csv", "sql"
    ]

    /// Maximum file size to read (10 MB absolute limit)
    private let maxFileSize: Int = 10 * 1024 * 1024

    /// Threshold for reading entire file vs. reading from end (64 KB)
    private let smallFileThreshold: Int = 64 * 1024

    private init() {}

    // MARK: - Public API

    /// Read content from a document path
    /// - Parameters:
    ///   - path: The file path to read
    ///   - maxLength: Maximum content length to return (truncates from beginning, keeps end)
    /// - Returns: File content string, or nil if file cannot be read
    func readContent(from path: String, maxLength: Int) async -> String? {
        logger.debug("Attempting to read document: \(path)")

        // Security checks
        guard isPathValid(path) else {
            logger.warning("Invalid path rejected: \(path)")
            return nil
        }

        guard isSupportedFileType(path) else {
            logger.info("Unsupported file type: \(path)")
            return nil
        }

        // Read file content
        guard let content = readFileContent(from: path, maxLength: maxLength) else {
            return nil
        }

        logger.info("Successfully read \(content.count) characters from document")
        return content
    }

    // MARK: - Private Methods

    /// Validate path for security
    private func isPathValid(_ path: String) -> Bool {
        // Must be absolute path
        guard path.hasPrefix("/") else {
            logger.debug("Path is not absolute")
            return false
        }

        // Prevent path traversal
        guard !path.contains("..") else {
            logger.debug("Path contains path traversal")
            return false
        }

        // Check if file exists and is readable
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false

        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else {
            logger.debug("File does not exist: \(path)")
            return false
        }

        guard !isDirectory.boolValue else {
            logger.debug("Path is a directory, not a file")
            return false
        }

        guard fileManager.isReadableFile(atPath: path) else {
            logger.debug("File is not readable")
            return false
        }

        return true
    }

    /// Check if file type is supported
    private func isSupportedFileType(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension.lowercased()
        return supportedExtensions.contains(ext)
    }

    /// Read file content with size handling
    private func readFileContent(from path: String, maxLength: Int) -> String? {
        let fileManager = FileManager.default

        // Get file size
        guard let attributes = try? fileManager.attributesOfItem(atPath: path),
              let fileSize = attributes[.size] as? Int else {
            logger.warning("Cannot get file attributes")
            return nil
        }

        // Check file size limit
        guard fileSize <= maxFileSize else {
            logger.warning("File too large: \(fileSize) bytes (max: \(self.maxFileSize))")
            return nil
        }

        logger.debug("File size: \(fileSize) bytes")

        // Read content based on file size
        let content: String?
        if fileSize <= smallFileThreshold {
            // Small file: read entirely
            content = readEntireFile(from: path)
        } else {
            // Large file: read from end
            content = readFileFromEnd(from: path, maxBytes: maxLength * 4) // Account for multi-byte chars
        }

        guard let text = content else {
            return nil
        }

        // Truncate from beginning if needed (keep most recent content at end)
        if text.count > maxLength {
            let startIndex = text.index(text.endIndex, offsetBy: -maxLength)
            return String(text[startIndex...])
        }

        return text
    }

    /// Read entire file content
    private func readEntireFile(from path: String) -> String? {
        let url = URL(fileURLWithPath: path)

        // Try UTF-8 first
        if let content = try? String(contentsOf: url, encoding: .utf8) {
            return content
        }

        // Fallback to Latin1 (ISO-8859-1) which never fails
        if let content = try? String(contentsOf: url, encoding: .isoLatin1) {
            logger.debug("Read file using Latin1 encoding")
            return content
        }

        logger.warning("Failed to read file with any encoding")
        return nil
    }

    /// Read content from end of file
    private func readFileFromEnd(from path: String, maxBytes: Int) -> String? {
        guard let fileHandle = FileHandle(forReadingAtPath: path) else {
            logger.warning("Cannot open file handle")
            return nil
        }

        defer {
            try? fileHandle.close()
        }

        do {
            // Get file size
            let fileSize = try fileHandle.seekToEnd()

            // Calculate start position
            let bytesToRead = min(UInt64(maxBytes), fileSize)
            let startPosition = fileSize - bytesToRead

            // Seek to start position
            try fileHandle.seek(toOffset: startPosition)

            // Read data
            guard let data = try fileHandle.readToEnd() else {
                logger.warning("Failed to read file data")
                return nil
            }

            // Try UTF-8 first
            if let content = String(data: data, encoding: .utf8) {
                // If we started mid-file, find first complete line
                if startPosition > 0 {
                    if let newlineIndex = content.firstIndex(of: "\n") {
                        return String(content[content.index(after: newlineIndex)...])
                    }
                }
                return content
            }

            // Fallback to Latin1
            if let content = String(data: data, encoding: .isoLatin1) {
                logger.debug("Read file tail using Latin1 encoding")
                if startPosition > 0 {
                    if let newlineIndex = content.firstIndex(of: "\n") {
                        return String(content[content.index(after: newlineIndex)...])
                    }
                }
                return content
            }

            logger.warning("Failed to decode file data")
            return nil

        } catch {
            logger.error("Error reading file: \(error.localizedDescription)")
            return nil
        }
    }
}
