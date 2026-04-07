import AppKit
import Combine
import SyncClipboardKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let appModel = AppModel()
    private var statusMenuController: StatusMenuController?
    private var settingsWindowController: SettingsWindowController?
    private var cancellables = Set<AnyCancellable>()
    private var terminationInProgress = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        applyDockIconVisibility(appModel.showDockIcon)
        observeWorkspaceNotifications()

        let settingsWindowController = SettingsWindowController(appModel: appModel)
        let statusMenuController = StatusMenuController(
            appModel: appModel,
            openSettings: { [weak settingsWindowController] in
                settingsWindowController?.show()
            }
        )

        self.settingsWindowController = settingsWindowController
        self.statusMenuController = statusMenuController
        appModel.$showDockIcon
            .removeDuplicates()
            .sink { [weak self] showDockIcon in
                self?.applyDockIconVisibility(showDockIcon)
            }
            .store(in: &cancellables)
        appModel.start()

        if appModel.requiresSetup {
            settingsWindowController.show()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationInProgress else {
            return .terminateNow
        }

        terminationInProgress = true
        Task { @MainActor in
            await appModel.stop()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settingsWindowController?.show()
        return true
    }

    private func applyDockIconVisibility(_ showDockIcon: Bool) {
        let activationPolicy: NSApplication.ActivationPolicy = showDockIcon ? .regular : .accessory
        NSApplication.shared.setActivationPolicy(activationPolicy)
    }

    private func observeWorkspaceNotifications() {
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in
                self?.appModel.handleSystemWake()
            }
            .store(in: &cancellables)
    }
}
