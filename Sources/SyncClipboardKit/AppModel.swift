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
    @Published public var maximumTransferSizeMiB: Int
    @Published public var autoSyncImages: Bool
    @Published public var autoSyncFiles: Bool
    @Published public private(set) var transferShortcut: GlobalShortcut?
    @Published public private(set) var isFileTransferRunning = false
    @Published public private(set) var connectionStatusText = "Disconnected"
    @Published public private(set) var lastPushAt: Date?
    @Published public private(set) var lastPullAt: Date?
    @Published public private(set) var lastErrorText = ""

    public let clipboardMonitor: ClipboardMonitor

    private let settingsStore: any SettingsStoring
    private let keychainStore: any KeychainStoring
    private let httpClient: SyncClipboardHTTPClient
    private let clipboardService: any ClipboardServicing
    private let realtimeClient: any RealtimeClient
    private let coordinator: SyncCoordinator
    private let launchAtLoginManager: any LaunchAtLoginManaging
    private var persistedSettings: AppSettings
    private var pollingTask: Task<Void, Never>?
    private var pollingTaskID: UUID?
    private var hasStarted = false
    private var screenAwake = true
    private var sessionActive = true
    public var shortcutRegistrationHandler: ((GlobalShortcut?) -> Bool)?

    public init(
        settingsStore: any SettingsStoring = SettingsStore(),
        keychainStore: any KeychainStoring = KeychainStore(),
        httpClient: SyncClipboardHTTPClient = SyncClipboardHTTPClient(),
        clipboardService: any ClipboardServicing = ClipboardService(),
        launchAtLoginManager: any LaunchAtLoginManaging = LaunchAtLoginManager(),
        realtimeClient: (any RealtimeClient)? = nil
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
        self.maximumTransferSizeMiB = max(1, Int(loadedSettings.maximumTransferSizeBytes / 1_024 / 1_024))
        self.transferShortcut = loadedSettings.transferShortcut
        self.autoSyncImages = loadedSettings.autoSyncImages
        self.autoSyncFiles = loadedSettings.autoSyncFiles
        self.persistedSettings = loadedSettings

        let notifier = UserNotifier()
        self.realtimeClient = realtimeClient ?? RealtimeClientFactory.make(httpClient: httpClient)
        self.coordinator = SyncCoordinator(httpClient: httpClient, notifier: notifier)

        self.clipboardMonitor.onChange = { [weak self] changeCount, observedAt in
            self?.handleLocalClipboardChange(changeCount: changeCount, observedAt: observedAt)
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
        hasStarted = true
        Task { await applyRuntimeConfiguration(forceRefresh: true) }
    }

    public func stop() async {
        hasStarted = false
        clipboardMonitor.stop()
        clipboardMonitor.onChange = nil
        stopPollingLoop()
        realtimeClient.onProfileChanged = nil
        realtimeClient.onStateChange = nil
        coordinator.diagnosticsHandler = nil
        await realtimeClient.stop()
    }

    @discardableResult
    public func persistSettings() async -> Bool {
        let requestedLaunchAtLogin = launchAtLogin
        var issueText: String?

        if Self.shouldUpdateLaunchAtLogin(
            requested: requestedLaunchAtLogin,
            status: launchAtLoginManager.status
        ) {
            do {
                try launchAtLoginManager.setEnabled(requestedLaunchAtLogin)
            } catch {
                issueText = error.localizedDescription
            }
        }

        let launchStatus = launchAtLoginManager.status
        launchAtLogin = Self.launchAtLoginEnabled(for: launchStatus)
        if issueText == nil {
            issueText = Self.launchAtLoginIssueText(forRequestedState: requestedLaunchAtLogin, status: launchStatus)
        }

        let settings = currentSettings()

        do {
            try keychainStore.savePassword(password, account: settings.keychainAccount)
            try settingsStore.save(settings)
            persistedSettings = settings
        } catch {
            issueText = error.localizedDescription
        }

        let succeeded = issueText == nil
        lastErrorText = issueText ?? ""
        await applyRuntimeConfiguration(forceRefresh: false)
        return succeeded
    }

    @discardableResult
    public func testConnection() async -> Bool {
        let configuration = buildServerConfiguration()

        do {
            httpClient.updateConfiguration(configuration)
            try await httpClient.testConnection()
            connectionStatusText = Self.connectionStatusAfterSuccessfulConnectionTest(
                for: configuration?.receiveMode ?? receiveMode
            )
            lastErrorText = ""
            return true
        } catch {
            connectionStatusText = "Error"
            lastErrorText = error.localizedDescription
            return false
        }
    }

    public func syncNow() async {
        await performExplicitSyncCycle()
    }

    public func syncFiles() async {
        guard !isFileTransferRunning else { return }
        isFileTransferRunning = true
        defer { isFileTransferRunning = false }

        httpClient.updateConfiguration(buildServerConfiguration())
        coordinator.updatePreferences(
            syncEnabled: syncEnabled,
            showNotifications: showNotifications,
            autoSyncImages: autoSyncImages,
            autoSyncFiles: autoSyncFiles,
            maximumBytes: maximumTransferSizeBytes
        )
        _ = await coordinator.transferClipboardFiles(
            using: clipboardService,
            maximumBytes: maximumTransferSizeBytes
        )
    }

    @discardableResult
    public func updateTransferShortcut(_ shortcut: GlobalShortcut?) async -> Bool {
        guard shortcut != transferShortcut else { return true }
        guard shortcutRegistrationHandler?(shortcut) != false else {
            lastErrorText = "That global shortcut is already in use."
            return false
        }

        let previous = transferShortcut
        transferShortcut = shortcut
        do {
            var settings = persistedSettings
            settings.transferShortcut = shortcut
            try settingsStore.save(settings)
            persistedSettings = settings
            lastErrorText = ""
            return true
        } catch {
            _ = shortcutRegistrationHandler?(previous)
            transferShortcut = previous
            lastErrorText = error.localizedDescription
            return false
        }
    }

    public func reportShortcutRegistrationFailure() {
        lastErrorText = "The configured global shortcut is already in use. Use the menu or choose another shortcut."
    }

    public static var maximumTransferSizeMiBLimit: Int {
        Int(maximumTransferSizeLimitBytes / 1_024 / 1_024)
    }

    private var maximumTransferSizeBytes: Int64 {
        Int64(min(max(1, maximumTransferSizeMiB), Self.maximumTransferSizeMiBLimit)) * 1_024 * 1_024
    }

    private func currentSettings() -> AppSettings {
        AppSettings(
            serverURL: serverURL.trimmingCharacters(in: .whitespacesAndNewlines),
            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
            keychainAccount: "primary",
            syncEnabled: syncEnabled,
            launchAtLogin: launchAtLogin,
            showNotifications: showNotifications,
            showDockIcon: showDockIcon,
            receiveMode: receiveMode,
            pollingIntervalSeconds: pollingIntervalSeconds,
            autoReconnect: autoReconnect,
            maximumTransferSizeBytes: maximumTransferSizeBytes,
            transferShortcut: transferShortcut,
            autoSyncImages: autoSyncImages,
            autoSyncFiles: autoSyncFiles
        )
    }

    private func performExplicitSyncCycle() async {
        httpClient.updateConfiguration(buildServerConfiguration())
        coordinator.updatePreferences(
            syncEnabled: syncEnabled,
            showNotifications: showNotifications,
            autoSyncImages: autoSyncImages,
            autoSyncFiles: autoSyncFiles,
            maximumBytes: maximumTransferSizeBytes
        )
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
            case .polling:
                updatePollingForActivity(forceRefresh: true)
            }
        }
    }

    public func handleScreenSleep() {
        screenAwake = false
        updateActivityDependentWork()
    }

    public func handleScreenWake() {
        screenAwake = true
        updateActivityDependentWork()
    }

    public func handleSessionResignActive() {
        sessionActive = false
        updateActivityDependentWork()
    }

    public func handleSessionBecomeActive() {
        sessionActive = true
        updateActivityDependentWork()
    }

    private func applyRuntimeConfiguration(forceRefresh: Bool) async {
        let configuration = buildServerConfiguration()
        httpClient.updateConfiguration(configuration)
        coordinator.updatePreferences(
            syncEnabled: syncEnabled,
            showNotifications: showNotifications,
            autoSyncImages: autoSyncImages,
            autoSyncFiles: autoSyncFiles,
            maximumBytes: maximumTransferSizeBytes
        )
        updateClipboardMonitoring()

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
        case .polling:
            await realtimeClient.stop()
            connectionStatusText = "Polling"
            updatePollingForActivity(forceRefresh: forceRefresh)
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

    private func handleLocalClipboardChange(changeCount: Int, observedAt: Date) {
        Task { @MainActor in
            await coordinator.handleLocalPasteboardChange(
                using: clipboardService,
                changeCount: changeCount,
                observedAt: observedAt
            )
        }
    }

    private func applyRealtimeState(_ state: RealtimeState) {
        let presentation = Self.realtimePresentationState(for: state)
        connectionStatusText = presentation.connectionStatusText
        lastErrorText = presentation.errorText
    }

    private func applyDiagnostics(_ diagnostics: SyncDiagnostics) {
        lastPushAt = diagnostics.lastPushAt
        lastPullAt = diagnostics.lastPullAt
        lastErrorText = diagnostics.lastError ?? ""

        guard syncEnabled, !requiresSetup, receiveMode == .polling else {
            return
        }

        connectionStatusText = lastErrorText.isEmpty ? "Polling" : "Error"
    }

    private func startPollingLoop(forceRefresh: Bool) {
        stopPollingLoop()
        let taskID = UUID()
        pollingTaskID = taskID

        pollingTask = Task { [weak self] in
            guard let self else { return }
            guard !Task.isCancelled else {
                self.finishPollingTask(id: taskID)
                return
            }
            let configuredInterval = min(max(self.pollingIntervalSeconds, 0.5), 60.0)
            var nextInterval = configuredInterval

            if forceRefresh {
                let succeeded = await self.coordinator.refreshFromServer(using: self.clipboardService)
                guard !Task.isCancelled else {
                    self.finishPollingTask(id: taskID)
                    return
                }
                if !succeeded && !self.autoReconnect {
                    self.connectionStatusText = "Error"
                    self.finishPollingTask(id: taskID)
                    return
                }
                nextInterval = Self.nextPollingDelay(
                    configuredInterval: configuredInterval,
                    previousDelay: nextInterval,
                    succeeded: succeeded
                )
            }

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(nextInterval * 1_000_000_000))
                guard !Task.isCancelled else { break }
                let succeeded = await self.coordinator.refreshFromServer(using: self.clipboardService)
                guard !Task.isCancelled else { break }
                if !succeeded && !self.autoReconnect {
                    self.connectionStatusText = "Error"
                    break
                }
                nextInterval = Self.nextPollingDelay(
                    configuredInterval: configuredInterval,
                    previousDelay: nextInterval,
                    succeeded: succeeded
                )
            }

            self.finishPollingTask(id: taskID)
        }
    }

    private func stopPollingLoop() {
        pollingTask?.cancel()
        pollingTask = nil
        pollingTaskID = nil
    }

    private func finishPollingTask(id: UUID) {
        guard pollingTaskID == id else { return }
        pollingTask = nil
        pollingTaskID = nil
    }

    private func updateActivityDependentWork() {
        updateClipboardMonitoring()
        updatePollingForActivity(forceRefresh: true)
    }

    private func updatePollingForActivity(forceRefresh: Bool) {
        guard receiveMode == .polling else { return }

        if hasStarted && Self.shouldMonitorClipboard(
            syncEnabled: syncEnabled,
            requiresSetup: requiresSetup,
            screenAwake: screenAwake,
            sessionActive: sessionActive
        ) {
            startPollingLoop(forceRefresh: forceRefresh)
        } else {
            stopPollingLoop()
        }
    }

    private func updateClipboardMonitoring() {
        if hasStarted && Self.shouldMonitorClipboard(
            syncEnabled: syncEnabled,
            requiresSetup: requiresSetup,
            screenAwake: screenAwake,
            sessionActive: sessionActive
        ) {
            clipboardMonitor.start()
        } else {
            clipboardMonitor.stop()
        }
    }

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

    nonisolated static func shouldUpdateLaunchAtLogin(
        requested: Bool,
        status: LaunchAtLoginStatus
    ) -> Bool {
        switch status {
        case .enabled:
            return !requested
        case .disabled:
            return requested
        case .requiresApproval:
            return false
        }
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

    nonisolated static func shouldMonitorClipboard(
        syncEnabled: Bool,
        requiresSetup: Bool,
        screenAwake: Bool,
        sessionActive: Bool
    ) -> Bool {
        syncEnabled && !requiresSetup && screenAwake && sessionActive
    }

    nonisolated static func nextPollingDelay(
        configuredInterval: TimeInterval,
        previousDelay: TimeInterval,
        succeeded: Bool
    ) -> TimeInterval {
        let configuredInterval = min(max(configuredInterval, 0.5), 60.0)
        return succeeded ? configuredInterval : min(max(previousDelay, configuredInterval) * 2, 60.0)
    }
}
