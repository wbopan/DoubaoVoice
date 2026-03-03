//
//  FloatingWindow.swift
//  Seedling
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
    static func calculateWindowPosition(mode: WindowPositionMode, windowSize: NSSize, settings: AppSettings) -> NSPoint {
        log(.info, "Calculating window position for mode: \(mode.rawValue)")

        guard let screen = NSScreen.main else {
            log(.warning, "No main screen available, using default position")
            return NSPoint(x: 100, y: 100)
        }

        let visibleFrame = screen.visibleFrame
        log(.debug, "Screen visible frame: \(String(describing: visibleFrame))")

        switch mode {
        case .rememberLast:
            // Try to load saved position, fallback to center
            if let savedPosition = settings.getSavedWindowPosition() {
                log(.info, "Using saved window position: \(String(describing: savedPosition))")
                return savedPosition
            }
            // Center the window
            let x = visibleFrame.origin.x + (visibleFrame.width - windowSize.width) / 2
            let y = visibleFrame.origin.y + (visibleFrame.height - windowSize.height) / 2
            let position = NSPoint(x: x, y: y)
            log(.info, "No saved position, centering window at: \(String(describing: position))")
            return position

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
            log(.info, "Positioning near mouse at: \(String(describing: position)) (mouse: \(String(describing: mouseLocation)))")
            return position

        case .topCenter:
            // Horizontal center, near top with margin for menu bar and notch
            let x = visibleFrame.origin.x + (visibleFrame.width - windowSize.width) / 2
            let y = visibleFrame.maxY - windowSize.height - 50
            let position = NSPoint(x: x, y: y)
            log(.info, "Positioning at top center: \(String(describing: position))")
            return position

        case .bottomCenter:
            // Horizontal center, near bottom with margin for Dock
            let x = visibleFrame.origin.x + (visibleFrame.width - windowSize.width) / 2
            let y = visibleFrame.minY + 50
            let position = NSPoint(x: x, y: y)
            log(.info, "Positioning at bottom center: \(String(describing: position))")
            return position
        }
    }

    convenience init() {
        log(.debug, "FloatingWindowController init() starting")

        // Create floating window (minimal initial size, non-activating)
        let window = FloatingWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 70),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        log(.debug, "FloatingWindow created")

        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.hidesOnDeactivate = false

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

        // Stop recording when window becomes hidden (defense-in-depth)
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] notification in
            guard let self = self else { return }
            self.ensureRecordingStopped()
        }
    }

    override func showWindow(_ sender: Any?) {
        log(.debug, "FloatingWindowController.showWindow() called")

        // Capture the currently active app BEFORE we activate
        previousActiveApp = NSWorkspace.shared.frontmostApplication
        if let app = previousActiveApp {
            log(.debug, "Captured previous active app: \(app.localizedName ?? "Unknown")")
        }

        // [Sync] Capture raw context BEFORE showing our window
        let rawContext = performSynchronousCapture()

        guard let window = window else {
            log(.error, "Window is nil in showWindow")
            return
        }

        // Reset window to minimal size when showing
        let minSize = NSSize(width: 200, height: 70)
        let currentCenter = NSPoint(
            x: window.frame.origin.x + window.frame.width / 2,
            y: window.frame.origin.y + window.frame.height / 2
        )
        let newOrigin = NSPoint(
            x: currentCenter.x - minSize.width / 2,
            y: currentCenter.y - minSize.height / 2
        )
        window.setFrame(NSRect(origin: newOrigin, size: minSize), display: false)
        log(.debug, "Reset window to minimal size: \(minSize)")

        // Recalculate window position based on current mode (except for rememberLast)
        let mode = settings.windowPositionMode
        if mode != .rememberLast {
            let position = Self.calculateWindowPosition(mode: mode, windowSize: window.frame.size, settings: settings)
            window.setFrameOrigin(position)
            log(.debug, "Repositioned window using mode \(mode.rawValue) at \(String(describing: position))")
        }

        log(.debug, "Window exists, frame: \(window.frame)")

        // Show window without stealing focus (non-activating panel)
        window.alphaValue = 0
        window.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            window.animator().alphaValue = 1
        }
        log(.debug, "orderFrontRegardless called (non-activating)")

        log(.info, "Window shown - frame: \(window.frame), isVisible: \(window.isVisible)")

        // [Async Serial] Process context -> Set context -> Start recording
        // This ensures recording starts AFTER context is ready
        Task { @MainActor in
            logger.debug("Task started - about to process context")

            // Step 1: Process and set context (or clear if not captured)
            if let raw = rawContext {
                logger.debug("Processing context from \(raw.applicationName): \(raw.text.count) chars")
                let processed = await ContextProcessor.shared.process(
                    text: raw.text,
                    maxLength: settings.maxContextLength
                )

                let processedContext = CapturedTextContext(
                    text: processed.text,
                    documentPath: raw.documentPath,
                    applicationName: raw.applicationName,
                    bundleIdentifier: raw.bundleIdentifier,
                    capturedAt: raw.capturedAt
                )

                logger.debug("About to call setCapturedContext")
                viewModel.setCapturedContext(processedContext)
                logger.info("Context set, processed: \(processed.originalLength) -> \(processed.text.count) chars")
            } else {
                // Clear previous context to avoid using stale data
                logger.debug("No rawContext, clearing previous context")
                viewModel.setCapturedContext(nil)
            }

            // Step 2: Start recording (context is now ready/cleared)
            logger.debug("About to call startRecording")
            if !viewModel.isRecording {
                viewModel.startRecording()
            }
            logger.debug("Task completed")
        }

        // Notify SwiftUI view to adjust window size (fixes size issue after empty-text close)
        NotificationCenter.default.post(name: .floatingWindowDidShow, object: nil)

        log(.info, "Floating window shown")
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
            }
        }
    }

    private func saveWindowPosition() {
        guard let window = window else { return }
        settings.saveWindowPosition(window.frame.origin)
    }

    /// Synchronously capture raw context from the previously focused application
    /// Returns the raw context without processing (processing is done in showWindow's Task)
    private func performSynchronousCapture() -> CapturedTextContext? {
        guard settings.contextCaptureEnabled else {
            log(.debug, "Context capture disabled")
            return nil
        }

        // Log the current frontmost app at the moment of capture
        let currentFrontmost = NSWorkspace.shared.frontmostApplication
        log(.debug, "performSynchronousCapture - frontmost app: \(currentFrontmost?.localizedName ?? "nil")")

        // Check accessibility permission
        guard AccessibilityTextCapture.shared.checkPermission(prompt: false) else {
            log(.warning, "Accessibility permission not granted for context capture")
            return nil
        }

        // Use the previously captured app info if available (more reliable for browsers)
        // This avoids timing issues where the focused app changes during capture
        if let prevApp = previousActiveApp,
           let bundleId = prevApp.bundleIdentifier,
           let appName = prevApp.localizedName {
            log(.debug, "Using previousActiveApp for capture: \(appName) (\(bundleId))")
            if let context = AccessibilityTextCapture.shared.captureFromApp(bundleId: bundleId, appName: appName) {
                if let path = context.documentPath {
                    let filename = (path as NSString).lastPathComponent
                    log(.info, "Captured \(context.text.count) chars from \(context.applicationName) [\(filename)]")
                } else {
                    log(.info, "Captured \(context.text.count) chars from \(context.applicationName)")
                }
                return context
            }
        } else {
            // Fall back to generic capture if no previous app info
            if let context = AccessibilityTextCapture.shared.captureFromFocusedApp() {
                if let path = context.documentPath {
                    let filename = (path as NSString).lastPathComponent
                    log(.info, "Captured \(context.text.count) chars from \(context.applicationName) [\(filename)]")
                } else {
                    log(.info, "Captured \(context.text.count) chars from \(context.applicationName)")
                }
                return context
            }
        }

        log(.info, "No context captured from previous app")
        return nil
    }

    /// Finish recording, copy to clipboard, auto-paste, and dismiss the window
    func finishRecordingAndDismiss() {
        Task { @MainActor in
            let success = await viewModel.finishRecordingAndCopy()
            if success {
                performAutoPasteIfEnabled()
            }
            hideWindow()
        }
    }

    func performAutoPasteIfEnabled() {
        guard settings.autoPasteAfterClose else { return }
        guard !viewModel.transcribedText.isEmpty else { return }

        log(.info, "Performing auto-paste (previous app stays active)")

        // Brief delay for pasteboard to settle, then simulate Cmd+V
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            self?.simulatePasteKeystroke()
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

/// A non-activating panel that never steals focus from other applications
class FloatingWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
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
    let audioLevels: [Float]
    var compact: Bool = false
    private let barCount = 5

    // Arc-shaped scale: bars inscribe a circle, center tallest, edges shortest
    private let arcScale: [CGFloat] = [0.6, 0.92, 1.0, 0.92, 0.6]

    var body: some View {
        HStack(spacing: compact ? 2 : 3) {
            ForEach(0..<barCount, id: \.self) { index in
                WaveformBar(level: barLevel(for: index), compact: compact)
            }
        }
        .frame(height: compact ? 21 : 36)
    }

    private func barLevel(for index: Int) -> CGFloat {
        let minHeight: CGFloat = 0.15
        let level = index < audioLevels.count ? audioLevels[index] : 0
        let scale = index < arcScale.count ? arcScale[index] : 1.0
        return max(minHeight * scale, CGFloat(level) * scale)
    }
}

