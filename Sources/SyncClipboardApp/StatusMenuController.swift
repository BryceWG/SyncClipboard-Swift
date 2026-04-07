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
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
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
        syncNowItem.isEnabled = appModel.syncEnabled && !appModel.requiresSetup
        updateStatusIcon()
    }

    private func updateStatusIcon() {
        guard let button = statusItem.button else { return }

        let resourceName: String
        let isTemplate: Bool

        let hasError = appModel.connectionStatusText == "Error"
            || appModel.connectionStatusText == "Missing Config"
            || !appModel.lastErrorText.isEmpty

        if !appModel.syncEnabled {
            resourceName = hasError ? "error-inactive" : "default-inactive"
            isTemplate = false
        } else if hasError {
            resourceName = "error"
            isTemplate = true
        } else {
            resourceName = "default"
            isTemplate = true
        }

        if let image = Self.loadTrayImage(named: resourceName) {
            let sizedImage = Self.makeStatusBarImage(from: image, targetHeight: button.bounds.height)
            sizedImage.isTemplate = isTemplate
            button.image = sizedImage
            button.title = ""
        } else {
            button.image = nil
            button.title = "SC"
        }
    }

    private static func loadTrayImage(named name: String) -> NSImage? {
        let bundle = Bundle.main
        let candidates: [(String?, String)] = [
            ("tray", name),
            (nil, name),
        ]

        for (directory, resourceName) in candidates {
            if let url = bundle.url(forResource: resourceName, withExtension: "png", subdirectory: directory),
               let image = NSImage(contentsOf: url) {
                return image
            }
        }

        return nil
    }

    private static func makeStatusBarImage(from image: NSImage, targetHeight: CGFloat) -> NSImage {
        let resized = (image.copy() as? NSImage) ?? image
        let side = min(max(targetHeight - 6, 14), 18)
        resized.size = NSSize(width: side, height: side)
        return resized
    }
}
