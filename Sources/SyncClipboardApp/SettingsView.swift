import Foundation
import SwiftUI
import SyncClipboardKit

struct SettingsView: View {
    @ObservedObject var appModel: AppModel
    @State private var isTestingConnection = false
    @State private var isSyncing = false

    var body: some View {
        Form {
            statusSection
            serverSection
            behaviorSection
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

            LabeledContent("Last Push", value: appModel.lastPushText)
            LabeledContent("Last Pull", value: appModel.lastPullText)

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
            TextField("Username", text: $appModel.username, prompt: Text("Account name"))
            SecureField("Password", text: $appModel.password, prompt: Text("Password"))

            HStack(spacing: 8) {
                Button {
                    Task {
                        isTestingConnection = true
                        await appModel.testConnection()
                        isTestingConnection = false
                    }
                } label: {
                    HStack(spacing: 6) {
                        if isTestingConnection {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(isTestingConnection ? "Testing…" : "Test Connection")
                    }
                }
                .disabled(isTestingConnection)

                Spacer()

                Button("Save Changes") {
                    Task { await appModel.persistSettings() }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
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

    private static func pollingIntervalText(for value: Double) -> String {
        if value.rounded(.towardZero) == value {
            return "\(Int(value)) sec"
        }

        return String(format: "%.1f sec", value)
    }
}
