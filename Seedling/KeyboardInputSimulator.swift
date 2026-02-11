//
//  KeyboardInputSimulator.swift
//  Seedling
//
//  Simulates keyboard input to type text directly into the active application
//  using CGEvent-based keystroke simulation.
//

import Foundation
import CoreGraphics

// MARK: - Text Diff

struct TextDiff {
    let commonPrefixLength: Int
    let deleteCount: Int
    let insertText: String
}

/// Compute the minimal diff between old and new text
func computeDiff(old: String, new: String) -> TextDiff {
    // Find common prefix length (by Character)
    let oldChars = Array(old)
    let newChars = Array(new)
    var commonPrefix = 0
    let minLen = min(oldChars.count, newChars.count)

    while commonPrefix < minLen && oldChars[commonPrefix] == newChars[commonPrefix] {
        commonPrefix += 1
    }

    let deleteCount = oldChars.count - commonPrefix
    let insertText = String(newChars[commonPrefix...])

    return TextDiff(
        commonPrefixLength: commonPrefix,
        deleteCount: deleteCount,
        insertText: insertText
    )
}

// MARK: - Keyboard Input Simulator

@MainActor
class KeyboardInputSimulator {
    private var lastSentText: String = ""
    private var isProcessing = false
    private var pendingText: String?

    /// Reset the simulator state (call when starting a new session)
    func reset() {
        lastSentText = ""
        isProcessing = false
        pendingText = nil
    }

    /// Apply new text by computing diff and simulating keystrokes
    func applyText(_ newText: String) {
        // Always keep only the latest text
        pendingText = newText
        if !isProcessing {
            Task { @MainActor in
                await processPendingTexts()
            }
        }
    }

    private func processPendingTexts() async {
        isProcessing = true
        while let text = pendingText {
            pendingText = nil
            await processText(text)
        }
        isProcessing = false
    }

    /// Per-keystroke delay for typing animation (5ms)
    private let keystrokeDelay: UInt64 = 5_000_000

    private func processText(_ initialTarget: String) async {
        var target = initialTarget

        log(.debug, "KeyboardInput: animating towards \(target.count) chars")

        while true {
            let diff = computeDiff(old: lastSentText, new: target)

            // Nothing left to do — target reached
            if diff.deleteCount == 0 && diff.insertText.isEmpty {
                break
            }

            // One atomic step: prefer deleting first, then inserting
            if diff.deleteCount > 0 {
                simulateBackspaces(count: 1)
                lastSentText = String(lastSentText.dropLast())
            } else {
                let char = diff.insertText[diff.insertText.startIndex]
                simulateTextInsert(String(char))
                lastSentText.append(char)
            }

            // Absorb new pending text — adjust target, keep animating
            if let newTarget = pendingText {
                pendingText = nil
                target = newTarget
                log(.debug, "KeyboardInput: retargeting to \(target.count) chars")
            }

            // Delay before next step if there's more work
            let next = computeDiff(old: lastSentText, new: target)
            if next.deleteCount > 0 || !next.insertText.isEmpty {
                try? await Task.sleep(nanoseconds: keystrokeDelay)
            }
        }
    }

    // MARK: - CGEvent Simulation

    private func simulateBackspaces(count: Int) {
        let source = CGEventSource(stateID: .hidSystemState)
        let backspaceKeyCode: CGKeyCode = 51

        for _ in 0..<count {
            guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: backspaceKeyCode, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: source, virtualKey: backspaceKeyCode, keyDown: false) else {
                log(.error, "Failed to create backspace CGEvent")
                continue
            }
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
        }
    }

    private func simulateTextInsert(_ text: String) {
        let source = CGEventSource(stateID: .hidSystemState)
        let utf16 = Array(text.utf16)
        let chunkSize = 20 // CGEvent max Unicode string length

        var offset = 0
        while offset < utf16.count {
            let end = min(offset + chunkSize, utf16.count)
            let chunk = Array(utf16[offset..<end])

            guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                log(.error, "Failed to create text insert CGEvent")
                offset = end
                continue
            }

            // Only set Unicode string on keyDown — keyUp should be a plain release event
            chunk.withUnsafeBufferPointer { buffer in
                keyDown.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: buffer.baseAddress!)
            }

            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)

            offset = end
        }
    }
}
