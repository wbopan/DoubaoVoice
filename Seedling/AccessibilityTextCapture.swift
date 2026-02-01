//
//  AccessibilityTextCapture.swift
//  Seedling
//
//  Captures text content from other applications using macOS Accessibility API
//

import Foundation
import AppKit
import ApplicationServices
import OSLog

// MARK: - Captured Text Context

/// Holds captured text and metadata from another application
struct CapturedTextContext: Sendable {
    /// The captured text content
    let text: String

    /// Document path if available (e.g., from editors)
    let documentPath: String?

    /// Name of the source application
    let applicationName: String

    /// Bundle identifier of the source application
    let bundleIdentifier: String?

    /// Timestamp when the context was captured
    let capturedAt: Date

    /// Whether any text was actually captured
    var hasContent: Bool {
        !text.isEmpty
    }

    /// Truncate text to a maximum length
    func truncated(to maxLength: Int) -> CapturedTextContext {
        guard text.count > maxLength else { return self }

        let truncatedText = String(text.prefix(maxLength))
        return CapturedTextContext(
            text: truncatedText,
            documentPath: documentPath,
            applicationName: applicationName,
            bundleIdentifier: bundleIdentifier,
            capturedAt: capturedAt
        )
    }
}

// MARK: - Accessibility Text Capture

/// Service for capturing text from other applications via Accessibility API
class AccessibilityTextCapture {
    static let shared = AccessibilityTextCapture()

    private let logger = Logger.accessibility

    private init() {}

    // MARK: - Permission Checking

    /// Check if accessibility permission is granted
    /// - Parameter prompt: If true, shows system prompt to request permission
    /// - Returns: true if permission is granted
    func checkPermission(prompt: Bool = false) -> Bool {
        let options: [String: Any]
        if prompt {
            options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        } else {
            options = [:]
        }
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    // MARK: - Text Capture

    /// Capture text from the currently focused application
    /// - Returns: CapturedTextContext with the captured text, or nil if capture failed
    func captureFromFocusedApp() -> CapturedTextContext? {
        logger.info("Starting text capture from focused app")

        // Check permission first
        guard checkPermission(prompt: false) else {
            logger.warning("Accessibility permission not granted")
            return nil
        }

        // Get system-wide accessibility element
        let systemWide = AXUIElementCreateSystemWide()

        // Get focused application
        var focusedAppRef: CFTypeRef?
        let appResult = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedApplicationAttribute as CFString,
            &focusedAppRef
        )

        guard appResult == .success,
              let focusedApp = focusedAppRef else {
            logger.warning("Failed to get focused application: \(appResult.rawValue)")
            return nil
        }

        let appElement = focusedApp as! AXUIElement

        // Get application info
        let appInfo = getApplicationInfo(from: appElement)
        logger.info("Capturing from: \(appInfo.name) (\(appInfo.bundleID ?? "unknown"))")

        // Try to get text content
        let text = captureText(from: appElement)

        // Try to get document path
        let documentPath = getDocumentPath(from: appElement)

        // Fallback to file content if text capture is minimal
        var finalText = text
        if text.isEmpty || text.count < 10 {
            if let path = documentPath {
                logger.info("Text capture minimal (\(text.count) chars), attempting file fallback: \(path)")

                // Synchronous read since this method is synchronous
                let semaphore = DispatchSemaphore(value: 0)
                var fileContent: String?
                Task {
                    fileContent = await DocumentContentReader.shared.readContent(
                        from: path,
                        maxLength: AppSettings.shared.maxContextLength
                    )
                    semaphore.signal()
                }
                semaphore.wait()

                if let content = fileContent {
                    logger.info("File fallback success: \(content.count) chars from \(path)")
                    finalText = content
                } else {
                    logger.info("File fallback failed for: \(path)")
                }
            }
        }

        if finalText.isEmpty {
            logger.info("No text captured from \(appInfo.name)")
            return nil
        }

        logger.info("Captured \(finalText.count) characters from \(appInfo.name)")

        return CapturedTextContext(
            text: finalText,
            documentPath: documentPath,
            applicationName: appInfo.name,
            bundleIdentifier: appInfo.bundleID,
            capturedAt: Date()
        )
    }

