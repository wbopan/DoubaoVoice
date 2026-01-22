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

/// View model for managing transcription state and coordinating services
@MainActor
class TranscriptionViewModel: ObservableObject {
    // MARK: - Published Properties

    @Published var isRecording = false
    @Published var transcribedText = ""
    @Published var errorMessage: String?
    @Published var statusMessage = "Ready"

    // MARK: - Private Properties

    private let audioRecorder = AudioRecorder()
    private let asrClient = DoubaoASRClient()
    private var recordingStartTime: Date?

    // ASR Configuration (using credentials from reference.py)
    private let asrConfig = ASRConfig(
        appKey: "3254061168",
        accessKey: "1jFY86tc4aNrg-8K69dIM43HSjJ_jhyb",
        resourceID: DoubaoConstants.resourceID,
        enableVAD: true,
        language: "zh-CN"
    )

    // MARK: - Public Methods

    /// Start recording and transcription
    func startRecording() {
        Task {
            do {
                // Request microphone permission
                let granted = await requestMicrophonePermission()
                guard granted else {
                    errorMessage = "Microphone permission denied. Please enable it in Settings."
                    return
                }

                // Clear previous state
                transcribedText = ""
                errorMessage = nil
                statusMessage = "Connecting..."
                recordingStartTime = Date()

                log(.info, "Starting transcription session...")

                // Connect to ASR service
                try await asrClient.connect(config: asrConfig)
                statusMessage = "Connected"

                // Start listening to ASR results
                Task {
                    await listenToASRResults()
                }

                // Start audio recording
                try await audioRecorder.startRecording { [weak self] audioData in
                    Task {
                        await self?.sendAudioToASR(audioData)
                    }
                }

                isRecording = true
                statusMessage = "Recording..."
                log(.info, "Transcription session started")

            } catch {
                errorMessage = "Failed to start recording: \(error.localizedDescription)"
                statusMessage = "Error"
                isRecording = false
                log(.error, "Start recording error: \(error)")
            }
        }
    }

    /// Stop recording and wait for final transcription
    func stopRecording() {
        Task {
            guard isRecording else { return }

            log(.info, "Stopping transcription session...")
            statusMessage = "Stopping..."
            isRecording = false

            // Stop audio recording
            await audioRecorder.stopRecording()

            // Send final packet to ASR
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
        }
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
                // For real-time updates, append new text
                if transcribedText.isEmpty {
                    transcribedText = result.text
                } else {
                    // Replace or append based on whether it's a final result
                    if result.isLastPackage {
                        transcribedText = result.text
                    } else {
                        // For interim results, just replace with the latest
                        transcribedText = result.text
                    }
                }

                log(.debug, "Updated text: [\(result.text)] final:\(result.isLastPackage)")
            }

            // Update status for final result
            if result.isLastPackage {
                log(.info, "Received final transcription result")
            }
        }
    }
}
