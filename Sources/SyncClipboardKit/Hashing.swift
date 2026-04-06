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
}
