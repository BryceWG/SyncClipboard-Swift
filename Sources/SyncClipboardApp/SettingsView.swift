import Foundation
import SwiftUI
import SyncClipboardKit

private enum ActionState: Equatable {
    case idle
    case running
    case succeeded
    case failed

    var isRunning: Bool { self == .running }

    func title(idle: String, running: String, succeeded: String, failed: String) -> String {
        switch self {
        case .idle: idle
        case .running: running
        case .succeeded: succeeded
        case .failed: failed
        }
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
            reconnectSection
        }
        .formStyle(.grouped)
        .frame(minWidth: 460, idealWidth: 520)
    }

    private var statusSection: some View {
        Section("Status") {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
                    .animation(.snappy(duration: 0.25), value: statusColor)
                Text(appModel.connectionStatusText)
                    .font(.headline)
                Spacer()
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Connection status: \(appModel.connectionStatusText)")

            activityRow("Last Push", date: appModel.lastPushAt)
            activityRow("Last Pull", date: appModel.lastPullAt)

            if !appModel.lastErrorText.isEmpty {
                Text(appModel.lastErrorText)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            HStack(spacing: 8) {
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
                        }
                        Text(isSyncing ? "Syncing…" : "Sync Now")
                    }
                }
                .disabled(!appModel.syncEnabled || appModel.requiresSetup || isSyncing)
            }
        }
    }

    private var serverSection: some View {
        Section("Server") {
            TextField("Server URL", text: $appModel.serverURL, prompt: Text("https://your-server.example"))
                .disabled(serverActionInProgress)
            TextField("Username", text: $appModel.username, prompt: Text("Account name"))
                .disabled(serverActionInProgress)
            SecureField("Password", text: $appModel.password, prompt: Text("Password"))
                .disabled(serverActionInProgress)

            HStack(spacing: 8) {
                Button {
                    Task {
                        connectionTestState = .running
                        connectionTestState = await appModel.testConnection() ? .succeeded : .failed
                    }
                } label: {
                    HStack(spacing: 6) {
                        if connectionTestState.isRunning {
                            ProgressView()
                                .controlSize(.small)
                        } else if connectionTestState == .succeeded {
                            Image(systemName: "checkmark")
                        } else if connectionTestState == .failed {
                            Image(systemName: "xmark")
                        }
                        Text(connectionTestState.title(
                            idle: "Test Connection",
                            running: "Testing…",
                            succeeded: "Connection OK",
                            failed: "Test Failed"
                        ))
                    }
                }
                .disabled(serverActionInProgress)

                Spacer()

                Button {
                    Task {
                        saveState = .running
                        saveState = await appModel.persistSettings() ? .succeeded : .failed
                    }
                } label: {
                    HStack(spacing: 6) {
                        if saveState.isRunning {
                            ProgressView()
                                .controlSize(.small)
                        } else if saveState == .succeeded {
                            Image(systemName: "checkmark")
                        } else if saveState == .failed {
                            Image(systemName: "xmark")
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
        Section {
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
                    }
                }
                .onChange(of: appModel.pollingIntervalSeconds) { _ in
                    Task { await appModel.persistSettings() }
                }
            }
        } header: {
            Text("Receive")
        } footer: {
            if appModel.receiveMode == .polling {
                Text("\(appModel.receiveMode.detailText) The client fetches the latest clipboard from the server at this interval.")
            } else {
                Text(appModel.receiveMode.detailText)
            }
        }
        .animation(.snappy(duration: 0.25), value: appModel.receiveMode)
    }

    private var fileTransferSection: some View {
        Section {
            LabeledContent("Global Shortcut") {
                ShortcutRecorder(shortcut: appModel.transferShortcut) { shortcut in
                    Task { await appModel.updateTransferShortcut(shortcut) }
                }
                .frame(width: 150, height: 26)
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

    private var reconnectSection: some View {
        Section {
            Toggle(appModel.receiveMode == .realtime ? "Auto Reconnect" : "Auto Retry", isOn: $appModel.autoReconnect)
                .onChange(of: appModel.autoReconnect) { _ in
                    Task { await appModel.persistSettings() }
                }
        } footer: {
            Text(appModel.receiveMode == .realtime
                 ? "Reconnect automatically after network interruptions and wake the connection back up after the Mac resumes."
                 : "Keep retrying future polling requests after network failures and refresh again when the Mac wakes.")
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
            } else {
                Text("Never")
            }
        }
    }

    private static func pollingIntervalText(for value: Double) -> String {
        if value.rounded(.towardZero) == value {
            return "\(Int(value)) sec"
        }

        return String(format: "%.1f sec", value)
    }
}
