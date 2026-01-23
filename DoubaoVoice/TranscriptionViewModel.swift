//
//  TranscriptionViewModel.swift
//  DoubaoVoice
//
//  View model coordinating recording and transcription
//

import Foundation
import SwiftUI
import AVFoundation
import Combine
import AppKit  // For NSPasteboard

/// View model for managing transcription state and coordinating services
@MainActor
class TranscriptionViewModel: ObservableObject {
    // MARK: - Singleton

    static let shared = TranscriptionViewModel()

    // MARK: - Published Properties

    @Published var transcribedText = ""
    @Published var errorMessage: String?
    @Published var statusMessage = "Ready"

    // MARK: - Private Properties

    /// Recording lifecycle state
    private enum RecordingState {
        case idle           // Not recording
        case connecting     // ASR connection in progress
        case recording      // Fully recording (both ASR + audio)
        case stopping       // Cleanup in progress
    }

    private var recordingState: RecordingState = .idle
    private var recordingTask: Task<Void, Never>?

    private let audioRecorder = AudioRecorder()
    private let asrClient = DoubaoASRClient()
    private var recordingStartTime: Date?
    private var currentConfig: ASRConfig?

    /// Computed property for backward compatibility
    var isRecording: Bool {
        recordingState == .recording || recordingState == .connecting
    }

    /// Check if we're in the connecting phase
    var isConnecting: Bool {
        recordingState == .connecting
    }

    // MARK: - Initialization

    private init() {
        // Private initializer for singleton
        updateConfig(settings: AppSettings.shared)
    }

    // MARK: - Public Methods

    /// Update ASR configuration from settings
    func updateConfig(settings: AppSettings) {
        currentConfig = ASRConfig(
            appKey: settings.appKey,
            accessKey: settings.accessKey,
            resourceID: settings.resourceID,
            enableVAD: settings.enableVAD,
            language: "zh-CN"
        )
    }

    /// Start recording and transcription
    func startRecording() {
        // Cancel any existing recording task
        recordingTask?.cancel()

        // Set connecting state IMMEDIATELY (before any async work)
        recordingState = .connecting

        // Clear previous state
        transcribedText = ""
        errorMessage = nil
        statusMessage = "Connecting..."
        recordingStartTime = Date()

        // Store Task reference for cancellation
        recordingTask = Task {
            do {
                // Check for cancellation before starting
                try Task.checkCancellation()

                // Ensure we have a valid config
                guard let config = currentConfig else {
                    errorMessage = "ASR configuration not set. Please check Settings."
                    await performCleanup()
                    recordingState = .idle
                    return
                }

                // Request microphone permission
                let granted = await requestMicrophonePermission()
                guard granted else {
                    errorMessage = "Microphone permission denied. Please enable it in Settings."
                    await performCleanup()
                    recordingState = .idle
                    return
                }

                log(.info, "Starting transcription session...")

                // Check for cancellation before connecting
                try Task.checkCancellation()

                // Connect to ASR service
                try await asrClient.connect(config: config)
                statusMessage = "Connected"

                // Check for cancellation after connecting
                try Task.checkCancellation()

                // Start listening to ASR results
                Task {
                    await listenToASRResults()
                }

                // Check for cancellation before starting audio
                try Task.checkCancellation()

                // Start audio recording
                try await audioRecorder.startRecording { [weak self] audioData in
                    Task {
                        await self?.sendAudioToASR(audioData)
                    }
                }

                // Only set .recording after audio actually starts
                recordingState = .recording
                statusMessage = "Recording..."
                log(.info, "Transcription session started")

            } catch is CancellationError {
                // User-initiated cancellation - silent cleanup, no error message
                log(.info, "Recording start cancelled by user")
                await performCleanup()
                recordingState = .idle
                statusMessage = "Ready"
            } catch {
                // Actual errors - show error message
                errorMessage = "Failed to start recording: \(error.localizedDescription)"
                statusMessage = "Error"
                log(.error, "Start recording error: \(error)")
                await performCleanup()
                recordingState = .idle
            }
        }
    }

