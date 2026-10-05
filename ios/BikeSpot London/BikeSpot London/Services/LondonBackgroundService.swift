import SwiftUI
import Observation
import OSLog

@MainActor
@Observable
final class LondonBackgroundService {
    static let shared = LondonBackgroundService()
    private(set) var image: CGImage?
    private(set) var bundledImageName = "LondonEyeHeader"

    @ObservationIgnored private let cache: LondonBackgroundCache
    @ObservationIgnored private let bundled: LondonBackgroundCatalog
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var rotation = LondonBackgroundRotation()
    @ObservationIgnored private var task: Task<Void, Never>?
    private static let selectionKey = "londonBackgroundImageID"
    private static let logger = Logger(subsystem: "BikeSpotLondon", category: "Backgrounds")

    init(cache: LondonBackgroundCache = LondonBackgroundCache(),
         bundled: LondonBackgroundCatalog = .bundled(), defaults: UserDefaults = .standard) {
        self.cache = cache
        self.bundled = bundled
        self.defaults = defaults
        bundledImageName = LondonBackgroundRotation.imageName(for: defaults.integer(forKey: LondonBackgroundRotation.selectionKey))
#if DEBUG
        debugDisplayedID = bundledImageName
        debugDisplayedEntry = bundled.images.first { $0.id == bundledImageName }
#endif
    }

    func handleScenePhase(_ phase: ScenePhase, baseURL: URL) {
        let shouldAdvance = rotation.shouldAdvance(for: phase)
        if phase == .background {
            task?.cancel()
        }
        guard shouldAdvance else { return }
        let previousTask = task
        previousTask?.cancel()
        task = Task {
            await previousTask?.value
            guard !Task.isCancelled else { return }
            await advanceAndRefresh(from: baseURL)
        }
    }

    private func advance(from baseURL: URL) async throws {
        let cached = await cache.cachedCatalog(from: baseURL)
        try Task.checkCancellation()
        let catalog = cached.flatMap { $0.images.isEmpty ? nil : $0 } ?? bundled
        let previousID = defaults.string(forKey: Self.selectionKey)
            ?? (defaults.object(forKey: LondonBackgroundRotation.selectionKey) == nil ? nil : bundledImageName)
        if let next = catalog.next(after: previousID) {
            defaults.set(next.id, forKey: Self.selectionKey)
            if bundled.images.contains(where: { $0.id == next.id && $0.sha256 == next.sha256 }),
               LondonBackgroundRotation.imageNames.contains(next.id) {
                image = nil
                bundledImageName = next.id
#if DEBUG
                debugDisplayedID = next.id
                debugDisplayedEntry = next
                debugImageSource = "Bundled"
#endif
            } else {
                // Keep the current image visible until the selected replacement is ready.
                let downloaded = try await cache.image(for: next, from: baseURL, downloadIfMissing: true)
                try Task.checkCancellation()
                image = downloaded
#if DEBUG
                debugDisplayedID = next.id
                debugDisplayedEntry = next
                debugImageSource = await cache.debugLastImageSource
#endif
            }
        }
    }

    private func advanceAndRefresh(from baseURL: URL) async {
        do {
            try await advance(from: baseURL)
        } catch {
            guard !Task.isCancelled else { return }
            Self.logger.debug("Keeping fallback background: \(String(describing: error), privacy: .public)")
        }
        guard !Task.isCancelled else { return }
        do {
            // A refreshed collection takes effect on the next visit, not halfway through this one.
            try await cache.refreshCatalog(from: baseURL)
        } catch {
            if !Task.isCancelled {
                Self.logger.debug("Keeping cached background catalogue: \(String(describing: error), privacy: .public)")
            }
        }
#if DEBUG
        await debugRefreshDiagnostics(from: baseURL)
#endif
    }

#if DEBUG
    enum DebugAction { case refreshCatalog, nextImage, downloadImage, reloadCachedImage, clearCache }

    private(set) var debugDisplayedID = "LondonEyeHeader"
    private(set) var debugImageSource = "Bundled"
    private(set) var debugCache = LondonBackgroundCache.DebugSnapshot()
    private(set) var debugStatus = "Refresh the catalogue to check the server's collection."
    private(set) var debugIsBusy = false
    @ObservationIgnored private var debugDisplayedEntry: LondonBackgroundCatalog.Entry?

    func debugRefreshDiagnostics(from baseURL: URL) async {
        debugCache = await cache.debugSnapshot(from: baseURL)
    }

    func debugCancel() {
        if debugIsBusy { task?.cancel() }
    }

    func debugPerform(_ action: DebugAction, from baseURL: URL) async {
        guard !debugIsBusy else { return }
        debugIsBusy = true
        debugStatus = "Running…"
        let previousTask = task
        previousTask?.cancel()
        let work = Task {
            // Wait for cancelled downloads before inspecting or clearing their files.
            await previousTask?.value
            do {
                try Task.checkCancellation()
                switch action {
                case .refreshCatalog:
                    try await cache.debugRefreshCatalog(from: baseURL)
                    debugStatus = "Server catalogue refreshed. Tap Next Image to use the updated collection."
                case .nextImage:
                    try await advance(from: baseURL)
                    debugStatus = "Showing \(debugDisplayedID) from \(debugImageSource.lowercased())."
                case .downloadImage:
                    guard let catalog = await cache.cachedCatalog(from: baseURL),
                          let entry = catalog.images.first(where: { $0.id == debugDisplayedID }) ?? catalog.images.first
                    else {
                        debugStatus = "Refresh the server catalogue first. It must contain at least one image."
                        break
                    }
                    let downloaded = try await cache.debugDownloadImage(for: entry, from: baseURL)
                    try Task.checkCancellation()
                    image = downloaded
                    debugDisplayedID = entry.id
                    debugDisplayedEntry = entry
                    debugImageSource = "Downloaded"
                    defaults.set(entry.id, forKey: Self.selectionKey)
                    debugStatus = "Downloaded \(entry.byteCount.formatted()) bytes. File size, SHA-256 and image decoding passed."
                case .reloadCachedImage:
                    guard let entry = debugDisplayedEntry,
                          let cached = try await cache.image(for: entry, from: baseURL, downloadIfMissing: false)
                    else {
                        debugStatus = "No valid cached copy of the displayed image. Use Download Image from Server first. No network request was made."
                        break
                    }
                    try Task.checkCancellation()
                    image = cached
                    debugImageSource = "Disk cache"
                    debugStatus = "Reloaded and validated the image from disk. No network request was made."
                case .clearCache:
                    try await cache.debugClearCache(from: baseURL)
                    try Task.checkCancellation()
                    image = nil
                    debugDisplayedID = bundledImageName
                    debugDisplayedEntry = bundled.images.first { $0.id == bundledImageName }
                    debugImageSource = "Bundled"
                    debugStatus = "Cleared this server's catalogue and downloaded images. Showing a bundled fallback."
                }
            } catch {
                let message: String
                switch error {
                case BackgroundImageError.invalidCatalog:
                    message = "The server catalogue is invalid or uses an unsupported format."
                case BackgroundImageError.invalidImage:
                    message = "The image failed its file size, SHA-256 or decoding checks."
                case BackgroundImageError.invalidResponse:
                    message = "The server returned an unsuccessful, redirected, empty or oversized response. Check the server URL and API deployment."
                default:
                    message = error.localizedDescription
                }
                debugStatus = Task.isCancelled ? "Cancelled. Keeping the current background." : "Failed: \(message) Keeping the current background."
            }
            await debugRefreshDiagnostics(from: baseURL)
            debugIsBusy = false
        }
        task = work
        await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
    }
#endif
}
