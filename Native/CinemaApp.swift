import SwiftUI
import AVKit
@preconcurrency import WebKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

private let backdrop = Color(red: 0.035, green: 0.037, blue: 0.043)
private let accent = Color.white
private let controlSurface = Color(red: 0.13, green: 0.135, blue: 0.15)

@main
struct CinemaApp: App {
    @StateObject private var catalogSync = CatalogSync()

    var body: some Scene {
        #if os(macOS)
        Window("Tom短剧", id: "cinema") {
            content.frame(minWidth: 540, minHeight: 440)
        }
        .defaultSize(width: 1080, height: 740)
        #else
        WindowGroup {
            content
        }
        #endif
    }

    private var content: some View {
        Group {
            if let catalog = catalogSync.catalog {
                Cinema(catalog: catalog, catalogSync: catalogSync)
            } else {
                Label("暂时无法读取片库", systemImage: "film")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(backdrop)
            }
        }
        .preferredColorScheme(.dark)
        .tint(accent)
        .task { await catalogSync.start() }
    }
}

private enum Area: String, Identifiable, CaseIterable {
    case home = "首页"
    case catalog = "片库"
    case search = "搜索"
    case library = "我的"

    var id: Self { self }
    var icon: String {
        switch self {
        case .home: return "house"
        case .catalog: return "film"
        case .search: return "magnifyingglass"
        case .library: return "bookmark"
        }
    }
}

private struct Viewing: Identifiable {
    let id = UUID()
    let show: Show
    let episode: Int
    let time: Double
}

private struct CinemaPresentation: Identifiable {
    let id = UUID()
    let show: Show
    var initialViewing: Viewing?
}

private struct Cinema: View {
    let catalog: MediaCatalog
    @ObservedObject var catalogSync: CatalogSync
    @StateObject private var library = Library()
    @State private var area: Area = .home
    @State private var featured = 0
    @State private var genre: String?
    @State private var sourceFilter: ProductionSource?
    @State private var query = ""
    @StateObject private var onlineSearch = OnlineSearchState()
    @State private var searchNotice: String?
    @FocusState private var searchFocused: Bool
    @State private var presentation: CinemaPresentation?

    var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            navigation
            #endif
            ZStack {
                ForEach(Area.allCases) { page in
                    pageContent(page)
                        .opacity(page == area ? 1 : 0)
                        .allowsHitTesting(page == area)
                        .disabled(page != area)
                        .accessibilityHidden(page != area)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            #if !os(macOS)
            navigation
            #endif
        }
        .background(backdrop)
        .cinemaPresentation($presentation, library: library)
    }

    @ViewBuilder
    private func pageContent(_ page: Area) -> some View {
        scroll {
            if page != .home {
                Text(page.rawValue).font(.largeTitle.bold())
                    .accessibilityAddTraits(.isHeader)
            }
            switch page {
            case .search:
                searchContent
            case .home:
                brand
                if catalog.featured.indices.contains(featured) { hero(catalog.featured[featured]) }
                let dramas = catalog.shows.filter { $0.genres.contains("国产短剧") }
                if !watching.isEmpty {
                    section("继续观看") { shelf(watching, continueWatching: true) }
                }
                if !dramas.isEmpty {
                    section("国产真人短剧") { shelf(dramas) }
                }
                let animation = catalog.shows.filter { $0.genres.contains("动画") && !ProductionSource.archive.owns($0) }
                if !animation.isEmpty { section("动画电影与短片") { shelf(animation) } }
                let classics = catalog.shows.filter(ProductionSource.archive.owns)
                if !classics.isEmpty {
                    section("国会图书馆 · 经典电影") { shelf(classics) }
                }
                let others = catalog.shows.filter {
                    !$0.genres.contains("动画") && !$0.genres.contains("国产短剧") && !ProductionSource.archive.owns($0)
                }
                if !others.isEmpty { section("更多短片与系列") { shelf(others) } }
            case .catalog:
                catalogSources
                filters
                let matches = catalog.shows.filter { show in
                    (sourceFilter.map { $0.owns(show) } ?? true) && (genre.map(show.genres.contains) ?? true)
                }
                Text("\(matches.count) 部作品").font(.footnote).foregroundStyle(.secondary)
                if matches.isEmpty { empty("没有符合条件的作品", symbol: "film") }
                else { grid(matches, ratio: 16.0 / 9) }
            case .library:
                section("收藏") {
                    let shows = catalog.shows.filter { library.saved.contains($0.id) }
                    if shows.isEmpty { empty("还没有收藏", symbol: "bookmark") } else { grid(shows) }
                }
                section("继续观看") {
                    if watching.isEmpty { empty("暂无观看记录", symbol: "play") } else { grid(watching, continueWatching: true) }
                }
                PublisherFeeds(sync: catalogSync)
            }
        }
        .refreshable {
            if page == .catalog { await catalogSync.refresh() }
        }
    }