    /// Stop recording and wait for final transcription
    func stopRecording() {
        Task {
            // Prevent re-entry
            guard recordingState != .stopping && recordingState != .idle else {
                log(.debug, "stopRecording() called but already stopping or idle")
                return
            }

            let previousState = recordingState
            recordingState = .stopping
            statusMessage = "Stopping..."

            log(.info, "Stopping transcription session (previous state: \(previousState))...")

            // Cancel recording task if still running
            recordingTask?.cancel()
            recordingTask = nil

            // ALWAYS stop audio recording, regardless of state
            await audioRecorder.stopRecording()

            // Handle ASR cleanup based on previous state
            if previousState == .recording {
                // Full recording was active - send final packet and wait for result
                do {
                    try await asrClient.sendFinalPacket()

                    // Wait for final result
                    statusMessage = "Processing..."
                    _ = await asrClient.waitForFinalResult()

                    // Disconnect
                    await asrClient.disconnect()

                    // Calculate duration
                    if let startTime = recordingStartTime {
                        let duration = Date().timeIntervalSince(startTime)
                        statusMessage = "Completed (\(String(format: "%.1f", duration))s)"
                    } else {
                        statusMessage = "Completed"
                    }

                    log(.info, "Transcription session stopped")

                } catch {
                    errorMessage = "Failed to stop recording: \(error.localizedDescription)"
                    statusMessage = "Error"
                    log(.error, "Stop recording error: \(error)")
                }
            } else if previousState == .connecting {
                // Still connecting - just disconnect without sending final packet
                log(.info, "Stopping during connection phase - disconnecting only")
                await asrClient.disconnect()
                statusMessage = "Ready"
            }

            recordingState = .idle
        }
    }

    /// Finish recording, wait for final result, and copy to clipboard
    func finishRecordingAndCopy() async -> Bool {
        guard recordingState == .recording else { return false }

        log(.info, "Finishing transcription with copy to clipboard...")
        statusMessage = "Finishing..."

        // Stop recording (reuse existing logic)
        await stopRecording()

        // Copy to clipboard if we have text
        guard !transcribedText.isEmpty else {
            log(.warning, "No text to copy to clipboard")
            return false
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let success = pasteboard.setString(transcribedText, forType: .string)

        if success {
            log(.info, "Transcribed text copied to clipboard (\(transcribedText.count) chars)")
            statusMessage = "Copied to clipboard"
        } else {
            log(.error, "Failed to copy text to clipboard")
            errorMessage = "Failed to copy to clipboard"
        }

        return success
    }

    /// Toggle recording state
    func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    // MARK: - Private Methods

    /// Request microphone permission
    private func requestMicrophonePermission() async -> Bool {
        return await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    /// Cleanup helper - stops audio and disconnects ASR
    private func performCleanup() async {
        await audioRecorder.stopRecording()
        await asrClient.disconnect()
    }

    /// Send audio data to ASR service
    private func sendAudioToASR(_ audioData: Data) async {
        guard isRecording else { return }

        do {
            try await asrClient.sendAudioData(audioData)
        } catch {
            log(.error, "Failed to send audio: \(error)")
            errorMessage = "Audio streaming error: \(error.localizedDescription)"
        }
    }

    /// Listen to ASR results and update UI
    private func listenToASRResults() async {
        for await result in await asrClient.resultStream() {
            // Check for errors
            if !result.isSuccess {
                errorMessage = "ASR error (\(result.code)): \(result.message)"
                log(.error, "ASR error - code:\(result.code) message:\(result.message)")
                continue
            }

            // Update transcribed text
            if result.text.isNotEmpty {
                // Apply post-processing
                var processedText = result.text
                if AppSettings.shared.removeTrailingPunctuation {
                    processedText = processedText.removingTrailingPunctuation()
                    log(.debug, "Applied punctuation removal: '\(result.text)' -> '\(processedText)'")
                }

                // For real-time updates, append new text
                if transcribedText.isEmpty {
                    transcribedText = processedText
                } else {
                    // Replace or append based on whether it's a final result
                    if result.isLastPackage {
                        transcribedText = processedText
                    } else {
                        // For interim results, just replace with the latest
                        transcribedText = processedText
                    }
                }

                log(.debug, "Updated text: [\(processedText)] final:\(result.isLastPackage)")
            }

            // Update status for final result
            if result.isLastPackage {
                log(.info, "Received final transcription result")
            }
        }
    }
}
