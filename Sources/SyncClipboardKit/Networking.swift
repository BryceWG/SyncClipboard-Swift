import Foundation

public struct ServerAuth: Sendable {
    public let username: String
    public let password: String

    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }

    public var authorizationHeader: String {
        let raw = "\(username):\(password)"
        return "Basic \(Data(raw.utf8).base64EncodedString())"
    }
}

@MainActor
public final class SyncClipboardHTTPClient {
    private let session: URLSession
    public var configuration: ServerConfiguration?

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func updateConfiguration(_ configuration: ServerConfiguration?) {
        self.configuration = configuration
    }

    public func testConnection() async throws {
        let configuration = try requireConfiguration()
        let auth = ServerAuth(username: configuration.username, password: configuration.password)

        let timeRequest = Self.makeRequest(
            baseURL: configuration.baseURL,
            path: "api/time",
            method: "GET",
            auth: auth
        )
        _ = try await perform(timeRequest)

        if configuration.receiveMode == .realtime {
            let hubRequest = Self.makeRequest(
                url: SignalRConnectionMetadata.hubNegotiateURL(for: configuration.baseURL),
                method: "POST",
                auth: auth
            )
            _ = try await perform(hubRequest)
        }
    }

    public func fetchCurrentProfile() async throws -> ProfileDTO {
        let configuration = try requireConfiguration()
        return try await fetchCurrentProfile(configuration: configuration)
    }

    public func fetchCurrentProfile(
        configuration: ServerConfiguration
    ) async throws -> ProfileDTO {
        let request = Self.makeRequest(
            baseURL: configuration.baseURL,
            path: "SyncClipboard.json",
            method: "GET",
            auth: ServerAuth(username: configuration.username, password: configuration.password)
        )
        let (data, _) = try await perform(request)
        return try JSONDecoder().decode(ProfileDTO.self, from: data)
    }

    public func setCurrentProfile(_ profile: ProfileDTO) async throws {
        let configuration = try requireConfiguration()
        try await setCurrentProfile(profile, configuration: configuration)
    }

    public func setCurrentProfile(
        _ profile: ProfileDTO,
        configuration: ServerConfiguration
    ) async throws {
        let body = try JSONEncoder().encode(profile)
        let request = Self.makeRequest(
            baseURL: configuration.baseURL,
            path: "SyncClipboard.json",
            method: "PUT",
            auth: ServerAuth(username: configuration.username, password: configuration.password),
            body: body,
            contentType: "application/json"
        )
        _ = try await perform(request)
    }

    public func uploadFile(data: Data, name: String, mimeType: String) async throws {
        let configuration = try requireConfiguration()
        let encodedName = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        let request = Self.makeRequest(
            baseURL: configuration.baseURL,
            path: "file/\(encodedName)",
            method: "PUT",
            auth: ServerAuth(username: configuration.username, password: configuration.password),
            body: data,
            contentType: mimeType
        )
        _ = try await perform(request)
    }

    public func uploadFile(at fileURL: URL, name: String, mimeType: String) async throws {
        let configuration = try requireConfiguration()
        let encodedName = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        let request = Self.makeRequest(
            baseURL: configuration.baseURL,
            path: "file/\(encodedName)",
            method: "PUT",
            auth: ServerAuth(username: configuration.username, password: configuration.password),
            contentType: mimeType
        )
        let (_, response) = try await session.upload(for: request, fromFile: fileURL)
        try Self.validate(response)
    }

    public func downloadFile(named name: String) async throws -> Data {
        let configuration = try requireConfiguration()
        let encodedName = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        let request = Self.makeRequest(
            baseURL: configuration.baseURL,
            path: "file/\(encodedName)",
            method: "GET",
            auth: ServerAuth(username: configuration.username, password: configuration.password)
        )
        let (data, _) = try await perform(request)
        return data
    }

    public func downloadFile(named name: String, maximumBytes: Int64) async throws -> URL {
        let configuration = try requireConfiguration()
        let encodedName = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        let request = Self.makeRequest(
            baseURL: configuration.baseURL,
            path: "file/\(encodedName)",
            method: "GET",
            auth: ServerAuth(username: configuration.username, password: configuration.password)
        )
        return try await LimitedFileDownloader(maximumBytes: maximumBytes)
            .download(request: request, configuration: session.configuration).url
    }

    public func fetchServerTime(configuration: ServerConfiguration) async throws -> Date {
        let request = Self.makeRequest(
            baseURL: configuration.baseURL,
            path: "api/time",
            method: "GET",
            auth: Self.auth(for: configuration)
        )
        let (data, _) = try await perform(request)
        let value = try JSONDecoder().decode(String.self, from: data)
        return try HistoryDateCodec.date(from: value)
    }

