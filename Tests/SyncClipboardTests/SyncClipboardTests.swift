import Foundation
#if canImport(XCTest)
import XCTest
@testable import SyncClipboardKit

private final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: SyncClipboardError.unexpectedResponse(-1))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []

    func append(_ entry: String) {
        lock.lock()
        entries.append(entry)
        lock.unlock()
    }

    func clear() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }

    var snapshot: [String] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }
}

@MainActor
private final class FakeClipboardService: ClipboardServicing {
    private(set) var writtenSnapshots: [ClipboardSnapshot] = []
    var nextSnapshot: ClipboardSnapshot?
    var fileURLs: [URL] = []

    func readFileURLs() -> [URL] {
        fileURLs
    }

    func readCurrentSnapshot() throws -> ClipboardSnapshot? {
        nextSnapshot
    }

    func write(_ snapshot: ClipboardSnapshot) throws {
        writtenSnapshots.append(snapshot)
    }
}

private final class FakeSettingsStore: SettingsStoring {
    private let loadedSettings: AppSettings
    private let onSave: (AppSettings) throws -> Void
    private(set) var savedSettings: [AppSettings] = []

    init(
        loadedSettings: AppSettings = AppSettings(),
        onSave: @escaping (AppSettings) throws -> Void = { _ in }
    ) {
        self.loadedSettings = loadedSettings
        self.onSave = onSave
    }

    func load() throws -> AppSettings {
        loadedSettings
    }

    func save(_ settings: AppSettings) throws {
        savedSettings.append(settings)
        try onSave(settings)
    }
}

private final class FakeKeychainStore: KeychainStoring {
    private let storedPassword: String?
    private let onSave: (String, String) throws -> Void
    private(set) var savedPasswords: [(account: String, password: String)] = []

    init(
        readPassword: String? = nil,
        onSave: @escaping (String, String) throws -> Void = { _, _ in }
    ) {
        self.storedPassword = readPassword
        self.onSave = onSave
    }

    func readPassword(account: String) throws -> String? {
        storedPassword
    }

    func savePassword(_ password: String, account: String) throws {
        savedPasswords.append((account: account, password: password))
        try onSave(password, account)
    }

    func deletePassword(account: String) throws {}
}

@MainActor
private final class FakeLaunchAtLoginManager: LaunchAtLoginManaging {
    var status: LaunchAtLoginStatus
    private let nextStatusAfterSet: LaunchAtLoginStatus?
    private(set) var requestedValues: [Bool] = []

    init(
        status: LaunchAtLoginStatus = .disabled,
        nextStatusAfterSet: LaunchAtLoginStatus? = nil
    ) {
        self.status = status
        self.nextStatusAfterSet = nextStatusAfterSet
    }

    func setEnabled(_ enabled: Bool) throws {
        requestedValues.append(enabled)
        if let nextStatusAfterSet {
            status = nextStatusAfterSet
        } else {
            status = enabled ? .enabled : .disabled
        }
    }
}

@MainActor
private final class FakeRealtimeClient: RealtimeClient {
    var onProfileChanged: (@Sendable (ProfileDTO) -> Void)?
    var onStateChange: (@Sendable (RealtimeState) -> Void)?

    private(set) var startedConfigurations: [ServerConfiguration] = []
    private(set) var stopCount = 0
    private(set) var pollCount = 0

    func start(configuration: ServerConfiguration) async {
        startedConfigurations.append(configuration)
    }

    func stop() async {
        stopCount += 1
    }

    func pollNow() async {
        pollCount += 1
    }
}

final class SyncClipboardTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testLongTextUsesTransferFilePayload() {
        let text = String(repeating: "a", count: textTransferThreshold + 5)
        let snapshot = ClipboardSnapshot.text(text)

