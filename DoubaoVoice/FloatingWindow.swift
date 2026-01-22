//
//  FloatingWindow.swift
//  DoubaoVoice
//
//  Floating transcription window with auto-start recording
//

import Cocoa
import SwiftUI
import OSLog

// MARK: - Floating Window Controller

class FloatingWindowController: NSWindowController {
    private let viewModel = TranscriptionViewModel.shared
    private let settings = AppSettings.shared
    private var previousActiveApp: NSRunningApplication?
    private let logger = Logger.ui

    /// Calculate window position based on the selected mode
    private static func calculateWindowPosition(mode: WindowPositionMode, windowSize: NSSize, settings: AppSettings) -> NSPoint {
        let logger = Logger.ui
        logger.info("Calculating window position for mode: \(mode.rawValue)")

        guard let screen = NSScreen.main else {
            logger.warning("No main screen available, using default position")
            return NSPoint(x: 100, y: 100)
        }

        let visibleFrame = screen.visibleFrame
        logger.debug("Screen visible frame: \(String(describing: visibleFrame))")

        switch mode {
        case .rememberLast:
            // Try to load saved position, fallback to center
            if let savedPosition = settings.getSavedWindowPosition() {
                logger.info("Using saved window position: \(String(describing: savedPosition))")
                return savedPosition
            } else {
                // Center the window
                let x = visibleFrame.origin.x + (visibleFrame.width - windowSize.width) / 2
                let y = visibleFrame.origin.y + (visibleFrame.height - windowSize.height) / 2
                let position = NSPoint(x: x, y: y)
                logger.info("No saved position, centering window at: \(String(describing: position))")
                return position
            }

        case .nearMouse:
            // Get mouse position and offset slightly
            let mouseLocation = NSEvent.mouseLocation
            let offset: CGFloat = 20
            let margin: CGFloat = 10

            var x = mouseLocation.x + offset
            var y = mouseLocation.y - offset

            // Boundary check: keep window within screen with margin
            if x + windowSize.width + margin > visibleFrame.maxX {
                x = mouseLocation.x - offset - windowSize.width
            }
            if x < visibleFrame.minX + margin {
                x = visibleFrame.minX + margin
            }

            if y < visibleFrame.minY + margin {
                y = mouseLocation.y + offset
            }
            if y + windowSize.height + margin > visibleFrame.maxY {
                y = visibleFrame.maxY - windowSize.height - margin
            }

            let position = NSPoint(x: x, y: y)
            logger.info("Positioning near mouse at: \(String(describing: position)) (mouse: \(String(describing: mouseLocation)))")
            return position

        case .topCenter:
            // Horizontal center, near top with margin for menu bar and notch
            let x = visibleFrame.origin.x + (visibleFrame.width - windowSize.width) / 2
            let y = visibleFrame.maxY - windowSize.height - 50
            let position = NSPoint(x: x, y: y)
            logger.info("Positioning at top center: \(String(describing: position))")
            return position

        case .bottomCenter:
            // Horizontal center, near bottom with margin for Dock
            let x = visibleFrame.origin.x + (visibleFrame.width - windowSize.width) / 2
            let y = visibleFrame.minY + 50
            let position = NSPoint(x: x, y: y)
            logger.info("Positioning at bottom center: \(String(describing: position))")
            return position
        }
    }

    convenience init() {
        log(.debug, "FloatingWindowController init() starting")

        // Create floating window
        let window = FloatingWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        log(.debug, "FloatingWindow created")

        window.title = "DoubaoVoice"
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // Ensure window is visible
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.alphaValue = 1.0

        log(.debug, "Window properties set")

        // Create SwiftUI view
        let contentView = FloatingTranscriptionView()
        window.contentView = NSHostingView(rootView: contentView)

        log(.debug, "Content view set")

        // Calculate and set window position based on mode
        let settings = AppSettings.shared
        let mode = settings.windowPositionMode
        let position = Self.calculateWindowPosition(mode: mode, windowSize: window.frame.size, settings: settings)
        window.setFrameOrigin(position)
        log(.debug, "Window positioned using mode \(mode.rawValue) at \(position)")

        self.init(window: window)

        log(.debug, "FloatingWindowController init() completed")

        // Save position when window moves
        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.saveWindowPosition()
        }

