//
//  AppDelegate.swift
//  DoubaoVoice
//
//  Core app coordinator for menu bar app with global hotkey
//

import Cocoa
import SwiftUI
import Carbon

class AppDelegate: NSObject, NSApplicationDelegate {
    // MARK: - Properties

    private var statusItem: NSStatusItem!
    private var floatingWindowController: FloatingWindowController?
    private var settingsWindowController: SettingsWindowController?
    private var hotkeyManager: GlobalHotkeyManager?
    private let viewModel = TranscriptionViewModel.shared
    private let settings = AppSettings.shared

    // MARK: - Application Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Set activation policy to accessory (no dock icon)
        NSApp.setActivationPolicy(.accessory)

        // Setup menu bar icon
        setupStatusItem()

        // Setup global hotkey
        setupHotkey()

        // Observe hotkey changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleHotkeyChanged),
            name: .globalHotkeyChanged,
            object: nil
        )

        log(.info, "DoubaoVoice menu bar app launched")
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Cleanup hotkey
        hotkeyManager?.unregister()
    }

    // MARK: - Status Bar Setup

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "DoubaoVoice")
            button.image?.isTemplate = true
        }

        // Create menu
        let menu = NSMenu()

        menu.addItem(NSMenuItem(title: "Show Window", action: #selector(showWindow), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))

        statusItem.menu = menu

        // Update icon color based on recording state
        observeRecordingState()
    }

    private func observeRecordingState() {
        // Observe the recording state and update icon color
        Task { @MainActor in
            for await _ in NotificationCenter.default.notifications(named: .recordingStateChanged).map({ _ in }) {
                updateStatusIcon()
            }
        }
    }

    @MainActor
    private func updateStatusIcon() {
        guard let button = statusItem.button else { return }

        if viewModel.isRecording {
            button.image = NSImage(systemSymbolName: "mic.circle.fill", accessibilityDescription: "Recording")
            button.contentTintColor = .systemRed
        } else {
            button.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "DoubaoVoice")
            button.contentTintColor = nil
        }
    }

    // MARK: - Global Hotkey Setup

    private func setupHotkey() {
        // Don't register if hotkey is unset
        guard !settings.globalHotkey.isUnset else {
            log(.warning, "Global hotkey is unset, skipping registration")
            return
        }

        hotkeyManager = GlobalHotkeyManager(
            keyCode: settings.globalHotkey.keyCode,
            modifiers: settings.globalHotkey.modifiers
        ) { [weak self] in
            Task { @MainActor in
                self?.toggleWindow()
            }
        }

        hotkeyManager?.register()
        log(.info, "Global hotkey registered: \(settings.globalHotkey.displayString)")
    }

    @objc private func handleHotkeyChanged() {
        print("🔔 Received globalHotkeyChanged notification")
        print("🔄 Updating hotkey...")
        log(.info, "Updating global hotkey...")

        if hotkeyManager != nil {
            print("🔄 Unregistering old hotkey")
            hotkeyManager?.unregister()
            hotkeyManager = nil
        }

        print("🔄 Setting up new hotkey: \(settings.globalHotkey.displayString)")
        setupHotkey()
        log(.info, "Global hotkey updated to: \(settings.globalHotkey.displayString)")
        print("✅ Hotkey update complete")
    }

    // MARK: - Window Management

    @MainActor
    @objc private func showWindow() {
        log(.debug, "showWindow() called")
        if floatingWindowController == nil {
            log(.debug, "Creating new FloatingWindowController")
            floatingWindowController = FloatingWindowController()
            log(.debug, "FloatingWindowController created: \(floatingWindowController != nil)")
        }
        log(.debug, "Calling showWindow on controller")
        floatingWindowController?.showWindow(nil)
        log(.debug, "showWindow() completed")
    }

    @MainActor
    @objc private func toggleWindow() {
        if let controller = floatingWindowController, controller.window?.isVisible == true {
            controller.hideWindow()
        } else {
            showWindow()
        }
    }

    @MainActor
    @objc private func openSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController()
        }
        settingsWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

// MARK: - Global Hotkey Manager

class GlobalHotkeyManager {
    private var hotKeyRef: EventHotKeyRef?
    private let keyCode: UInt32
    private let modifiers: UInt32
    private let callback: () -> Void
    private var eventHandler: EventHandlerRef?

    init(keyCode: UInt32, modifiers: UInt32, callback: @escaping () -> Void) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.callback = callback
    }

    deinit {
        unregister()
    }

    func register() {
        guard hotKeyRef == nil else {
            log(.warning, "Hotkey already registered")
            return
        }

        // Convert modifiers to Carbon format
        var carbonModifiers: UInt32 = 0
        if modifiers & UInt32(cmdKey) != 0 {
            carbonModifiers |= UInt32(cmdKey)
        }
        if modifiers & UInt32(optionKey) != 0 {
            carbonModifiers |= UInt32(optionKey)
        }
        if modifiers & UInt32(shiftKey) != 0 {
            carbonModifiers |= UInt32(shiftKey)
        }
        if modifiers & UInt32(controlKey) != 0 {
            carbonModifiers |= UInt32(controlKey)
        }

        // Create hotkey ID
        var hotKeyID = EventHotKeyID(signature: OSType("DBVC".fourCharCode), id: 1)

        // Install event handler
        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))

        let callback: EventHandlerUPP = { (nextHandler, theEvent, userData) -> OSStatus in
            guard let userData = userData else { return OSStatus(eventNotHandledErr) }
            let manager = Unmanaged<GlobalHotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            manager.callback()
            return noErr
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &eventSpec,
            selfPtr,
            &eventHandler
        )

        guard status == noErr else {
            log(.error, "Failed to install hotkey event handler: \(status)")
            return
        }

        // Register hotkey
        let registerStatus = RegisterEventHotKey(
            keyCode,
            carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        if registerStatus == noErr {
            log(.info, "Hotkey registered successfully")
        } else {
            log(.error, "Failed to register hotkey: \(registerStatus)")
        }
    }

    func unregister() {
        if let hotKeyRef = hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
            log(.info, "Hotkey unregistered")
        }

        if let eventHandler = eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }
}

// MARK: - String Extension for FourCC

extension String {
    var fourCharCode: FourCharCode {
        assert(self.count == 4, "String must be exactly 4 characters")
        var result: FourCharCode = 0
        for char in self.utf8 {
            result = (result << 8) + FourCharCode(char)
        }
        return result
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let recordingStateChanged = Notification.Name("recordingStateChanged")
    static let globalHotkeyChanged = Notification.Name("globalHotkeyChanged")
}
