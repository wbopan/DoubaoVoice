//
//  FloatingBallWindow.swift
//  Seedling
//
//  Non-activating floating ball indicator for direct text input mode.
//  Does not steal focus from the active application.
//

import Cocoa
import SwiftUI
import OSLog

// MARK: - Floating Ball Panel

/// A non-activating panel that never steals focus from other applications
class FloatingBallPanel: NSPanel {
    private var dragOrigin: NSPoint?

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override init(contentRect: NSRect, styleMask: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool) {
        // Always include .nonactivatingPanel to prevent activation
        let style: NSWindow.StyleMask = [.borderless, .nonactivatingPanel]
        super.init(contentRect: contentRect, styleMask: style, backing: backing, defer: flag)

        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
    }

    // MARK: - Custom Drag

    override func mouseDown(with event: NSEvent) {
        dragOrigin = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = dragOrigin else { return }
        let current = event.locationInWindow
        let dx = current.x - origin.x
        let dy = current.y - origin.y
        var frameOrigin = frame.origin
        frameOrigin.x += dx
        frameOrigin.y += dy
        setFrameOrigin(frameOrigin)
    }

    override func mouseUp(with event: NSEvent) {
        dragOrigin = nil
        // Save position after drag
        AppSettings.shared.saveBallPosition(frame.origin)
    }
}

// MARK: - Floating Ball Window Controller

class FloatingBallWindowController: NSWindowController {
    private let viewModel = TranscriptionViewModel.shared
    private let settings = AppSettings.shared
    private let logger = Logger.ui
    private var capturedContext: CapturedTextContext?

    convenience init() {
        let ballSize: CGFloat = 36
        let panel = FloatingBallPanel(
            contentRect: NSRect(x: 0, y: 0, width: ballSize, height: ballSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        let contentView = FloatingBallView()
        let hostingView = NSHostingView(rootView: contentView)
        hostingView.autoresizingMask = [.width, .height]
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear

        panel.contentView = hostingView

        DispatchQueue.main.async {
            clearBackgrounds(hostingView)
        }

        // Position based on WindowPositionMode setting
        let mode = AppSettings.shared.windowPositionMode
        if mode == .rememberLast {
            if let savedPosition = AppSettings.shared.getSavedBallPosition() {
                panel.setFrameOrigin(savedPosition)
            } else {
                // Default: top-right area of screen
                if let screen = NSScreen.main {
                    let visibleFrame = screen.visibleFrame
                    let x = visibleFrame.maxX - ballSize - 20
                    let y = visibleFrame.maxY - ballSize - 80
                    panel.setFrameOrigin(NSPoint(x: x, y: y))
                }
            }
        } else {
            let position = FloatingWindowController.calculateWindowPosition(
                mode: mode,
                windowSize: NSSize(width: ballSize, height: ballSize),
                settings: AppSettings.shared
            )
            panel.setFrameOrigin(position)
        }

        self.init(window: panel)

        // Save position when window moves
        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            if let origin = self?.window?.frame.origin {
                AppSettings.shared.saveBallPosition(origin)
            }
        }
    }

    @MainActor
    func showBall() {
        guard let panel = window else { return }

        // Reposition based on WindowPositionMode (except rememberLast)
        let mode = settings.windowPositionMode
        if mode != .rememberLast {
            let ballSize: CGFloat = 36
            let position = FloatingWindowController.calculateWindowPosition(
                mode: mode,
                windowSize: NSSize(width: ballSize, height: ballSize),
                settings: settings
            )
            panel.setFrameOrigin(position)
            log(.debug, "FloatingBall: repositioned using mode \(mode.rawValue)")
        }

        // The active app is still the frontmost app since we don't activate
        let frontApp = NSWorkspace.shared.frontmostApplication
        log(.debug, "FloatingBall: frontmost app is \(frontApp?.localizedName ?? "unknown")")

        // Show panel without activating, fade in
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().alphaValue = 1
        }

        // Capture context from the frontmost app (which remains active)
        capturedContext = nil
        let rawContext = performSynchronousCapture(frontApp: frontApp)

        // Enable direct input mode
        viewModel.setDirectInputMode(true)

        // Process context and start recording
        Task { @MainActor in
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
                capturedContext = processedContext
                viewModel.setCapturedContext(processedContext)
            } else {
                viewModel.setCapturedContext(nil)
            }

            if !viewModel.isRecording {
                viewModel.startRecording()
                NotificationCenter.default.post(name: .recordingStateChanged, object: nil)
            }
        }

        log(.info, "Floating ball shown")
    }

    @MainActor
    func hideBall() {
        if viewModel.isRecording || viewModel.isConnecting {
            // Ball stays visible showing processing spinner while waiting for second pass
            Task { @MainActor in
                await viewModel.finishRecordingDirectInput()
                viewModel.setDirectInputMode(false)
                await fadeOutAndHide()
                log(.info, "Floating ball hidden after second pass")
            }
            NotificationCenter.default.post(name: .recordingStateChanged, object: nil)
        } else {
            viewModel.setDirectInputMode(false)
            Task { @MainActor in
                await fadeOutAndHide()
                log(.info, "Floating ball hidden")
            }
        }
    }

    @MainActor
    private func fadeOutAndHide() async {
        guard let panel = window else { return }
        await withCheckedContinuation { continuation in
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.2
                panel.animator().alphaValue = 0
            }, completionHandler: {
                panel.orderOut(nil)
                panel.alphaValue = 1  // Reset for next show
                continuation.resume()
            })
        }
    }

    private func performSynchronousCapture(frontApp: NSRunningApplication?) -> CapturedTextContext? {
        guard settings.contextCaptureEnabled else {
            log(.debug, "Context capture disabled")
            return nil
        }

        guard AccessibilityTextCapture.shared.checkPermission(prompt: false) else {
            log(.warning, "Accessibility permission not granted for context capture")
            return nil
        }

        if let app = frontApp,
           let bundleId = app.bundleIdentifier,
           let appName = app.localizedName {
            log(.debug, "Capturing context from \(appName) (\(bundleId))")
            if let context = AccessibilityTextCapture.shared.captureFromApp(bundleId: bundleId, appName: appName) {
                log(.info, "Captured \(context.text.count) chars from \(context.applicationName)")
                return context
            }
        }

        log(.info, "No context captured from frontmost app")
        return nil
    }
}

// MARK: - Floating Ball View

struct FloatingBallView: View {
    @ObservedObject private var viewModel = TranscriptionViewModel.shared

    var body: some View {
        ZStack {
            // State-based content
            if viewModel.isConnecting || viewModel.isProcessing {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 36, height: 36)
            } else if viewModel.isRecording {
                WaveformView(audioLevel: viewModel.audioLevel, compact: true)
                    .foregroundStyle(.primary)
            }
        }
        .frame(width: 36, height: 36)
        .glassEffect(.regular, in: .circle)
        .clipShape(Circle())
    }

}