    private var navigation: some View {
        HStack(spacing: 6) {
            ForEach(Area.allCases) { page in
                Button {
                    if page != .search { searchFocused = false }
                    area = page
                } label: {
                    ViewThatFits(in: .horizontal) {
                        Label(page.rawValue, systemImage: page.icon).fixedSize()
                        Image(systemName: page.icon)
                    }
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .foregroundStyle(area == page ? Color.black : Color.white.opacity(0.76))
                    .background(area == page ? Color.white : Color.clear, in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(page.rawValue)
                .accessibilityAddTraits(area == page ? .isSelected : [])
            }
        }
        .frame(maxWidth: 470)
        .padding(5)
        .background(.regularMaterial, in: Capsule())
        .overlay { Capsule().strokeBorder(.white.opacity(0.12)) }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity)
        .background(backdrop.ignoresSafeArea(edges: .bottom))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("导航")
    }

    private var watching: [Show] {
        catalog.shows.filter(library.watching).sorted {
            (library.records[$0.id]?.updated ?? .distantPast) > (library.records[$1.id]?.updated ?? .distantPast)
        }
    }

    private var searchContent: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("片名、演员或题材", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit(searchOnline)
                    .onChange(of: query) { _ in
                        onlineSearch.invalidate()
                        searchNotice = nil
                    }
                Button("在线联搜", action: searchOnline)
                    .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(13)
            .background(controlSurface, in: RoundedRectangle(cornerRadius: 10))
            Text("联搜会向国会图书馆和 Blender 官方频道发送关键词，只返回发行方提供的正片。馆藏可用英文片名搜。")
                .font(.footnote).foregroundStyle(.secondary)
            if onlineSearch.busy {
                ProgressView("正在查询发行方…").controlSize(.small)
            }
            if !onlineSearch.failures.isEmpty {
                Text("暂未查到响应：\(onlineSearch.failures.map(\.text).joined(separator: "、"))。可重试，未将失败当作零结果。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let searchNotice { Text(searchNotice).font(.footnote).foregroundStyle(.secondary) }
            if !onlineSearch.results.isEmpty {
                section("在线正片 · \(onlineSearch.results.count) 部") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140, maximum: 225), spacing: 12, alignment: .topLeading)], spacing: 17) {
                        ForEach(onlineSearch.results) { result in
                            card(result.show, ratio: 16.0 / 9, continueWatching: false) {
                                if !catalogSync.remember(result) { searchNotice = "本机无法保存此作品，仍可在线播放。" }
                                showDetail(result.show)
                            }
                        }
                    }
                }
            }
            if onlineSearch.hasMore {
                Button(onlineSearch.failures.isEmpty ? "搜索更多在线正片" : "继续搜索或重试") { onlineSearch.more() }
                    .solidControl()
            }
            let alreadyFound = Set(onlineSearch.results.map(\.id))
            let otherMatches = filtered.filter { !alreadyFound.contains($0.id) }
            if !otherMatches.isEmpty, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                section("片库中可播") { grid(otherMatches, ratio: 16.0 / 9) }
            } else if onlineSearch.results.isEmpty, !onlineSearch.busy, !onlineSearch.hasMore,
                      onlineSearch.failures.isEmpty, !onlineSearch.searched.isEmpty {
                empty("未找到匹配的公开正片", symbol: "magnifyingglass")
            }
        }
    }

    private func searchOnline() {
        searchFocused = false
        searchNotice = nil
        onlineSearch.submit(query)
    }

    private var filtered: [Show] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return catalog.shows }
        let relevance = SearchRelevance(query)
        return catalog.shows.enumerated().compactMap { index, show -> (Int, Int, Show)? in
            guard let score = relevance.score(title: show.title, metadata: show.searchText) else { return nil }
            return (score, index, show)
        }.sorted { ($0.0, $0.1) < ($1.0, $1.1) }.map(\.2)
    }

    private func scroll<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 26, content: content)
                .frame(maxWidth: 1320, alignment: .leading)
                .padding(.horizontal, 22)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
        }
        .background(backdrop)
    }

    private func section<Content: View>(_ name: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(name).font(.title3.bold()).accessibilityAddTraits(.isHeader)
            content()
        }
    }

    private func empty(_ message: String, symbol: String) -> some View {
        Label(message, systemImage: symbol)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 110)
    }

    private var brand: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Tom短剧").font(.title2.bold()).accessibilityAddTraits(.isHeader)
            Spacer()
            Text("\(catalog.shows.count) 部作品 · 免费观看")
                .font(.caption.weight(.medium)).foregroundStyle(.secondary)
        }
    }

    private func grid(_ shows: [Show], ratio: CGFloat = 0.8, continueWatching: Bool = false) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140, maximum: 225), spacing: 12, alignment: .topLeading)],
                  alignment: .leading, spacing: 17) {
            ForEach(shows) { show in
                card(show, ratio: ratio, continueWatching: continueWatching)
            }
        }
    }

    private func shelf(_ shows: [Show], continueWatching: Bool = false) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 13) {
                ForEach(shows) { show in
                    card(show, ratio: 16.0 / 9, continueWatching: continueWatching)
                        .frame(width: 212)
                }
            }
        }
    }

    private func card(_ show: Show, ratio: CGFloat, continueWatching: Bool, open: (() -> Void)? = nil) -> some View {
        Button {
            if let open { open() }
            else if continueWatching { play(show) } else { showDetail(show) }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Poster(path: show.image, title: show.title)
                    .aspectRatio(ratio, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                    .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(.white.opacity(0.12)) }
                Text(show.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                Text(continueWatching ? continueLabel(show) : show.metadata.suffix(2).joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(continueWatching ? "继续观看\(show.title)" : show.title)
    }

    private func continueLabel(_ show: Show) -> String {
        let position = library.resume(show)
        if show.episodeSummary != nil, show.episodes.indices.contains(position.episode) {
            return "第 \(show.episodeNumber(at: position.episode)) 集"
        }
        let seconds = Int(position.time)
        return String(format: "已看 %d:%02d", seconds / 60, seconds % 60)
    }

    private var catalogSources: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("片源").font(.headline)
                Spacer()
                if catalogSync.busy {
                    ProgressView().controlSize(.small).accessibilityLabel("正在同步片源")
                }
                Button { Task { await catalogSync.refresh() } } label: {
                    Label("刷新片源", systemImage: "arrow.clockwise").labelStyle(.iconOnly)
                }
                .solidControl()
                .disabled(catalogSync.busy)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    sourceChip(nil, title: "全部来源", subtitle: "\(catalog.shows.count) 部")
                    ForEach(ProductionSource.allCases) { source in
                        let label = catalogSync.sourceStatus[source]?.chipLabel ?? "随应用收录"
                        sourceChip(source, title: source.title, subtitle: "\(catalogSync.count(for: source)) 部 · \(label)")
                    }
                }
            }
            if let message = catalogSync.message {
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func sourceChip(_ source: ProductionSource?, title: String, subtitle: String) -> some View {
        Button {
            sourceFilter = source
            genre = nil
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(subtitle).font(.caption).opacity(0.68)
            }
            .padding(.horizontal, 13).padding(.vertical, 9)
            .foregroundStyle(sourceFilter == source ? Color.black : Color.white)
            .background(sourceFilter == source ? Color.white : controlSurface, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(sourceFilter == source ? .isSelected : [])
    }

    private var filters: some View {
        let genres = Set(catalog.shows.filter { show in sourceFilter.map { $0.owns(show) } ?? true }.flatMap(\.genres))
        let items = genres.filter { $0 == "国产短剧" }.sorted() + genres.filter { $0 != "国产短剧" }.sorted()
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                filter("全部", value: nil)
                ForEach(items, id: \.self) { filter($0, value: $0) }
            }
            .padding(.vertical, 4)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("题材")
    }

    private func filter(_ title: String, value: String?) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) { genre = value }
        } label: {
            Text(title).font(.subheadline.weight(.medium))
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
                .foregroundStyle(genre == value ? Color.black : Color.primary)
                .background(genre == value ? accent : Color.white.opacity(0.07), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(genre == value ? .isSelected : [])
    }

    private func hero(_ show: Show) -> some View {
        ZStack(alignment: .bottomLeading) {
            Poster(path: show.hero ?? show.image)
            LinearGradient(stops: [.init(color: backdrop, location: 0), .init(color: .black.opacity(0.65), location: 0.28), .init(color: .clear, location: 0.77)],
                           startPoint: .bottom, endPoint: .top).allowsHitTesting(false)
            LinearGradient(colors: [.black.opacity(0.62), .clear], startPoint: .leading, endPoint: .trailing)
                .allowsHitTesting(false)
            VStack(alignment: .leading, spacing: 9) {
                Text("精选呈献").font(.caption.weight(.semibold)).tracking(4).foregroundStyle(.white.opacity(0.75))
                Text(show.title)
                    .font(.system(size: 40, weight: .heavy)).lineLimit(2).minimumScaleFactor(0.65)
                    .accessibilityAddTraits(.isHeader)
                Text(show.metadata.joined(separator: " · ")).font(.footnote).foregroundStyle(.secondary)
                Text(show.description).font(.subheadline).lineLimit(2).foregroundStyle(.white.opacity(0.87))
                HStack(spacing: 10) {
                    if show.playableEpisodeIndices.isEmpty {
                        Text("暂无可播放剧集").font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Button { play(show) } label: { Label("立即播放", systemImage: "play.fill") }
                            .buttonStyle(SolidPlayStyle())
                    }
                    Button { showDetail(show) } label: {
                        Text("详情").font(.subheadline.weight(.semibold)).padding(.horizontal, 16).frame(minHeight: 44)
                    }
                    .solidControl()
                    Spacer(minLength: 5)
                    if catalog.featured.count > 1 {
                        Button {
                            withAnimation(.easeInOut(duration: 0.23)) {
                                featured = (featured + 1) % catalog.featured.count
                            }
                        } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }
                        .solidControl()
                        .accessibilityLabel("下一部精选")
                    }
                }
                .padding(.top, 4)
            }
            .padding(19)
        }
        #if os(macOS)
        .frame(height: 408)
        #else
        .frame(height: 390)
        #endif
        .clipShape(RoundedRectangle(cornerRadius: 24))
    }

    private func play(_ show: Show) {
        let resume = library.resume(show)
        guard show.playableEpisodeIndices.contains(resume.episode) else { return }
        presentation = CinemaPresentation(show: show, initialViewing: Viewing(show: show, episode: resume.episode, time: resume.time))
    }

    private func showDetail(_ show: Show) {
        presentation = CinemaPresentation(show: show)
    }
}

