import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?

    let configStore = ConfigStore()
    let permission = InputMonitoringPermission()
    private(set) lazy var detector = SlapDetector(configStore: configStore)

    func applicationDidFinishLaunching(_ notification: Notification) {
        Theme.registerFonts()
        NSApp.setActivationPolicy(.accessory) // menu bar only, no Dock icon

        setupStatusItem()
        permission.refresh()

        detector.onSlot = { [weak self] slapCount in
            self?.handleSlot(slapCount: slapCount)
        }
        detector.start()

        if configStore.config.launchAtLogin {
            LaunchAtLogin.set(true)
        }

        if ProcessInfo.processInfo.environment["SLAPSHIFT_AUTOTEST"] == "1" {
            runAutomatedSelfTest()
        } else if !configStore.config.hasCompletedOnboarding {
            DispatchQueue.main.async { [weak self] in
                self?.openOnboarding()
            }
        }
    }

    /// Drives the real detection/action pipeline end-to-end without any GUI
    /// interaction, for headless verification. Activated via
    /// `SLAPSHIFT_AUTOTEST=1`; logs each stage to stderr so a test harness can
    /// assert on observable behavior instead of trusting a visual screenshot.
    private func runAutomatedSelfTest() {
        FileHandle.standardError.write("AUTOTEST: launched, hardwareAvailable=\(detector.isHardwareAvailable), permission=\(permission.status)\n".data(using: .utf8)!)

        let originalOnSlot = detector.onSlot
        detector.onSlot = { count in
            FileHandle.standardError.write("AUTOTEST: detector fired lastFiredSlapCount=\(count)\n".data(using: .utf8)!)
            originalOnSlot?(count)
            if let slot = self.configStore.slot(forSlapCount: count) {
                FileHandle.standardError.write("AUTOTEST: resolved slot name=\"\(slot.name)\" actions=\(slot.actions.map { "\($0.kind.rawValue):\($0.target)" })\n".data(using: .utf8)!)
            } else {
                FileHandle.standardError.write("AUTOTEST: no enabled slot bound to count=\(count)\n".data(using: .utf8)!)
            }
        }

        func fireSequence(count: Int, after delay: Double, label: String) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                FileHandle.standardError.write("AUTOTEST: injecting \(count) simulated slap(s) for \(label)\n".data(using: .utf8)!)
                self.detector.simulateSlaps(count: count)
            }
        }

        fireSequence(count: 1, after: 0.5, label: "single-slap")
        fireSequence(count: 2, after: 2.5, label: "double-slap")
        fireSequence(count: 3, after: 5.0, label: "triple-slap")

        DispatchQueue.main.asyncAfter(deadline: .now() + 7.5) {
            FileHandle.standardError.write("AUTOTEST: lifetimeSlapCount=\(self.configStore.config.lifetimeSlapCount)\n".data(using: .utf8)!)
            FileHandle.standardError.write("AUTOTEST: complete\n".data(using: .utf8)!)
            NSApp.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        detector.stop()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "hand.tap.fill", accessibilityDescription: "SlapShift")
        statusItem.button?.image?.isTemplate = true

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "SlapShift", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Open Settings…", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Simulate Slap", action: #selector(simulateSlap), keyEquivalent: "s"))
        menu.addItem(NSMenuItem(title: "Run Setup Again…", action: #selector(openOnboardingMenuAction), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit SlapShift", action: #selector(quit), keyEquivalent: "q"))

        for item in menu.items {
            item.target = self
        }
        statusItem.menu = menu
    }

    private func handleSlot(slapCount: Int) {
        if ProcessInfo.processInfo.environment["SLAPSHIFT_DEBUG_HID"] == "1" {
            FileHandle.standardError.write("REAL SLAP DETECTED: count=\(slapCount)\n".data(using: .utf8)!)
        }
        guard let slot = configStore.slot(forSlapCount: slapCount) else { return }
        ActionRunner.run(slot: slot)
        HUDOverlay.show(slotName: slot.name, slapCount: slapCount)
    }

    @objc private func openSettings() {
        permission.refresh()
        if settingsWindow == nil {
            let view = SettingsView(configStore: configStore, detector: detector, permission: permission, onShowOnboarding: { [weak self] in
                self?.openOnboarding()
            })
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 700),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "SlapShift Settings"
            window.contentView = NSHostingView(rootView: view)
            window.center()
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func openOnboardingMenuAction() {
        openOnboarding()
    }

    private func openOnboarding() {
        if onboardingWindow == nil {
            let view = OnboardingView(configStore: configStore, detector: detector, permission: permission, onFinished: { [weak self] in
                self?.onboardingWindow?.close()
            })
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 460),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "Welcome to SlapShift"
            window.contentView = NSHostingView(rootView: view)
            window.center()
            window.isReleasedWhenClosed = false
            onboardingWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func simulateSlap() {
        detector.simulateSlaps(count: 1)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
