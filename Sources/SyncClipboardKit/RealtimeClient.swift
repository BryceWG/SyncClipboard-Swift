import Foundation
import SignalRClient

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

enum SignalRConnectionMetadata {
    static let hubPath = "SyncClipboardHub"
    static let remoteProfileChangedMethod = "RemoteProfileChanged"
    static let negotiateVersion = 1

    static func hubURL(for baseURL: URL) -> String {
        let baseString = baseURL.absoluteString.hasSuffix("/") ? String(baseURL.absoluteString.dropLast()) : baseURL.absoluteString
        return "\(baseString)/\(hubPath)"
    }

    static func hubNegotiateURL(for baseURL: URL) -> URL {
        var components = URLComponents(string: hubURL(for: baseURL)) ?? URLComponents(url: baseURL, resolvingAgainstBaseURL: false) ?? URLComponents()
        if !components.path.hasSuffix("/") {
            components.path += "/"
        }
        components.path += "negotiate"

        var queryItems = components.queryItems ?? []
        if !queryItems.contains(where: { $0.name == "negotiateVersion" }) {
            queryItems.append(URLQueryItem(name: "negotiateVersion", value: "\(negotiateVersion)"))
        }
        components.queryItems = queryItems

        return components.url ?? baseURL.appending(path: "\(hubPath)/negotiate")
    }

    static func headers(for configuration: ServerConfiguration) -> [String: String] {
        [
            "Authorization": ServerAuth(username: configuration.username, password: configuration.password).authorizationHeader,
        ]
    }

    static func fingerprint(for profile: ProfileDTO) -> String {
        let stableHash = profile.hash.isEmpty ? profile.text : profile.hash
        return "\(profile.type.rawValue)|\(stableHash)"
    }

}

struct InfiniteSignalRRetryPolicy: RetryPolicy {
    private let delays: [TimeInterval] = [0, 2, 5, 10, 30]

    func nextRetryInterval(retryContext: RetryContext) -> TimeInterval? {
        delays[min(retryContext.retryCount, delays.count - 1)]
    }
}

struct RealtimeRefreshContext: Equatable {
    let configuration: ServerConfiguration
    let connectionToken: UUID?
}

@MainActor
public enum RealtimeClientFactory {
    public static func make(httpClient: SyncClipboardHTTPClient) -> RealtimeClient {
        SignalRRealtimeClient(httpClient: httpClient)
    }
}

@MainActor
public final class SignalRRealtimeClient: RealtimeClient {
    public var onProfileChanged: (@Sendable (ProfileDTO) -> Void)?
    public var onStateChange: (@Sendable (RealtimeState) -> Void)?

    private let httpClient: SyncClipboardHTTPClient
    private let reconnectDelay: TimeInterval

    private var desiredConfiguration: ServerConfiguration?
    private var hubConnection: HubConnection?
    private var connectionToken: UUID?
    private var restartTask: Task<Void, Never>?
    private var lastFingerprint: String?

    public init(httpClient: SyncClipboardHTTPClient, reconnectDelaySeconds: TimeInterval = 3) {
        self.httpClient = httpClient
        self.reconnectDelay = reconnectDelaySeconds
    }

    public func start(configuration: ServerConfiguration) async {
        httpClient.updateConfiguration(configuration)

        let isSameConfiguration = desiredConfiguration == configuration
        desiredConfiguration = configuration

        guard !isSameConfiguration || connectionToken == nil else {
            return
        }

        await replaceConnection(with: configuration, resetFingerprint: true)
    }

    public func stop() async {
        desiredConfiguration = nil
        restartTask?.cancel()
        restartTask = nil

        let existingConnection = hubConnection
        hubConnection = nil
        connectionToken = nil
        lastFingerprint = nil

        if let existingConnection {
            await existingConnection.stop()
        }

        onStateChange?(.disconnected)
    }