    public func fetchHistoryRecord(
        profileID: String,
        configuration: ServerConfiguration
    ) async throws -> HistoryRecordDTO? {
        let request = Self.makeRequest(
            baseURL: configuration.baseURL,
            path: "api/history/\(Self.encodedPathComponent(profileID))",
            method: "GET",
            auth: Self.auth(for: configuration)
        )
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw SyncClipboardError.unexpectedResponse(-1)
        }
        if response.statusCode == 404 {
            return nil
        }
        try Self.validate(response)
        return try JSONDecoder().decode(HistoryRecordDTO.self, from: data)
    }

    public func fetchHistoryPage(
        page: Int,
        configuration: ServerConfiguration
    ) async throws -> [HistoryRecordDTO] {
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "Page", value: String(max(1, page))),
            URLQueryItem(name: "Types", value: "File, Image, Group"),
            URLQueryItem(name: "SortByLastAccessed", value: "true"),
        ]
        let body = Data((components.percentEncodedQuery ?? "").utf8)
        let request = Self.makeRequest(
            baseURL: configuration.baseURL,
            path: "api/history/query",
            method: "POST",
            auth: Self.auth(for: configuration),
            body: body,
            contentType: "application/x-www-form-urlencoded"
        )
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw SyncClipboardError.unexpectedResponse(-1)
        }
        if response.statusCode == 404 {
            throw SyncClipboardError.historyUnavailable
        }
        try Self.validate(response)
        return try JSONDecoder().decode([HistoryRecordDTO].self, from: data)
    }

    public func uploadHistory(
        _ record: HistoryRecordDTO,
        dataFileURL: URL,
        fileName: String,
        configuration: ServerConfiguration
    ) async throws -> HistoryRecordDTO {
        _ = try record.profileID
        let multipart = try await Task.detached {
            try HistoryMultipartBody.create(
                record: record,
                dataFileURL: dataFileURL,
                fileName: fileName
            )
        }.value
        defer { multipart.cleanup() }

        let request = Self.makeRequest(
            baseURL: configuration.baseURL,
            path: "api/history",
            method: "POST",
            auth: Self.auth(for: configuration),
            contentType: "multipart/form-data; boundary=\(multipart.boundary)"
        )
        let (data, response) = try await session.upload(for: request, fromFile: multipart.url)
        guard let response = response as? HTTPURLResponse else {
            throw SyncClipboardError.unexpectedResponse(-1)
        }
        guard (200 ... 299).contains(response.statusCode) else {
            if response.statusCode == 404 {
                throw SyncClipboardError.historyUnavailable
            }
            let message = String(decoding: data, as: UTF8.self).lowercased()
            if response.statusCode == 500, message.contains("hash mismatch") {
                throw SyncClipboardError.historyHashMismatch
            }
            throw SyncClipboardError.historyUploadFailed(response.statusCode)
        }

        let serverRecord = try JSONDecoder().decode(HistoryRecordDTO.self, from: data)
        guard try serverRecord.profileID == record.profileID else {
            throw SyncClipboardError.invalidHistoryProfile
        }
        return serverRecord
    }

    public func downloadHistoryData(
        profileID: String,
        maximumBytes: Int64,
        configuration: ServerConfiguration
    ) async throws -> DownloadedTransfer {
        let request = Self.makeRequest(
            baseURL: configuration.baseURL,
            path: "api/history/\(Self.encodedPathComponent(profileID))/data",
            method: "GET",
            auth: Self.auth(for: configuration)
        )
        return try await LimitedFileDownloader(
            maximumBytes: maximumBytes,
            notFoundError: .historyDataMissing(profileID)
        ).download(request: request, configuration: session.configuration)
    }

    public static func makeRequest(
        baseURL: URL,
        path: String,
        method: String,
        auth: ServerAuth,
        body: Data? = nil,
        contentType: String? = nil
    ) -> URLRequest {
        let baseString = baseURL.absoluteString.hasSuffix("/") ? baseURL.absoluteString : baseURL.absoluteString + "/"
        let url = URL(string: baseString + path) ?? baseURL.appending(path: path)
        return makeRequest(url: url, method: method, auth: auth, body: body, contentType: contentType)
    }

    public static func makeRequest(
        url: URL,
        method: String,
        auth: ServerAuth,
        body: Data? = nil,
        contentType: String? = nil
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 30
        request.setValue(auth.authorizationHeader, forHTTPHeaderField: "Authorization")
        request.setValue("SyncClipboard-Swift", forHTTPHeaderField: "User-Agent")
        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        let httpResponse = try Self.validate(response)
        return (data, httpResponse)
    }

    @discardableResult
    private static func validate(_ response: URLResponse) throws -> HTTPURLResponse {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SyncClipboardError.unexpectedResponse(-1)
        }
        guard (200 ... 299).contains(httpResponse.statusCode) else {
            throw SyncClipboardError.unexpectedResponse(httpResponse.statusCode)
        }
        return httpResponse
    }

    private func requireConfiguration() throws -> ServerConfiguration {
        guard let configuration else {
            throw SyncClipboardError.missingServerConfiguration
        }
        return configuration
    }

    private static func auth(for configuration: ServerConfiguration) -> ServerAuth {
        ServerAuth(username: configuration.username, password: configuration.password)
    }

    private static func encodedPathComponent(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

struct HistoryMultipartBody {
    static let metadataFieldNames = [
        "hash", "type", "createTime", "lastModified", "lastAccessed",
        "starred", "pinned", "version", "isDeleted", "text", "size",
    ]

    let url: URL
    let boundary: String

    static func create(record: HistoryRecordDTO, dataFileURL: URL, fileName: String) throws -> Self {
        let boundary = "SyncClipboard-\(UUID().uuidString)"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SyncClipboard-Multipart-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }

        do {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            let fields = [
                ("hash", record.normalizedHash),
                ("type", record.type.rawValue),
                ("createTime", HistoryDateCodec.string(from: record.createTime)),
                ("lastModified", HistoryDateCodec.string(from: record.lastModified)),
                ("lastAccessed", HistoryDateCodec.string(from: record.lastAccessed)),
                ("starred", String(record.starred)),
                ("pinned", String(record.pinned)),
                ("version", String(record.version)),
                ("isDeleted", String(record.isDeleted)),
                ("text", record.text),
                ("size", String(record.size)),
            ]

            for (name, value) in fields {
                try handle.write(contentsOf: Data(
                    "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8
                ))
            }

            let safeName = fileName
                .replacingOccurrences(of: "\\", with: "_")
                .replacingOccurrences(of: "\"", with: "_")
                .replacingOccurrences(of: "\r", with: "_")
                .replacingOccurrences(of: "\n", with: "_")
            try handle.write(contentsOf: Data(
                "--\(boundary)\r\nContent-Disposition: form-data; name=\"data\"; filename=\"\(safeName)\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8
            ))

            let source = try FileHandle(forReadingFrom: dataFileURL)
            defer { try? source.close() }
            while let data = try source.read(upToCount: 64 * 1_024), !data.isEmpty {
                try handle.write(contentsOf: data)
            }
            try handle.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
            return Self(url: url, boundary: boundary)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: url)
    }
}

