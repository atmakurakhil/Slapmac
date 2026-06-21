import SwiftUI
import AppKit

/// Live calibration meter: a horizontal bar tracking the rolling accelerometer
/// magnitude with a red threshold line, mirroring the real app's "Slap the
/// palm rest. The red line is the slap threshold" calibration screen.
struct SlapMeter: View {
    @ObservedObject var detector: SlapDetector

    private let minG: Double = 0.8
    private let maxG: Double = 4.0

    @State private var peakPulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Slap meter")
                    .font(.newsreader(13, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                Spacer()
                Text(String(format: "%.2fg", detector.liveMagnitudeG))
                    .font(.newsreader(13).monospacedDigit())
                    .foregroundColor(Theme.textSecondary)
                Button("Reset peak") { detector.resetPeakMeter() }
                    .buttonStyle(.plain)
                    .font(.newsreader(11))
                    .foregroundColor(Theme.accent)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Theme.surfaceBorder.opacity(0.5))

                    RoundedRectangle(cornerRadius: 6)
                        .fill(barGradient)
                        .frame(width: width(for: detector.liveMagnitudeG, in: geo.size.width))
                        .animation(.linear(duration: 0.05), value: detector.liveMagnitudeG)

                    Rectangle()
                        .fill(Theme.danger)
                        .frame(width: 2)
                        .offset(x: width(for: detector.thresholdG, in: geo.size.width))

                    Rectangle()
                        .fill(Theme.textSecondary.opacity(0.6))
                        .frame(width: 1.5)
                        .scaleEffect(y: peakPulse ? 1.8 : 1)
                        .offset(x: width(for: detector.peakMagnitudeG, in: geo.size.width))
                        .animation(Theme.Motion.celebrate, value: peakPulse)
                }
            }
            .frame(height: 22)
            .onChange(of: detector.peakMagnitudeG) { _ in
                peakPulse = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { peakPulse = false }
            }

            if detector.isArmedForMoreSlaps {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for next slap…")
                        .font(.newsreaderItalic(11))
                        .foregroundColor(Theme.accent)
                }
                .transition(.opacity)
            }

            if !detector.isHardwareAvailable {
                Text("No live signal — accelerometer access isn't granted yet, or this Mac's motion sensor path differs. Use Simulate Slap to test the rest of the pipeline.")
                    .font(.newsreaderItalic(11))
                    .foregroundColor(Theme.textSecondary)
            }
        }
        .animation(Theme.Motion.quick, value: detector.isArmedForMoreSlaps)
    }

    private var barGradient: LinearGradient {
        let progress = min(max((detector.liveMagnitudeG - minG) / (detector.thresholdG - minG), 0), 1)
        return LinearGradient(
            colors: [Theme.accent, Color.interpolate(from: Theme.accent, to: Theme.danger, fraction: progress)],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private func width(for value: Double, in totalWidth: CGFloat) -> CGFloat {
        let clamped = min(max(value, minG), maxG)
        let fraction = (clamped - minG) / (maxG - minG)
        return totalWidth * CGFloat(fraction)
    }
}

private extension Color {
    static func interpolate(from: Color, to: Color, fraction: Double) -> Color {
        let f = min(max(fraction, 0), 1)
        let a = NSColor(from).usingColorSpace(.deviceRGB) ?? NSColor(from)
        let b = NSColor(to).usingColorSpace(.deviceRGB) ?? NSColor(to)
        return Color(
            red: a.redComponent + (b.redComponent - a.redComponent) * f,
            green: a.greenComponent + (b.greenComponent - a.greenComponent) * f,
            blue: a.blueComponent + (b.blueComponent - a.blueComponent) * f
        )
    }
}
