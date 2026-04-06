import Foundation

public struct SyncDiagnostics: Sendable {
    public var lastPushAt: Date?
    public var lastPullAt: Date?
    public var lastError: String?

    public init(lastPushAt: Date? = nil, lastPullAt: Date? = nil, lastError: String? = nil) {
        self.lastPushAt = lastPushAt
        self.lastPullAt = lastPullAt
        self.lastError = lastError
    }
}

@MainActor
public final class SyncCoordinator {
    private let httpClient: SyncClipboardHTTPClient
    private let notifier: UserNotifier

    private var tracker = SyncSnapshotTracker()
    private var diagnostics = SyncDiagnostics()
    private var syncEnabled = false
    private var showNotifications = true
    public var diagnosticsHandler: ((SyncDiagnostics) -> Void)?

    public init(httpClient: SyncClipboardHTTPClient, notifier: UserNotifier) {
        self.httpClient = httpClient
        self.notifier = notifier
    }

    public func updatePreferences(syncEnabled: Bool, showNotifications: Bool) {
        self.syncEnabled = syncEnabled
        self.showNotifications = showNotifications
    }

    public func handleLocalPasteboardChange(using clipboardService: ClipboardService) async {
        guard syncEnabled else { return }

        do {
            let snapshot = try clipboardService.readCurrentSnapshot()
            guard let snapshot else { return }
            guard tracker.shouldUpload(snapshot) else { return }

            if let transferData = snapshot.transferData, let dataName = snapshot.dataName {
                let mimeType = snapshot.type == .image ? "image/png" : "text/plain; charset=utf-8"
                try await httpClient.uploadFile(data: transferData, name: dataName, mimeType: mimeType)
            }

            try await httpClient.setCurrentProfile(snapshot.profileDTO)
            tracker.markUploaded(snapshot)
            diagnostics.lastPushAt = Date()
            diagnostics.lastError = nil
            diagnosticsHandler?(diagnostics)
        } catch {
            diagnostics.lastError = error.localizedDescription
            diagnosticsHandler?(diagnostics)
        }
    }

    public func refreshFromServer(using clipboardService: ClipboardService) async {
        guard syncEnabled else { return }

        do {
            let profile = try await httpClient.fetchCurrentProfile()
            await handleRemoteProfileChange(profile, using: clipboardService)
        } catch {
            diagnostics.lastError = error.localizedDescription
            diagnosticsHandler?(diagnostics)
        }
    }

    public func handleRemoteProfileChange(_ profile: ProfileDTO, using clipboardService: ClipboardService) async {
        guard syncEnabled else { return }

        do {
            let transferData: Data?
            if profile.hasData, let dataName = profile.dataName {
                transferData = try await httpClient.downloadFile(named: dataName)
            } else {
                transferData = nil
            }

            let snapshot = try ClipboardSnapshot.fromRemote(dto: profile, transferData: transferData)
            guard tracker.shouldApplyRemote(snapshot) else { return }

            try clipboardService.write(snapshot)

            tracker.markAppliedRemote(snapshot)
            diagnostics.lastPullAt = Date()
            diagnostics.lastError = nil
            diagnosticsHandler?(diagnostics)

            if showNotifications {
                notifier.notify(title: "Clipboard Updated", body: snapshot.previewText)
            }
        } catch {
            diagnostics.lastError = error.localizedDescription
            diagnosticsHandler?(diagnostics)
        }
    }
}
