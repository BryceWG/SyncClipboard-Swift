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

private func makeHistoryRecord(
    type: ProfileType = .file,
    hash: String = String(repeating: "A", count: 64),
    text: String = "report.pdf",
    date: Date = Date(timeIntervalSince1970: 1_700_000_000),
    size: Int64 = 4,
    hasData: Bool = true,
    version: Int = 0,
    isDeleted: Bool = false
) -> HistoryRecordDTO {
    HistoryRecordDTO(
        hash: hash,
        text: text,
        type: type,
        createTime: date,
        lastModified: date,
        lastAccessed: date,
        size: size,
        hasData: hasData,
        version: version,
        isDeleted: isDeleted
    )
}

private func requestBody(_ request: URLRequest) throws -> Data {
    if let body = request.httpBody {
        return body
    }
    guard let stream = request.httpBodyStream else {
        return Data()
    }
    stream.open()
    defer { stream.close() }
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 1_024)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        guard count >= 0 else {
            throw stream.streamError ?? CocoaError(.fileReadUnknown)
        }
        if count == 0 { break }
        result.append(buffer, count: count)
    }
    return result
}

private func multipartField(_ name: String, in body: String) throws -> String {
    let marker = "name=\"\(name)\"\r\n\r\n"
    let start = try XCTUnwrap(body.range(of: marker)).upperBound
    let remainder = body[start...]
    let end = try XCTUnwrap(remainder.range(of: "\r\n")).lowerBound
    return String(remainder[..<end])
}

@MainActor
private final class FakeClipboardService: ClipboardServicing {
    private(set) var writtenSnapshots: [ClipboardSnapshot] = []
    var changeCount = 0
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
        changeCount += 1
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

    func testUnchangedSelectionProducesStableArchiveProfileHash() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let first = directory.appendingPathComponent("first.txt")
        let second = directory.appendingPathComponent("second.txt")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("first".utf8).write(to: first)
        try Data("second".utf8).write(to: second)
        let eventDate = Date(timeIntervalSince1970: 1_700_000_000)

        let firstArchive = try await FileTransfer.prepareUpload(
            urls: [second, first],
            maximumBytes: 1_024 * 1_024,
            actionDate: eventDate
        )
        defer { firstArchive.cleanup() }
        let secondArchive = try await FileTransfer.prepareUpload(
            urls: [first, second],
            maximumBytes: 1_024 * 1_024,
            actionDate: eventDate
        )
        defer { secondArchive.cleanup() }

