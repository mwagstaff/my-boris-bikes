import SwiftUI
import CoreLocation

struct DistanceIndicator: View {
    let distance: CLLocationDistance?
    let distanceString: String
    
    private var distanceCategory: DistanceCategory {
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
        HStack(spacing: 6) {
            // Visual distance indicator - horizontal bars
            HStack(spacing: 2) {
                ForEach(0..<5, id: \.self) { index in
                    Rectangle()
                        .fill(index < distanceCategory.barCount ? distanceCategory.color : Color.gray.opacity(0.3))
                        .frame(width: 4, height: index < distanceCategory.barCount ? 12 - CGFloat(index) * 2 : 8)
                        .clipShape(Capsule())
                }
            }
            
            // Distance text
            Text(distanceString)
                .font(.caption)
                .foregroundColor(distanceCategory.color)
                .fontWeight(.medium)
        }
    }
}

private enum DistanceCategory {
    case veryClose
    case close
    case moderate
    case far
    case veryFar
    case unknown
    
    var barCount: Int {
        switch self {
        case .veryClose: return 5
        case .close: return 4
        case .moderate: return 3
        case .far: return 2
        case .veryFar: return 1
        case .unknown: return 0
        }
    }
    
    var color: Color {
        switch self {
        case .veryClose: return .green
        case .close: return .mint
        case .moderate: return .orange
        case .far: return .purple
        case .veryFar: return .red
        case .unknown: return .gray
        }
    }
}

#Preview {
    VStack(spacing: 12) {
        DistanceIndicator(distance: 150, distanceString: "150m")
        DistanceIndicator(distance: 350, distanceString: "350m")
        DistanceIndicator(distance: 750, distanceString: "750m")
        DistanceIndicator(distance: 1500, distanceString: "1.5km")
        DistanceIndicator(distance: 3000, distanceString: "3.0km")
        DistanceIndicator(distance: nil, distanceString: "Unknown")
    }
    .padding()
}