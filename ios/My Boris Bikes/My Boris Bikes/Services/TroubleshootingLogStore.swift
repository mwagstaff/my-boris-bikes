import Foundation

struct TroubleshootingLogEntry: Codable, Identifiable, Equatable {
    let id: UUID
    let timestamp: Date
    let category: String
    let event: String
    let message: String
    let metadata: [String: String]
}

@MainActor
final class TroubleshootingLogStore: ObservableObject {
    static let shared = TroubleshootingLogStore()

    @Published private(set) var entries: [TroubleshootingLogEntry]

    private let storageKey = "troubleshootingLogEntries"
    private let maxEntries = 300
    private let store = AppConstants.UserDefaults.sharedDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private init() {
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        if let data = store.data(forKey: storageKey),
           let decoded = try? decoder.decode([TroubleshootingLogEntry].self, from: data) {
            entries = decoded
        } else {
            entries = []
        }
    }

    func record(
        category: String,
        event: String,
        message: String,
        metadata: [String: Any?] = [:]
    ) {
        let cleanedMetadata = metadata.reduce(into: [String: String]()) { result, item in
            guard let value = item.value else { return }
            result[item.key] = String(describing: value)
        }

        let entry = TroubleshootingLogEntry(
            id: UUID(),
            timestamp: Date(),
            category: category,
            event: event,
            message: message,
            metadata: cleanedMetadata
        )
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
        persist()
    }

    func clear() {
        entries.removeAll()
        store.removeObject(forKey: storageKey)
    }

    func exportText() -> String {
        var lines = [
            "My Boris Bikes troubleshooting log",
            "Generated: \(Self.displayFormatter.string(from: Date()))",
            "Device ID: \(DeviceTokenHelper.scheduledJourneyDeviceId)",
            "APNs token prefix: \(DeviceTokenHelper.apnsDeviceToken.map { String($0.prefix(8)) } ?? "none")",
            "Server: \(AppConstants.Server.baseURL)",
            "Entry count: \(entries.count)",
            "",
        ]

        for entry in entries.sorted(by: { $0.timestamp < $1.timestamp }) {
            lines.append("[\(Self.displayFormatter.string(from: entry.timestamp))] \(entry.category).\(entry.event)")
            lines.append(entry.message)
            if !entry.metadata.isEmpty {
                let metadata = entry.metadata
                    .sorted { $0.key < $1.key }
                    .map { "\($0.key)=\($0.value)" }
                    .joined(separator: ", ")
                lines.append(metadata)
            }
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    func exportFileURL() throws -> URL {
        let fileName = "my-boris-bikes-troubleshooting-\(Self.fileDateFormatter.string(from: Date())).txt"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        try exportText().write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func persist() {
        guard let data = try? encoder.encode(entries) else { return }
        store.set(data, forKey: storageKey)
    }

    private static let displayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()

    private static let fileDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter
    }()
}
