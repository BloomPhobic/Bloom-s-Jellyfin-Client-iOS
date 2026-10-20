import JellyfinAPI
import SwiftUI

/// "Cast & crew": actors first (with their role), then directors, writers and the rest.
/// Each opens the person's page.
struct CastRow: View {
    let item: BaseItemDto
    let api: LibraryAPI

    var body: some View {
        let people = Self.credits(item.people ?? [])
        if !people.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(text: "Cast & crew")
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(people) { credit in
                            NavigationLink(value: BrowseRoute.item(credit.personItem)) {
                                PersonCard(credit: credit, api: api)
                            }
                            .buttonStyle(PressableStyle())
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
    }

    /// One entry per person, with all their jobs on this title ("Director, Writer").
    static func credits(_ people: [BaseItemPerson]) -> [Credit] {
        let order: [PersonKind] = [.actor, .guestStar, .director, .writer, .producer, .composer]
        func rank(_ person: BaseItemPerson) -> Int {
            person.type.flatMap { order.firstIndex(of: $0) } ?? order.count
        }
        var credits: [Credit] = []
        var positions: [String: Int] = [:]
        // A stable sort keeps the server's billing order inside each group.
        let sorted = people.enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element)
        for person in sorted {
            guard let id = person.id, let name = person.name else { continue }
            let job = Credit.job(person)
            if let position = positions[id] {
                if let job, !credits[position].jobs.contains(job) {
                    credits[position].jobs.append(job)
                }
                continue
            }
            positions[id] = credits.count
            credits.append(Credit(id: id, name: name, imageTag: person.primaryImageTag, jobs: job.map { [$0] } ?? []))
        }
        return Array(credits.prefix(40))
    }
}

/// A person on a title, with what they did on it.
struct Credit: Identifiable {
    let id: String
    let name: String
    let imageTag: String?
    var jobs: [String]

    /// The character for actors, otherwise the job.
    static func job(_ person: BaseItemPerson) -> String? {
        switch person.type {
        case .actor, .guestStar:
            return person.role.flatMap { $0.isEmpty ? nil : $0 }
        case .director: return "Director"
        case .writer: return "Writer"
        case .producer: return "Producer"
        case .composer: return "Composer"
        case .none, .unknown: return person.role
        case .some(let kind): return kind.rawValue
        }
    }

    var personItem: BaseItemDto {
        var item = BaseItemDto()
        item.id = id
        item.name = name
        item.type = .person
        return item
    }
}

/// Round photo, name and role.
private struct PersonCard: View {
    let credit: Credit
    let api: LibraryAPI

    var body: some View {
        VStack(spacing: 6) {
            PersonPhoto(url: api.imageURL(credit.imageTag.map { ImageRef(itemID: credit.id, type: .primary, tag: $0) }, maxWidth: 200))
                .frame(width: 76, height: 76)
            Text(credit.name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.text)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            if !credit.jobs.isEmpty {
                Text(credit.jobs.joined(separator: ", "))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.text3)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(width: 84)
        .contentShape(Rectangle())
    }
}

/// A person's photo in a circle, or an outline figure when there isn't one.
private struct PersonPhoto: View {
    let url: URL?

    var body: some View {
        ZStack {
            Circle().fill(Theme.raised2)
            if url == nil {
                Image(systemName: "person.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(Theme.text3.opacity(0.6))
            } else {
                RemoteImage(url: url)
                    .clipShape(Circle())
            }
        }
        .overlay(Circle().strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
    }
}

/// "More like this": titles from your own library that the server finds similar.
struct SimilarRow: View {
    let item: BaseItemDto
    let api: LibraryAPI

    @State private var items: [BaseItemDto] = []

    var body: some View {
        Group {
            if !items.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    SectionTitle(text: "More like this")
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 12) {
                            ForEach(items, id: \.id) { similar in
                                NavigationLink(value: BrowseRoute.item(similar)) {
                                    PosterCard(item: similar, api: api)
                                        .frame(width: 108)
                                }
                                .buttonStyle(PressableStyle())
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
                .transition(.opacity)
            }
        }
        .task(id: item.id) {
            guard items.isEmpty, let id = item.id else { return }
            do {
                let found = try await api.similar(to: id)
                withAnimation(.easeOut(duration: 0.25)) { items = found }
            } catch {
                if !AuthWatch.isCancellation(error) {
                    AppLog.shared.log("No similar titles: \(error.localizedDescription)", level: .warning)
                }
            }
        }
    }
}

/// An actor's or director's page: photo, birth details, biography, and what of theirs is in your library.
struct PersonView: View {
    let api: LibraryAPI
    let personID: String

    @State private var person: BaseItemDto?
    @State private var titles: [BaseItemDto] = []
    @State private var hasLoaded = false
    @State private var errorMessage: String?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: 3)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let person {
                    header(person)
                    if let overview = person.overview, !overview.isEmpty {
                        ExpandableText(text: overview)
                            .padding(.horizontal, 20)
                    }
                }
                section("Movies", titles.filter { $0.type == .movie })
                section("Shows", titles.filter { $0.type == .series })
                if hasLoaded && titles.isEmpty && errorMessage == nil {
                    Text("Nothing else of theirs is in your library.")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.text3)
                        .padding(.horizontal, 20)
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .background(Theme.background.ignoresSafeArea())
        .overlay {
            if !hasLoaded {
                ProgressView()
            } else if person == nil, let errorMessage {
                ErrorState(message: errorMessage) { await load() }
            }
        }
        .navigationTitle(person?.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard !hasLoaded else { return }
            await load()
        }
    }

    private func header(_ person: BaseItemDto) -> some View {
        HStack(spacing: 16) {
            PersonPhoto(url: api.imageURL(Artwork.poster(person), maxWidth: 300))
                .frame(width: 104, height: 104)
            VStack(alignment: .leading, spacing: 4) {
                Text(person.name ?? "")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                ForEach(Self.lifeLines(person), id: \.self) { line in
                    Text(line)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.text2)
                }
            }
        }
        .padding(.horizontal, 20)
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [BaseItemDto]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(text: title)
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(items, id: \.id) { item in
                        NavigationLink(value: BrowseRoute.item(item)) {
                            PosterCard(item: item, api: api)
                        }
                        .buttonStyle(PressableStyle())
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    /// "Born 12 March 1970 · London" and "Died ...", when the server knows them.
    private static func lifeLines(_ person: BaseItemDto) -> [String] {
        var lines: [String] = []
        if let born = person.premiereDate {
            var line = "Born " + born.formatted(date: .long, time: .omitted)
            if let place = person.productionLocations?.first, !place.isEmpty {
                line += " · " + place
            }
            lines.append(line)
        }
        if let died = person.endDate {
            lines.append("Died " + died.formatted(date: .long, time: .omitted))
        }
        return lines
    }

    private func load() async {
        errorMessage = nil
        defer { hasLoaded = true }
        async let details = api.item(personID)
        async let found = api.titles(withPerson: personID)
        do {
            person = try await details
        } catch {
            guard !AuthWatch.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
            AppLog.shared.log("Couldn't load person: \(error.localizedDescription)", level: .error)
        }
        titles = (try? await found) ?? []
    }
}
