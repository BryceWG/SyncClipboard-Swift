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
    private var inFlightRemoteFingerprint: String?
    public var diagnosticsHandler: ((SyncDiagnostics) -> Void)?

    public init(httpClient: SyncClipboardHTTPClient, notifier: UserNotifier) {
        self.httpClient = httpClient
        self.notifier = notifier
    }

    public func updatePreferences(syncEnabled: Bool, showNotifications: Bool) {
        self.syncEnabled = syncEnabled
        self.showNotifications = showNotifications
        if syncEnabled && showNotifications {
            notifier.prepareAuthorization()
        }
    }

    public func handleLocalPasteboardChange(using clipboardService: any ClipboardServicing) async {
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

    @discardableResult
    public func refreshFromServer(using clipboardService: any ClipboardServicing) async -> Bool {
        guard syncEnabled else { return false }

        do {
            let profile = try await httpClient.fetchCurrentProfile()
            return await handleRemoteProfileChange(profile, using: clipboardService)
        } catch {
            diagnostics.lastError = error.localizedDescription
            diagnosticsHandler?(diagnostics)
            return false
        }
    }

    @discardableResult
    public func handleRemoteProfileChange(_ profile: ProfileDTO, using clipboardService: any ClipboardServicing) async -> Bool {
        guard syncEnabled else { return false }
        let fingerprint = profile.fingerprint

        guard beginRemoteHandlingIfNeeded(fingerprint: fingerprint) else {
            return true
        }

        defer { finishRemoteHandling(fingerprint: fingerprint) }

        do {
            let transferData: Data?
            if profile.hasData, let dataName = profile.dataName {
                transferData = try await httpClient.downloadFile(named: dataName)
            } else {
                transferData = nil
            }

            let snapshot = try ClipboardSnapshot.fromRemote(dto: profile, transferData: transferData)
            guard tracker.shouldApplyRemote(snapshot) else { return true }

            try clipboardService.write(snapshot)

            tracker.markAppliedRemote(snapshot)
            diagnostics.lastPullAt = Date()
            diagnostics.lastError = nil
            diagnosticsHandler?(diagnostics)

            if showNotifications {
                notifier.notify(title: "Clipboard Updated", body: snapshot.previewText)
            }
            return true
        } catch {
            diagnostics.lastError = error.localizedDescription
            diagnosticsHandler?(diagnostics)
            return false
        }
    }

    private func beginRemoteHandlingIfNeeded(fingerprint: String) -> Bool {
        guard inFlightRemoteFingerprint != fingerprint else {
            return false
        }
        guard tracker.shouldFetchRemote(fingerprint: fingerprint) else {
            return false
        }

        inFlightRemoteFingerprint = fingerprint
        return true
    }

    private func finishRemoteHandling(fingerprint: String) {
        guard inFlightRemoteFingerprint == fingerprint else {
            return
        }

        inFlightRemoteFingerprint = nil
    }
}
