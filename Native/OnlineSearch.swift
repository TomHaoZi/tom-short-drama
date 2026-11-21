import Combine
import Foundation

struct OnlineSearchPage: Sendable {
    let data: Data
    let hasNext: Bool
}

func writeSearchRows(_ rows: [[String: Any]], allowEmpty: Bool) throws -> Data {
    guard allowEmpty || !rows.isEmpty else { throw URLError(.cannotParseResponse) }
    return try JSONSerialization.data(withJSONObject: ["shows": rows], options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
}

enum OnlineSearch: String, CaseIterable, Sendable {
    case archive, blender

    var title: String { self == .archive ? ProductionSource.archive.title : ProductionSource.blender.title }
    var source: ProductionSource { self == .archive ? .archive : .blender }

    static func escape(_ query: String) throws -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) else { throw URLError(.badURL) }
        return encoded
    }

    func search(_ query: String, page: Int) async throws -> OnlineSearchPage {
        guard (1...12).contains(page) else { throw URLError(.badURL) }
        switch self {
        case .archive: return try await ArchiveCatalog.search(query, page: page)
        case .blender: return try await BlenderCatalog.search(query, page: page)
        }
    }
}

struct SearchRelevance {
    private let phrase: String
    private let tokens: [String]

    init(_ query: String) {
        phrase = Self.normalize(query)
        tokens = query.split(whereSeparator: \.isWhitespace).map { Self.normalize(String($0)) }.filter { !$0.isEmpty }
    }

    private static func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive], locale: nil)
            .filter { !$0.isWhitespace && !$0.isPunctuation }
    }

    func score(title: String, metadata: String) -> Int? {
        guard !phrase.isEmpty else { return 3 }
        let name = Self.normalize(title)
        if name == phrase { return 0 }
        if name.contains(phrase) || tokens.allSatisfy({ name.contains($0) }) { return 1 }
        let details = Self.normalize(title + " " + metadata)
        if details.contains(phrase) || tokens.allSatisfy({ details.contains($0) }) { return 2 }
        return nil
    }
}

@MainActor
final class OnlineSearchState: ObservableObject {
    struct Result: Identifiable {
        var id: String { show.id }
        let show: Show
        let payload: Data
        let source: ProductionSource
    }

    struct Failure: Equatable {
        let title: String
        let reason: SourceFailure
        var text: String { "\(title)（\(reason.text)）" }
    }

    @Published private(set) var results: [Result] = []
    @Published private(set) var searched = ""
    @Published private(set) var busy = false
    @Published private(set) var failures: [Failure] = []
    @Published private(set) var hasMore = false
    private var next: [OnlineSearch: Int] = [:]
    private var request: Task<Void, Never>?
    private var generation = UUID()
    private let performSearch: @Sendable (OnlineSearch, String, Int) async throws -> OnlineSearchPage

    init(performSearch: @escaping @Sendable (OnlineSearch, String, Int) async throws -> OnlineSearchPage = {
        try await $0.search($1, page: $2)
    }) {
        self.performSearch = performSearch
    }

    func submit(_ text: String) {
        let query = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
        guard !query.isEmpty else { return }
        request?.cancel()
        generation = UUID()
        searched = query
        results = []
        next = Dictionary(uniqueKeysWithValues: OnlineSearch.allCases.map { ($0, 1) })
        loadMore()
    }

    func more() {
        guard !busy, hasMore else { return }
        loadMore()
    }

    func invalidate() {
        generation = UUID()
        request?.cancel()
        request = nil
        busy = false
        hasMore = false
        failures = []
        results = []
        searched = ""
    }

    private func loadMore() {
        let id = generation
        let query = searched
        let pages = next
        failures = []
        busy = true
        hasMore = false
        request = Task { [weak self] in
            guard let perform = self?.performSearch else { return }
            await withTaskGroup(of: (OnlineSearch, OnlineSearchPage?, SourceFailure?).self) { group in
                for (source, number) in pages {
                    group.addTask {
                        do { return (source, try await perform(source, query, number), nil) }
                        catch { return (source, nil, SourceFailure.classify(error)) }
                    }
                }
                for await (source, result, failure) in group {
                    guard !Task.isCancelled, let self, self.generation == id else { group.cancelAll(); return }
                    if let failure {
                        if failure != .cancelled {
                            self.failures.append(Failure(title: source.title, reason: failure))
                        }
                        continue
                    }
                    guard let result, let shows = try? JSONDecoder().decode(MediaCatalog.self, from: result.data).shows else {
                        self.failures.append(Failure(title: source.title, reason: .content))
                        continue
                    }
                    if result.hasNext, let current = pages[source], current < 12 { self.next[source] = current + 1 }
                    else { self.next[source] = nil }
                    var seen = Set(self.results.map(\.id))
                    let relevance = SearchRelevance(query)
                    self.results += shows.filter { show in
                        relevance.score(title: show.title, metadata: show.searchText) != nil && seen.insert(show.id).inserted
                    }.map { Result(show: $0, payload: result.data, source: source.source) }
                    self.results = self.results.map { match in
                        (match, relevance.score(title: match.show.title, metadata: match.show.searchText) ?? 3)
                    }.sorted { lhs, rhs in
                        if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
                        return lhs.0.id < rhs.0.id
                    }.map(\.0)
                }
                if let self, self.generation == id {
                    self.busy = false
                    self.hasMore = !self.next.isEmpty
                }
            }
        }
    }
}
