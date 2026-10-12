import SwiftUI
import UIKit

/// The app's accent colour, chosen in Settings and stored as a hex string.
enum Appearance {
    static let accentKey = "appearance.accent"
    static let defaultAccentHex = "AA5CC3"

    static let presets: [(name: String, hex: String)] = [
        ("Jellyfin purple", "AA5CC3"),
        ("Dark purple", "7B3FBF"),
        ("Jellyfin blue", "00A4DC"),
        ("Pink", "E0559A"),
        ("Green", "34C77B"),
        ("Orange", "F28C28"),
    ]

    static func color(hex: String) -> Color {
        Color(hex: hex) ?? Color(hex: defaultAccentHex) ?? .purple
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
