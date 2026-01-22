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

    convenience init() {
        print("DEBUG: FloatingWindowController init() starting")

        // Create floating window
        let window = FloatingWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        print("DEBUG: FloatingWindow created")

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

        print("DEBUG: Window properties set")

        // Create SwiftUI view
        let contentView = FloatingTranscriptionView()
        window.contentView = NSHostingView(rootView: contentView)

        print("DEBUG: Content view set")

        // Restore saved position
        if let savedPosition = AppSettings.shared.getSavedWindowPosition() {
            window.setFrameOrigin(savedPosition)
            print("DEBUG: Restored position to \(savedPosition)")
        } else {
            window.center()
            print("DEBUG: Centered window")
        }

        self.init(window: window)

        print("DEBUG: FloatingWindowController init() completed")

        // Save position when window moves
        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.saveWindowPosition()
        }
    }

    override func showWindow(_ sender: Any?) {
        print("DEBUG: FloatingWindowController.showWindow() called")
        super.showWindow(sender)

        // Ensure window is visible
        guard let window = window else {
            print("DEBUG: ERROR - Window is nil in showWindow")
            log(.error, "Window is nil in showWindow")
            return
        }

        print("DEBUG: Window exists, frame: \(window.frame)")

        // Activate the app and show window
        NSApp.activate(ignoringOtherApps: true)
        print("DEBUG: App activated")

        window.makeKeyAndOrderFront(nil)
        print("DEBUG: makeKeyAndOrderFront called")

        window.orderFrontRegardless()
        print("DEBUG: orderFrontRegardless called")

        print("DEBUG: Window shown - frame: \(window.frame), isVisible: \(window.isVisible), isKeyWindow: \(window.isKeyWindow)")
        log(.info, "Window shown - frame: \(window.frame), isVisible: \(window.isVisible)")

        // Auto-start recording when window appears
        Task { @MainActor in
            print("DEBUG: Starting recording task")
            if !viewModel.isRecording {
                viewModel.startRecording()
                NotificationCenter.default.post(name: .recordingStateChanged, object: nil)
            }
        }

        log(.info, "Floating window shown, recording started")
    }

    func hideWindow() {
        // Stop recording when window hides
        Task { @MainActor in
            if viewModel.isRecording {
                viewModel.stopRecording()
                NotificationCenter.default.post(name: .recordingStateChanged, object: nil)
            }
        }

        window?.orderOut(nil)
        log(.info, "Floating window hidden, recording stopped")
    }

    private func saveWindowPosition() {
        guard let window = window else { return }
        settings.saveWindowPosition(window.frame.origin)
    }
}

// MARK: - Floating Window Class

class FloatingWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        // Handle Escape key to hide window
        if event.keyCode == 53 { // Escape key
            if let controller = windowController as? FloatingWindowController {
                controller.hideWindow()
            }
        } else {
            super.keyDown(with: event)
        }
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
}

#Preview {
    FloatingTranscriptionView()
        .frame(width: 400, height: 300)
}
