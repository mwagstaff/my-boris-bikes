import Foundation
import SwiftUI

@main
struct BackgroundDebugChecks {
    @MainActor
    static func main() async throws {
        let base = URL(string: CommandLine.arguments[1])!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "BackgroundDebugChecks-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
        }
        try await control("bundled", base: base)
        let (data, _) = try await URLSession.shared.data(from: base.appendingPathComponent("backgrounds"))
        let bundled = try JSONDecoder().decode(LondonBackgroundCatalog.self, from: data).validated()
        let cache = LondonBackgroundCache(directory: root)
        let service = LondonBackgroundService(cache: cache, bundled: bundled, defaults: defaults)

        // The debug refresh bypasses both the normal freshness window and failed-attempt delay.
        let before = try await stats(base: base)
        await service.debugPerform(.refreshCatalog, from: base)
        await service.debugPerform(.refreshCatalog, from: base)
        let refreshed = try await stats(base: base)
        assert(refreshed["catalogRequests"] == before["catalogRequests"]! + 2)
        assert(service.debugCache.catalog?.images == bundled.images)

        // The same rotation used by the app visits every image and wraps around without downloads.
        var visited = Set<String>()
        for _ in bundled.images {
            await service.debugPerform(.nextImage, from: base)
            visited.insert(service.debugDisplayedID)
            assert(service.debugImageSource == "Bundled")
        }
        assert(visited == Set(bundled.images.map(\.id)))
        await service.debugPerform(.nextImage, from: base)
        assert(service.debugDisplayedID == bundled.images[0].id)
        let rotated = try await stats(base: base)
        assert(rotated == refreshed)

        // Identical bundled bytes still download; repeating the command bypasses the disk copy too.
        await service.debugPerform(.downloadImage, from: base)
        await service.debugPerform(.downloadImage, from: base)
        let downloaded = try await stats(base: base)
        assert(downloaded["imageRequests"] == rotated["imageRequests"]! + 2)
        assert(service.debugImageSource == "Downloaded")
        assert(service.image?.width == 1536)
        assert(service.debugCache.imageCount == 1)
        assert(service.debugCache.byteCount == bundled.images[0].byteCount)

        try await control("offline", base: base)
        await service.debugPerform(.reloadCachedImage, from: base)
        let reloaded = try await stats(base: base)
        assert(reloaded == downloaded, "Disk-only reload must make no network requests")
        assert(service.debugImageSource == "Disk cache")
        let displayed = service.debugDisplayedID
        await service.debugPerform(.downloadImage, from: base)
        assert(service.debugStatus.hasPrefix("Failed:"))
        assert(service.debugDisplayedID == displayed && service.debugImageSource == "Disk cache")
        assert(service.debugCache.imageCount == 1, "A failed force-download must retain the good file")
        await service.debugPerform(.refreshCatalog, from: base)
        assert(service.debugStatus.hasPrefix("Failed:"))
        assert(service.debugCache.catalog?.images == bundled.images)

        // An immediate retry succeeds; server additions/replacements enter the actual rotation path.
        try await control("valid", base: base)
        await service.debugPerform(.refreshCatalog, from: base)
        await service.debugPerform(.nextImage, from: base)
        assert(service.debugDisplayedID == "remote-landmark" && service.debugImageSource == "Downloaded")
        await service.debugPerform(.nextImage, from: base)
        assert(service.debugImageSource == "Disk cache")
        let oldBytes = service.debugCache.byteCount
        try await control("updated", base: base)
        await service.debugPerform(.refreshCatalog, from: base)
        await service.debugPerform(.nextImage, from: base)
        assert(service.debugImageSource == "Downloaded" && service.debugCache.byteCount > oldBytes)

        // A cancelled request cannot replace the current display or cached collection.
        try await control("slow", base: base)
        let cancellation = Task { await service.debugPerform(.refreshCatalog, from: base) }
        try await Task.sleep(for: .milliseconds(100))
        service.debugCancel()
        await cancellation.value
        assert(service.debugStatus.hasPrefix("Cancelled."))
        assert(!service.debugIsBusy && service.debugDisplayedID == "remote-landmark")

        // Leaving for the background cancels a download. Clearing waits for it to finish cancelling.
        try await control("bundled", base: base)
        await service.debugPerform(.refreshCatalog, from: base)
        try await control("slow-image", base: base)
        let interrupted = Task { await service.debugPerform(.downloadImage, from: base) }
        try await Task.sleep(for: .milliseconds(100))
        service.handleScenePhase(.background, baseURL: base)
        await interrupted.value
        assert(service.debugStatus.hasPrefix("Cancelled."))
        assert(service.debugDisplayedID == "remote-landmark")

        // Clearing is scoped to this API origin and resets its freshness/retry state.
        let otherServer = base.appendingPathComponent("another-server")
        try await cache.debugClearCache(from: otherServer)
        await service.debugRefreshDiagnostics(from: base)
        assert(service.debugCache.imageCount > 0)
        await service.debugPerform(.clearCache, from: base)
        assert(service.debugCache.imageCount == 0 && service.debugCache.catalog == nil)
        assert(service.image == nil && service.debugImageSource == "Bundled")
        let clearedStats = try await stats(base: base)
        await service.debugPerform(.reloadCachedImage, from: base)
        let missingStats = try await stats(base: base)
        assert(missingStats == clearedStats && service.debugStatus.hasPrefix("No valid cached copy"))
        try await control("valid", base: base)
        try await cache.refreshCatalog(from: base)
        let afterClear = await cache.cachedCatalog(from: base)
        assert(afterClear != nil)

        print("Passed: debug force refresh/download, full rotation, disk-only offline reload, failure retention, cancellation and scoped cache reset.")
    }

    private static func control(_ mode: String, base: URL) async throws {
        _ = try await URLSession.shared.data(from: URL(string: "\(base.absoluteString)/control?mode=\(mode)")!)
    }

    private static func stats(base: URL) async throws -> [String: Int] {
        let (data, _) = try await URLSession.shared.data(from: base.appendingPathComponent("stats"))
        return try JSONDecoder().decode([String: Int].self, from: data)
    }
}
