# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

DoubaoVoice is a macOS application for real-time speech-to-text transcription using the Doubao (豆包) ASR API. It features a native SwiftUI interface and implements the Doubao binary WebSocket protocol for streaming audio transcription.

### Python Reference Implementation
The `reference.py` file contains a daemon implementation with HTTP API. This is reference code showing the protocol implementation but is NOT the primary application.

## Build & Run Commands

```bash
./build.sh          # Build only
./build_run.sh      # Build and run with logs in terminal
```

## Project Structure

```
DoubaoVoice/
├── DoubaoVoiceApp.swift          # App entry point
├── ContentView.swift             # Main UI
├── TranscriptionViewModel.swift  # View model coordinator
├── DoubaoASRClient.swift         # WebSocket ASR client
├── AudioRecorder.swift           # Audio capture
└── Utilities.swift               # Models, constants, extensions
reference.py                      # Python reference implementation (daemon)
```
