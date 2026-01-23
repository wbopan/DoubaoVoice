//
//  AppDelegate.swift
//  DoubaoVoice
//
//  Core app coordinator for menu bar app with global hotkey
//

import Cocoa
import SwiftUI
import Carbon
import OSLog

class AppDelegate: NSObject, NSApplicationDelegate {
    // MARK: - Properties

    private var statusItem: NSStatusItem!
    private var floatingWindowController: FloatingWindowController?
    private var settingsWindowController: SettingsWindowController?
    private var hotkeyManager: GlobalHotkeyManager?
    private var modifierKeyMonitor: ModifierKeyMonitor?
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

        // Setup long-press modifier key monitor
        setupLongPressMonitor()

        // Observe hotkey changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleHotkeyChanged),
            name: .globalHotkeyChanged,
            object: nil
        )

        // Observe long-press config changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleLongPressConfigChanged),
            name: .longPressConfigChanged,
            object: nil
        )

        log(.info, "DoubaoVoice menu bar app launched")
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Cleanup hotkey
        hotkeyManager?.unregister()
        // Cleanup long-press monitor
        modifierKeyMonitor?.stop()
    }

    // MARK: - Status Bar Setup

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "waveform.circle.fill", accessibilityDescription: "DoubaoVoice")
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

    // MARK: - Long-Press Modifier Key Setup

    private func setupLongPressMonitor() {
        // Stop existing monitor if any
        modifierKeyMonitor?.stop()
        modifierKeyMonitor = nil

        let config = settings.longPressConfig
        guard config.enabled else {
            log(.info, "Long-press modifier key is disabled")
            return
        }

        log(.info, "Setting up long-press monitor for \(config.modifierKey.displayName) key")

        modifierKeyMonitor = ModifierKeyMonitor(
            modifierKey: config.modifierKey,
            minimumDuration: config.minimumPressDuration,
            onActivate: { [weak self] in
                Task { @MainActor in
                    self?.handleLongPressActivate()
                }
            },
            onRelease: { [weak self] in
                Task { @MainActor in
                    self?.handleLongPressRelease()
                }
            }
        )

        modifierKeyMonitor?.start()
        log(.info, "Long-press monitor started for \(config.modifierKey.symbol) key")
    }

    @objc private func handleLongPressConfigChanged() {
        log(.info, "Long-press config changed, updating monitor...")
        setupLongPressMonitor()
    }

    @MainActor
    private func handleLongPressActivate() {
        log(.info, "Long-press activated, showing window and starting recording")
        showWindow()
    }

    @MainActor
    private func handleLongPressRelease() {
        guard settings.longPressConfig.autoSubmitOnRelease else {
            log(.debug, "Auto-submit on release is disabled, ignoring release")
            return
        }

        // Check if we have a visible window
        guard let controller = floatingWindowController,
              controller.window?.isVisible == true else {
            log(.debug, "No visible window, ignoring release")
            return
        }

        if viewModel.transcribedText.isEmpty {
            // No text - just close the window
            log(.info, "Long-press released with no text, closing window")
            controller.hideWindow()
        } else {
            // Has text - trigger finish recording (submit and close)
            log(.info, "Long-press released with text, triggering finish recording")
            NotificationCenter.default.post(name: .finishRecordingRequested, object: nil)
        }
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
        let hotKeyID = EventHotKeyID(signature: OSType("DBVC".fourCharCode), id: 1)

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

// MARK: - Modifier Key Monitor

/// Monitors global modifier key press/release events for long-press activation
/// Requires Accessibility permission to work
class ModifierKeyMonitor {
    private let modifierKey: LongPressModifierKey
    private let minimumDuration: TimeInterval
    private let onActivate: () -> Void
    private let onRelease: () -> Void

    private var globalEventMonitor: Any?
    private var localEventMonitor: Any?
    private var pressStartTime: Date?
    private var isActivated = false
    private var lastReleaseTime: Date?
    private let debounceInterval: TimeInterval = 0.5

    private let logger = Logger.hotkey

    init(modifierKey: LongPressModifierKey,
         minimumDuration: TimeInterval,
         onActivate: @escaping () -> Void,
         onRelease: @escaping () -> Void) {
        self.modifierKey = modifierKey
        self.minimumDuration = minimumDuration
        self.onActivate = onActivate
        self.onRelease = onRelease
    }

    deinit {
        stop()
    }

    func start() {
        stop() // Ensure no duplicate monitors

        logger.info("Starting modifier key monitor for \(self.modifierKey.displayName)")

        // Global monitor - captures events sent to OTHER applications
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event, source: "global")
        }

        // Local monitor - captures events sent to OUR application
        // This is crucial because when our window is shown and focused,
        // global monitor won't receive the key release event
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event, source: "local")
            return event // Pass the event through
        }

        if globalEventMonitor == nil {
            logger.error("Failed to create global event monitor - check Accessibility permission")
        }
        if localEventMonitor == nil {
            logger.error("Failed to create local event monitor")
        }
    }

    func stop() {
        if let monitor = globalEventMonitor {
            NSEvent.removeMonitor(monitor)
            globalEventMonitor = nil
        }
        if let monitor = localEventMonitor {
            NSEvent.removeMonitor(monitor)
            localEventMonitor = nil
        }
        logger.info("Modifier key monitor stopped")
        pressStartTime = nil
        isActivated = false
    }

    private func handleFlagsChanged(_ event: NSEvent, source: String) {
        let flags = event.modifierFlags

        // Check if ONLY our target modifier is pressed (ignore combos)
        let targetFlag = modifierKey.modifierFlag
        let otherModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift, .function]
            .filter { $0 != targetFlag }
            .reduce(NSEvent.ModifierFlags()) { $0.union($1) }

        let isTargetPressed = flags.contains(targetFlag)
        let hasOtherModifiers = !flags.intersection(otherModifiers).isEmpty

        logger.debug("[\(source)] flagsChanged: target=\(isTargetPressed), otherMods=\(hasOtherModifiers), isActivated=\(self.isActivated), pressStartTime=\(self.pressStartTime != nil)")

        // If other modifiers are pressed, abort any pending activation
        if hasOtherModifiers {
            if pressStartTime != nil {
                logger.debug("[\(source)] Other modifier detected, aborting activation")
                pressStartTime = nil
                isActivated = false
            }
            return
        }

        if isTargetPressed && pressStartTime == nil {
            // Modifier key pressed - start timer
            // Check debounce
            if let lastRelease = lastReleaseTime,
               Date().timeIntervalSince(lastRelease) < debounceInterval {
                logger.debug("[\(source)] Debounce active, ignoring press")
                return
            }

            logger.debug("[\(source)] \(self.modifierKey.symbol) pressed, starting timer")
            pressStartTime = Date()

            // Schedule activation check after minimum duration
            DispatchQueue.main.asyncAfter(deadline: .now() + minimumDuration) { [weak self] in
                self?.checkActivation()
            }

        } else if !isTargetPressed && pressStartTime != nil {
            // Modifier key released
            let pressDuration = pressStartTime.map { Date().timeIntervalSince($0) } ?? 0
            logger.debug("[\(source)] \(self.modifierKey.symbol) released after \(String(format: "%.2f", pressDuration))s, isActivated=\(self.isActivated)")

            if isActivated {
                // Was activated - trigger release callback
                logger.info("[\(source)] Long-press release detected, triggering callback")
                lastReleaseTime = Date()
                onRelease()
            } else {
                // Released before activation threshold - just a quick tap
                logger.debug("[\(source)] Released before threshold, ignoring")
            }

            pressStartTime = nil
            isActivated = false
        } else if !isTargetPressed && pressStartTime == nil && isActivated {
            // Edge case: release detected but pressStartTime was already cleared
            logger.warning("[\(source)] Release detected but pressStartTime is nil, isActivated=\(self.isActivated)")
        }
    }

    private func checkActivation() {
        // Verify the key is still pressed and enough time has passed
        guard let startTime = pressStartTime else {
            return
        }

        let elapsed = Date().timeIntervalSince(startTime)
        guard elapsed >= minimumDuration else {
            return
        }

        // Check if modifier is still pressed
        let currentFlags = NSEvent.modifierFlags
        guard currentFlags.contains(modifierKey.modifierFlag) else {
            logger.debug("Modifier released before activation")
            return
        }

        // Activate
        logger.info("Long-press threshold reached, activating")
        isActivated = true
        onActivate()
    }

    /// Check if Accessibility permission is granted
    static func checkAccessibilityPermission(prompt: Bool = false) -> Bool {
        let options: [String: Any]
        if prompt {
            options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        } else {
            options = [:]
        }
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let recordingStateChanged = Notification.Name("recordingStateChanged")
    static let globalHotkeyChanged = Notification.Name("globalHotkeyChanged")
    static let longPressConfigChanged = Notification.Name("longPressConfigChanged")
}
