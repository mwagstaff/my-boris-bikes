import SwiftUI
import CoreLocation

struct WatchDistanceIndicator: View {
    let distance: CLLocationDistance?
    let distanceString: String
    
    private var distanceCategory: WatchDistanceCategory {
        guard let distance = distance else { return .unknown }
        
        switch distance {
        case 0..<500:
            return .veryClose
        case 500..<1000:
            return .close
        case 1000..<1500:
            return .moderate
        case 1500..<3000:
            return .far
        default:
            return .veryFar
        }
    }
    
    var body: some View {
        HStack(spacing: 3) {
            // Compact visual distance indicator for watch
            HStack(spacing: 1) {
                ForEach(0..<3, id: \.self) { index in
                    Rectangle()
                        .fill(index < distanceCategory.barCount ? distanceCategory.color : Color.gray.opacity(0.3))
                        .frame(width: 2, height: index < distanceCategory.barCount ? 8 - CGFloat(index) : 4)
                        .clipShape(Capsule())
                }
            }
            
            Text(distanceString)
                .font(.caption2)
                .foregroundColor(distanceCategory.color)
                .fontWeight(.medium)
        }
    }
}

private enum WatchDistanceCategory {
    case veryClose
    case close
    case moderate
    case far
    case veryFar
    case unknown
    
    var barCount: Int {
        switch self {
        case .veryClose: return 3
        case .close: return 2
        case .moderate: return 2
        case .far: return 1
        case .veryFar: return 1
        case .unknown: return 0
        }
    }
    
    var color: Color {
        switch self {
        case .veryClose: return .green
        case .close: return .mint
        case .moderate: return .orange
        case .far: return .red
        case .veryFar: return .purple
        case .unknown: return .gray
        }
    }
}