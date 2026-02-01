//
//  AppDelegate.swift
//  Seedling
//
//  Core app coordinator for menu bar app with global hotkey
//

import Cocoa
import SwiftUI
import Carbon
import OSLog
import KeyboardShortcuts

class AppDelegate: NSObject, NSApplicationDelegate {
    // MARK: - Properties

    private var statusItem: NSStatusItem!
    private var floatingWindowController: FloatingWindowController?
    private var settingsWindowController: SettingsWindowController?
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

        // Setup double-tap-and-hold modifier key monitor
        setupDoubleTapHoldMonitor()

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

        log(.info, "Seedling menu bar app launched")
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Cleanup long-press monitor
        modifierKeyMonitor?.stop()
    }

    // MARK: - Status Bar Setup

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "waveform.circle.fill", accessibilityDescription: "Seedling")
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
        // Migrate legacy settings on first run
        AppSettings.migrateHotkeyIfNeeded()

        KeyboardShortcuts.onKeyUp(for: .toggleWindow) { [weak self] in
            Task { @MainActor in
                self?.toggleWindow()
            }
        }

        log(.info, "Global hotkey registered via KeyboardShortcuts")
    }

    @objc private func handleHotkeyChanged() {
        // KeyboardShortcuts handles changes automatically
        log(.info, "Global hotkey setting changed")
    }

    // MARK: - Double-Tap-and-Hold Modifier Key Setup

    private func setupDoubleTapHoldMonitor() {
        // Stop existing monitor if any
        modifierKeyMonitor?.stop()
        modifierKeyMonitor = nil

        let config = settings.longPressConfig
        guard config.enabled else {
            log(.info, "Double-tap-and-hold modifier key is disabled")
            return
        }

        log(.info, "Setting up double-tap-and-hold monitor for \(config.modifierKey.displayName) key")

        modifierKeyMonitor = ModifierKeyMonitor(
            modifierKey: config.modifierKey,
            minimumDuration: config.minimumPressDuration,
            onActivate: { [weak self] in
                Task { @MainActor in
                    self?.handleDoubleTapHoldActivate()
                }
            },
            onRelease: { [weak self] in
                Task { @MainActor in
                    self?.handleDoubleTapHoldRelease()
                }
            }
        )

        modifierKeyMonitor?.start()
        log(.info, "Double-tap-and-hold monitor started for \(config.modifierKey.symbol) key")
    }

    @objc private func handleLongPressConfigChanged() {
        log(.info, "Double-tap-and-hold config changed, updating monitor...")
        setupDoubleTapHoldMonitor()
    }

    @MainActor
    private func handleDoubleTapHoldActivate() {
        log(.info, "Double-tap-and-hold activated, showing window and starting recording")
        showWindow()
    }

    @MainActor
    private func handleDoubleTapHoldRelease() {
        // Check if we have a visible window
        guard let controller = floatingWindowController,
              controller.window?.isVisible == true else {
            log(.debug, "No visible window, ignoring release")
            return
        }

        if viewModel.transcribedText.isEmpty {
            // No text - just close the window
            log(.info, "Double-tap-and-hold released with no text, closing window")
            controller.hideWindow()
        } else {
            // Has text - trigger finish recording (submit and close)
            log(.info, "Double-tap-and-hold released with text, triggering finish recording")
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

// MARK: - Modifier Key Monitor

/// Monitors global modifier key press/release events for double-tap-and-hold activation
/// Requires Accessibility permission to work
///
/// State machine:
/// idle → firstPressDown → waitingForSecondPress → secondPressHeld → activated
class ModifierKeyMonitor {
    // MARK: - State Machine

    private enum State: CustomStringConvertible {
        case idle
        case firstPressDown
        case waitingForSecondPress
        case secondPressHeld
        case activated

        var description: String {
            switch self {
            case .idle: return "idle"
            case .firstPressDown: return "firstPressDown"
            case .waitingForSecondPress: return "waitingForSecondPress"
            case .secondPressHeld: return "secondPressHeld"
            case .activated: return "activated"
            }
        }
    }

    // MARK: - Configuration

    private let modifierKey: LongPressModifierKey
    private let minimumDuration: TimeInterval  // Time to hold on second press before activation
    private let onActivate: () -> Void
    private let onRelease: () -> Void

    // Double-tap timing constants
    private let doubleTapInterval: TimeInterval = 0.3  // Max time between taps
    private let firstTapMaxDuration: TimeInterval = 0.25  // Max duration for first tap

    // MARK: - State

    private var globalEventMonitor: Any?
    private var localEventMonitor: Any?
    private var state: State = .idle
    private var firstPressTime: Date?
    private var firstReleaseTime: Date?
    private var secondPressTime: Date?
    private var doubleTapTimeoutWorkItem: DispatchWorkItem?

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

        logger.info("Starting modifier key monitor for \(self.modifierKey.displayName) (double-tap-and-hold)")

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
        doubleTapTimeoutWorkItem?.cancel()
        doubleTapTimeoutWorkItem = nil
        logger.info("Modifier key monitor stopped")
        resetState()
    }

    private func resetState() {
        state = .idle
        firstPressTime = nil
        firstReleaseTime = nil
        secondPressTime = nil
        doubleTapTimeoutWorkItem?.cancel()
        doubleTapTimeoutWorkItem = nil
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

        logger.debug("[\(source)] flagsChanged: target=\(isTargetPressed), otherMods=\(hasOtherModifiers), state=\(self.state.description)")

        // If other modifiers are pressed, abort any pending activation
        if hasOtherModifiers {
            if state != .idle {
                logger.debug("[\(source)] Other modifier detected, resetting state")
                resetState()
            }
            return
        }

        // State machine transitions
        switch state {
        case .idle:
            if isTargetPressed {
                // First press detected
                logger.debug("[\(source)] First press detected")
                state = .firstPressDown
                firstPressTime = Date()
            }

        case .firstPressDown:
            if !isTargetPressed {
                // First release - check if it was quick enough
                guard let pressTime = firstPressTime else {
                    resetState()
                    return
                }

                let pressDuration = Date().timeIntervalSince(pressTime)
                if pressDuration <= firstTapMaxDuration {
                    // Quick tap - wait for second press
                    logger.debug("[\(source)] First tap completed (duration: \(String(format: "%.2f", pressDuration))s), waiting for second press")
                    state = .waitingForSecondPress
                    firstReleaseTime = Date()

                    // Start timeout for double-tap interval
                    let workItem = DispatchWorkItem { [weak self] in
                        guard let self = self, self.state == .waitingForSecondPress else { return }
                        self.logger.debug("Double-tap timeout, resetting state")
                        self.resetState()
                    }
                    doubleTapTimeoutWorkItem = workItem
                    DispatchQueue.main.asyncAfter(deadline: .now() + doubleTapInterval, execute: workItem)
                } else {
                    // Held too long for first tap - this is not a double-tap attempt
                    logger.debug("[\(source)] First press held too long (\(String(format: "%.2f", pressDuration))s), resetting")
                    resetState()
                }
            }

        case .waitingForSecondPress:
            if isTargetPressed {
                // Second press detected
                guard let releaseTime = firstReleaseTime else {
                    resetState()
                    return
                }

                let timeSinceRelease = Date().timeIntervalSince(releaseTime)
                if timeSinceRelease <= doubleTapInterval {
                    // Within double-tap window - start hold detection
                    logger.debug("[\(source)] Second press detected (interval: \(String(format: "%.2f", timeSinceRelease))s), waiting for hold")
                    state = .secondPressHeld
                    secondPressTime = Date()
                    doubleTapTimeoutWorkItem?.cancel()
                    doubleTapTimeoutWorkItem = nil

                    // Schedule activation check after minimum duration
                    DispatchQueue.main.asyncAfter(deadline: .now() + minimumDuration) { [weak self] in
                        self?.checkActivation()
                    }
                } else {
                    // Too slow - treat as new first press
                    logger.debug("[\(source)] Second press too slow, treating as new first press")
                    resetState()
                    state = .firstPressDown
                    firstPressTime = Date()
                }
            }

        case .secondPressHeld:
            if !isTargetPressed {
                // Released before activation threshold
                let pressDuration = secondPressTime.map { Date().timeIntervalSince($0) } ?? 0
                logger.debug("[\(source)] Second press released before activation (duration: \(String(format: "%.2f", pressDuration))s)")
                resetState()
            }

        case .activated:
            if !isTargetPressed {
                // Released after activation - trigger release callback
                logger.info("[\(source)] Double-tap-and-hold release detected, triggering callback")
                onRelease()
                resetState()
            }
        }
    }

    private func checkActivation() {
        // Verify we're still in secondPressHeld state and the key is still pressed
        guard state == .secondPressHeld,
              let pressTime = secondPressTime,
              Date().timeIntervalSince(pressTime) >= minimumDuration else {
            return
        }

        // Check if modifier is still pressed
        let currentFlags = NSEvent.modifierFlags
        guard currentFlags.contains(modifierKey.modifierFlag) else {
            logger.debug("Modifier released before activation")
            resetState()
            return
        }

        // Activate
        logger.info("Double-tap-and-hold threshold reached, activating")
        state = .activated
        onActivate()
    }

    /// Check if Accessibility permission is granted
    static func checkAccessibilityPermission(prompt: Bool = false) -> Bool {
        let options: [String: Any] = prompt
            ? [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
            : [:]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let recordingStateChanged = Notification.Name("recordingStateChanged")
    static let globalHotkeyChanged = Notification.Name("globalHotkeyChanged")
    static let longPressConfigChanged = Notification.Name("longPressConfigChanged")
}
