import Foundation
import Combine

struct MediaCatalog: Decodable, Sendable {
    let featuredIds: [String]
    let shows: [Show]

    private enum CodingKeys: String, CodingKey {
        case featuredIds, shows
    }

    init(featuredIds: [String], shows: [Show]) {
        self.featuredIds = featuredIds
        self.shows = shows
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var entries = try container.nestedUnkeyedContainer(forKey: .shows)
        let hasEntries = !entries.isAtEnd
        var seenShowIDs = Set<String>()
        var shows = [Show]()
        while !entries.isAtEnd {
            let entry = try entries.superDecoder()
            if let show = try? Show(from: entry),
               !show.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !show.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               seenShowIDs.insert(show.id).inserted {
                shows.append(show)
            }
        }
        if hasEntries && shows.isEmpty {
            throw DecodingError.dataCorruptedError(forKey: .shows, in: container, debugDescription: "No valid catalog entries")
        }
        self.shows = shows
        let requestedFeatured = (try? container.decode([String].self, forKey: .featuredIds)) ?? []
        var seenFeaturedIDs = Set<String>()
        featuredIds = requestedFeatured.filter { seenShowIDs.contains($0) && seenFeaturedIDs.insert($0).inserted }
    }

    static func load() throws -> Self {
        guard let file = Bundle.main.url(forResource: "catalog", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let decoder = JSONDecoder()
        let base = try decoder.decode(Self.self, from: Data(contentsOf: file))
        guard let starter = Bundle.main.url(forResource: "online-starter", withExtension: "json"),
              let extra = try? decoder.decode(Self.self, from: Data(contentsOf: starter)) else { return base }
        var existing = Set(base.shows.map(\.id))
        let added = extra.shows.filter { existing.insert($0.id).inserted }
        return Self(featuredIds: base.featuredIds, shows: base.shows + added)
    }

    var featured: [Show] {
        featuredIds.compactMap { id in shows.first { $0.id == id } }
    }
}

struct Show: Decodable, Identifiable, Hashable, Sendable {
    private(set) var id: String
    let title: String
    let original: String
    let year: String
    let length: String
    let genres: [String]
    let description: String
    private(set) var image: String
    private(set) var hero: String?
    let region: String?
    let languages: [String]?
    let creators: [String]?
    let totalEpisodes: Int?
    let releaseStatus: String?
    let source: URL
    private(set) var repository: URL?
    let credit: String
    let license: String
    private(set) var licenseUrl: URL?
    let changes: String?
    private(set) var episodes: [Episode]

    func importedFromPublisher(namespace: String) -> Self? {
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              CatalogAddress.isHTTPS(source), let totalEpisodes, totalEpisodes > 0,
              episodes.count >= totalEpisodes else { return nil }

        var show = self
        show.id = "publisher/\(namespace)/\(id)"
        show.image = CatalogAddress.parse(image)?.absoluteString ?? ""
        show.hero = hero.flatMap { CatalogAddress.parse($0)?.absoluteString }
        show.repository = repository.flatMap { CatalogAddress.isHTTPS($0) ? $0 : nil }
        show.licenseUrl = licenseUrl.flatMap { CatalogAddress.isHTTPS($0) ? $0 : nil }
        show.episodes = episodes.map { $0.importedFromPublisher() }
        let playableNumbers = show.playableEpisodeIndices.map { show.episodeNumber(at: $0) }
        guard playableNumbers.count == totalEpisodes, playableNumbers.last == totalEpisodes else { return nil }
        return show
    }

    func episodeNumber(at index: Int) -> Int {
        episodes[index].number ?? index + 1
    }

    var episodeIndices: [Int] {
        var rowIndexByNumber = [Int: Int]()
        for index in episodes.indices {
            let number = episodeNumber(at: index)
            guard number > 0 else { continue }
            if let previous = rowIndexByNumber[number] {
                guard !episodes[previous].isPlayable, episodes[index].isPlayable else { continue }
            }
            rowIndexByNumber[number] = index
        }
        return rowIndexByNumber.sorted { $0.key < $1.key }.map(\.value)
    }

    var playableEpisodeIndices: [Int] {
        episodeIndices.filter { episodes[$0].isPlayable }
    }

    func nextEpisode(after index: Int) -> Int? {
        guard episodes.indices.contains(index) else { return nil }
        let number = episodeNumber(at: index)
        let (nextNumber, overflow) = number.addingReportingOverflow(1)
        guard number > 0, !overflow else { return nil }
        return playableEpisodeIndices.first { episodeNumber(at: $0) == nextNumber }
    }

    var episodeSummary: String? {
        guard totalEpisodes != nil || episodes.count > 1 || episodes.first?.number != nil else { return nil }
        let playable = playableEpisodeIndices.map { episodeNumber(at: $0) }
        guard let totalEpisodes, totalEpisodes > 0, (playable.last ?? 0) <= totalEpisodes else {
            return "可播 \(playable.count) 集"
        }
        return totalEpisodes == playable.count ? "全 \(totalEpisodes) 集" : "可播 \(playable.count)/\(totalEpisodes) 集"
    }

