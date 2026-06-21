import SwiftUI

/// First-run flow: explain the Input Monitoring requirement, then calibrate
/// by walking the user through a real 1/2/3-slap test — mirroring the real
/// app's "Slap your MacBook once" / "Now slap twice" / "And three slaps" steps.
struct OnboardingView: View {
    @ObservedObject var configStore: ConfigStore
    @ObservedObject var detector: SlapDetector
    @ObservedObject var permission: InputMonitoringPermission
    var onFinished: () -> Void

    private enum Step: Int, CaseIterable {
        case welcome, permission, calibrate1, calibrate2, calibrate3, done
    }

    @State private var step: Step = .welcome
    @State private var confirmedCounts: Set<Int> = []

    var body: some View {
        VStack(spacing: 0) {
            StepDots(current: step.rawValue, total: Step.allCases.count)
                .padding(.top, Theme.Spacing.lg)

            content
                .id(step)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .move(edge: .trailing)),
                    removal: .opacity.combined(with: .move(edge: .leading))
                ))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(36)

            footer
        }
        .background(Theme.background)
        .frame(width: 520, height: 460)
        .onReceive(detector.$lastFiredSlapCount) { count in
            handleSlap(count: count)
        }
        .onAppear { permission.refresh() }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .welcome:
            welcomeStep
        case .permission:
            permissionStep
        case .calibrate1:
            calibrateStep(target: 1, title: "Slap your MacBook once", detail: "Give it one firm slap on the palm rest. We'll confirm we felt it.")
        case .calibrate2:
            calibrateStep(target: 2, title: "Now slap twice", detail: "Two slaps in under half a second. Tap-tap. We'll confirm we caught both.")
        case .calibrate3:
            calibrateStep(target: 3, title: "And three slaps", detail: "Tap-tap-tap, fast. Three slaps map to a third mode later.")
        case .done:
            doneStep
        }
    }

    private var welcomeStep: some View {
        VStack(spacing: 18) {
            PixelImpactMark(blockSize: 7)
            Text("Welcome to SlapShift")
                .font(.newsreader(28, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
            Text("Slap your MacBook to switch between workspaces — each slap count opens, closes, and focuses exactly what you tell it to.")
                .font(.newsreaderItalic(15))
                .foregroundColor(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
    }

    private var permissionStep: some View {
        VStack(spacing: 16) {
            Text("One permission")
                .font(.newsreader(24, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
            Text("SlapShift reads the motion sensor in your MacBook to detect a slap. macOS treats motion as input, so it needs Input Monitoring permission.")
                .font(.newsreader(14))
                .foregroundColor(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)

            statusBadge

            HStack(spacing: 10) {
                Button("Grant Access") { permission.request() }
                    .buttonStyle(PrimaryButtonStyle())
                Button("Open System Settings") { permission.openSystemSettings() }
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
    }

    private var statusBadge: some View {
        let (text, color): (String, Color) = {
            switch permission.status {
            case .granted: return ("Access granted", Theme.success)
            case .denied: return ("Access denied — enable it in System Settings", Theme.danger)
            case .unknown: return ("Not yet requested", Theme.textSecondary)
            }
        }()
        return Text(text)
            .font(.newsreader(12, weight: .medium))
            .foregroundColor(color)
    }

    private func calibrateStep(target: Int, title: String, detail: String) -> some View {
        VStack(spacing: 18) {
            Text(String(repeating: "✋", count: target))
                .font(.system(size: 30))
            Text(title)
                .font(.newsreader(22, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
            Text(detail)
                .font(.newsreader(14))
                .foregroundColor(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)

            SlapMeter(detector: detector)
                .frame(maxWidth: 380)

            if confirmedCounts.contains(target) {
                Text("Felt it ✓")
                    .font(.newsreader(13, weight: .semibold))
                    .foregroundColor(Theme.success)
                    .scaleEffect(confirmedCounts.contains(target) ? 1 : 0.6)
                    .transition(.scale.combined(with: .opacity))
                    .animation(Theme.Motion.celebrate, value: confirmedCounts)
            } else {
                Button("Simulate (no hardware needed)") {
                    fireSimulated(count: target)
                }
                .buttonStyle(SecondaryButtonStyle())
            }
        }
    }

    private var doneStep: some View {
        VStack(spacing: 16) {
            PixelImpactMark(blockSize: 7)
            Text("You're set")
                .font(.newsreader(26, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
            Text("Menu bar icon installed — look for the hand.tap symbol top-right. Open Settings from there to customize modes.")
                .font(.newsreader(14))
                .foregroundColor(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
    }

    private var footer: some View {
        HStack {
            if step != .welcome {
                Button("Back") {
                    withAnimation(Theme.Motion.standard) {
                        step = Step(rawValue: step.rawValue - 1) ?? .welcome
                    }
                }
                .buttonStyle(SecondaryButtonStyle())
            }
            Spacer()
            Button(step == .done ? "Finish" : "Continue") {
                advance()
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(!canAdvance)
        }
        .padding(20)
        .background(Theme.surface)
    }

    private var canAdvance: Bool {
        switch step {
        case .calibrate1: return confirmedCounts.contains(1)
        case .calibrate2: return confirmedCounts.contains(2)
        case .calibrate3: return confirmedCounts.contains(3)
        default: return true
        }
    }

    private func advance() {
        if step == .done {
            configStore.config.hasCompletedOnboarding = true
            configStore.save()
            onFinished()
            return
        }
        withAnimation(Theme.Motion.standard) {
            step = Step(rawValue: step.rawValue + 1) ?? .done
        }
    }

    private func handleSlap(count: Int) {
        guard count > 0 else { return }
        confirmedCounts.insert(count)
    }

    private func fireSimulated(count: Int) {
        detector.simulateSlaps(count: count)
    }
}

/// Small progress breadcrumb above the onboarding content — one dot per step,
/// the current step filled and slightly enlarged.
private struct StepDots: View {
    let current: Int
    let total: Int

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            ForEach(0..<total, id: \.self) { index in
                Circle()
                    .fill(index == current ? Theme.accent : Theme.surfaceBorder)
                    .frame(width: index == current ? 8 : 6, height: index == current ? 8 : 6)
                    .animation(Theme.Motion.quick, value: current)
            }
        }
    }
}
