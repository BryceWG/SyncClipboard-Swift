import AppKit
import Foundation

@MainActor
public final class ClipboardService {
    public init() {}

    public func readCurrentSnapshot() throws -> ClipboardSnapshot? {
        let pasteboard = NSPasteboard.general

        if let imageData = extractImage(from: pasteboard) {
            return .image(pngData: imageData)
        }

        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            return .text(text)
        }

        return nil
    }

    public func write(_ snapshot: ClipboardSnapshot) throws {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        switch snapshot.payload {
        case .text(let text):
            pasteboard.setString(text, forType: .string)

        case .image(let data):
            guard let image = NSImage(data: data) else {
                throw SyncClipboardError.invalidImageData
            }

            if !pasteboard.writeObjects([image]) {
                pasteboard.setData(data, forType: .png)
            }
        }
    }

    private func extractImage(from pasteboard: NSPasteboard) -> Data? {
        let hasImageType = pasteboard.types?.contains(where: { type in
            type == .png || type == .tiff
        }) ?? false

        guard hasImageType,
              let images = pasteboard.readObjects(forClasses: [NSImage.self]),
              let image = images.first as? NSImage else {
            return nil
        }

        return image.pngData()
    }
}

@MainActor
public final class ClipboardMonitor {
    public var onChange: (() -> Void)?

    private let interval: TimeInterval
    private var timer: Timer?
    private var debounceItem: DispatchWorkItem?
    private var lastChangeCount: Int

    public init(interval: TimeInterval = 0.3) {
        self.interval = interval
        self.lastChangeCount = NSPasteboard.general.changeCount
    }

    public func start() {
        stop()
        lastChangeCount = NSPasteboard.general.changeCount
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pollPasteboard()
            }
        }
    }

    public func stop() {
        debounceItem?.cancel()
        debounceItem = nil
        timer?.invalidate()
        timer = nil
    }

    private func pollPasteboard() {
        let currentChangeCount = NSPasteboard.general.changeCount
        guard currentChangeCount != lastChangeCount else {
            return
        }

        lastChangeCount = currentChangeCount
        debounceItem?.cancel()

        let item = DispatchWorkItem { [weak self] in
            self?.onChange?()
        }
        debounceItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: item)
    }
}

private extension NSImage {
    func pngData() -> Data? {
        guard let tiffData = tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else {
            return nil
        }

        return bitmap.representation(using: .png, properties: [:])
    }
}
