import Foundation
import JellyfinAPI

/// A language people can pick. `codes` are the tags files use (3-letter and 2-letter).
struct LanguageOption: Identifiable, Hashable {
    let id: String
    let name: String
    let codes: [String]

    static let all: [LanguageOption] = [
        ("eng", "English", ["en"]), ("tur", "Turkish", ["tr"]), ("jpn", "Japanese", ["ja", "jp"]),
        ("ger", "German", ["de", "deu"]), ("fre", "French", ["fr", "fra"]), ("spa", "Spanish", ["es"]),
        ("ita", "Italian", ["it"]), ("por", "Portuguese", ["pt"]), ("rus", "Russian", ["ru"]),
        ("kor", "Korean", ["ko"]), ("chi", "Chinese", ["zh", "zho", "cmn"]), ("ara", "Arabic", ["ar"]),
        ("dut", "Dutch", ["nl", "nld"]), ("pol", "Polish", ["pl"]), ("swe", "Swedish", ["sv"]),
        ("hin", "Hindi", ["hi"]), ("ukr", "Ukrainian", ["uk"]), ("gre", "Greek", ["el", "ell"]),
    ].map { LanguageOption(id: $0.0, name: $0.1, codes: [$0.0] + $0.2) }

    static func name(of id: String) -> String {
        switch id {
        case LanguagePreference.original: return "Original"
        case LanguagePreference.off: return "Off"
        default: return all.first { $0.id == id }?.name ?? id
        }
    }

    /// Whether a track's language tag (as the file wrote it) is this language.
    func matches(_ tag: String?) -> Bool {
        guard let tag = tag?.lowercased(), !tag.isEmpty else { return false }
        return codes.contains(tag)
    }
}

/// Ordered wishes for audio and subtitles. The first one the video has wins; if none is there the
/// video's own default is left alone.
struct LanguagePreference: Codable, Equatable {
    /// "Original" (audio only): the track the file lists as its main one.
    static let original = "original"
    /// "Off" (subtitles only): no subtitles.
    static let off = "off"

    var audio: [String] = []
    var subtitles: [String] = []

    private static let defaultKey = "languages.default"
    private static func libraryKey(_ id: String) -> String { "languages.library.\(id)" }
    private static let libraryOfKey = "languages.libraryOf"

    private static func load(_ key: String) -> LanguagePreference? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(LanguagePreference.self, from: $0) }
    }

    private static func save(_ value: LanguagePreference?, _ key: String) {
        UserDefaults.standard.set(value.flatMap { try? JSONEncoder().encode($0) }, forKey: key)
    }

    static var standard: LanguagePreference {
        get { load(defaultKey) ?? LanguagePreference() }
        set { save(newValue, defaultKey) }
    }

    /// A library's own wishes, or nil when it follows the default.
    static func custom(for libraryID: String) -> LanguagePreference? { load(libraryKey(libraryID)) }

    static func setCustom(_ value: LanguagePreference?, for libraryID: String) {
        save(value, libraryKey(libraryID))
    }

    static func effective(libraryID: String?) -> LanguagePreference {
        libraryID.flatMap { custom(for: $0) } ?? standard
    }

    // MARK: Which library an item is in (remembered, so it also works offline)

    /// `key` is the show's ID for episodes, otherwise the item's own ID.
    static func rememberedLibrary(for key: String?) -> String? {
        guard let key else { return nil }
        return (UserDefaults.standard.dictionary(forKey: libraryOfKey) as? [String: String])?[key]
    }

    static func remember(library: String, for key: String) {
        var map = (UserDefaults.standard.dictionary(forKey: libraryOfKey) as? [String: String]) ?? [:]
        map[key] = library
        UserDefaults.standard.set(map, forKey: libraryOfKey)
    }

    static func key(for item: BaseItemDto) -> String? { item.seriesID ?? item.id }

    // MARK: Choosing tracks

    struct Track {
        let id: Int
        let language: String?
        let isDefault: Bool
        let isForced: Bool
    }

    /// The audio track to use, or nil to keep the video's own choice.
    func pickAudio(from tracks: [Track]) -> Int? {
        for wish in audio {
            if wish == Self.original {
                return (tracks.first { $0.isDefault } ?? tracks.first)?.id
            }
            if let option = LanguageOption.all.first(where: { $0.id == wish }),
               let track = tracks.first(where: { option.matches($0.language) }) {
                return track.id
            }
        }
        return nil
    }

    /// `.some(nil)` means turn subtitles off; `nil` keeps the video's own choice.
    func pickSubtitle(from tracks: [Track]) -> Int?? {
        for wish in subtitles {
            if wish == Self.off { return .some(nil) }
            guard let option = LanguageOption.all.first(where: { $0.id == wish }) else { continue }
            let found = tracks.filter { option.matches($0.language) }
            if let track = found.first(where: { !$0.isForced }) ?? found.first {
                return .some(track.id)
            }
        }
        return nil
    }
}
