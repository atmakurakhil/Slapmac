import Foundation

enum ActionKind: String, Codable, CaseIterable, Identifiable {
    case openApp
    case openURL
    case activateFocus
    case quitApp

    var id: String { rawValue }

    var label: String {
        switch self {
        case .openApp: return "Open App"
        case .openURL: return "Open URL"
        case .activateFocus: return "Activate Focus"
        case .quitApp: return "Quit App"
        }
    }

    var systemImageName: String {
        switch self {
        case .openApp: return "app.fill"
        case .openURL: return "link"
        case .activateFocus: return "moon.fill"
        case .quitApp: return "xmark.circle"
        }
    }
}

struct SlotAction: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var kind: ActionKind
    /// Bundle identifier (openApp/quitApp) or raw string (openURL path/URL, activateFocus shortcut name)
    var target: String
    var displayName: String
}

struct Slot: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    /// 1, 2, or 3 consecutive slaps
    var slapCount: Int
    var name: String
    var actions: [SlotAction] = []
    var enabled: Bool = true
}

struct AppConfig: Codable, Equatable {
    var slots: [Slot]
    var sensitivity: Double // 0.0 (least sensitive) ... 1.0 (most sensitive)
    var launchAtLogin: Bool
    var lifetimeSlapCount: Int
    var multiSlapWindowSeconds: Double
    var hasCompletedOnboarding: Bool = false

    static let `default` = AppConfig(
        slots: [
            Slot(slapCount: 1, name: "Focus Mode", actions: [
                SlotAction(kind: .activateFocus, target: "Focus", displayName: "Focus"),
                SlotAction(kind: .quitApp, target: "com.apple.Music", displayName: "Music")
            ]),
            Slot(slapCount: 2, name: "Dev Mode", actions: [
                SlotAction(kind: .openApp, target: "com.microsoft.VSCode", displayName: "Visual Studio Code"),
                SlotAction(kind: .openURL, target: "http://localhost:3000", displayName: "localhost:3000")
            ]),
            Slot(slapCount: 3, name: "Browse Mode", actions: [
                SlotAction(kind: .openApp, target: "com.google.Chrome", displayName: "Google Chrome")
            ])
        ],
        // 0.77, not the midpoint 0.5: this Mac's BMI286 accelerometer is configured
        // for a narrow +/-2g range, so a genuine physical tap only reaches ~1.4-1.6g
        // (resting baseline is already ~1.2g from gravity), and 0.5's vote thresholds
        // sit well above that band. 0.77 was empirically validated this session via a
        // real physical-tap run with AUTOTEST's hardware listener active the whole
        // time: it caught a genuine slap and produced zero false positives while the
        // machine sat quietly. A higher value (0.88) was tried and rejected — it
        // false-triggered from incidental keyboard-typing vibration during automated
        // testing, which would make ordinary typing misfire slots in daily use. The
        // latency fix below, not a sensitivity bump, is what actually fixes "feels
        // slow/unresponsive" — don't re-raise this without a fresh quiet-vs-typing
        // false-positive test.
        sensitivity: 0.77,
        launchAtLogin: false,
        lifetimeSlapCount: 0,
        multiSlapWindowSeconds: 0.45
    )
}
