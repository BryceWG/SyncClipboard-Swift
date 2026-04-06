import Foundation
#if canImport(XCTest)
import XCTest
@testable import SyncClipboardKit

final class SyncClipboardTests: XCTestCase {
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
}
#endif
