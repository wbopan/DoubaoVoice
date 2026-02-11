//
//  AudioRecorder.swift
//  Seedling
//
//  Audio capture service for real-time transcription
//

import AVFoundation
import Foundation
import CoreAudio
import Accelerate

/// Audio recorder for capturing microphone input and streaming to ASR
actor AudioRecorder {
    // MARK: - Properties

    private var audioEngine: AVAudioEngine?
    private var audioConverter: AVAudioConverter?
    private var isRecording = false
    private var audioCallback: ((Data) -> Void)?
    private var audioLevelCallback: (([Float]) -> Void)?
    private var segmentBuffer = Data()

    // FFT properties for frequency band analysis
    private let fftSize = 2048
    private let fftLog2n: vDSP_Length = 11  // log2(2048)
    private var fftSetup: FFTSetup?
    private var hanningWindow: [Float] = []
    // Per-band adaptive noise floor (tracks ambient noise level)
    private var noiseFloor: [Float] = [Float](repeating: 0, count: 5)
    // Reusable FFT buffers (avoid per-frame allocation)
    private var fftInputBuffer: [Float] = []
    private var fftRealBuffer: [Float] = []
    private var fftImagBuffer: [Float] = []
    private var fftMagnitudes: [Float] = []

    /// Audio processing Task to prevent Task explosion
    private var processingTask: Task<Void, Never>?
    /// Audio buffer channel for backpressure control
    private var audioBufferChannel: AsyncStream<AVAudioPCMBuffer>.Continuation?

    // Target audio format: 16kHz, 16-bit, mono PCM
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: ASRConstants.sampleRate,
        channels: ASRConstants.channels,
        interleaved: true
    )!

    // MARK: - Lifecycle

    /// Start recording audio
    /// - Parameters:
    ///   - callback: Called with audio data segments
    ///   - levelCallback: Called with audio level for visualization
    ///   - selectedMicrophoneUID: UID of the selected microphone (empty for system default)
    func startRecording(
        callback: @escaping (Data) -> Void,
        levelCallback: (([Float]) -> Void)? = nil,
        selectedMicrophoneUID: String = ""
    ) throws {
        guard !isRecording else {
            log(.warning, "Already recording")
            return
        }

        log(.info, "Starting audio recording...")

        self.audioCallback = callback
        self.audioLevelCallback = levelCallback
        self.segmentBuffer.removeAll()

        // Initialize FFT
        let halfSize = fftSize / 2
        fftSetup = vDSP_create_fftsetup(fftLog2n, FFTRadix(kFFTRadix2))
        hanningWindow = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&hanningWindow, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        noiseFloor = [Float](repeating: 0, count: 5)
        // Pre-allocate reusable buffers
        fftInputBuffer = [Float](repeating: 0, count: fftSize)
        fftRealBuffer = [Float](repeating: 0, count: halfSize)
        fftImagBuffer = [Float](repeating: 0, count: halfSize)
        fftMagnitudes = [Float](repeating: 0, count: halfSize)

        // Create audio engine
        let engine = AVAudioEngine()
        self.audioEngine = engine

        // Apply selected microphone device before accessing inputNode
        if !selectedMicrophoneUID.isEmpty,
           let deviceID = AudioDeviceManager.lookupDeviceID(forUID: selectedMicrophoneUID) {
            var deviceIDVar = deviceID
            let status = AudioUnitSetProperty(
                engine.inputNode.audioUnit!,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &deviceIDVar,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            if status == noErr {
                log(.info, "Using microphone: \(selectedMicrophoneUID)")
            } else {
                log(.warning, "Failed to set microphone device (status: \(status)), using system default")
            }
        } else {
            log(.info, "Using system default microphone")
        }

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
        let bufferSize = AVAudioFrameCount(inputFormat.sampleRate * ASRConstants.segmentDuration)

        // Create AsyncStream with backpressure control to prevent Task explosion
        // bufferingNewest(5) keeps only the latest 5 buffers, preventing memory buildup
        let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream(
            bufferingPolicy: .bufferingNewest(5)
        )
        self.audioBufferChannel = continuation

        // Start a single processing Task instead of creating one per callback
        processingTask = Task { [weak self] in
            for await buffer in stream {
                guard let self = self else { break }
                guard await self.isRecording else { break }
                await self.processAudioBuffer(buffer)
            }
        }

        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) { [weak self] buffer, _ in
            // Use yield instead of creating a new Task - this is non-blocking
            // If buffer is full, bufferingNewest policy will drop oldest data
            self?.audioBufferChannel?.yield(buffer)
        }

        // Prepare and start engine
        engine.prepare()
        try engine.start()

        isRecording = true
        log(.info, "Audio recording started")
    }

    /// Stop recording audio
    func stopRecording() {
        guard isRecording else {
            log(.info, "Audio recorder already stopped")
            return
        }

        log(.info, "Stopping audio recording...")

        isRecording = false

        // Stop the audio buffer channel and processing task
        audioBufferChannel?.finish()
        audioBufferChannel = nil
        processingTask?.cancel()
        processingTask = nil

        // Stop engine and remove tap
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        audioConverter = nil

        // Send any remaining buffered data
        if !segmentBuffer.isEmpty {
            log(.info, "Flushing final buffer: \(segmentBuffer.count) bytes")
            audioCallback?(segmentBuffer)
            segmentBuffer.removeAll()
        }

        audioCallback = nil
        audioLevelCallback = nil

        // Clean up FFT
        if let setup = fftSetup {
            vDSP_destroy_fftsetup(setup)
            fftSetup = nil
        }
        hanningWindow = []
        fftInputBuffer = []
        fftRealBuffer = []
        fftImagBuffer = []
        fftMagnitudes = []

        log(.info, "Audio recording stopped")
    }

    // MARK: - Private Methods

    /// Compute 5 frequency band levels from PCM samples using real FFT (vDSP_fft_zrip)
    /// Returns normalized levels [0..1] for speech-focused frequency bands
    private func computeFrequencyBands(_ samples: UnsafeMutablePointer<Int16>, frameCount: Int) -> [Float] {
        let bandCount = 5
        let halfSize = fftSize / 2
        guard let setup = fftSetup, frameCount >= fftSize else {
            return [Float](repeating: 0, count: bandCount)
        }

        // Convert Int16 -> Float using vDSP (vectorized, ~10x faster than Swift loop)
        vDSP_vflt16(samples, 1, &fftInputBuffer, 1, vDSP_Length(fftSize))
        var divisor = Float(Int16.max)
        vDSP_vsdiv(fftInputBuffer, 1, &divisor, &fftInputBuffer, 1, vDSP_Length(fftSize))

        // Apply Hanning window
        vDSP_vmul(fftInputBuffer, 1, hanningWindow, 1, &fftInputBuffer, 1, vDSP_Length(fftSize))

        // Pack real data into split complex format for vDSP_fft_zrip
        // zrip interprets the input as interleaved: [real[0], imag[0], real[1], imag[1], ...]
        fftInputBuffer.withUnsafeMutableBufferPointer { buf in
            var splitComplex = DSPSplitComplex(
                realp: buf.baseAddress!,
                imagp: buf.baseAddress! + 1
            )
            vDSP_ctoz(
                UnsafePointer<DSPComplex>(OpaquePointer(buf.baseAddress!)),
                2,
                &splitComplex,
                1,
                vDSP_Length(halfSize)
            )
        }

        // Execute real-to-complex FFT in-place using split complex layout
        fftRealBuffer.withUnsafeMutableBufferPointer { realBuf in
            fftImagBuffer.withUnsafeMutableBufferPointer { imagBuf in
                // Copy packed data into split buffers
                fftInputBuffer.withUnsafeBufferPointer { inputBuf in
                    for i in 0..<halfSize {
                        realBuf[i] = inputBuf[2 * i]
                        imagBuf[i] = inputBuf[2 * i + 1]
                    }
                }

                var splitComplex = DSPSplitComplex(realp: realBuf.baseAddress!, imagp: imagBuf.baseAddress!)
                vDSP_fft_zrip(setup, &splitComplex, 1, fftLog2n, FFTDirection(FFT_FORWARD))

                // Compute magnitudes squared into reusable buffer
                vDSP_zvmags(&splitComplex, 1, &fftMagnitudes, 1, vDSP_Length(halfSize))
            }
        }

        // 5 speech-focused frequency bands for 16kHz sample rate
        // Bin resolution = 16000/2048 ≈ 7.8125 Hz/bin
        // Human speech energy is concentrated in 85-3500 Hz
        // Band 0: 85-250 Hz   (bins 11-32)   - Fundamental frequency (F0)
        // Band 1: 250-500 Hz  (bins 32-64)   - First formant (F1), vowel openness
        // Band 2: 500-1200 Hz (bins 64-154)  - F1/F2 crossover, vowel identity
        // Band 3: 1200-3000 Hz (bins 154-384) - F2/F3, consonant clarity
        // Band 4: 3000-8000 Hz (bins 384-1024) - Fricatives, sibilants (s/f/sh)
        let bandRanges: [(Int, Int)] = [
            (11, 32), (32, 64), (64, 154), (154, 384), (384, min(halfSize, 1024))
        ]

        // Dynamic range above noise floor for normalization
        let dynamicRangeDB: Float = 18.0

        var levels = [Float](repeating: 0, count: bandCount)
        fftMagnitudes.withUnsafeBufferPointer { buf in
            for (i, range) in bandRanges.enumerated() {
                let lo = min(range.0, halfSize)
                let hi = min(range.1, halfSize)
                guard hi > lo else { continue }

                // Average magnitude in this band
                var sum: Float = 0
                vDSP_sve(buf.baseAddress! + lo, 1, &sum, vDSP_Length(hi - lo))
                let avgMag = sum / Float(hi - lo)

                // Convert to dB
                let db = 10.0 * log10f(max(avgMag, 1e-10))

                // Adaptive noise floor tracking per band:
                // - Downward: fast exponential tracking (settles in ~5 frames)
                //   Avoids locking to transient minimums unlike instant snap-down
                // - Upward within 10dB: slow tracking for ambient drift
                // - Upward >10dB: speech energy, don't update floor
                let delta = db - noiseFloor[i]
                if delta < 0 {
                    noiseFloor[i] += delta * 0.3
                } else if delta < 10.0 {
                    noiseFloor[i] += delta * 0.02
                }

                // Normalize: only show energy above noise floor + margin
                // 6dB margin absorbs normal ambient noise fluctuation
                let aboveNoise = db - (noiseFloor[i] + 6.0)
                levels[i] = max(0, min(1, aboveNoise / dynamicRangeDB))
            }
        }

        return levels
    }

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

        // Compute frequency bands via FFT for waveform visualization
        let bands = computeFrequencyBands(channelData[0], frameCount: frameLength)

        if let levelCallback = audioLevelCallback {
            Task { @MainActor in
                levelCallback(bands)
            }
        }

        let data = Data(bytes: channelData[0], count: frameLength * ASRConstants.bytesPerSample)

        // Add to segment buffer
        segmentBuffer.append(data)

        // Send complete segments
        while segmentBuffer.count >= ASRConstants.segmentByteSize {
            let segment = segmentBuffer.prefix(ASRConstants.segmentByteSize)
            audioCallback?(segment)
            segmentBuffer.removeFirst(ASRConstants.segmentByteSize)

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
