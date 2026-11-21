import Foundation

@main
struct SourceAvailability {
    @MainActor
    static func main() async throws {
        precondition(ProductionSource.allCases.map(\.rawValue) == ["guangzhou", "blender", "archive"])
        precondition(SourceFailure.classify(URLError(.timedOut)) == .timeout)
        precondition(SourceFailure.classify(URLError(.notConnectedToInternet)) == .network)
        precondition(SourceFailure.classify(URLError(.cancelled)) == .cancelled)
        precondition(SourceFailure.classify(CancellationError()) == .cancelled)
        precondition(SourceFailure.timeout.text == "超时")
        precondition(SourceFailure.http.text == "服务无响应")
        precondition(SourceFailure.content.text == "目录无法解析")

        let relevance = SearchRelevance("准确片名")
        precondition(relevance.score(title: "准确片名", metadata: "") == 0)
        precondition(relevance.score(title: "准确片名续集", metadata: "") == 1)
        precondition(relevance.score(title: "访谈", metadata: "聊聊准确片名") == 2)
        precondition(relevance.score(title: "无关推荐", metadata: "热门短剧") == nil)

        let state = OnlineSearchState(performSearch: { source, query, page in
            if query == "旧查询" {
                try await Task.sleep(nanoseconds: 8_000_000_000)
                throw URLError(.timedOut)
            }
            precondition(query == "准确片名")
            if source == .blender { throw URLError(.timedOut) }
            return OnlineSearchPage(data: try catalog([
                show(id: "online-archive-late", title: "准确片名续集"),
                show(id: "online-archive-exact", title: "准确片名"),
                show(id: "online-archive-noise", title: "无关推荐", description: "热门短剧"),
                show(id: "online-archive-meta", title: "访谈", description: "聊聊准确片名")
            ]), hasNext: false)
        })

        state.submit("旧查询")
        try await Task.sleep(nanoseconds: 80_000_000)
        precondition(state.searched == "旧查询")
        state.submit("准确片名")
        for _ in 0..<80 {
            if !state.busy { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        precondition(state.busy == false)
        precondition(state.searched == "准确片名")
        precondition(state.results.map(\.show.title) == ["准确片名", "准确片名续集", "访谈"])
        precondition(state.results.map(\.show.id) == [
            "online-archive-exact", "online-archive-late", "online-archive-meta"
        ])
        precondition(state.failures.map(\.text) == ["Blender 动画（超时）"])
        precondition(state.results.allSatisfy { $0.show.title != "旧查询" })

        state.invalidate()
        precondition(state.results.isEmpty && state.failures.isEmpty && state.searched.isEmpty && state.busy == false)
        print("PASS: no hongguo source, failure classification, cancelled stale search, ranked results, ignored unrelated rows")
    }

    static func show(id: String, title: String, description: String = "") -> [String: Any] {
        [
            "id": id,
            "title": title,
            "original": "",
            "year": "",
            "length": "",
            "genres": [],
            "description": description,
            "image": "",
            "source": "https://example.org/shows/\(id)",
            "credit": "Fixture",
            "license": "CC0",
            "totalEpisodes": 1,
            "episodes": [["title": "第一集", "sources": ["https://example.org/video.mp4"]]]
        ]
    }

    static func catalog(_ rows: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["shows": rows])
    }
}
