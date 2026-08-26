import UIKit

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        // Repro hook: crash before the test bundle can connect, so idb's
        // client receives no test results at all. Only active when the
        // environment variable is set, so ordinary runs are unaffected.
        if ProcessInfo.processInfo.environment["IDB_REPRO_CRASH_ON_LAUNCH"] != nil {
            let pointer = UnsafeMutablePointer<Int>(bitPattern: 0x1)!
            pointer.pointee = 0xDEAD
        }

        let window = UIWindow(frame: UIScreen.main.bounds)
        let viewController = UIViewController()
        viewController.view.backgroundColor = .systemBackground
        let label = UILabel(frame: viewController.view.bounds)
        label.text = "rules_idb host app"
        label.textAlignment = .center
        viewController.view.addSubview(label)
        window.rootViewController = viewController
        window.makeKeyAndVisible()
        self.window = window
        return true
    }
}
