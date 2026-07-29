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
            .download(request: request, configuration: session.configuration)
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
}

private final class LimitedFileDownloader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let maximumBytes: Int64
    private let temporaryURL: URL
    private let handle: FileHandle
    private let lock = NSLock()
    private var receivedBytes: Int64 = 0
    private var failure: Error?
    private var continuation: CheckedContinuation<URL, Error>?
    private var session: URLSession?

    init(maximumBytes: Int64) throws {
        self.maximumBytes = maximumBytes
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

    func download(request: URLRequest, configuration: URLSessionConfiguration) async throws -> URL {
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
            failure = SyncClipboardError.unexpectedResponse(response.statusCode)
            completionHandler(.cancel)
            return
        }
        guard response.expectedContentLength <= maximumBytes else {
            failure = SyncClipboardError.transferTooLarge(maximumBytes)
            completionHandler(.cancel)
            return
        }
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
        let continuation = lock.withLock { () -> CheckedContinuation<URL, Error>? in
            let continuation = self.continuation
            self.continuation = nil
            self.session = nil
            return continuation
        }
        session.finishTasksAndInvalidate()
        if let result {
            continuation?.resume(throwing: result)
        } else {
            continuation?.resume(returning: temporaryURL)
        }
    }
}