private final class LimitedFileDownloader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let maximumBytes: Int64
    private let notFoundError: SyncClipboardError?
    private let temporaryURL: URL
    private let handle: FileHandle
    private let lock = NSLock()
    private var receivedBytes: Int64 = 0
    private var failure: Error?
    private var continuation: CheckedContinuation<DownloadedTransfer, Error>?
    private var session: URLSession?
    private var suggestedName: String?

    init(maximumBytes: Int64, notFoundError: SyncClipboardError? = nil) throws {
        self.maximumBytes = maximumBytes
        self.notFoundError = notFoundError
        self.temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SyncClipboard-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temporaryURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            self.handle = try FileHandle(forWritingTo: temporaryURL)
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }

    func download(request: URLRequest, configuration: URLSessionConfiguration) async throws -> DownloadedTransfer {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    try? self.handle.close()
                    try? FileManager.default.removeItem(at: self.temporaryURL)
                    continuation.resume(throwing: CancellationError())
                    return
                }

                let queue = OperationQueue()
                queue.maxConcurrentOperationCount = 1
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
                let task = session.dataTask(with: request)
                lock.withLock {
                    self.continuation = continuation
                    self.session = session
                }
                task.resume()
                if Task.isCancelled { task.cancel() }
            }
        } onCancel: {
            let session = self.lock.withLock { self.session }
            session?.invalidateAndCancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let response = response as? HTTPURLResponse else {
            failure = SyncClipboardError.unexpectedResponse(-1)
            completionHandler(.cancel)
            return
        }
        guard (200 ... 299).contains(response.statusCode) else {
            failure = response.statusCode == 404
                ? notFoundError ?? SyncClipboardError.unexpectedResponse(404)
                : SyncClipboardError.unexpectedResponse(response.statusCode)
            completionHandler(.cancel)
            return
        }
        guard response.expectedContentLength < 0 || response.expectedContentLength <= maximumBytes else {
            failure = SyncClipboardError.transferTooLarge(maximumBytes)
            completionHandler(.cancel)
            return
        }
        suggestedName = response.suggestedFilename
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil else { return }
        receivedBytes += Int64(data.count)
        guard receivedBytes <= maximumBytes else {
            failure = SyncClipboardError.transferTooLarge(maximumBytes)
            dataTask.cancel()
            return
        }

        do {
            try handle.write(contentsOf: data)
        } catch {
            failure = error
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let closeError: Error?
        do {
            try handle.close()
            closeError = nil
        } catch {
            closeError = error
        }
        let result = failure ?? error ?? closeError
        if result != nil {
            try? FileManager.default.removeItem(at: temporaryURL)
        }
        let continuation = lock.withLock { () -> CheckedContinuation<DownloadedTransfer, Error>? in
            let continuation = self.continuation
            self.continuation = nil
            self.session = nil
            return continuation
        }
        session.finishTasksAndInvalidate()
        if let result {
            continuation?.resume(throwing: result)
        } else {
            continuation?.resume(returning: DownloadedTransfer(url: temporaryURL, suggestedName: suggestedName))
        }
    }
}