    // MARK: - Private Methods

    /// Get application name and bundle identifier
    private func getApplicationInfo(from appElement: AXUIElement) -> (name: String, bundleID: String?) {
        var titleRef: CFTypeRef?
        var name = "Unknown"

        if AXUIElementCopyAttributeValue(appElement, kAXTitleAttribute as CFString, &titleRef) == .success,
           let title = titleRef as? String {
            name = title
        }

        // Try to get bundle identifier from PID
        var pid: pid_t = 0
        if AXUIElementGetPid(appElement, &pid) == .success {
            if let app = NSRunningApplication(processIdentifier: pid) {
                if let bundleID = app.bundleIdentifier {
                    return (app.localizedName ?? name, bundleID)
                }
            }
        }

        return (name, nil)
    }

    /// Capture text from the focused element or window
    private func captureText(from appElement: AXUIElement) -> String {
        // First, try to get focused UI element
        var focusedElementRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElementRef
        ) == .success {
            let focusedElement = focusedElementRef as! AXUIElement

            // Try to get value from focused element (works for text fields, editors)
            if let text = getTextValue(from: focusedElement) {
                logger.debug("Got text from focused element")
                return text
            }

            // Try to get selected text
            if let selectedText = getSelectedText(from: focusedElement), !selectedText.isEmpty {
                logger.debug("Got selected text from focused element")
                return selectedText
            }
        }

        // If no focused element text, try to get text from the focused window
        var windowRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &windowRef
        ) == .success {
            let windowElement = windowRef as! AXUIElement

            // Try to find text areas in the window
            if let text = findTextInChildren(of: windowElement, maxDepth: 5) {
                logger.debug("Got text from window children")
                return text
            }
        }

        return ""
    }

    /// Get text value from an element
    private func getTextValue(from element: AXUIElement) -> String? {
        var valueRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
           let value = valueRef as? String {
            return value
        }
        return nil
    }

    /// Get selected text from an element
    private func getSelectedText(from element: AXUIElement) -> String? {
        var selectedTextRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selectedTextRef) == .success,
           let selectedText = selectedTextRef as? String {
            return selectedText
        }
        return nil
    }

    /// Recursively search for text content in child elements
    private func findTextInChildren(of element: AXUIElement, maxDepth: Int) -> String? {
        guard maxDepth > 0 else { return nil }

        // Try to get value from this element
        if let text = getTextValue(from: element), !text.isEmpty {
            return text
        }

        // Get children
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else {
            return nil
        }

        // Search children for text content
        for child in children {
            // Check role to prioritize text areas
            var roleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleRef) == .success,
               let role = roleRef as? String {

                // Prioritize text-related roles
                if role == kAXTextAreaRole as String ||
                   role == kAXTextFieldRole as String ||
                   role == kAXStaticTextRole as String {
                    if let text = getTextValue(from: child), !text.isEmpty {
                        return text
                    }
                }
            }

            // Recursively search
            if let text = findTextInChildren(of: child, maxDepth: maxDepth - 1) {
                return text
            }
        }

        return nil
    }

    /// Get document path from the application
    private func getDocumentPath(from appElement: AXUIElement) -> String? {
        // Try focused window first
        var windowRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &windowRef
        ) == .success {
            let windowElement = windowRef as! AXUIElement

            // Try document attribute
            var documentRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(windowElement, kAXDocumentAttribute as CFString, &documentRef) == .success,
               let document = documentRef as? String {
                // Convert file:// URL to path
                if document.hasPrefix("file://") {
                    return URL(string: document)?.path
                }
                return document
            }
        }

        return nil
    }
}
