//
//  SettingsWindow.swift
//  DoubaoVoice
//
//  Settings panel with API configuration and hotkey recorder
//

import Cocoa
import SwiftUI
import Carbon

// MARK: - Settings Window Controller

class SettingsWindowController: NSWindowController {
    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 550, height: 500),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        window.title = "Settings"
        window.center()
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.backgroundColor = .clear

        // Create SwiftUI view
        let contentView = SettingsView()
        window.contentView = NSHostingView(rootView: contentView)

        self.init(window: window)
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    private let viewModel = TranscriptionViewModel.shared

    @State private var showingHotkeyRecorder = false
    @State private var showingFinishHotkeyRecorder = false
    @State private var tempAppKey = ""
    @State private var tempAccessKey = ""

    var body: some View {
        VStack(spacing: 0) {
            // Tabbed interface
            TabView {
                APISettingsTab(appKey: $tempAppKey, accessKey: $tempAccessKey)
                    .tabItem {
                        Label("API", systemImage: "key.fill")
                    }

                ControlsSettingsTab(
                    settings: settings,
                    showingHotkeyRecorder: $showingHotkeyRecorder,
                    showingFinishHotkeyRecorder: $showingFinishHotkeyRecorder
                )
                .tabItem {
                    Label("Controls", systemImage: "command")
                }

                AboutTab()
                    .tabItem {
                        Label("About", systemImage: "info.circle")
                    }
            }
            .padding(.top, 8)

            // Bottom button bar
            Divider()

            HStack {
                Spacer()

                Button("Cancel") {
                    closeWindow()
                }
                .keyboardShortcut(.cancelAction)

                Button("Save") {
                    saveSettings()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .background(.thickMaterial)
        .sheet(isPresented: $showingHotkeyRecorder) {
            HotkeyRecorderView(
                currentHotkey: settings.globalHotkey,
                onSave: { newHotkey in
                    settings.globalHotkey = newHotkey
                    showingHotkeyRecorder = false

                    // Update the global hotkey registration
                    if let appDelegate = NSApp.delegate as? AppDelegate {
                        appDelegate.updateHotkey()
                    }
                },
                onCancel: {
                    showingHotkeyRecorder = false
                }
            )
        }
        .sheet(isPresented: $showingFinishHotkeyRecorder) {
            HotkeyRecorderView(
                currentHotkey: settings.finishHotkey,
                onSave: { newHotkey in
                    settings.finishHotkey = newHotkey
                    showingFinishHotkeyRecorder = false
                },
                onCancel: {
                    showingFinishHotkeyRecorder = false
                }
            )
        }
        .onAppear {
            // Load current settings
            tempAppKey = settings.appKey
            tempAccessKey = settings.accessKey
        }
    }

    private func saveSettings() {
        // Save settings
        settings.appKey = tempAppKey
        settings.accessKey = tempAccessKey

        // Update view model config
        viewModel.updateConfig(settings: settings)

        closeWindow()
    }

    private func closeWindow() {
        if let window = NSApp.keyWindow {
            window.close()
        }
    }
}

// MARK: - API Settings Tab

struct APISettingsTab: View {
    @Binding var appKey: String
    @Binding var accessKey: String

    var body: some View {
        Form {
            Section {
                TextField("App Key:", text: $appKey)
                    .textFieldStyle(.roundedBorder)

                SecureField("Access Key:", text: $accessKey)
                    .textFieldStyle(.roundedBorder)
            } header: {
                Text("Doubao API Credentials")
                    .font(.headline)
            } footer: {
                Text("Obtain credentials from the Doubao console at console.volcengine.com")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

// MARK: - Controls Settings Tab

struct ControlsSettingsTab: View {
    @ObservedObject var settings: AppSettings
    @Binding var showingHotkeyRecorder: Bool
    @Binding var showingFinishHotkeyRecorder: Bool

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Hotkey:")
                        .frame(width: 100, alignment: .trailing)

                    Text(settings.globalHotkey.displayString)
                        .font(.system(.body, design: .monospaced))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.thickMaterial)
                        .cornerRadius(6)

                    Button("Change...") {
                        showingHotkeyRecorder = true
                    }
                }
            } header: {
                Text("Global Hotkey")
                    .font(.headline)
            } footer: {
                Text("Press the hotkey to show/hide the transcription window")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section {
                HStack {
                    Text("Finish & Copy:")
                        .frame(width: 100, alignment: .trailing)

                    Text(settings.finishHotkey.displayString)
                        .font(.system(.body, design: .monospaced))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.thickMaterial)
                        .cornerRadius(6)

                    Button("Change...") {
                        showingFinishHotkeyRecorder = true
                    }
                }
            } header: {
                Text("Window Hotkey")
                    .font(.headline)
            } footer: {
                Text("Press this key to finish recording and copy text (only works when window is active)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section {
                Toggle("Enable Voice Activity Detection", isOn: $settings.enableVAD)
            } header: {
                Text("Recording")
                    .font(.headline)
            } footer: {
                Text("VAD automatically detects when you start and stop speaking")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section {
                Toggle("Auto-paste after finish", isOn: $settings.autoPasteAfterClose)
                Toggle("Remove trailing punctuation", isOn: $settings.removeTrailingPunctuation)
            } header: {
                Text("Behavior")
                    .font(.headline)
            } footer: {
                Text("Automatically paste transcribed text into the previous application when using the finish action. Remove trailing punctuation removes both full-width (。！？) and half-width (. ! ?) punctuation marks from the end of the transcribed text.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section {
                HStack {
                    Text("Window position:")
                        .frame(width: 120, alignment: .trailing)

                    Picker("", selection: $settings.windowPositionMode) {
                        ForEach(WindowPositionMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 200)

                    Spacer()
                }
            } header: {
                Text("Window Appearance")
                    .font(.headline)
            } footer: {
                Text("Choose where the transcription window appears: Remember Last Position keeps it where you last placed it, Near Mouse Cursor opens it near your cursor, Top/Bottom of Screen centers it at the screen edge.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

// MARK: - About Tab

struct AboutTab: View {
    private let appName = Bundle.main.infoDictionary?["CFBundleName"] as? String ?? "DoubaoVoice"
    private let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 64))
                .foregroundColor(.accentColor)

            Text(appName)
                .font(.title)
                .fontWeight(.semibold)

            Text("Version \(appVersion)")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Text("Real-time speech-to-text transcription using the Doubao ASR API")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Hotkey Recorder View

struct HotkeyRecorderView: View {
    let currentHotkey: HotkeyConfig
    let onSave: (HotkeyConfig) -> Void
    let onCancel: () -> Void

    @State private var recordedKeyCode: UInt32?
    @State private var recordedModifiers: UInt32 = 0
    @State private var isRecording = false

    var body: some View {
        VStack(spacing: 20) {
            Text("Press a Hotkey")
                .font(.headline)

            Text("Press a key combination to set as the global hotkey")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            // Display current/recorded hotkey
            HStack {
                if isRecording {
                    Text(recordedDisplayString)
                        .font(.system(.title2, design: .monospaced))
                        .foregroundColor(.accentColor)
                } else {
                    Text(currentHotkey.displayString)
                        .font(.system(.title2, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
            .frame(minWidth: 150, minHeight: 60)
            .frame(maxWidth: .infinity)
            .background(.thickMaterial)
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isRecording ? Color.accentColor : Color.clear, lineWidth: 2)
            )

            if !isRecording {
                Button("Start Recording") {
                    startRecording()
                }
            } else {
                Text("Waiting for key press...")
                    .font(.caption)
                    .foregroundColor(.accentColor)
            }

            Divider()

            HStack {
                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Save") {
                    if let keyCode = recordedKeyCode {
                        let newHotkey = HotkeyConfig(keyCode: keyCode, modifiers: recordedModifiers)
                        onSave(newHotkey)
                    } else {
                        onCancel()
                    }
                }
                .disabled(recordedKeyCode == nil)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(30)
        .frame(width: 350, height: 280)
        .background(HotkeyRecorderRepresentable(
            isRecording: $isRecording,
            recordedKeyCode: $recordedKeyCode,
            recordedModifiers: $recordedModifiers
        ))
    }

    private var recordedDisplayString: String {
        guard let keyCode = recordedKeyCode else {
            return "Press a key..."
        }

        let tempHotkey = HotkeyConfig(keyCode: keyCode, modifiers: recordedModifiers)
        return tempHotkey.displayString
    }

    private func startRecording() {
        isRecording = true
        recordedKeyCode = nil
        recordedModifiers = 0
    }
}

// MARK: - Hotkey Recorder NSView Representable

struct HotkeyRecorderRepresentable: NSViewRepresentable {
    @Binding var isRecording: Bool
    @Binding var recordedKeyCode: UInt32?
    @Binding var recordedModifiers: UInt32

    func makeNSView(context: Context) -> HotkeyRecorderNSView {
        let view = HotkeyRecorderNSView()
        view.onKeyPress = { keyCode, modifiers in
            recordedKeyCode = keyCode
            recordedModifiers = modifiers
            isRecording = false
        }
        return view
    }

    func updateNSView(_ nsView: HotkeyRecorderNSView, context: Context) {
        nsView.isRecording = isRecording
    }
}

// MARK: - Hotkey Recorder NSView

class HotkeyRecorderNSView: NSView {
    var onKeyPress: ((UInt32, UInt32) -> Void)?
    var isRecording = false

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }

        let keyCode = UInt32(event.keyCode)
        var modifiers: UInt32 = 0

        let flags = event.modifierFlags

        if flags.contains(.command) {
            modifiers |= UInt32(cmdKey)
        }
        if flags.contains(.option) {
            modifiers |= UInt32(optionKey)
        }
        if flags.contains(.shift) {
            modifiers |= UInt32(shiftKey)
        }
        if flags.contains(.control) {
            modifiers |= UInt32(controlKey)
        }

        // For finish hotkey (Enter key), allow no modifiers (local scope)
        // For global hotkeys, require at least one modifier
        guard modifiers != 0 || keyCode == 36 else {
            NSSound.beep()
            return
        }

        onKeyPress?(keyCode, modifiers)
    }

    override func flagsChanged(with event: NSEvent) {
        // Don't call super to prevent default behavior
    }
}

#Preview {
    SettingsView()
        .frame(width: 550, height: 500)
}
