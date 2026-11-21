import Combine
import CryptoKit
import Foundation

enum CinemaProfile {
    // The standalone Mac build can exercise updates and restarts without touching a real library.
    private static var isolated: String? {
        #if os(macOS)
        return ProcessInfo.processInfo.environment["TOM_CINEMA_TEST_PROFILE"].flatMap {
            UUID(uuidString: $0)?.uuidString
        }
        #else
        return nil
        #endif
    }

    static var defaults: UserDefaults {
        if let isolated, let defaults = UserDefaults(suiteName: "local.tom.shortdrama.test.\(isolated)") { return defaults }
        return .standard
    }

    static var storage: URL {
        let root = isolated.map { "Tom短剧-test-\($0)" } ?? "Tom短剧"
        return URL.applicationSupportDirectory.appendingPathComponent(root).appendingPathComponent("publisher-catalog.json")
    }
}

enum CatalogAddress {
    static func parse(_ text: String, relativeTo base: URL? = nil) -> URL? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, let url = URL(string: value, relativeTo: base)?.absoluteURL,
              isHTTPS(url) else { return nil }
        return url
    }

    static func isHTTPS(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.isEmpty == false
            && url.user == nil && url.password == nil && url.fragment == nil
    }

    static func publisherEndpoint(_ text: String) -> URL? {
        guard let url = parse(text) else { return nil }
        guard url.host?.lowercased() == "github.com" else { return url }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.port == nil || components.port == 443,
              components.query == nil || components.query == "raw=true" || components.query == "raw=1" else { return nil }
        let parts = components.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 6, parts[0].isEmpty, parts[3] == "blob",
              parts.last?.lowercased().hasSuffix(".json") == true else { return nil }
        // Refuse ambiguous escaped separators and path navigation before rebuilding the URL.
        guard parts.dropFirst().allSatisfy({ part in
            guard let decoded = String(part).removingPercentEncoding else { return false }
            return !decoded.isEmpty && decoded != "." && decoded != ".." && !decoded.contains("/")
                && !decoded.contains("\\") && !decoded.contains("%")
        }) else { return nil }
        return parse("https://raw.githubusercontent.com/\(parts[1])/\(parts[2])/\(parts.dropFirst(4).joined(separator: "/"))")
    }

    static func sameOrigin(_ first: URL, _ second: URL) -> Bool {
        isHTTPS(first) && isHTTPS(second) && first.host?.lowercased() == second.host?.lowercased()
            && (first.port ?? 443) == (second.port ?? 443)
    }
}

private enum CatalogSyncError: LocalizedError {
    case address, alreadyConnected, paging, response, tooLarge, invalid, unsupportedPack, storage

    var errorDescription: String? {
        switch self {
        case .address: return "请输入 HTTPS 发行方目录，或 GitHub 上的 JSON 文件链接。"
        case .alreadyConnected: return "这个片库已经接入。"
        case .paging: return "片库的分页地址有误。"
        case .response: return "片库服务暂时无法访问。"
        case .tooLarge: return "片库响应超过同步容量。"
        case .invalid: return "未读到符合格式的全集和 HTTPS 正片地址。"
        case .unsupportedPack: return "这是 TVBox 类配置，不是可直接导入的发行方目录。仅支持发行方的 HTTPS JSON，不运行解析器、JAR 或脚本。"
        case .storage: return "片库已下载，但无法保存到本机。"
        }
    }
}

private struct PublisherPage: Decodable {
    let shows: [Show]
    let featuredIds: [String]?
    let next: String?
}

final class PublisherRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    let endpoint: URL

    init(endpoint: URL) { self.endpoint = endpoint }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        let sameOrigin = request.url.map { CatalogAddress.sameOrigin(endpoint, $0) } ?? false
        completionHandler(sameOrigin ? request : nil)
    }
}

enum PublisherCatalogClient {
    static func download(_ endpoint: URL, configuration: URLSessionConfiguration = .ephemeral) async throws -> [Data] {
        guard CatalogAddress.isHTTPS(endpoint) else { throw CatalogSyncError.address }
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 40
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: PublisherRedirects(endpoint: endpoint), delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        var pages: [Data] = []
        var visited: Set<URL> = []
        var remainingBytes = 96 * 1024 * 1024
        var next: URL? = endpoint
        while let pageURL = next {
            guard visited.insert(pageURL).inserted else { throw CatalogSyncError.paging }
            guard pages.count < 1_024 else { throw CatalogSyncError.tooLarge }
            let (bytes, response) = try await session.bytes(from: pageURL)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let returnedURL = http.url, CatalogAddress.sameOrigin(endpoint, returnedURL) else {
                throw CatalogSyncError.response
            }
            let limit = min(8 * 1024 * 1024, remainingBytes)
            guard response.expectedContentLength <= Int64(limit) else { throw CatalogSyncError.tooLarge }
            var data = Data()
            for try await byte in bytes {
                guard data.count < limit else { throw CatalogSyncError.tooLarge }
                data.append(byte)
            }
            remainingBytes -= data.count
            guard let page = try? JSONDecoder().decode(PublisherPage.self, from: data) else {
                if let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                   object["sites"] != nil || object["spider"] != nil || object["parses"] != nil {
                    throw CatalogSyncError.unsupportedPack
                }
                throw CatalogSyncError.invalid
            }
            pages.append(data)
            if let address = page.next {
                guard let url = CatalogAddress.parse(address, relativeTo: returnedURL),
                      CatalogAddress.sameOrigin(endpoint, url) else { throw CatalogSyncError.paging }
                next = url
            } else {
                next = nil
            }
        }
        return pages
    }
}

