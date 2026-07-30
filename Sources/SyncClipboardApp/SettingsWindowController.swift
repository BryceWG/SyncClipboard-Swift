import AppKit
import SwiftUI
import SyncClipboardKit

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let appModel: AppModel
    private let window: NSWindow

    init(appModel: AppModel) {
        self.appModel = appModel
        self.window = NSWindow(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 520, height: 640)),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        super.init()

        window.title = L10n.tr("Settings")
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.center()
        window.collectionBehavior = [.moveToActiveSpace]
    }

    func show() {
        if window.contentViewController == nil {
            window.contentViewController = NSHostingController(rootView: SettingsView(appModel: appModel))
            window.setContentSize(NSSize(width: 520, height: 640))
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window.contentViewController = nil
    }
}
