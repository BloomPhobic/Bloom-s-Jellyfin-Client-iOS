import Foundation
import JellyfinAPI
import Network
import Observation

/// A downloaded (or downloading) movie or episode, with what's needed to show and play it offline.
struct DownloadRecord: Codable, Identifiable {
    enum State: String, Codable {
        case queued
        case downloading
        case paused
        case failed
        case done
    }

    /// The item's ID.
    let id: String
    /// The account that downloaded it. Each account only sees its own downloads.
    let userID: String
    let serverID: String?
    /// The full item as it was when downloaded (names, artwork tags, media streams).
    var item: BaseItemDto
    let mediaSourceID: String?
    /// The video's file name inside the item's folder, e.g. "media.mkv".
    let fileName: String
    var totalBytes: Int64
    var receivedBytes: Int64
    var state: State
    var errorMessage: String?
    /// The failure was the network's, so it's retried by itself when the connection returns.
    var retryable: Bool
    let addedAt: Date
    /// Skip markers, saved so Skip intro works offline.
    var segments: [MediaSegmentDto]
    /// Progress made on the downloaded file. Kept until it has reached the server.
    var position: Double?
    var played: Bool?
    var progressUpdatedAt: Date?
    var needsSync: Bool

    var isEpisode: Bool { item.type == .episode }

    var fraction: Double {
        totalBytes > 0 ? Double(receivedBytes) / Double(totalBytes) : 0
    }

    /// Where to start: progress made on this file if it's newer, otherwise the server's.
    var resumeSeconds: Double {
        if played == true { return 0 }
        if let position, progressUpdatedAt != nil { return position }
        return item.isPlayed ? 0 : item.resumeSeconds
    }

    var isWatched: Bool { played ?? item.isPlayed }
}

/// Where downloads live on disk. Separate from the store so the URL session's delegate (which runs
/// off the main thread) can use it.
enum DownloadFiles {
    /// Application Support/Downloads: kept until deleted, and left out of iCloud backups.
    static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var url = base.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        return url
    }()

    static var index: URL { root.appendingPathComponent("index.json") }

    static func folder(_ id: String) -> URL {
        root.appendingPathComponent(id, isDirectory: true)
    }

    static func resumeData(_ id: String) -> URL {
        folder(id).appendingPathComponent("resume.data")
    }

    static func poster(_ id: String) -> URL {
        folder(id).appendingPathComponent("poster.jpg")
    }

    static func still(_ id: String) -> URL {
        folder(id).appendingPathComponent("still.jpg")
    }

    /// Space left on the phone for things the user asked for.
    static var freeBytes: Int64 {
        let values = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    /// "itemID|fileName", stored on each URL session task so a relaunched app knows what it was.
    static func taskDescription(id: String, fileName: String) -> String {
        "\(id)|\(fileName)"
    }

    static func parse(_ description: String?) -> (id: String, fileName: String)? {
        guard let parts = description?.split(separator: "|", maxSplits: 1), parts.count == 2 else { return nil }
        return (String(parts[0]), String(parts[1]))
    }
}

/// Downloads movies and episodes (the original file, never a transcode) with iOS's background
/// downloader, so they continue when the app is in the background. Also keeps progress made on
/// downloaded files and sends it to the server when the connection is back.
@MainActor
@Observable
final class DownloadStore {
    static let shared = DownloadStore()
    static let cellularKey = "downloads.allowCellular"

    private(set) var records: [String: DownloadRecord] = [:]
    /// The phone is on Wi-Fi (or wired). Downloads wait for it unless mobile data is allowed.
    private(set) var isOnWiFi = true
    /// Bumped when artwork is saved, so rows showing a placeholder load it.
    private(set) var artworkRevision = 0

    @ObservationIgnored var backgroundCompletion: (() -> Void)?
    @ObservationIgnored private weak var sessionStore: SessionStore?
    @ObservationIgnored private var urlSession: URLSession!
    @ObservationIgnored private let delegate = DownloadSessionDelegate()
    @ObservationIgnored private var tasks: [String: URLSessionDownloadTask] = [:]
    @ObservationIgnored private var pausing: Set<String> = []
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var lastProgressNote: [String: Date] = [:]
    @ObservationIgnored private var refreshObserver: NSObjectProtocol?
    @ObservationIgnored private var addressObserver: NSObjectProtocol?
    @ObservationIgnored private var isSyncing = false
    /// Download speed per item, in bytes a second, smoothed so the number doesn't jump around.
    private(set) var speeds: [String: Double] = [:]
    @ObservationIgnored private var speedSamples: [String: (time: Date, bytes: Int64)] = [:]

