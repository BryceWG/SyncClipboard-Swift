import Combine
import Foundation

@MainActor
public final class AppModel: ObservableObject {
    @Published public var serverURL: String
    @Published public var username: String
    @Published public var password: String
    @Published public var syncEnabled: Bool
    @Published public var launchAtLogin: Bool
    @Published public var showNotifications: Bool
    @Published public private(set) var connectionStatusText = "Disconnected"
    @Published public private(set) var lastPushText = "Never"
    @Published public private(set) var lastPullText = "Never"
    @Published public private(set) var lastErrorText = ""

    public let clipboardMonitor: ClipboardMonitor

    private let settingsStore: SettingsStore
    private let keychainStore: KeychainStore
    private let httpClient: SyncClipboardHTTPClient
    private let clipboardService: ClipboardService
    private let realtimeClient: any RealtimeClient
    private let coordinator: SyncCoordinator
    private let launchAtLoginManager = LaunchAtLoginManager()

    public init(
        settingsStore: SettingsStore = SettingsStore(),
        keychainStore: KeychainStore = KeychainStore(),
        httpClient: SyncClipboardHTTPClient = SyncClipboardHTTPClient()
    ) {
        self.settingsStore = settingsStore
        self.keychainStore = keychainStore
        self.httpClient = httpClient
        self.clipboardService = ClipboardService()
        self.clipboardMonitor = ClipboardMonitor()

        let loadedSettings = (try? settingsStore.load()) ?? AppSettings()
        let loadedPassword = (try? keychainStore.readPassword(account: loadedSettings.keychainAccount)) ?? nil

        self.serverURL = loadedSettings.serverURL
        self.username = loadedSettings.username
        self.password = loadedPassword ?? ""
        self.syncEnabled = loadedSettings.syncEnabled
        self.launchAtLogin = loadedSettings.launchAtLogin
        self.showNotifications = loadedSettings.showNotifications

        let notifier = UserNotifier()
        self.realtimeClient = RealtimeClientFactory.make(httpClient: httpClient)
        self.coordinator = SyncCoordinator(httpClient: httpClient, notifier: notifier)

        self.clipboardMonitor.onChange = { [weak self] in
            self?.handleLocalClipboardChange()
        }

        self.realtimeClient.onProfileChanged = { [weak self] profile in
            guard let self else { return }
            Task {
                await self.coordinator.handleRemoteProfileChange(profile, using: self.clipboardService)
            }
        }

        self.realtimeClient.onStateChange = { [weak self] state in
            Task { @MainActor in
                self?.applyRealtimeState(state)
            }
        }

        self.coordinator.diagnosticsHandler = { [weak self] diagnostics in
            self?.applyDiagnostics(diagnostics)
        }
    }

    public func start() {
        clipboardMonitor.start()
        Task { await applyRuntimeConfiguration(forceRefresh: true) }
    }

    public func stop() {
        clipboardMonitor.stop()
        Task { await realtimeClient.stop() }
    }

    public func persistSettings() async {
        let settings = AppSettings(
            serverURL: serverURL.trimmingCharacters(in: .whitespacesAndNewlines),
            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
            keychainAccount: "primary",
            syncEnabled: syncEnabled,
            launchAtLogin: launchAtLogin,
            showNotifications: showNotifications
        )

        do {
            try settingsStore.save(settings)
            try keychainStore.savePassword(password, account: settings.keychainAccount)
            try launchAtLoginManager.setEnabled(launchAtLogin)
            lastErrorText = ""
        } catch {
            lastErrorText = error.localizedDescription
        }

        await applyRuntimeConfiguration(forceRefresh: false)
    }

    public func testConnection() async {
        do {
            httpClient.updateConfiguration(buildServerConfiguration())
            try await httpClient.testConnection()
            connectionStatusText = "Connected"
            lastErrorText = ""
        } catch {
            connectionStatusText = "Error"
            lastErrorText = error.localizedDescription
        }
    }

    public func syncNow() async {
        httpClient.updateConfiguration(buildServerConfiguration())
        await coordinator.refreshFromServer(using: clipboardService)
        await realtimeClient.pollNow()
    }

    public var requiresSetup: Bool {
        buildServerConfiguration() == nil
    }

    private func applyRuntimeConfiguration(forceRefresh: Bool) async {
        let configuration = buildServerConfiguration()
        httpClient.updateConfiguration(configuration)
        coordinator.updatePreferences(syncEnabled: syncEnabled, showNotifications: showNotifications)

        guard let configuration, syncEnabled else {
            connectionStatusText = syncEnabled ? "Missing Config" : "Disabled"
            await realtimeClient.stop()
            return
        }

        await realtimeClient.start(configuration: configuration)
        if forceRefresh {
            await coordinator.refreshFromServer(using: clipboardService)
        }
    }

    private func buildServerConfiguration() -> ServerConfiguration? {
        let trimmedURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUser = username.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedURL.isEmpty,
              !trimmedUser.isEmpty,
              !password.isEmpty,
              let url = URL(string: trimmedURL) else {
            return nil
        }

        return ServerConfiguration(baseURL: url, username: trimmedUser, password: password)
    }

    private func handleLocalClipboardChange() {
        Task {
            await coordinator.handleLocalPasteboardChange(using: clipboardService)
        }
    }

    private func applyRealtimeState(_ state: RealtimeState) {
        switch state {
        case .disconnected:
            connectionStatusText = "Disconnected"
        case .connecting:
            connectionStatusText = "Connecting"
        case .connected:
            connectionStatusText = "Connected"
        case .reconnecting:
            connectionStatusText = "Reconnecting"
        case .error(let message):
            connectionStatusText = "Error"
            lastErrorText = message
        }
    }

    private func applyDiagnostics(_ diagnostics: SyncDiagnostics) {
        if let lastPushAt = diagnostics.lastPushAt {
            lastPushText = Self.relativeFormatter.localizedString(for: lastPushAt, relativeTo: Date())
        }
        if let lastPullAt = diagnostics.lastPullAt {
            lastPullText = Self.relativeFormatter.localizedString(for: lastPullAt, relativeTo: Date())
        }
        if let lastError = diagnostics.lastError {
            lastErrorText = lastError
        }
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()
}
