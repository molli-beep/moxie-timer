import SwiftUI

/// Settings → Notion: the integration token, what to sync, and a Sync now button.
struct NotionSettingsSection: View {
    @Environment(AppSettings.self) private var settings
    @Environment(NotionSync.self) private var notion
    @State private var showDatabases = false
    @State private var isTesting = false

    var body: some View {
        @Bindable var settings = settings

        VStack(alignment: .leading, spacing: 8) {
            CapsLabel("Notion")
            Text("Keeps your Notion Projects and Task Tracker in step with Moxie, and mirrors time logged here into the Time Tracker. Moxie is the source of truth; planning fields you add in Notion are never touched.")
                .font(.system(size: 10))
                .foregroundStyle(Theme.faint)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                CapsLabel("Integration token")
                FieldBox {
                    SecureField("secret_… from Settings → Connections → Develop or manage integrations", text: $settings.notionToken)
                        .textFieldStyle(.plain)
                }
                Text("Create an internal integration named Moxie Timer, then add it to the four databases below with ··· → Connections. The token is stored in your Mac's Keychain.")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Toggle("Keep Notion up to date", isOn: $settings.notionEnabled)
            Toggle("Only tasks assigned to me (or unassigned)", isOn: $settings.notionOnlyMine)

            VStack(alignment: .leading, spacing: 6) {
                CapsLabel("Statuses offered at Finish")
                FieldBox {
                    TextField(AppSettings.defaultFinishStatuses, text: $settings.finishStatuses)
                        .textFieldStyle(.plain)
                }
                Text("Comma-separated Notion status names, shown alongside Done and “Just save the time”. Moxie gets the same stage when the project has one with that name.")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Text("Every")
                Picker("", selection: $settings.notionSyncMinutes) {
                    ForEach([5, 15, 30, 60], id: \.self) { Text("\(String($0)) min").tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .onChange(of: settings.notionSyncMinutes) { notion.schedule() }
                Text("plus whenever you finish a task or log time.")
                    .foregroundStyle(Theme.muted)
            }
            .font(.system(size: 12))

            HStack(spacing: 8) {
                Button {
                    Task { await notion.sync(userInitiated: true) }
                } label: {
                    HStack(spacing: 6) {
                        if notion.isSyncing { ProgressView().controlSize(.small) }
                        Text("Sync now")
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!settings.notionIsConfigured || notion.isSyncing)

                Button {
                    isTesting = true
                    Task {
                        await notion.testConnection()
                        isTesting = false
                    }
                } label: {
                    HStack(spacing: 6) {
                        if isTesting { ProgressView().controlSize(.small) }
                        Text("Test connection")
                    }
                }
                .buttonStyle(ChipButtonStyle())
                .disabled(settings.makeNotion() == nil || isTesting)
            }

            if let status {
                Text(status.text)
                    .font(.system(size: 11))
                    .foregroundStyle(status.isError ? Theme.danger : Theme.running)
                    .fixedSize(horizontal: false, vertical: true)
            }

            DisclosureGroup("Databases", isExpanded: $showDatabases) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Data source ids from your Virtually Molli OS workspace. Change these only if you move the databases.")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.faint)
                        .fixedSize(horizontal: false, vertical: true)
                    databaseField("Task Tracker", text: $settings.notionTasksDB)
                    databaseField("Projects", text: $settings.notionProjectsDB)
                    databaseField("Clients", text: $settings.notionClientsDB)
                    databaseField("Time Tracker", text: $settings.notionTimeDB)
                    Button("Forget sync links") { notion.resetLinks() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.navy)
                        .help("The next sync re-matches every record by its Moxie ID. Nothing in Notion is deleted.")
                }
                .padding(.top, 6)
            }
            .font(.system(size: 12, weight: .semibold))
        }
        .toggleStyle(.switch)
        .tint(Theme.navy)
        .controlSize(.small)
        .font(.system(size: 12))
    }

    private func databaseField(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.muted)
            FieldBox {
                TextField("data source id", text: text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
            }
        }
    }

    private var status: (text: String, isError: Bool)? {
        if let result = notion.testResult { return result }
        switch notion.state {
        case let .failed(message): return (message, true)
        case .syncing: return ("Syncing…", false)
        case .idle:
            guard let last = notion.lastSynced else { return nil }
            let when = last.formatted(date: .omitted, time: .shortened)
            return ("Last sync \(when): \(notion.summary ?? "done").", false)
        }
    }
}