        XCTAssertEqual(firstArchive.name, secondArchive.name)
        XCTAssertEqual(
            try Hashing.fileProfileHash(fileName: firstArchive.name, fileURL: firstArchive.url),
            try Hashing.fileProfileHash(fileName: secondArchive.name, fileURL: secondArchive.url)
        )
    }

    func testFileModifiedAfterClipboardObservationUsesActionTime() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = root.appendingPathComponent("changed.txt")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("changed".utf8).write(to: file)
        let observation = Date(timeIntervalSince1970: 1_700_000_000)
        let action = observation.addingTimeInterval(20)
        try FileManager.default.setAttributes(
            [.modificationDate: observation.addingTimeInterval(10)],
            ofItemAtPath: file.path
        )

        let prepared = try await FileTransfer.prepareUpload(
            urls: [file],
            maximumBytes: 1_024,
            observationDate: observation,
            actionDate: action
        )
        defer { prepared.cleanup() }
        XCTAssertEqual(prepared.eventDate, action)
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

    func testHistoryDatesAndProfileIDsUseOfficialFormat() throws {
        let officialUTC = "2026-07-29T12:34:56.1234567Z"
        let officialOffset = "2026-07-29T20:34:56.1234567+08:00"
        XCTAssertEqual(
            try HistoryDateCodec.date(from: officialUTC),
            try HistoryDateCodec.date(from: officialOffset)
        )
        XCTAssertNotNil(try HistoryDateCodec.string(from: HistoryDateCodec.date(from: officialUTC)).wholeMatch(
            of: /\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+Z/
        ))

        let record = makeHistoryRecord(type: .image, hash: String(repeating: "a", count: 64))
        XCTAssertEqual(try record.profileID, "Image-\(String(repeating: "A", count: 64))")
        XCTAssertThrowsError(try HistoryDateCodec.date(from: "not-a-date"))
        XCTAssertThrowsError(try makeHistoryRecord(hash: "not-a-hash").profileID)
    }

    @MainActor
    func testHistoryQueryUsesFormBody() async throws {
        let client = SyncClipboardHTTPClient(session: makeMockSession())
        let configuration = ServerConfiguration(
            baseURL: URL(string: "https://example.com/sync/")!,
            username: "alice",
            password: "secret"
        )
        MockURLProtocol.requestHandler = { request in
            let url = try XCTUnwrap(request.url)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
            let body = String(decoding: try requestBody(request), as: UTF8.self)
            let components = URLComponents(string: "?\(body)")
            let values = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            XCTAssertEqual(values["Page"], "1")
            XCTAssertEqual(values["Types"], "File, Image, Group")
            XCTAssertEqual(values["SortByLastAccessed"], "true")
            return (
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("[]".utf8)
            )
        }

        let records = try await client.fetchHistoryPage(page: 1, configuration: configuration)
        XCTAssertTrue(records.isEmpty)
    }

    func testHistoryMultipartContainsExactMetadataBeforeData() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = root.appendingPathComponent("payload.bin")
        try Data("payload".utf8).write(to: payload)
        let multipart = try HistoryMultipartBody.create(
            record: makeHistoryRecord(),
            dataFileURL: payload,
            fileName: "payload.bin"
        )
        defer { multipart.cleanup() }
        let body = try String(contentsOf: multipart.url, encoding: .utf8)

        XCTAssertFalse(body.contains("name=\"hasData\""))
        XCTAssertEqual(HistoryMultipartBody.metadataFieldNames.count, 11)
        let metadataOffsets = try HistoryMultipartBody.metadataFieldNames.map { name in
            try XCTUnwrap(body.range(of: "name=\"\(name)\"")?.lowerBound)
        }
        XCTAssertEqual(metadataOffsets, metadataOffsets.sorted())
        let dataOffset = try XCTUnwrap(body.range(of: "name=\"data\"")?.lowerBound)
        XCTAssertTrue(metadataOffsets.allSatisfy { $0 < dataOffset })
        XCTAssertTrue(body.hasSuffix("\r\n--\(multipart.boundary)--\r\n"))
    }

    @MainActor
    func testHistoryUploadDistinguishesHashMismatchFromOtherFailures() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = root.appendingPathComponent("report.pdf")
        try Data("file".utf8).write(to: payload)
        let configuration = ServerConfiguration(
            baseURL: URL(string: "https://example.com/sync/")!,
            username: "alice",
            password: "secret"
        )
        let client = SyncClipboardHTTPClient(session: makeMockSession())

        MockURLProtocol.requestHandler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
                Data("Hash mismatch for the provided file.".utf8)
            )
        }
        do {
            _ = try await client.uploadHistory(
                makeHistoryRecord(),
                dataFileURL: payload,
                fileName: "report.pdf",
                configuration: configuration
            )
            XCTFail("Expected hash mismatch")
        } catch let error as SyncClipboardError {
            guard case .historyHashMismatch = error else { return XCTFail("Unexpected error: \(error)") }
        }

        MockURLProtocol.requestHandler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
                Data("database unavailable".utf8)
            )
        }
        do {
            _ = try await client.uploadHistory(
                makeHistoryRecord(),
                dataFileURL: payload,
                fileName: "report.pdf",
                configuration: configuration
            )
            XCTFail("Expected generic history upload failure")
        } catch let error as SyncClipboardError {
            guard case .historyUploadFailed(500) = error else { return XCTFail("Unexpected error: \(error)") }
        }
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

        let history = makeHistoryRecord(
            type: .image,
            hash: local.hash,
            text: try XCTUnwrap(local.dataName),
            size: 3
        )
        let profileID = try history.profileID
        MockURLProtocol.requestHandler = { request in
            let url = try XCTUnwrap(request.url)
            log.append("\(request.httpMethod ?? "GET") \(url.path)")
            switch (request.httpMethod, url.path) {
            case ("GET", "/sync/api/history/\(profileID)"):
                return (HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
            case ("GET", "/sync/api/time"):
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    try JSONEncoder().encode(HistoryDateCodec.string(from: Date()))
                )
            case ("POST", "/sync/api/history"):
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    try JSONEncoder().encode(history)
                )
            case ("POST", "/sync/api/history/query"):
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    try JSONEncoder().encode([history])
                )
            case ("GET", "/sync/SyncClipboard.json"):
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    try JSONEncoder().encode(ProfileDTO(type: .text, hash: "text", text: "text"))
                )
            case ("PUT", "/sync/SyncClipboard.json"):
                let profile = try JSONDecoder().decode(ProfileDTO.self, from: requestBody(request))
                XCTAssertEqual(profile.type, .image)
                XCTAssertEqual(profile.hash, history.normalizedHash)
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "GET") \(url.path)")
                return (HTTPURLResponse(url: url, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
            }
        }

        let uploaded = await coordinator.transferClipboardFiles(using: clipboardService, maximumBytes: 1_024)
        XCTAssertTrue(uploaded)
        XCTAssertEqual(log.snapshot, [
            "GET /sync/api/history/\(profileID)",
            "GET /sync/api/time",
            "POST /sync/api/history",
            "POST /sync/api/history/query",
            "GET /sync/SyncClipboard.json",
            "PUT /sync/SyncClipboard.json",
        ])

        log.clear()
        MockURLProtocol.requestHandler = { request in
            let url = try XCTUnwrap(request.url)
            log.append("\(request.httpMethod ?? "GET") \(url.path)")
            let data = url.path.hasSuffix("/query")
                ? try JSONEncoder().encode([history])
                : try JSONEncoder().encode(history)
            return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
        }
        let skipped = await coordinator.transferClipboardFiles(using: clipboardService, maximumBytes: 1_024)
        XCTAssertTrue(skipped)
        XCTAssertEqual(log.snapshot, [
            "GET /sync/api/history/\(profileID)",
            "POST /sync/api/history/query",
            "GET /sync/SyncClipboard.json",
        ])
    }

    @MainActor
    func testManualRemoteFileDownloadsToConfiguredDirectory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let httpClient = SyncClipboardHTTPClient(session: makeMockSession())
        let coordinator = SyncCoordinator(httpClient: httpClient, notifier: UserNotifier(), downloadsDirectory: root)
        let clipboardService = FakeClipboardService()
        clipboardService.nextSnapshot = .text("local text remains in the clipboard")
        let payload = Data("file".utf8)
        let profile = makeHistoryRecord(
            type: .file,
            hash: Hashing.fileProfileHash(fileName: "report.pdf", fileData: payload),
            text: "report.pdf",
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
            if url.path.hasSuffix("/query") {
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    try JSONEncoder().encode([profile])
                )
            }
            return (
                HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Disposition": "attachment; filename=report.pdf"]
                )!,
                payload
            )
        }

        let downloaded = await coordinator.transferClipboardFiles(using: clipboardService, maximumBytes: 1_024)
        XCTAssertTrue(downloaded)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("report.pdf")), Data("file".utf8))
    }

    @MainActor
    func testManualSyncRejectsActiveHistoryWithoutData() async throws {
        let log = RequestLog()
        let httpClient = SyncClipboardHTTPClient(session: makeMockSession())
        let coordinator = SyncCoordinator(httpClient: httpClient, notifier: UserNotifier())
        let clipboardService = FakeClipboardService()
        let local = ClipboardSnapshot.image(pngData: Data([1, 2, 3]))
        let broken = makeHistoryRecord(
            type: .image,
            hash: local.hash,
            text: try XCTUnwrap(local.dataName),
            size: 3,
            hasData: false
        )
        var diagnostics = SyncDiagnostics()
        coordinator.diagnosticsHandler = { diagnostics = $0 }
        coordinator.updatePreferences(syncEnabled: true, showNotifications: false)
        clipboardService.nextSnapshot = local
        httpClient.updateConfiguration(ServerConfiguration(
            baseURL: URL(string: "https://example.com/sync/")!,
            username: "alice",
            password: "secret"
        ))
        MockURLProtocol.requestHandler = { request in
            let url = try XCTUnwrap(request.url)
            log.append("\(request.httpMethod ?? "GET") \(url.path)")
            return (
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                try JSONEncoder().encode(broken)
            )
        }

        let succeeded = await coordinator.transferClipboardFiles(using: clipboardService, maximumBytes: 1_024)
        XCTAssertFalse(succeeded)
        XCTAssertEqual(log.snapshot, ["GET /sync/api/history/\(try broken.profileID)"])
        XCTAssertEqual(
            diagnostics.lastError,
            SyncClipboardError.historyDataMissing(try broken.profileID).localizedDescription
        )
    }

    @MainActor
    func testLatestHistoryDoesNotSkipActiveRecordWithMissingData() async throws {
        let log = RequestLog()
        let httpClient = SyncClipboardHTTPClient(session: makeMockSession())
        let coordinator = SyncCoordinator(httpClient: httpClient, notifier: UserNotifier())
        let clipboardService = FakeClipboardService()
        let broken = makeHistoryRecord(
            hash: String(repeating: "B", count: 64),
            text: "latest.bin",
            hasData: false
        )
        let older = makeHistoryRecord(
            hash: String(repeating: "C", count: 64),
            text: "older.bin",
            date: Date(timeIntervalSince1970: 1_699_999_999)
        )
        var diagnostics = SyncDiagnostics()
        coordinator.diagnosticsHandler = { diagnostics = $0 }
        coordinator.updatePreferences(syncEnabled: true, showNotifications: false)
        httpClient.updateConfiguration(ServerConfiguration(
            baseURL: URL(string: "https://example.com/sync/")!,
            username: "alice",
            password: "secret"
        ))
        MockURLProtocol.requestHandler = { request in
            let url = try XCTUnwrap(request.url)
            log.append("\(request.httpMethod ?? "GET") \(url.path)")
            XCTAssertTrue(url.path.hasSuffix("/query"))
            return (
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                try JSONEncoder().encode([broken, older])
            )
        }

        let succeeded = await coordinator.transferClipboardFiles(using: clipboardService, maximumBytes: 1_024)

        XCTAssertFalse(succeeded)
        XCTAssertEqual(log.snapshot, ["POST /sync/api/history/query"])
        XCTAssertEqual(
            diagnostics.lastError,
            SyncClipboardError.historyDataMissing(try broken.profileID).localizedDescription
        )
    }

    @MainActor
    func testDeletedHistoryIsRestoredWithPayloadAndIncrementedVersion() async throws {
        let log = RequestLog()
        let httpClient = SyncClipboardHTTPClient(session: makeMockSession())
        let coordinator = SyncCoordinator(httpClient: httpClient, notifier: UserNotifier())
        let clipboardService = FakeClipboardService()
        let local = ClipboardSnapshot.image(pngData: Data([1, 2, 3]))
        var deleted = makeHistoryRecord(
            type: .image,
            hash: local.hash,
            text: try XCTUnwrap(local.dataName),
            size: 3,
            hasData: false,
            version: 7,
            isDeleted: true
        )
        deleted.starred = true
        deleted.pinned = true
        var restored = makeHistoryRecord(
            type: .image,
            hash: local.hash,
            text: try XCTUnwrap(local.dataName),
            size: 3,
            version: 8
        )
        restored.starred = true
        restored.pinned = true
        let deletedRecord = deleted
        let restoredRecord = restored
        let profileID = try restoredRecord.profileID
        coordinator.updatePreferences(syncEnabled: true, showNotifications: false)
        clipboardService.nextSnapshot = local
        httpClient.updateConfiguration(ServerConfiguration(
            baseURL: URL(string: "https://example.com/sync/")!,
            username: "alice",
            password: "secret"
        ))
        MockURLProtocol.requestHandler = { request in
            let url = try XCTUnwrap(request.url)
            log.append("\(request.httpMethod ?? "GET") \(url.path)")
            switch (request.httpMethod, url.path) {
            case ("GET", "/sync/api/history/\(profileID)"):
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    try JSONEncoder().encode(deletedRecord)
                )
            case ("GET", "/sync/api/time"):
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    try JSONEncoder().encode(HistoryDateCodec.string(from: Date()))
                )
            case ("POST", "/sync/api/history"):
                let body = String(decoding: try requestBody(request), as: UTF8.self)
                XCTAssertTrue(body.contains("name=\"version\"\r\n\r\n8\r\n"))
                XCTAssertTrue(body.contains("name=\"isDeleted\"\r\n\r\nfalse\r\n"))
                XCTAssertTrue(body.contains("name=\"starred\"\r\n\r\ntrue\r\n"))
                XCTAssertTrue(body.contains("name=\"pinned\"\r\n\r\ntrue\r\n"))
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    try JSONEncoder().encode(restoredRecord)
                )
            case ("POST", "/sync/api/history/query"):
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    try JSONEncoder().encode([restoredRecord])
                )
            case ("GET", "/sync/SyncClipboard.json"):
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    try JSONEncoder().encode(ProfileDTO(type: .text, hash: "text", text: "text"))
                )
            case ("PUT", "/sync/SyncClipboard.json"):
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "GET") \(url.path)")
                return (HTTPURLResponse(url: url, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
            }
        }

        let succeeded = await coordinator.transferClipboardFiles(using: clipboardService, maximumBytes: 1_024)
        XCTAssertTrue(succeeded)
        XCTAssertEqual(log.snapshot, [
            "GET /sync/api/history/\(profileID)",
            "GET /sync/api/time",
            "POST /sync/api/history",
            "POST /sync/api/history/query",
            "GET /sync/SyncClipboard.json",
            "PUT /sync/SyncClipboard.json",
        ])
    }

    @MainActor
    func testOfficialGroupDownloadsByRemoteProfileIDWithoutHashingZIP() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("file".utf8).write(to: source.appendingPathComponent("file.txt"))
        let archive = try await FileTransfer.prepareUpload(urls: [source], maximumBytes: 1_024 * 1_024)
        defer { archive.cleanup() }
        let payload = try Data(contentsOf: archive.url)
        let group = makeHistoryRecord(
            type: .group,
            hash: String(repeating: "E", count: 64),
            text: "folder\nfile.txt",
            size: Int64(payload.count)
        )
        let profileID = try group.profileID
        let log = RequestLog()
        let httpClient = SyncClipboardHTTPClient(session: makeMockSession())
        let coordinator = SyncCoordinator(httpClient: httpClient, notifier: UserNotifier(), downloadsDirectory: root)
        let clipboardService = FakeClipboardService()
        coordinator.updatePreferences(syncEnabled: true, showNotifications: false)
        httpClient.updateConfiguration(ServerConfiguration(
            baseURL: URL(string: "https://example.com/sync/")!,
            username: "alice",
            password: "secret"
        ))
        MockURLProtocol.requestHandler = { request in
            let url = try XCTUnwrap(request.url)
            log.append("\(request.httpMethod ?? "GET") \(url.path)")
            if url.path.hasSuffix("/query") {
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    try JSONEncoder().encode([group])
                )
            }
            XCTAssertEqual(url.path, "/sync/api/history/\(profileID)/data")
            return (
                HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Disposition": "attachment; filename=bundle"]
                )!,
                payload
            )
        }

        let succeeded = await coordinator.transferClipboardFiles(using: clipboardService, maximumBytes: 1_024 * 1_024)
        XCTAssertTrue(succeeded)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("bundle.zip")), payload)
        XCTAssertEqual(log.snapshot.filter { $0.contains(profileID) }.count, 1)
    }

    @MainActor
    func testInvalidGroupArchiveIsRejectedBeforeSaving() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let group = makeHistoryRecord(
            type: .group,
            hash: String(repeating: "E", count: 64),
            text: "folder\nfile.txt",
            size: 4
        )
        let httpClient = SyncClipboardHTTPClient(session: makeMockSession())
        let coordinator = SyncCoordinator(httpClient: httpClient, notifier: UserNotifier(), downloadsDirectory: root)
        let clipboardService = FakeClipboardService()
        var diagnostics = SyncDiagnostics()
        coordinator.diagnosticsHandler = { diagnostics = $0 }
        coordinator.updatePreferences(syncEnabled: true, showNotifications: false)
        httpClient.updateConfiguration(ServerConfiguration(
            baseURL: URL(string: "https://example.com/sync/")!,
            username: "alice",
            password: "secret"
        ))
        MockURLProtocol.requestHandler = { request in
            let url = try XCTUnwrap(request.url)
            if url.path.hasSuffix("/query") {
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    try JSONEncoder().encode([group])
                )
            }
            return (
                HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Disposition": "attachment; filename=broken.zip"]
                )!,
                Data("PK00".utf8)
            )
        }

        let succeeded = await coordinator.transferClipboardFiles(using: clipboardService, maximumBytes: 1_024)

        XCTAssertFalse(succeeded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("broken.zip").path))
        XCTAssertEqual(diagnostics.lastError, SyncClipboardError.historyArchiveInvalid.localizedDescription)
    }

    @MainActor
    func testDownloadedImageProvenancePreventsFalseReupload() async throws {
        let bytes = Data([1, 2, 3])
        let remote = makeHistoryRecord(
            type: .image,
            hash: Hashing.fileProfileHash(fileName: "remote.png", fileData: bytes),
            text: "remote.png",
            size: 3
        )
        let profileID = try remote.profileID
        let log = RequestLog()
        let httpClient = SyncClipboardHTTPClient(session: makeMockSession())
        let coordinator = SyncCoordinator(httpClient: httpClient, notifier: UserNotifier())
        let clipboardService = FakeClipboardService()
        coordinator.updatePreferences(syncEnabled: true, showNotifications: false)
        httpClient.updateConfiguration(ServerConfiguration(
            baseURL: URL(string: "https://example.com/sync/")!,
            username: "alice",
            password: "secret"
        ))
        MockURLProtocol.requestHandler = { request in
            let url = try XCTUnwrap(request.url)
            log.append("\(request.httpMethod ?? "GET") \(url.path)")
            if url.path.hasSuffix("/query") {
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    try JSONEncoder().encode([remote])
                )
            }
            if request.httpMethod == "GET", url.path.hasSuffix("/SyncClipboard.json") {
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    try JSONEncoder().encode(ProfileDTO(type: .image, hash: remote.normalizedHash, text: remote.text))
                )
            }
            if request.httpMethod == "PUT" {
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
            }
            XCTAssertEqual(url.path, "/sync/api/history/\(profileID)/data")
            return (
                HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Disposition": "attachment; filename=remote.png"]
                )!,
                bytes
            )
        }

        let first = await coordinator.transferClipboardFiles(using: clipboardService, maximumBytes: 1_024)
        XCTAssertTrue(first)
        clipboardService.nextSnapshot = .image(pngData: bytes)
        log.clear()

        let second = await coordinator.transferClipboardFiles(using: clipboardService, maximumBytes: 1_024)
        XCTAssertTrue(second)
        XCTAssertEqual(log.snapshot, ["POST /sync/api/history/query", "GET /sync/SyncClipboard.json"])
    }

    @MainActor
    func testDownloadRetriesOnceWhenHistoryHeadChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = RequestLog()
        let first = makeHistoryRecord(
            hash: Hashing.fileProfileHash(fileName: "first.bin", fileData: Data("first".utf8)),
            text: "first.bin",
            size: 5
        )
        let second = makeHistoryRecord(
            hash: Hashing.fileProfileHash(fileName: "second.bin", fileData: Data("second".utf8)),
            text: "second.bin",
            date: Date(timeIntervalSince1970: 1_700_000_001),
            size: 6
        )
        let httpClient = SyncClipboardHTTPClient(session: makeMockSession())
        let coordinator = SyncCoordinator(httpClient: httpClient, notifier: UserNotifier(), downloadsDirectory: root)
        let clipboardService = FakeClipboardService()
        coordinator.updatePreferences(syncEnabled: true, showNotifications: false)
        httpClient.updateConfiguration(ServerConfiguration(
            baseURL: URL(string: "https://example.com/sync/")!,
            username: "alice",
            password: "secret"
        ))
        MockURLProtocol.requestHandler = { request in
            let url = try XCTUnwrap(request.url)
            log.append("\(request.httpMethod ?? "GET") \(url.path)")
            if url.path.hasSuffix("/query") {
                let queryCount = log.snapshot.filter { $0.hasSuffix("/query") }.count
                let record = queryCount == 1 ? first : second
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    try JSONEncoder().encode([record])
                )
            }
            let isFirst = url.path.contains(try first.profileID)
            let name = isFirst ? "first.bin" : "second.bin"
            let data = Data((isFirst ? "first" : "second").utf8)
            return (
                HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Disposition": "attachment; filename=\(name)"]
                )!,
                data
            )
        }

        let succeeded = await coordinator.transferClipboardFiles(using: clipboardService, maximumBytes: 1_024)
        XCTAssertTrue(succeeded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("first.bin").path))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("second.bin")), Data("second".utf8))
        XCTAssertEqual(log.snapshot.filter { $0.hasSuffix("/query") }.count, 3)
    }

    @MainActor
    func testCorruptedHistoryDownloadIsRejectedBeforeSaving() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let expected = Data("good".utf8)
        let remote = makeHistoryRecord(
            hash: Hashing.fileProfileHash(fileName: "payload.bin", fileData: expected),
            text: "payload.bin",
            size: 4
        )
        let httpClient = SyncClipboardHTTPClient(session: makeMockSession())
        let coordinator = SyncCoordinator(httpClient: httpClient, notifier: UserNotifier(), downloadsDirectory: root)
        let clipboardService = FakeClipboardService()
        var diagnostics = SyncDiagnostics()
        coordinator.diagnosticsHandler = { diagnostics = $0 }
        coordinator.updatePreferences(syncEnabled: true, showNotifications: false)
        httpClient.updateConfiguration(ServerConfiguration(
            baseURL: URL(string: "https://example.com/sync/")!,
            username: "alice",
            password: "secret"
        ))
        MockURLProtocol.requestHandler = { request in
            let url = try XCTUnwrap(request.url)
            if url.path.hasSuffix("/query") {
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    try JSONEncoder().encode([remote])
                )
            }
            return (
                HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Disposition": "attachment; filename=payload.bin"]
                )!,
                Data("evil".utf8)
            )
        }

        let succeeded = await coordinator.transferClipboardFiles(using: clipboardService, maximumBytes: 1_024)

        XCTAssertFalse(succeeded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("payload.bin").path))
        XCTAssertEqual(diagnostics.lastError, SyncClipboardError.historyDownloadHashMismatch.localizedDescription)
    }

    @MainActor
    func testFileDownloadReceiptSkipsRepeatDownload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = RequestLog()
        let httpClient = SyncClipboardHTTPClient(session: makeMockSession())
        let coordinator = SyncCoordinator(httpClient: httpClient, notifier: UserNotifier(), downloadsDirectory: root)
        let clipboardService = FakeClipboardService()
        clipboardService.nextSnapshot = .text("local text remains in the clipboard")
        let payload = Data("file".utf8)
        let profile = makeHistoryRecord(
            type: .file,
            hash: Hashing.fileProfileHash(fileName: "report.pdf", fileData: payload),
            text: "report.pdf",
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
            log.append("\(request.httpMethod ?? "GET") \(url.path)")
            if url.path.hasSuffix("/query") {
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    try JSONEncoder().encode([profile])
                )
            }
            return (
                HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Disposition": "attachment; filename=report.pdf"]
                )!,
                payload
            )
        }

        let first = await coordinator.transferClipboardFiles(using: clipboardService, maximumBytes: 1_024)
        XCTAssertTrue(first)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("report.pdf")), payload)

        log.clear()
        let second = await coordinator.transferClipboardFiles(using: clipboardService, maximumBytes: 1_024)
        XCTAssertTrue(second)
        XCTAssertEqual(log.snapshot, ["POST /sync/api/history/query"])
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("report.pdf")), payload)
    }

    @MainActor
    func testDownloadFailsWhenHistoryHeadChangesRepeatedly() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = RequestLog()
        let first = makeHistoryRecord(
            type: .file,
            hash: Hashing.fileProfileHash(fileName: "first.bin", fileData: Data("first".utf8)),
            text: "first.bin",
            size: 5
        )
        let second = makeHistoryRecord(
            type: .file,
            hash: Hashing.fileProfileHash(fileName: "second.bin", fileData: Data("second".utf8)),
            text: "second.bin",
            date: Date(timeIntervalSince1970: 1_700_000_001),
            size: 6
        )
        let third = makeHistoryRecord(
            type: .file,
            hash: Hashing.fileProfileHash(fileName: "third.bin", fileData: Data("third".utf8)),
            text: "third.bin",
            date: Date(timeIntervalSince1970: 1_700_000_002),
            size: 5
        )
        let httpClient = SyncClipboardHTTPClient(session: makeMockSession())
        let coordinator = SyncCoordinator(httpClient: httpClient, notifier: UserNotifier(), downloadsDirectory: root)
        let clipboardService = FakeClipboardService()
        var diagnostics = SyncDiagnostics()
        coordinator.diagnosticsHandler = { diagnostics = $0 }
        coordinator.updatePreferences(syncEnabled: true, showNotifications: false)
        httpClient.updateConfiguration(ServerConfiguration(
            baseURL: URL(string: "https://example.com/sync/")!,
            username: "alice",
            password: "secret"
        ))
        MockURLProtocol.requestHandler = { request in
            let url = try XCTUnwrap(request.url)
            log.append("\(request.httpMethod ?? "GET") \(url.path)")
            if url.path.hasSuffix("/query") {
                let queryCount = log.snapshot.filter { $0.hasSuffix("/query") }.count
                let record = queryCount == 1 ? first : (queryCount == 2 ? second : third)
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    try JSONEncoder().encode([record])
                )
            }
            if url.path.contains(try first.profileID) {
                return (
                    HTTPURLResponse(
                        url: url,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Disposition": "attachment; filename=first.bin"]
                    )!,
                    Data("first".utf8)
                )
            }
            if url.path.contains(try second.profileID) {
                return (
                    HTTPURLResponse(
                        url: url,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Disposition": "attachment; filename=second.bin"]
                    )!,
                    Data("second".utf8)
                )
            }
            XCTFail("Unexpected request: \(request.httpMethod ?? "GET") \(url.path)")
            return (HTTPURLResponse(url: url, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
        }

        let succeeded = await coordinator.transferClipboardFiles(using: clipboardService, maximumBytes: 1_024)

        XCTAssertFalse(succeeded)
        XCTAssertEqual(log.snapshot.filter { $0.hasSuffix("/query") }.count, 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("first.bin").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("second.bin").path))
        XCTAssertEqual(diagnostics.lastError, SyncClipboardError.historyChangedDuringTransfer.localizedDescription)
    }

    @MainActor
    func testDownloadIsDiscardedWhenServerConfigurationChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let httpClient = SyncClipboardHTTPClient(session: makeMockSession())
        let coordinator = SyncCoordinator(httpClient: httpClient, notifier: UserNotifier(), downloadsDirectory: root)
        let clipboardService = FakeClipboardService()
        let payload = Data("file".utf8)
        let profile = makeHistoryRecord(
            type: .file,
            hash: Hashing.fileProfileHash(fileName: "report.pdf", fileData: payload),
            text: "report.pdf",
            size: 4
        )
        var diagnostics = SyncDiagnostics()
        coordinator.diagnosticsHandler = { diagnostics = $0 }
        coordinator.updatePreferences(syncEnabled: true, showNotifications: false)
        httpClient.updateConfiguration(ServerConfiguration(
            baseURL: URL(string: "https://example.com/sync/")!,
            username: "alice",
            password: "secret"
        ))
        let changedConfiguration = ServerConfiguration(
            baseURL: URL(string: "https://example.com/sync/")!,
            username: "bob",
            password: "secret"
        )
        MockURLProtocol.requestHandler = { request in
            let url = try XCTUnwrap(request.url)
            if url.path.hasSuffix("/query") {
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    try JSONEncoder().encode([profile])
                )
            }
            // Simulate the user saving new server settings while the download is in flight.
            Task { @MainActor in
                httpClient.updateConfiguration(changedConfiguration)
            }
            return (
                HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Disposition": "attachment; filename=report.pdf"]
                )!,
                payload
            )
        }

        let succeeded = await coordinator.transferClipboardFiles(using: clipboardService, maximumBytes: 1_024)

        XCTAssertFalse(succeeded)
        XCTAssertEqual(diagnostics.lastError, SyncClipboardError.serverConfigurationChanged.localizedDescription)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("report.pdf").path))
    }

    @MainActor
    func testHistoryPaginationContinuesPastFullPageOfDeletedRecords() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = RequestLog()
        let payload = Data("file".utf8)
        let valid = makeHistoryRecord(
            type: .file,
            hash: Hashing.fileProfileHash(fileName: "report.pdf", fileData: payload),
            text: "report.pdf",
            size: 4
        )
        let deleted: [HistoryRecordDTO] = (0 ..< 50).map { index in
            let suffix = String(index, radix: 16).uppercased()
            return makeHistoryRecord(
                hash: String(repeating: "0", count: 64 - suffix.count) + suffix,
                text: "deleted-\(index).bin",
                isDeleted: true
            )
        }
        let httpClient = SyncClipboardHTTPClient(session: makeMockSession())
        let coordinator = SyncCoordinator(httpClient: httpClient, notifier: UserNotifier(), downloadsDirectory: root)
        let clipboardService = FakeClipboardService()
        coordinator.updatePreferences(syncEnabled: true, showNotifications: false)
        httpClient.updateConfiguration(ServerConfiguration(
            baseURL: URL(string: "https://example.com/sync/")!,
            username: "alice",
            password: "secret"
        ))
        MockURLProtocol.requestHandler = { request in
            let url = try XCTUnwrap(request.url)
            log.append("\(request.httpMethod ?? "GET") \(url.path)")
            if url.path.hasSuffix("/query") {
                let body = String(decoding: try requestBody(request), as: UTF8.self)
                let records = body.contains("Page=2") ? [valid] : deleted
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    try JSONEncoder().encode(records)
                )
            }
            return (
                HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Disposition": "attachment; filename=report.pdf"]
                )!,
                payload
            )
        }

        let succeeded = await coordinator.transferClipboardFiles(using: clipboardService, maximumBytes: 1_024)

        XCTAssertTrue(succeeded)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("report.pdf")), payload)
        XCTAssertEqual(log.snapshot.filter { $0.hasSuffix("/query") }.count, 4)
    }

    @MainActor
    func testLocalEventTimeIsCorrectedByServerClockOffset() async throws {
        let httpClient = SyncClipboardHTTPClient(session: makeMockSession())
        let coordinator = SyncCoordinator(httpClient: httpClient, notifier: UserNotifier())
        let clipboardService = FakeClipboardService()
        let local = ClipboardSnapshot.image(pngData: Data([1, 2, 3]))
        let history = makeHistoryRecord(
            type: .image,
            hash: local.hash,
            text: try XCTUnwrap(local.dataName),
            size: 3
        )
        let profileID = try history.profileID
        let observation = Date().addingTimeInterval(-600)
        let serverOffset: TimeInterval = 3_600
        coordinator.updatePreferences(syncEnabled: true, showNotifications: false)
        clipboardService.nextSnapshot = local
        clipboardService.changeCount = 7
        httpClient.updateConfiguration(ServerConfiguration(
            baseURL: URL(string: "https://example.com/sync/")!,
            username: "alice",
            password: "secret"
        ))
        MockURLProtocol.requestHandler = { request in
            let url = try XCTUnwrap(request.url)
            switch (request.httpMethod, url.path) {
            case ("GET", "/sync/api/history/\(profileID)"):
                return (HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
            case ("GET", "/sync/api/time"):
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    try JSONEncoder().encode(HistoryDateCodec.string(from: Date().addingTimeInterval(serverOffset)))
                )
            case ("POST", "/sync/api/history"):
                let body = String(decoding: try requestBody(request), as: UTF8.self)
                let expected = observation.addingTimeInterval(serverOffset)
                for field in ["createTime", "lastModified", "lastAccessed"] {
                    let value = try HistoryDateCodec.date(from: multipartField(field, in: body))
                    XCTAssertEqual(value.timeIntervalSince(expected), 0, accuracy: 10)
                }
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    try JSONEncoder().encode(history)
                )
            case ("POST", "/sync/api/history/query"):
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    try JSONEncoder().encode([history])
                )
            case ("GET", "/sync/SyncClipboard.json"):
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    try JSONEncoder().encode(ProfileDTO(type: .text, hash: "text", text: "text"))
                )
            case ("PUT", "/sync/SyncClipboard.json"):
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "GET") \(url.path)")
                return (HTTPURLResponse(url: url, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
            }
        }

        await coordinator.handleLocalPasteboardChange(using: clipboardService, changeCount: 7, observedAt: observation)
        let succeeded = await coordinator.transferClipboardFiles(using: clipboardService, maximumBytes: 1_024)
        XCTAssertTrue(succeeded)
    }

    @MainActor
    func testRemoteDeclaredSizeAboveLimitFailsBeforeDownload() async throws {
        let log = RequestLog()
        let httpClient = SyncClipboardHTTPClient(session: makeMockSession())
        let coordinator = SyncCoordinator(httpClient: httpClient, notifier: UserNotifier())
        let clipboardService = FakeClipboardService()
        let profile = makeHistoryRecord(
            type: .file,
            hash: Hashing.fileProfileHash(fileName: "big.bin", fileData: Data("big".utf8)),
            text: "big.bin",
            size: 2_048
        )
        var diagnostics = SyncDiagnostics()
        coordinator.diagnosticsHandler = { diagnostics = $0 }
        coordinator.updatePreferences(syncEnabled: true, showNotifications: false)
        httpClient.updateConfiguration(ServerConfiguration(
            baseURL: URL(string: "https://example.com/sync/")!,
            username: "alice",
            password: "secret"
        ))
        MockURLProtocol.requestHandler = { request in
            let url = try XCTUnwrap(request.url)
            log.append("\(request.httpMethod ?? "GET") \(url.path)")
            XCTAssertTrue(url.path.hasSuffix("/query"))
            return (
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                try JSONEncoder().encode([profile])
            )
        }

        let succeeded = await coordinator.transferClipboardFiles(using: clipboardService, maximumBytes: 1_024)

        XCTAssertFalse(succeeded)
        XCTAssertEqual(log.snapshot, ["POST /sync/api/history/query"])
        XCTAssertEqual(diagnostics.lastError, SyncClipboardError.transferTooLarge(1_024).localizedDescription)
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
        XCTAssertTrue(launchManager.requestedValues.isEmpty)
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
        XCTAssertEqual(launchManager.requestedValues, [true])
    }

    func testLaunchAtLoginUpdatesOnlyForDefiniteStateChanges() {
        XCTAssertFalse(AppModel.shouldUpdateLaunchAtLogin(requested: false, status: .disabled))
        XCTAssertFalse(AppModel.shouldUpdateLaunchAtLogin(requested: true, status: .enabled))
        XCTAssertFalse(AppModel.shouldUpdateLaunchAtLogin(requested: false, status: .requiresApproval))
        XCTAssertFalse(AppModel.shouldUpdateLaunchAtLogin(requested: true, status: .requiresApproval))
        XCTAssertTrue(AppModel.shouldUpdateLaunchAtLogin(requested: true, status: .disabled))
        XCTAssertTrue(AppModel.shouldUpdateLaunchAtLogin(requested: false, status: .enabled))
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
