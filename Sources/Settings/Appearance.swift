import SwiftUI
import UIKit

/// The app's accent colour, chosen in Settings and stored as a hex string.
enum Appearance {
    static let accentKey = "appearance.accent"
    static let defaultAccentHex = "B57BFF"

    static let presets: [(name: String, hex: String)] = [
        ("Bloom purple", "B57BFF"),
        ("Jellyfin purple", "AA5CC3"),
        ("Dark purple", "7B3FBF"),
        ("Jellyfin blue", "00A4DC"),
        ("Pink", "E0559A"),
        ("Green", "34C77B"),
    ]

    /// Builds before the redesign defaulted to Jellyfin purple. Move anyone still on that old default
    /// to the new one, once; a colour the user picked themselves is kept.
    static func migrateDefault() {
        let defaults = UserDefaults.standard
        let migratedKey = "appearance.accentMigrated"
        guard !defaults.bool(forKey: migratedKey) else { return }
        defaults.set(true, forKey: migratedKey)
        if defaults.string(forKey: accentKey) == "AA5CC3" {
            defaults.set(defaultAccentHex, forKey: accentKey)
        }
    }

    static func color(hex: String) -> Color {
        Color(hex: hex) ?? Color(hex: defaultAccentHex) ?? .purple
    }
}

/// The chosen accent. Views that read `Theme.accent` redraw when it changes, wherever they are
/// (including the full-screen player, which doesn't always inherit the app's tint).
@Observable
final class AccentStore {
    static let shared = AccentStore()

    var hex: String {
        didSet { UserDefaults.standard.set(hex, forKey: Appearance.accentKey) }
    }

    var color: Color { Appearance.color(hex: hex) }

    private init() {
        Appearance.migrateDefault()
        hex = UserDefaults.standard.string(forKey: Appearance.accentKey) ?? Appearance.defaultAccentHex
    }
}

/// Applies the accent as the tint for system controls (toggles, links, progress views).
struct AccentTint: ViewModifier {
    func body(content: Content) -> some View {
        content.tint(Theme.accent)
    }
}

extension Color {
    init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") {
            text.removeFirst()
        }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    var hexString: String {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        UIColor(self).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        func byte(_ component: CGFloat) -> Int { Int((min(max(component, 0), 1) * 255).rounded()) }
        return String(format: "%02X%02X%02X", byte(red), byte(green), byte(blue))
    }
}
