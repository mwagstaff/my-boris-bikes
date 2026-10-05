import Foundation

struct LondonBackgroundCatalog: Codable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        let id: String
        let file: String
        let sha256: String
        let byteCount: Int
    }

    static let maximumImageBytes = 5 * 1024 * 1024
    static let maximumCatalogBytes = 128 * 1024
    let schemaVersion: Int
    let images: [Entry]

    func validated() throws -> Self {
        guard schemaVersion == 1, images.count <= 100 else { throw BackgroundImageError.invalidCatalog }
        var ids = Set<String>()
        for image in images {
            guard image.id.range(of: "^[A-Za-z0-9_-]{1,80}$", options: .regularExpression) != nil,
                  ids.insert(image.id).inserted,
                  image.sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
                  ["\(image.id)-\(image.sha256).jpg", "\(image.id)-\(image.sha256).png"].contains(image.file),
                  (1...Self.maximumImageBytes).contains(image.byteCount) else {
                throw BackgroundImageError.invalidCatalog
            }
        }
        return self
    }

    func next(after id: String?) -> Entry? {
        guard !images.isEmpty else { return nil }
        guard let index = images.firstIndex(where: { $0.id == id }) else { return images[0] }
        return images[(index + 1) % images.count]
    }

    static func bundled() -> Self {
        if let url = Bundle.main.url(forResource: "LondonBackgrounds", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let catalog = try? JSONDecoder().decode(Self.self, from: data).validated() {
            return catalog
        }
        // Standalone previews may not include the app's resource bundle.
        return Self(schemaVersion: 1, images: [])
    }
}

enum BackgroundImageError: Error {
    case invalidCatalog
    case invalidImage
    case invalidResponse
}
