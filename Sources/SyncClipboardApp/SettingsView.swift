import Foundation
import SwiftUI
import SyncClipboardKit

struct SettingsView: View {
    @ObservedObject var appModel: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                headerSection
                serverSection
                behaviorSection
                statusSection
            }
            .padding(24)
        }
        .frame(minWidth: 680, minHeight: 560)
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SyncClipboard-Swift")
                .font(.system(size: 24, weight: .semibold))
            Text("Minimal macOS clipboard sync client for your self-hosted server.")
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                statusBadge(title: "Connection", value: appModel.connectionStatusText)
                statusBadge(title: "Last Push", value: appModel.lastPushText)
                statusBadge(title: "Last Pull", value: appModel.lastPullText)
            }
            .padding(.top, 6)
        }
    }

    private var serverSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                formRow("Server URL") {
                    TextField("https://your-server.example", text: $appModel.serverURL)
                        .textFieldStyle(.roundedBorder)
                }
                formRow("Username") {
                    TextField("Account name", text: $appModel.username)
                        .textFieldStyle(.roundedBorder)
                }
                formRow("Password") {
                    SecureField("Password", text: $appModel.password)
                        .textFieldStyle(.roundedBorder)
                }
                HStack(spacing: 10) {
                    Button("Test Connection") {
                        Task { await appModel.testConnection() }
                    }
                    Button("Save Changes") {
                        Task { await appModel.persistSettings() }
                    }
                    .keyboardShortcut(.defaultAction)
                    Button("Sync Now") {
                        Task { await appModel.syncNow() }
                    }
                    .disabled(!appModel.syncEnabled || appModel.requiresSetup)
                }
            }
        } label: {
            Label("Server", systemImage: "externaldrive.connected.to.line.below")
        }
    }

    private var behaviorSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
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
                Divider()
                formRow("Receive Mode") {
                    Picker("Receive Mode", selection: $appModel.receiveMode) {
                        ForEach(RemoteReceiveMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onChange(of: appModel.receiveMode) { _ in
                        Task { await appModel.persistSettings() }
                    }
                }
                Text(appModel.receiveMode.detailText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if appModel.receiveMode == .polling {
                    formRow("Polling Interval") {
                        Stepper(value: $appModel.pollingIntervalSeconds, in: 0.5 ... 60.0, step: 0.5) {
                            Text("\(Self.pollingIntervalText(for: appModel.pollingIntervalSeconds))")
                        }
                        .onChange(of: appModel.pollingIntervalSeconds) { _ in
                            Task { await appModel.persistSettings() }
                        }
                    }
                    Text("How often the client fetches the latest clipboard from the server while polling mode is enabled.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Toggle(appModel.receiveMode == .realtime ? "Auto Reconnect" : "Auto Retry", isOn: $appModel.autoReconnect)
                    .onChange(of: appModel.autoReconnect) { _ in
                        Task { await appModel.persistSettings() }
                    }
                Text(appModel.receiveMode == .realtime
                     ? "Reconnect automatically after network interruptions and wake the connection back up after the Mac resumes."
                     : "Keep retrying future polling requests after network failures and refresh again when the Mac wakes.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } label: {
            Label("Behavior", systemImage: "slider.horizontal.3")
        }
    }

    private var statusSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                formRow("Connection") {
                    Text(appModel.connectionStatusText)
                }
                formRow("Last Push") {
                    Text(appModel.lastPushText)
                }
                formRow("Last Pull") {
                    Text(appModel.lastPullText)
                }
                if !appModel.lastErrorText.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Last Error")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                        Text(appModel.lastErrorText)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
            }
        } label: {
            Label("Diagnostics", systemImage: "waveform.path.ecg")
        }
    }

    private func formRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func statusBadge(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.medium))
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private static func pollingIntervalText(for value: Double) -> String {
        if value.rounded(.towardZero) == value {
            return "\(Int(value)) sec"
        }

        return String(format: "%.1f sec", value)
    }
}