struct WaveformBar: View {
    let level: CGFloat
    var compact: Bool = false

    var body: some View {
        RoundedRectangle(cornerRadius: compact ? 1 : 1.5)
            .fill(Color.primary.opacity(0.8))
            .frame(width: compact ? 2.5 : 3, height: max(compact ? 3 : 4, level * (compact ? 18 : 30)))
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
                // Waveform animation - show as soon as recording starts (including connecting phase)
                if viewModel.isRecording {
                    WaveformView(audioLevels: viewModel.audioLevels)
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
                            .help("Close")

                            if viewModel.isRecording && !viewModel.transcribedText.isEmpty {
                                CircularGlassButton(
                                    systemName: "arrow.up",
                                    isAccent: true,
                                    action: finishRecording
                                )
                                .glassEffectID("submit", in: buttonNamespace)
                                .help("Done")
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
        guard let window = NSApp.windows.first(where: { $0 is FloatingWindow }) else { return }

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

    private func findController() -> FloatingWindowController? {
        NSApp.windows
            .first(where: { $0 is FloatingWindow })?
            .windowController as? FloatingWindowController
    }

    private func closeWindow() {
        findController()?.hideWindow()
    }

    private func finishRecording() {
        findController()?.finishRecordingAndDismiss()
    }
}

#Preview {
    FloatingTranscriptionView()
        .frame(width: 400, height: 300)
}

// MARK: - Notification Extensions

extension Notification.Name {
    static let floatingWindowDidShow = Notification.Name("floatingWindowDidShow")
}
