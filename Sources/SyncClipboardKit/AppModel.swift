import Combine
import Foundation

struct RealtimePresentationState: Equatable {
    let connectionStatusText: String
    let errorText: String
}

@MainActor
public final class AppModel: ObservableObject {
    @Published public var serverURL: String
    @Published public var username: String
    @Published public var password: String
    @Published public var syncEnabled: Bool
    @Published public var launchAtLogin: Bool
    @Published public var showNotifications: Bool
    @Published public var showDockIcon: Bool
    @Published public var receiveMode: RemoteReceiveMode
    @Published public var pollingIntervalSeconds: Double
    @Published public var autoReconnect: Bool
    @Published public private(set) var connectionStatusText = "Disconnected"
    @Published public private(set) var lastPushText = "Never"
    @Published public private(set) var lastPullText = "Never"
    @Published public private(set) var lastErrorText = ""

    public let clipboardMonitor: ClipboardMonitor

    private let settingsStore: any SettingsStoring
    private let keychainStore: any KeychainStoring
    private let httpClient: SyncClipboardHTTPClient
    private let clipboardService: any ClipboardServicing
    private let realtimeClient: any RealtimeClient
    private let coordinator: SyncCoordinator
    private let launchAtLoginManager: any LaunchAtLoginManaging
    private var pollingTask: Task<Void, Never>?

