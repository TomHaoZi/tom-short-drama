import Foundation

enum ProductionSource: String, CaseIterable, Identifiable, Sendable {
    case guangzhou, blender, archive

    var id: Self { self }
    var title: String {
        switch self {
        case .guangzhou: return "广州微短剧"
        case .blender: return "Blender 动画"
        case .archive: return "国会图书馆经典"
        }
    }
    var prefix: String { "online-\(rawValue)-" }

    func owns(_ show: Show) -> Bool { show.id.hasPrefix(prefix) }

    func fetch() async throws -> Data {
        switch self {
        case .guangzhou: return try await GuangzhouCatalog.load()
        case .blender: return try await BlenderCatalog.load()
        case .archive: return try await ArchiveCatalog.load()
        }
    }

    func decode(_ data: Data) throws -> [Show] {
        let catalog = try JSONDecoder().decode(MediaCatalog.self, from: data)
        guard !catalog.shows.isEmpty, catalog.shows.allSatisfy({ show in
            owns(show) && CatalogAddress.isHTTPS(show.source) && show.episodeIndices == show.playableEpisodeIndices
                && show.episodes.count == show.episodeIndices.count && !show.episodes.isEmpty && show.episodes.allSatisfy {
                    !$0.sources.isEmpty && $0.sources.allSatisfy(CatalogAddress.isHTTPS)
                }
        }) else { throw ProductionError.content }
        return catalog.shows
    }
}

enum SourceFailure: Equatable, Sendable {
    case timeout, network, http, content, cancelled

    var text: String {
        switch self {
        case .timeout: return "超时"
        case .network: return "网络不可用"
        case .http: return "服务无响应"
        case .content: return "目录无法解析"
        case .cancelled: return "已取消"
        }
    }

    static func classify(_ error: Error) -> SourceFailure {
        if error is CancellationError { return .cancelled }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled: return .cancelled
            case .timedOut: return .timeout
            default: return .network
            }
        }
        if let production = error as? ProductionError {
            switch production {
            case .response, .limit: return .http
            case .content: return .content
            }
        }
        return .network
    }
}

enum ProductionError: Error { case response, content, limit }

struct OnlineHTTP {
    func get(_ url: URL) async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 15
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration, delegate: PublisherRedirects(endpoint: url), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(from: url)
        let maxBytes = 2 * 1024 * 1024
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let returned = http.url, CatalogAddress.sameOrigin(url, returned),
              response.expectedContentLength <= maxBytes else { throw ProductionError.response }
        var data = Data()
        for try await byte in bytes {
            guard data.count < maxBytes else { throw ProductionError.limit }
            data.append(byte)
        }
        return data
    }
}

private func matches(_ pattern: String, in text: String) -> [[String]] {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match in
        (1..<match.numberOfRanges).map { Range(match.range(at: $0), in: text).map { String(text[$0]) } ?? "" }
    }
}

