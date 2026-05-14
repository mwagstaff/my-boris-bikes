//
//  DeviceTokenHelper.swift
//  My Boris Bikes
//
//  Helper to generate a consistent device token for tracking unique users
//

import Foundation
import UIKit

struct DeviceTokenHelper {
    private static let apnsTokenStorageKey = "apns_device_token"
    private static let scheduledJourneyDeviceIdStorageKey = "scheduled_journey_device_id"

    /// APNs device token used by the server to send direct alert/background pushes.
    static var apnsDeviceToken: String? {
        let value = UserDefaults.standard.string(forKey: apnsTokenStorageKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    static func setApnsDeviceToken(_ token: String) {
        let normalized = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        UserDefaults.standard.set(normalized, forKey: apnsTokenStorageKey)
    }

    /// Stable identifier for analytics/user counting; not valid for APNs sends.
    static var analyticsDeviceToken: String? {
        UIDevice.current.identifierForVendor?.uuidString
    }

    static var scheduledJourneyDeviceId: String {
        if let existing = UserDefaults.standard.string(forKey: scheduledJourneyDeviceIdStorageKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !existing.isEmpty {
            return existing
        }

        let generated = UUID().uuidString
        UserDefaults.standard.set(generated, forKey: scheduledJourneyDeviceIdStorageKey)
        return generated
    }

    /// Backwards-compatible alias used by existing analytics call sites.
    static var deviceToken: String? {
        analyticsDeviceToken
    }
}
