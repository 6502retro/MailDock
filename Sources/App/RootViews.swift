import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @EnvironmentObject private var store: MailStore

    var body: some View {
        Group {
            if store.clientConfig == nil {
                SetupView()
            } else if store.accounts.isEmpty {
                WelcomeView()
            } else {
                MainSplitView()
            }
        }
        .overlay(alignment: .bottom) { StatusOverlay() }
        .sheet(isPresented: Binding(get: { store.isSigningIn }, set: { _ in })) { SignInWaitingView() }
        .onAppear {
            store.openURL = { NSWorkspace.shared.open($0) }
            store.onNewMail = { Notifier.post($0) }
            Notifier.requestPermission()
            store.start()
        }
        .onChange(of: store.unreadInboxTotal) { _, total in
            NSApp.dockTile.badgeLabel = total > 0 ? String(total) : nil
        }
    }
}

struct SignInWaitingView: View {
    @EnvironmentObject private var store: MailStore

    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
            Text("Finish signing in with Google").font(.headline)
            Text("Google requires its sign-in page to open in your default browser. Come back here when it says you're signed in.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Cancel") { store.cancelSignIn() }
        }
        .padding(28)
        .frame(width: 400)
    }
}

struct StatusOverlay: View {
    @EnvironmentObject private var store: MailStore

    var body: some View {
        VStack(spacing: 8) {
            if let undo = store.undo {
                HStack(spacing: 14) {
                    Text(undo.title)
                    Button("Undo") { Task { await store.performUndo() } }
                        .buttonStyle(.link)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(.regularMaterial, in: Capsule())
                .shadow(radius: 4)
                .task(id: undo.title + String(undo.targets.count)) {
                    try? await Task.sleep(nanoseconds: 7_000_000_000)
                    if !Task.isCancelled { store.undo = nil }
                }
            }
            if let banner = store.banner {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(banner).lineLimit(3)
                    Button {
                        store.banner = nil
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                .shadow(radius: 4)
            }
            if store.isOffline {
                Label("Offline", systemImage: "wifi.slash")
                    .font(.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(.regularMaterial, in: Capsule())
            }
        }
        .padding(.bottom, 14)
        .frame(maxWidth: 560)
    }
}

/// Shown once, to connect the app to the user's own Google Cloud client.
struct SetupView: View {
    @EnvironmentObject private var store: MailStore
    @State private var clientID = ""
    @State private var clientSecret = ""
    @State private var problem: String?

    private let steps = [
        "In Google Cloud, create a project and enable the Gmail API.",
        "Under Google Auth Platform, set up the app with the audience External.",
        "Under Audience, click Publish app so it says In production. In Testing, Google signs you out every 7 days.",
        "Under Data Access, add the scope gmail.modify.",
        "Under Clients, create a Desktop app client and download its JSON file.",
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Connect MailDock to Gmail").font(.largeTitle.weight(.semibold))
                Text("Your mail goes directly between this Mac and Google. To allow that, Google needs a small sign-in client that belongs to you. This takes about ten minutes and is only needed once.")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("\(index + 1).").bold().monospacedDigit()
                            Text(step)
                        }
                    }
                }
                Link("Open Google Cloud Console", destination: URL(string: "https://console.cloud.google.com/apis/library/gmail.googleapis.com")!)
                Divider()
                Button("Choose the Downloaded JSON File…", action: chooseFile)
                    .buttonStyle(.borderedProminent)
                DisclosureGroup("Or enter the details by hand") {
                    VStack(alignment: .trailing) {
                        TextField("Client ID", text: $clientID)
                        SecureField("Client secret", text: $clientSecret)
                        Button("Save") { save(OAuthClientConfig(clientID: clientID.trimmingCharacters(in: .whitespacesAndNewlines), clientSecret: clientSecret.trimmingCharacters(in: .whitespacesAndNewlines))) }
                            .disabled(clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .textFieldStyle(.roundedBorder)
                    .padding(.top, 6)
                }
                if let problem { Text(problem).foregroundStyle(.red) }
            }
            .padding(36)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            save(try OAuthClientConfig.parse(json: Data(contentsOf: url)))
        } catch {
            problem = error.localizedDescription
        }
    }

    private func save(_ config: OAuthClientConfig) {
        do {
            try store.setClient(config)
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }
}

struct WelcomeView: View {
    @EnvironmentObject private var store: MailStore

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "tray.2.fill").font(.system(size: 54)).foregroundStyle(.tint)
            Text("Add your first Gmail account").font(.title.weight(.semibold))
            Button("Add Gmail Account") { Task { await store.addAccount() } }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct SettingsView: View {
    @EnvironmentObject private var store: MailStore
    @State private var confirmRemoval: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Accounts").font(.headline)
            List(store.accounts) { account in
                HStack {
                    Circle().fill(account.color).frame(width: 10, height: 10)
                    VStack(alignment: .leading) {
                        Text(account.email)
                        if !account.displayName.isEmpty {
                            Text(account.displayName).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Remove") { confirmRemoval = account.email }
                }
            }
            HStack {
                Button("Add Gmail Account") { Task { await store.addAccount() } }
                    .disabled(store.clientConfig == nil)
                Spacer()
                Text("Removing an account signs it out of MailDock. Your mail stays in Gmail.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .alert("Remove this account?", isPresented: Binding(get: { confirmRemoval != nil }, set: { if !$0 { confirmRemoval = nil } })) {
            Button("Remove", role: .destructive) {
                if let email = confirmRemoval { Task { await store.removeAccount(email) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmRemoval ?? "")
        }
    }
}

struct MainSplitView: View {
    @EnvironmentObject private var store: MailStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } content: {
            ThreadListView()
                .navigationSplitViewColumnWidth(min: 300, ideal: 380, max: 560)
        } detail: {
            ReaderView()
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    if let id = store.newMessage() { openWindow(id: "compose", value: id) }
                } label: {
                    Label("New Message", systemImage: "square.and.pencil")
                }
                .help("New Message")
            }
        }
    }
}

struct SidebarView: View {
    @EnvironmentObject private var store: MailStore
    @State private var collapsed: Set<String> = []

    private var selection: Binding<Mailbox?> {
        Binding(get: { store.mailbox }, set: { new in Task { await store.selectMailbox(new) } })
    }

    var body: some View {
        List(selection: selection) {
            if store.accounts.count > 1 {
                Label("All Inboxes", systemImage: "tray.2")
                    .badge(store.unreadInboxTotal)
                    .tag(Mailbox.allInboxes)
            }
            ForEach(store.accounts) { account in
                Section(isExpanded: expansion(for: account.email)) {
                    if account.needsSignIn {
                        Button {
                            Task { await store.addAccount() }
                        } label: {
                            Label("Sign in again", systemImage: "exclamationmark.circle")
                                .foregroundStyle(.orange)
                        }
                        .buttonStyle(.plain)
                    }
                    ForEach(store.sidebarEntries(for: account.email)) { entry in
                        Label(entry.title, systemImage: entry.icon)
                            .badge(entry.count)
                            .tag(entry.mailbox)
                    }
                } header: {
                    HStack(spacing: 6) {
                        Circle().fill(account.color).frame(width: 8, height: 8)
                        Text(account.email).lineLimit(1).truncationMode(.middle)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            Button {
                Task { await store.addAccount() }
            } label: {
                Label("Add Account", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(10)
            .background(.bar)
        }
    }

    private func expansion(for email: String) -> Binding<Bool> {
        Binding(
            get: { !collapsed.contains(email) },
            set: { open in
                if open { collapsed.remove(email) } else { collapsed.insert(email) }
            })
    }
}
