import UIKit

/// The marker resource this build of the host carries.
public func hostMarker() -> String {
    guard let url = Bundle.main.url(forResource: "marker", withExtension: "txt"),
          let marker = try? String(contentsOf: url, encoding: .utf8) else {
        return "<no marker>"
    }
    return marker
}

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
        label.text = hostMarker()
        label.accessibilityIdentifier = "marker"
        label.textAlignment = .center
        viewController.view.addSubview(label)
        window.rootViewController = viewController
        window.makeKeyAndVisible()
        self.window = window
        return true
    }
}
