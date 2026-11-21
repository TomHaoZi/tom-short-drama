import Foundation

@main
struct GitHubPublisher {
    @MainActor
    static func main() async throws {
        let page = "https://github.com/creator/movies/blob/main/releases/catalog.json?raw=true"
        let expected = URL(string: "https://raw.githubusercontent.com/creator/movies/main/releases/catalog.json")!
        precondition(CatalogAddress.publisherEndpoint(page) == expected)
        precondition(CatalogAddress.publisherEndpoint(expected.absoluteString) == expected)
        precondition(CatalogAddress.publisherEndpoint("https://github.com/creator/movies") == nil)
        precondition(CatalogAddress.publisherEndpoint("https://github.com/creator/movies/blob/main/%2e%2e/catalog.json") == nil)
        precondition(CatalogAddress.publisherEndpoint("https://github.com/creator/movies/blob/main/red%2Fcatalog.json") == nil)
        precondition(CatalogAddress.publisherEndpoint("https://github.com:8443/creator/movies/blob/main/catalog.json") == nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tom-github-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = Data("""
        {"shows":[{"id":"example","title":"Fixture","original":"","year":"","length":"","genres":[],"description":"",
          "image":"","source":"https://example.org/films/example","credit":"Fixture","license":"CC BY 4.0","totalEpisodes":1,
          "episodes":[{"title":"Fixture episode","sources":["https://example.org/example.mp4"]}]}]}
        """.utf8)
        let sync = CatalogSync(bundled: nil, storage: root.appendingPathComponent("cache.json"), productionSources: [], download: { url in
            precondition(url == expected)
            return [fixture]
        })
        let first = await sync.connect(page)
        precondition(first && sync.catalog?.shows.first?.title == "Fixture")
        let duplicate = await sync.connect(expected.absoluteString)
        precondition(!duplicate && sync.feeds.count == 1)
        print("PASS: GitHub blob → raw canonicalization, path rejection, authorized catalog import fixture, duplicate identity")
    }
}
