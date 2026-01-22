# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

DoubaoVoice is a macOS application for real-time speech-to-text transcription using the Doubao (豆包) ASR API. It features a native SwiftUI interface and implements the Doubao binary WebSocket protocol for streaming audio transcription.

### Python Reference Implementation
The `REFERENCE.py` file contains a daemon implementation with HTTP API. This is reference code showing the protocol implementation but is NOT the primary application.

## Build & Run Commands

```bash
./build.sh          # Build only
./run.sh      # Build and run with logs in terminal
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
```

## Logging System

The application uses Apple's unified logging system (OSLog/Logger API) for debug output and diagnostics. Actively use debug logs.

- **`.debug`** - Detailed debugging information (verbose, only in DEBUG builds)
- **`.info`** - Important state changes and milestones
- **`.warning`** - Potential issues that don't break functionality
- **`.error`** - Critical errors that prevent functionality

```swift
// Basic logging (uses general category)
log(.info, "Starting transcription session...")
log(.error, "Failed to connect: \(error)")
log(.debug, "Audio buffer size: \(bufferSize) bytes")

// Category-specific logging (recommended for new code)
import OSLog
private let logger = Logger.asr

logger.info("Connecting to Doubao ASR...")
logger.debug("Payload compressed: \(size) bytes")
```

## Creating Worktrees

To create an worktree, put the worktree in ./worktrees and use `builtin cd` into it. 