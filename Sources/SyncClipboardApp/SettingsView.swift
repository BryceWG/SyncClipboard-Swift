import Foundation
import SwiftUI
import SyncClipboardKit

private enum ActionState: Equatable {
    case idle
    case running
    case succeeded
    case failed

    var isRunning: Bool { self == .running }

    var tint: Color? {
        switch self {
        case .succeeded: .green
        case .failed: .red
        default: nil
        }
    }

    /// How long a finished state stays on screen before reverting to idle.
    var revertDelay: Duration? {
        switch self {
        case .succeeded: .seconds(2)
        case .failed: .seconds(3)
        default: nil
        }
    }

    func title(idle: String, running: String, succeeded: String, failed: String) -> String {
        let raw: String
        switch self {
        case .idle: raw = idle
        case .running: raw = running
        case .succeeded: raw = succeeded
        case .failed: raw = failed
        }
        return L10n.tr(raw)
    }
}

struct SettingsView: View {
    @ObservedObject var appModel: AppModel
    @State private var connectionTestState = ActionState.idle
    @State private var saveState = ActionState.idle
    @State private var isSyncing = false

    var body: some View {
        Form {
            statusSection
            serverSection
            behaviorSection
            fileTransferSection
            receiveModeSection
        }
        .formStyle(.grouped)
        .frame(minWidth: 460, idealWidth: 520)
    }

