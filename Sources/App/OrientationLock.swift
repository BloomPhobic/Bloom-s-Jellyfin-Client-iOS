import UIKit

/// The orientations the app allows right now. The player locks to landscape while it's open.
@MainActor
enum OrientationLock {
    static var mask: UIInterfaceOrientationMask = .allButUpsideDown

    static var isLandscape: Bool {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.interfaceOrientation.isLandscape ?? false
    }

    /// Allows `allowed`, then rotates the screen to `rotateTo`.
    static func set(_ allowed: UIInterfaceOrientationMask, rotateTo: UIInterfaceOrientationMask, attempt: Int = 0) {
        mask = allowed
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            // The topmost presented screen (the player's full-screen cover) decides what's allowed.
            var controller = scene.keyWindow?.rootViewController
            while let current = controller {
                current.setNeedsUpdateOfSupportedInterfaceOrientations()
                controller = current.presentedViewController
            }
            let state = scene.activationState.rawValue
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: rotateTo)) { error in
                Task { @MainActor in
                    AppLog.shared.log("Rotation failed (try \(attempt + 1), scene state \(state)): \(error.localizedDescription)", level: .warning)
                    // iOS sometimes refuses while a screen is still being presented; ask again shortly,
                    // unless something else has changed the lock since.
                    guard attempt < 2, mask == allowed else { return }
                    try? await Task.sleep(for: .milliseconds(attempt == 0 ? 300 : 900))
                    guard mask == allowed else { return }
                    set(allowed, rotateTo: rotateTo, attempt: attempt + 1)
                }
            }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        MainActor.assumeIsolated { OrientationLock.mask }
    }

    /// iOS woke the app because background downloads finished.
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        MainActor.assumeIsolated {
            DownloadStore.shared.backgroundCompletion = completionHandler
        }
    }
}