    public func pollNow() async {
        guard let context = currentRefreshContext() else {
            return
        }

        await fetchAndEmitCurrentProfile(using: context, forceEmit: true)
    }

    private func replaceConnection(with configuration: ServerConfiguration, resetFingerprint: Bool) async {
        restartTask?.cancel()
        restartTask = nil

        let existingConnection = hubConnection
        hubConnection = nil
        connectionToken = nil

        if resetFingerprint {
            lastFingerprint = nil
        }

        if let existingConnection {
            await existingConnection.stop()
        }

        await connect(configuration: configuration)
    }

    private func connect(configuration: ServerConfiguration) async {
        guard desiredConfiguration == configuration else {
            return
        }

        let token = UUID()
        connectionToken = token

        let connection = buildConnection(for: configuration)
        await installHandlers(on: connection, configuration: configuration, token: token)
        hubConnection = connection

        onStateChange?(.connecting)

        do {
            try await connection.start()
            guard isCurrentConnection(token: token, configuration: configuration) else {
                await connection.stop()
                return
            }

            onStateChange?(.connected)
            await fetchAndEmitCurrentProfile(
                using: RealtimeRefreshContext(configuration: configuration, connectionToken: token),
                forceEmit: false
            )
        } catch {
            guard isCurrentConnection(token: token, configuration: configuration) else {
                return
            }

            hubConnection = nil
            connectionToken = nil
            onStateChange?(.error(error.localizedDescription))
            scheduleRestart(for: configuration)
        }
    }

    private func buildConnection(for configuration: ServerConfiguration) -> HubConnection {
        var options = HttpConnectionOptions()
        options.headers = SignalRConnectionMetadata.headers(for: configuration)
        let builder = HubConnectionBuilder()
            .withUrl(url: SignalRConnectionMetadata.hubURL(for: configuration.baseURL), options: options)
            .withHubProtocol(hubProtocol: .json)
            .withServerTimeout(serverTimeout: 30)
            .withKeepAliveInterval(keepAliveInterval: 15)

        if configuration.autoReconnect {
            return builder
                .withAutomaticReconnect(retryPolicy: InfiniteSignalRRetryPolicy())
                .build()
        }

        return builder.build()
    }

    private func installHandlers(on connection: HubConnection, configuration: ServerConfiguration, token: UUID) async {
        let onProfileChanged: @Sendable (ProfileDTO) async -> Void = { [weak self] profile in
            await MainActor.run {
                guard let self else { return }
                Task {
                    await self.handleRemoteProfile(profile, configuration: configuration, token: token)
                }
            }
        }
        await connection.on(SignalRConnectionMetadata.remoteProfileChangedMethod, handler: onProfileChanged)

        let onReconnecting: @Sendable (Error?) async -> Void = { [weak self] error in
            await MainActor.run {
                guard let self else { return }
                Task {
                    await self.handleReconnecting(error, configuration: configuration, token: token)
                }
            }
        }
        await connection.onReconnecting(handler: onReconnecting)

        let onReconnected: @Sendable () async -> Void = { [weak self] in
            await MainActor.run {
                guard let self else { return }
                Task {
                    await self.handleReconnected(configuration: configuration, token: token)
                }
            }
        }
        await connection.onReconnected(handler: onReconnected)

        let onClosed: @Sendable (Error?) async -> Void = { [weak self] error in
            await MainActor.run {
                guard let self else { return }
                Task {
                    await self.handleClosed(error, configuration: configuration, token: token)
                }
            }
        }
        await connection.onClosed(handler: onClosed)
    }

    private func handleRemoteProfile(_ profile: ProfileDTO, configuration: ServerConfiguration, token: UUID) async {
        guard isCurrentConnection(token: token, configuration: configuration) else {
            return
        }

        emitIfNeeded(profile)
    }

