//
//  AudioRecorder.swift
//  DoubaoVoice
//
//  Audio capture service for real-time transcription
//

import AVFoundation
import Foundation

/// Audio recorder for capturing microphone input and streaming to ASR
actor AudioRecorder {
    // MARK: - Properties

    private var audioEngine: AVAudioEngine?
    private var audioConverter: AVAudioConverter?
    private var isRecording = false
    private var audioCallback: ((Data) -> Void)?
    private var segmentBuffer = Data()

    // Target audio format: 16kHz, 16-bit, mono PCM
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: DoubaoConstants.sampleRate,
        channels: DoubaoConstants.channels,
        interleaved: true
    )!

    // MARK: - Lifecycle

    /// Start recording audio
    func startRecording(callback: @escaping (Data) -> Void) throws {
        guard !isRecording else {
            log(.warning, "Already recording")
            return
        }

        log(.info, "Starting audio recording...")

        self.audioCallback = callback
        self.segmentBuffer.removeAll()

        // Create audio engine
        let engine = AVAudioEngine()
        self.audioEngine = engine

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        log(.info, "Input format: \(inputFormat.sampleRate)Hz, \(inputFormat.channelCount)ch")
        log(.info, "Target format: \(targetFormat.sampleRate)Hz, \(targetFormat.channelCount)ch")

        // Create converter if sample rates don't match
        if inputFormat.sampleRate != targetFormat.sampleRate {
            guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
                throw AudioRecorderError.conversionFailed
            }
            self.audioConverter = converter
            log(.info, "Audio converter created: \(inputFormat.sampleRate)Hz → \(targetFormat.sampleRate)Hz")
        } else {
            self.audioConverter = nil
            log(.info, "No conversion needed")
        }

        // Install tap on input node
        let bufferSize = AVAudioFrameCount(inputFormat.sampleRate * DoubaoConstants.segmentDuration)

        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) { [weak self] buffer, time in
            Task {
                await self?.processAudioBuffer(buffer)
            }
        }

        // Prepare and start engine
        engine.prepare()
        try engine.start()

        isRecording = true
        log(.info, "Audio recording started")
    }

    /// Stop recording audio
    func stopRecording() {
        guard isRecording else { return }

        log(.info, "Stopping audio recording...")

        isRecording = false

        // Stop engine and remove tap
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        audioConverter = nil

        // Send any remaining buffered data
        if !segmentBuffer.isEmpty {
            log(.debug, "Flushing final buffer: \(segmentBuffer.count) bytes")
            audioCallback?(segmentBuffer)
            segmentBuffer.removeAll()
        }

        audioCallback = nil
        log(.info, "Audio recording stopped")
    }

    // MARK: - Private Methods

    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard isRecording else { return }

        // Convert audio if needed
        let convertedBuffer: AVAudioPCMBuffer
        if let converter = audioConverter {
            guard let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: AVAudioFrameCount(
                    Double(buffer.frameLength) * targetFormat.sampleRate / buffer.format.sampleRate
                )
            ) else {
                log(.error, "Failed to create output buffer")
                return
            }

            var error: NSError?
            let inputBlock: AVAudioConverterInputBlock = { inNumPackets, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }

            converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)

            if let error = error {
                log(.error, "Audio conversion error: \(error)")
                return
            }

            convertedBuffer = outputBuffer
        } else {
            convertedBuffer = buffer
        }

        // Convert buffer to Data (16-bit PCM)
        guard let channelData = convertedBuffer.int16ChannelData else {
            log(.error, "Failed to get channel data")
            return
        }

        let frameLength = Int(convertedBuffer.frameLength)
        let data = Data(bytes: channelData[0], count: frameLength * DoubaoConstants.bytesPerSample)

        // Add to segment buffer
        segmentBuffer.append(data)

        // Send complete segments
        while segmentBuffer.count >= DoubaoConstants.segmentByteSize {
            let segment = segmentBuffer.prefix(DoubaoConstants.segmentByteSize)
            audioCallback?(segment)
            segmentBuffer.removeFirst(DoubaoConstants.segmentByteSize)

            log(.debug, "Sent audio segment: \(segment.count) bytes")
        }
    }
}

// MARK: - Error Types

enum AudioRecorderError: Error, LocalizedError {
    case conversionFailed
    case recordingFailed
    case notRecording

    var errorDescription: String? {
        switch self {
        case .conversionFailed:
            return "Failed to create audio converter"
        case .recordingFailed:
            return "Failed to start recording"
        case .notRecording:
            return "Not currently recording"
        }
    }
}