    static var allowsCellular: Bool {
        UserDefaults.standard.bool(forKey: cellularKey)
    }

    private init() {
        load()
        let configuration = URLSessionConfiguration.background(withIdentifier: "\(Bundle.main.bundleIdentifier ?? "jellyfinclient").downloads")
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        // One file at a time; the rest wait their turn.
        configuration.httpMaximumConnectionsPerHost = 1
        urlSession = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        Task { await reattach() }
        startPathMonitor()
        refreshObserver = NotificationCenter.default.addObserver(forName: .contentShouldRefresh, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.connectionReturned()
            }
        }
        addressObserver = NotificationCenter.default.addObserver(forName: .serverAddressChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.restartMovedDownloads()
            }
        }
    }

    /// Connects the store to the signed-in accounts. Called once at launch.
    func attach(_ store: SessionStore) {
        sessionStore = store
        connectionReturned()
    }

    // MARK: - Queries

    /// The current account's downloads.
    func list(for userID: String?) -> [DownloadRecord] {
        guard let userID else { return [] }
        return records.values.filter { $0.userID == userID }
    }

    func record(_ itemID: String?) -> DownloadRecord? {
        itemID.flatMap { records[$0] }
    }

    /// The downloaded file for an item, if it's complete (and of the requested version).
    func fileURL(itemID: String, mediaSourceID: String?) -> URL? {
        guard let record = records[itemID], record.state == .done else { return nil }
        if let mediaSourceID, let saved = record.mediaSourceID, mediaSourceID != saved {
            return nil
        }
        let url = DownloadFiles.folder(itemID).appendingPathComponent(record.fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func posterURL(_ itemID: String?) -> URL? {
        guard let itemID else { return nil }
        let url = DownloadFiles.poster(itemID)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func stillURL(_ itemID: String?) -> URL? {
        guard let itemID else { return nil }
        let url = DownloadFiles.still(itemID)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Downloaded episodes of a show, in order.
    func episodes(seriesID: String?, userID: String?) -> [DownloadRecord] {
        guard let seriesID else { return [] }
        return list(for: userID)
            .filter { $0.state == .done && $0.item.seriesID == seriesID }
            .sorted(by: Self.episodeOrder)
    }

    /// The next downloaded episode after this one, for playing on without a connection.
    func nextEpisode(after item: BaseItemDto, userID: String?) -> BaseItemDto? {
        let list = episodes(seriesID: item.seriesID, userID: userID)
        guard let index = list.firstIndex(where: { $0.id == item.id }), list.indices.contains(index + 1) else { return nil }
        return list[index + 1].item
    }

    static func episodeOrder(_ a: DownloadRecord, _ b: DownloadRecord) -> Bool {
        let left = (a.item.parentIndexNumber ?? 0, a.item.indexNumber ?? 0)
        let right = (b.item.parentIndexNumber ?? 0, b.item.indexNumber ?? 0)
        return left < right
    }

    /// Bytes used on the phone by this account's downloads (finished ones plus what's arrived so far).
    func usedBytes(userID: String?) -> Int64 {
        list(for: userID).reduce(0) { $0 + ($1.state == .done ? $1.totalBytes : $1.receivedBytes) }
    }

    /// A download's row text: the sizes on the first line, then the percentage or what it's waiting for.
    func statusLines(_ record: DownloadRecord) -> (sizes: String, status: String) {
        let size = Self.format(record.totalBytes)
        let sizes = record.receivedBytes > 0 ? "\(Self.format(record.receivedBytes)) of \(size)" : size
        let percent = "\(Int(record.fraction * 100))%"
        switch record.state {
        case .done:
            return (size, "Downloaded")
        case .queued, .downloading:
            if !isOnWiFi && !Self.allowsCellular {
                return (sizes, "Waiting for Wi-Fi")
            }
            if record.receivedBytes == 0 {
                return (sizes, record.state == .queued ? "Queued" : "Starting…")
            }
            if let speed = speed(record.id) {
                return (sizes, "\(percent) · \(Self.formatSpeed(speed))")
            }
            return (sizes, percent)
        case .paused:
            return (sizes, "Paused · \(percent)")
        case .failed:
            return (sizes, record.errorMessage ?? "Download failed")
        }
    }

    /// An item's current speed, if it has received something in the last few seconds.
    func speed(_ id: String, now: Date = Date()) -> Double? {
        guard let sample = speedSamples[id], now.timeIntervalSince(sample.time) < 5,
              let speed = speeds[id], speed > 0 else { return nil }
        return speed
    }

    /// Everything downloading right now, added up. Nil when nothing is moving.
    func totalSpeed(userID: String?, now: Date = Date()) -> Double? {
        let total = list(for: userID).compactMap { speed($0.id, now: now) }.reduce(0, +)
        return total > 0 ? total : nil
    }

    static func formatSpeed(_ bytesPerSecond: Double) -> String {
        "\(ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file))/s"
    }

    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    // MARK: - Starting, pausing, deleting

    /// Starts downloading an item's original file. Returns a message for the user if it can't.
    func download(itemID: String, api: LibraryAPI) async -> String? {
        if let existing = records[itemID], existing.state != .failed {
            return nil
        }
        let item: BaseItemDto
        do {
            item = try await api.item(itemID)
        } catch {
            return "Couldn't load the item: \(error.localizedDescription)"
        }
        guard let source = item.mediaSources?.first,
              let url = api.streamURL(itemID: itemID, mediaSourceID: source.id) else {
            return "This item has no file to download."
        }

        let size = Int64(source.size ?? 0)
        let stillToCome = records.values.filter { $0.state != .done }.reduce(Int64(0)) { $0 + max(0, $1.totalBytes - $1.receivedBytes) }
        let free = DownloadFiles.freeBytes
        // Leave some room so the phone doesn't run completely full.
        let margin: Int64 = 500 * 1024 * 1024
        if size > 0, size + stillToCome + margin > free {
            let name = item.name ?? "This item"
            return "Not enough space. \(name) needs \(Self.format(size)), and \(Self.format(max(0, free - stillToCome))) is free."
        }

        let fileExtension = Self.fileExtension(for: source)
        let record = DownloadRecord(
            id: itemID,
            userID: api.userID,
            serverID: item.serverID,
            item: item,
            mediaSourceID: source.id,
            fileName: "media.\(fileExtension)",
            totalBytes: size,
            receivedBytes: 0,
            state: .queued,
            errorMessage: nil,
            retryable: false,
            addedAt: Date(),
            segments: [],
            position: nil,
            played: nil,
            progressUpdatedAt: nil,
            needsSync: false
        )
        try? FileManager.default.removeItem(at: DownloadFiles.folder(itemID))
        try? FileManager.default.createDirectory(at: DownloadFiles.folder(itemID), withIntermediateDirectories: true)
        records[itemID] = record
        save()
        startTask(record, url: url)
        AppLog.shared.log("Download started: \(Self.title(item)) (\(Self.format(size)))")

        // Artwork and skip markers, so the download looks and works the same offline.
        Task {
            await saveExtras(itemID: itemID, item: item, api: api)
        }
        return nil
    }

    func pause(_ id: String) {
        guard let task = tasks[id] else { return }
        pausing.insert(id)
        clearSpeed(id)
        task.cancel(byProducingResumeData: { data in
            guard let data else { return }
            try? data.write(to: DownloadFiles.resumeData(id))
        })
        AppLog.shared.log("Download paused: \(Self.title(records[id]?.item))")
    }

    /// Resumes a paused or failed download, from where it stopped when possible.
    func resume(_ id: String) {
        guard var record = records[id], record.state != .done else { return }
        let hasResumeData = FileManager.default.fileExists(atPath: DownloadFiles.resumeData(id).path)
        let url = currentAPI(for: record)?.streamURL(itemID: id, mediaSourceID: record.mediaSourceID)
        guard hasResumeData || url != nil else {
            record.state = .failed
            record.errorMessage = "Connect to the server to continue"
            records[id] = record
            return
        }
        record.state = .queued
        record.errorMessage = nil
        record.retryable = false
        records[id] = record
        save()
        startTask(record, url: url)
    }

    func delete(_ id: String) {
        tasks[id]?.cancel()
        tasks[id] = nil
        pausing.remove(id)
        clearSpeed(id)
        let name = Self.title(records[id]?.item)
        records[id] = nil
        try? FileManager.default.removeItem(at: DownloadFiles.folder(id))
        save()
        AppLog.shared.log("Download removed: \(name)")
    }

    func deleteAll(userID: String?) {
        for record in list(for: userID) {
            delete(record.id)
        }
    }

    /// Pauses every download of this account (keeping what has arrived).
    func pauseAll(userID: String?) {
        for record in list(for: userID) where record.state == .queued || record.state == .downloading {
            pause(record.id)
        }
    }

    func resumeAll(userID: String?) {
        for record in list(for: userID) where record.state == .paused || record.state == .failed {
            resume(record.id)
        }
    }

    /// Restarts unfinished tasks so the new mobile-data setting applies. iOS fixes the setting when a
    /// task starts, so a task waiting for Wi-Fi would otherwise keep waiting. Ones that have started
    /// are stopped with their resume data and continue from where they were.
    func cellularSettingChanged() {
        restartUnfinished { _, _ in true }
        AppLog.shared.log("Mobile data for downloads: \(Self.allowsCellular ? "on" : "off")")
    }

    /// Restarts running tasks still aimed at an old server address (the home network one after
    /// leaving Wi-Fi, say), which would otherwise keep waiting for an address they can't reach.
    private func restartMovedDownloads() {
        restartUnfinished { task, url in
            guard let url, let old = task.originalRequest?.url else { return false }
            let moved = old.host != url.host || old.port != url.port || old.scheme != url.scheme
            if moved {
                AppLog.shared.log("Download moved to the server address in use now")
            }
            return moved
        }
    }

    /// Stops unfinished tasks (keeping what has arrived) and starts them again with the current
    /// settings and server address.
    private func restartUnfinished(where shouldRestart: (URLSessionDownloadTask, URL?) -> Bool) {
        for record in records.values where record.state == .queued || record.state == .downloading {
            guard let task = tasks[record.id] else { continue }
            let id = record.id
            let url = currentAPI(for: record)?.streamURL(itemID: id, mediaSourceID: record.mediaSourceID)
            guard shouldRestart(task, url) else { continue }
            tasks[id] = nil
            clearSpeed(id)
            guard record.receivedBytes > 0 else {
                task.cancel()
                startTask(record, url: url)
                continue
            }
            task.cancel(byProducingResumeData: { data in
                Task { @MainActor in
                    let store = DownloadStore.shared
                    // Deleted or restarted meanwhile.
                    guard let current = store.records[id], store.tasks[id] == nil, current.state != .done else { return }
                    if let data {
                        try? data.write(to: DownloadFiles.resumeData(id))
                    } else {
                        AppLog.shared.log("Download of \(Self.title(current.item)) restarts from the beginning (no resume data)", level: .warning)
                    }
                    store.startTask(current, url: url)
                }
            })
        }
    }

    private func startTask(_ record: DownloadRecord, url: URL?) {
        let resumeURL = DownloadFiles.resumeData(record.id)
        let task: URLSessionDownloadTask
        if let data = try? Data(contentsOf: resumeURL) {
            try? FileManager.default.removeItem(at: resumeURL)
            // The resume data carries the old request: the address it used (the home network one,
            // say, which can't be reached on mobile data) and whether it may use mobile data.
            let patched = ResumeData.updating(data, cellular: Self.allowsCellular, url: url)
            if patched == nil {
                AppLog.shared.log("Couldn't update a resumed download's address and mobile-data setting", level: .warning)
            }
            task = urlSession.downloadTask(withResumeData: patched ?? data)
        } else if let url {
            var request = URLRequest(url: url)
            request.allowsCellularAccess = Self.allowsCellular
            task = urlSession.downloadTask(with: request)
        } else {
            return
        }
        task.taskDescription = DownloadFiles.taskDescription(id: record.id, fileName: record.fileName)
        tasks[record.id] = task
        task.resume()
    }

    private func saveExtras(itemID: String, item: BaseItemDto, api: LibraryAPI) async {
        if let segments = try? await api.segments(itemID: itemID), records[itemID] != nil {
            records[itemID]?.segments = segments
            save()
        }
        let images: [(ImageRef?, Int, URL)] = [
            (Artwork.poster(item), 400, DownloadFiles.poster(itemID)),
            (Artwork.landscape(item), 600, DownloadFiles.still(itemID)),
        ]
        for (ref, width, destination) in images {
            guard let url = api.imageURL(ref, maxWidth: width),
                  let result = try? await URLSession.shared.data(from: url),
                  (result.1 as? HTTPURLResponse)?.statusCode == 200,
                  records[itemID] != nil else { continue }
            try? result.0.write(to: destination)
        }
        artworkRevision += 1
    }

    // MARK: - Events from the URL session

    /// Events from a task that was replaced (restarted, or deleted and downloaded again) are ignored.
    private func isCurrent(_ id: String, taskID: Int) -> Bool {
        guard let task = tasks[id] else { return true }
        return task.taskIdentifier == taskID
    }

    fileprivate func progress(id: String, taskID: Int, received: Int64, expected: Int64) {
        guard isCurrent(id, taskID: taskID), var record = records[id], record.state != .done, !pausing.contains(id) else { return }
        noteSpeed(id: id, received: received)
        record.receivedBytes = received
        if expected > 0 {
            record.totalBytes = expected
        }
        record.state = .downloading
        records[id] = record
    }

    fileprivate func finished(id: String, taskID: Int, error: String?) {
        guard isCurrent(id, taskID: taskID) else { return }
        tasks[id] = nil
        clearSpeed(id)
        guard var record = records[id] else { return }
        if let error {
            record.state = .failed
            record.errorMessage = error
            record.retryable = false
            AppLog.shared.log("Download failed: \(Self.title(record.item)): \(error)", level: .error)
        } else {
            let file = DownloadFiles.folder(id).appendingPathComponent(record.fileName)
            let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
            if let size = (attributes?[.size] as? NSNumber)?.int64Value {
                record.totalBytes = size
            }
            record.receivedBytes = record.totalBytes
            record.state = .done
            record.errorMessage = nil
            AppLog.shared.log("Download finished: \(Self.title(record.item)) (\(Self.format(record.totalBytes)))")
        }
        records[id] = record
        save()
    }

    fileprivate func failed(id: String, taskID: Int, error: Error, resumeData: Data?) {
        guard isCurrent(id, taskID: taskID) else { return }
        tasks[id] = nil
        clearSpeed(id)
        guard var record = records[id], record.state != .done else { return }
        if let resumeData {
            try? resumeData.write(to: DownloadFiles.resumeData(id))
        }
        if pausing.remove(id) != nil {
            record.state = .paused
        } else if (error as NSError).code == NSURLErrorCancelled {
            // Cancelled to restart with a new setting, or the record was deleted.
            return
        } else {
            let networkError = (error as NSError).domain == NSURLErrorDomain
            record.state = .failed
            record.errorMessage = networkError ? "Connection lost · tap to retry" : error.localizedDescription
            record.retryable = networkError
            AppLog.shared.log("Download stopped: \(Self.title(record.item)): \(error.localizedDescription)", level: .warning)
        }
        records[id] = record
        save()
    }

    fileprivate func backgroundEventsFinished() {
        backgroundCompletion?()
        backgroundCompletion = nil
    }

    /// After a relaunch: pick up the tasks iOS kept running, and mark the rest as stopped.
    private func reattach() async {
        let running = await urlSession.allTasks
        var found: Set<String> = []
        for task in running {
            guard let download = task as? URLSessionDownloadTask,
                  let parsed = DownloadFiles.parse(task.taskDescription) else { continue }
            if records[parsed.id] == nil {
                task.cancel()
                continue
            }
            tasks[parsed.id] = download
            found.insert(parsed.id)
        }
        for (id, record) in records where (record.state == .queued || record.state == .downloading) && !found.contains(id) {
            records[id]?.state = .failed
            records[id]?.errorMessage = "Stopped · tap to continue"
            records[id]?.retryable = true
        }
        save()
    }

    // MARK: - Progress on downloaded files

    /// Called by the player while a downloaded file plays. `synced` means the server is getting the
    /// same progress live; otherwise it's kept for later.
    func noteProgress(itemID: String, position: Double, duration: Double, synced: Bool, force: Bool = false) {
        guard var record = records[itemID], duration > 0 else { return }
        let now = Date()
        if !force, let last = lastProgressNote[itemID], now.timeIntervalSince(last) < 10 {
            return
        }
        lastProgressNote[itemID] = now
        record.position = position
        record.played = position >= duration * 0.9
        record.progressUpdatedAt = now
        if !synced {
            record.needsSync = true
        }
        records[itemID] = record
        save()
    }

    private func connectionReturned() {
        guard let store = sessionStore, store.isConnected else { return }
        Task { await syncProgress() }
        restartMovedDownloads()
        for record in records.values where record.state == .failed && record.retryable {
            resume(record.id)
        }
    }

    /// Sends progress made offline to the server, unless the server has newer progress (watched
    /// further on another device in the meantime).
    func syncProgress() async {
        guard !isSyncing, let store = sessionStore, let client = store.client, let userID = store.session?.userID else { return }
        isSyncing = true
        defer { isSyncing = false }
        let api = LibraryAPI(client: client, userID: userID)
        for record in records.values where record.needsSync && record.userID == userID {
            guard let position = record.position, let changed = record.progressUpdatedAt else { continue }
            do {
                let server = try await api.item(record.id)
                if let lastPlayed = server.userData?.lastPlayedDate, lastPlayed > changed {
                    AppLog.shared.log("Offline progress for \(Self.title(record.item)) skipped: the server has newer progress")
                } else {
                    try await Self.sendProgress(client: client, record: record, position: position)
                    AppLog.shared.log("Offline progress for \(Self.title(record.item)) sent: \(ItemDetailView.timeText(position))")
                }
                records[record.id]?.needsSync = false
                records[record.id]?.item.userData = (try? await api.item(record.id))?.userData ?? server.userData
                save()
            } catch {
                AppLog.shared.log("Couldn't send offline progress: \(error.localizedDescription)", level: .warning)
                return
            }
        }
    }

    private static func sendProgress(client: JellyfinClient, record: DownloadRecord, position: Double) async throws {
        let ticks = Int(max(position, 0) * 10_000_000)
        let playSessionID = UUID().uuidString
        var start = PlaybackStateInfo()
        start.itemID = record.id
        start.mediaSourceID = record.mediaSourceID
        start.playSessionID = playSessionID
        start.positionTicks = ticks
        start.isPaused = true
        start.canSeek = true
        start.playMethod = .directPlay
        try await client.send(Paths.reportPlaybackStart(start))
        var stop = PlaybackStopInfo()
        stop.itemID = record.id
        stop.mediaSourceID = record.mediaSourceID
        stop.playSessionID = playSessionID
        stop.positionTicks = ticks
        try await client.send(Paths.reportPlaybackStopped(stop))
    }

    // MARK: - Helpers

    private func noteSpeed(id: String, received: Int64) {
        let now = Date()
        guard let last = speedSamples[id], received >= last.bytes else {
            speedSamples[id] = (now, received)
            return
        }
        let elapsed = now.timeIntervalSince(last.time)
        guard elapsed >= 1 else { return }
        let current = Double(received - last.bytes) / elapsed
        speeds[id] = speeds[id].map { $0 * 0.7 + current * 0.3 } ?? current
        speedSamples[id] = (now, received)
    }

    private func clearSpeed(_ id: String) {
        speedSamples[id] = nil
        speeds[id] = nil
    }

    private func currentAPI(for record: DownloadRecord) -> LibraryAPI? {
        guard let store = sessionStore, let client = store.client, store.session?.userID == record.userID else { return nil }
        return LibraryAPI(client: client, userID: record.userID)
    }

    private func startPathMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            let wifi = path.status == .satisfied && (path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet))
            Task { @MainActor in
                DownloadStore.shared.isOnWiFi = wifi
            }
        }
        monitor.start(queue: DispatchQueue(label: "downloads.path"))
        pathMonitor = monitor
    }

    private static func fileExtension(for source: MediaSourceInfo) -> String {
        if let path = source.path {
            let ext = (path as NSString).pathExtension.lowercased()
            if !ext.isEmpty, ext.count <= 5 {
                return ext
            }
        }
        if let container = source.container?.split(separator: ",").first, !container.isEmpty {
            return String(container)
        }
        return "mkv"
    }

    static func title(_ item: BaseItemDto?) -> String {
        guard let item else { return "item" }
        return [item.seriesName, item.episodeLabel, item.name].compactMap { $0 }.joined(separator: " · ")
    }

    private func load() {
        guard let data = try? Data(contentsOf: DownloadFiles.index),
              let saved = try? JSONDecoder().decode([DownloadRecord].self, from: data) else { return }
        records = Dictionary(saved.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Writes the list soon, once, even when many changes arrive together.
    private func save() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            let list = Array(records.values)
            if let data = try? JSONEncoder().encode(list) {
                try? data.write(to: DownloadFiles.index, options: .atomic)
            }
        }
    }
}

