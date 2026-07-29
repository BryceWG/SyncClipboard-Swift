import AppKit
import Combine
import SyncClipboardKit

@MainActor
final class StatusMenuController {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let appModel: AppModel
    private let openSettings: () -> Void
    private var cancellables = Set<AnyCancellable>()
    private var trayImages: [String: NSImage] = [:]

    private let statusLineItem = NSMenuItem(title: L10n.tr("Status: %@"), action: nil, keyEquivalent: "")
    private let syncToggleItem = NSMenuItem(title: L10n.tr("Enable Sync"), action: #selector(toggleSync), keyEquivalent: "")
    private let syncNowItem = NSMenuItem(title: L10n.tr("Sync Now"), action: #selector(syncNow), keyEquivalent: "")
    private let syncFilesItem = NSMenuItem(title: L10n.tr("Sync Images/Files"), action: #selector(syncFiles), keyEquivalent: "")
    private let settingsItem = NSMenuItem(title: L10n.tr("Open Settings"), action: #selector(showSettings), keyEquivalent: ",")
    private let quitItem = NSMenuItem(title: L10n.tr("Quit"), action: #selector(quit), keyEquivalent: "q")

    init(appModel: AppModel, openSettings: @escaping () -> Void) {
        self.appModel = appModel
        self.openSettings = openSettings

        if let button = statusItem.button {
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
            button.toolTip = "SyncClipboard-Swift"
        }

        syncToggleItem.target = self
        syncNowItem.target = self
        syncFilesItem.target = self
        settingsItem.target = self
        quitItem.target = self

        let menu = NSMenu()
        statusLineItem.isEnabled = false
        menu.addItem(statusLineItem)
        menu.addItem(.separator())
        menu.addItem(syncToggleItem)
        menu.addItem(syncNowItem)
        menu.addItem(syncFilesItem)
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

    @objc private func syncFiles() {
        Task { await appModel.syncFiles() }
    }

    @objc private func showSettings() {
        openSettings()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func refreshMenu() {
        statusLineItem.title = String(format: L10n.tr("Status: %@"), L10n.tr(appModel.connectionStatusText))
        syncToggleItem.state = appModel.syncEnabled ? .on : .off
        syncNowItem.isEnabled = appModel.syncEnabled && !appModel.requiresSetup
        syncFilesItem.isEnabled = appModel.syncEnabled && !appModel.requiresSetup && !appModel.isFileTransferRunning
        let shortcut = appModel.transferShortcut.map { "   \(ShortcutDisplay.string(for: $0))" } ?? ""
        syncFilesItem.title = (appModel.isFileTransferRunning ? L10n.tr("Syncing Images/Files…") : L10n.tr("Sync Images/Files")) + shortcut
        updateStatusIcon()
    }

    private func updateStatusIcon() {
        guard let button = statusItem.button else { return }

        let hasError = appModel.connectionStatusText == "Error"
            || appModel.connectionStatusText == "Missing Config"
            || !appModel.lastErrorText.isEmpty
        let resourceName = hasError ? "error" : (appModel.syncEnabled ? "default" : "default-inactive")
        let isTemplate = resourceName != "default-inactive"

        if let image = trayImage(named: resourceName, targetHeight: button.bounds.height, isTemplate: isTemplate) {
            button.image = image
            button.title = ""
        } else {
            button.image = nil
            button.title = "SC"
        }
    }

    private func trayImage(named name: String, targetHeight: CGFloat, isTemplate: Bool) -> NSImage? {
        if let image = trayImages[name] { return image }

        let bundle = Bundle.main
        for directory in ["tray", nil] {
            guard let url = bundle.url(forResource: name, withExtension: "png", subdirectory: directory),
                  let image = NSImage(contentsOf: url) else { continue }
            let side = min(max(targetHeight - 6, 14), 18)
            image.size = NSSize(width: side, height: side)
            image.isTemplate = isTemplate
            trayImages[name] = image
            return image
        }

        return nil
    }
}
