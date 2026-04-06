import AppKit
import SyncClipboardKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let appModel = AppModel()
    private var statusMenuController: StatusMenuController?
    private var settingsWindowController: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)

        let settingsWindowController = SettingsWindowController(appModel: appModel)
        let statusMenuController = StatusMenuController(
            appModel: appModel,
            openSettings: { [weak settingsWindowController] in
                settingsWindowController?.show()
            }
        )

        self.settingsWindowController = settingsWindowController
        self.statusMenuController = statusMenuController
        appModel.start()

        if appModel.requiresSetup {
            settingsWindowController.show()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        appModel.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settingsWindowController?.show()
        return true
    }
}
