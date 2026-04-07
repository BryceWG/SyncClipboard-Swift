import Foundation
import Security

public protocol KeychainStoring {
    func readPassword(account: String) throws -> String?
    func savePassword(_ password: String, account: String) throws
    func deletePassword(account: String) throws
}

public final class KeychainStore: KeychainStoring {
    private let service: String

    public init(service: String = "xyz.jericx.SyncClipboard-Swift") {
        self.service = service
    }

    public func readPassword(account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data else {
                return nil
            }
            return String(data: data, encoding: .utf8)

        case errSecItemNotFound:
            return nil

        default:
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    public func savePassword(_ password: String, account: String) throws {
        let valueData = Data(password.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: valueData,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        if updateStatus != errSecItemNotFound {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(updateStatus))
        }

        var createQuery = query
        createQuery[kSecValueData as String] = valueData
        let createStatus = SecItemAdd(createQuery as CFDictionary, nil)
        if createStatus != errSecSuccess {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(createStatus))
        }
    }

    public func deletePassword(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }
}
