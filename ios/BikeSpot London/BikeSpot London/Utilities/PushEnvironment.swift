import Foundation

enum PushEnvironment {
    /// Maps the code-signing APNs entitlement to the server's expected build type label.
    static var buildType: String {
        apnsEnvironment == "production" ? "production" : "development"
    }

    static var apnsEnvironment: String {
        if let environment = provisioningEntitlementValue(for: "aps-environment"),
           environment == "development" || environment == "production" {
            return environment
        }

        #if DEBUG
        return "development"
        #else
        return "production"
        #endif
    }

    private static func provisioningEntitlementValue(for entitlement: String) -> String? {
        guard let profileURL = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let profileData = try? Data(contentsOf: profileURL),
              let profile = String(data: profileData, encoding: .ascii),
              let plistStart = profile.range(of: "<plist"),
              let plistEnd = profile.range(of: "</plist>")
        else {
            return nil
        }

        let plistString = String(profile[plistStart.lowerBound..<plistEnd.upperBound])
        guard let plistData = plistString.data(using: .utf8),
              let plistObject = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil),
              let plistDict = plistObject as? [String: Any],
              let entitlements = plistDict["Entitlements"] as? [String: Any]
        else {
            return nil
        }

        return entitlements[entitlement] as? String
    }
}