        // Always stop recording when window becomes hidden (defense-in-depth)
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] notification in
            guard let self = self else { return }
            self.ensureRecordingStopped()
        }

        // Observe when window is hidden/ordered out
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] notification in
            guard let self = self else { return }
            // Only stop if window is actually becoming hidden
            if self.window?.isVisible == false {
                self.ensureRecordingStopped()
            }
        }
    }

    override func showWindow(_ sender: Any?) {
        log(.debug, "FloatingWindowController.showWindow() called")

        // Capture the currently active app BEFORE we activate
        previousActiveApp = NSWorkspace.shared.frontmostApplication
        if let app = previousActiveApp {
            log(.debug, "Captured previous active app: \(app.localizedName ?? "Unknown")")
        }

        // Recalculate window position based on current mode (except for rememberLast)
        if let window = window {
            let mode = settings.windowPositionMode
            // Only reposition if not in rememberLast mode
            // In rememberLast mode, keep the window where it was last positioned
            if mode != .rememberLast {
                let position = Self.calculateWindowPosition(mode: mode, windowSize: window.frame.size, settings: settings)
                window.setFrameOrigin(position)
                log(.debug, "Repositioned window using mode \(mode.rawValue) at \(String(describing: position))")
            } else {
                log(.debug, "Using rememberLast mode, keeping window at current position")
            }
        }

        super.showWindow(sender)

        // Ensure window is visible
        guard let window = window else {
            log(.error, "Window is nil in showWindow")
            return
        }

        log(.debug, "Window exists, frame: \(window.frame)")

        // Activate the app and show window
        NSApp.activate(ignoringOtherApps: true)
        log(.debug, "App activated")

        window.makeKeyAndOrderFront(nil)
        log(.debug, "makeKeyAndOrderFront called")

        window.orderFrontRegardless()
        log(.debug, "orderFrontRegardless called")

        log(.info, "Window shown - frame: \(window.frame), isVisible: \(window.isVisible), isKeyWindow: \(window.isKeyWindow)")

        // Auto-start recording when window appears
        Task { @MainActor in
            log(.debug, "Starting recording task")
            if !viewModel.isRecording {
                viewModel.startRecording()
                NotificationCenter.default.post(name: .recordingStateChanged, object: nil)
            }
        }

        log(.info, "Floating window shown, recording started")
    }

    func hideWindow() {
        // Stop recording when window hides
        ensureRecordingStopped()

        window?.orderOut(nil)
        log(.info, "Floating window hidden, recording stopped")
    }

    private func ensureRecordingStopped() {
        // Always stop recording when window becomes hidden, regardless of how it was hidden
        Task { @MainActor in
            if viewModel.isRecording {
                log(.debug, "Stopping recording due to window hide")
                viewModel.stopRecording()
                NotificationCenter.default.post(name: .recordingStateChanged, object: nil)
            }
        }
    }

    private func saveWindowPosition() {
        guard let window = window else { return }
        settings.saveWindowPosition(window.frame.origin)
    }

    func performAutoPasteIfEnabled() {
        guard settings.autoPasteAfterClose else { return }
        guard !viewModel.transcribedText.isEmpty else { return }

        guard let previousApp = previousActiveApp else {
            log(.warning, "No previous app to paste into")
            return
        }

        log(.info, "Performing auto-paste to \(previousApp.localizedName ?? "unknown app")")

        // Brief delay before switching apps
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            // Activate the previous application
            previousApp.activate(options: [.activateIgnoringOtherApps])

            // Wait for app to become active, then simulate Cmd+V
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                self?.simulatePasteKeystroke()
            }
        }
    }

    private func simulatePasteKeystroke() {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            log(.error, "Failed to create CGEventSource for paste")
            return
        }

        // Key code for 'V' is 9
        let vKeyCode: CGKeyCode = 9

        // Create key down event with Cmd modifier
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true) else {
            log(.error, "Failed to create key down event")
            return
        }
        keyDown.flags = .maskCommand

        // Create key up event with Cmd modifier
        guard let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false) else {
            log(.error, "Failed to create key up event")
            return
        }
        keyUp.flags = .maskCommand

        // Post events
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)

        log(.info, "Auto-paste keystroke simulated (Cmd+V)")
    }
}

// MARK: - Floating Window Class

class FloatingWindow: NSPanel {
    private var localEventMonitor: Any?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func becomeKey() {
        super.becomeKey()
        setupLocalEventMonitor()
    }

    override func resignKey() {
        super.resignKey()
        removeLocalEventMonitor()
    }

