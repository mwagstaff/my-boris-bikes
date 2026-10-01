import SwiftUI
import CoreLocation

struct DistanceIndicator: View {
    let distance: CLLocationDistance?
    let distanceString: String
    var reference = "your location"
    
    var body: some View {
        Label(distanceString, systemImage: distance == nil ? "location.slash" : "location")
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityLabel(distance == nil ? "Distance unavailable" : "\(distanceString) from \(reference)")
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