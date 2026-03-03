# Pre-connection Audio Buffering

## Problem

Recording only starts after WebSocket connection is established, losing the first few seconds of speech.

## Solution

Start audio recording and WebSocket connection in parallel. Buffer audio data during connection, flush once connected.

## Approach: Buffer in TranscriptionViewModel

### New properties

- `preConnectionAudioBuffer: [Data]` — stores audio segments before connection
- `isASRConnected: Bool` — tracks ASR connection state

### Buffer cap

5 seconds max (160,000 bytes at 16kHz/16-bit/mono). Oldest data discarded when exceeded.

### State flow

```
press record → connecting (audio buffering) → connected → flush buffer → recording (streaming)
```

### Changes

Only `TranscriptionViewModel.swift` is modified:

1. `startRecording()` — start audio and ASR connection concurrently
2. `sendAudioToASR()` — buffer when not connected, send when connected
3. New `flushAudioBuffer()` — send buffered data after connection

### Error handling

- Connection failure: discard buffer, stop recording
- User cancellation: discard buffer, normal cleanup
