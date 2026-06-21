import AppKit
import Foundation

/// Executes the actions attached to a fired slot.
struct ActionRunner {
    /// `Process` instances must stay alive until they terminate — Foundation's
    /// SIGCHLD-driven completion bookkeeping can fault if the wrapper object
    /// is deallocated while the child is still being reaped. Letting a local
    /// `Process` fall out of scope right after `run()` reproduced a SIGSEGV
    /// in this app's autorelease pool drain when a second action ran shortly
    /// after, so every spawned process is held here until its handler fires.
    private static var inFlightProcesses: [ObjectIdentifier: Process] = [:]
    static func run(slot: Slot) {
        for action in slot.actions {
            run(action: action)
        }
    }

    static func run(action: SlotAction) {
        switch action.kind {
        case .openApp:
            openApp(bundleIdentifier: action.target)
        case .openURL:
            openURL(action.target)
        case .activateFocus:
            activateFocus(shortcutName: action.target)
        case .quitApp:
            quitApp(bundleIdentifier: action.target)
        }
    }

    private static func openApp(bundleIdentifier: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    private static func openURL(_ raw: String) {
        let urlString = raw.contains("://") ? raw : "https://\(raw)"
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    private static func quitApp(bundleIdentifier: String) {
        for app in NSWorkspace.shared.runningApplications where app.bundleIdentifier == bundleIdentifier {
            app.terminate()
        }
    }

    /// macOS has no public API to programmatically switch Focus modes. The
    /// supported workaround (also used by other menu-bar utilities) is to
    /// invoke a user-created Shortcuts.app automation by name via the `shortcuts` CLI.
    /// Create a Shortcut named e.g. "Focus" that runs "Set Focus" for this to work.
    private static func activateFocus(shortcutName: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = ["run", shortcutName]

        let key = ObjectIdentifier(process)
        process.terminationHandler = { finished in
            DispatchQueue.main.async {
                inFlightProcesses.removeValue(forKey: key)
            }
        }

        do {
            inFlightProcesses[key] = process
            try process.run()
        } catch {
            inFlightProcesses.removeValue(forKey: key)
            NSLog("SlapShift: failed to run Shortcuts automation \"\(shortcutName)\": \(error)")
        }
    }
}