    public init(
        settingsStore: any SettingsStoring = SettingsStore(),
        keychainStore: any KeychainStoring = KeychainStore(),
        httpClient: SyncClipboardHTTPClient = SyncClipboardHTTPClient(),
        clipboardService: any ClipboardServicing = ClipboardService(),
        launchAtLoginManager: any LaunchAtLoginManaging = LaunchAtLoginManager()
    ) {
        self.settingsStore = settingsStore
        self.keychainStore = keychainStore
        self.httpClient = httpClient
        self.clipboardService = clipboardService
        self.launchAtLoginManager = launchAtLoginManager
        self.clipboardMonitor = ClipboardMonitor()

        let loadedSettings = (try? settingsStore.load()) ?? AppSettings()
        let loadedPassword = (try? keychainStore.readPassword(account: loadedSettings.keychainAccount)) ?? nil

        self.serverURL = loadedSettings.serverURL
        self.username = loadedSettings.username
        self.password = loadedPassword ?? ""
        self.syncEnabled = loadedSettings.syncEnabled
        self.launchAtLogin = Self.launchAtLoginEnabled(for: launchAtLoginManager.status)
        self.showNotifications = loadedSettings.showNotifications
        self.showDockIcon = loadedSettings.showDockIcon
        self.receiveMode = loadedSettings.receiveMode
        self.pollingIntervalSeconds = loadedSettings.pollingIntervalSeconds
        self.autoReconnect = loadedSettings.autoReconnect

        let notifier = UserNotifier()
        self.realtimeClient = RealtimeClientFactory.make(httpClient: httpClient)
        self.coordinator = SyncCoordinator(httpClient: httpClient, notifier: notifier)

        self.clipboardMonitor.onChange = { [weak self] in
            self?.handleLocalClipboardChange()
        }

        self.realtimeClient.onProfileChanged = { [weak self] profile in
            guard let self else { return }
            Task { @MainActor in
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

    public func stop() async {
        clipboardMonitor.stop()
        clipboardMonitor.onChange = nil
        stopPollingLoop()
        realtimeClient.onProfileChanged = nil
        realtimeClient.onStateChange = nil
        coordinator.diagnosticsHandler = nil
        await realtimeClient.stop()
    }

    public func persistSettings() async {
        let requestedLaunchAtLogin = launchAtLogin
        var issueText: String?

        do {
            try launchAtLoginManager.setEnabled(requestedLaunchAtLogin)
        } catch {
            issueText = error.localizedDescription
        }

        let launchStatus = launchAtLoginManager.status
        launchAtLogin = Self.launchAtLoginEnabled(for: launchStatus)
        if issueText == nil {
            issueText = Self.launchAtLoginIssueText(forRequestedState: requestedLaunchAtLogin, status: launchStatus)
        }

        let settings = AppSettings(
            serverURL: serverURL.trimmingCharacters(in: .whitespacesAndNewlines),
            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
            keychainAccount: "primary",
            syncEnabled: syncEnabled,
            launchAtLogin: launchAtLogin,
            showNotifications: showNotifications,
            showDockIcon: showDockIcon,
            receiveMode: receiveMode,
            pollingIntervalSeconds: pollingIntervalSeconds,
            autoReconnect: autoReconnect
        )

        do {
            try keychainStore.savePassword(password, account: settings.keychainAccount)
            try settingsStore.save(settings)
        } catch {
            issueText = error.localizedDescription
        }

        lastErrorText = issueText ?? ""
        await applyRuntimeConfiguration(forceRefresh: false)
    }

    public func testConnection() async {
        let configuration = buildServerConfiguration()

        do {
            httpClient.updateConfiguration(configuration)
            try await httpClient.testConnection()
            connectionStatusText = Self.connectionStatusAfterSuccessfulConnectionTest(
                for: configuration?.receiveMode ?? receiveMode
            )
            lastErrorText = ""
        } catch {
            connectionStatusText = "Error"
            lastErrorText = error.localizedDescription
        }
    }

    public func syncNow() async {
        httpClient.updateConfiguration(buildServerConfiguration())
        await coordinator.handleLocalPasteboardChange(using: clipboardService)
        switch receiveMode {
        case .realtime:
            await realtimeClient.pollNow()
        case .polling:
            await coordinator.refreshFromServer(using: clipboardService)
        }
    }

    public var requiresSetup: Bool {
        buildServerConfiguration() == nil
    }

    public func handleSystemWake() {
        Task {
            let configuration = buildServerConfiguration()
            httpClient.updateConfiguration(configuration)

            guard let configuration, syncEnabled, autoReconnect else {
                return
            }

            switch receiveMode {
            case .realtime:
                await realtimeClient.stop()
                await realtimeClient.start(configuration: configuration)
                _ = await coordinator.refreshFromServer(using: clipboardService)
            case .polling:
                connectionStatusText = "Polling"
                _ = await coordinator.refreshFromServer(using: clipboardService)
            }
        }
    }

    private func applyRuntimeConfiguration(forceRefresh: Bool) async {
        let configuration = buildServerConfiguration()
        httpClient.updateConfiguration(configuration)
        coordinator.updatePreferences(syncEnabled: syncEnabled, showNotifications: showNotifications)

        guard let configuration, syncEnabled else {
            stopPollingLoop()
            connectionStatusText = syncEnabled ? "Missing Config" : "Disabled"
            await realtimeClient.stop()
            return
        }

        switch receiveMode {
        case .realtime:
            stopPollingLoop()
            await realtimeClient.start(configuration: configuration)
            if forceRefresh {
                _ = await coordinator.refreshFromServer(using: clipboardService)
            }
        case .polling:
            await realtimeClient.stop()
            connectionStatusText = "Polling"
            startPollingLoop(forceRefresh: forceRefresh)
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

        return ServerConfiguration(
            baseURL: url,
            username: trimmedUser,
            password: password,
            receiveMode: receiveMode,
            autoReconnect: autoReconnect
        )
    }

    private func handleLocalClipboardChange() {
        Task { @MainActor in
            await coordinator.handleLocalPasteboardChange(using: clipboardService)
        }
    }

    private func applyRealtimeState(_ state: RealtimeState) {
        let presentation = Self.realtimePresentationState(for: state)
        connectionStatusText = presentation.connectionStatusText
        lastErrorText = presentation.errorText
    }

    private func applyDiagnostics(_ diagnostics: SyncDiagnostics) {
        if let lastPushAt = diagnostics.lastPushAt {
            lastPushText = Self.relativeFormatter.localizedString(for: lastPushAt, relativeTo: Date())
        }
        if let lastPullAt = diagnostics.lastPullAt {
            lastPullText = Self.relativeFormatter.localizedString(for: lastPullAt, relativeTo: Date())
        }
        lastErrorText = diagnostics.lastError ?? ""

        guard syncEnabled, !requiresSetup, receiveMode == .polling else {
            return
        }

        connectionStatusText = lastErrorText.isEmpty ? "Polling" : "Error"
    }

    private func startPollingLoop(forceRefresh: Bool) {
        stopPollingLoop()

        pollingTask = Task { [weak self] in
            guard let self else { return }

            if forceRefresh {
                let succeeded = await self.coordinator.refreshFromServer(using: self.clipboardService)
                if !succeeded && !self.autoReconnect {
                    self.connectionStatusText = "Error"
                    self.pollingTask = nil
                    return
                }
            }

            while !Task.isCancelled {
                let interval = max(self.pollingIntervalSeconds, 0.5)
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled else { break }
                let succeeded = await self.coordinator.refreshFromServer(using: self.clipboardService)
                if !succeeded && !self.autoReconnect {
                    self.connectionStatusText = "Error"
                    break
                }
            }

            self.pollingTask = nil
        }
    }

    private func stopPollingLoop() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    nonisolated static func realtimePresentationState(for state: RealtimeState) -> RealtimePresentationState {
        switch state {
        case .disconnected:
            return RealtimePresentationState(connectionStatusText: "Disconnected", errorText: "")
        case .connecting:
            return RealtimePresentationState(connectionStatusText: "Connecting", errorText: "")
        case .connected:
            return RealtimePresentationState(connectionStatusText: "Connected", errorText: "")
        case .reconnecting:
            return RealtimePresentationState(connectionStatusText: "Reconnecting", errorText: "")
        case .error(let message):
            return RealtimePresentationState(connectionStatusText: "Error", errorText: message)
        }
    }

    nonisolated static func launchAtLoginEnabled(for status: LaunchAtLoginStatus) -> Bool {
        status == .enabled
    }

    nonisolated static func launchAtLoginIssueText(
        forRequestedState requested: Bool,
        status: LaunchAtLoginStatus
    ) -> String? {
        guard requested, status == .requiresApproval else {
            return nil
        }

        return "Launch at Login is pending approval in System Settings."
    }

    nonisolated static func connectionStatusAfterSuccessfulConnectionTest(
        for receiveMode: RemoteReceiveMode
    ) -> String {
        switch receiveMode {
        case .realtime:
            return "Connected"
        case .polling:
            return "Polling"
        }
    }
}
