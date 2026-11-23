import JellyfinAPI
import SwiftUI

/// The Filters sheet of a library: genre, decade, age rating, score and quality, one category at a
/// time so it never becomes one long list. Changes apply to the grid behind it straight away.
struct LibraryFiltersView: View {
    let parent: BaseItemDto
    let userID: String
    @Binding var query: LibraryQuery
    let total: Int

    @Environment(SessionStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var category: Category = .genre
    @State private var genres: [String] = []
    @State private var ratings: [String] = []
    @State private var decades: [Int] = []
    @State private var isLoading = true

    private enum Category: String, CaseIterable {
        case genre = "Genre"
        case decade = "Decade"
        case rating = "Age rating"
        case score = "Score"
        case quality = "Quality"
    }

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 10)]
    private let scores: [Int?] = [nil, 5, 6, 7, 8, 9]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Filters")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Theme.text)
                Spacer()
                Button("Reset") {
                    query.clearExtraFilters()
                }
                .font(.system(size: 15, weight: .semibold))
                .disabled(!query.hasExtraFilters)
            }
            .padding(.horizontal, 20)
            .padding(.top, 26)
            .padding(.bottom, 12)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Category.allCases, id: \.self) { item in
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) { category = item }
                        } label: {
                            Pill(title: title(item), isSelected: item == category)
                        }
                        .buttonStyle(PressableStyle())
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.bottom, 8)

            ScrollView {
                options
                    .padding(16)
            }

            Button {
                dismiss()
            } label: {
                Text("Show \(total) \(total == 1 ? "result" : "results")")
            }
            .buttonStyle(PrimaryButtonStyle(height: 50))
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Theme.surface)
        .task { await load() }
    }

    private func title(_ item: Category) -> String {
        let count: Int
        switch item {
        case .genre: count = query.genres.count
        case .decade: count = query.decades.count
        case .rating: count = query.ratings.count
        case .score: count = query.minScore == nil ? 0 : 1
        case .quality: count = (query.only4K ? 1 : 0) + (query.onlyHD ? 1 : 0)
        }
        return count > 0 ? "\(item.rawValue) · \(count)" : item.rawValue
    }

    @ViewBuilder
    private var options: some View {
        switch category {
        case .genre:
            chipGrid(genres, selected: query.genres, label: { $0 }) { flip(\.genres, $0) }
        case .decade:
            chipGrid(decades, selected: query.decades, label: { "\($0)s" }) { flip(\.decades, $0) }
        case .rating:
            chipGrid(ratings, selected: query.ratings, label: { $0 }) { flip(\.ratings, $0) }
        case .score:
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(scores, id: \.self) { score in
                    chip(score.map { "\($0)+" } ?? "Any", isOn: query.minScore == score) {
                        query.minScore = score
                    }
                }
            }
        case .quality:
            LazyVGrid(columns: columns, spacing: 10) {
                chip("4K", isOn: query.only4K) { query.only4K.toggle() }
                chip("HD or better", isOn: query.onlyHD) { query.onlyHD.toggle() }
            }
        }
    }

    /// The values the library offers, as chips; says so when there are none (or they're still loading).
    @ViewBuilder
    private func chipGrid<T: Hashable>(_ values: [T], selected: [T], label: @escaping (T) -> String, tap: @escaping (T) -> Void) -> some View {
        if values.isEmpty {
            if isLoading {
                ProgressView().frame(maxWidth: .infinity).padding(.top, 30)
            } else {
                Text("Nothing to filter by here.")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.text3)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 30)
            }
        } else {
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(values, id: \.self) { value in
                    chip(label(value), isOn: selected.contains(value)) { tap(value) }
                }
            }
        }
    }

    private func chip(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundStyle(isOn ? Theme.onAccent : Theme.text)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity)
                .frame(height: 38)
                .background(Capsule().fill(isOn ? Theme.accent : Theme.raised))
                .overlay(Capsule().strokeBorder(isOn ? Color.clear : Theme.line, lineWidth: 1))
        }
        .buttonStyle(PressableStyle())
    }

    private func flip<T: Equatable>(_ keyPath: WritableKeyPath<LibraryQuery, [T]>, _ value: T) {
        if let index = query[keyPath: keyPath].firstIndex(of: value) {
            query[keyPath: keyPath].remove(at: index)
        } else {
            query[keyPath: keyPath].append(value)
        }
    }

    /// Asks the server what this library contains (genres, age ratings, years).
    private func load() async {
        defer { isLoading = false }
        guard let parentID = parent.id else { return }
        var path = "Items/Filters?userId=\(userID)&parentId=\(parentID)"
        switch parent.collectionType {
        case .movies: path += "&includeItemTypes=Movie"
        case .tvshows: path += "&includeItemTypes=Series"
        case .boxsets: path += "&includeItemTypes=BoxSet"
        default: break
        }
        guard let body = try? await store.adminJSON(path) as? [String: Any] else { return }
        genres = body["Genres"] as? [String] ?? []
        ratings = body["OfficialRatings"] as? [String] ?? []
        let years = body["Years"] as? [Int] ?? []
        decades = Array(Set(years.map { $0 / 10 * 10 })).sorted(by: >)
    }
}