    private var statusSection: some View {
        Section("Status") {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: statusSymbol)
                        .symbolReplaceTransition()
                    Text(localizedStatusText)
                        .fontWeight(.semibold)
                }
                .font(.headline)
                .foregroundStyle(statusColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(statusColor.opacity(0.12), in: Capsule())
                .animation(.snappy(duration: 0.25), value: appModel.connectionStatusText)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Connection status: \(localizedStatusText)")

                Spacer()

                Button {
                    Task {
                        isSyncing = true
                        await appModel.syncNow()
                        isSyncing = false
                    }
                } label: {
                    HStack(spacing: 6) {
                        if isSyncing {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                        Text(isSyncing ? "Syncing…" : "Sync Now")
                    }
                }
                .animation(.snappy(duration: 0.2), value: isSyncing)
                .disabled(!appModel.syncEnabled || appModel.requiresSetup || isSyncing)
            }

            activityRow("Last Push", date: appModel.lastPushAt)
            activityRow("Last Pull", date: appModel.lastPullAt)

            if !appModel.lastErrorText.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(appModel.lastErrorText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.callout)
                .foregroundStyle(.red)
                .padding(8)
                .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var serverSection: some View {
        Section("Server") {
            TextField("Server URL", text: $appModel.serverURL, prompt: Text("https://your-server.example"))
                .disabled(serverActionInProgress)
            TextField("Username", text: $appModel.username, prompt: Text("Account name"))
                .textContentType(.username)
                .disabled(serverActionInProgress)
            SecureField("Password", text: $appModel.password, prompt: Text("Password"))
                .textContentType(.password)
                .disabled(serverActionInProgress)

            HStack(spacing: 8) {
                Button {
                    Task {
                        connectionTestState = .running
                        connectionTestState = await appModel.testConnection() ? .succeeded : .failed
                        if let delay = connectionTestState.revertDelay {
                            try? await Task.sleep(for: delay)
                            connectionTestState = .idle
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        if connectionTestState.isRunning {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: connectionTestState == .succeeded
                                  ? "checkmark"
                                  : connectionTestState == .failed ? "xmark" : "network")
                                .symbolReplaceTransition()
                        }
                        Text(connectionTestState.title(
                            idle: "Test Connection",
                            running: "Testing…",
                            succeeded: "Connection OK",
                            failed: "Test Failed"
                        ))
                    }
                    .foregroundStyle(connectionTestState.tint ?? .primary)
                }
                .animation(.snappy(duration: 0.2), value: connectionTestState)
                .disabled(serverActionInProgress)

                Spacer()

                Button {
                    Task {
                        saveState = .running
                        saveState = await appModel.persistSettings() ? .succeeded : .failed
                        if let delay = saveState.revertDelay {
                            try? await Task.sleep(for: delay)
                            saveState = .idle
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        if saveState.isRunning {
                            ProgressView()
                                .controlSize(.small)
                        } else if saveState == .succeeded {
                            Image(systemName: "checkmark")
                                .symbolReplaceTransition()
                        } else if saveState == .failed {
                            Image(systemName: "xmark")
                                .symbolReplaceTransition()
                        }
                        Text(saveState.title(
                            idle: "Save Changes",
                            running: "Saving…",
                            succeeded: "Saved",
                            failed: "Save Failed"
                        ))
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(saveState.tint ?? .accentColor)
                .animation(.snappy(duration: 0.2), value: saveState)
                .disabled(serverActionInProgress)
            }
        }
        .onChange(of: [appModel.serverURL, appModel.username, appModel.password]) { _ in
            connectionTestState = .idle
            saveState = .idle
        }
    }

    private var behaviorSection: some View {
        Section("Behavior") {
            Toggle("Enable Sync", isOn: $appModel.syncEnabled)
                .onChange(of: appModel.syncEnabled) { _ in
                    Task { await appModel.persistSettings() }
                }
            Toggle("Launch at Login", isOn: $appModel.launchAtLogin)
                .onChange(of: appModel.launchAtLogin) { _ in
                    Task { await appModel.persistSettings() }
                }
            Toggle("Show Notifications", isOn: $appModel.showNotifications)
                .onChange(of: appModel.showNotifications) { _ in
                    Task { await appModel.persistSettings() }
                }
            Toggle("Show Dock Icon", isOn: $appModel.showDockIcon)
                .onChange(of: appModel.showDockIcon) { _ in
                    Task { await appModel.persistSettings() }
                }
        }
    }

    private var receiveModeSection: some View {
        Section("Receive") {
            Picker("Receive Mode", selection: $appModel.receiveMode) {
                ForEach(RemoteReceiveMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .onChange(of: appModel.receiveMode) { _ in
                Task { await appModel.persistSettings() }
            }

            if appModel.receiveMode == .polling {
                Stepper(value: $appModel.pollingIntervalSeconds, in: 0.5 ... 60.0, step: 0.5) {
                    HStack {
                        Text("Polling Interval")
                        Spacer()
                        Text(Self.pollingIntervalText(for: appModel.pollingIntervalSeconds))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .onChange(of: appModel.pollingIntervalSeconds) { _ in
                    Task { await appModel.persistSettings() }
                }
            }

            Toggle(appModel.receiveMode == .realtime ? "Auto Reconnect" : "Auto Retry", isOn: $appModel.autoReconnect)
                .onChange(of: appModel.autoReconnect) { _ in
                    Task { await appModel.persistSettings() }
                }
        }
        .animation(.snappy(duration: 0.25), value: appModel.receiveMode)
    }

    private var fileTransferSection: some View {
        Section {
            HStack {
                Text("Global Shortcut")
                Spacer()
                ShortcutRecorder(shortcut: appModel.transferShortcut) { shortcut in
                    Task { await appModel.updateTransferShortcut(shortcut) }
                }
                .frame(width: 150, height: 22)
            }

            TextField("Maximum Transfer Size (MiB)", value: $appModel.maximumTransferSizeMiB, format: .number)
                .onChange(of: appModel.maximumTransferSizeMiB) { value in
                    guard value > 0 else {
                        appModel.maximumTransferSizeMiB = 1
                        return
                    }
                    guard value <= AppModel.maximumTransferSizeMiBLimit else {
                        appModel.maximumTransferSizeMiB = AppModel.maximumTransferSizeMiBLimit
                        return
                    }
                    Task { await appModel.persistSettings() }
                }
        } header: {
            Text("Images and Files")
        } footer: {
            Text("Images and files transfer only on request. Maximum: \(AppModel.maximumTransferSizeMiBLimit) MiB. Downloads are saved to ~/Downloads/SyncClipboard.")
        }
    }

    private var localizedStatusText: String {
        L10n.tr(appModel.connectionStatusText)
    }

    private var statusSymbol: String {
        switch appModel.connectionStatusText {
        case "Connected", "Polling":
            return "checkmark.circle.fill"
        case "Connecting", "Reconnecting":
            return "antenna.radiowaves.left.and.right"
        case "Error", "Missing Config":
            return "exclamationmark.triangle.fill"
        default:
            return "circle.slash"
        }
    }

    private var statusColor: Color {
        switch appModel.connectionStatusText {
        case "Connected", "Polling":
            return .green
        case "Connecting", "Reconnecting":
            return .orange
        case "Error", "Missing Config":
            return .red
        default:
            return Color(.tertiaryLabelColor)
        }
    }

    private var serverActionInProgress: Bool {
        connectionTestState.isRunning || saveState.isRunning
    }

    @ViewBuilder
    private func activityRow(_ title: String, date: Date?) -> some View {
        LabeledContent(title) {
            if let date {
                Text(date, style: .relative)
                    .monospacedDigit()
            } else {
                Text("Never")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private static func pollingIntervalText(for value: Double) -> String {
        if value.rounded(.towardZero) == value {
            return String(format: L10n.tr("%ld sec"), Int(value))
        }

        return String(format: L10n.tr("%.1f sec"), value)
    }
}

extension View {
    /// Smooth symbol swap where supported; falls back to a plain swap on macOS 13.
    @ViewBuilder
    func symbolReplaceTransition() -> some View {
        if #available(macOS 14, *) {
            contentTransition(.symbolEffect(.replace))
        } else {
            self
        }
    }
}
