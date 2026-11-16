import Combine
import UIKit

/// Presentation changes must not release or suspend an active local installer.
@MainActor
final class InstallationActivity: ObservableObject {
    private var task: UIBackgroundTaskIdentifier = .invalid
    private var installer: ServerInstaller?

    func start(retaining installer: ServerInstaller) {
        guard task == .invalid else { return }
        self.installer = installer
        // UIKit retains this activity until stop/expiration; the task identifier
        // lives independently of SwiftUI's presentation/state storage.
        task = UIApplication.shared.beginBackgroundTask(withName: "Local app installation") {
            self.stop()
        }
        #if !targetEnvironment(macCatalyst)
        BackgroundAudioManager.shared.start()
        #endif
    }

    func stop() {
        if task != .invalid {
            let identifier = task
            task = .invalid
            UIApplication.shared.endBackgroundTask(identifier)
        }
        installer = nil
        #if !targetEnvironment(macCatalyst)
        BackgroundAudioManager.shared.stop()
        #endif
    }
}