@MainActor
final class CatalogSync: ObservableObject {
    struct Feed: Identifiable {
        let id: URL
        let count: Int
    }

    private struct SavedFeed: Codable, Sendable {
        let endpoint: URL
        let pages: [Data]
    }

    private struct Snapshot: Sendable {
        let saved: SavedFeed
        let catalog: MediaCatalog

        init(saved: SavedFeed) throws {
            let namespace = SHA256.hash(data: Data(saved.endpoint.absoluteString.utf8))
                .map { String(format: "%02x", $0) }.joined()
            var ids: Set<String> = []
            var shows: [Show] = []
            var requestedFeatured: [String] = []
            var hadEntries = false
            guard CatalogAddress.isHTTPS(saved.endpoint), !saved.pages.isEmpty else { throw CatalogSyncError.invalid }
            for data in saved.pages {
                let page = try JSONDecoder().decode(PublisherPage.self, from: data)
                hadEntries = hadEntries || !page.shows.isEmpty
                for item in page.shows {
                    if let show = item.importedFromPublisher(namespace: namespace), ids.insert(show.id).inserted {
                        shows.append(show)
                    }
                }
                requestedFeatured.append(contentsOf: (page.featuredIds ?? []).map { "publisher/\(namespace)/\($0)" })
            }
            guard !hadEntries || !shows.isEmpty else { throw CatalogSyncError.invalid }
            var seenFeatured: Set<String> = []
            let featured = requestedFeatured.filter { ids.contains($0) && seenFeatured.insert($0).inserted }
            self.saved = saved
            self.catalog = MediaCatalog(featuredIds: featured, shows: shows)
        }
    }

    enum SourceStatus: Equatable {
        case saved, live, unavailable(SourceFailure)

        var chipLabel: String {
            switch self {
            case .live: return "已同步"
            case .saved: return "随应用收录"
            case .unavailable(let failure): return "上次目录 · \(failure.text)"
            }
        }
    }

    @Published private(set) var sourceStatus: [ProductionSource: SourceStatus] = [:]
    @Published private(set) var catalog: MediaCatalog?
    @Published private(set) var feeds: [Feed] = []
    @Published private(set) var busy = false
    @Published private(set) var message: String?

    private let bundled: MediaCatalog?
    private let storage: URL
    private let download: @Sendable (URL) async throws -> [Data]
    private let productionSources: [ProductionSource]
    private let productionDownload: @Sendable (ProductionSource) async throws -> Data
    private var online: [ProductionSource: [Show]] = [:]
    private var remembered: [String: Data] = [:]
    private var rememberedShows: [Show] = []
    private var snapshots: [Snapshot] = []
    private var started = false

    init(bundled: MediaCatalog? = try? MediaCatalog.load(),
         storage: URL = CinemaProfile.storage,
         productionSources: [ProductionSource] = ProductionSource.allCases,
         productionDownload: @escaping @Sendable (ProductionSource) async throws -> Data = { try await $0.fetch() },
         download: @escaping @Sendable (URL) async throws -> [Data] = { try await PublisherCatalogClient.download($0) }) {
        self.bundled = bundled
        self.catalog = bundled
        self.storage = storage
        self.download = download
        self.productionSources = productionSources
        self.productionDownload = productionDownload
    }

    func count(for source: ProductionSource) -> Int {
        catalog?.shows.filter(source.owns).count ?? 0
    }

    private func cacheURL(for source: ProductionSource) -> URL {
        storage.deletingLastPathComponent().appendingPathComponent("online-\(source.rawValue).json")
    }

    private var rememberedURL: URL { storage.deletingLastPathComponent().appendingPathComponent("online-viewed.json") }

