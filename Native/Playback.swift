import AVFoundation
import Combine
import Foundation

@MainActor
final class Playback: ObservableObject {
    private static let startupTimeout: UInt64 = 20
    private static let stallTimeout: UInt64 = 5
    private static let seekTimeout: UInt64 = 10

    let player = AVPlayer()

    @Published private(set) var failed = false
    @Published private(set) var loading = false
    @Published private(set) var activeSourceURL: URL?

    private var urls: [URL] = []
    private var sourceIndex = 0
    private var attempt = UUID()
    private var position = 0.0
    private var starting = false
    private var startPlaying = true
    private var hasPlayed = false
    private var lastTimeJump = -Double.infinity
    private var ended = false
    private var onProgress: ((Double, Double) -> Void)?
    private var onEnd: (() -> Void)?
    private var watchdog: Task<Void, Never>?
    private var itemObservation: NSKeyValueObservation?
    private var playerObservation: NSKeyValueObservation?
    private var notifications: [NSObjectProtocol] = []
    private var timeObserver: Any?

    init() {
        player.automaticallyWaitsToMinimizeStalling = true
    }

    var intendsToPlay: Bool {
        starting ? startPlaying : player.timeControlStatus != .paused
    }

    var resumePosition: Double {
        if !starting, !failed, player.currentItem?.status == .readyToPlay {
            let time = player.currentTime().seconds
            if time.isFinite && time >= 0 { return time }
        }
        return position
    }

    deinit {
        watchdog?.cancel()
        notifications.forEach(NotificationCenter.default.removeObserver)
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
    }

    func open(
        urls: [URL],
        resumeAt: Double,
        autoplay: Bool = true,
        onProgress: @escaping (Double, Double) -> Void,
        onEnd: @escaping () -> Void
    ) {
        close()
        var seen: Set<URL> = []
        self.urls = urls.filter { seen.insert($0).inserted }
        self.position = resumeAt.isFinite ? max(resumeAt, 0) : 0
        self.startPlaying = autoplay
        self.onProgress = onProgress
        self.onEnd = onEnd
        startSource()
    }

    func retry() {
        guard failed, !urls.isEmpty else { return }
        sourceIndex = 0
        startSource()
    }

    func close() {
        savePosition()
        detachPlayerItem()
        urls.removeAll()
        sourceIndex = 0
        position = 0
        onProgress = nil
        onEnd = nil
        activeSourceURL = nil
        failed = false
        loading = false
    }

    private func startSource() {
        guard urls.indices.contains(sourceIndex) else {
            activeSourceURL = nil
            loading = false
            failed = true
            return
        }

        let item = AVPlayerItem(url: urls[sourceIndex])
        let id = attempt
        failed = false
        loading = true
        starting = true
        ended = false
        player.replaceCurrentItem(with: item)

        itemObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.itemStatusChanged(id) }
        }
        playerObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.playbackStatusChanged(id) }
        }
        observe(AVPlayerItem.didPlayToEndTimeNotification, item: item) { [weak self] in self?.finish(id) }
        observe(AVPlayerItem.failedToPlayToEndTimeNotification, item: item) { [weak self] in self?.advance(id) }
        observe(AVPlayerItem.timeJumpedNotification, item: item) { [weak self] in self?.playheadJumped(id) }

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.attempt == id else { return }
                self.savePosition()
            }
        }

        startWatchdog(seconds: Self.startupTimeout, id: id)
    }

    private func itemStatusChanged(_ id: UUID) {
        guard attempt == id, !ended, let item = player.currentItem else { return }
        switch item.status {
        case .failed:
            advance(id)
        case .readyToPlay:
            guard starting else { return }
            if position <= 0 {
                startPlayback(id)
                return
            }

            let duration = item.duration.seconds
            let seekPosition = duration.isFinite && duration > 0
                ? min(position, max(0, duration - 0.25))
                : position
            player.seek(
                to: CMTime(seconds: seekPosition, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.startPlayback(id) }
            }
        case .unknown:
            break
        @unknown default:
            break
        }
    }

    private func startPlayback(_ id: UUID) {
        guard attempt == id, starting, !ended else { return }
        activeSourceURL = urls[sourceIndex]
        starting = false
        if startPlaying {
            player.play()
        } else {
            watchdog?.cancel()
            watchdog = nil
            loading = false
            savePosition()
        }
    }

    private func playbackStatusChanged(_ id: UUID) {
        guard attempt == id, !starting, !ended else { return }
        switch player.timeControlStatus {
        case .playing:
            hasPlayed = true
            startPlaying = true
            fallthrough
        case .paused:
            watchdog?.cancel()
            watchdog = nil
            loading = false
        case .waitingToPlayAtSpecifiedRate:
            loading = true
            if watchdog == nil {
                let recentJump = ProcessInfo.processInfo.systemUptime - lastTimeJump < 1
                let stallDelay = recentJump ? Self.seekTimeout : Self.stallTimeout
                startWatchdog(seconds: hasPlayed ? stallDelay : Self.startupTimeout, id: id)
            }
        @unknown default:
            break
        }
    }

    private func playheadJumped(_ id: UUID) {
        guard attempt == id, !starting, !ended else { return }
        lastTimeJump = ProcessInfo.processInfo.systemUptime
        savePosition()
        // A seek can require a fresh byte range. Give it longer to recover.
        if attempt == id, hasPlayed, player.timeControlStatus == .waitingToPlayAtSpecifiedRate {
            startWatchdog(seconds: Self.seekTimeout, id: id)
        }
    }

    private func startWatchdog(seconds: UInt64, id: UUID) {
        watchdog?.cancel()
        watchdog = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled, let self, self.attempt == id, !self.ended else { return }
            self.watchdog = nil
            guard self.loading, self.starting || self.player.timeControlStatus == .waitingToPlayAtSpecifiedRate else {
                return
            }
            self.advance(id)
        }
    }

    private func advance(_ id: UUID) {
        guard attempt == id, !ended else { return }
        // AVPlayer can reset to zero when an item fails. Retain the last valid playhead.
        if player.currentItem?.status == .readyToPlay {
            savePosition()
        }
        guard attempt == id else { return }
        detachPlayerItem()
        sourceIndex += 1
        startSource()
    }

    private func finish(_ id: UUID) {
        guard attempt == id, !ended else { return }
        savePosition()
        guard attempt == id else { return }
        ended = true
        loading = false
        watchdog?.cancel()
        watchdog = nil
        onEnd?()
    }

    private func savePosition() {
        guard !starting, !ended, let item = player.currentItem, item.status == .readyToPlay else { return }
        let current = player.currentTime().seconds
        let duration = item.duration.seconds
        guard current.isFinite, current >= 0 else { return }
        position = current
        if duration.isFinite, duration > 0 {
            onProgress?(current, duration)
        }
    }

    private func observe(
        _ notification: Notification.Name,
        item: AVPlayerItem,
        action: @escaping @MainActor () -> Void
    ) {
        let observer = NotificationCenter.default.addObserver(
            forName: notification,
            object: item,
            queue: .main
        ) { _ in
            Task { @MainActor in action() }
        }
        notifications.append(observer)
    }

    private func detachPlayerItem() {
        attempt = UUID()
        watchdog?.cancel()
        watchdog = nil
        itemObservation = nil
        playerObservation = nil
        notifications.forEach(NotificationCenter.default.removeObserver)
        notifications.removeAll()
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        player.pause()
        player.replaceCurrentItem(with: nil)
        starting = false
        hasPlayed = false
        lastTimeJump = -Double.infinity
        ended = false
    }
}
