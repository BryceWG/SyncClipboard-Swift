import AppKit
import Carbon
import SwiftUI
import SyncClipboardKit

enum ShortcutDisplay {
    static func string(for shortcut: GlobalShortcut?) -> String {
        guard let shortcut else { return "Not Set" }
        var value = ""
        if shortcut.modifiers & GlobalShortcut.control != 0 { value += "⌃" }
        if shortcut.modifiers & GlobalShortcut.option != 0 { value += "⌥" }
        if shortcut.modifiers & GlobalShortcut.shift != 0 { value += "⇧" }
        if shortcut.modifiers & GlobalShortcut.command != 0 { value += "⌘" }
        return value + (shortcut.displayKey ?? "Key \(shortcut.keyCode)")
    }
}

@MainActor
final class GlobalHotKeyManager {
    private var hotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var currentShortcut: GlobalShortcut?
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return OSStatus(eventNotHandledErr) }
                Unmanaged<GlobalHotKeyManager>.fromOpaque(userData).takeUnretainedValue().action()
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
    }

    func invalidate() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
        hotKey = nil
        eventHandler = nil
        currentShortcut = nil
    }

    func register(_ shortcut: GlobalShortcut?) -> Bool {
        if shortcut?.keyCode == currentShortcut?.keyCode,
           shortcut?.modifiers == currentShortcut?.modifiers {
            currentShortcut = shortcut
            return true
        }

        guard let shortcut else {
            if let hotKey { UnregisterEventHotKey(hotKey) }
            hotKey = nil
            currentShortcut = nil
            return true
        }

        var newHotKey: EventHotKeyRef?
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            carbonModifiers(shortcut.modifiers),
            EventHotKeyID(signature: 0x53434654, id: 1), // SCFT
            GetApplicationEventTarget(),
            0,
            &newHotKey
        )
        guard status == noErr, let newHotKey else { return false }

        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = newHotKey
        currentShortcut = shortcut
        return true
    }

    private func carbonModifiers(_ modifiers: UInt32) -> UInt32 {
        var result: UInt32 = 0
        if modifiers & GlobalShortcut.command != 0 { result |= UInt32(cmdKey) }
        if modifiers & GlobalShortcut.control != 0 { result |= UInt32(controlKey) }
        if modifiers & GlobalShortcut.option != 0 { result |= UInt32(optionKey) }
        if modifiers & GlobalShortcut.shift != 0 { result |= UInt32(shiftKey) }
        return result
    }
}

struct ShortcutRecorder: NSViewRepresentable {
    let shortcut: GlobalShortcut?
    let onChange: (GlobalShortcut?) -> Void

    func makeNSView(context: Context) -> ShortcutRecorderView {
        ShortcutRecorderView(shortcut: shortcut, onChange: onChange)
    }

    func updateNSView(_ view: ShortcutRecorderView, context: Context) {
        view.shortcut = shortcut
        view.onChange = onChange
    }
}

final class ShortcutRecorderView: NSView {
    var shortcut: GlobalShortcut? { didSet { needsDisplay = true } }
    var onChange: (GlobalShortcut?) -> Void
    private var isRecording = false { didSet { needsDisplay = true } }

    init(shortcut: GlobalShortcut?, onChange: @escaping (GlobalShortcut?) -> Void) {
        self.shortcut = shortcut
        self.onChange = onChange
        super.init(frame: .zero)
        setAccessibilityLabel("File sync shortcut")
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 150, height: 26) }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        isRecording = true
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        return super.resignFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }

        switch event.keyCode {
        case 53: // Escape
            finishRecording()
        case 51, 117: // Delete / Forward Delete
            finishRecording()
            onChange(nil)
        default:
            let modifiers = Self.modifiers(from: event.modifierFlags)
            guard modifiers != 0 else {
                NSSound.beep()
                return
            }
            let key = event.charactersIgnoringModifiers?.uppercased()
            finishRecording()
            onChange(GlobalShortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers, displayKey: key))
        }
    }

    private func finishRecording() {
        isRecording = false
        window?.makeFirstResponder(nil)
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        (isRecording ? NSColor.controlAccentColor.withAlphaComponent(0.15) : NSColor.controlBackgroundColor).setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.stroke()

        let text = isRecording ? "Type Shortcut" : ShortcutDisplay.string(for: shortcut)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: NSColor.labelColor,
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(
            at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2),
            withAttributes: attributes
        )
    }

    private static func modifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= GlobalShortcut.command }
        if flags.contains(.control) { result |= GlobalShortcut.control }
        if flags.contains(.option) { result |= GlobalShortcut.option }
        if flags.contains(.shift) { result |= GlobalShortcut.shift }
        return result
    }
}
