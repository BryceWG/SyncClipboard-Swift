import AppKit
import SwiftUI
import SyncClipboardKit

@MainActor
final class SettingsWindowController {
    private let window: NSWindow

    init(appModel: AppModel) {
        let hostingController = NSHostingController(rootView: SettingsView(appModel: appModel))
        let window = NSWindow(contentViewController: hostingController)
        window.title = "SyncClipboard-Swift"
        window.setContentSize(NSSize(width: 520, height: 420))
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        window.collectionBehavior = [.moveToActiveSpace]
        self.window = window
    }

    func show() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
