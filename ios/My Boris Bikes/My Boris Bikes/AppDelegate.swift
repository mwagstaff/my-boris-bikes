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
        BackgroundRefreshService.shared.prewarmAllBikePointsIfStale(force: true)

        // Request notification authorization and register for remote notifications.
        // We need the device token even if the user declines visible notifications,
        // because we use silent (content-available) pushes for complication refresh.
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
            if let error = error {
                self.logger.error("Notification authorization error: \(error.localizedDescription)")
            }
            self.logger.info("Notification authorization granted: \(granted)")
        }
        application.registerForRemoteNotifications()

        return true
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        BackgroundRefreshService.shared.prewarmAllBikePointsIfStale()
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        BackgroundRefreshService.shared.scheduleAppRefresh()
    }

    // MARK: - Device token registration

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let tokenString = deviceToken.map { String(format: "%02x", $0) }.joined()
        logger.info("Registered for remote notifications: \(tokenString.prefix(16))...")
        DeviceTokenHelper.setApnsDeviceToken(tokenString)

        // Register the token with our server so it can send periodic silent background
        // pushes that wake this app to refresh complication data for the watch face.
        Task {
            await registerComplicationToken(tokenString)
            await LiveActivityService.shared.refreshNotificationStatusFromServer()
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        logger.error("Failed to register for remote notifications: \(error.localizedDescription)")
    }

    // MARK: - Silent background push handler

    /// Called by APNs when the server sends a content-available:1 push.
    /// Fetches fresh dock data, updates widgets, and signals the watch.
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        // Only handle silent pushes (visible notifications have no content-available)
        guard let aps = userInfo["aps"] as? [String: Any],
              aps["content-available"] as? Int == 1 else {
            completionHandler(.noData)
            return
        }

        logger.info("Silent background push received — refreshing complication data")

        Task {
            let success = await BackgroundRefreshService.shared.performComplicationRefresh()
            completionHandler(success ? .newData : .failed)
        }
    }

    // MARK: - Helpers

    private func registerComplicationToken(_ token: String) async {
        guard let url = URL(string: AppConstants.Server.baseURL + AppConstants.Server.complicationRegisterEndpoint) else {
            logger.error("Invalid complication register URL")
            return
        }

        #if DEBUG
        let buildType = "development"
        #else
        let buildType = "production"
        #endif

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10

        let body: [String: Any] = ["deviceToken": token, "buildType": buildType]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return }
        request.httpBody = bodyData

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse {
                logger.info("Complication token registered with server (HTTP \(http.statusCode))")
            }
        } catch {
            logger.error("Failed to register complication token: \(error.localizedDescription)")
        }
    }
}
