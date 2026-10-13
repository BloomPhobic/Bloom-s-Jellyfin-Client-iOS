import SwiftUI

/// The app's dark look ("Bloom's Archive dark purple"). The accent comes from Settings.
enum Theme {
    /// The accent chosen in Settings. Use this, not `Color.accentColor` (that's iOS's default blue).
    static var accent: Color { AccentStore.shared.color }
    static let background = Color(red: 0x0D / 255, green: 0x0A / 255, blue: 0x12 / 255)
    static let surface = Color(red: 0x17 / 255, green: 0x12 / 255, blue: 0x1F / 255)
    static let raised = Color(red: 0x1B / 255, green: 0x15 / 255, blue: 0x24 / 255)
    static let raised2 = Color(red: 0x23 / 255, green: 0x1B / 255, blue: 0x2E / 255)
    static let text = Color(red: 0xF4 / 255, green: 0xF0 / 255, blue: 0xFA / 255)
    static let text2 = Color(red: 0xBD / 255, green: 0xB3 / 255, blue: 0xCC / 255)
    static let text3 = Color(red: 0x9C / 255, green: 0x90 / 255, blue: 0xAE / 255)
    /// Text on accent-coloured fills (dark, so it stays readable on light accents).
    static let onAccent = Color(red: 0x17 / 255, green: 0x0B / 255, blue: 0x26 / 255)
    static let line = Color.white.opacity(0.08)
    /// Dark translucent fill for controls drawn over video or artwork.
    static let scrim = Color(red: 0x0D / 255, green: 0x0A / 255, blue: 0x12 / 255).opacity(0.7)

    static let press = Animation.spring(response: 0.25, dampingFraction: 0.7)
}

/// Big accent capsule: Play, Resume, Continue.
struct PrimaryButtonStyle: ButtonStyle {
    var height: CGFloat = 50

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .bold))
            .foregroundStyle(Theme.onAccent)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(Capsule().fill(Theme.accent))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(Theme.press, value: configuration.isPressed)
    }
}

/// Square-ish tile with an icon over a label (Restart, Watched, Favourite). `isOn` tints it.
struct TileButtonStyle: ButtonStyle {
    var isOn = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(isOn ? Theme.accent : Theme.text)
            .frame(maxWidth: .infinity)
            .frame(height: 64)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.raised))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(isOn ? Theme.accent : Theme.line, lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(Theme.press, value: configuration.isPressed)
    }
}

/// Cards and rows: shrink slightly while pressed.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(Theme.press, value: configuration.isPressed)
    }
}

/// Round translucent button over video or artwork.
struct CircleButtonStyle: ButtonStyle {
    var size: CGFloat = 40
    var fill: Color = Theme.scrim

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Theme.text)
            .frame(width: size, height: size)
            .background(Circle().fill(fill))
            .contentShape(Circle())
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(Theme.press, value: configuration.isPressed)
    }
}

/// Small rounded pill (libraries, seasons, filters, genres).
struct Pill: View {
    let title: String
    var isSelected = false

    var body: some View {
        Text(title)
            .font(.system(size: 14, weight: .semibold))
            .lineLimit(1)
            .padding(.horizontal, 14)
            .frame(height: 36)
            .foregroundStyle(isSelected ? Theme.onAccent : Theme.text)
            .background(Capsule().fill(isSelected ? Theme.accent : Theme.raised))
            .overlay(Capsule().strokeBorder(isSelected ? Color.clear : Theme.line, lineWidth: 1))
    }
}

/// The app's mark: a play symbol on an accent rounded square, gently "breathing".
struct LogoMark: View {
    var size: CGFloat = 76
    var animated = true

    @State private var breathe = false

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(Theme.accent)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: "play.fill")
                    .font(.system(size: size * 0.38, weight: .bold))
                    .foregroundStyle(Theme.onAccent)
                    .offset(x: size * 0.03)
            }
            .shadow(color: Theme.accent.opacity(0.4), radius: size * 0.22)
            // Only a scale change: cheap for the GPU, unlike animating the shadow.
            .scaleEffect(breathe ? 1.04 : 1)
            .onAppear {
                guard animated else { return }
                withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) {
                    breathe = true
                }
            }
            .accessibilityHidden(true)
    }
}

/// "Couldn't load" with the reason and a Try again button.
struct ErrorState: View {
    let message: String
    let retry: () async -> Void

    @State private var isRetrying = false

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(Theme.text3)
            Text("Couldn't load")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(Theme.text)
            Text(message)
                .font(.system(size: 14))
                .foregroundStyle(Theme.text2)
                .multilineTextAlignment(.center)
            Button {
                Task {
                    isRetrying = true
                    await retry()
                    isRetrying = false
                }
            } label: {
                if isRetrying {
                    ProgressView().tint(Theme.onAccent)
                } else {
                    Text("Try again")
                }
            }
            .buttonStyle(PrimaryButtonStyle(height: 44))
            .frame(width: 180)
            .disabled(isRetrying)
        }
        .padding(32)
        .frame(maxWidth: .infinity)
    }
}

/// Thin accent progress bar on a faint track.
struct ProgressBar: View {
    let fraction: Double
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.15))
                Capsule()
                    .fill(Theme.accent)
                    .frame(width: proxy.size.width * CGFloat(min(max(fraction, 0), 1)))
            }
        }
        .frame(height: height)
    }
}

/// Section heading used on Home and detail pages.
struct SectionTitle: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 20, weight: .bold))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 20)
    }
}

extension View {
    /// Lists and forms on the app background instead of the system grey.
    func themedBackground() -> some View {
        scrollContentBackground(.hidden)
            .background(Theme.background.ignoresSafeArea())
    }
}
