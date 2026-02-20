import UIKit
import UserNotifications
import os.log

class AppDelegate: NSObject, UIApplicationDelegate {
    private let logger = Logger(subsystem: "dev.skynolimit.myborisbikes", category: "AppDelegate")

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        BackgroundRefreshService.shared.register()
        BackgroundRefreshService.shared.scheduleAppRefresh()

        // Request notification authorization and register for remote notifications
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
            if let error = error {
                self.logger.error("Notification authorization error: \(error.localizedDescription)")
            }
            self.logger.info("Notification authorization granted: \(granted)")
        }
        application.registerForRemoteNotifications()

        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        BackgroundRefreshService.shared.scheduleAppRefresh()
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let tokenString = deviceToken.map { String(format: "%02x", $0) }.joined()
        logger.info("Registered for remote notifications: \(tokenString.prefix(16))...")
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        logger.error("Failed to register for remote notifications: \(error.localizedDescription)")
    }
}
