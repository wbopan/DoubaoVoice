# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Seedling is a macOS application for real-time speech-to-text transcription using the Seed ASR API. It features a native SwiftUI interface and implements the Seed ASR binary WebSocket protocol for streaming audio transcription.

### Python Reference Implementation
The `REFERENCE.py` file contains a daemon implementation with HTTP API. This is reference code showing the protocol implementation but is NOT the primary application.

## Build Commands

```bash
./build.sh          # Build and see logs
```

## Project Structure

```
Seedling/
├── SeedlingApp.swift             # App entry point
├── ContentView.swift             # Main UI
├── TranscriptionViewModel.swift  # View model coordinator
├── ASRClient.swift               # WebSocket ASR client
├── AudioRecorder.swift           # Audio capture
└── Utilities.swift               # Models, constants, extensions
```

## Logging System

Use the global `log()` function defined in `Utilities.swift`. This outputs to stderr so logs appear in the terminal when running via `./run.sh`.

```swift
log(.debug, "Payload compressed: \(size) bytes")
log(.info, "Connecting to Seed ASR...")
log(.warning, "Connection retry attempt \(count)")
log(.error, "Failed to connect: \(error)")
```

**Log levels**:
- **`.debug`** - Detailed debugging information
- **`.info`** - Important state changes and milestones
- **`.warning`** - Potential issues that don't break functionality
- **`.error`** - Critical errors that prevent functionality

**Conventions**: Use plain text without emojis. Format as "Action/State: details". Keep messages concise and include relevant metrics.

## Creating Worktrees

To create an worktree, put the worktree in ./worktrees
