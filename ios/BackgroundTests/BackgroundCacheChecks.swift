import Foundation

@main
struct BackgroundCacheChecks {
    static func main() async throws {
        let base = URL(string: CommandLine.arguments[1])!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = LondonBackgroundCache(directory: root)
        let start = Date()

        try await control("valid", base: base)
        let initiallyCached = await cache.cachedCatalog(from: base)
        assert(initiallyCached == nil)
        try await cache.refreshCatalog(from: base, now: start)
        let first = await cache.cachedCatalog(from: base)!
        let firstEntry = first.images[0]
        let beforeImage = try await stats(base: base)
        assert(beforeImage["imageRequests"] == 0, "A catalogue check must not download the collection")
        let firstImage = try await cache.image(for: firstEntry, from: base, downloadIfMissing: true)
        assert(firstImage?.width == 1536 && firstImage?.height == 1024)
        let afterDownload = try await stats(base: base)
        _ = try await cache.image(for: firstEntry, from: base, downloadIfMissing: true)
        try await cache.refreshCatalog(from: base, now: start.addingTimeInterval(60))
        let afterReuse = try await stats(base: base)
        assert(afterReuse == afterDownload, "Fresh catalogue and cached image must avoid network requests")

        // A new process can read and render the disk cache while the server is offline.
        try await control("offline", base: base)
        let relaunched = LondonBackgroundCache(directory: root)
        let restored = await relaunched.cachedCatalog(from: base)
        assert(restored?.images == first.images)
        let offlineImage = try await relaunched.image(for: firstEntry, from: base, downloadIfMissing: true)
        assert(offlineImage != nil)
        var failed = false
        do { try await relaunched.refreshCatalog(from: base, now: start.addingTimeInterval(7 * 3600)) }
        catch { failed = true }
        assert(failed)
        let retained = await relaunched.cachedCatalog(from: base)
        assert(retained?.images == first.images)

        // A replacement of the same ID downloads the new bytes, leaving the old version intact.
        try await control("updated", base: base)
        try await cache.refreshCatalog(from: base, now: start.addingTimeInterval(8 * 3600))
        let updated = await cache.cachedCatalog(from: base)!
        assert(updated.images[0].id == firstEntry.id)
        assert(updated.images[0].sha256 != firstEntry.sha256)
        _ = try await cache.image(for: updated.images[0], from: base, downloadIfMissing: true)
        let folder = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)[0]
        assert(FileManager.default.fileExists(atPath: folder.appendingPathComponent(firstEntry.file).path))
        assert(FileManager.default.fileExists(atPath: folder.appendingPathComponent(updated.images[0].file).path))

        // Corrupt local data is discarded and fetched again.
        try Data("corrupt".utf8).write(to: folder.appendingPathComponent(updated.images[0].file))
        let beforeRepair = try await stats(base: base)
        _ = try await cache.image(for: updated.images[0], from: base, downloadIfMissing: true)
        let afterRepair = try await stats(base: base)
        assert(afterRepair["imageRequests"] == beforeRepair["imageRequests"]! + 1)

        // Bad server bytes never enter the image cache.
        try await control("corrupt", base: base)
        let emptyRoot = root.appendingPathComponent("fresh-cache")
        let empty = LondonBackgroundCache(directory: emptyRoot)
        failed = false
        do { _ = try await empty.image(for: firstEntry, from: base, downloadIfMissing: true) }
        catch { failed = true }
        assert(failed)
        assert(!FileManager.default.fileExists(atPath: emptyRoot.path))

        try await control("oversized", base: base)
        failed = false
        do { _ = try await empty.image(for: firstEntry, from: base, downloadIfMissing: true) }
        catch { failed = true }
        assert(failed)
        assert(!FileManager.default.fileExists(atPath: emptyRoot.path))

        // Unsupported catalogues cannot replace the last valid version.
        try await control("invalid", base: base)
        failed = false
        do { try await cache.refreshCatalog(from: base, now: start.addingTimeInterval(15 * 3600)) }
        catch { failed = true }
        assert(failed)
        let afterInvalid = await cache.cachedCatalog(from: base)
        assert(afterInvalid?.images == updated.images)

        // Cancellation leaves the saved catalogue unchanged and does not mark it fresh.
        try await control("slow", base: base)
        let cancelled = Task { try await cache.refreshCatalog(from: base, now: start.addingTimeInterval(22 * 3600)) }
        try await Task.sleep(for: .milliseconds(100))
        cancelled.cancel()
        failed = false
        do { try await cancelled.value } catch { failed = true }
        assert(failed)
        let afterCancellation = await cache.cachedCatalog(from: base)
        assert(afterCancellation?.images == updated.images)

        // Paths cannot escape the cache or the server's image endpoint.
        let unsafe = LondonBackgroundCatalog.Entry(id: "../escape", file: "../escape.jpg", sha256: firstEntry.sha256, byteCount: 1)
        failed = false
        do { _ = try await cache.image(for: unsafe, from: base, downloadIfMissing: true) }
        catch { failed = true }
        assert(failed)

        // Old image files are removed when the cache exceeds its 50 MiB budget.
        try await control("valid", base: base)
        for index in 0..<11 {
            let old = folder.appendingPathComponent("old-\(index).jpg")
            try Data(repeating: 0, count: 5 * 1024 * 1024).write(to: old)
            try FileManager.default.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: old.path)
        }
        try FileManager.default.removeItem(at: folder.appendingPathComponent(firstEntry.file))
        _ = try await cache.image(for: firstEntry, from: base, downloadIfMissing: true)
        let total = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])
            .filter { $0.pathExtension == "jpg" }
            .reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        assert(total <= 50 * 1024 * 1024)
        assert(FileManager.default.fileExists(atPath: folder.appendingPathComponent(firstEntry.file).path))
        print("Passed: on-demand downloads, cache hits, offline restart, version replacement, corruption, cancellation, path validation and cache eviction.")
    }

    private static func control(_ mode: String, base: URL) async throws {
        _ = try await URLSession.shared.data(from: URL(string: "\(base.absoluteString)/control?mode=\(mode)")!)
    }

    private static func stats(base: URL) async throws -> [String: Int] {
        let (data, _) = try await URLSession.shared.data(from: base.appendingPathComponent("stats"))
        return try JSONDecoder().decode([String: Int].self, from: data)
    }
}
