import SwiftUI
import CoreLocation

struct LocationPermissionBanner: View {
    let locationService: LocationService
    let onRequestPermission: () -> Void
    
    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "location.slash")
                    .foregroundColor(.orange)
                    .font(.title2)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("Location Access Required")
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    Text(locationMessage)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.leading)
                }
                
                Spacer()
            }
            
            HStack {
                Spacer()
                
                Button(action: onRequestPermission) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.clockwise")
                        Text(buttonText)
                    }
                    .font(.subheadline)
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.accentColor)
                    .cornerRadius(8)
                }
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.1), radius: 8, x: 0, y: 2)
        .padding(.horizontal)
    }
    
    private var locationMessage: String {
        switch locationService.authorizationStatus {
        case .notDetermined:
            return "Enable location access to sort favorites by distance and center the map on your location."
        case .denied, .restricted:
            return "Location access is disabled. Enable it in Settings to sort favorites by distance."
        default:
            return "Unable to access your location. Tap to retry."
        }
    }
    
    private var buttonText: String {
        switch locationService.authorizationStatus {
        case .notDetermined:
            return "Enable Location"
        case .denied, .restricted:
            return "Open Settings"
        default:
            return "Retry"
        }
    }
}

#Preview {
    VStack {
        LocationPermissionBanner(
            locationService: LocationService.shared,
            onRequestPermission: {}
        )
        Spacer()
    }
    .background(Color.gray.opacity(0.1))
}