    private func handleReconnecting(_ error: Error?, configuration: ServerConfiguration, token: UUID) async {
        guard isCurrentConnection(token: token, configuration: configuration) else {
            return
        }

        if let error {
            onStateChange?(.error(error.localizedDescription))
        }
        onStateChange?(.reconnecting)
    }

    private func handleReconnected(configuration: ServerConfiguration, token: UUID) async {
        guard isCurrentConnection(token: token, configuration: configuration) else {
            return
        }

        onStateChange?(.connected)
        await fetchAndEmitCurrentProfile(
            using: RealtimeRefreshContext(configuration: configuration, connectionToken: token),
            forceEmit: false
        )
    }

    private func handleClosed(_ error: Error?, configuration: ServerConfiguration, token: UUID) async {
        guard isCurrentConnection(token: token, configuration: configuration) else {
            return
        }

        hubConnection = nil
        connectionToken = nil

        guard desiredConfiguration == configuration else {
            return
        }

        if let terminalState = Self.terminalStateAfterClose(error: error, autoReconnectEnabled: configuration.autoReconnect) {
            onStateChange?(terminalState)
            return
        }

        if let error {
            onStateChange?(.error(error.localizedDescription))
        }
        scheduleRestart(for: configuration)
    }

    private func scheduleRestart(for configuration: ServerConfiguration) {
        guard desiredConfiguration == configuration, configuration.autoReconnect else {
            return
        }

        restartTask?.cancel()
        onStateChange?(.reconnecting)

        restartTask = Task { [weak self] in
            do {
                let reconnectDelay = self?.reconnectDelay ?? 0
                try await Task.sleep(nanoseconds: UInt64(reconnectDelay * 1_000_000_000))
            } catch {
                return
            }

            guard let self else { return }
            await self.connect(configuration: configuration)
        }
    }

    private func fetchAndEmitCurrentProfile(using context: RealtimeRefreshContext, forceEmit: Bool) async {
        httpClient.updateConfiguration(context.configuration)

        do {
            let profile = try await httpClient.fetchCurrentProfile()
            guard isCurrentRefreshContext(context) else {
                return
            }

            emitIfNeeded(profile, forceEmit: forceEmit)
        } catch {
            guard isCurrentRefreshContext(context) else {
                return
            }

            onStateChange?(.error(error.localizedDescription))
        }
    }

    private func emitIfNeeded(_ profile: ProfileDTO, forceEmit: Bool = false) {
        let fingerprint = SignalRConnectionMetadata.fingerprint(for: profile)
        guard forceEmit || fingerprint != lastFingerprint else {
            return
        }

        lastFingerprint = fingerprint
        onProfileChanged?(profile)
    }

    private func isCurrentConnection(token: UUID, configuration: ServerConfiguration) -> Bool {
        connectionToken == token && desiredConfiguration == configuration
    }

    private func currentRefreshContext() -> RealtimeRefreshContext? {
        guard let configuration = desiredConfiguration else {
            return nil
        }

        return RealtimeRefreshContext(configuration: configuration, connectionToken: connectionToken)
    }

    private func isCurrentRefreshContext(_ context: RealtimeRefreshContext) -> Bool {
        Self.isCurrentRefreshContext(
            context,
            desiredConfiguration: desiredConfiguration,
            currentConnectionToken: connectionToken
        )
    }

    nonisolated static func isCurrentRefreshContext(
        _ context: RealtimeRefreshContext,
        desiredConfiguration: ServerConfiguration?,
        currentConnectionToken: UUID?
    ) -> Bool {
        guard desiredConfiguration == context.configuration else {
            return false
        }

        guard let contextToken = context.connectionToken else {
            return true
        }

        return currentConnectionToken == contextToken
    }

    nonisolated static func terminalStateAfterClose(error: Error?, autoReconnectEnabled: Bool) -> RealtimeState? {
        guard !autoReconnectEnabled else {
            return nil
        }

        if let error {
            return .error(error.localizedDescription)
        }

        return .disconnected
    }
}
