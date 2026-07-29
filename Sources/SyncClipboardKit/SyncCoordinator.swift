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
    private struct PasteboardObservation {
        let changeCount: Int
        let observedAt: Date
    }

    private struct ImageProvenance {
        let serverIdentity: String
        let profileID: String
        let changeCount: Int
    }

    private struct FileDownloadReceipt {
        let serverIdentity: String
        let profileID: String
        let destination: URL
    }

    private struct LocalHistoryCandidate {
        let type: ProfileType
        let hash: String
        let prepared: PreparedTransferFile

        var profileID: String {
            "\(type.rawValue)-\(hash.uppercased())"
        }
    }

    private enum LocalBinaryCandidate {
        case upload(LocalHistoryCandidate)
        case knownRemote(profileID: String)

        var profileID: String {
            switch self {
            case .upload(let candidate):
                return candidate.profileID
            case .knownRemote(let profileID):
                return profileID
            }
        }
    }

    private let httpClient: SyncClipboardHTTPClient
    private let notifier: UserNotifier
    private let downloadsDirectory: URL

    private var tracker = SyncSnapshotTracker()
    private var diagnostics = SyncDiagnostics()
    private var syncEnabled = false
    private var showNotifications = true
    private var inFlightRemoteFingerprint: String?
    private var lastPasteboardObservation: PasteboardObservation?
    private var imageProvenance: ImageProvenance?
    private var fileDownloadReceipt: FileDownloadReceipt?
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

    public func handleLocalPasteboardChange(
        using clipboardService: any ClipboardServicing,
        changeCount: Int? = nil,
        observedAt: Date = Date()
    ) async {
        guard syncEnabled else { return }

        if let changeCount {
            lastPasteboardObservation = PasteboardObservation(
                changeCount: changeCount,
                observedAt: observedAt
            )
            if imageProvenance?.changeCount != changeCount {
                imageProvenance = nil
            }
        }

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
            guard !Task.isCancelled else { return false }
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
                notifier.notify(title: NSLocalizedString("Clipboard Updated", bundle: .main, comment: "Notification title"), body: snapshot.previewText)
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
            guard let configuration = httpClient.configuration else {
                throw SyncClipboardError.missingServerConfiguration
            }
            let actionDate = Date()
            let local = try await captureLocalBinary(
                using: clipboardService,
                maximumBytes: maximumBytes,
                actionDate: actionDate,
                configuration: configuration
            )
            defer {
                if case .upload(let candidate) = local {
                    candidate.prepared.cleanup()
                }
            }

            let uploaded: Bool
            if case .upload(let candidate) = local {
                uploaded = try await ensureHistory(
                    for: candidate,
                    configuration: configuration
                )
            } else {
                uploaded = false
            }

            guard let remote = try await latestBinaryHistory(configuration: configuration) else {
                if uploaded, case .upload(let candidate) = local {
                    throw SyncClipboardError.historyDataMissing(candidate.profileID)
                }
                notifyManualSkip(NSLocalizedString("No remote image or file is available.", bundle: .main, comment: "Manual transfer skip message"))
                return true
            }

            let remoteID = try remote.profileID
            if remoteID == local?.profileID {
                try await publishCurrentProfile(remote, configuration: configuration)
                if uploaded, case .upload(let candidate) = local {
                    completeManualTransfer(push: true, message: candidate.prepared.name)
                } else {
                    notifyManualSkip(NSLocalizedString("The latest image or file is already local.", bundle: .main, comment: "Manual transfer skip message"))
                }
                return true
            }

            if uploaded {
                diagnostics.lastPushAt = Date()
            }
            return try await pullRemoteHistory(
                remote,
                using: clipboardService,
                maximumBytes: maximumBytes,
                configuration: configuration
            )
        } catch {
            diagnostics.lastError = error.localizedDescription
            diagnosticsHandler?(diagnostics)
            if showNotifications {
                notifier.notify(title: NSLocalizedString("File Sync Failed", bundle: .main, comment: "Notification title"), body: error.localizedDescription)
            }
            return false
        }
    }

    private func captureLocalBinary(
        using clipboardService: any ClipboardServicing,
        maximumBytes: Int64,
        actionDate: Date,
        configuration: ServerConfiguration
    ) async throws -> LocalBinaryCandidate? {
        let changeCount = clipboardService.changeCount
        let observationDate = lastPasteboardObservation?.changeCount == changeCount
            ? lastPasteboardObservation?.observedAt
            : nil
        let fileURLs = clipboardService.readFileURLs()
        if !fileURLs.isEmpty {
            let prepared = try await FileTransfer.prepareUpload(
                urls: fileURLs,
                maximumBytes: maximumBytes,
                observationDate: observationDate,
                actionDate: actionDate
            )
            let hash = try await Task.detached {
                try Hashing.fileProfileHash(fileName: prepared.name, fileURL: prepared.url)
            }.value
            return .upload(LocalHistoryCandidate(type: .file, hash: hash, prepared: prepared))
        }

        guard let snapshot = try clipboardService.readCurrentSnapshot(), snapshot.type == .image else {
            return nil
        }
        let identity = serverIdentity(configuration)
        if let provenance = imageProvenance,
           provenance.changeCount == changeCount,
           provenance.serverIdentity == identity {
            return .knownRemote(profileID: provenance.profileID)
        }
        guard let data = snapshot.transferData, let name = snapshot.dataName else {
            throw SyncClipboardError.missingTransferData(.image)
        }
        let prepared = try await FileTransfer.prepareImage(
            data: data,
            name: name,
            maximumBytes: maximumBytes,
            eventDate: observationDate ?? actionDate
        )
        return .upload(LocalHistoryCandidate(type: .image, hash: snapshot.hash, prepared: prepared))
    }

    private func ensureHistory(
        for candidate: LocalHistoryCandidate,
        configuration: ServerConfiguration
    ) async throws -> Bool {
        let existing = try await httpClient.fetchHistoryRecord(
            profileID: candidate.profileID,
            configuration: configuration
        )
        if let existing, !existing.isDeleted {
            guard existing.hasData else {
                throw SyncClipboardError.historyDataMissing(candidate.profileID)
            }
            return false
        }

        let localBefore = Date()
        let serverTime = try await httpClient.fetchServerTime(configuration: configuration)
        let localAfter = Date()
        let localMidpoint = Date(
            timeIntervalSinceReferenceDate:
                (localBefore.timeIntervalSinceReferenceDate + localAfter.timeIntervalSinceReferenceDate) / 2
        )
        let correctedEventDate = candidate.prepared.eventDate.addingTimeInterval(
            serverTime.timeIntervalSince(localMidpoint)
        )
        let record = HistoryRecordDTO(
            hash: candidate.hash,
            text: candidate.prepared.name,
            type: candidate.type,
            createTime: existing?.createTime ?? correctedEventDate,
            lastModified: correctedEventDate,
            lastAccessed: correctedEventDate,
            starred: existing?.starred ?? false,
            pinned: existing?.pinned ?? false,
            size: candidate.prepared.size,
            hasData: true,
            version: existing.map { max($0.version + 1, 1) } ?? 0,
            isDeleted: false
        )
        let uploaded = try await httpClient.uploadHistory(
            record,
            dataFileURL: candidate.prepared.url,
            fileName: candidate.prepared.name,
            configuration: configuration
        )
        guard !uploaded.isDeleted, uploaded.hasData else {
            throw SyncClipboardError.historyDataMissing(candidate.profileID)
        }
        return true
    }

    private func latestBinaryHistory(configuration: ServerConfiguration) async throws -> HistoryRecordDTO? {
        var page = 1
        while true {
            let records = try await httpClient.fetchHistoryPage(page: page, configuration: configuration)
            for record in records where !record.isDeleted {
                let profileID = try record.profileID
                guard record.hasData else {
                    throw SyncClipboardError.historyDataMissing(profileID)
                }
                return record
            }
            guard records.count == 50 else {
                return nil
            }
            page += 1
        }
    }

    private func pullRemoteHistory(
        _ initial: HistoryRecordDTO,
        using clipboardService: any ClipboardServicing,
        maximumBytes: Int64,
        configuration: ServerConfiguration
    ) async throws -> Bool {
        var remote = initial

        for attempt in 0 ... 1 {
            let profileID = try remote.profileID
            let identity = serverIdentity(configuration)
            if remote.type != .image,
               let receipt = fileDownloadReceipt,
               receipt.serverIdentity == identity,
               receipt.profileID == profileID,
               FileManager.default.fileExists(atPath: receipt.destination.path) {
                notifyManualSkip(NSLocalizedString("The latest file has already been downloaded.", bundle: .main, comment: "Manual transfer skip message"))
                return true
            }
            guard remote.size >= 0, remote.size <= maximumBytes else {
                throw SyncClipboardError.transferTooLarge(maximumBytes)
            }

            let downloaded = try await httpClient.downloadHistoryData(
                profileID: profileID,
                maximumBytes: maximumBytes,
                configuration: configuration
            )
            let temporaryURL = downloaded.url
            defer { try? FileManager.default.removeItem(at: temporaryURL) }

            guard httpClient.configuration == configuration else {
                throw SyncClipboardError.serverConfigurationChanged
            }
            let barrier = try await latestBinaryHistory(configuration: configuration)
            guard httpClient.configuration == configuration else {
                throw SyncClipboardError.serverConfigurationChanged
            }
            guard let barrier, try barrier.profileID == profileID else {
                if attempt == 0, let barrier {
                    remote = barrier
                    continue
                }
                throw SyncClipboardError.historyChangedDuringTransfer
            }

            if remote.type == .group {
                try await FileTransfer.validateZIP(at: temporaryURL)
            } else {
                let fileName = remote.text
                let expectedHash = remote.normalizedHash
                let hash = try await Task.detached {
                    try Hashing.fileProfileHash(fileName: fileName, fileURL: temporaryURL)
                }.value
                guard hash == expectedHash else {
                    throw SyncClipboardError.historyDownloadHashMismatch
                }
            }

            let name = try downloadedName(for: remote, suggestedName: downloaded.suggestedName)
            if remote.type == .image {
                let data = try await Task.detached { try Data(contentsOf: temporaryURL) }.value
                guard httpClient.configuration == configuration else {
                    throw SyncClipboardError.serverConfigurationChanged
                }
                let snapshot = try ClipboardSnapshot.fromRemote(
                    dto: ProfileDTO(
                        type: .image,
                        hash: remote.normalizedHash,
                        text: remote.text,
                        hasData: true,
                        dataName: name,
                        size: remote.size
                    ),
                    transferData: data
                )
                try clipboardService.write(snapshot)
                imageProvenance = ImageProvenance(
                    serverIdentity: identity,
                    profileID: profileID,
                    changeCount: clipboardService.changeCount
                )
                completeManualTransfer(push: false, message: name)
            } else {
                let destination = try await FileTransfer.saveDownloadedFile(
                    temporaryURL,
                    suggestedName: name,
                    downloadsDirectory: downloadsDirectory
                )
                guard httpClient.configuration == configuration else {
                    try? FileManager.default.removeItem(at: destination)
                    throw SyncClipboardError.serverConfigurationChanged
                }
                fileDownloadReceipt = FileDownloadReceipt(
                    serverIdentity: identity,
                    profileID: profileID,
                    destination: destination
                )
                completeManualTransfer(push: false, message: destination.path)
            }
            return true
        }

        throw SyncClipboardError.historyChangedDuringTransfer
    }

    private func publishCurrentProfile(
        _ record: HistoryRecordDTO,
        configuration: ServerConfiguration
    ) async throws {
        guard httpClient.configuration == configuration else {
            throw SyncClipboardError.serverConfigurationChanged
        }
        let current = try await httpClient.fetchCurrentProfile(configuration: configuration)
        guard httpClient.configuration == configuration else {
            throw SyncClipboardError.serverConfigurationChanged
        }
        guard current.type != record.type || current.hash.uppercased() != record.normalizedHash else {
            return
        }
        try await httpClient.setCurrentProfile(
            ProfileDTO(
                type: record.type,
                hash: record.normalizedHash,
                text: record.text,
                hasData: record.hasData,
                dataName: record.hasData ? record.text : nil,
                size: record.size
            ),
            configuration: configuration
        )
        guard httpClient.configuration == configuration else {
            throw SyncClipboardError.serverConfigurationChanged
        }
    }

    private func downloadedName(for record: HistoryRecordDTO, suggestedName: String?) throws -> String {
        if record.type == .group {
            guard let suggestedName, !suggestedName.isEmpty, suggestedName != "data" else {
                return "SyncClipboard-Group.zip"
            }
            let safeName = try FileTransfer.safeFileName(suggestedName)
            return safeName.lowercased().hasSuffix(".zip") ? safeName : "\(safeName).zip"
        }
        if let suggestedName, !suggestedName.isEmpty, suggestedName != "data" {
            return try FileTransfer.safeFileName(suggestedName)
        }
        return try FileTransfer.safeFileName(record.text)
    }

    private func serverIdentity(_ configuration: ServerConfiguration) -> String {
        "\(configuration.baseURL.absoluteString)|\(configuration.username)"
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
            let title = push
                ? NSLocalizedString("File Uploaded", bundle: .main, comment: "Notification title")
                : NSLocalizedString("File Downloaded", bundle: .main, comment: "Notification title")
            notifier.notify(title: title, body: message)
        }
    }

    private func notifyManualSkip(_ message: String) {
        diagnostics.lastError = nil
        diagnosticsHandler?(diagnostics)
        if showNotifications {
            notifier.notify(title: NSLocalizedString("Nothing to Transfer", bundle: .main, comment: "Notification title"), body: message)
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
