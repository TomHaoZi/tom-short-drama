import Foundation

@main
struct CatalogFallback {
    @MainActor
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tom-catalog-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = root.appendingPathComponent("publisher-catalog.json")
        let path = URL(fileURLWithPath: CommandLine.arguments[1])
        let starter = try Data(contentsOf: path.appendingPathComponent("online-starter.json"))
        let catalog = try JSONDecoder().decode(MediaCatalog.self, from: starter)
        let rows = (try JSONSerialization.jsonObject(with: starter) as! [String: [[String: Any]]])["shows"]!
        var inputs: [ProductionSource: Data] = [:]
        for source in ProductionSource.allCases {
            let matches = rows.filter { ($0["id"] as? String)?.hasPrefix(source.prefix) == true }
            inputs[source] = try JSONSerialization.data(withJSONObject: ["shows": matches])
        }
        let downloads = inputs
        let first = CatalogSync(bundled: catalog, storage: storage, productionDownload: { downloads[$0]! })
        await first.start()
        precondition(first.sourceStatus.values.allSatisfy { $0 == .live })
        precondition(first.catalog?.shows.count == catalog.shows.count)

        // A slow/unavailable provider does not wipe its cache or prevent other providers refreshing.
        let restored = CatalogSync(bundled: nil, storage: storage, productionDownload: { source in
            if source == .archive { throw URLError(.notConnectedToInternet) }
            return downloads[source]!
        })
        await restored.start()
        precondition(restored.sourceStatus[.archive] == .unavailable(.network))
        precondition(restored.sourceStatus[.blender] == .live)
        precondition(restored.message?.contains("国会图书馆经典网络不可用") == true)
        precondition(restored.catalog?.shows.map(\.id) == first.catalog?.shows.map(\.id))

        let timed = CatalogSync(bundled: nil, storage: storage, productionDownload: { source in
            if source == .guangzhou { throw URLError(.timedOut) }
            if source == .blender { return Data("{\"shows\":[]}".utf8) }
            return downloads[source]!
        })
        await timed.start()
        precondition(timed.sourceStatus[.guangzhou] == .unavailable(.timeout))
        precondition(timed.sourceStatus[.blender] == .unavailable(.content))
        precondition(timed.sourceStatus[.archive] == .live)
        precondition(timed.message?.contains("广州微短剧超时") == true)
        precondition(timed.message?.contains("Blender 动画目录无法解析") == true)
        precondition(timed.catalog?.shows.map(\.id) == first.catalog?.shows.map(\.id))

        // A fresh offline installation still has the packaged directory.
        let offline = CatalogSync(bundled: catalog, storage: root.appendingPathComponent("fresh/catalog.json"), productionDownload: { _ in
            throw URLError(.notConnectedToInternet)
        })
        await offline.start()
        precondition(offline.catalog?.shows.count == catalog.shows.count)
        print("PASS: all sources, independent fallback, cached restart, packaged offline starter (\(catalog.shows.count) items)")
    }
}
