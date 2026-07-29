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
    private let downloadsDirectory: URL

    private var tracker = SyncSnapshotTracker()
    private var diagnostics = SyncDiagnostics()
    private var syncEnabled = false
    private var showNotifications = true
    private var inFlightRemoteFingerprint: String?
    public var diagnosticsHandler: ((SyncDiagnostics) -> Void)?

    public init(
        httpClient: SyncClipboardHTTPClient,
        notifier: UserNotifier,
        downloadsDirectory: URL? = nil
    ) {
        self.httpClient = httpClient
        self.notifier = notifier
        self.downloadsDirectory = downloadsDirectory ?? FileTransfer.defaultDownloadsDirectory
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
            guard snapshot.type == .text else { return }
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
        guard profile.type == .text else { return true }
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

    @discardableResult
    public func transferClipboardFiles(
        using clipboardService: any ClipboardServicing,
        maximumBytes: Int64
    ) async -> Bool {
        guard syncEnabled else { return false }

        do {
            let fileURLs = clipboardService.readFileURLs()
            if !fileURLs.isEmpty {
                let prepared = try await FileTransfer.prepareUpload(urls: fileURLs, maximumBytes: maximumBytes)
                defer { prepared.cleanup() }
                let hash = try await Task.detached {
                    try Hashing.fileProfileHash(fileName: prepared.name, fileURL: prepared.url)
                }.value
                try await httpClient.uploadFile(
                    at: prepared.url,
                    name: prepared.name,
                    mimeType: prepared.url.pathExtension.lowercased() == "zip"
                        ? "application/zip"
                        : "application/octet-stream"
                )
                try await httpClient.setCurrentProfile(ProfileDTO(
                    type: .file,
                    hash: hash,
                    text: prepared.name,
                    hasData: true,
                    dataName: prepared.name,
                    size: prepared.size
                ))
                completeManualTransfer(push: true, message: prepared.name)
                return true
            }

            let localSnapshot = try clipboardService.readCurrentSnapshot()
            if let localSnapshot, localSnapshot.type == .image {
                guard localSnapshot.size <= maximumBytes else {
                    throw SyncClipboardError.transferTooLarge(maximumBytes)
                }
                let remote = try await httpClient.fetchCurrentProfile()
                guard remote.type != .image || remote.hash != localSnapshot.hash else {
                    notifyManualSkip("The same image is already on the server.")
                    return true
                }
                guard let data = localSnapshot.transferData, let name = localSnapshot.dataName else {
                    throw SyncClipboardError.missingTransferData(.image)
                }
                try await httpClient.uploadFile(data: data, name: name, mimeType: "image/png")
                try await httpClient.setCurrentProfile(localSnapshot.profileDTO)
                tracker.markUploaded(localSnapshot)
                completeManualTransfer(push: true, message: name)
                return true
            }

            let remote = try await httpClient.fetchCurrentProfile()
            guard remote.type == .image || remote.type == .file || remote.type == .group else {
                notifyManualSkip("No remote image or file is available.")
                return true
            }
            guard remote.size <= maximumBytes else {
                throw SyncClipboardError.transferTooLarge(maximumBytes)
            }
            guard remote.hasData, let proposedName = remote.dataName else {
                throw SyncClipboardError.missingTransferData(remote.type)
            }
            let name = try FileTransfer.safeFileName(proposedName)
            let temporaryURL = try await httpClient.downloadFile(named: name, maximumBytes: maximumBytes)
            defer { try? FileManager.default.removeItem(at: temporaryURL) }

            if remote.type == .image {
                let data = try await Task.detached { try Data(contentsOf: temporaryURL) }.value
                let snapshot = try ClipboardSnapshot.fromRemote(dto: remote, transferData: data)
                try clipboardService.write(snapshot)
                tracker.markAppliedRemote(snapshot)
                completeManualTransfer(push: false, message: name)
            } else {
                let destination = try await FileTransfer.saveDownloadedFile(
                    temporaryURL,
                    suggestedName: name,
                    downloadsDirectory: downloadsDirectory
                )
                completeManualTransfer(push: false, message: destination.path)
            }
            return true
        } catch {
            diagnostics.lastError = error.localizedDescription
            diagnosticsHandler?(diagnostics)
            if showNotifications {
                notifier.notify(title: "File Sync Failed", body: error.localizedDescription)
            }
            return false
        }
    }

    private func completeManualTransfer(push: Bool, message: String) {
        if push {
            diagnostics.lastPushAt = Date()
        } else {
            diagnostics.lastPullAt = Date()
        }
        diagnostics.lastError = nil
        diagnosticsHandler?(diagnostics)
        if showNotifications {
            notifier.notify(title: push ? "File Uploaded" : "File Downloaded", body: message)
        }
    }

    private func notifyManualSkip(_ message: String) {
        diagnostics.lastError = nil
        diagnosticsHandler?(diagnostics)
        if showNotifications {
            notifier.notify(title: "Nothing to Transfer", body: message)
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
