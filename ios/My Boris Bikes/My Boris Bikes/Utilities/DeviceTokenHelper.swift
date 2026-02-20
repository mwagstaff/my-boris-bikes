//
//  DeviceTokenHelper.swift
//  My Boris Bikes
//
//  Helper to generate a consistent device token for tracking unique users
//

import Foundation
import UIKit

struct DeviceTokenHelper {
    /// Get a stable device identifier for tracking unique users
    /// Uses identifierForVendor which persists across app launches but resets on uninstall
    static var deviceToken: String? {
        return UIDevice.current.identifierForVendor?.uuidString
    }
}
