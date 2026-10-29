import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(Catalog.self) private var catalog
    @Environment(WidgetUI.self) private var ui

    @State private var users: [MoxieUser] = []
    @State private var status: String?
    @State private var statusIsError = false
    @State private var isTesting = false

    var body: some View {
        @Bindable var settings = settings

        ScrollView {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                if settings.isConfigured {
                    Button { ui.route = nil } label: {
                        Label("Settings", systemImage: "chevron.left")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text("Connect to Moxie").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.ink)
                }
                WindowDragArea().frame(maxWidth: .infinity, minHeight: 24)
                Button { ui.collapse() } label: {
                    Image(systemName: "chevron.up").foregroundStyle(Theme.muted).frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
            }

            field("API key") {
                SecureField("Paste your workspace API key", text: $settings.apiKey)
                    .textFieldStyle(.plain)
                    .onChange(of: settings.apiKey) { catalog.reset() }
            }

            VStack(alignment: .leading, spacing: 6) {
                CapsLabel("Your email in Moxie")
                HStack(spacing: 6) {
                    FieldBox {
                        TextField("you@example.com", text: $settings.userEmail)
                            .textFieldStyle(.plain)
                    }
                    Menu {
                        if users.isEmpty {
                            Button("Load workspace users") { Task { await loadUsers() } }
                        } else {
                            ForEach(users, id: \.self) { user in
                                Button("\(user.displayName) — \(user.user.email ?? "")") {
                                    settings.userEmail = user.user.email ?? ""
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "person.crop.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 36)
                    .disabled(settings.makeAPI() == nil)
                    .help("Pick from workspace users")
                }
                Text("Time is logged for this user.")
                    .font(.system(size: 11)).foregroundStyle(Theme.muted)
            }

            field("Base URL") {
                TextField("https://pod00.withmoxie.dev/api/public", text: $settings.baseURL)
                    .textFieldStyle(.plain)
                    .onChange(of: settings.baseURL) { catalog.reset() }
            }

            HStack {
                Button {
                    Task { await testConnection() }
                } label: {
                    HStack(spacing: 6) {
                        if isTesting { ProgressView().controlSize(.small) }
                        Text("Test connection")
                    }
                }
                .buttonStyle(ChipButtonStyle())
                .disabled(settings.makeAPI() == nil || isTesting)

                if let status {
                    Text(status)
                        .font(.system(size: 11))
                        .foregroundStyle(statusIsError ? Theme.danger : Theme.running)
                        .lineLimit(2)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Toggle("Keep widget above other windows", isOn: $settings.keepOnTop)
                Toggle("Show on every Space & full-screen app", isOn: $settings.showOnAllSpaces)
                Toggle("Hide the widget while a timer runs (\(HotKey.toggleDescription) or stopping brings it back)",
                       isOn: $settings.autoHideWhileRunning)
                Toggle("Close the card when I click outside it", isOn: $settings.closeOnOutsideClick)
                Toggle("Open at login", isOn: $settings.launchAtLogin)
            }
            .toggleStyle(.switch)
            .tint(Theme.navy)
            .controlSize(.small)
            .font(.system(size: 12))

            Divider()

            FocusSettingsSection()

            Divider()

            ReviewSettingsSection()

            Divider()

            NotionSettingsSection()

            Divider()

            DistractionSettingsSection()

            Divider()

            CallSettingsSection()

            Divider()

            Text("The pet and its voice have their own tab: Pet & Voice.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.muted)

            Divider()

            AISettingsSection()

            Divider()

            DataSettingsSection()

            Divider()

            UpdatesSection()

            Divider()

            HStack {
                Button("Hide widget") { ui.onVisibilityRequest?(false) }
                    .buttonStyle(ChipButtonStyle())
                Spacer()
                Button("Quit Moxie Timer") { NSApp.terminate(nil) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.danger)
            }

            Text("In Moxie open Custom API and choose Enable, then copy the API key and the workspace base URL shown there. The key is stored in your Mac's Keychain.\n\nUnofficial app — not affiliated with or endorsed by Moxie. Provided as is, without warranty; use at your own risk.")
                .font(.system(size: 10))
                .foregroundStyle(Theme.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        }
        .frame(height: 580)
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            CapsLabel(label)
            FieldBox { content() }
        }
    }

    private func loadUsers() async {
        guard let api = settings.makeAPI() else { return }
        do {
            users = try await api.users()
        } catch {
            setStatus(error.localizedDescription, isError: true)
        }
    }

    private func testConnection() async {
        guard let api = settings.makeAPI() else { return }
        isTesting = true
        defer { isTesting = false }
        do {
            let clients = try await api.clients()
            setStatus("Connected · \(clients.count) clients", isError: false)
            await catalog.loadClients(force: true)
            if users.isEmpty { users = (try? await api.users()) ?? [] }
            if settings.userEmail.isEmpty, users.count == 1, let email = users.first?.user.email {
                settings.userEmail = email
            }
        } catch {
            setStatus(error.localizedDescription, isError: true)
        }
    }

    private func setStatus(_ message: String, isError: Bool) {
        status = message
        statusIsError = isError
    }
}
