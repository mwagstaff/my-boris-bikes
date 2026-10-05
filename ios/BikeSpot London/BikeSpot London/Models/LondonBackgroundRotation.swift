import SwiftUI

struct LondonBackgroundRotation {
    static let selectionKey = "londonBackgroundImageIndex"
    static let imageNames = [
        "LondonEyeHeader",
        "BigBenHeader",
        "GherkinHeader",
        "TowerBridgeHeader",
        "StPaulsHeader",
        "ShardHeader",
        "BatterseaHeader",
        "GreenwichHeader",
        "RoyalAlbertHallHeader",
        "StPancrasHeader",
        "TrafalgarSquareHeader",
        "TowerOfLondonHeader"
    ]

    private var needsNextImage = true

    static func imageName(for index: Int) -> String {
        imageNames[imageNames.indices.contains(index) ? index : 0]
    }

    /// Advance once per visit, not after temporary interruptions such as Control Centre.
    mutating func shouldAdvance(for phase: ScenePhase) -> Bool {
        switch phase {
        case .background:
            needsNextImage = true
        case .active where needsNextImage:
            needsNextImage = false
            return true
        default:
            break
        }
        return false
    }
}
