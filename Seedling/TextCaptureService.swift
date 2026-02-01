//
//  TextCaptureService.swift
//  Seedling
//
//  Text capture service using SelectedTextKit for improved cross-app text selection capture
//

import Foundation
import AppKit
import SelectedTextKit
import OSLog

/// Service for capturing selected text from other applications using SelectedTextKit
actor TextCaptureService {
    static let shared = TextCaptureService()

    private let textManager = SelectedTextManager.shared
    private let logger = Logger.accessibility

    private init() {}

    // MARK: - Permission Checking

    /// Check if accessibility permission is granted
    /// - Parameter prompt: If true, shows system prompt to request permission
    /// - Returns: true if permission is granted
    nonisolated func checkPermission(prompt: Bool = false) -> Bool {
        let options: [String: Any]
        if prompt {
            options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        } else {
            options = [:]
        }
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    // MARK: - Text Capture

    /// Capture selected text using multiple strategies
    func captureSelectedText() async -> CapturedTextContext? {
        let frontmostApp = NSWorkspace.shared.frontmostApplication
        let appName = frontmostApp?.localizedName ?? "Unknown"
        let bundleId = frontmostApp?.bundleIdentifier

        logger.debug("Attempting capture from: \(appName)")

        // Try multiple strategies in order of reliability
        let strategies: [TextStrategy] = [.accessibility, .menuAction, .appleScript, .shortcut]

        do {
            if let text = try await textManager.getSelectedText(strategies: strategies),
               !text.isEmpty {
                logger.info("Captured \(text.count) chars from \(appName)")
                return CapturedTextContext(
                    text: text,
                    documentPath: nil,
                    applicationName: appName,
                    bundleIdentifier: bundleId,
                    capturedAt: Date()
                )
            }
        } catch {
            logger.warning("SelectedTextKit capture failed: \(error.localizedDescription)")
        }

        logger.info("No text captured from \(appName)")
        return nil
    }

    /// Synchronous wrapper for use before window activation
    /// Uses semaphore to block until async capture completes
    ///
    /// IMPORTANT: This must be called BEFORE our window activates,
    /// as the frontmost app changes after window activation
    nonisolated func captureSelectedTextSync() -> CapturedTextContext? {
        // Check permission first
        guard checkPermission(prompt: false) else {
            return nil
        }

        let semaphore = DispatchSemaphore(value: 0)
        var result: CapturedTextContext?

        Task {
            result = await self.captureSelectedText()
            semaphore.signal()
        }

        // Wait with a reasonable timeout (2 seconds)
        let waitResult = semaphore.wait(timeout: .now() + 2.0)
        if waitResult == .timedOut {
            return nil
        }

        return result
    }
}