private struct PublisherFeeds: View {
    @ObservedObject var sync: CatalogSync
    @State private var address = ""

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(sync.feeds) { feed in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(feed.id.host ?? "").lineLimit(1)
                            Text("\(feed.count) 部全集").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("移除", role: .destructive) { sync.disconnect(feed.id) }
                            .help(feed.id.path)
                            .disabled(sync.busy)
                    }
                }
                HStack {
                    TextField("发行方目录或 GitHub JSON 链接", text: $address)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .onSubmit(connect)
                    Button("连接", action: connect)
                        .disabled(sync.busy || address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Text("支持带授权说明的发行方 HTTPS JSON。影视仓类解析器、JAR 和脚本不导入。")
                    .font(.footnote).foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    if !sync.feeds.isEmpty {
                        Button("立即同步") { Task { await sync.refresh() } }.disabled(sync.busy)
                    }
                    if sync.busy {
                        ProgressView().controlSize(.small).accessibilityLabel("正在同步片库")
                    }
                    if let message = sync.message {
                        Text(message).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.top, 12)
        } label: {
            Label("片库同步", systemImage: "arrow.triangle.2.circlepath")
                .font(.headline)
        }
        .padding(14)
        .background(controlSurface, in: RoundedRectangle(cornerRadius: 12))
    }

    private func connect() {
        Task {
            if await sync.connect(address) { address = "" }
        }
    }
}

