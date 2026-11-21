import AVFoundation
import Foundation

@main
struct OnlineSearchProbe {
    @MainActor
    static func main() async {
        do {
            try await check()
        } catch {
            print("FAIL: \(error)")
            exit(1)
        }
    }

    @MainActor
    static func check() async throws {
        let relevance = SearchRelevance("荒岛上，还摆高姿态")
        guard relevance.score(title: "荒岛上还摆高姿态", metadata: "") == 0,
              relevance.score(title: "荒岛上还摆高姿态第二季", metadata: "") == 1,
              relevance.score(title: "短剧访谈", metadata: "聊聊荒岛上还摆高姿态") == 2,
              relevance.score(title: "热门推荐", metadata: "荒岛求生") == nil,
              SearchRelevance("ＷＩＮＧ ＩＴ").score(title: "Wing It!", metadata: "") == 0 else {
            throw URLError(.cannotParseResponse)
        }
        let live = OnlineSearchState()
        live.submit("train")
        for _ in 0..<100 where live.busy { try await Task.sleep(nanoseconds: 200_000_000) }
        guard !live.busy, live.results.contains(where: { $0.show.title == "Freight train" }),
              live.results.allSatisfy({ SearchRelevance("train").score(title: $0.show.title, metadata: $0.show.searchText) != nil }) else {
            throw URLError(.cannotParseResponse)
        }
        print("PASS: exact/partial/metadata ranking, width and punctuation folding, unrelated recommendation filtering; live train search returned \(live.results.count) matches.")
        async let archive = OnlineSearch.archive.search("train", page: 1)
        async let blender = OnlineSearch.blender.search("WING IT", page: 1)
        let (history, animation) = try await (archive, blender)
        let decoder = JSONDecoder()
        let known = try decoder.decode(MediaCatalog.self, from: Data(contentsOf: URL(fileURLWithPath: "Native/online-starter.json")))
        let results = try decoder.decode(MediaCatalog.self, from: history.data).shows
        let cartoons = try decoder.decode(MediaCatalog.self, from: animation.data).shows
        guard history.hasNext, let fresh = results.first(where: { $0.id == "online-archive-00694211" }),
              !known.shows.contains(where: { $0.id == fresh.id }),
              cartoons.contains(where: { $0.title == "临场发挥！" }) else { throw URLError(.cannotParseResponse) }
        let pageTwo = try await OnlineSearch.archive.search("train", page: 2)
        let secondResults = try decoder.decode(MediaCatalog.self, from: pageTwo.data).shows
        let firstIDs = Set(results.map(\.id))
        guard secondResults.contains(where: { !firstIDs.contains($0.id) }) else { throw URLError(.cannotParseResponse) }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tom-search-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = root.appendingPathComponent("test.json")
        let initial = CatalogSync(bundled: known, storage: storage, productionSources: [])
        guard initial.remember(.init(show: fresh, payload: history.data, source: .archive)) else { throw CocoaError(.fileWriteUnknown) }
        let relaunched = CatalogSync(bundled: known, storage: storage, productionSources: [])
        await relaunched.start()
        guard relaunched.catalog?.shows.contains(where: { $0.id == fresh.id }) == true else { throw CocoaError(.fileReadCorruptFile) }

        for url in fresh.episodes[0].playableSources {
            let player = AVPlayer(url: url)
            player.isMuted = true
            player.play()
            for _ in 0..<100 {
                if player.currentItem?.status == .failed { break }
                if player.currentTime().seconds > 1, let item = player.currentItem {
                    player.pause()
                    print("PASS: live search (\(results.count) first page, \(secondResults.count) next page); Blender returned 临场发挥！. New title \(fresh.title) absent from starter, remembered across restart, played \(player.currentTime().seconds)s at \(item.presentationSize) via \(url.host ?? "").")
                    return
                }
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            player.pause()
        }
        throw URLError(.cannotLoadFromNetwork)
    }
}
