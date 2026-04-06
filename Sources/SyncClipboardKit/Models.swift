import Foundation

public let textTransferThreshold = 10_240

public enum ProfileType: String, Codable, Sendable, CaseIterable {
    case text = "Text"
    case file = "File"
    case image = "Image"
    case group = "Group"
    case unknown = "Unknown"
    case none = "None"
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var serverURL: String
    public var username: String
    public var keychainAccount: String
    public var syncEnabled: Bool
    public var launchAtLogin: Bool
    public var showNotifications: Bool

    public init(
        serverURL: String = "",
        username: String = "",
        keychainAccount: String = "default",
        syncEnabled: Bool = false,
        launchAtLogin: Bool = false,
        showNotifications: Bool = true
    ) {
        self.serverURL = serverURL
        self.username = username
        self.keychainAccount = keychainAccount
        self.syncEnabled = syncEnabled
        self.launchAtLogin = launchAtLogin
        self.showNotifications = showNotifications
    }
}

public struct ServerConfiguration: Equatable, Sendable {
    public let baseURL: URL
    public let username: String
    public let password: String

    public init(baseURL: URL, username: String, password: String) {
        self.baseURL = baseURL
        self.username = username
        self.password = password
    }
}

public struct ProfileDTO: Codable, Equatable, Sendable {
    public var type: ProfileType
    public var hash: String
    public var text: String
    public var hasData: Bool
    public var dataName: String?
    public var size: Int64

    public init(
        type: ProfileType = .text,
        hash: String = "",
        text: String = "",
        hasData: Bool = false,
        dataName: String? = nil,
        size: Int64 = 0
    ) {
        self.type = type
        self.hash = hash
        self.text = text
        self.hasData = hasData
        self.dataName = dataName
        self.size = size
    }
}

public enum ClipboardPayload: Equatable, Sendable {
    case text(String)
    case image(Data)
}

public enum SyncClipboardError: LocalizedError, Sendable {
    case missingServerConfiguration
    case unsupportedRemoteType(ProfileType)
    case missingTransferData(ProfileType)
    case invalidTextEncoding
    case invalidImageData
    case unexpectedResponse(Int)

    public var errorDescription: String? {
        switch self {
        case .missingServerConfiguration:
            return "Server configuration is incomplete."
        case .unsupportedRemoteType(let type):
            return "Unsupported clipboard type: \(type.rawValue)."
        case .missingTransferData(let type):
            return "Missing transfer data for \(type.rawValue)."
        case .invalidTextEncoding:
            return "Text transfer data is not valid UTF-8."
        case .invalidImageData:
            return "Image data could not be decoded."
        case .unexpectedResponse(let statusCode):
            return "Unexpected HTTP status code: \(statusCode)."
        }
    }
}

public struct ClipboardSnapshot: Equatable, Sendable {
    public let type: ProfileType
    public let hash: String
    public let previewText: String
    public let inlineText: String?
    public let transferData: Data?
    public let dataName: String?
    public let size: Int64

    public init(
        type: ProfileType,
        hash: String,
        previewText: String,
        inlineText: String?,
        transferData: Data?,
        dataName: String?,
        size: Int64
    ) {
        self.type = type
        self.hash = hash
        self.previewText = previewText
        self.inlineText = inlineText
        self.transferData = transferData
        self.dataName = dataName
        self.size = size
    }

    public var fingerprint: String {
        let fallback = hash.isEmpty ? previewText : hash
        return "\(type.rawValue)|\(fallback)"
    }

    public var payload: ClipboardPayload {
        switch type {
        case .text:
            return .text(inlineText ?? String(decoding: transferData ?? Data(), as: UTF8.self))
        case .image:
            return .image(transferData ?? Data())
        default:
            return .text(previewText)
        }
    }

    public var profileDTO: ProfileDTO {
        ProfileDTO(
            type: type,
            hash: hash,
            text: previewText,
            hasData: transferData != nil,
            dataName: dataName,
            size: size
        )
    }

    public static func text(_ fullText: String) -> ClipboardSnapshot {
        let hash = Hashing.sha256Hex(of: fullText)
        if fullText.count > textTransferThreshold {
            let preview = String(fullText.prefix(textTransferThreshold))
            return ClipboardSnapshot(
                type: .text,
                hash: hash,
                previewText: preview,
                inlineText: nil,
                transferData: Data(fullText.utf8),
                dataName: "text-\(hash).txt",
                size: Int64(fullText.count)
            )
        }

        return ClipboardSnapshot(
            type: .text,
            hash: hash,
            previewText: fullText,
            inlineText: fullText,
            transferData: nil,
            dataName: nil,
            size: Int64(fullText.count)
        )
    }

    public static func image(pngData: Data) -> ClipboardSnapshot {
        let contentHash = Hashing.sha256Hex(of: pngData)
        let dataName = "image-\(contentHash).png"
        let finalHash = Hashing.fileProfileHash(fileName: dataName, fileData: pngData)

        return ClipboardSnapshot(
            type: .image,
            hash: finalHash,
            previewText: dataName,
            inlineText: nil,
            transferData: pngData,
            dataName: dataName,
            size: Int64(pngData.count)
        )
    }

    public static func fromRemote(dto: ProfileDTO, transferData: Data?) throws -> ClipboardSnapshot {
        switch dto.type {
        case .text:
            if dto.hasData {
                guard let transferData else {
                    throw SyncClipboardError.missingTransferData(.text)
                }
                guard let fullText = String(data: transferData, encoding: .utf8) else {
                    throw SyncClipboardError.invalidTextEncoding
                }
                return ClipboardSnapshot(
                    type: .text,
                    hash: dto.hash.isEmpty ? Hashing.sha256Hex(of: fullText) : dto.hash,
                    previewText: dto.text,
                    inlineText: nil,
                    transferData: transferData,
                    dataName: dto.dataName,
                    size: dto.size == 0 ? Int64(fullText.count) : dto.size
                )
            }

            return ClipboardSnapshot(
                type: .text,
                hash: dto.hash.isEmpty ? Hashing.sha256Hex(of: dto.text) : dto.hash,
                previewText: dto.text,
                inlineText: dto.text,
                transferData: nil,
                dataName: nil,
                size: dto.size == 0 ? Int64(dto.text.count) : dto.size
            )

        case .image:
            guard let transferData else {
                throw SyncClipboardError.missingTransferData(.image)
            }
            let localImage = ClipboardSnapshot.image(pngData: transferData)
            return ClipboardSnapshot(
                type: .image,
                hash: dto.hash.isEmpty ? localImage.hash : dto.hash,
                previewText: dto.text,
                inlineText: nil,
                transferData: transferData,
                dataName: dto.dataName ?? localImage.dataName,
                size: dto.size == 0 ? Int64(transferData.count) : dto.size
            )

        default:
            throw SyncClipboardError.unsupportedRemoteType(dto.type)
        }
    }
}
