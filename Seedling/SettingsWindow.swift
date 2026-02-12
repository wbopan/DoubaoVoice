//
//  SettingsWindow.swift
//  Seedling
//
//  Settings panel with API configuration and hotkey recorder
//

import Cocoa
import SwiftUI
import Carbon
import LaunchAtLogin
import KeyboardShortcuts

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
    @State private var tempContext = ""

    var body: some View {
        VStack(spacing: 0) {
            // Tabbed interface
            TabView {
                APISettingsTab(appKey: $tempAppKey, accessKey: $tempAccessKey)
                    .tabItem {
                        Label("API", systemImage: "key.fill")
                    }

                ContextSettingsTab(context: $tempContext)
                    .tabItem {
                        Label("Context", systemImage: "text.bubble")
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
            tempContext = settings.context
        }
        .onChange(of: settings.context) { _, newValue in
            // Sync tempContext when settings.context is updated externally (e.g., by context capture)
            tempContext = newValue
        }
    }

    private func saveSettings() {
        // Save settings
        settings.appKey = tempAppKey
        settings.accessKey = tempAccessKey
        settings.context = tempContext

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
                Text("Seed ASR Credentials")
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

// MARK: - Context Settings Tab

struct ContextSettingsTab: View {
    @Binding var context: String
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Provide persistent context that always applies. This has priority over auto-captured content.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    TextEditor(text: $context)
                        .font(.system(.body))
                        .frame(height: 100)
                        .scrollContentBackground(.hidden)
                        .background(Color(NSColor.textBackgroundColor).opacity(0.5))
                        .cornerRadius(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                        )

                    // Character count
                    HStack {
                        Spacer()
                        Text("\(context.count) / \(settings.maxContextLength)")
                            .font(.caption2)
                            .foregroundColor(context.count > settings.maxContextLength ? .red : .secondary)
                    }
                }
            } header: {
                Text("User Context")
                    .font(.headline)
            }

            ContextCaptureSection(settings: settings)
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

// MARK: - Context Capture Section

struct ContextCaptureSection: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject private var viewModel = TranscriptionViewModel.shared
    @State private var hasAccessibilityPermission = false

    var body: some View {
        Section {
            Toggle("Enable context capture", isOn: $settings.contextCaptureEnabled.animation())
                .onChange(of: settings.contextCaptureEnabled) { _, newValue in
                    if newValue {
                        _ = AccessibilityTextCapture.shared.checkPermission(prompt: true)
                        updateAccessibilityStatus()
                    }
                }

            if settings.contextCaptureEnabled {
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
                    Text("Max context length:")

                    Spacer()

                    Picker("", selection: $settings.maxContextLength) {
                        Text("500").tag(500)
                        Text("1000").tag(1000)
                        Text("2000").tag(2000)
                        Text("5000").tag(5000)
                    }
                    .labelsHidden()
                    .frame(width: 100)
                }

                // Read-only auto-captured context display
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Auto-captured Context")
                            .font(.caption)
                            .fontWeight(.medium)
                        if !viewModel.capturedContextSource.isEmpty {
                            Text("from \(viewModel.capturedContextSource)")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Text("\(viewModel.capturedContextText.count) chars")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }

                    if viewModel.capturedContextText.isEmpty {
                        Text("No context captured yet. Use the shortcut to activate and capture context from another app.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .italic()
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(NSColor.textBackgroundColor).opacity(0.3))
                            .cornerRadius(6)
                    } else {
                        // Read-only text display
                        ScrollView {
                            Text(viewModel.capturedContextText)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(height: 120)
                        .padding(8)
                        .background(Color(NSColor.textBackgroundColor).opacity(0.3))
                        .cornerRadius(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                        )
                    }
                }
            }
        } header: {
            Text("Auto Context Capture")
                .font(.headline)
        } footer: {
            Text("When enabled, text from the previous application is captured on each activation and appended after your user context (up to the max length limit).")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .onAppear {
            updateAccessibilityStatus()
        }
    }

    private func updateAccessibilityStatus() {
        hasAccessibilityPermission = AccessibilityTextCapture.shared.checkPermission(prompt: false)
    }

    private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Controls Settings Tab

struct ControlsSettingsTab: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject private var deviceManager = AudioDeviceManager.shared

    var body: some View {
        Form {
            Section {
                LaunchAtLogin.Toggle("Launch at login")
            } header: {
                Text("General")
                    .font(.headline)
            }

            Section {
                Picker("Microphone:", selection: $settings.selectedMicrophoneUID) {
                    Text("System Default").tag("")
                    ForEach(deviceManager.inputDevices) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
            } header: {
                Text("Microphone")
                    .font(.headline)
            } footer: {
                Text("Changes take effect on next recording.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section {
                HStack {
                    Text("Shortcut:")
                    Spacer()
                    KeyboardShortcuts.Recorder("", name: .toggleWindow)
                        .fixedSize()
                }
            } header: {
                Text("Global Shortcut")
                    .font(.headline)
            } footer: {
                Text("Show or hide the transcription window")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if settings.floatingWindowMode == .fullWindow {
                Section {
                    HStack {
                        Text("Done:")
                            .fixedSize()
                        Spacer()
                        KeyboardShortcuts.Recorder("", name: .finishRecording)
                            .fixedSize()
                    }
                } header: {
                    Text("Window Shortcut")
                        .font(.headline)
                } footer: {
                    Text("Finish dictation and copy text to clipboard. Only works when the window is focused.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            PushToTalkSection(settings: settings)

            if settings.floatingWindowMode == .fullWindow {
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
            } else {
                Section {
                    Toggle("Remove trailing punctuation", isOn: $settings.removeTrailingPunctuation)
                } header: {
                    Text("Behavior")
                        .font(.headline)
                }
            }

            Section {
                Picker("Window mode:", selection: $settings.floatingWindowMode) {
                    ForEach(FloatingWindowMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }

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
                Text("Appearance")
                    .font(.headline)
            } footer: {
                Text("Choose where the window appears. You can also drag to reposition.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

// MARK: - Push to Talk Section

struct PushToTalkSection: View {
    @ObservedObject var settings: AppSettings
    @State private var hasAccessibilityPermission = false

    var body: some View {
        Section {
            Toggle("Enable Push to Talk", isOn: configBinding(\.enabled, onSet: { newValue in
                if newValue {
                    _ = ModifierKeyMonitor.checkAccessibilityPermission(prompt: true)
                    updateAccessibilityStatus()
                }
            }))

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

                    Picker("", selection: configBinding(\.modifierKey)) {
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
                        value: configBinding(\.minimumPressDuration),
                        in: 0.1...1.0,
                        step: 0.1
                    )

                    Text(String(format: "%.1fs", settings.longPressConfig.minimumPressDuration))
                        .frame(width: 40)
                        .monospacedDigit()
                }
            }
        } header: {
            Text("Push to Talk")
                .font(.headline)
        } footer: {
            Text("Double-tap a modifier key and hold to start dictation. Release to finish and auto-paste. Requires Accessibility permission.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .onAppear {
            updateAccessibilityStatus()
        }
    }

    /// Create a binding to a LongPressConfig property with optional side effect
    private func configBinding<T>(_ keyPath: WritableKeyPath<LongPressConfig, T>, onSet: ((T) -> Void)? = nil) -> Binding<T> {
        Binding(
            get: { settings.longPressConfig[keyPath: keyPath] },
            set: { newValue in
                var config = settings.longPressConfig
                config[keyPath: keyPath] = newValue
                settings.longPressConfig = config
                onSet?(newValue)
            }
        )
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
    private let appName = Bundle.main.infoDictionary?["CFBundleName"] as? String ?? "Seedling"
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

            Text("Real-time speech-to-text transcription using the Seed ASR API")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    SettingsView()
        .frame(width: 550, height: 500)
}
