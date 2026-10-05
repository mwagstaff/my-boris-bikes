import Foundation
import CryptoKit
import ImageIO

/// Owns networking, validation and discardable files away from the UI actor.
actor LondonBackgroundCache {
    private struct SavedCatalog: Codable {
        let checkedAt: Date
        let catalog: LondonBackgroundCatalog
    }

    private let directory: URL
    private let session: URLSession
    private var lastAttempt: [URL: Date] = [:]
    private let refreshInterval: TimeInterval = 6 * 60 * 60
    private let retryInterval: TimeInterval = 5 * 60
    private let maximumCacheBytes = 50 * 1024 * 1024

    init(directory: URL? = nil, session: URLSession? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LondonBackgrounds", isDirectory: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        self.session = session ?? URLSession(configuration: configuration)
    }

    func cachedCatalog(from baseURL: URL) -> LondonBackgroundCatalog? {
        savedCatalog(from: baseURL)?.catalog
    }

    func refreshCatalog(from baseURL: URL, now: Date = Date()) async throws {
        if let saved = savedCatalog(from: baseURL),
           (0..<refreshInterval).contains(now.timeIntervalSince(saved.checkedAt)) { return }
        if let attempted = lastAttempt[baseURL],
           (0..<retryInterval).contains(now.timeIntervalSince(attempted)) { return }
        try await fetchCatalog(from: baseURL, now: now)
    }

    private func fetchCatalog(from baseURL: URL, now: Date) async throws {
        lastAttempt[baseURL] = now
        do {
            let data = try await download(baseURL.appendingPathComponent("backgrounds"),
                                          maximumBytes: LondonBackgroundCatalog.maximumCatalogBytes)
            let catalog = try JSONDecoder().decode(LondonBackgroundCatalog.self, from: data).validated()
            try Task.checkCancellation()
            let folder = folder(for: baseURL)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let saved = SavedCatalog(checkedAt: now, catalog: catalog)
            try JSONEncoder().encode(saved).write(to: folder.appendingPathComponent("catalog.json"), options: .atomic)
        } catch {
            if Task.isCancelled {
                lastAttempt[baseURL] = nil
                throw CancellationError()
            }
            // The last validated catalogue remains usable after network or server errors.
            throw error
        }
    }

    func image(for entry: LondonBackgroundCatalog.Entry, from baseURL: URL, downloadIfMissing: Bool) async throws -> CGImage? {
        _ = try LondonBackgroundCatalog(schemaVersion: 1, images: [entry]).validated()
        try Task.checkCancellation()
        let folder = folder(for: baseURL)
        let file = folder.appendingPathComponent(entry.file)
        if FileManager.default.fileExists(atPath: file.path) {
            if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
               size == entry.byteCount,
               let data = try? Data(contentsOf: file),
               let image = try? decode(data, entry: entry) {
                try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
#if DEBUG
                debugLastImageSource = "Disk cache"
#endif
                return image
            }
            try? FileManager.default.removeItem(at: file)
        }
        guard downloadIfMissing else { return nil }
        return try await downloadImage(for: entry, from: baseURL)
    }

    private func downloadImage(for entry: LondonBackgroundCatalog.Entry, from baseURL: URL) async throws -> CGImage {
        let folder = folder(for: baseURL)
        let file = folder.appendingPathComponent(entry.file)
        let url = baseURL.appendingPathComponent("backgrounds/images").appendingPathComponent(entry.file)
        let data = try await download(url, maximumBytes: entry.byteCount)
        let image = try decode(data, entry: entry)
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
        prune(folder: folder, keeping: file)
#if DEBUG
        debugLastImageSource = "Downloaded"
#endif
        return image
    }

#if DEBUG
    struct DebugSnapshot {
        var catalog: LondonBackgroundCatalog?
        var checkedAt: Date?
        var imageCount = 0
        var byteCount = 0
    }

    private(set) var debugLastImageSource = "Unknown"

    func debugSnapshot(from baseURL: URL) -> DebugSnapshot {
        let saved = savedCatalog(from: baseURL)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder(for: baseURL),
            includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let sizes = files.filter { ["jpg", "png"].contains($0.pathExtension) }.compactMap {
            try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize
        }
        return DebugSnapshot(catalog: saved?.catalog, checkedAt: saved?.checkedAt,
                             imageCount: sizes.count, byteCount: sizes.reduce(0, +))
    }

    func debugRefreshCatalog(from baseURL: URL) async throws {
        try await fetchCatalog(from: baseURL, now: Date())
    }

    func debugDownloadImage(for entry: LondonBackgroundCatalog.Entry, from baseURL: URL) async throws -> CGImage {
        _ = try LondonBackgroundCatalog(schemaVersion: 1, images: [entry]).validated()
        try Task.checkCancellation()
        // Bypass the bundle and disk cache, but keep any good cached copy if the download fails.
        return try await downloadImage(for: entry, from: baseURL)
    }

    func debugClearCache(from baseURL: URL) throws {
        let folder = folder(for: baseURL)
        if FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.removeItem(at: folder)
        }
        lastAttempt[baseURL] = nil
    }
#endif

    private func savedCatalog(from baseURL: URL) -> SavedCatalog? {
        let file = folder(for: baseURL).appendingPathComponent("catalog.json")
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= LondonBackgroundCatalog.maximumCatalogBytes,
              let data = try? Data(contentsOf: file),
              let saved = try? JSONDecoder().decode(SavedCatalog.self, from: data),
              (try? saved.catalog.validated()) != nil else { return nil }
        return saved
    }

    private func folder(for baseURL: URL) -> URL {
        // Development and production catalogues never share cached files.
        directory.appendingPathComponent(hash(Data(baseURL.absoluteString.utf8)), isDirectory: true)
    }

    private func download(_ url: URL, maximumBytes: Int) async throws -> Data {
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        let (temporary, response) = try await session.download(for: request,
            delegate: BackgroundDownloadLimit(maximumBytes: maximumBytes))
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.url == url,
              let size = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0, size <= maximumBytes else { throw BackgroundImageError.invalidResponse }
        return try Data(contentsOf: temporary)
    }

    private func decode(_ data: Data, entry: LondonBackgroundCatalog.Entry) throws -> CGImage {
        guard data.count == entry.byteCount, hash(data) == entry.sha256,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (1...4096).contains(width), (1...4096).contains(height),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2048,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary)
        else { throw BackgroundImageError.invalidImage }
        return image
    }

    private func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func prune(folder: URL, keeping currentFile: URL) {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
        let entries = files.filter { ["jpg", "png"].contains($0.pathExtension) }.compactMap { url -> (URL, Int, Date)? in
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let size = values.fileSize else { return nil }
            return (url, size, values.contentModificationDate ?? .distantPast)
        }.sorted { $0.2 < $1.2 }
        var total = entries.reduce(0) { $0 + $1.1 }
        for (url, size, _) in entries where total > maximumCacheBytes && url != currentFile {
            if (try? FileManager.default.removeItem(at: url)) != nil { total -= size }
        }
    }
}

private final class BackgroundDownloadLimit: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let maximumBytes: Int64

    init(maximumBytes: Int) {
        self.maximumBytes = Int64(maximumBytes)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > maximumBytes || totalBytesExpectedToWrite > maximumBytes {
            downloadTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {}
}