private struct PresentedCinema: View {
    let presentation: CinemaPresentation
    @ObservedObject var library: Library
    let onClose: () -> Void
    @State private var viewing: Viewing?

    init(presentation: CinemaPresentation, library: Library, onClose: @escaping () -> Void) {
        self.presentation = presentation
        self.library = library
        self.onClose = onClose
        _viewing = State(initialValue: presentation.initialViewing)
    }

    var body: some View {
        if let viewing {
            Theater(request: viewing, library: library, onClose: closePlayer)
                .id(viewing.id)
                #if os(macOS)
                .frame(minWidth: 820, minHeight: 560)
                #endif
        } else {
            Detail(show: presentation.show, library: library, onPlay: { viewing = $0 }, onClose: onClose)
                #if os(macOS)
                .frame(minWidth: 720, minHeight: 500)
                #endif
        }
    }

    private func closePlayer() {
        if presentation.initialViewing == nil {
            viewing = nil
        } else {
            onClose()
        }
    }
}

private struct Detail: View {
    let show: Show
    @ObservedObject var library: Library
    let onPlay: (Viewing) -> Void
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 17) {
                    Poster(path: show.hero ?? show.image, title: show.title)
                        .frame(height: 225)
                        .clipShape(RoundedRectangle(cornerRadius: 21))
                    VStack(alignment: .leading, spacing: 5) {
                        Text(show.title).font(.largeTitle.bold())
                        if !show.original.isEmpty, show.original != show.title {
                            Text(show.original).foregroundStyle(.secondary)
                        }
                        Text(show.metadata.joined(separator: " · ")).font(.subheadline).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 8) {
                        if show.playableEpisodeIndices.isEmpty {
                            Text("暂无可播放剧集").font(.footnote).foregroundStyle(.secondary)
                        } else {
                            Button { start() } label: {
                                Label(library.watching(show) ? "继续观看" : "立即播放", systemImage: "play.fill")
                            }
                            .buttonStyle(SolidPlayStyle())
                        }
                        Button {
                            library.toggle(show)
                        } label: {
                            Label(library.saved.contains(show.id) ? "已收藏" : "收藏",
                                  systemImage: library.saved.contains(show.id) ? "bookmark.fill" : "bookmark")
                                .padding(.horizontal, 14).frame(minHeight: 44)
                        }
                        .solidControl()
                    }
                    Text(show.description)
                    let metadata = [(label: "主创", value: show.creators), (label: "语言", value: show.languages)]
                    ForEach(metadata, id: \.label) { field in
                        if let value = field.value, !value.isEmpty {
                            LabeledContent(field.label, value: value.joined(separator: "、"))
                                .font(.subheadline)
                        }
                    }
                    if !show.episodes.isEmpty {
                        Text(show.episodeSummary == nil ? "正片" : "选集")
                            .font(.title3.bold()).accessibilityAddTraits(.isHeader)
                        ForEach(show.episodeIndices, id: \.self) { index in
                            let episode = show.episodes[index]
                            Button { start(index) } label: {
                                EpisodeRow(number: show.episodeNumber(at: index), episode: episode, active: false)
                            }
                            .buttonStyle(.plain)
                            .disabled(!episode.isPlayable)
                        }
                    }
                    DisclosureGroup("作品署名") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(show.credit)
                            if let changes = show.changes { Text(changes) }
                            Link("作品出处", destination: show.source)
                            if let license = show.licenseUrl { Link(show.license, destination: license) }
                            else if !show.license.isEmpty { Text(show.license) }
                            ForEach(show.episodeIndices, id: \.self) { index in
                                let episode = show.episodes[index]
                                if let source = episode.source, let credit = episode.credit {
                                    Link(episode.original ?? episode.title, destination: source)
                                    Text([credit, episode.license].compactMap { $0 }.joined(separator: " · "))
                                }
                            }
                        }
                        .font(.footnote).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.subheadline)
                }
                .frame(maxWidth: 680, alignment: .leading)
                .padding(20)
                .frame(maxWidth: .infinity)
            }
            .background(backdrop)
            .overlay(alignment: .topTrailing) {
                Button(action: onClose) {
                    Image(systemName: "xmark").frame(width: 44, height: 44)
                }
                .solidControl()
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("关闭详情")
                .padding(12)
            }
        }
    }

    private func start(_ explicit: Int? = nil) {
        let position = library.resume(show)
        let index = explicit ?? position.episode
        guard show.playableEpisodeIndices.contains(index) else { return }
        onPlay(Viewing(show: show, episode: index, time: position.episode == index ? position.time : 0))
    }
}