/// Receives the background downloader's events (on its own thread) and passes them to the store.
private final class DownloadSessionDelegate: NSObject, URLSessionDownloadDelegate {
    private let lock = NSLock()
    private var lastProgress: [String: Date] = [:]

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let parsed = DownloadFiles.parse(downloadTask.taskDescription) else { return }
        let taskID = downloadTask.taskIdentifier
        let now = Date()
        lock.lock()
        let due = now.timeIntervalSince(lastProgress[parsed.id] ?? .distantPast) >= 0.5
        if due {
            lastProgress[parsed.id] = now
        }
        lock.unlock()
        guard due else { return }
        Task { @MainActor in
            DownloadStore.shared.progress(id: parsed.id, taskID: taskID, received: totalBytesWritten, expected: totalBytesExpectedToWrite)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let parsed = DownloadFiles.parse(downloadTask.taskDescription) else { return }
        let taskID = downloadTask.taskIdentifier
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let message = status == 401 || status == 403
                ? "The server refused the download (HTTP \(status))"
                : "The server answered HTTP \(status)"
            Task { @MainActor in
                DownloadStore.shared.finished(id: parsed.id, taskID: taskID, error: message)
            }
            return
        }
        // The temporary file is deleted when this method returns, so move it now.
        let folder = DownloadFiles.folder(parsed.id)
        let destination = folder.appendingPathComponent(parsed.fileName)
        var failure: String?
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            failure = "Couldn't save the file: \(error.localizedDescription)"
        }
        Task { @MainActor in
            DownloadStore.shared.finished(id: parsed.id, taskID: taskID, error: failure)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let parsed = DownloadFiles.parse(task.taskDescription) else { return }
        let taskID = task.taskIdentifier
        let resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        Task { @MainActor in
            DownloadStore.shared.failed(id: parsed.id, taskID: taskID, error: error, resumeData: resumeData)
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            DownloadStore.shared.backgroundEventsFinished()
        }
    }
}

