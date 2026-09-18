import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $model.settings.appearance) {
                    Text("Use System Setting").tag("System")
                    Text("Light").tag("Light")
                    Text("Dark").tag("Dark")
                }
                .pickerStyle(.segmented)
            }

            Section("Transfer") {
                Toggle("Transfer automatically when a card is connected", isOn: $model.settings.autoTransfer)
                Toggle("Group files into YYYY-MM-DD folders", isOn: $model.settings.groupByDate)
                Toggle("Show completion notifications", isOn: $model.settings.showNotifications)
                Toggle("Show the activity log", isOn: $model.settings.showActivityLog)
            }

            Section("System") {
                Toggle("Launch Media Shuttle at login", isOn: Binding(
                    get: { model.startupEnabled },
                    set: { model.setLaunchAtLogin($0) }
                ))
                Text("Launch at Login is managed by macOS in System Settings › General › Login Items.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(8)
        .frame(width: 520, height: 410)
        .onChange(of: model.settings) { _, _ in
            model.saveSettings()
        }
    }
}
