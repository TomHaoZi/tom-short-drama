import AVFoundation
import Foundation

@main
struct LiveSources {
    static func main() async {
        setvbuf(stdout, nil, _IOLBF, 0)
        do { try await run() }
        catch {
            print("FAIL: \(error)")
            exit(1)
        }
    }

    static func run() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        var failures: [String] = []
        let providers = ProductionSource.allCases.filter { source in
            !args.contains(where: { $0.hasPrefix("--only=") }) || args.contains("--only=\(source.rawValue)")
        }
        for source in providers {
            let data = try await source.fetch()
            let shows = try source.decode(data)
            print("\(source.title): \(shows.count) 部 / \(shows.flatMap(\.episodes).count) 集")
            if let folder = args.first(where: { !$0.hasPrefix("--") }) {
                try data.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(source.rawValue).json"))
            }
            if args.contains("--probe") {
                let samples = source == .archive ? Array(shows.prefix(2) + shows.suffix(2)) : shows
                for show in samples {
                    for index in show.playableEpisodeIndices {
                        let episode = show.episodes[index]
                        let label = "\(show.title) #\(show.episodeNumber(at: index))"
                        if let proof = await probe(episode) { print("\(label): \(proof)") }
                        else { failures.append(label); print("不可播：\(label)") }
                    }
                }
            }
        }
        if !failures.isEmpty { throw CocoaError(.fileReadCorruptFile, userInfo: ["titles": failures]) }
    }

    @MainActor
    static func probe(_ episode: Episode) async -> String? {
        for url in episode.playableSources {
            let player = AVPlayer(url: url)
            player.isMuted = true
            player.play()
            for _ in 0..<100 {
                if player.currentItem?.status == .failed { break }
                if player.currentTime().seconds > 0.8, let item = player.currentItem {
                    player.pause()
                    return "播放进度 \(player.currentTime().seconds)s；画面 \(Int(item.presentationSize.width))×\(Int(item.presentationSize.height))；\(url.host ?? "")"
                }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            player.pause()
        }
        return nil
    }
}