    var metadata: [String] {
        [year, region, genres.first, episodeSummary ?? length, releaseStatus]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
    }

    var searchText: String {
        var fields = [title, original, description, region ?? "", credit]
        fields.append(contentsOf: genres)
        fields.append(contentsOf: creators ?? [])
        fields.append(contentsOf: languages ?? [])
        for episode in episodes {
            fields.append(episode.title)
            if let synopsis = episode.description { fields.append(synopsis) }
        }
        return fields.joined(separator: " ")
    }
}

struct Episode: Decodable, Hashable, Sendable {
    let number: Int?
    let title: String
    let original: String?
    let description: String?
    let durationLabel: String?
    let credit: String?
    let license: String?
    private(set) var source: URL?
    private(set) var sources: [URL]
    private(set) var subtitles: String?
    private let sourceQualities: [String: Int]
    private var bundledVideo: String?
    private var officialBilibiliID: String?

    private enum CodingKeys: String, CodingKey {
        case number, title, original, description, durationLabel, credit, license, source, sources, subtitles, bundledVideo
        case officialBilibiliID, sourceQualities
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        number = try container.decodeIfPresent(Int.self, forKey: .number)
        title = try container.decode(String.self, forKey: .title)
        original = try container.decodeIfPresent(String.self, forKey: .original)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        durationLabel = try container.decodeIfPresent(String.self, forKey: .durationLabel)
        credit = try container.decodeIfPresent(String.self, forKey: .credit)
        license = try container.decodeIfPresent(String.self, forKey: .license)
        source = try container.decodeIfPresent(URL.self, forKey: .source)
        subtitles = try container.decodeIfPresent(String.self, forKey: .subtitles)
        bundledVideo = try container.decodeIfPresent(String.self, forKey: .bundledVideo)
        officialBilibiliID = try container.decodeIfPresent(String.self, forKey: .officialBilibiliID)
        sourceQualities = try container.decodeIfPresent([String: Int].self, forKey: .sourceQualities) ?? [:]

        var urls = [URL]()
        if var entries = try? container.nestedUnkeyedContainer(forKey: .sources) {
            while !entries.isAtEnd {
                let entry = try entries.superDecoder()
                if let url = try? entry.singleValueContainer().decode(URL.self) { urls.append(url) }
            }
        }
        sources = urls
    }

    func importedFromPublisher() -> Self {
        var episode = self
        episode.source = source.flatMap { CatalogAddress.isHTTPS($0) ? $0 : nil }
        episode.sources = sources.filter(CatalogAddress.isHTTPS)
        episode.subtitles = nil
        episode.bundledVideo = nil
        episode.officialBilibiliID = nil
        return episode
    }

    var officialPlayerURL: URL? {
        guard let videoID = officialBilibiliID,
              videoID.range(of: "^BV[0-9A-Za-z]{10}$", options: .regularExpression) != nil else { return nil }
        var url = URLComponents()
        url.scheme = "https"
        url.host = "player.bilibili.com"
        url.path = "/player.html"
        url.queryItems = [
            URLQueryItem(name: "bvid", value: videoID),
            URLQueryItem(name: "p", value: "1"),
            URLQueryItem(name: "autoplay", value: "1"),
            URLQueryItem(name: "danmaku", value: "0"),
            URLQueryItem(name: "muted", value: "0"),
        ]
        return url.url
    }

    var isPlayable: Bool {
        officialPlayerURL != nil || !playableSources.isEmpty
    }

    var availableQualities: [Int] {
        Set(playableSources.compactMap(quality(of:))).sorted(by: >)
    }

    func quality(of url: URL) -> Int? {
        guard let height = sourceQualities[url.absoluteString], height > 0 else { return nil }
        return height
    }

    func playableSources(preferringQuality preferred: Int?) -> [URL] {
        let urls = playableSources
        guard let preferred else { return urls }
        let byQuality = Dictionary(grouping: urls, by: quality(of:))
        let knownQualities = byQuality.keys.compactMap { $0 }.sorted()
        let lower = knownQualities.reversed().filter { $0 < preferred }
        let higher = knownQualities.filter { $0 > preferred }
        let preferredOrder = [preferred] + lower + higher
        return preferredOrder.flatMap { byQuality[$0] ?? [] } + (byQuality[nil] ?? [])
    }

