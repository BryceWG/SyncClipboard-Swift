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
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SyncClipboardError.unexpectedResponse(-1)
        }
        guard (200 ... 299).contains(httpResponse.statusCode) else {
            throw SyncClipboardError.unexpectedResponse(httpResponse.statusCode)
        }
        return (data, httpResponse)
    }

    private func requireConfiguration() throws -> ServerConfiguration {
        guard let configuration else {
            throw SyncClipboardError.missingServerConfiguration
        }
        return configuration
    }
}
