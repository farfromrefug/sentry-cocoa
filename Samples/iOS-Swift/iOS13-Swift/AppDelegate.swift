import Sentry
import UIKit

@main
class AppDelegate: UIResponder, UIApplicationDelegate {

    static let defaultDSN = "https://a92d50327ac74b8b9aa4ea80eccfb267@o447951.ingest.sentry.io/5428557"

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
                   
            // For testing purposes, we want to be able to change the DSN and store it to disk. In a real app, you shouldn't need this behavior.
            let dsn = DSNStorage.shared.getDSN() ?? AppDelegate.defaultDSN
            DSNStorage.shared.saveDSN(dsn: dsn)
            
            SentrySDK.start { options in
                options.dsn = dsn
                options.beforeSend = { event in
                    return event
                }
                options.debug = true
                // Sampling 100% - In Production you probably want to adjust this
                options.tracesSampleRate = 1.0
                options.sessionTrackingIntervalMillis = 5_000
                if ProcessInfo.processInfo.arguments.contains("--io.sentry.profiling.enable") {
                    options.profilesSampleRate = 1
                }
            }
        
        return true
    }

    // MARK: UISceneSession Lifecycle

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        // Called when a new scene session is being created.
        // Use this method to select a configuration to create the new scene with.
        return UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }

    func application(_ application: UIApplication, didDiscardSceneSessions sceneSessions: Set<UISceneSession>) {
        // Called when the user discards a scene session.
        // If any sessions were discarded while the application was not running, this will be called shortly after application:didFinishLaunchingWithOptions.
        // Use this method to release any resources that were specific to the discarded scenes, as they will not return.
    }

}