/// Edits iOS's resume data. It holds the original request archived inside it; that request decides
/// whether the continued download may use mobile data.
enum ResumeData {
    private static let requestKeys = ["NSURLSessionResumeCurrentRequest", "NSURLSessionResumeOriginalRequest"]
    private static let urlKey = "NSURLSessionDownloadURL"

    /// Sets whether the continued download may use mobile data, and points it at the server address
    /// in use now (when given), so a download started at home can continue elsewhere.
    static func updating(_ data: Data, cellular allowed: Bool, url: URL?) -> Data? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        // Newer iOS versions wrap the whole dictionary in a keyed archive.
        let isArchive = plist["$archiver"] != nil
        let dictionary: [String: Any]
        if isArchive {
            guard let unarchived = unarchive(data) as? [String: Any] else { return nil }
            dictionary = unarchived
        } else {
            dictionary = plist
        }
        var changed = dictionary
        var found = false
        func update(_ copy: NSMutableURLRequest) {
            copy.allowsCellularAccess = allowed
            if let url {
                copy.url = url
            }
        }
        for key in requestKeys {
            if let archived = dictionary[key] as? Data,
               let request = unarchive(archived) as? NSURLRequest,
               let copy = request.mutableCopy() as? NSMutableURLRequest {
                update(copy)
                guard let encoded = try? NSKeyedArchiver.archivedData(withRootObject: copy, requiringSecureCoding: false) else { return nil }
                changed[key] = encoded
                found = true
            } else if let request = dictionary[key] as? NSURLRequest,
                      let copy = request.mutableCopy() as? NSMutableURLRequest {
                update(copy)
                changed[key] = copy
                found = true
            }
        }
        if let url, dictionary[urlKey] != nil {
            changed[urlKey] = url.absoluteString
        }
        guard found else { return nil }
        if isArchive {
            return try? NSKeyedArchiver.archivedData(withRootObject: changed as NSDictionary, requiringSecureCoding: false)
        }
        return try? PropertyListSerialization.data(fromPropertyList: changed, format: .binary, options: 0)
    }

    private static func unarchive(_ data: Data) -> Any? {
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        unarchiver.requiresSecureCoding = false
        defer { unarchiver.finishDecoding() }
        return unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey)
    }
}
