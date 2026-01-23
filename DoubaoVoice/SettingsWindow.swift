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

                ControlsSettingsTab(settings: settings)
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
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("How to get credentials:")
                        .fontWeight(.medium)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("1. Open the Volcengine Speech Console")
                        Text("2. Select \"旧版控制台\" (Legacy Console) in the upper left")
                        Text("3. Navigate to \"语音识别大模型\" → \"流式语音识别大模型\"")
                        Text("4. Copy your App ID and Access Token")
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)

                    Button {
                        if let url = URL(string: "https://console.volcengine.com/speech/app") {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        HStack {
                            Image(systemName: "arrow.up.right.square")
                            Text("Open Volcengine Console")
                        }
                    }
                    .buttonStyle(.link)
                }
            } header: {
                Text("Setup Guide")
                    .font(.headline)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

// MARK: - Controls Settings Tab

struct ControlsSettingsTab: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Hotkey:")

                    Spacer()

                    HotkeyInputCapsule(
                        hotkey: Binding(
                            get: { settings.globalHotkey },
                            set: { newValue in
                                print("🔧 Hotkey changed to: \(newValue.displayString)")
                                settings.globalHotkey = newValue
                                print("🔧 Settings updated (notification will be posted via didSet)")
                            }
                        ),
                        requireModifiers: true
                    )
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

                    Spacer()

                    HotkeyInputCapsule(
                        hotkey: Binding(
                            get: { settings.finishHotkey },
                            set: { settings.finishHotkey = $0 }
                        ),
                        requireModifiers: false
                    )
                }
            } header: {
                Text("Window Hotkey")
                    .font(.headline)
            } footer: {
                Text("Press this key to finish recording and copy text (only works when window is active)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            DoubleTapHoldModifierSection(settings: settings)

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

// MARK: - Double-Tap-and-Hold Modifier Section

struct DoubleTapHoldModifierSection: View {
    @ObservedObject var settings: AppSettings
    @State private var hasAccessibilityPermission = false

    var body: some View {
        Section {
            Toggle("Enable double-tap-and-hold", isOn: Binding(
                get: { settings.longPressConfig.enabled },
                set: { newValue in
                    var config = settings.longPressConfig
                    config.enabled = newValue
                    settings.longPressConfig = config

                    // Prompt for accessibility permission when enabling
                    if newValue {
                        _ = ModifierKeyMonitor.checkAccessibilityPermission(prompt: true)
                        updateAccessibilityStatus()
                    }
                }
            ))

            if settings.longPressConfig.enabled {
                // Accessibility permission status
                HStack {
                    Image(systemName: hasAccessibilityPermission ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundColor(hasAccessibilityPermission ? .green : .orange)

                    Text(hasAccessibilityPermission ? "Accessibility permission granted" : "Accessibility permission required")
                        .font(.caption)

                    Spacer()

                    if !hasAccessibilityPermission {
                        Button("Open Settings") {
                            openAccessibilitySettings()
                        }
                        .font(.caption)
                    }
                }

                HStack {
                    Text("Modifier key:")

                    Spacer()

                    Picker("", selection: Binding(
                        get: { settings.longPressConfig.modifierKey },
                        set: { newValue in
                            var config = settings.longPressConfig
                            config.modifierKey = newValue
                            settings.longPressConfig = config
                        }
                    )) {
                        ForEach(LongPressModifierKey.allCases, id: \.self) { key in
                            Text("\(key.symbol) \(key.displayName)").tag(key)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                }

                HStack {
                    Text("Hold duration:")

                    Slider(
                        value: Binding(
                            get: { settings.longPressConfig.minimumPressDuration },
                            set: { newValue in
                                var config = settings.longPressConfig
                                config.minimumPressDuration = newValue
                                settings.longPressConfig = config
                            }
                        ),
                        in: 0.1...1.0,
                        step: 0.1
                    )

                    Text(String(format: "%.1fs", settings.longPressConfig.minimumPressDuration))
                        .frame(width: 40)
                        .monospacedDigit()
                }

                Toggle("Auto-submit on release", isOn: Binding(
                    get: { settings.longPressConfig.autoSubmitOnRelease },
                    set: { newValue in
                        var config = settings.longPressConfig
                        config.autoSubmitOnRelease = newValue
                        settings.longPressConfig = config
                    }
                ))
            }
        } header: {
            Text("Double-Tap-and-Hold")
                .font(.headline)
        } footer: {
            Text("Double-tap the modifier key and hold on the second tap to start recording. Release to finish and auto-paste. This feature requires Accessibility permission.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .onAppear {
            updateAccessibilityStatus()
        }
    }

    private func updateAccessibilityStatus() {
        hasAccessibilityPermission = ModifierKeyMonitor.checkAccessibilityPermission(prompt: false)
    }

    private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
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

// MARK: - Hotkey Input Capsule

struct HotkeyInputCapsule: View {
    @Binding var hotkey: HotkeyConfig
    var requireModifiers: Bool = true

    @State private var isRecording = false
    @State private var recordedKeyCode: UInt32?
    @State private var recordedModifiers: UInt32 = 0
    @State private var recordingViewID = UUID()

    var body: some View {
        // Display text (centered)
        Group {
            if isRecording {
                Text(recordedDisplayString)
                    .font(.system(.body, design: .monospaced))
                    .tracking(1.5)
                    .foregroundColor(.accentColor)
                    .lineLimit(1)
            } else {
                Text(displayText)
                    .font(.system(.body, design: .monospaced))
                    .tracking(1.5)
                    .foregroundColor(hotkey.isUnset ? .secondary : .primary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity) // Center the text
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(width: 130, alignment: .center) // 30% longer than 100
        .background(.thickMaterial)
        .cornerRadius(20)
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(isRecording ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            handleTap()
        }
        .background(
            HotkeyRecorderBackgroundView(
                isRecording: $isRecording,
                recordedKeyCode: $recordedKeyCode,
                recordedModifiers: $recordedModifiers,
                requireModifiers: requireModifiers,
                onRecorded: { keyCode, modifiers in
                    hotkey = HotkeyConfig(keyCode: keyCode, modifiers: modifiers)
                    isRecording = false
                },
                viewID: recordingViewID
            )
        )
    }

    private var displayText: String {
        // Check if hotkey is "unset" (using a sentinel value or default)
        // For now, we'll just display the current hotkey
        return hotkey.displayString
    }

    private var recordedDisplayString: String {
        guard let keyCode = recordedKeyCode else {
            return "Listening..."
        }

        let tempHotkey = HotkeyConfig(keyCode: keyCode, modifiers: recordedModifiers)
        return tempHotkey.displayString
    }

    private func handleTap() {
        // If already recording, do nothing (let keyboard handler process)
        if isRecording {
            return
        }

        // If hotkey is set, clear it on first click
        if !hotkey.isUnset {
            hotkey = HotkeyConfig.unset
        } else {
            // If hotkey is not set, start recording on click
            startRecording()
        }
    }

    private func startRecording() {
        isRecording = true
        recordedKeyCode = nil
        recordedModifiers = 0
        // Force view ID change to recreate the background view and regain focus
        recordingViewID = UUID()
    }
}

// MARK: - Hotkey Recorder Background View

struct HotkeyRecorderBackgroundView: NSViewRepresentable {
    @Binding var isRecording: Bool
    @Binding var recordedKeyCode: UInt32?
    @Binding var recordedModifiers: UInt32
    var requireModifiers: Bool
    var onRecorded: (UInt32, UInt32) -> Void
    var viewID: UUID

    func makeNSView(context: Context) -> HotkeyRecorderBackgroundNSView {
        let view = HotkeyRecorderBackgroundNSView()
        view.requireModifiers = requireModifiers
        view.onKeyPress = { keyCode, modifiers in
            recordedKeyCode = keyCode
            recordedModifiers = modifiers
            onRecorded(keyCode, modifiers)
        }
        return view
    }

    func updateNSView(_ nsView: HotkeyRecorderBackgroundNSView, context: Context) {
        nsView.isRecording = isRecording
        nsView.requireModifiers = requireModifiers

        // When recording starts, request focus
        if isRecording {
            DispatchQueue.main.async {
                nsView.window?.makeFirstResponder(nsView)
            }
        }
    }
}

// MARK: - Hotkey Recorder Background NSView

class HotkeyRecorderBackgroundNSView: NSView {
    var onKeyPress: ((UInt32, UInt32) -> Void)?
    var isRecording = false {
        didSet {
            if isRecording {
                // Request focus when recording starts
                DispatchQueue.main.async { [weak self] in
                    self?.window?.makeFirstResponder(self)
                }
            }
        }
    }
    var requireModifiers = true

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        return true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil && isRecording {
            DispatchQueue.main.async { [weak self] in
                self?.window?.makeFirstResponder(self)
            }
        }
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }

        let keyCode = UInt32(event.keyCode)

        // Escape key (keyCode 53) cancels recording
        if keyCode == 53 {
            // Don't call onKeyPress, just let recording be cancelled by not saving
            return
        }

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
        if requireModifiers && modifiers == 0 && keyCode != 36 {
            NSSound.beep()
            return
        }

        onKeyPress?(keyCode, modifiers)
    }

    override func flagsChanged(with event: NSEvent) {
        // Don't call super to prevent default behavior
    }

    override func mouseDown(with event: NSEvent) {
        // Capture mouse down to gain first responder status
        if !isRecording {
            super.mouseDown(with: event)
        } else {
            window?.makeFirstResponder(self)
        }
    }
}

#Preview {
    SettingsView()
        .frame(width: 550, height: 500)
}
