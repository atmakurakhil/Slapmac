import IOKit.hidsystem
import AppKit
import Combine

/// macOS treats raw motion/HID event streams as "input" for privacy purposes,
/// so reading the accelerometer through IOHIDEventSystemClient requires the
/// user to grant Input Monitoring access — the same permission class as
/// keylogger-capable APIs. The real SlapShift app surfaces this explicitly
/// ("SlapShift reads the motion sensor... it needs Input Monitoring
/// permission"); we do the same instead of failing silently.
final class InputMonitoringPermission: ObservableObject {
    enum Status {
        case granted
        case denied
        case unknown
    }

    @Published private(set) var status: Status = .unknown

    func refresh() {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: status = .granted
        case kIOHIDAccessTypeDenied: status = .denied
        default: status = .unknown
        }
    }

    /// Triggers the system permission prompt (only shows once per app per
    /// Apple's policy; afterward the user must flip it manually in Settings).
    func request() {
        let granted = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        status = granted ? .granted : .denied
    }

    func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") else { return }
        NSWorkspace.shared.open(url)
    }
}
