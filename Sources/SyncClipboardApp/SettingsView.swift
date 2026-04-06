import SwiftUI
import SyncClipboardKit

struct SettingsView: View {
    @ObservedObject var appModel: AppModel

    var body: some View {
        Form {
            Section("Server") {
                TextField("Server URL", text: $appModel.serverURL)
                    .textFieldStyle(.roundedBorder)
                TextField("Username", text: $appModel.username)
                    .textFieldStyle(.roundedBorder)
                SecureField("Password", text: $appModel.password)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Button("Test Connection") {
                        Task { await appModel.testConnection() }
                    }
                    Button("Save") {
                        Task { await appModel.persistSettings() }
                    }
                    Button("Sync Now") {
                        Task { await appModel.syncNow() }
                    }
                }
            }

            Section("General") {
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
            }

            Section("Status") {
                LabeledContent("Connection", value: appModel.connectionStatusText)
                LabeledContent("Last Push", value: appModel.lastPushText)
                LabeledContent("Last Pull", value: appModel.lastPullText)
                if !appModel.lastErrorText.isEmpty {
                    LabeledContent("Last Error") {
                        Text(appModel.lastErrorText)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 420)
    }
}