    var playableSources: [URL] {
        var seen = Set<URL>()
        var results = sources.filter { url in
            guard let host = url.host?.lowercased(), !host.isEmpty else { return false }
            let scheme = url.scheme?.lowercased()
            let isLocalHost = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
            return (scheme == "https" || (scheme == "http" && isLocalHost)) && seen.insert(url).inserted
        }
        if let name = bundledVideo, !name.contains("/"), !name.contains("\\"),
           (name as NSString).pathExtension.lowercased() == "mp4",
           let resource = Bundle.main.url(forResource: name, withExtension: nil, subdirectory: "assets/videos"),
           FileManager.default.isReadableFile(atPath: resource.path) {
            results.append(resource)
        }
        return results
    }
}

struct Caption {
    let start: Double
    let end: Double
    let text: String

    static func load(at path: String?) -> [Self] {
        guard let path,
              let url = Bundle.main.resourceURL?.appendingPathComponent(path),
              let file = try? String(contentsOf: url, encoding: .utf8) else { return [] }

        return file.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n").compactMap { block in
            let lines = block.split(separator: "\n").map(String.init)
            guard let index = lines.firstIndex(where: { $0.contains(" --> ") }) else { return nil }
            let times = lines[index].components(separatedBy: " --> ")
            guard times.count == 2, let start = seconds(times[0]), let end = seconds(times[1]), end > start else { return nil }
            let text = lines.dropFirst(index + 1).joined(separator: "\n").replacingOccurrences(of: "</?[^>]+>", with: "", options: .regularExpression)
            return text.isEmpty ? nil : Self(start: start, end: end, text: text)
        }
    }

    private static func seconds(_ value: String) -> Double? {
        let parts = value.split(separator: " ").first?.split(separator: ":").compactMap { Double($0) } ?? []
        guard (2...3).contains(parts.count) else { return nil }
        return parts.reduce(0) { $0 * 60 + $1 }
    }
}

struct Record: Codable {
    let episode: Int
    let episodeNumber: Int?
    let time: Double
    let ended: Bool
    let updated: Date

    var publishedEpisodeNumber: Int? {
        if let episodeNumber { return episodeNumber > 0 ? episodeNumber : nil }
        let (legacyNumber, overflow) = episode.addingReportingOverflow(1)
        return !overflow && legacyNumber > 0 ? legacyNumber : nil
    }
}

@MainActor
final class Library: ObservableObject {
    @Published private(set) var saved: Set<String>
    @Published private(set) var records: [String: Record]
    private let defaults: UserDefaults
    private var lastWrite = Date.distantPast

    init(defaults: UserDefaults = CinemaProfile.defaults) {
        self.defaults = defaults
        saved = Set(defaults.stringArray(forKey: "interval-favorites") ?? [])
        records = defaults.data(forKey: "interval-progress")
            .flatMap { try? JSONDecoder().decode([String: Record].self, from: $0) } ?? [:]
    }

    func toggle(_ show: Show) {
        if saved.contains(show.id) { saved.remove(show.id) } else { saved.insert(show.id) }
        defaults.set(Array(saved), forKey: "interval-favorites")
    }

    func update(_ show: Show, episode: Int, time: Double, ended: Bool = false) {
        guard show.playableEpisodeIndices.contains(episode), time.isFinite, time >= 1 || ended else { return }
        let number = show.episodeNumber(at: episode)
        let previous = records[show.id]
        if !ended, previous?.episodeNumber == number, previous?.ended == false,
           previous.map({ abs($0.time - time) < 0.8 }) == true { return }
        records[show.id] = Record(episode: episode, episodeNumber: number, time: time, ended: ended, updated: Date())
        if ended || Date().timeIntervalSince(lastWrite) >= 1 { persist() }
    }

    func rememberEpisode(_ show: Show, at index: Int) {
        guard show.playableEpisodeIndices.contains(index) else { return }
        records[show.id] = Record(episode: index, episodeNumber: show.episodeNumber(at: index),
                                  time: 0, ended: false, updated: Date())
        persist()
    }

    func resume(_ show: Show) -> (episode: Int, time: Double) {
        let fallback = (episode: show.playableEpisodeIndices.first ?? 0, time: 0.0)
        guard let record = records[show.id],
              let index = indexForRecord(record, in: show) else { return fallback }
        if record.ended {
            guard let next = show.nextEpisode(after: index) else { return fallback }
            return (next, 0)
        }
        guard show.playableEpisodeIndices.contains(index) else { return fallback }
        return (index, record.time.isFinite ? max(record.time, 0) : 0)
    }

    func watching(_ show: Show) -> Bool {
        guard let record = records[show.id],
              let index = indexForRecord(record, in: show) else { return false }
        return record.ended ? show.nextEpisode(after: index) != nil : show.playableEpisodeIndices.contains(index)
    }

    private func indexForRecord(_ record: Record, in show: Show) -> Int? {
        guard let number = record.publishedEpisodeNumber else { return nil }
        return show.episodeIndices.first { show.episodeNumber(at: $0) == number }
    }

    func persist() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: "interval-progress")
        lastWrite = Date()
    }
}
