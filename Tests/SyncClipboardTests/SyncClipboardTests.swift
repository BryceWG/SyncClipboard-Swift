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

    var snapshot: [String] {
        lock.lock()
        defer { lock.unlock() }
        return entries
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

    private func makeMockSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}
#endif
