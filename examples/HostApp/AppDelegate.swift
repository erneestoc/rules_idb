import UIKit

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
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
