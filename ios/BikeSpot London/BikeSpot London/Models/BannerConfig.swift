import Foundation

struct BannerConfig: Codable, Equatable {
    let enabled: Bool
    let title: String
    let message: String
    let severity: BannerSeverity
    let updatedAt: String

    enum BannerSeverity: String, Codable {
        case info
        case warning
        case error
    }
}
