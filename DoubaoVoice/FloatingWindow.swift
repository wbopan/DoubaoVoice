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
    private var capturedContext: CapturedTextContext?

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

        // Create SwiftUI view - Liquid Glass effect is applied in SwiftUI
        let contentView = FloatingTranscriptionView()
        let hostingView = NSHostingView(rootView: contentView)
        hostingView.autoresizingMask = [.width, .height]

        // Make hosting view fully transparent for Liquid Glass to work properly
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear

        // Remove any default background from the hosting view's subviews
        func clearBackgrounds(_ view: NSView) {
            view.wantsLayer = true
            view.layer?.backgroundColor = .clear
            for subview in view.subviews {
                clearBackgrounds(subview)
            }
        }

        window.contentView = hostingView

        // Clear backgrounds after adding to window (needed for proper layer setup)
        DispatchQueue.main.async {
            clearBackgrounds(hostingView)
        }

        log(.debug, "Content view set with Liquid Glass effect")

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

        // Capture context from the focused app BEFORE activating our window
        capturedContext = nil
        if settings.contextCaptureEnabled && settings.autoCaptureOnActivate {
            captureContextFromPreviousApp()
        }

        // Reset window to minimal size when showing
        if let window = window {
            let minSize = NSSize(width: 200, height: 70)
            let currentOrigin = window.frame.origin

            // Keep center position when resizing to minimum
            let currentCenter = NSPoint(
                x: currentOrigin.x + window.frame.width / 2,
                y: currentOrigin.y + window.frame.height / 2
            )

            let newOrigin = NSPoint(
                x: currentCenter.x - minSize.width / 2,
                y: currentCenter.y - minSize.height / 2
            )

            window.setFrame(NSRect(origin: newOrigin, size: minSize), display: false)
            log(.debug, "Reset window to minimal size: \(minSize)")
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

        // Notify SwiftUI view to adjust window size (fixes size issue after empty-text close)
        NotificationCenter.default.post(name: .floatingWindowDidShow, object: nil)

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

    /// Capture context from the previously focused application
    private func captureContextFromPreviousApp() {
        logger.info("Attempting to capture context from previous app")

        guard AccessibilityTextCapture.shared.checkPermission(prompt: false) else {
            logger.warning("Accessibility permission not granted, skipping context capture")
            return
        }

        if let context = AccessibilityTextCapture.shared.captureFromFocusedApp() {
            // Truncate to max length setting
            let truncatedContext = context.truncated(to: settings.maxContextLength)
            capturedContext = truncatedContext

            logger.info("Captured \(truncatedContext.text.count) chars from \(truncatedContext.applicationName)")

            // Pass the captured context to the view model
            viewModel.setCapturedContext(truncatedContext)
        } else {
            logger.info("No context captured from previous app")
            capturedContext = nil
            viewModel.setCapturedContext(nil)
        }
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
            previousApp.activate()

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

            // Handle finish hotkey (only when recording and hotkey is set)
            guard TranscriptionViewModel.shared.isRecording else {
                return event
            }

            // Skip if finish hotkey is unset
            guard !finishConfig.isUnset else {
                return event
            }

            if event.keyCode == UInt16(finishConfig.keyCode) &&
               event.modifierFlags.carbonModifiers == finishConfig.modifiers {
                NotificationCenter.default.post(name: .finishRecordingRequested, object: nil)
                return nil
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

// MARK: - Circular Glass Button

struct CircularGlassButton: View {
    let systemName: String
    let isAccent: Bool
    let action: () -> Void

    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(isAccent ? .white : .primary)
                .frame(width: 32, height: 32)
                .background {
                    if isAccent {
                        Circle()
                            .fill(Color.accentColor)
                    }
                }
                .glassEffect(isAccent ? .clear : .regular, in: .circle)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Waveform View

struct WaveformView: View {
    let audioLevel: Float
    private let barCount = 5

    // Fixed random offsets for each bar to create organic variation
    private let barOffsets: [Float] = [0.7, 1.0, 0.85, 0.95, 0.75]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<barCount, id: \.self) { index in
                WaveformBar(level: barLevel(for: index))
            }
        }
        .frame(height: 24)
    }

    private func barLevel(for index: Int) -> CGFloat {
        let offset = barOffsets[index]
        let minHeight: CGFloat = 0.15
        return max(minHeight, CGFloat(audioLevel) * CGFloat(offset))
    }
}

struct WaveformBar: View {
    let level: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: 1.5)
            .fill(Color.primary.opacity(0.8))
            .frame(width: 3, height: max(4, level * 20))
            .animation(.easeInOut(duration: 0.12), value: level)
    }
}

// MARK: - Floating Transcription View

struct FloatingTranscriptionView: View {
    @ObservedObject private var viewModel = TranscriptionViewModel.shared
    @Namespace private var buttonNamespace

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
            .scrollContentBackground(.hidden)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Button area - waveform on left, buttons on right
            HStack {
                // Waveform animation - only show when recording and connected
                if viewModel.isRecording && !viewModel.isConnecting {
                    WaveformView(audioLevel: viewModel.audioLevel)
                        .padding(.leading, 20)
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }

                Spacer()

                GlassEffectContainer(spacing: 8) {
                    HStack(spacing: 8) {
                        if viewModel.isConnecting || viewModel.isProcessing {
                            ProgressView()
                                .controlSize(.small)
                                .frame(width: 32, height: 32)
                        } else {
                            CircularGlassButton(
                                systemName: "xmark",
                                isAccent: false,
                                action: closeWindow
                            )
                            .glassEffectID("close", in: buttonNamespace)
                            .help("Hide window (ESC)")

                            if viewModel.isRecording && !viewModel.transcribedText.isEmpty {
                                CircularGlassButton(
                                    systemName: "arrow.up",
                                    isAccent: true,
                                    action: finishRecording
                                )
                                .glassEffectID("submit", in: buttonNamespace)
                                .help(AppSettings.shared.finishHotkey.isUnset
                                    ? "Finish and copy (no hotkey set)"
                                    : "Finish and copy (\(AppSettings.shared.finishHotkey.displayString))")
                                .transition(.opacity)
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 4)
                .padding(.bottom, 12)
            }
            .animation(.easeInOut(duration: 0.2), value: viewModel.isRecording)
        }
        .frame(minWidth: 150, minHeight: 70)
        .background(.clear)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 28))
        .clipShape(RoundedRectangle(cornerRadius: 28))
        .onAppear {
            // Adjust window size on initial appearance
            DispatchQueue.main.async {
                adjustWindowSize()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .finishRecordingRequested)) { _ in
            finishRecording()
        }
        .onReceive(NotificationCenter.default.publisher(for: .floatingWindowDidShow)) { _ in
            DispatchQueue.main.async {
                adjustWindowSize()
            }
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

#Preview {
    FloatingTranscriptionView()
        .frame(width: 400, height: 300)
}

// MARK: - Notification Extensions

extension Notification.Name {
    static let finishRecordingRequested = Notification.Name("finishRecordingRequested")
    static let floatingWindowDidShow = Notification.Name("floatingWindowDidShow")
}
