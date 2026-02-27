import Foundation
import CoreLocation
import Combine
import OSLog

class LocationService: NSObject, ObservableObject {
    static let shared = LocationService()
    
    @Published var location: CLLocation?
    @Published var heading: CLLocationDirection?
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published var error: String?
    
    private let locationManager = CLLocationManager()
    private let logger = Logger(subsystem: "com.myborisbikes.app", category: "LocationService")
    
    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = 10
        locationManager.headingFilter = 5
        
        // Initialize with current authorization status
        authorizationStatus = locationManager.authorizationStatus
        logger.info("LocationService initialized with authorization status: \(self.authorizationStatus.rawValue)")
    }
    
    func requestLocationPermission() {
        logger.info("Requesting location permission, current status: \(self.authorizationStatus.rawValue)")
        switch authorizationStatus {
        case .notDetermined:
            logger.info("Authorization not determined, requesting when-in-use authorization")
            locationManager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            logger.warning("Location access denied or restricted")
            error = "Location access is required to sort favorites by distance. Please enable location access in Settings."
        default:
            logger.info("Location permission already granted or other status: \(self.authorizationStatus.rawValue)")
            break
        }
    }
    
    func startLocationUpdates() {
        logger.info("Starting location updates, authorization status: \(self.authorizationStatus.rawValue)")
        guard authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways else {
            logger.warning("Cannot start location updates - insufficient authorization")
            requestLocationPermission()
            return
        }
        
        logger.info("Starting CLLocationManager location updates")
        locationManager.startUpdatingLocation()
    }

    func startHeadingUpdates() {
        guard CLLocationManager.headingAvailable() else {
            logger.info("Heading updates unavailable on this device")
            return
        }

        guard authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways else {
            logger.warning("Cannot start heading updates - insufficient authorization")
            return
        }

        logger.info("Starting CLLocationManager heading updates")
        locationManager.startUpdatingHeading()
    }
    
    func stopLocationUpdates() {
        logger.info("Stopping location updates")
        locationManager.stopUpdatingLocation()
    }

    func stopHeadingUpdates() {
        logger.info("Stopping heading updates")
        locationManager.stopUpdatingHeading()
        heading = nil
    }
    
    func distance(to coordinate: CLLocationCoordinate2D) -> CLLocationDistance? {
        guard let location = location else { return nil }
        let targetLocation = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return location.distance(from: targetLocation)
    }
    
    func distanceString(to coordinate: CLLocationCoordinate2D) -> String {
        guard let distance = distance(to: coordinate) else { return "Unknown" }
        
        if distance < 1000 {
            return String(format: "%.0fm", distance)
        } else {
            // Convert to miles and format to one decimal place
            let distanceInMiles = distance * 0.000621371 // Convert meters to miles
            // Display "mile" if distance is exactly 1 mile, "miles" otherwise
            if distanceInMiles == 1.0 {
                return String(format: "%.1f mile", distanceInMiles)
            } else {
                return String(format: "%.1f miles", distanceInMiles)
            }
        }
    }
}

extension LocationService: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let newLocation = locations.last else {
            logger.warning("Received location update with no locations")
            return
        }
        
        logger.info("Received location update: lat=\(newLocation.coordinate.latitude), lon=\(newLocation.coordinate.longitude), accuracy=\(newLocation.horizontalAccuracy)m")
        location = newLocation
        error = nil

        // Fallback for devices where compass heading is unavailable.
        if !CLLocationManager.headingAvailable(), newLocation.course >= 0 {
            heading = newLocation.course
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        let resolvedHeading: CLLocationDirection?

        if newHeading.trueHeading >= 0 {
            resolvedHeading = newHeading.trueHeading
        } else if newHeading.magneticHeading >= 0 {
            resolvedHeading = newHeading.magneticHeading
        } else {
            resolvedHeading = nil
        }

        heading = resolvedHeading
    }
    
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        logger.error("Location manager failed with error: \(error.localizedDescription)")
        self.error = error.localizedDescription
    }
    
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let previousStatus = authorizationStatus
        authorizationStatus = manager.authorizationStatus
        logger.info("Authorization changed from \(previousStatus.rawValue) to \(self.authorizationStatus.rawValue)")
        
        switch authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            logger.info("Location authorized, clearing error and starting updates")
            error = nil
            startLocationUpdates()
            startHeadingUpdates()
        case .denied, .restricted:
            logger.warning("Location access denied or restricted, stopping updates")
            error = "Location access denied. Distance sorting will not be available."
            stopLocationUpdates()
            stopHeadingUpdates()
        case .notDetermined:
            logger.info("Location authorization not determined")
        @unknown default:
            logger.warning("Unknown authorization status: \(self.authorizationStatus.rawValue)")
            break
        }
    }
}
