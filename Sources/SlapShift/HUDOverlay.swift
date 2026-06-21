import AppKit
import SwiftUI

/// A transient, click-through HUD shown briefly in the center of the screen
/// whenever a slot fires, so the user gets instant visual confirmation.
final class HUDOverlay {
    private static var window: NSWindow?
    private static var dismissTimer: Timer?
    private static let fadeDuration: TimeInterval = 0.22

    static func show(slotName: String, slapCount: Int) {
        dismissTimer?.invalidate()
        window?.close()

        let state = HUDAnimationState()
        let content = HUDView(slotName: slotName, slapCount: slapCount, state: state)
        let hosting = NSHostingView(rootView: content)
        hosting.frame = NSRect(x: 0, y: 0, width: 280, height: 90)

        let panel = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // Without this, AppKit's legacy close-time release (triggered by the
        // default isReleasedWhenClosed=true) double-decrements the retain
        // count alongside ARC's own management of the `window` strong var,
        // corrupting memory the moment a second HUD replaces a first one.
        panel.isReleasedWhenClosed = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
        panel.contentView = hosting

        if let screen = NSScreen.main {
            let frame = screen.frame
            let originX = frame.midX - hosting.frame.width / 2
            let originY = frame.midY - hosting.frame.height / 2 + frame.height * 0.18
            panel.setFrameOrigin(NSPoint(x: originX, y: originY))
        }

        panel.orderFrontRegardless()
        window = panel

        // Flip to visible a beat after insertion so the initial scale/opacity state
        // actually renders first and the transition has something to animate from.
        DispatchQueue.main.async {
            withAnimation(Theme.Motion.standard) {
                state.isVisible = true
            }
        }

        dismissTimer = Timer.scheduledTimer(withTimeInterval: 1.4, repeats: false) { _ in
            withAnimation(Theme.Motion.quick) {
                state.isVisible = false
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + fadeDuration) {
                window?.close()
                window = nil
            }
        }
    }
}

private final class HUDAnimationState: ObservableObject {
    @Published var isVisible = false
}

private struct HUDView: View {
    let slotName: String
    let slapCount: Int
    @ObservedObject var state: HUDAnimationState

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(Theme.accent.opacity(0.18 + 0.1 * Double(slapCount)))
                    .frame(width: 52 + CGFloat(slapCount) * 6, height: 52 + CGFloat(slapCount) * 6)
                    .blur(radius: 6)
                Text(String(repeating: "✋", count: slapCount))
                    .font(.system(size: 22))
            }
            Text(slotName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .frame(width: 280, height: 90)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.black.opacity(0.78))
        )
        .scaleEffect(state.isVisible ? 1 : 0.85)
        .opacity(state.isVisible ? 1 : 0)
    }
}
