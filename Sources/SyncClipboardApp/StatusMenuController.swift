import AppKit
import Combine
import SyncClipboardKit

@MainActor
final class StatusMenuController {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let appModel: AppModel
    private let openSettings: () -> Void
    private var cancellables = Set<AnyCancellable>()

    private let statusLineItem = NSMenuItem(title: "Status: Disconnected", action: nil, keyEquivalent: "")
    private let syncToggleItem = NSMenuItem(title: "Enable Sync", action: #selector(toggleSync), keyEquivalent: "")
    private let syncNowItem = NSMenuItem(title: "Sync Now", action: #selector(syncNow), keyEquivalent: "")
    private let settingsItem = NSMenuItem(title: "Open Settings", action: #selector(showSettings), keyEquivalent: ",")
    private let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")

    init(appModel: AppModel, openSettings: @escaping () -> Void) {
        self.appModel = appModel
        self.openSettings = openSettings

        if let button = statusItem.button {
            if let image = NSImage(
                systemSymbolName: "arrow.left.arrow.right.circle.fill",
                accessibilityDescription: "SyncClipboard-Swift"
            ) {
                image.isTemplate = true
                button.image = image
            } else {
                button.title = "SC"
            }
            button.toolTip = "SyncClipboard-Swift"
        }

        syncToggleItem.target = self
        syncNowItem.target = self
        settingsItem.target = self
        quitItem.target = self

        let menu = NSMenu()
        statusLineItem.isEnabled = false
        menu.addItem(statusLineItem)
        menu.addItem(.separator())
        menu.addItem(syncToggleItem)
        menu.addItem(syncNowItem)
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        menu.addItem(quitItem)
        statusItem.menu = menu

        appModel.objectWillChange
            .sink { [weak self] in
                Task { @MainActor in
                    self?.refreshMenu()
                }
            }
            .store(in: &cancellables)

        refreshMenu()
    }

    @objc private func toggleSync() {
        appModel.syncEnabled.toggle()
        Task { await appModel.persistSettings() }
    }

    @objc private func syncNow() {
        Task { await appModel.syncNow() }
    }

    @objc private func showSettings() {
        openSettings()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func refreshMenu() {
        statusLineItem.title = "Status: \(appModel.connectionStatusText)"
        syncToggleItem.state = appModel.syncEnabled ? .on : .off
        syncNowItem.isEnabled = appModel.syncEnabled
    }
}
