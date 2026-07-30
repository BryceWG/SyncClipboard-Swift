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

    private struct ImageProvenance: Codable {
        let serverIdentity: String
        let profileID: String
        let changeCount: Int
    }

    private struct FileDownloadReceipt: Codable {
        let serverIdentity: String
        let profileID: String
        let destination: URL
    }

    private struct BinarySyncState: Codable {
        var imageProvenances: [String: ImageProvenance]
        var fileDownloadReceipts: [String: FileDownloadReceipt]
        var knownLocalBinaryProfileIDs: Set<String>
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
    private let stateFileURL: URL?

    private var tracker = SyncSnapshotTracker()
    private var diagnostics = SyncDiagnostics()
    private var syncEnabled = false
    private var showNotifications = true
    private var autoSyncImages = false
    private var autoSyncFiles = false
    private var maximumBytes: Int64 = defaultMaximumTransferSizeBytes
    private var inFlightRemoteFingerprint: String?
    private var binaryTransferInFlight = false
    private var binaryTransferWaiters: [CheckedContinuation<Void, Never>] = []
    private var lastPasteboardObservation: PasteboardObservation?
    private var imageProvenances: [String: ImageProvenance] = [:]
    private var fileDownloadReceipts: [String: FileDownloadReceipt] = [:]
    private var knownLocalBinaryProfileIDs: Set<String> = []
    private var binaryStatePersistenceError: String?
    public var diagnosticsHandler: ((SyncDiagnostics) -> Void)?

    public init(
        httpClient: SyncClipboardHTTPClient,
        notifier: UserNotifier,
        downloadsDirectory: URL? = nil,
        stateFileURL: URL? = nil
    ) {
        self.httpClient = httpClient
        self.notifier = notifier
        self.downloadsDirectory = downloadsDirectory ?? FileTransfer.defaultDownloadsDirectory
        self.stateFileURL = stateFileURL
        if let stateFileURL,
           let data = try? Data(contentsOf: stateFileURL),
           let state = try? JSONDecoder().decode(BinarySyncState.self, from: data) {
            imageProvenances = state.imageProvenances
            fileDownloadReceipts = state.fileDownloadReceipts
            knownLocalBinaryProfileIDs = state.knownLocalBinaryProfileIDs
        }
    }

    public func updatePreferences(
        syncEnabled: Bool,
        showNotifications: Bool,
        autoSyncImages: Bool = false,
        autoSyncFiles: Bool = false,
        maximumBytes: Int64 = defaultMaximumTransferSizeBytes
    ) {
        self.syncEnabled = syncEnabled
        self.showNotifications = showNotifications
        self.autoSyncImages = autoSyncImages
        self.autoSyncFiles = autoSyncFiles
        self.maximumBytes = maximumBytes
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
            let previousCount = imageProvenances.count
            imageProvenances = imageProvenances.filter { $0.value.changeCount == changeCount }
            if imageProvenances.count != previousCount {
                persistBinarySyncState()
            }
        }

        do {
            if autoSyncFiles, !clipboardService.readFileURLs().isEmpty {
                try await uploadLocalFiles(using: clipboardService, observedAt: observedAt)
                return
            }

            let snapshot = try clipboardService.readCurrentSnapshot()
            guard let snapshot else { return }
            guard snapshot.type == .text || (snapshot.type == .image && autoSyncImages) else { return }
            if snapshot.type == .image {
                if let configuration = httpClient.configuration,
                   let provenance = imageProvenances[serverIdentity(configuration)],
                   provenance.changeCount == clipboardService.changeCount,
                   provenance.serverIdentity == serverIdentity(configuration) {
                    return
                }
                try await uploadLocalImage(snapshot)
                return
            }
            try await uploadSnapshot(snapshot, mimeType: "text/plain; charset=utf-8")
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
        switch profile.type {
        case .text:
            return await handleRemoteClipboardProfile(profile, using: clipboardService)
        case .image where autoSyncImages:
            return await handleRemoteBinaryProfile(profile, using: clipboardService)
        case .file where autoSyncFiles, .group where autoSyncFiles:
            return await handleRemoteBinaryProfile(profile, using: clipboardService)
        default:
            return true
        }
    }

    private func handleRemoteClipboardProfile(
        _ profile: ProfileDTO,
        using clipboardService: any ClipboardServicing
    ) async -> Bool {
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
            diagnostics.lastError = binaryStatePersistenceError
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

    private func handleRemoteBinaryProfile(
        _ profile: ProfileDTO,
        using clipboardService: any ClipboardServicing
    ) async -> Bool {
        let fingerprint = profile.fingerprint
        guard beginRemoteHandlingIfNeeded(fingerprint: fingerprint) else {
            return true
        }
        defer { finishRemoteHandling(fingerprint: fingerprint) }
        let requestedConfiguration = httpClient.configuration
        await acquireBinaryTransfer()
        defer { releaseBinaryTransfer() }

        do {
            guard tracker.shouldFetchRemote(fingerprint: fingerprint) else { return true }
            guard let configuration = requestedConfiguration else {
                throw SyncClipboardError.missingServerConfiguration
            }
            guard httpClient.configuration == configuration else {
                throw SyncClipboardError.serverConfigurationChanged
            }
            if let profileID = binaryProfileID(type: profile.type, hash: profile.hash),
               knownLocalBinaryProfileIDs.contains(knownLocalKey(for: profileID, configuration: configuration)) {
                tracker.markHandledRemote(fingerprint: fingerprint)
                return true
            }
            guard profile.hasData, let dataName = profile.dataName else {
                throw SyncClipboardError.missingTransferData(profile.type)
            }
            guard profile.size >= 0, profile.size <= maximumBytes else {
                throw SyncClipboardError.transferTooLarge(maximumBytes)
            }
            let temporaryURL = try await httpClient.downloadFile(named: dataName, maximumBytes: maximumBytes)
            defer { try? FileManager.default.removeItem(at: temporaryURL) }
            guard httpClient.configuration == configuration else {
                throw SyncClipboardError.serverConfigurationChanged
            }

            if profile.type == .group {
                try await FileTransfer.validateZIP(at: temporaryURL)
            } else {
                let hash = try await Task.detached {
                    try Hashing.fileProfileHash(fileName: dataName, fileURL: temporaryURL)
                }.value
                guard profile.hash.isEmpty || hash == profile.hash.uppercased() else {
                    throw SyncClipboardError.historyDownloadHashMismatch
                }
            }

            if profile.type == .image {
                let data = try await Task.detached { try Data(contentsOf: temporaryURL) }.value
                let snapshot = try ClipboardSnapshot.fromRemote(dto: profile, transferData: data)
                try clipboardService.write(snapshot)
                tracker.markAppliedRemote(.image(pngData: data))
                tracker.markHandledRemote(fingerprint: fingerprint)
                if let profileID = binaryProfileID(type: profile.type, hash: profile.hash) {
                    let identity = serverIdentity(configuration)
                    imageProvenances[identity] = ImageProvenance(
                        serverIdentity: identity,
                        profileID: profileID,
                        changeCount: clipboardService.changeCount
                    )
                    knownLocalBinaryProfileIDs.insert("\(identity)|\(profileID)")
                }
                diagnostics.lastPullAt = Date()
                diagnostics.lastError = binaryStatePersistenceError
                diagnosticsHandler?(diagnostics)
                persistBinarySyncState()
                if showNotifications {
                    notifier.notify(title: NSLocalizedString("Clipboard Updated", bundle: .main, comment: "Notification title"), body: snapshot.previewText)
                }
            } else {
                let destination = try await FileTransfer.saveDownloadedFile(
                    temporaryURL,
                    suggestedName: dataName,
                    downloadsDirectory: downloadsDirectory
                )
                guard httpClient.configuration == configuration else {
                    try? FileManager.default.removeItem(at: destination)
                    throw SyncClipboardError.serverConfigurationChanged
                }
                tracker.markHandledRemote(fingerprint: fingerprint)
                if let profileID = binaryProfileID(type: profile.type, hash: profile.hash) {
                    let identity = serverIdentity(configuration)
                    fileDownloadReceipts[identity] = FileDownloadReceipt(
                        serverIdentity: identity,
                        profileID: profileID,
                        destination: destination
                    )
                    knownLocalBinaryProfileIDs.insert("\(identity)|\(profileID)")
                }
                completeBinaryTransfer(push: false, message: destination.path, downloadedFileURL: destination)
                persistBinarySyncState()
            }
            return true
        } catch {
            diagnostics.lastError = error.localizedDescription
            diagnosticsHandler?(diagnostics)
            if showNotifications {
                notifier.notify(title: NSLocalizedString("File Sync Failed", bundle: .main, comment: "Notification title"), body: error.localizedDescription)
            }
            return false
        }
    }

    private func uploadLocalFiles(
        using clipboardService: any ClipboardServicing,
        observedAt: Date
    ) async throws {
        await acquireBinaryTransfer()
        defer { releaseBinaryTransfer() }

        let prepared = try await FileTransfer.prepareUpload(
            urls: clipboardService.readFileURLs(),
            maximumBytes: maximumBytes,
            observationDate: observedAt
        )
        defer { prepared.cleanup() }
        let hash = try await Task.detached {
            try Hashing.fileProfileHash(fileName: prepared.name, fileURL: prepared.url)
        }.value
        let snapshot = ClipboardSnapshot(
            type: .file,
            hash: hash,
            previewText: prepared.name,
            inlineText: nil,
            transferData: nil,
            dataName: prepared.name,
            size: prepared.size
        )
        guard tracker.shouldUpload(snapshot) else { return }
        guard let configuration = httpClient.configuration else {
            throw SyncClipboardError.missingServerConfiguration
        }

        try await httpClient.uploadFile(
            at: prepared.url,
            name: prepared.name,
            mimeType: prepared.name.lowercased().hasSuffix(".zip") ? "application/zip" : "application/octet-stream",
            configuration: configuration
        )
        try await publishUploadedSnapshot(snapshot, configuration: configuration)
    }

    private func uploadLocalImage(_ snapshot: ClipboardSnapshot) async throws {
        guard snapshot.size <= maximumBytes else {
            throw SyncClipboardError.transferTooLarge(maximumBytes)
        }
        await acquireBinaryTransfer()
        defer { releaseBinaryTransfer() }
        try await uploadSnapshot(snapshot, mimeType: "image/png")
    }

    private func uploadSnapshot(_ snapshot: ClipboardSnapshot, mimeType: String) async throws {
        guard let configuration = httpClient.configuration else {
            throw SyncClipboardError.missingServerConfiguration
        }
        if let profileID = binaryProfileID(type: snapshot.type, hash: snapshot.hash),
           knownLocalBinaryProfileIDs.contains(knownLocalKey(for: profileID, configuration: configuration)) {
            return
        }
        guard tracker.shouldUpload(snapshot) else { return }
        if let transferData = snapshot.transferData, let dataName = snapshot.dataName {
            try await httpClient.uploadFile(
                data: transferData,
                name: dataName,
                mimeType: mimeType,
                configuration: configuration
            )
        }
        try await publishUploadedSnapshot(snapshot, configuration: configuration)
    }

    private func publishUploadedSnapshot(
        _ snapshot: ClipboardSnapshot,
        configuration: ServerConfiguration
    ) async throws {
        guard httpClient.configuration == configuration else {
            throw SyncClipboardError.serverConfigurationChanged
        }
        try await httpClient.setCurrentProfile(snapshot.profileDTO, configuration: configuration)
        guard httpClient.configuration == configuration else {
            throw SyncClipboardError.serverConfigurationChanged
        }
        tracker.markUploaded(snapshot)
        if let profileID = binaryProfileID(type: snapshot.type, hash: snapshot.hash) {
            knownLocalBinaryProfileIDs.insert(knownLocalKey(for: profileID, configuration: configuration))
        }
        diagnostics.lastPushAt = Date()
        diagnostics.lastError = binaryStatePersistenceError
        diagnosticsHandler?(diagnostics)
        persistBinarySyncState()
    }

    @discardableResult
    public func transferClipboardFiles(
        using clipboardService: any ClipboardServicing,
        maximumBytes: Int64
    ) async -> Bool {
        guard syncEnabled else { return false }
        await acquireBinaryTransfer()
        defer { releaseBinaryTransfer() }

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
            if let local {
                knownLocalBinaryProfileIDs.insert(knownLocalKey(for: local.profileID, configuration: configuration))
                persistBinarySyncState()
            }
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
                if uploaded, case .upload(let candidate) = local {
                    completeBinaryTransfer(push: true, message: candidate.prepared.name)
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
        if let provenance = imageProvenances[identity],
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
               let receipt = fileDownloadReceipts[identity],
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
                tracker.markAppliedRemote(.image(pngData: data))
                tracker.markHandledRemote(fingerprint: snapshot.fingerprint)
                imageProvenances[identity] = ImageProvenance(
                    serverIdentity: identity,
                    profileID: profileID,
                    changeCount: clipboardService.changeCount
                )
                knownLocalBinaryProfileIDs.insert("\(identity)|\(profileID)")
                completeBinaryTransfer(push: false, message: name)
                persistBinarySyncState()
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
                tracker.markHandledRemote(
                    fingerprint: ProfileDTO(type: remote.type, hash: remote.normalizedHash).fingerprint
                )
                fileDownloadReceipts[identity] = FileDownloadReceipt(
                    serverIdentity: identity,
                    profileID: profileID,
                    destination: destination
                )
                knownLocalBinaryProfileIDs.insert("\(identity)|\(profileID)")
                completeBinaryTransfer(push: false, message: destination.path, downloadedFileURL: destination)
                persistBinarySyncState()
            }
            return true
        }

        throw SyncClipboardError.historyChangedDuringTransfer
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

    private func binaryProfileID(type: ProfileType, hash: String) -> String? {
        guard type == .image || type == .file || type == .group, !hash.isEmpty else { return nil }
        return "\(type.rawValue)-\(hash.uppercased())"
    }

    private func knownLocalKey(for profileID: String, configuration: ServerConfiguration) -> String {
        "\(serverIdentity(configuration))|\(profileID)"
    }

    private func persistBinarySyncState() {
        guard let stateFileURL else { return }
        let state = BinarySyncState(
            imageProvenances: imageProvenances,
            fileDownloadReceipts: fileDownloadReceipts,
            knownLocalBinaryProfileIDs: knownLocalBinaryProfileIDs
        )
        do {
            try FileManager.default.createDirectory(
                at: stateFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(state).write(to: stateFileURL, options: .atomic)
            if binaryStatePersistenceError != nil {
                binaryStatePersistenceError = nil
                diagnostics.lastError = nil
                diagnosticsHandler?(diagnostics)
            }
        } catch {
            binaryStatePersistenceError = error.localizedDescription
            diagnostics.lastError = binaryStatePersistenceError
            diagnosticsHandler?(diagnostics)
        }
    }

    private func acquireBinaryTransfer() async {
        guard binaryTransferInFlight else {
            binaryTransferInFlight = true
            return
        }
        await withCheckedContinuation { binaryTransferWaiters.append($0) }
    }

    private func releaseBinaryTransfer() {
        guard !binaryTransferWaiters.isEmpty else {
            binaryTransferInFlight = false
            return
        }
        binaryTransferWaiters.removeFirst().resume()
    }

    private func completeBinaryTransfer(push: Bool, message: String, downloadedFileURL: URL? = nil) {
        if push {
            diagnostics.lastPushAt = Date()
        } else {
            diagnostics.lastPullAt = Date()
        }
        diagnostics.lastError = binaryStatePersistenceError
        diagnosticsHandler?(diagnostics)
        if showNotifications {
            let title = push
                ? NSLocalizedString("File Uploaded", bundle: .main, comment: "Notification title")
                : NSLocalizedString("File Downloaded", bundle: .main, comment: "Notification title")
            notifier.notify(title: title, body: message, fileURL: downloadedFileURL)
        }
    }

    private func notifyManualSkip(_ message: String) {
        diagnostics.lastError = binaryStatePersistenceError
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