private struct EpisodeRow: View {
    let number: Int
    let episode: Episode
    let active: Bool

    var body: some View {
        let available = episode.isPlayable
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: active ? "speaker.wave.2" : available ? "play" : "clock")
                .frame(width: 23, height: 21)
            VStack(alignment: .leading, spacing: 4) {
                Text("第 \(number) 集 · \(episode.title)").font(.subheadline.weight(.semibold))
                if let description = episode.description {
                    Text(description).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            if !available {
                Text("暂不可播").font(.caption).foregroundStyle(.secondary)
            } else if let duration = episode.durationLabel {
                Text(duration).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(minHeight: 48)
        .foregroundStyle(active ? accent : Color.primary)
        .background(Color.white.opacity(active ? 0.12 : 0.06), in: RoundedRectangle(cornerRadius: 13))
    }
}

private struct Theater: View {
    let request: Viewing
    @ObservedObject var library: Library
    let onClose: () -> Void
    @StateObject private var playback = Playback()
    @Environment(\.scenePhase) private var phase
    @State private var current = 0
    @State private var seconds = 0.0
    @State private var duration = 0.0
    @State private var captions: [Caption] = []
    @State private var showCaptions = true
    @State private var missingNextEpisode: Int?
    @State private var finished = false
    @State private var officialPlayerURL: URL?
    @State private var selectedQuality: Int?
    @State private var showEpisodes = true

    private var hasEpisodeList: Bool { request.show.episodeSummary != nil }

    private var availableQualities: [Int] {
        guard officialPlayerURL == nil, request.show.episodes.indices.contains(current) else { return [] }
        return request.show.episodes[current].availableQualities
    }

    private var activeQuality: Int? {
        guard let url = playback.activeSourceURL, request.show.episodes.indices.contains(current) else { return nil }
        return request.show.episodes[current].quality(of: url)
    }

    private var qualityDescription: String {
        let selection = selectedQuality.map { "\($0)p" } ?? "自动"
        guard playback.activeSourceURL != nil else { return selection }
        guard let activeQuality else { return "\(selection)，当前画质未标注" }
        guard activeQuality != selectedQuality else { return selection }
        return "\(selection)，当前 \(activeQuality)p"
    }

    var body: some View {
        GeometryReader { layout in
            let displaysEpisodes = hasEpisodeList && showEpisodes
            let sidebarMinimum: CGFloat = officialPlayerURL == nil ? 750 : 880
            let wide = layout.size.width > sidebarMinimum && displaysEpisodes
            let playbackLayout = wide ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            VStack(spacing: 0) {
                header
                playbackLayout {
                    screen
                        .frame(maxHeight: displaysEpisodes && !wide ? layout.size.height * 0.56 : .infinity)
                    if displaysEpisodes {
                        episodes.frame(width: wide ? 285 : nil)
                    }
                }
            }
        }
        .background(.black)
        .onAppear { play(request.episode, from: request.time) }
        .onDisappear {
            playback.close()
            library.persist()
        }
        .onChange(of: phase) { value in
            if value != .active { library.persist() }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(request.show.title).font(.headline).lineLimit(1)
                if request.show.episodeSummary != nil, request.show.episodes.indices.contains(current) {
                    Text("第 \(request.show.episodeNumber(at: current)) 集 · \(request.show.episodes[current].title)")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if availableQualities.count > 1 { qualityMenu }
            if !captions.isEmpty {
                Button {
                    showCaptions.toggle()
                } label: {
                    Image(systemName: showCaptions ? "captions.bubble.fill" : "captions.bubble")
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(showCaptions ? "关闭中文字幕" : "打开中文字幕")
                .solidControl()
            }
            if hasEpisodeList {
                Button {
                    showEpisodes.toggle()
                } label: {
                    Image(systemName: "list.bullet")
                        .foregroundStyle(showEpisodes ? accent : Color.primary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(showEpisodes ? "收起选集" : "显示选集")
                .solidControl()
            }
            Button(action: close) {
                Image(systemName: "xmark").frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
                .accessibilityLabel("关闭播放器")
                .solidControl()
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var qualityMenu: some View {
        Menu {
            qualityOption(nil, label: "自动")
            ForEach(availableQualities, id: \.self) { height in
                qualityOption(height, label: "\(height)p")
            }
        } label: {
            let height = playback.activeSourceURL == nil ? selectedQuality : activeQuality
            Text(height.map { "\($0)p" } ?? "画质")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 8)
                .frame(minHeight: 44)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .background(controlSurface, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityLabel("画质")
        .accessibilityValue(qualityDescription)
    }

    private func qualityOption(_ height: Int?, label: String) -> some View {
        Button {
            let canRetryQuality = height != nil && activeQuality != height && !playback.loading
            guard selectedQuality != height || playback.failed || canRetryQuality else { return }
            play(current, from: finished ? 0 : playback.resumePosition,
                 quality: height, autoplay: playback.intendsToPlay || playback.failed)
        } label: {
            if selectedQuality == height { Label(label, systemImage: "checkmark") }
            else { Text(label) }
        }
    }

    @ViewBuilder
    private var screen: some View {
        if let officialPlayerURL {
            VStack(spacing: 0) {
                OfficialPlayerScreen(url: officialPlayerURL)
                    .id(officialPlayerURL)
                Text("官方播放器游客画质 360p，更高清晰度需登录。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity)
            }
        } else {
            directScreen
        }
    }

    private var directScreen: some View {
        ZStack(alignment: .bottom) {
            NativeVideo(player: playback.player)
                .background(.black)
            if showCaptions, let caption = captions.last(where: { seconds >= $0.start && seconds < $0.end }) {
                Text(caption.text)
                    .font(.subheadline.weight(.medium))
                    .multilineTextAlignment(.center)
                    .padding(.vertical, 5)
                    .padding(.horizontal, 10)
                    .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 6))
                    .padding(.horizontal, 14)
                    .padding(.bottom, 80)
                    .allowsHitTesting(false)
            }
            if playback.failed {
                VStack(spacing: 12) {
                    Text("暂时无法播放这集")
                    Button("重试") { playback.retry() }.buttonStyle(SolidPlayStyle())
                }
                .padding(22)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black.opacity(0.75))
            } else if playback.loading {
                ProgressView().tint(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
                    .accessibilityLabel("正在加载")
            } else if let missingNextEpisode {
                Text("第 \(missingNextEpisode) 集暂不可播放")
                    .padding(12)
                    .background(controlSurface, in: RoundedRectangle(cornerRadius: 10))
                    .padding(.bottom, 68)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var episodes: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 7) {
                Text("选集").font(.headline)
                ForEach(request.show.episodeIndices, id: \.self) { index in
                    let episode = request.show.episodes[index]
                    Button {
                        if index != current { play(index) }
                        else if officialPlayerURL == nil, playback.failed { playback.retry() }
                        else if officialPlayerURL == nil, playback.player.timeControlStatus == .paused {
                            if finished {
                                play(index)
                            } else {
                                playback.player.play()
                            }
                        }
                    } label: {
                        EpisodeRow(number: request.show.episodeNumber(at: index), episode: episode, active: current == index)
                    }
                    .buttonStyle(.plain)
                    .disabled(!episode.isPlayable)
                    .accessibilityAddTraits(current == index ? .isSelected : [])
                }
            }
            .padding(12)
        }
        .background(backdrop)
    }

    private func close() {
        playback.close()
        officialPlayerURL = nil
        library.persist()
        onClose()
    }

    private func play(_ index: Int, from time: Double = 0, quality: Int? = nil, autoplay: Bool = true) {
        let show = request.show
        guard show.playableEpisodeIndices.contains(index) else { return }
        let episode = show.episodes[index]
        playback.close()
        current = index
        seconds = time
        duration = 0
        selectedQuality = quality
        missingNextEpisode = nil
        finished = false
        captions = Caption.load(at: episode.subtitles)
        officialPlayerURL = episode.officialPlayerURL
        if officialPlayerURL != nil {
            library.rememberEpisode(show, at: index)
            return
        }
        playback.open(urls: episode.playableSources(preferringQuality: quality), resumeAt: time, autoplay: autoplay, onProgress: { time, total in
            self.seconds = time
            self.duration = total
            library.update(show, episode: index, time: time)
        }, onEnd: {
            finished = true
            library.update(show, episode: index, time: duration, ended: true)
            if let next = show.nextEpisode(after: index) {
                play(next)
            } else {
                let (upcoming, overflow) = show.episodeNumber(at: index).addingReportingOverflow(1)
                guard !overflow else { return }
                if (show.totalEpisodes ?? 0) >= upcoming ||
                    show.episodeIndices.contains(where: { show.episodeNumber(at: $0) >= upcoming }) {
                    missingNextEpisode = upcoming
                }
            }
        })
    }
}

private struct OfficialPlayerScreen: View {
    let url: URL
    @State private var attempt = UUID()
    @State private var loading = true
    @State private var failed = false

    var body: some View {
        ZStack {
            OfficialWebPlayer(url: url, onResult: { success in
                loading = false
                failed = !success
            })
            .id(attempt)
            if loading {
                ProgressView().tint(.white)
                    .allowsHitTesting(false)
                    .accessibilityLabel("正在加载正片")
            }
            if failed {
                VStack(spacing: 12) {
                    Text("暂时无法播放这集")
                    Button("重试") {
                        loading = true
                        failed = false
                        attempt = UUID()
                    }
                    .buttonStyle(SolidPlayStyle())
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
        .task(id: attempt) {
            do {
                try await Task.sleep(nanoseconds: 25_000_000_000)
            } catch {
                return
            }
            if loading {
                loading = false
                failed = true
            }
        }
    }
}

private struct OfficialWebPlayer {
    let url: URL
    let onResult: (Bool) -> Void
    @MainActor private static let sessionDataStore = WKWebsiteDataStore.nonPersistent()

    func makeCoordinator() -> Coordinator {
        Coordinator(onResult: onResult)
    }

    @MainActor func makePlayer(coordinator: Coordinator) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = Self.sessionDataStore
        config.mediaTypesRequiringUserActionForPlayback = []
        #if os(iOS)
        config.allowsInlineMediaPlayback = true
        config.defaultWebpagePreferences.preferredContentMode = .desktop
        #endif
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = coordinator
        view.underPageBackgroundColor = .black
        view.load(URLRequest(url: url))
        return view
    }

    static func stopPlayer(_ view: WKWebView) {
        view.navigationDelegate = nil
        view.stopLoading()
        view.pauseAllMediaPlayback(completionHandler: {})
        view.closeAllMediaPresentations(completionHandler: {})
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onResult: (Bool) -> Void

        init(onResult: @escaping (Bool) -> Void) {
            self.onResult = onResult
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let target = navigationAction.targetFrame else {
                decisionHandler(.cancel)
                return
            }
            let url = navigationAction.request.url
            let allowed = !target.isMainFrame || (url?.scheme == "https" && url?.host == "player.bilibili.com")
            decisionHandler(allowed ? .allow : .cancel)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { onResult(true) }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            reportNavigationFailure(error)
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) { reportNavigationFailure(error) }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { onResult(false) }

        private func reportNavigationFailure(_ error: Error) {
            let failure = error as NSError
            if failure.domain == NSURLErrorDomain, failure.code == NSURLErrorCancelled { return }
            onResult(false)
        }
    }
}

#if os(macOS)
extension OfficialWebPlayer: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { makePlayer(coordinator: context.coordinator) }
    func updateNSView(_ view: WKWebView, context: Context) {}
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) { stopPlayer(view) }
}
#else
extension OfficialWebPlayer: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { makePlayer(coordinator: context.coordinator) }
    func updateUIView(_ view: WKWebView, context: Context) {}
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) { stopPlayer(view) }
}
#endif

#if os(macOS)
private struct NativeVideo: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}
#else
private struct NativeVideo: View {
    let player: AVPlayer

    var body: some View {
        VideoPlayer(player: player)
    }
}
#endif

private struct Poster: View {
    let path: String
    var title: String? = nil

    private var artwork: Image? {
        guard !path.isEmpty, let url = Bundle.main.resourceURL?.appendingPathComponent(path) else { return nil }
        #if os(macOS)
        return NSImage(contentsOf: url).map { Image(nsImage: $0) }
        #else
        return UIImage(contentsOfFile: url.path).map { Image(uiImage: $0) }
        #endif
    }

    private var remoteArtwork: URL? {
        guard let url = URL(string: path), url.scheme == "https", url.host != nil else { return nil }
        return url
    }

    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .overlay {
                if let remoteArtwork {
                    AsyncImage(url: remoteArtwork) { phase in
                        if let image = phase.image { cover(image) }
                        else { placeholder }
                    }
                } else {
                    if let image = artwork { cover(image) }
                    else { placeholder }
                }
            }
            .clipped()
            .accessibilityHidden(true)
    }

    private func cover(_ image: Image) -> some View {
        GeometryReader { proxy in
            image.resizable().scaledToFill()
                .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    private var placeholder: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottomLeading) {
                LinearGradient(colors: [Color(red: 0.32, green: 0.16, blue: 0.11), backdrop],
                               startPoint: .topTrailing, endPoint: .bottomLeading)
                if let title {
                    Text(title)
                        .font(.system(size: min(proxy.size.width * 0.09, 46), weight: .heavy))
                        .foregroundStyle(accent)
                        .minimumScaleFactor(0.7)
                        .lineLimit(2)
                        .padding(13)
                }
            }
        }
    }
}

private struct SolidPlayStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .foregroundStyle(Color.black)
            .background(configuration.isPressed ? Color(white: 0.77) : accent,
                        in: RoundedRectangle(cornerRadius: 10))
    }
}

private extension View {
    func solidControl() -> some View {
        buttonStyle(.plain)
            .background(controlSurface, in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    func cinemaPresentation(_ selection: Binding<CinemaPresentation?>, library: Library) -> some View {
        #if os(macOS)
        sheet(item: selection) { request in
            PresentedCinema(presentation: request, library: library, onClose: { selection.wrappedValue = nil })
        }
        #else
        fullScreenCover(item: selection) { request in
            PresentedCinema(presentation: request, library: library, onClose: { selection.wrappedValue = nil })
        }
        #endif
    }
}