    func remember(_ result: OnlineSearchState.Result) -> Bool {
        guard remembered[result.id] == nil else { return true }
        do {
            guard result.source.owns(result.show),
                  let envelope = try JSONSerialization.jsonObject(with: result.payload) as? [String: [[String: Any]]],
                  let row = envelope["shows"]?.first(where: { $0["id"] as? String == result.id }) else { return false }
            let data = try writeSearchRows([row], allowEmpty: false)
            let validated = try result.source.decode(data)
            var updated = remembered
            updated[result.id] = data
            try FileManager.default.createDirectory(at: rememberedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(updated).write(to: rememberedURL, options: .atomic)
            remembered = updated
            rememberedShows += validated
            apply(snapshots)
            return true
        } catch { return false }
    }

    func start() async {
        guard !started else { return }
        started = true
        busy = true
        let restored = await Task.detached(priority: .utility) { [storage] in
            guard let cached = try? Data(contentsOf: storage),
                  let saved = try? JSONDecoder().decode([SavedFeed].self, from: cached) else { return [Snapshot]() }
            return saved.compactMap { try? Snapshot(saved: $0) }
        }.value
        for source in productionSources {
            let url = cacheURL(for: source)
            if let shows = await Task.detached(priority: .utility, operation: {
                try? source.decode(Data(contentsOf: url))
            }).value { online[source] = shows }
            sourceStatus[source] = .saved
        }
        if let cached = try? Data(contentsOf: rememberedURL),
           let saved = try? JSONDecoder().decode([String: Data].self, from: cached) {
            for (id, data) in saved where remembered[id] == nil {
                guard let source = ProductionSource.allCases.first(where: { id.hasPrefix($0.prefix) }),
                      let show = try? source.decode(data).first, show.id == id else { continue }
                remembered[id] = data
                rememberedShows.append(show)
            }
        }
        apply(restored)
        busy = false
        await refresh()
    }

    func connect(_ address: String) async -> Bool {
        guard !busy else { return false }
        guard let url = CatalogAddress.publisherEndpoint(address) else {
            message = CatalogSyncError.address.localizedDescription
            return false
        }
        guard !snapshots.contains(where: { $0.saved.endpoint == url }) else {
            message = CatalogSyncError.alreadyConnected.localizedDescription
            return false
        }

        busy = true
        message = nil
        defer { busy = false }
        do {
            let pages = try await download(url)
            let snapshot = try Snapshot(saved: SavedFeed(endpoint: url, pages: pages))
            try save(snapshots + [snapshot])
            message = "已接入 \(snapshot.catalog.shows.count) 部。"
            return true
        } catch {
            message = (error as? CatalogSyncError)?.localizedDescription ?? "接入失败，请检查片库地址和网络。"
            return false
        }
    }

    func refresh() async {
        guard !busy, !snapshots.isEmpty || !productionSources.isEmpty else { return }
        busy = true
        message = nil
        defer { busy = false }

        var issues: [String] = []
        await withTaskGroup(of: (ProductionSource, [Show]?, SourceFailure?).self) { group in
            for source in productionSources {
                let url = cacheURL(for: source)
                group.addTask { [productionDownload] in
                    do {
                        let data = try await productionDownload(source)
                        let shows = try source.decode(data)
                        try Task.checkCancellation()
                        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try data.write(to: url, options: .atomic)
                        return (source, shows, nil)
                    } catch {
                        return (source, nil, SourceFailure.classify(error))
                    }
                }
            }
            for await (source, shows, failure) in group {
                if let shows {
                    online[source] = shows
                    sourceStatus[source] = .live
                    apply(snapshots)
                } else {
                    let reason = failure ?? .network
                    sourceStatus[source] = .unavailable(reason)
                    issues.append("\(source.title)\(reason.text)")
                }
            }
        }
        var refreshed = snapshots
        var publisherFailed = false
        for (index, snapshot) in snapshots.enumerated() {
            if Task.isCancelled { return }
            do {
                let url = snapshot.saved.endpoint
                let pages = try await download(url)
                refreshed[index] = try Snapshot(saved: SavedFeed(endpoint: url, pages: pages))
            } catch {
                publisherFailed = true
            }
        }
        if publisherFailed { issues.append("发行方目录未更新") }
        guard !Task.isCancelled else { return }
        do {
            if !refreshed.isEmpty { try save(refreshed) }
            message = issues.isEmpty ? "片库已同步。" : "\(issues.joined(separator: "、"))，仍可浏览已收录目录。"
        } catch {
            message = CatalogSyncError.storage.localizedDescription
        }
    }

    func disconnect(_ endpoint: URL) {
        guard !busy else { return }
        do {
            try save(snapshots.filter { $0.saved.endpoint != endpoint })
            message = nil
        } catch {
            message = CatalogSyncError.storage.localizedDescription
        }
    }

    private func save(_ updated: [Snapshot]) throws {
        do {
            let data = try JSONEncoder().encode(updated.map(\.saved))
            try FileManager.default.createDirectory(at: storage.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: storage, options: .atomic)
        } catch {
            throw CatalogSyncError.storage
        }
        apply(updated)
    }

    private func apply(_ updated: [Snapshot]) {
        snapshots = updated
        feeds = updated.map { Feed(id: $0.saved.endpoint, count: $0.catalog.shows.count) }
        let offline = bundled?.shows ?? []
        let builtIn = ProductionSource.allCases.flatMap { source in
            online[source] ?? offline.filter(source.owns)
        }
        var shows = updated.flatMap(\.catalog.shows) + offline.filter { show in
            !ProductionSource.allCases.contains { $0.owns(show) }
        } + builtIn
        var available = Set(shows.map(\.id))
        shows += rememberedShows.sorted { $0.id < $1.id }.filter { available.insert($0.id).inserted }
        let featured = (updated.flatMap(\.catalog.featuredIds) + (bundled?.featuredIds ?? [])).filter(available.contains)
        catalog = bundled == nil && shows.isEmpty ? nil : MediaCatalog(featuredIds: featured, shows: shows)
    }
}
