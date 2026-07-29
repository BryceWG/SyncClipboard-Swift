import AppKit
import Foundation

@MainActor
public protocol ClipboardServicing: AnyObject {
    var changeCount: Int { get }
    func readFileURLs() -> [URL]
    func readCurrentSnapshot() throws -> ClipboardSnapshot?
    func write(_ snapshot: ClipboardSnapshot) throws
}

@MainActor
public final class ClipboardService: ClipboardServicing {
    public init() {}

    public var changeCount: Int {
        NSPasteboard.general.changeCount
    }

    public func readFileURLs() -> [URL] {
        NSPasteboard.general.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
    }

    public func readCurrentSnapshot() throws -> ClipboardSnapshot? {
        let pasteboard = NSPasteboard.general

        guard readFileURLs().isEmpty else {
            return nil
        }

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

        switch snapshot.payload {
        case .text(let text):
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)

        case .image(let data):
            guard NSImage(data: data) != nil else {
                throw SyncClipboardError.invalidImageData
            }

            pasteboard.clearContents()
            pasteboard.setData(data, forType: .png)
        }
    }

    private func extractImage(from pasteboard: NSPasteboard) -> Data? {
        if let pngData = pasteboard.data(forType: .png), NSImage(data: pngData) != nil {
            return pngData
        }

        guard let tiffData = pasteboard.data(forType: .tiff),
              let bitmap = NSBitmapImageRep(data: tiffData) else {
            return nil
        }

        return bitmap.representation(using: .png, properties: [:])
    }
}

@MainActor
public final class ClipboardMonitor {
    public var onChange: ((Int, Date) -> Void)?

    private let interval: TimeInterval
    private var timer: Timer?
    private var debounceItem: DispatchWorkItem?
    private var lastChangeCount: Int

    public init(interval: TimeInterval = 0.5) {
        self.interval = interval
        self.lastChangeCount = NSPasteboard.general.changeCount
    }

    public func start() {
        guard timer == nil else { return }

        lastChangeCount = NSPasteboard.general.changeCount
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pollPasteboard()
            }
        }
        timer.tolerance = interval / 2
        self.timer = timer
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
        let observedAt = Date()
        debounceItem?.cancel()

        let item = DispatchWorkItem { [weak self] in
            self?.onChange?(currentChangeCount, observedAt)
        }
        debounceItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: item)
    }
}
