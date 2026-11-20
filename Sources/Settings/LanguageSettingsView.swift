import JellyfinAPI
import SwiftUI

/// Settings > Playback > Languages: the default wishes, and optional wishes per library.
struct LanguageSettingsView: View {
    @Environment(SessionStore.self) private var store
    @State private var libraries: [BaseItemDto] = []
    @State private var refresh = 0

    var body: some View {
        List {
            Section {
                NavigationLink("Default languages") {
                    LanguageEditorPage(title: "Default languages", libraryID: nil)
                }
            } footer: {
                Text("Used for every library that doesn't have its own choice. List several in order: the first one a video has is used, otherwise the video's own default.")
            }
            if !libraries.isEmpty {
                Section("Per library") {
                    ForEach(libraries, id: \.id) { library in
                        if let id = library.id {
                            NavigationLink {
                                LanguageEditorPage(title: library.name ?? "Library", libraryID: id)
                            } label: {
                                LabeledContent(library.name ?? "Library",
                                               value: LanguagePreference.custom(for: id) == nil ? "Default languages" : "Own choice")
                                    .id(refresh)
                            }
                        }
                    }
                }
            }
        }
        .onAppear { refresh += 1 }
        .themedBackground()
        .navigationTitle("Languages")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard let userID = store.session?.userID, let api = store.apiForDownloads(userID: userID) else { return }
            libraries = (try? await api.libraries()) ?? []
        }
    }
}

/// Edits one set of wishes: the default (`libraryID` nil) or a single library's.
private struct LanguageEditorPage: View {
    let title: String
    let libraryID: String?
    @State private var preference = LanguagePreference()
    @State private var usesDefault = true

    var body: some View {
        List {
            if libraryID != nil {
                Section {
                    Toggle("Use the default languages", isOn: $usesDefault)
                }
            }
            if libraryID == nil || !usesDefault {
                wishSection("Audio", footer: "\"Original\" is the track the file lists first as its main one, so a German show plays in German and a Turkish one in Turkish. It relies on how the file was tagged.",
                            ids: $preference.audio, special: LanguagePreference.original)
                wishSection("Subtitles", footer: "\"Off\" means no subtitles. If none of these exist in a video, its own default is used.",
                            ids: $preference.subtitles, special: LanguagePreference.off)
            }
        }
        .environment(\.editMode, .constant(.active))
        .themedBackground()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if let libraryID {
                let custom = LanguagePreference.custom(for: libraryID)
                usesDefault = custom == nil
                preference = custom ?? LanguagePreference.standard
            } else {
                preference = LanguagePreference.standard
            }
        }
        .onChange(of: preference) { save() }
        .onChange(of: usesDefault) { save() }
    }

    private func save() {
        if let libraryID {
            LanguagePreference.setCustom(usesDefault ? nil : preference, for: libraryID)
        } else {
            LanguagePreference.standard = preference
        }
    }

    private func wishSection(_ name: String, footer: String, ids: Binding<[String]>, special: String) -> some View {
        Section {
            ForEach(Array(ids.wrappedValue.enumerated()), id: \.element) { index, id in
                Text("\(index + 1). \(LanguageOption.name(of: id))")
            }
            .onMove { ids.wrappedValue.move(fromOffsets: $0, toOffset: $1) }
            .onDelete { ids.wrappedValue.remove(atOffsets: $0) }
            Menu {
                let all = [special] + LanguageOption.all.map(\.id)
                ForEach(all.filter { !ids.wrappedValue.contains($0) }, id: \.self) { id in
                    Button(LanguageOption.name(of: id)) { ids.wrappedValue.append(id) }
                }
            } label: {
                Label("Add a language", systemImage: "plus.circle")
            }
        } header: {
            Text(name)
        } footer: {
            Text(footer)
        }
    }
}
