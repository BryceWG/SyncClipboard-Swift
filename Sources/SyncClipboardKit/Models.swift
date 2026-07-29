import Foundation

public let textTransferThreshold = 10_240
public let defaultMaximumTransferSizeBytes: Int64 = 100 * 1_024 * 1_024
public let maximumTransferSizeLimitBytes: Int64 = 2_047 * 1_024 * 1_024

public struct GlobalShortcut: Codable, Equatable, Sendable {
    public static let command: UInt32 = 1 << 0
    public static let control: UInt32 = 1 << 1
    public static let option: UInt32 = 1 << 2
    public static let shift: UInt32 = 1 << 3
    public static let defaultTransfer = GlobalShortcut(
        keyCode: 9, // V on the ANSI keyboard layout
        modifiers: command | control | option,
        displayKey: "V"
    )

    public var keyCode: UInt32
    public var modifiers: UInt32
    public var displayKey: String?

    public init(keyCode: UInt32, modifiers: UInt32, displayKey: String? = nil) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.displayKey = displayKey
    }
}

public enum RemoteReceiveMode: String, Codable, Equatable, Sendable, CaseIterable, Identifiable {
    case realtime
    case polling

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .realtime:
            return "Realtime"
        case .polling:
            return "Polling"
        }
    }

    public var detailText: String {
        switch self {
        case .realtime:
            return "Use the server's long-lived realtime channel for immediate remote updates."
        case .polling:
            return "Periodically fetch the latest clipboard over HTTP instead of keeping a live connection."
        }
    }

    static func fromLegacyTransportRawValue(_ rawValue: String?) -> Self? {
        switch rawValue {
        case "automatic", "webSockets", "serverSentEvents":
            return .realtime
        case "longPolling":
            return .polling
        default:
            return nil
        }
    }
}

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
    public var showDockIcon: Bool
    public var receiveMode: RemoteReceiveMode
    public var pollingIntervalSeconds: Double
    public var autoReconnect: Bool
    public var maximumTransferSizeBytes: Int64
    public var transferShortcut: GlobalShortcut?

    public init(
        serverURL: String = "",
        username: String = "",
        keychainAccount: String = "default",
        syncEnabled: Bool = false,
        launchAtLogin: Bool = false,
        showNotifications: Bool = true,
        showDockIcon: Bool = true,
        receiveMode: RemoteReceiveMode = .realtime,
        pollingIntervalSeconds: Double = 1.0,
        autoReconnect: Bool = true,
        maximumTransferSizeBytes: Int64 = defaultMaximumTransferSizeBytes,
        transferShortcut: GlobalShortcut? = .defaultTransfer
    ) {
        self.serverURL = serverURL
        self.username = username
        self.keychainAccount = keychainAccount
        self.syncEnabled = syncEnabled
        self.launchAtLogin = launchAtLogin
        self.showNotifications = showNotifications
        self.showDockIcon = showDockIcon
        self.receiveMode = receiveMode
        self.pollingIntervalSeconds = Self.clampedPollingInterval(pollingIntervalSeconds)
        self.autoReconnect = autoReconnect
        self.maximumTransferSizeBytes = min(max(1, maximumTransferSizeBytes), maximumTransferSizeLimitBytes)
        self.transferShortcut = transferShortcut
    }

    enum CodingKeys: String, CodingKey {
        case serverURL
        case username
        case keychainAccount
        case syncEnabled
        case launchAtLogin
        case showNotifications
        case showDockIcon
        case receiveMode
        case pollingIntervalSeconds
        case autoReconnect
        case realtimeTransportMode
        case maximumTransferSizeBytes
        case transferShortcut
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.serverURL = try container.decodeIfPresent(String.self, forKey: .serverURL) ?? ""
        self.username = try container.decodeIfPresent(String.self, forKey: .username) ?? ""
        self.keychainAccount = try container.decodeIfPresent(String.self, forKey: .keychainAccount) ?? "default"
        self.syncEnabled = try container.decodeIfPresent(Bool.self, forKey: .syncEnabled) ?? false
        self.launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        self.showNotifications = try container.decodeIfPresent(Bool.self, forKey: .showNotifications) ?? true
        self.showDockIcon = try container.decodeIfPresent(Bool.self, forKey: .showDockIcon) ?? true
        if let receiveMode = try container.decodeIfPresent(RemoteReceiveMode.self, forKey: .receiveMode) {
            self.receiveMode = receiveMode
        } else {
            let legacyTransport = try container.decodeIfPresent(String.self, forKey: .realtimeTransportMode)
            self.receiveMode = RemoteReceiveMode.fromLegacyTransportRawValue(legacyTransport) ?? .realtime
        }
        let pollingInterval = try container.decodeIfPresent(Double.self, forKey: .pollingIntervalSeconds) ?? 1.0
        self.pollingIntervalSeconds = Self.clampedPollingInterval(pollingInterval)
        self.autoReconnect = try container.decodeIfPresent(Bool.self, forKey: .autoReconnect) ?? true
        self.maximumTransferSizeBytes = min(
            max(
                1,
                try container.decodeIfPresent(Int64.self, forKey: .maximumTransferSizeBytes)
                    ?? defaultMaximumTransferSizeBytes
            ),
            maximumTransferSizeLimitBytes
        )
        self.transferShortcut = try container.contains(.transferShortcut)
            ? container.decodeIfPresent(GlobalShortcut.self, forKey: .transferShortcut)
            : .defaultTransfer
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(serverURL, forKey: .serverURL)
        try container.encode(username, forKey: .username)
        try container.encode(keychainAccount, forKey: .keychainAccount)
        try container.encode(syncEnabled, forKey: .syncEnabled)
        try container.encode(launchAtLogin, forKey: .launchAtLogin)
        try container.encode(showNotifications, forKey: .showNotifications)
        try container.encode(showDockIcon, forKey: .showDockIcon)
        try container.encode(receiveMode, forKey: .receiveMode)
        try container.encode(Self.clampedPollingInterval(pollingIntervalSeconds), forKey: .pollingIntervalSeconds)
        try container.encode(autoReconnect, forKey: .autoReconnect)
        try container.encode(
            min(max(1, maximumTransferSizeBytes), maximumTransferSizeLimitBytes),
            forKey: .maximumTransferSizeBytes
        )
        try container.encode(transferShortcut, forKey: .transferShortcut)
    }

    private static func clampedPollingInterval(_ value: Double) -> Double {
        min(max(value, 0.5), 60.0)
    }
}

public struct ServerConfiguration: Equatable, Sendable {
    public let baseURL: URL
    public let username: String
    public let password: String
    public let receiveMode: RemoteReceiveMode
    public let autoReconnect: Bool

    public init(
        baseURL: URL,
        username: String,
        password: String,
        receiveMode: RemoteReceiveMode = .realtime,
        autoReconnect: Bool = true
    ) {
        self.baseURL = baseURL
        self.username = username
        self.password = password
        self.receiveMode = receiveMode
        self.autoReconnect = autoReconnect
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

    public var fingerprint: String {
        let stableHash = hash.isEmpty ? text : hash
        return "\(type.rawValue)|\(stableHash)"
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
    case transferTooLarge(Int64)
    case unsupportedFileSelection
    case invalidRemoteFileName
    case archiveFailed(String)
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
        case .transferTooLarge(let maximumBytes):
            return "Transfer exceeds the configured limit of \(maximumBytes / 1_024 / 1_024) MiB."
        case .unsupportedFileSelection:
            return "The clipboard does not contain readable regular files or folders."
        case .invalidRemoteFileName:
            return "The server returned an invalid file name."
        case .archiveFailed(let message):
            return "Could not create ZIP archive: \(message)"
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
