//
//  FloatingWindow.swift
//  DoubaoVoice
//
//  Floating transcription window with auto-start recording
//

import Cocoa
import SwiftUI

// MARK: - Floating Window Controller

class FloatingWindowController: NSWindowController {
    private let viewModel = TranscriptionViewModel.shared
    private let settings = AppSettings.shared
    private var previousActiveApp: NSRunningApplication?

    convenience init() {
        log(.debug, "FloatingWindowController init() starting")

        // Create floating window (minimal initial size)
        let window = FloatingWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 70),
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )

        log(.debug, "FloatingWindow created")

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

        // Create SwiftUI view with glass effect
        let contentView = FloatingTranscriptionView()
        let hostingView = NSHostingView(rootView: contentView)
        hostingView.autoresizingMask = [.width, .height]

        // Create glass effect base
        let glassView = GlassEffectView(frame: window.contentView!.bounds)
        glassView.autoresizingMask = [.width, .height]

        // Make hosting view transparent
        hostingView.layer?.backgroundColor = .clear

        // Set up view hierarchy
        glassView.addSubview(hostingView)
        hostingView.frame = glassView.bounds

        window.contentView = glassView

        log(.debug, "Content view set with glass effect")

        // Restore saved position
        if let savedPosition = AppSettings.shared.getSavedWindowPosition() {
            window.setFrameOrigin(savedPosition)
            log(.debug, "Restored position to \(savedPosition)")
        } else {
            window.center()
            log(.debug, "Centered window")
        }

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

// MARK: - Glass Effect View

class GlassEffectView: NSView {
    private let visualEffectView: NSVisualEffectView

    override init(frame: NSRect) {
        visualEffectView = NSVisualEffectView(frame: frame)
        super.init(frame: frame)

        // Configure glass effect
        visualEffectView.material = .popover
        visualEffectView.blendingMode = .behindWindow
        visualEffectView.state = .active
        visualEffectView.wantsLayer = true
        visualEffectView.autoresizingMask = [.width, .height]

        // Apply large corner radius
        visualEffectView.layer?.cornerRadius = 28.0
        visualEffectView.layer?.masksToBounds = true

        addSubview(visualEffectView)

        // Add subtle tint layer for glass aesthetic
        let tintLayer = CALayer()
        tintLayer.backgroundColor = CGColor(gray: 0.95, alpha: 0.3)
        tintLayer.cornerRadius = 28.0
        tintLayer.frame = bounds
        tintLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        visualEffectView.layer?.addSublayer(tintLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override func layout() {
        super.layout()
        visualEffectView.frame = bounds
    }
}

// MARK: - Floating Transcription View

struct FloatingTranscriptionView: View {
    @ObservedObject private var viewModel = TranscriptionViewModel.shared

    var body: some View {
        VStack(spacing: 0) {
            // Text area - auto expand height, no scrollbar
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(viewModel.transcribedText)
                        .font(.system(size: 15))
                        .textSelection(.enabled)
                        .animation(.easeInOut(duration: 0.2), value: viewModel.transcribedText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Button area - aligned to bottom right
            HStack {
                Spacer()

                HStack(spacing: 8) {
                    // Show loading indicator when preparing to record
                    if !viewModel.isRecording && (viewModel.statusMessage == "Connecting..." || viewModel.statusMessage == "Connected") {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 32, height: 32)
                            .background(
                                Circle()
                                    .fill(Color.primary.opacity(0.15))
                            )
                    }
                    // Show buttons when recording
                    else if viewModel.isRecording {
                        // Always show close button when recording
                        Button(action: {
                            closeWindow()
                        }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 14, weight: .bold))
                        }
                        .buttonStyle(CircularButtonStyle(isAccent: false))
                        .help("Hide window (ESC)")

                        // Only show submit button when there's text
                        if !viewModel.transcribedText.isEmpty {
                            Button(action: {
                                finishRecording()
                            }) {
                                Image(systemName: "arrow.up")
                                    .font(.system(size: 14, weight: .bold))
                            }
                            .buttonStyle(CircularButtonStyle(isAccent: true))
                            .help("Finish and copy (\(AppSettings.shared.finishHotkey.displayString))")
                            .transition(.opacity)
                        }
                    }
                    // Show close button when not recording (finished state)
                    else {
                        Button(action: {
                            closeWindow()
                        }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 14, weight: .bold))
                        }
                        .buttonStyle(CircularButtonStyle(isAccent: false))
                        .help("Hide window (ESC)")
                    }
                }
                .animation(.easeInOut(duration: 0.3), value: viewModel.transcribedText.isEmpty)
                .padding(.horizontal, 20)
                .padding(.top, 4)
                .padding(.bottom, 12)
            }
        }
        .frame(minWidth: 150, minHeight: 70)
        .onAppear {
            // Adjust window size on initial appearance
            DispatchQueue.main.async {
                adjustWindowSize()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .finishRecordingRequested)) { _ in
            finishRecording()
        }
        .onChange(of: viewModel.transcribedText) {
            adjustWindowSize()
        }
    }

    private func adjustWindowSize() {
        guard let window = NSApp.keyWindow else { return }

        let text = viewModel.transcribedText

        // Calculate text size (use single character placeholder if empty)
        let displayText = text.isEmpty ? " " : text
        let font = NSFont.systemFont(ofSize: 15)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]

        // First, get the natural text width
        let attributedString = NSAttributedString(string: displayText, attributes: attributes)
        let naturalSize = attributedString.size()

        // Define width constraints
        let minWidth: CGFloat = 200
        let maxWidth: CGFloat = 420 // 70% of original 600
        let horizontalPadding: CGFloat = 56 // 40 for text (20 * 2) + 16 extra

        // Calculate desired width based on text
        let desiredTextWidth = min(max(naturalSize.width + 10, minWidth - horizontalPadding), maxWidth - horizontalPadding)
        let finalWidth = desiredTextWidth + horizontalPadding

        // Now calculate height with the determined width
        let textRect = attributedString.boundingRect(
            with: NSSize(width: desiredTextWidth, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )

        let textHeight = ceil(textRect.height)
        let buttonAreaHeight: CGFloat = 48 // 32 (button) + 4 (top padding) + 12 (bottom padding)
        let textPadding: CGFloat = 16 // 12 (top) + 4 (bottom), horizontal is 20 per side

        let maxTextHeight: CGFloat = 400
        let constrainedTextHeight = min(textHeight, maxTextHeight)

        let totalHeight = constrainedTextHeight + textPadding + buttonAreaHeight
        let finalHeight = max(totalHeight, 70)

        // Keep center position when resizing
        let currentFrame = window.frame
        let centerX = currentFrame.origin.x + currentFrame.width / 2
        let centerY = currentFrame.origin.y + currentFrame.height / 2

        let newX = centerX - finalWidth / 2
        let newY = centerY - finalHeight / 2

        let newFrame = NSRect(
            x: newX,
            y: newY,
            width: finalWidth,
            height: finalHeight
        )

        // Animate the resize
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(newFrame, display: true)
        })
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

// MARK: - Circular Button Style

struct CircularButtonStyle: ButtonStyle {
    let isAccent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(isAccent ? .white : .primary)
            .frame(width: 32, height: 32)
            .background(
                Circle()
                    .fill(isAccent ? Color.accentColor : Color.primary.opacity(configuration.isPressed ? 0.3 : 0.15))
            )
            .scaleEffect(configuration.isPressed ? 0.9 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: configuration.isPressed)
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
