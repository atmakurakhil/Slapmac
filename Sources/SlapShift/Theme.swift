import SwiftUI
import CoreText
import AppKit

/// Visual language modeled on the real SlapShift app: warm parchment
/// background, terracotta accent, editorial serif (Newsreader, OFL-licensed
/// Google Font) paired with a pixel-motion accent mark.
enum Theme {
    static let background = Color(hex: 0xEDE3CE)
    static let surface = Color(hex: 0xF7F1E3)
    static let surfaceBorder = Color(hex: 0xDCCFAE)
    static let accent = Color(hex: 0xD2592E)
    static let accentDim = Color(hex: 0xD2592E).opacity(0.55)
    static let textPrimary = Color(hex: 0x2B2520)
    static let textSecondary = Color(hex: 0x6B5F4F)
    static let danger = Color(hex: 0xB23A2E)
    static let success = Color(hex: 0x4C7A4A)

    static func registerFonts() {
        for name in ["Newsreader-Regular", "Newsreader-Italic"] {
            guard let url = Bundle.module.url(forResource: name, withExtension: "ttf", subdirectory: "Resources/Fonts")
                ?? Bundle.module.url(forResource: name, withExtension: "ttf") else { continue }
            var error: Unmanaged<CFError>?
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
        }
    }

    /// Spacing scale used in place of ad-hoc padding constants.
    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 14
        static let lg: CGFloat = 22
        static let xl: CGFloat = 36
    }

    /// Shared animation durations/curves so motion feels consistent rather than ad-hoc.
    enum Motion {
        static let quick = Animation.easeOut(duration: 0.15)
        static let standard = Animation.spring(response: 0.32, dampingFraction: 0.8)
        static let celebrate = Animation.spring(response: 0.45, dampingFraction: 0.62)
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(red: r, green: g, blue: b, opacity: opacity)
    }
}

extension Font {
    static func newsreader(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom("Newsreader", size: size).weight(weight)
    }

    static func newsreaderItalic(_ size: CGFloat) -> Font {
        .custom("Newsreader-Italic", size: size)
    }
}

/// Small pixel-block "impact lines" mark used as a decorative accent,
/// echoing the bundled app icon's motion glyph.
struct PixelImpactMark: View {
    var color: Color = Theme.accent
    var blockSize: CGFloat = 5

    var body: some View {
        Canvas { context, _ in
            let cells: [(Int, Int)] = [(0, 0), (1, 1), (2, 2), (3, 3), (4, 0), (4, -1)]
            for (x, y) in cells {
                let rect = CGRect(
                    x: CGFloat(x) * blockSize,
                    y: CGFloat(y) * blockSize + blockSize * 2,
                    width: blockSize,
                    height: blockSize
                )
                context.fill(Path(rect), with: .color(color))
            }
        }
        .frame(width: blockSize * 6, height: blockSize * 5)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.newsreader(14, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Theme.accent.opacity(configuration.isPressed ? 0.75 : (isHovered ? 0.92 : 1)))
            )
            .scaleEffect(configuration.isPressed ? 0.97 : (isHovered ? 1.015 : 1))
            .animation(Theme.Motion.quick, value: isHovered)
            .animation(Theme.Motion.quick, value: configuration.isPressed)
            .onHover { isHovered = $0 }
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.newsreader(13, weight: .medium))
            .foregroundColor(Theme.textPrimary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovered ? Theme.surfaceBorder.opacity(0.4) : Theme.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Theme.surfaceBorder, lineWidth: 1)
                    )
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(Theme.Motion.quick, value: isHovered)
            .onHover { isHovered = $0 }
    }
}

/// Visual treatment for a control bound to a disabled slot/action — dimmed, and
/// hover/press feedback suppressed since interaction is intentionally inert.
struct DisabledRowStyle: ViewModifier {
    var isDisabled: Bool

    func body(content: Content) -> some View {
        content
            .opacity(isDisabled ? 0.5 : 1)
            .allowsHitTesting(!isDisabled)
            .animation(Theme.Motion.quick, value: isDisabled)
    }
}

extension View {
    func disabledRowStyle(_ isDisabled: Bool) -> some View { modifier(DisabledRowStyle(isDisabled: isDisabled)) }
}

struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Theme.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Theme.surfaceBorder, lineWidth: 1)
                    )
                    .shadow(color: Theme.textPrimary.opacity(0.08), radius: 8, x: 0, y: 3)
            )
    }
}

extension View {
    func cardBackground() -> some View { modifier(CardBackground()) }
}
