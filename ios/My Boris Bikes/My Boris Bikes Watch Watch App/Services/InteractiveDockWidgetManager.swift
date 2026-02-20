//
//  InteractiveDockWidgetManager.swift
//  My Boris Bikes Watch Watch App
//
//  Created by Mike Wagstaff on 11/08/2025.
//

import Foundation
import WidgetKit

// MARK: - Per-Widget Dock Configuration Manager
class InteractiveDockWidgetManager {
    static let shared = InteractiveDockWidgetManager()
    private let appGroup = "group.dev.skynolimit.myborisbikes"
    private let widgetConfigPrefix = "widget_dock_"
    private let pendingConfigurationKey = "pending_widget_configuration"
    
    private init() {}
    
    // Get the selected dock ID for a specific widget configuration
    func getSelectedDockId(for configurationId: String) -> String? {
        guard let userDefaults = UserDefaults(suiteName: appGroup) else {
            return nil
        }
        
        let key = widgetConfigPrefix + configurationId
        let selectedId = userDefaults.string(forKey: key)
        
        // Debug: Show all keys in UserDefaults for debugging
        let allKeys = userDefaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(widgetConfigPrefix) }
        
        return selectedId
    }
    
    // Set the selected dock ID for a specific widget configuration
    func setSelectedDockId(_ dockId: String, for configurationId: String) {
        guard let userDefaults = UserDefaults(suiteName: appGroup) else {
            return
        }
        
        let key = widgetConfigPrefix + configurationId
        
        userDefaults.set(dockId, forKey: key)
        let syncResult = userDefaults.synchronize()
        
        // Verify the value was saved
        let savedValue = userDefaults.string(forKey: key)
        
        
        // Debug: Show all current widget configurations
        let allConfigs = getAllConfigurations()
        
        // Clear any pending configuration
        clearPendingConfiguration()
        
        // Reload all interactive dock widgets
        reloadInteractiveDockWidgets()
    }
    
    // Clear the selected dock ID for a specific widget configuration
    func clearSelectedDockId(for configurationId: String) {
        guard let userDefaults = UserDefaults(suiteName: appGroup) else {
            return
        }
        
        let key = widgetConfigPrefix + configurationId
        userDefaults.removeObject(forKey: key)
        userDefaults.synchronize()
        
        
        // Reload all interactive dock widgets
        reloadInteractiveDockWidgets()
    }
    
    // Store which widget is currently being configured (used when user taps widget)
    func setPendingConfiguration(for configurationId: String) {
        guard let userDefaults = UserDefaults(suiteName: appGroup) else {
            return
        }
        
        userDefaults.set(configurationId, forKey: pendingConfigurationKey)
        userDefaults.synchronize()
        
    }
    
    // Get which widget is currently being configured
    func getPendingConfiguration() -> String? {
        guard let userDefaults = UserDefaults(suiteName: appGroup) else {
            return nil
        }
        
        let configurationId = userDefaults.string(forKey: pendingConfigurationKey)
        return configurationId
    }
    
    // Clear pending configuration
    func clearPendingConfiguration() {
        guard let userDefaults = UserDefaults(suiteName: appGroup) else {
            return
        }
        
        userDefaults.removeObject(forKey: pendingConfigurationKey)
        userDefaults.synchronize()
        
    }
    
    // Get all configured widget configurations (for debugging)
    func getAllConfigurations() -> [String: String] {
        guard let userDefaults = UserDefaults(suiteName: appGroup) else {
            return [:]
        }
        
        let allKeys = userDefaults.dictionaryRepresentation().keys
        let widgetKeys = allKeys.filter { $0.hasPrefix(widgetConfigPrefix) }
        
        var configurations: [String: String] = [:]
        for key in widgetKeys {
            let configId = String(key.dropFirst(widgetConfigPrefix.count))
            if let dockId = userDefaults.string(forKey: key) {
                configurations[configId] = dockId
            }
        }
        
        return configurations
    }
    
    private func reloadInteractiveDockWidgets() {
        WidgetCenter.shared.reloadTimelines(ofKind: "CustomDockWidget1")
        WidgetCenter.shared.reloadTimelines(ofKind: "CustomDockWidget2")
        WidgetCenter.shared.reloadTimelines(ofKind: "CustomDockWidget3")
        WidgetCenter.shared.reloadTimelines(ofKind: "CustomDockWidget4")
        WidgetCenter.shared.reloadTimelines(ofKind: "CustomDockWidget5")
        WidgetCenter.shared.reloadTimelines(ofKind: "CustomDockWidget6")
    }
}