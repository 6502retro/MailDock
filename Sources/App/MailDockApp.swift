import AppKit
import Security
import SwiftUI
import UserNotifications

struct KeychainStore: SecretStore {
    private let service = "local.maildock.app"

    private func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key]
    }

    func read(_ key: String) -> Data? {
        var request = query(key)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    func write(_ key: String, _ value: Data) throws {
        let update = [kSecValueData as String: value] as CFDictionary
        var status = SecItemUpdate(query(key) as CFDictionary, update)
        if status == errSecItemNotFound {
            var add = query(key)
            add[kSecValueData as String] = value
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw MailError.api(status: Int(status), message: "Could not save to the Keychain.")
        }
    }

    func delete(_ key: String) { SecItemDelete(query(key) as CFDictionary) }
}

@MainActor
enum AppEnvironment {
    static func makeStore() -> MailStore {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MailDock", isDirectory: true)
        return MailStore(secrets: KeychainStore(), disk: DiskStore(root: support))
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Compose windows belong to one run of the app, so don't reopen them.
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
    }
}

@main
struct MailDockApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store: MailStore

    @MainActor init() {
        _store = StateObject(wrappedValue: AppEnvironment.makeStore())
    }

    var body: some Scene {
        Window("MailDock", id: "main") {
            RootView()
                .environmentObject(store)
                .frame(minWidth: 1000, minHeight: 620)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1400, height: 880)
        .commands { MailCommands(store: store) }

        Settings {
            SettingsView()
                .environmentObject(store)
                .frame(width: 520, height: 340)
        }
    }
}

struct MailCommands: Commands {
    @ObservedObject var store: MailStore

    var body: some Commands {
        CommandGroup(replacing: .newItem) { MailMenuNew(store: store) }
        CommandMenu("Message") { MailMenuItems(store: store) }
    }
}

struct MailMenuNew: View {
    @ObservedObject var store: MailStore

    var body: some View {
        Button("New Message") { _ = store.newMessage() }
        .keyboardShortcut("n")
        .disabled(store.accounts.isEmpty)
    }
}

struct MailMenuItems: View {
    @ObservedObject var store: MailStore

    private var hasSelection: Bool { !store.actionTargets.isEmpty }
    private var hasDetail: Bool { store.openThread != nil && store.detail?.replyTarget != nil }

    var body: some View {
        Button("Reply") { compose(all: false) }
            .keyboardShortcut("r").disabled(!hasDetail)
        Button("Reply All") { compose(all: true) }
            .keyboardShortcut("r", modifiers: [.command, .shift]).disabled(!hasDetail)
        Button("Forward") { forward() }
            .keyboardShortcut("f", modifiers: [.command, .shift]).disabled(!hasDetail)
        Divider()
        Button("Archive") { run(.archive) }
            .keyboardShortcut("e").disabled(!hasSelection)
        Button("Move to Trash") { run(.trash) }
            .keyboardShortcut(.delete).disabled(!hasSelection)
        Button("Mark as Spam") { run(.spam) }
            .keyboardShortcut("j", modifiers: [.command, .shift]).disabled(!hasSelection)
        Divider()
        Button("Mark as Unread") { run(.markUnread) }
            .keyboardShortcut("u", modifiers: [.command, .shift]).disabled(!hasSelection)
        Button("Add Star") { run(.star) }
            .keyboardShortcut("l", modifiers: [.command, .shift]).disabled(!hasSelection)
        Divider()
        Button("Back to List") { store.closeThread() }
            .keyboardShortcut("[").disabled(store.openThread == nil)
        Button("Check for New Mail") { Task { await store.reload() } }
            .keyboardShortcut("n", modifiers: [.command, .shift])
    }

    private func run(_ action: ThreadAction) {
        let targets = store.actionTargets
        Task { await store.perform(action, on: targets) }
    }

    private func compose(all: Bool) {
        guard let detail = store.detail, let target = detail.replyTarget else { return }
        _ = store.reply(target, all: all, account: detail.account, inline: true)
    }

    private func forward() {
        guard let detail = store.detail, let target = detail.replyTarget else { return }
        Task { _ = await store.forward(target, account: detail.account, inline: true) }
    }
}

enum Notifier {
    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    static func post(_ threads: [ThreadSummary]) {
        for thread in threads.prefix(5) {
            let content = UNMutableNotificationContent()
            content.title = thread.senders
            content.subtitle = thread.subject
            content.body = thread.snippet
            content.sound = .default
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: thread.id, content: content, trigger: nil))
        }
    }
}