    private func setupLocalEventMonitor() {
        removeLocalEventMonitor()

        let finishConfig = AppSettings.shared.finishHotkey

        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }

            // Handle Escape key for closing (works always)
            if event.keyCode == 53 {
                if let controller = self.windowController as? FloatingWindowController {
                    controller.hideWindow()
                }
                return nil
            }

            // Handle finish hotkey (only when recording)
            guard TranscriptionViewModel.shared.isRecording else {
                return event
            }

            if event.keyCode == UInt16(finishConfig.keyCode) {
                let expectedModifiers = finishConfig.modifiers
                var actualModifiers: UInt32 = 0

                if event.modifierFlags.contains(.command) {
                    actualModifiers |= UInt32(cmdKey)
                }
                if event.modifierFlags.contains(.option) {
                    actualModifiers |= UInt32(optionKey)
                }
                if event.modifierFlags.contains(.shift) {
                    actualModifiers |= UInt32(shiftKey)
                }
                if event.modifierFlags.contains(.control) {
                    actualModifiers |= UInt32(controlKey)
                }

                if actualModifiers == expectedModifiers {
                    NotificationCenter.default.post(name: .finishRecordingRequested, object: nil)
                    return nil
                }
            }

            return event
        }
    }

    private func removeLocalEventMonitor() {
        if let monitor = localEventMonitor {
            NSEvent.removeMonitor(monitor)
            localEventMonitor = nil
        }
    }

    deinit {
        removeLocalEventMonitor()
    }
}

// MARK: - Floating Transcription View

struct FloatingTranscriptionView: View {
    @ObservedObject private var viewModel = TranscriptionViewModel.shared

    var body: some View {
        VStack(spacing: 0) {
            // Status bar
            HStack {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)

                Text(viewModel.statusMessage)
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                // Finish button (only show when recording)
                if viewModel.isRecording {
                    Button(action: {
                        finishRecording()
                    }) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .imageScale(.small)
                    }
                    .buttonStyle(.plain)
                    .help("Finish and copy (\(AppSettings.shared.finishHotkey.displayString))")
                }

                // Close button
                Button(action: {
                    closeWindow()
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                        .imageScale(.small)
                }
                .buttonStyle(.plain)
                .help("Hide window (ESC)")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)

            Divider()

            // Transcription text area
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if viewModel.transcribedText.isEmpty {
                            Text("Listening...")
                                .foregroundColor(.secondary)
                                .italic()
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding()
                        } else {
                            Text(viewModel.transcribedText)
                                .font(.body)
                                .textSelection(.enabled)
                                .padding()
                                .id("transcriptionText")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onChange(of: viewModel.transcribedText) { _ in
                        // Auto-scroll to bottom
                        withAnimation {
                            proxy.scrollTo("transcriptionText", anchor: .bottom)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.ultraThinMaterial)

            // Error message
            if let error = viewModel.errorMessage {
                Divider()

                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .imageScale(.small)

                    Text(error)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial)
            }
        }
        .frame(minWidth: 300, minHeight: 200)
        .onReceive(NotificationCenter.default.publisher(for: .finishRecordingRequested)) { _ in
            finishRecording()
        }
    }

    private var statusColor: Color {
        if viewModel.isRecording {
            return .red
        } else if viewModel.errorMessage != nil {
            return .orange
        } else if viewModel.statusMessage.contains("Connected") || viewModel.statusMessage.contains("Completed") {
            return .green
        } else {
            return .gray
        }
    }

    private func closeWindow() {
        // Find the window controller and hide the window
        if let window = NSApp.keyWindow,
           let controller = window.windowController as? FloatingWindowController {
            controller.hideWindow()
        }
    }

    private func finishRecording() {
        Task {
            let success = await viewModel.finishRecordingAndCopy()

            // Give brief moment for user to see "Copied" status
            if success {
                try? await Task.sleep(nanoseconds: 300_000_000) // 300ms
            }

            // Perform auto-paste if enabled and copy succeeded
            if success, let controller = NSApp.keyWindow?.windowController as? FloatingWindowController {
                controller.performAutoPasteIfEnabled()
            }

            // Close window
            closeWindow()
        }
    }
}

#Preview {
    FloatingTranscriptionView()
        .frame(width: 400, height: 300)
}

// MARK: - Notification Extensions

extension Notification.Name {
    static let finishRecordingRequested = Notification.Name("finishRecordingRequested")
}
