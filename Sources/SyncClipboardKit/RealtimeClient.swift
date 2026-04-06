import Foundation

public enum RealtimeState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case reconnecting
    case error(String)
}

@MainActor
public protocol RealtimeClient: AnyObject {
    var onProfileChanged: (@Sendable (ProfileDTO) -> Void)? { get set }
    var onStateChange: (@Sendable (RealtimeState) -> Void)? { get set }
    func start(configuration: ServerConfiguration) async
    func stop() async
    func pollNow() async
}

@MainActor
public enum RealtimeClientFactory {
    public static func make(httpClient: SyncClipboardHTTPClient) -> RealtimeClient {
        PollingRealtimeClient(httpClient: httpClient)
    }
}

@MainActor
public final class PollingRealtimeClient: RealtimeClient {
    public var onProfileChanged: (@Sendable (ProfileDTO) -> Void)?
    public var onStateChange: (@Sendable (RealtimeState) -> Void)?

    private let httpClient: SyncClipboardHTTPClient
    private let pollInterval: TimeInterval
    private var timer: Timer?
    private var lastFingerprint: String?
    private var isConnected = false

    public init(httpClient: SyncClipboardHTTPClient, pollIntervalSeconds: TimeInterval = 3) {
        self.httpClient = httpClient
        self.pollInterval = pollIntervalSeconds
    }

    public func start(configuration: ServerConfiguration) async {
        httpClient.updateConfiguration(configuration)
        if timer != nil {
            return
        }

        onStateChange?(.connecting)
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.fetchAndEmitCurrentProfile()
            }
        }
        await fetchAndEmitCurrentProfile()
    }

    public func stop() async {
        timer?.invalidate()
        timer = nil
        lastFingerprint = nil
        isConnected = false
        onStateChange?(.disconnected)
    }

    public func pollNow() async {
        await fetchAndEmitCurrentProfile()
    }

    private func fetchAndEmitCurrentProfile() async {
        do {
            let profile = try await httpClient.fetchCurrentProfile()
            let fingerprint = profile.hash.isEmpty ? "\(profile.type.rawValue)|\(profile.text)" : "\(profile.type.rawValue)|\(profile.hash)"

            if !isConnected {
                isConnected = true
                onStateChange?(.connected)
            }

            guard fingerprint != lastFingerprint else {
                return
            }

            lastFingerprint = fingerprint
            onProfileChanged?(profile)
        } catch {
            isConnected = false
            onStateChange?(.error(error.localizedDescription))
            onStateChange?(.reconnecting)
        }
    }
}
