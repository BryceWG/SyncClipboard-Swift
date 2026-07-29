import CryptoKit
import Foundation

public enum Hashing {
    public static func sha256Hex(of text: String) -> String {
        sha256Hex(of: Data(text.utf8))
    }

    public static func sha256Hex(of data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02X", $0) }.joined()
    }

    public static func fileProfileHash(fileName: String, fileData: Data) -> String {
        let contentHash = sha256Hex(of: fileData)
        return sha256Hex(of: "\(fileName)|\(contentHash)")
    }

    public static func fileProfileHash(fileName: String, fileURL: URL) throws -> String {
        var hasher = SHA256()
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        while let data = try handle.read(upToCount: 64 * 1_024), !data.isEmpty {
            hasher.update(data: data)
        }

        let contentHash = hasher.finalize().map { String(format: "%02X", $0) }.joined()
        return sha256Hex(of: "\(fileName)|\(contentHash)")
    }
}
