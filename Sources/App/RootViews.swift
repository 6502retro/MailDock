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
                MainShell()
            }
        }
        .background(Theme.canvas)
        .overlay(alignment: .bottomLeading) { Snackbar() }
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
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 88, height: 88)
            Text("Add your first Gmail account")
                .font(.system(size: 24))
                .foregroundStyle(Theme.text)
            Text("You can add more accounts later. They'll all appear in the sidebar.")
                .font(.system(size: 14))
                .foregroundStyle(Theme.mutedText)
            Button {
                Task { await store.addAccount() }
            } label: {
                Text("Add Gmail account")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.onAccent)
                    .padding(.horizontal, 24)
                    .frame(height: 40)
                    .background(Theme.accent, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(48)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
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
