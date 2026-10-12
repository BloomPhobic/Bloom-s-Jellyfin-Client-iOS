import Foundation

/// Subtitle look, chosen in the player and remembered across videos.
enum SubtitleSettings {
    static let sizeKey = "subtitles.size"
    static let styleKey = "subtitles.style"
    static let boldKey = "subtitles.bold"

    enum Size: String, CaseIterable, Identifiable {
        case small
        case medium
        case large
        case extraLarge

        var id: String { rawValue }

        var label: String {
            switch self {
            case .small: return "S"
            case .medium: return "M"
            case .large: return "L"
            case .extraLarge: return "XL"
            }
        }

        var scale: Double {
            switch self {
            case .small: return 0.8
            case .medium: return 1.0
            case .large: return 1.25
            case .extraLarge: return 1.5
            }
        }
    }

    enum Style: String, CaseIterable, Identifiable {
        case outline
        case thickOutline
        case box

        var id: String { rawValue }

        var label: String {
            switch self {
            case .outline: return "Outline"
            case .thickOutline: return "Thick outline"
            case .box: return "Background"
            }
        }

        var borderSize: Double {
            switch self {
            case .outline: return 3
            case .thickOutline: return 5
            case .box: return 3
            }
        }
    }

    static var size: Size {
        UserDefaults.standard.string(forKey: sizeKey).flatMap(Size.init(rawValue:)) ?? .medium
    }

    static var style: Style {
        UserDefaults.standard.string(forKey: styleKey).flatMap(Style.init(rawValue:)) ?? .outline
    }

    static var bold: Bool {
        UserDefaults.standard.bool(forKey: boldKey)
    }
}
