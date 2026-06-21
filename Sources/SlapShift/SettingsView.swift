import SwiftUI

struct SettingsView: View {
    @ObservedObject var configStore: ConfigStore
    @ObservedObject var detector: SlapDetector
    @ObservedObject var permission: InputMonitoringPermission
    var onShowOnboarding: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            SlapMeter(detector: detector)

            ScrollView {
                VStack(spacing: 12) {
                    ForEach($configStore.config.slots) { $slot in
                        SlotEditorCard(slot: $slot, onChange: configStore.save)
                    }
                }
                .padding(.vertical, 4)
            }

            Divider().overlay(Theme.surfaceBorder)

            generalSettings

            Divider().overlay(Theme.surfaceBorder)

            footer
        }
        .padding(22)
        .frame(width: 520, height: 700)
        .background(Theme.background)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    PixelImpactMark()
                    Text("SlapShift")
                        .font(.newsreader(22, weight: .bold))
                        .foregroundColor(Theme.textPrimary)
                }
                Text(statusLine)
                    .font(.newsreader(12))
                    .foregroundColor(statusColor)
            }
            Spacer()
            Button("Redo Setup") { onShowOnboarding() }
                .buttonStyle(SecondaryButtonStyle())
        }
    }

    private var statusLine: String {
        switch permission.status {
        case .granted: return detector.isHardwareAvailable ? "Listening for slaps" : "Permission granted — accelerometer not responding"
        case .denied: return "Input Monitoring denied — slap detection is off"
        case .unknown: return "Input Monitoring not yet requested"
        }
    }

    private var statusColor: Color {
        switch permission.status {
        case .granted: return detector.isHardwareAvailable ? Theme.success : Theme.danger
        case .denied: return Theme.danger
        case .unknown: return Theme.textSecondary
        }
    }

    private var generalSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            settingRow(label: "Sensitivity", help: "Lower = easier to trigger but more false positives from typing.") {
                Slider(value: $configStore.config.sensitivity, in: 0...1) { _ in configStore.save() }
                Text(String(format: "%.0f%%", configStore.config.sensitivity * 100))
                    .frame(width: 44, alignment: .trailing)
                    .monospacedDigit()
            }

            settingRow(label: "Multi-slap window", help: "How long to wait after the first slap before firing the mode.") {
                Slider(value: $configStore.config.multiSlapWindowSeconds, in: 0.3...1.2) { _ in configStore.save() }
                Text(String(format: "%.1fs", configStore.config.multiSlapWindowSeconds))
                    .frame(width: 44, alignment: .trailing)
                    .monospacedDigit()
            }

            Toggle("Launch SlapShift at login", isOn: Binding(
                get: { configStore.config.launchAtLogin },
                set: { newValue in
                    configStore.config.launchAtLogin = newValue
                    LaunchAtLogin.set(newValue)
                    configStore.save()
                }
            ))
            .font(.newsreader(13))
            .toggleStyle(.switch)
        }
    }

    private func settingRow<Content: View>(label: String, help: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.newsreader(13, weight: .medium)).foregroundColor(Theme.textPrimary)
                content()
            }
            Text(help)
                .font(.newsreaderItalic(11))
                .foregroundColor(Theme.textSecondary)
        }
    }

    private var footer: some View {
        HStack {
            VStack(alignment: .leading) {
                Text("Lifetime slaps")
                    .font(.newsreader(11))
                    .foregroundColor(Theme.textSecondary)
                Text("\(configStore.config.lifetimeSlapCount)")
                    .font(.newsreader(20, weight: .bold))
                    .foregroundColor(Theme.accent)
                    .monospacedDigit()
            }

            Spacer()

            Button("Slap!") { detector.simulateSlaps(count: 1) }
                .buttonStyle(SecondaryButtonStyle())
            Button("Slap x2") { detector.simulateSlaps(count: 2) }
                .buttonStyle(SecondaryButtonStyle())
            Button("Slap x3") { detector.simulateSlaps(count: 3) }
                .buttonStyle(PrimaryButtonStyle())
        }
    }
}

private struct SlotEditorCard: View {
    @Binding var slot: Slot
    var onChange: () -> Void

    @State private var pendingDeleteAction: SlotAction?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(String(repeating: "✋", count: slot.slapCount))
                    .font(.system(size: 16))
                TextField("Mode name", text: $slot.name)
                    .textFieldStyle(.plain)
                    .font(.newsreader(15, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                    .onChange(of: slot.name) { _ in onChange() }
                Spacer()
                Toggle("", isOn: $slot.enabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .onChange(of: slot.enabled) { _ in onChange() }
            }

            VStack(alignment: .leading, spacing: 10) {
                ForEach(slot.actions) { action in
                    HStack {
                        Image(systemName: action.kind.systemImageName)
                            .foregroundColor(Theme.accent)
                            .frame(width: 16)
                        Text(action.kind.label)
                            .font(.newsreader(11))
                            .frame(width: 80, alignment: .leading)
                            .foregroundColor(Theme.textSecondary)
                        Text(action.displayName)
                            .font(.newsreader(12))
                            .foregroundColor(Theme.textPrimary)
                        Spacer()
                        Button {
                            pendingDeleteAction = action
                        } label: {
                            Image(systemName: "trash")
                                .foregroundColor(Theme.danger)
                        }
                        .buttonStyle(.plain)
                    }
                }

                AddActionRow(slot: $slot, onChange: onChange)
            }
            .disabledRowStyle(!slot.enabled)
        }
        .padding(14)
        .cardBackground()
        .opacity(slot.enabled ? 1 : 0.6)
        .animation(Theme.Motion.quick, value: slot.enabled)
        .confirmationDialog(
            "Remove this action?",
            isPresented: Binding(get: { pendingDeleteAction != nil }, set: { if !$0 { pendingDeleteAction = nil } }),
            presenting: pendingDeleteAction
        ) { action in
            Button("Remove \(action.displayName)", role: .destructive) {
                slot.actions.removeAll { $0.id == action.id }
                onChange()
            }
        }
    }
}

private struct AddActionRow: View {
    @Binding var slot: Slot
    var onChange: () -> Void

    @State private var kind: ActionKind = .openApp
    @State private var target: String = ""
    @State private var displayName: String = ""

    var body: some View {
        HStack {
            Picker("", selection: $kind) {
                ForEach(ActionKind.allCases) { kind in
                    Text(kind.label).tag(kind)
                }
            }
            .labelsHidden()
            .frame(width: 130)

            TextField(placeholder(for: kind), text: $target)
                .textFieldStyle(.roundedBorder)
                .font(.newsreader(12))

            Button("Add") {
                guard !target.isEmpty else { return }
                let name = displayName.isEmpty ? target : displayName
                slot.actions.append(SlotAction(kind: kind, target: target, displayName: name))
                target = ""
                displayName = ""
                onChange()
            }
            .buttonStyle(SecondaryButtonStyle())
        }
    }

    private func placeholder(for kind: ActionKind) -> String {
        switch kind {
        case .openApp, .quitApp: return "com.apple.Safari (bundle id)"
        case .openURL: return "https://localhost:3000"
        case .activateFocus: return "Shortcut name to run"
        }
    }
}