private func plainText(_ value: String) -> String {
    value.replacingOccurrences(of: "&quot;", with: "\"")
        .replacingOccurrences(of: "&#39;", with: "'")
        .replacingOccurrences(of: "&amp;", with: "&")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

private func catalogData(_ shows: [[String: Any]]) throws -> Data {
    guard !shows.isEmpty else { throw ProductionError.content }
    return try JSONSerialization.data(withJSONObject: ["shows": shows], options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
}

private func parallelMap<Input: Sendable, Output: Sendable>(
    _ items: [Input], _ work: @escaping @Sendable (Input) async throws -> Output
) async throws -> [Output] {
    var results: [Output] = []
    for start in stride(from: 0, to: items.count, by: 6) {
        let batch = try await withThrowingTaskGroup(of: (Int, Output).self) { group in
            for index in start..<min(start + 6, items.count) {
                let item = items[index]
                group.addTask { (index, try await work(item)) }
            }
            var result: [(Int, Output)] = []
            for try await entry in group { result.append(entry) }
            return result.sorted { $0.0 < $1.0 }.map(\.1)
        }
        results.append(contentsOf: batch)
    }
    return results
}

private enum GuangzhouCatalog {
    static let base = URL(string: "https://www.gzjjjc.gov.cn/ljgzw/ztzl/ljwhwdj/")!
    static let existing = Set(["源起", "我那帅气的老祖宗", "穿越2000年的答案", "容错纠错——BUG启示录", "酱心", "路", "清风引归途"])

    struct Entry: Sendable {
        let article: String
        let title: String
        let number: Int
        let episode: String
    }

    struct Media: Sendable {
        let entry: Entry
        let source: URL
        let urls: [String]
        let cover: String
    }

    static func load() async throws -> Data {
        var page = base
        var visited = Set<URL>()
        var seen = Set<String>()
        var entries: [Entry] = []
        while true {
            guard visited.count < 12, visited.insert(page).inserted else { throw ProductionError.limit }
            let html = String(decoding: try await OnlineHTTP().get(page), as: UTF8.self)
            let rows = matches(#"<a\s+title="([^"]+)"\s+href="[^"]*/content/post_(\d+)\.html""#, in: html)
            guard !rows.isEmpty else { throw ProductionError.content }
            for row in rows where seen.insert(row[1]).inserted {
                guard let parts = matches(#"《([^》]+)》(.*)"#, in: plainText(row[0])).first,
                      !existing.contains(parts[0]) else { continue }
                let sub = parts[1].trimmingCharacters(in: .whitespaces)
                let components = matches(#"^第([0-9一二三四五六七八九十]+)集\s*[：:]?\s*(.*)$"#, in: sub).first
                if sub.hasPrefix("第"), components == nil { continue }
                let number = components.flatMap { episodeNumber($0[0]) } ?? (components == nil ? 1 : 0)
                guard number > 0 else { continue }
                let name = components?[1] ?? ""
                entries.append(Entry(article: row[1], title: parts[0], number: number,
                                     episode: name.isEmpty ? (components == nil ? parts[0] : "第 \(number) 集") : name))
            }
            guard let next = matches(#"<a\s+class="next"\s+href="[^"]*/(index_\d+\.html)""#, in: html).first else { break }
            page = base.appendingPathComponent(next[0])
        }
        guard entries.count <= 150 else { throw ProductionError.limit }
        let media = try await parallelMap(entries) { try await Self.media(for: $0) }
        let groups = Dictionary(grouping: media, by: { $0.entry.title })
        var emitted = Set<String>()
        return try catalogData(media.compactMap { item -> [String: Any]? in
            let title = item.entry.title
            guard emitted.insert(title).inserted, let group = groups[title] else { return nil }
            let episodes = group.sorted { $0.entry.number < $1.entry.number }
            guard let first = episodes.first, Set(episodes.map { $0.entry.number }).count == episodes.count else { return nil }
            return ["id": ProductionSource.guangzhou.prefix + first.entry.article, "title": title, "original": title,
                    "year": "", "length": "微短剧", "genres": ["国产短剧", "真人"], "image": first.cover,
                    "description": "广州市纪委监委官网微短剧专题收录。",
                    "region": "中国大陆", "source": first.source.absoluteString, "credit": "广州市纪委监委网站",
                    "license": "官网公开发布", "episodes": episodes.map { item in
                        ["title": item.entry.episode, "number": item.entry.number,
                         "source": item.source.absoluteString, "sources": item.urls] as [String: Any]
                    }]
        })
    }

    static func episodeNumber(_ text: String) -> Int? {
        if let arabic = Int(text) { return arabic }
        let digits = Array("一二三四五六七八九")
        let halves = text.components(separatedBy: "十")
        func digit(_ value: String) -> Int? {
            guard value.count == 1, let char = value.first, let index = digits.firstIndex(of: char) else { return nil }
            return index + 1
        }
        if halves.count == 1 { return digit(text) }
        guard halves.count == 2, let tens = halves[0].isEmpty ? 1 : digit(halves[0]),
              let ones = halves[1].isEmpty ? 0 : digit(halves[1]) else { return nil }
        return tens * 10 + ones
    }

    static func media(for entry: Entry) async throws -> Media {
        let url = base.appendingPathComponent("content/post_\(entry.article).html")
        let html = String(decoding: try await OnlineHTTP().get(url), as: UTF8.self)
        guard let config = matches(#"var playerOpt\s*=\s*(\{[^\r\n]+\});"#, in: html).first,
              let object = try JSONSerialization.jsonObject(with: Data(config[0].utf8)) as? [String: Any],
              let rawSource = object["source"] as? String else { throw ProductionError.content }
        let sources = (try? JSONSerialization.jsonObject(with: Data(rawSource.utf8))) as? [String: String]
        let raw = sources.map { values in ["OD", "FD", "HD", "SD", "LD"].compactMap { values[$0] } } ?? [rawSource]
        let urls = raw.compactMap { CatalogAddress.parse($0) }.filter {
            $0.host == "gdvideo.southcn.com" && ["mp4", "m3u8"].contains($0.pathExtension.lowercased())
        }.map(\.absoluteString)
        guard !urls.isEmpty else { throw ProductionError.content }
        let cover = (object["cover"] as? String ?? "").replacingOccurrences(of: "http://", with: "https://", options: .anchored)
        return Media(entry: entry, source: url, urls: urls, cover: CatalogAddress.parse(cover)?.absoluteString ?? "")
    }
}

enum ArchiveCatalog {
    static let base = URL(string: "https://www.loc.gov/collections/national-screening-room/")!
    static let mediaBase = URL(string: "https://tile.loc.gov")!

    struct Feed: Decodable {
        struct Pagination: Decodable { let next: String? }
        let pagination: Pagination
        let results: [Film]
    }
    struct Film: Decodable, Sendable {
        struct Resource: Decodable, Sendable {
            let video: String?
            let video_stream: String?
            let poster: String?
            let files: Int?
            let duration: Double?
        }
        let id: String
        let access_restricted: Bool?
        let title: String
        let date: String?
        let description: [String]?
        let subject: [String]?
        let resources: [Resource]?
    }

    static func load() async throws -> Data {
        async let fiction = films(subject: "fiction%20films")
        async let animation = films(subject: "animated%20films")
        let films = try await animation + fiction
        return try convert(films)
    }

    static func search(_ query: String, page: Int) async throws -> OnlineSearchPage {
        var url = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        url.percentEncodedQuery = "c=25&dates=1890/1929&fo=json&q=\(try OnlineSearch.escape(query))&sp=\(page)"
        let feed = try JSONDecoder().decode(Feed.self, from: await OnlineHTTP().get(url.url!))
        return OnlineSearchPage(data: try convert(feed.results, allowEmpty: true), hasNext: feed.pagination.next != nil)
    }

    static func convert(_ films: [Film], allowEmpty: Bool = false) throws -> Data {
        var seen = Set<String>()
        var seenVideos = Set<String>()
        let rows = films.compactMap { film -> [String: Any]? in
            let title = plainText(film.title)
            let subjects = Set(film.subject ?? [])
            guard film.access_restricted == false, !title.isEmpty,
                  !title.localizedCaseInsensitiveContains("excerpt"), !subjects.contains("film excerpts"),
                  let year = film.date, year.count == 4, let number = Int(year), (1890...1928).contains(number),
                  let id = matches(#"^https?://www\.loc\.gov/item/([a-zA-Z0-9]+)/$"#, in: film.id).first?.first,
                  let resources = film.resources, resources.count == 1, let media = resources.first, media.files == 1,
                  let duration = media.duration, duration.isFinite, (60...14_400).contains(duration) else { return nil }
            func url(_ address: String?, ext: String) -> String? {
                guard let address, let url = CatalogAddress.parse(address), CatalogAddress.sameOrigin(mediaBase, url),
                      url.pathExtension == ext else { return nil }
                return url.absoluteString
            }
            guard let stream = url(media.video_stream, ext: "m3u8"), let mp4 = url(media.video, ext: "mp4"),
                  seen.insert(id).inserted, seenVideos.insert(mp4).inserted else { return nil }
            let page = "https://www.loc.gov/item/\(id)/"
            let cover = media.poster.map { $0.hasPrefix("//") ? "https:\($0)" : $0 }.flatMap { url($0, ext: "jpg") } ?? ""
            let seconds = Int(duration)
            var genres = ["经典电影"]
            if subjects.contains("animated films") { genres.append("动画") }
            if subjects.contains("silent films") { genres.append("默片") }
            if subjects.contains("comedy films") { genres.append("喜剧") }
            return ["id": ProductionSource.archive.prefix + id, "title": title, "original": title, "year": year,
                    "description": film.description?.first.map(plainText) ?? "美国国会图书馆公开数字馆藏。",
                    "length": "\((seconds + 59) / 60) 分钟", "genres": genres, "image": cover,
                    "source": page, "credit": "Library of Congress, National Screening Room",
                    "license": "国会图书馆公开馆藏；具体权利说明见原页", "episodes": [[
                        "title": title, "source": page, "sources": [stream, mp4],
                        "durationLabel": String(format: "%d:%02d", seconds / 60, seconds % 60)
                    ] as [String: Any]]]
        }
        return try writeSearchRows(rows, allowEmpty: allowEmpty)
    }

    static func films(subject: String) async throws -> [Film] {
        let count = subject == "animated%20films" ? 25 : 50
        func address(_ page: Int) -> URL {
            URL(string: "\(base.absoluteString)?c=\(count)&dates=1890/1929&fa=subject%3A\(subject)&fo=json&sp=\(page)")!
        }
        var films: [Film] = []
        for page in 1...12 {
            let url = address(page)
            let data: Data
            do {
                data = try await OnlineHTTP().get(url)
            } catch is URLError {
                try await Task.sleep(nanoseconds: 350_000_000)
                data = try await OnlineHTTP().get(url)
            }
            let feed = try JSONDecoder().decode(Feed.self, from: data)
            guard !feed.results.isEmpty else { throw ProductionError.content }
            films += feed.results
            guard let raw = feed.pagination.next else { return films }
            guard let next = CatalogAddress.parse(raw, relativeTo: url), CatalogAddress.sameOrigin(base, next),
                  next.path == base.path,
                  URLComponents(url: next, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "sp" })?.value == String(page + 1)
            else { throw ProductionError.content }
        }
        throw ProductionError.limit
    }
}

enum BlenderCatalog {
    static let base = URL(string: "https://video.blender.org")!
    static let excluded = ["making of", "teaser", "trailer", "caminandes", "sintel", "coffee run", "tears of steel", "charge -", "spring -"]
    static let translations = ["WING IT!": "临场发挥！", "SINGULARITY": "奇点", "Sprite Fright": "精灵惊魂",
                               "Big Buck Bunny": "大雄兔", "Elephants Dream": "大象之梦", "Cosmos Laundromat": "宇宙洗衣房",
                               "Glass Half": "半杯", "Agent 327": "特工 327：理发店行动", "The Daily Dweebs": "呆萌日常", "HERO": "英雄"]

    struct Feed: Decodable { let total: Int; let data: [Video] }
    struct Video: Decodable, Sendable {
        let uuid: UUID
        let name: String
        let duration: Int
        let isLocal: Bool
        let nsfw: Bool
        let isLive: Bool
        let channel: Detail.Channel?
    }
    struct Detail: Decodable {
        struct Playlist: Decodable { let playlistUrl: String; let files: [File] }
        struct File: Decodable {
            let fileUrl: String?
            let playlistUrl: String?
            let height: Int?
            let width: Int?
        }
        struct Licence: Decodable { let id: Int?; let label: String }
        struct Channel: Decodable { let name: String; let host: String }
        let url: String
        let description: String?
        let thumbnailPath: String?
        let previewPath: String?
        let originallyPublishedAt: String?
        let licence: Licence
        let channel: Channel
        let streamingPlaylists: [Playlist]
        let files: [File]
    }
    struct Film: Sendable {
        let video: Video
        let source: String
        let cover: String
        let description: String
        let year: String
        let license: String
        let urls: [String]
        let qualities: [String: Int]
    }

    static func load() async throws -> Data {
        var start = 0
        var videos: [Video] = []
        var seen = Set<UUID>()
        while true {
            let url = URL(string: "\(base.absoluteString)/api/v1/video-channels/blender_open_movies/videos?count=25&start=\(start)&sort=-publishedAt")!
            let feed = try JSONDecoder().decode(Feed.self, from: await OnlineHTTP().get(url))
            guard feed.total <= 250, !feed.data.isEmpty, feed.data.allSatisfy({ seen.insert($0.uuid).inserted }) else {
                throw ProductionError.content
            }
            videos += feed.data
            start += feed.data.count
            if start >= feed.total { break }
        }
        return try await convert(videos, allowEmpty: false)
    }

    static func search(_ query: String, page: Int) async throws -> OnlineSearchPage {
        // The upstream search index includes federated videos. Validate publisher identity again locally.
        let term = translations.first(where: { $0.value == query || $0.value == query + "！" })?.key ?? query
        let start = (page - 1) * 10
        let url = URL(string: "\(base.absoluteString)/api/v1/search/videos?search=\(try OnlineSearch.escape(term))&count=10&start=\(start)&channelHandle=blender_open_movies%40video.blender.org")!
        let feed = try JSONDecoder().decode(Feed.self, from: await OnlineHTTP().get(url))
        let checked = feed.data.filter { $0.channel?.name == "blender_open_movies" && $0.channel?.host == base.host }
        return OnlineSearchPage(data: try await convert(checked, allowEmpty: true), hasNext: !feed.data.isEmpty && start + feed.data.count < feed.total)
    }

    static func convert(_ videos: [Video], allowEmpty: Bool) async throws -> Data {
        let hasHDRemaster = videos.contains { $0.name.hasPrefix("Big Buck Bunny 60fps") }
        let eligible = videos.filter { item in
            let name = item.name.lowercased()
            return item.isLocal && !item.nsfw && !item.isLive && item.duration >= 45
                && !excluded.contains(where: name.contains) && !(hasHDRemaster && item.name == "Big Buck Bunny")
        }
        let details = try await parallelMap(eligible) { try await Self.film(for: $0) }
        return try writeSearchRows(details.map { film in
            let video = film.video
            let title = translations.keys.sorted().first { video.name.hasPrefix($0) }.flatMap { translations[$0] } ?? video.name
            return ["id": ProductionSource.blender.prefix + video.uuid.uuidString.lowercased(), "title": title,
                    "original": video.name, "year": film.year, "length": "\((video.duration + 59) / 60) 分钟",
                    "genres": ["动画", "动画短片"], "description": film.description, "image": film.cover,
                    "source": film.source, "credit": "Blender 官方 Open Movies 频道", "license": film.license,
                    "episodes": [["title": title, "source": film.source, "sources": film.urls,
                                  "durationLabel": String(format: "%d:%02d", video.duration / 60, video.duration % 60),
                                  "sourceQualities": film.qualities] as [String: Any]]]
        }, allowEmpty: allowEmpty)
    }

    static func film(for video: Video) async throws -> Film {
        let url = base.appendingPathComponent("api/v1/videos/\(video.uuid.uuidString.lowercased())")
        let detail = try JSONDecoder().decode(Detail.self, from: await OnlineHTTP().get(url))
        guard detail.channel.name == "blender_open_movies", detail.channel.host == base.host,
              let source = CatalogAddress.parse(detail.url), CatalogAddress.sameOrigin(base, source) else { throw ProductionError.content }
        var urls: [String] = []
        var qualities: [String: Int] = [:]
        func add(_ address: String?, extension ext: String, quality: Int? = nil) {
            guard let address, let url = CatalogAddress.parse(address), CatalogAddress.sameOrigin(base, url),
                  url.pathExtension == ext, !urls.contains(address) else { return }
            urls.append(address)
            qualities[address] = quality
        }
        func shortEdge(_ file: Detail.File) -> Int? {
            guard let height = file.height, let width = file.width, min(height, width) > 0 else { return nil }
            return min(height, width)
        }
        for playlist in detail.streamingPlaylists { add(playlist.playlistUrl, extension: "m3u8") }
        // Prefer a moderate progressive file on constrained networks. HD stays selectable.
        func priority(_ file: Detail.File) -> Int {
            guard let height = shortEdge(file) else { return Int.max }
            return height <= 720 ? 720 - height : height
        }
        for file in detail.files.sorted(by: { priority($0) < priority($1) }) {
            add(file.fileUrl, extension: "mp4", quality: shortEdge(file))
        }
        for file in detail.streamingPlaylists.flatMap(\.files).sorted(by: { (shortEdge($0) ?? 0) > (shortEdge($1) ?? 0) }) {
            add(file.playlistUrl, extension: "m3u8", quality: shortEdge(file))
        }
        guard !urls.isEmpty else { throw ProductionError.content }
        let description = detail.description?.split(separator: "\n").first.map(String.init) ?? "Blender 官方发布的动画短片。"
        let cover = (detail.previewPath ?? detail.thumbnailPath).flatMap { CatalogAddress.parse($0, relativeTo: base) }
            .flatMap { CatalogAddress.sameOrigin(base, $0) ? $0.absoluteString : nil } ?? ""
        return Film(video: video, source: source.absoluteString, cover: cover, description: description,
                    year: detail.originallyPublishedAt.map { String($0.prefix(4)) } ?? "",
                    license: detail.licence.id == nil ? "官方公开发布（授权详见原页）" : detail.licence.label,
                    urls: urls, qualities: qualities)
    }
}