        XCTAssertEqual(snapshot.transferData, Data(text.utf8))
        XCTAssertNil(snapshot.inlineText)
        XCTAssertEqual(snapshot.previewText.count, textTransferThreshold)
        XCTAssertTrue(snapshot.profileDTO.hasData)
        XCTAssertEqual(snapshot.profileDTO.dataName, "text-\(snapshot.hash).txt")
    }

    func testImageHashUsesDeterministicFileNaming() {
        let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01, 0x02, 0x03])
        let snapshot = ClipboardSnapshot.image(pngData: bytes)

        let expectedName = "image-\(Hashing.sha256Hex(of: bytes)).png"
        let expectedHash = Hashing.fileProfileHash(fileName: expectedName, fileData: bytes)

        XCTAssertEqual(snapshot.dataName, expectedName)
        XCTAssertEqual(snapshot.hash, expectedHash)
        XCTAssertEqual(snapshot.profileDTO.type, .image)
    }

    func testStreamingFileHashMatchesInMemoryHash() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fileURL = directory.appendingPathComponent("payload.bin")
        let data = Data((0 ..< 255).map(UInt8.init))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try data.write(to: fileURL)

        XCTAssertEqual(
            try Hashing.fileProfileHash(fileName: fileURL.lastPathComponent, fileURL: fileURL),
            Hashing.fileProfileHash(fileName: fileURL.lastPathComponent, fileData: data)
        )
    }

    func testMultipleFilesAreArchivedAndTransferLimitIsEnforced() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let first = directory.appendingPathComponent("first.txt")
        let second = directory.appendingPathComponent("second.txt")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("first".utf8).write(to: first)
        try Data("second".utf8).write(to: second)

        let prepared = try await FileTransfer.prepareUpload(urls: [first, second], maximumBytes: 1_024 * 1_024)
        defer { prepared.cleanup() }
        XCTAssertEqual(prepared.url.pathExtension, "zip")
        XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.url.path))

        do {
            _ = try await FileTransfer.prepareUpload(urls: [first, second], maximumBytes: 5)
            XCTFail("Expected the source-size limit to reject the selection")
        } catch let error as SyncClipboardError {
            guard case .transferTooLarge(5) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testArchivedFoldersExcludeSymbolicLinks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("source")
        let secret = root.appendingPathComponent("secret.txt")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("secret".utf8).write(to: secret)
        try FileManager.default.createSymbolicLink(
            at: source.appendingPathComponent("secret-link"),
            withDestinationURL: secret
        )

        let prepared = try await FileTransfer.prepareUpload(urls: [source], maximumBytes: 1_024 * 1_024)
        defer { prepared.cleanup() }
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-Z1", prepared.url.path]
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        let entries = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertFalse(entries.contains("secret-link"))
        XCTAssertFalse(entries.contains("secret.txt"))
    }

    func testDownloadedFilesUseSafeUniqueNames() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let downloads = root.appendingPathComponent("Downloads")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("existing".utf8).write(to: downloads.appendingPathComponent("report.pdf"))
        let temporary = root.appendingPathComponent("incoming")
        try Data("new".utf8).write(to: temporary)

        let saved = try await FileTransfer.saveDownloadedFile(
            temporary,
            suggestedName: "../report.pdf",
            downloadsDirectory: downloads
        )

        XCTAssertEqual(saved.lastPathComponent, "report (1).pdf")
        XCTAssertEqual(try Data(contentsOf: saved), Data("new".utf8))
    }

    func testProfileDTOEncodesUsingServerFieldNames() throws {
        let dto = ProfileDTO(
            type: .text,
            hash: "ABC",
            text: "hello",
            hasData: true,
            dataName: "payload.txt",
            size: 5
        )

        let data = try JSONEncoder().encode(dto)
        let jsonObject = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(jsonObject["type"] as? String, "Text")
        XCTAssertEqual(jsonObject["hash"] as? String, "ABC")
        XCTAssertEqual(jsonObject["text"] as? String, "hello")
        XCTAssertEqual(jsonObject["hasData"] as? Bool, true)
        XCTAssertEqual(jsonObject["dataName"] as? String, "payload.txt")
        XCTAssertEqual(jsonObject["size"] as? Int, 5)
    }

    func testTrackerSuppressesImmediateRemoteEcho() {
        var tracker = SyncSnapshotTracker()
        let snapshot = ClipboardSnapshot.text("echo")

        XCTAssertTrue(tracker.shouldUpload(snapshot))
        tracker.markUploaded(snapshot)
        XCTAssertFalse(tracker.shouldApplyRemote(snapshot))

        let remote = ClipboardSnapshot.text("remote")
        XCTAssertTrue(tracker.shouldApplyRemote(remote))
        tracker.markAppliedRemote(remote)
        XCTAssertFalse(tracker.shouldUpload(remote))
    }

    func testRealtimePresentationStateClearsErrorAfterRecovery() {
        XCTAssertEqual(
            AppModel.realtimePresentationState(for: .error("network down")),
            RealtimePresentationState(connectionStatusText: "Error", errorText: "network down")
        )
        XCTAssertEqual(
            AppModel.realtimePresentationState(for: .connected),
            RealtimePresentationState(connectionStatusText: "Connected", errorText: "")
        )
        XCTAssertEqual(
            AppModel.realtimePresentationState(for: .reconnecting),
            RealtimePresentationState(connectionStatusText: "Reconnecting", errorText: "")
        )
    }

    func testConnectionStatusAfterSuccessfulPollingConnectionUsesPollingLabel() {
        XCTAssertEqual(
            AppModel.connectionStatusAfterSuccessfulConnectionTest(for: .polling),
            "Polling"
        )
        XCTAssertEqual(
            AppModel.connectionStatusAfterSuccessfulConnectionTest(for: .realtime),
            "Connected"
        )
    }

    func testSignalRHubURLUsesOfficialHubPath() {
        let baseURL = URL(string: "https://example.com/sync/")!

        XCTAssertEqual(
            SignalRConnectionMetadata.hubURL(for: baseURL),
            "https://example.com/sync/SyncClipboardHub"
        )
    }

    func testSignalRHubNegotiateURLUsesOfficialNegotiatePath() {
        let baseURL = URL(string: "https://example.com/sync/")!

        XCTAssertEqual(
            SignalRConnectionMetadata.hubNegotiateURL(for: baseURL).absoluteString,
            "https://example.com/sync/SyncClipboardHub/negotiate?negotiateVersion=1"
        )
    }

    func testSignalRHeadersUseBasicAuthorization() {
        let configuration = ServerConfiguration(
            baseURL: URL(string: "https://example.com")!,
            username: "alice",
            password: "secret"
        )

        XCTAssertEqual(
            SignalRConnectionMetadata.headers(for: configuration)["Authorization"],
            ServerAuth(username: "alice", password: "secret").authorizationHeader
        )
    }

    func testAppSettingsDecodeBackfillsNewFields() throws {
        let legacyJSON = """
        {
          "serverURL": "https://example.com",
          "username": "alice",
          "keychainAccount": "primary",
          "syncEnabled": true,
          "launchAtLogin": false,
          "showNotifications": true
        }
        """.data(using: .utf8)!

        let settings = try JSONDecoder().decode(AppSettings.self, from: legacyJSON)

        XCTAssertEqual(settings.serverURL, "https://example.com")
        XCTAssertEqual(settings.username, "alice")
        XCTAssertEqual(settings.keychainAccount, "primary")
        XCTAssertTrue(settings.syncEnabled)
        XCTAssertTrue(settings.showNotifications)
        XCTAssertTrue(settings.showDockIcon)
        XCTAssertEqual(settings.receiveMode, .realtime)
        XCTAssertEqual(settings.pollingIntervalSeconds, 1.0)
        XCTAssertTrue(settings.autoReconnect)
        XCTAssertEqual(settings.maximumTransferSizeBytes, defaultMaximumTransferSizeBytes)
        XCTAssertEqual(settings.transferShortcut, .defaultTransfer)
    }

    func testAppSettingsDecodePreservesLegacyRealtimeTransportChoices() throws {
        let legacyLongPollingJSON = """
        {
          "realtimeTransportMode": "longPolling"
        }
        """.data(using: .utf8)!
        let legacyRealtimeJSON = """
        {
          "realtimeTransportMode": "serverSentEvents"
        }
        """.data(using: .utf8)!

        let longPollingSettings = try JSONDecoder().decode(AppSettings.self, from: legacyLongPollingJSON)
        let realtimeSettings = try JSONDecoder().decode(AppSettings.self, from: legacyRealtimeJSON)

        XCTAssertEqual(longPollingSettings.receiveMode, .polling)
        XCTAssertEqual(realtimeSettings.receiveMode, .realtime)
    }

    func testSettingsStoreRoundTripsPollingConfiguration() throws {
        let temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = temporaryDirectory.appendingPathComponent("AppSettings.json", isDirectory: false)
        let store = SettingsStore(fileURL: fileURL)
        let original = AppSettings(
            serverURL: "https://example.com/sync",
            username: "alice",
            keychainAccount: "primary",
            syncEnabled: true,
            launchAtLogin: true,
            showNotifications: false,
            showDockIcon: false,
            receiveMode: .polling,
            pollingIntervalSeconds: 2.5,
            autoReconnect: false
        )

        try store.save(original)
        let loaded = try store.load()

        XCTAssertEqual(loaded, original)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testAppSettingsClampPollingInterval() throws {
        let tooSmallJSON = """
        {
          "pollingIntervalSeconds": 0.1
        }
        """.data(using: .utf8)!
        let tooLargeJSON = """
        {
          "pollingIntervalSeconds": 120
        }
        """.data(using: .utf8)!

        let tooSmallSettings = try JSONDecoder().decode(AppSettings.self, from: tooSmallJSON)
        let tooLargeSettings = try JSONDecoder().decode(AppSettings.self, from: tooLargeJSON)

        XCTAssertEqual(tooSmallSettings.pollingIntervalSeconds, 0.5)
        XCTAssertEqual(tooLargeSettings.pollingIntervalSeconds, 60.0)
    }

    func testAppSettingsClampTransferLimitToServerCompatibleMaximum() throws {
        let data = """
        {
          "maximumTransferSizeBytes": 9223372036854775807
        }
        """.data(using: .utf8)!

        let settings = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(settings.maximumTransferSizeBytes, maximumTransferSizeLimitBytes)
    }

    @MainActor
    func testRefreshContextRejectsSupersededConnectionsEvenWhenConfigurationMatches() {
        let configuration = ServerConfiguration(
            baseURL: URL(string: "https://example.com")!,
            username: "alice",
            password: "secret"
        )
        let oldToken = UUID()
        let newToken = UUID()
        let context = RealtimeRefreshContext(configuration: configuration, connectionToken: oldToken)

        XCTAssertFalse(
            SignalRRealtimeClient.isCurrentRefreshContext(
                context,
                desiredConfiguration: configuration,
                currentConnectionToken: newToken
            )
        )
        XCTAssertTrue(
            SignalRRealtimeClient.isCurrentRefreshContext(
                context,
                desiredConfiguration: configuration,
                currentConnectionToken: oldToken
            )
        )
    }

    @MainActor
    func testConnectionChecksSignalRHubAvailability() async throws {
        let log = RequestLog()
        let session = makeMockSession()
        let client = SyncClipboardHTTPClient(session: session)
        let configuration = ServerConfiguration(
            baseURL: URL(string: "https://example.com/sync/")!,
            username: "alice",
            password: "secret"
        )
        client.updateConfiguration(configuration)

        MockURLProtocol.requestHandler = { request in
            let url = try XCTUnwrap(request.url)
            log.append("\(request.httpMethod ?? "GET") \(url.absoluteString)")

            switch (request.httpMethod, url.path, url.query) {
            case ("GET", "/sync/api/time", nil):
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data("ok".utf8)
                )
            case ("POST", "/sync/SyncClipboardHub/negotiate", "negotiateVersion=1"):
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data("{}".utf8)
                )
            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "GET") \(url.absoluteString)")
                return (
                    HTTPURLResponse(url: url, statusCode: 500, httpVersion: nil, headerFields: nil)!,
                    Data()
                )
            }
        }

        try await client.testConnection()

        XCTAssertEqual(
            log.snapshot,
            [
                "GET https://example.com/sync/api/time",
                "POST https://example.com/sync/SyncClipboardHub/negotiate?negotiateVersion=1",
            ]
        )
    }

    @MainActor
    func testConnectionFailsWhenSignalRHubUnavailable() async {
        let session = makeMockSession()
        let client = SyncClipboardHTTPClient(session: session)
        let configuration = ServerConfiguration(
            baseURL: URL(string: "https://example.com/sync/")!,
            username: "alice",
            password: "secret"
        )
        client.updateConfiguration(configuration)

        MockURLProtocol.requestHandler = { request in
            let url = try XCTUnwrap(request.url)

            switch (request.httpMethod, url.path) {
            case ("GET", "/sync/api/time"):
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data("ok".utf8)
                )
            case ("POST", "/sync/SyncClipboardHub/negotiate"):
                return (
                    HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!,
                    Data()
                )
            default:
                return (
                    HTTPURLResponse(url: url, statusCode: 500, httpVersion: nil, headerFields: nil)!,
                    Data()
                )
            }
        }

        do {
            try await client.testConnection()
            XCTFail("Expected missing SignalR hub to fail connection test")
        } catch let error as SyncClipboardError {
            switch error {
            case .unexpectedResponse(404):
                break
            default:
                XCTFail("Unexpected SyncClipboardError: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    @MainActor
    func testRefreshFromServerReturnsFalseWhenRemoteDownloadFails() async {
        let session = makeMockSession()
        let httpClient = SyncClipboardHTTPClient(session: session)
        let coordinator = SyncCoordinator(httpClient: httpClient, notifier: UserNotifier())
        let clipboardService = ClipboardService()
        let configuration = ServerConfiguration(
            baseURL: URL(string: "https://example.com/sync/")!,
            username: "alice",
            password: "secret"
        )
        let profile = ProfileDTO(
            type: .text,
            hash: "hash",
            text: "preview",
            hasData: true,
            dataName: "missing.txt",
            size: 7
        )
        var latestDiagnostics = SyncDiagnostics()

        coordinator.updatePreferences(syncEnabled: true, showNotifications: false)
        coordinator.diagnosticsHandler = { diagnostics in
            latestDiagnostics = diagnostics
        }
        httpClient.updateConfiguration(configuration)

        MockURLProtocol.requestHandler = { request in
            let url = try XCTUnwrap(request.url)

            switch (request.httpMethod, url.path) {
            case ("GET", "/sync/SyncClipboard.json"):
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    try JSONEncoder().encode(profile)
                )
            case ("GET", "/sync/file/missing.txt"):
                return (
                    HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!,
                    Data()
                )
            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "GET") \(url.absoluteString)")
                return (
                    HTTPURLResponse(url: url, statusCode: 500, httpVersion: nil, headerFields: nil)!,
                    Data()
                )
            }
        }

        let succeeded = await coordinator.refreshFromServer(using: clipboardService)

        XCTAssertFalse(succeeded)
        XCTAssertEqual(
            latestDiagnostics.lastError,
            SyncClipboardError.unexpectedResponse(404).localizedDescription
        )
    }

    @MainActor
    func testAutomaticSyncIgnoresImagesAndFiles() async {
        let log = RequestLog()
        let httpClient = SyncClipboardHTTPClient(session: makeMockSession())
        let coordinator = SyncCoordinator(httpClient: httpClient, notifier: UserNotifier())
        let clipboardService = FakeClipboardService()
        clipboardService.nextSnapshot = .image(pngData: Data([1, 2, 3]))
        coordinator.updatePreferences(syncEnabled: true, showNotifications: false)

        MockURLProtocol.requestHandler = { request in
            log.append(request.url?.absoluteString ?? "request")
            throw SyncClipboardError.unexpectedResponse(500)
        }

        await coordinator.handleLocalPasteboardChange(using: clipboardService)
        let accepted = await coordinator.handleRemoteProfileChange(
            ProfileDTO(type: .file, hash: "file", text: "archive.zip", hasData: true, dataName: "archive.zip", size: 10),
            using: clipboardService
        )

        XCTAssertTrue(accepted)
        XCTAssertTrue(log.snapshot.isEmpty)
        XCTAssertTrue(clipboardService.writtenSnapshots.isEmpty)
    }

    @MainActor
    func testManualImageSyncUsesLocalImageAndSkipsMatchingHash() async throws {
        let log = RequestLog()
        let httpClient = SyncClipboardHTTPClient(session: makeMockSession())
        let coordinator = SyncCoordinator(httpClient: httpClient, notifier: UserNotifier())
        let clipboardService = FakeClipboardService()
        let local = ClipboardSnapshot.image(pngData: Data([1, 2, 3]))
        clipboardService.nextSnapshot = local
        coordinator.updatePreferences(syncEnabled: true, showNotifications: false)
        httpClient.updateConfiguration(ServerConfiguration(
            baseURL: URL(string: "https://example.com/sync/")!,
            username: "alice",
            password: "secret"
        ))

        let remote = ProfileDTO(type: .image, hash: "different", text: "remote.png", hasData: true, dataName: "remote.png", size: 3)
        MockURLProtocol.requestHandler = { request in
            let url = try XCTUnwrap(request.url)
            log.append("\(request.httpMethod ?? "GET") \(url.path)")
            if request.httpMethod == "GET" {
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, try JSONEncoder().encode(remote))
            }
            return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }

        let uploaded = await coordinator.transferClipboardFiles(using: clipboardService, maximumBytes: 1_024)
        XCTAssertTrue(uploaded)
        XCTAssertEqual(log.snapshot, [
            "GET /sync/SyncClipboard.json",
            "PUT /sync/file/\(local.dataName!)",
            "PUT /sync/SyncClipboard.json",
        ])

        log.clear()
        let matchingRemote = ProfileDTO(type: .image, hash: local.hash, text: "remote.png", hasData: true, dataName: "remote.png", size: 3)
        MockURLProtocol.requestHandler = { request in
            let url = try XCTUnwrap(request.url)
            log.append("\(request.httpMethod ?? "GET") \(url.path)")
            return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, try JSONEncoder().encode(matchingRemote))
        }
        let skipped = await coordinator.transferClipboardFiles(using: clipboardService, maximumBytes: 1_024)
        XCTAssertTrue(skipped)
        XCTAssertEqual(log.snapshot, ["GET /sync/SyncClipboard.json"])
    }

    @MainActor
    func testManualRemoteFileDownloadsToConfiguredDirectory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let httpClient = SyncClipboardHTTPClient(session: makeMockSession())
        let coordinator = SyncCoordinator(httpClient: httpClient, notifier: UserNotifier(), downloadsDirectory: root)
        let clipboardService = FakeClipboardService()
        let profile = ProfileDTO(
            type: .file,
            hash: "hash",
            text: "report.pdf",
            hasData: true,
            dataName: "report.pdf",
            size: 4
        )
        coordinator.updatePreferences(syncEnabled: true, showNotifications: false)
        httpClient.updateConfiguration(ServerConfiguration(
            baseURL: URL(string: "https://example.com/sync/")!,
            username: "alice",
            password: "secret"
        ))
        MockURLProtocol.requestHandler = { request in
            let url = try XCTUnwrap(request.url)
            let data = url.lastPathComponent == "SyncClipboard.json"
                ? try JSONEncoder().encode(profile)
                : Data("file".utf8)
            return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
        }

        let downloaded = await coordinator.transferClipboardFiles(using: clipboardService, maximumBytes: 1_024)
        XCTAssertTrue(downloaded)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("report.pdf")), Data("file".utf8))
    }

    @MainActor
    func testStreamingDownloadStopsWhenActualDataExceedsLimit() async throws {
        let client = SyncClipboardHTTPClient(session: makeMockSession())
        client.updateConfiguration(ServerConfiguration(
            baseURL: URL(string: "https://example.com/sync/")!,
            username: "alice",
            password: "secret"
        ))
        MockURLProtocol.requestHandler = { request in
            let url = try XCTUnwrap(request.url)
            return (
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(repeating: 1, count: 10)
            )
        }

        do {
            _ = try await client.downloadFile(named: "large.bin", maximumBytes: 4)
            XCTFail("Expected the streamed byte limit to cancel the download")
        } catch let error as SyncClipboardError {
            guard case .transferTooLarge(4) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    @MainActor
    func testRemoteDuplicatePayloadDoesNotRedownloadTransferFile() async throws {
        let log = RequestLog()
        let session = makeMockSession()
        let httpClient = SyncClipboardHTTPClient(session: session)
        let coordinator = SyncCoordinator(httpClient: httpClient, notifier: UserNotifier())
        let clipboardService = FakeClipboardService()
        let configuration = ServerConfiguration(
            baseURL: URL(string: "https://example.com/sync/")!,
            username: "alice",
            password: "secret"
        )
        let profile = ProfileDTO(
            type: .text,
            hash: "hash-1",
            text: "preview",
            hasData: true,
            dataName: "payload.txt",
            size: 9
        )

        coordinator.updatePreferences(syncEnabled: true, showNotifications: false)
        httpClient.updateConfiguration(configuration)

        MockURLProtocol.requestHandler = { request in
            let url = try XCTUnwrap(request.url)
            log.append("\(request.httpMethod ?? "GET") \(url.absoluteString)")

            switch (request.httpMethod, url.path) {
            case ("GET", "/sync/file/payload.txt"):
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data("full text".utf8)
                )
            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "GET") \(url.absoluteString)")
                return (
                    HTTPURLResponse(url: url, statusCode: 500, httpVersion: nil, headerFields: nil)!,
                    Data()
                )
            }
        }

        let firstSyncResult = await coordinator.handleRemoteProfileChange(profile, using: clipboardService)
        let secondSyncResult = await coordinator.handleRemoteProfileChange(profile, using: clipboardService)

        XCTAssertTrue(firstSyncResult)
        XCTAssertTrue(secondSyncResult)

        XCTAssertEqual(
            log.snapshot,
            ["GET https://example.com/sync/file/payload.txt"]
        )
        XCTAssertEqual(clipboardService.writtenSnapshots.count, 1)
    }

    func testCleanCloseWithoutAutoReconnectPublishesDisconnectedState() {
        XCTAssertEqual(
            SignalRRealtimeClient.terminalStateAfterClose(error: nil, autoReconnectEnabled: false),
            .disconnected
        )
        XCTAssertNil(
            SignalRRealtimeClient.terminalStateAfterClose(error: nil, autoReconnectEnabled: true)
        )
    }

    func testRealtimePollStrategyRestartsMissingOrStoppedConnectionWhenAutoReconnectEnabled() {
        XCTAssertEqual(
            SignalRRealtimeClient.pollStrategy(
                hubConnectionState: nil,
                autoReconnectEnabled: true,
                isCurrentConfiguration: true
            ),
            .restartConnection
        )
        XCTAssertEqual(
            SignalRRealtimeClient.pollStrategy(
                hubConnectionState: .Stopped,
                autoReconnectEnabled: true,
                isCurrentConfiguration: true
            ),
            .restartConnection
        )
    }

    func testRealtimePollStrategyFetchesForActiveConnectionsAndSkipsSupersededConfigs() {
        XCTAssertEqual(
            SignalRRealtimeClient.pollStrategy(
                hubConnectionState: .Connected,
                autoReconnectEnabled: true,
                isCurrentConfiguration: true
            ),
            .fetchCurrentProfile
        )
        XCTAssertEqual(
            SignalRRealtimeClient.pollStrategy(
                hubConnectionState: .Reconnecting,
                autoReconnectEnabled: false,
                isCurrentConfiguration: true
            ),
            .fetchCurrentProfile
        )
        XCTAssertEqual(
            SignalRRealtimeClient.pollStrategy(
                hubConnectionState: .Stopped,
                autoReconnectEnabled: true,
                isCurrentConfiguration: false
            ),
            .skip
        )
    }

    @MainActor
    func testPollingConnectionDoesNotRequireSignalRHub() async throws {
        let log = RequestLog()
        let session = makeMockSession()
        let client = SyncClipboardHTTPClient(session: session)
        let configuration = ServerConfiguration(
            baseURL: URL(string: "https://example.com/sync/")!,
            username: "alice",
            password: "secret",
            receiveMode: .polling
        )
        client.updateConfiguration(configuration)

        MockURLProtocol.requestHandler = { request in
            let url = try XCTUnwrap(request.url)
            log.append("\(request.httpMethod ?? "GET") \(url.absoluteString)")

            switch (request.httpMethod, url.path, url.query) {
            case ("GET", "/sync/api/time", nil):
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data("ok".utf8)
                )
            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "GET") \(url.absoluteString)")
                return (
                    HTTPURLResponse(url: url, statusCode: 500, httpVersion: nil, headerFields: nil)!,
                    Data()
                )
            }
        }

        try await client.testConnection()

        XCTAssertEqual(
            log.snapshot,
            [
                "GET https://example.com/sync/api/time",
            ]
        )
    }

    func testClipboardMonitoringRequiresReadyActiveSession() {
        XCTAssertTrue(
            AppModel.shouldMonitorClipboard(
                syncEnabled: true,
                requiresSetup: false,
                screenAwake: true,
                sessionActive: true
            )
        )
        XCTAssertFalse(AppModel.shouldMonitorClipboard(syncEnabled: false, requiresSetup: false, screenAwake: true, sessionActive: true))
        XCTAssertFalse(AppModel.shouldMonitorClipboard(syncEnabled: true, requiresSetup: true, screenAwake: true, sessionActive: true))
        XCTAssertFalse(AppModel.shouldMonitorClipboard(syncEnabled: true, requiresSetup: false, screenAwake: false, sessionActive: true))
        XCTAssertFalse(AppModel.shouldMonitorClipboard(syncEnabled: true, requiresSetup: false, screenAwake: true, sessionActive: false))
    }

    func testPollingDelayBacksOffAfterFailuresAndResetsAfterSuccess() {
        XCTAssertEqual(AppModel.nextPollingDelay(configuredInterval: 1, previousDelay: 1, succeeded: false), 2)
        XCTAssertEqual(AppModel.nextPollingDelay(configuredInterval: 1, previousDelay: 2, succeeded: false), 4)
        XCTAssertEqual(AppModel.nextPollingDelay(configuredInterval: 1, previousDelay: 40, succeeded: false), 60)
        XCTAssertEqual(AppModel.nextPollingDelay(configuredInterval: 1, previousDelay: 60, succeeded: true), 1)
    }

    @MainActor
    func testPollingStopsAcrossRapidSleepWakeTransitions() async throws {
        let requests = RequestLog()
        let responseData = try JSONEncoder().encode(ProfileDTO(text: "remote"))
        MockURLProtocol.requestHandler = { request in
            requests.append(request.url!.absoluteString)
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                responseData
            )
        }
        let settings = AppSettings(
            serverURL: "https://example.com",
            username: "alice",
            syncEnabled: true,
            showNotifications: false,
            receiveMode: .polling,
            pollingIntervalSeconds: 0.5,
            autoReconnect: false
        )
        let model = AppModel(
            settingsStore: FakeSettingsStore(loadedSettings: settings),
            keychainStore: FakeKeychainStore(readPassword: "secret"),
            httpClient: SyncClipboardHTTPClient(session: makeMockSession()),
            clipboardService: FakeClipboardService(),
            launchAtLoginManager: FakeLaunchAtLoginManager(),
            realtimeClient: FakeRealtimeClient()
        )

        model.start()
        await waitForRequestCount(1, in: requests)
        model.handleScreenSleep()
        model.handleScreenWake()
        await waitForRequestCount(2, in: requests)
        model.handleScreenSleep()
        try await Task.sleep(nanoseconds: 700_000_000)

        XCTAssertEqual(requests.snapshot.count, 2)
        XCTAssertTrue(model.lastErrorText.isEmpty)
        await model.stop()
    }

    @MainActor
    func testPersistSettingsStoresPasswordBeforeSettingsFile() async {
        let operations = RequestLog()
        let settingsStore = FakeSettingsStore { settings in
            operations.append("settings:\(settings.keychainAccount)")
        }
        let keychainStore = FakeKeychainStore { _, account in
            operations.append("keychain:\(account)")
        }
        let launchManager = FakeLaunchAtLoginManager()
        let model = AppModel(
            settingsStore: settingsStore,
            keychainStore: keychainStore,
            httpClient: SyncClipboardHTTPClient(session: makeMockSession()),
            clipboardService: FakeClipboardService(),
            launchAtLoginManager: launchManager
        )

        model.serverURL = "https://example.com"
        model.username = "alice"
        model.password = "secret"

        let succeeded = await model.persistSettings()

        XCTAssertTrue(succeeded)
        XCTAssertEqual(
            operations.snapshot,
            ["keychain:primary", "settings:primary"]
        )
        XCTAssertEqual(keychainStore.savedPasswords.first?.password, "secret")
        XCTAssertEqual(settingsStore.savedSettings.first?.keychainAccount, "primary")
    }

    @MainActor
    func testPersistSettingsShowsLaunchAtLoginPendingApprovalState() async {
        let settingsStore = FakeSettingsStore()
        let keychainStore = FakeKeychainStore()
        let launchManager = FakeLaunchAtLoginManager(
            status: .disabled,
            nextStatusAfterSet: .requiresApproval
        )
        let model = AppModel(
            settingsStore: settingsStore,
            keychainStore: keychainStore,
            httpClient: SyncClipboardHTTPClient(session: makeMockSession()),
            clipboardService: FakeClipboardService(),
            launchAtLoginManager: launchManager
        )

        model.launchAtLogin = true

        let succeeded = await model.persistSettings()

        XCTAssertFalse(succeeded)
        XCTAssertFalse(model.launchAtLogin)
        XCTAssertEqual(
            model.lastErrorText,
            AppModel.launchAtLoginIssueText(forRequestedState: true, status: .requiresApproval)
        )
        XCTAssertEqual(settingsStore.savedSettings.first?.launchAtLogin, false)
    }

    @MainActor
    func testShortcutUpdatePersistsWithoutApplyingUnrelatedSettings() async {
        let settingsStore = FakeSettingsStore()
        let launchManager = FakeLaunchAtLoginManager(
            status: .requiresApproval,
            nextStatusAfterSet: .requiresApproval
        )
        let model = AppModel(
            settingsStore: settingsStore,
            keychainStore: FakeKeychainStore(),
            httpClient: SyncClipboardHTTPClient(session: makeMockSession()),
            clipboardService: FakeClipboardService(),
            launchAtLoginManager: launchManager
        )
        model.shortcutRegistrationHandler = { _ in true }
        model.serverURL = "https://unsaved.example"
        model.username = "unsaved-user"
        let shortcut = GlobalShortcut(keyCode: 8, modifiers: GlobalShortcut.command, displayKey: "C")

        let succeeded = await model.updateTransferShortcut(shortcut)

        XCTAssertTrue(succeeded)
        XCTAssertEqual(settingsStore.savedSettings.last?.transferShortcut, shortcut)
        XCTAssertEqual(settingsStore.savedSettings.last?.serverURL, "")
        XCTAssertEqual(settingsStore.savedSettings.last?.username, "")
        XCTAssertTrue(launchManager.requestedValues.isEmpty)
    }

    private func makeMockSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    @MainActor
    private func waitForRequestCount(_ expectedCount: Int, in log: RequestLog) async {
        for _ in 0 ..< 50 {
            if log.snapshot.count >= expectedCount { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
#endif
