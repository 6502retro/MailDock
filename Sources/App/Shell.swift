import AppKit
import SwiftUI

/// The Gmail-style window: search bar on top, navigation on the left, and one
/// rounded panel that shows either the message list or a single conversation.
struct MainShell: View {
    @EnvironmentObject private var store: MailStore
    @State private var navExpanded = true
    @State private var cursor: String?
    @FocusState private var searchFocused: Bool
    @FocusState private var panelFocused: Bool

    init() {}

    var body: some View {
        VStack(spacing: 0) {
            TopBar(navExpanded: $navExpanded, searchFocused: $searchFocused) { panelFocused = true }
            HStack(alignment: .top, spacing: 0) {
                NavRail(expanded: navExpanded)
                panel
            }
        }
        .background(Theme.canvas)
        .ignoresSafeArea(.container, edges: .top)
        .overlay(alignment: .bottomTrailing) {
            ComposeDock().padding(.trailing, 24)
        }
        .overlay { MaximizedCompose() }
        .onAppear { panelFocused = true }
        .onChange(of: store.openThread?.id) { old, new in
            if new == nil, let old { cursor = old }
            panelFocused = true
        }
    }

    private var panel: some View {
        Group {
            if let open = store.openThread {
                ConversationPage(summary: open)
            } else {
                ThreadListPage(cursor: $cursor)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .padding(.trailing, 16)
        .padding(.bottom, 16)
        .focusable()
        .focusEffectDisabled()
        .focused($panelFocused)
        .onKeyPress(phases: .down) { press in handle(press) ? .handled : .ignored }
    }

    // MARK: Gmail keyboard shortcuts

    private func handle(_ press: KeyPress) -> Bool {
        // Never treat typing in a text box as a command.
        if NSApp.keyWindow?.firstResponder is NSText { return false }
        guard press.modifiers.subtracting([.shift, .capsLock]).isEmpty else { return false }
        let key = press.characters
        switch key {
        case "/":
            searchFocused = true
            return true
        case "c":
            _ = store.newMessage()
            return true
        default:
            break
        }
        if let open = store.openThread { return handleConversation(key, press.key, open) }
        return handleList(key, press.key)
    }

    private func run(_ action: ThreadAction, _ targets: [ThreadSummary]) {
        guard !targets.isEmpty else { return }
        Task { await store.perform(action, on: targets) }
    }

    private func handleList(_ key: String, _ special: KeyEquivalent) -> Bool {
        let threads = store.threads
        let current = threads.first { $0.id == cursor }
        let targets = store.selectedThreads.isEmpty ? (current.map { [$0] } ?? []) : store.selectedThreads
        if special == .return {
            guard let current else { return false }
            Task { await store.open(current) }
            return true
        }
        switch key {
        case "j", "k":
            guard !threads.isEmpty else { return false }
            let offset = key == "j" ? 1 : -1
            let index = threads.firstIndex { $0.id == cursor } ?? (offset > 0 ? -1 : threads.count)
            cursor = threads[min(max(index + offset, 0), threads.count - 1)].id
        case "o":
            guard let current else { return false }
            Task { await store.open(current) }
        case "x":
            guard let current else { return false }
            if store.selection.contains(current.id) { store.selection.remove(current.id) } else { store.selection.insert(current.id) }
        case "e": run(.archive, targets)
        case "#": run(.trash, targets)
        case "!": run(.spam, targets)
        case "s":
            guard let first = targets.first else { return false }
            run(first.isStarred ? .unstar : .star, targets)
        case "I": run(.markRead, targets)
        case "U": run(.markUnread, targets)
        default:
            return false
        }
        return true
    }

    private func handleConversation(_ key: String, _ special: KeyEquivalent, _ open: ThreadSummary) -> Bool {
        if special == .escape {
            store.closeThread()
            return true
        }
        switch key {
        case "u": store.closeThread()
        case "j": Task { await store.openNeighbor(1) }
        case "k": Task { await store.openNeighbor(-1) }
        case "e": run(.archive, [open])
        case "#": run(.trash, [open])
        case "!": run(.spam, [open])
        case "s": run(open.isStarred ? .unstar : .star, [open])
        case "U": run(.markUnread, [open])
        case "r", "a":
            guard let detail = store.detail, let target = detail.replyTarget else { return false }
            _ = store.reply(target, all: key == "a", account: detail.account, inline: true)
        case "f":
            guard let detail = store.detail, let target = detail.replyTarget else { return false }
            Task { _ = await store.forward(target, account: detail.account, inline: true) }
        default:
            return false
        }
        return true
    }
}

struct TopBar: View {
    @EnvironmentObject private var store: MailStore
    @Binding var navExpanded: Bool
    var searchFocused: FocusState<Bool>.Binding
    let onFinishSearch: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            IconButton(systemName: "line.3.horizontal", help: "Main menu", size: 48, iconSize: 18) {
                withAnimation(.easeInOut(duration: 0.15)) { navExpanded.toggle() }
            }
            HStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 34, height: 34)
                Text("MailDock")
                    .font(.system(size: 22))
                    .foregroundStyle(Theme.secondaryText)
            }
            .frame(width: 176, alignment: .leading)
            SearchBar(focused: searchFocused, onFinish: onFinishSearch)
            Spacer(minLength: 12)
            if store.isOffline {
                Label("Offline", systemImage: "wifi.slash")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.mutedText)
                    .padding(.trailing, 8)
            }
            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: 40, height: 40)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Settings")
            HStack(spacing: -6) {
                ForEach(store.accounts.prefix(4)) { account in
                    Avatar(name: account.title, size: 30, color: account.color)
                        .overlay(Circle().stroke(Theme.canvas, lineWidth: 2))
                        .help(account.email)
                }
            }
            .padding(.leading, 6)
        }
        // Room for the window's close, minimize and zoom buttons.
        .padding(.leading, 76)
        .padding(.trailing, 16)
        .frame(height: 64)
    }
}

struct SearchBar: View {
    @EnvironmentObject private var store: MailStore
    var focused: FocusState<Bool>.Binding
    let onFinish: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16))
                .foregroundStyle(Theme.secondaryText)
            TextField("Search mail", text: $store.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .focused(focused)
                .onSubmit {
                    Task { await store.applySearch() }
                    onFinish()
                }
                .onExitCommand { onFinish() }
            if !store.searchText.isEmpty || !store.activeSearch.isEmpty {
                IconButton(systemName: "xmark", help: "Clear search", size: 30, iconSize: 13) {
                    store.searchText = ""
                    Task { await store.applySearch() }
                    onFinish()
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 46)
        .frame(maxWidth: 720)
        .background(focused.wrappedValue ? Theme.surface : Theme.search, in: Capsule())
        .shadow(color: Color.black.opacity(focused.wrappedValue ? 0.16 : 0), radius: 4, x: 0, y: 1)
    }
}

struct NavRail: View {
    @EnvironmentObject private var store: MailStore
    let expanded: Bool
    @State private var collapsed: Set<String> = []
    @State private var showMore: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ComposeButton(expanded: expanded)
                .padding(.leading, 8)
                .padding(.top, 4)
                .padding(.bottom, 16)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if expanded { full } else { compact }
                }
                .padding(.bottom, 16)
            }
        }
        .frame(width: expanded ? 256 : 72, alignment: .leading)
    }

    private func select(_ mailbox: Mailbox) {
        Task { await store.selectMailbox(mailbox) }
    }

    private func inboxUnread(_ email: String) -> Int {
        store.labels[email]?.first { $0.id == SystemLabel.inbox }?.threadsUnread ?? 0
    }

    private func isSelected(_ mailbox: Mailbox) -> Bool {
        store.mailbox == mailbox && store.activeSearch.isEmpty
    }

    @ViewBuilder private var full: some View {
        if store.accounts.count > 1 {
            NavItem(title: "All Inboxes", icon: "tray.2", count: store.unreadInboxTotal, emphasize: true,
                    selected: isSelected(.allInboxes)) { select(.allInboxes) }
                .padding(.bottom, 4)
        }
        ForEach(store.accounts) { account in
            accountSection(account)
        }
        NavItem(title: "Add account", icon: "plus", count: 0, emphasize: false, selected: false) {
            Task { await store.addAccount() }
        }
        .padding(.top, 10)
    }

    @ViewBuilder private func accountSection(_ account: Account) -> some View {
        let isOpen = !collapsed.contains(account.email)
        AccountHeader(account: account, isOpen: isOpen, unread: inboxUnread(account.email)) {
            if isOpen { collapsed.insert(account.email) } else { collapsed.remove(account.email) }
        }
        if isOpen {
            if account.needsSignIn {
                NavItem(title: "Sign in again", icon: "exclamationmark.circle", count: 0, emphasize: true,
                        selected: false, tint: Theme.warning) {
                    Task { await store.addAccount() }
                }
            }
            let entries = store.systemEntries(for: account.email)
            let extra = Array(entries.dropFirst(4))
            let moreOpen = showMore.contains(account.email) || extra.contains { isSelected($0.mailbox) }
            ForEach(Array(entries.prefix(4))) { item($0) }
            if moreOpen {
                ForEach(extra) { item($0) }
            }
            NavItem(title: moreOpen ? "Less" : "More", icon: moreOpen ? "chevron.up" : "chevron.down",
                    count: 0, emphasize: false, selected: false) {
                if showMore.contains(account.email) { showMore.remove(account.email) } else { showMore.insert(account.email) }
            }
            let labels = store.labelEntries(for: account.email)
            if !labels.isEmpty {
                Text("Labels")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .padding(.leading, 26)
                    .padding(.top, 12)
                    .padding(.bottom, 4)
                ForEach(labels) { item($0) }
            }
        }
    }

    private func item(_ entry: SidebarEntry) -> some View {
        var isDrafts = false
        if case .label(_, let id) = entry.mailbox, id == SystemLabel.draft { isDrafts = true }
        return NavItem(title: entry.title, icon: entry.icon, count: entry.count, emphasize: !isDrafts,
                       selected: isSelected(entry.mailbox)) { select(entry.mailbox) }
    }

    @ViewBuilder private var compact: some View {
        if store.accounts.count > 1 {
            RailIcon(selected: isSelected(.allInboxes), badge: store.unreadInboxTotal, help: "All Inboxes", action: { select(.allInboxes) }) {
                Image(systemName: isSelected(.allInboxes) ? "tray.2.fill" : "tray.2").font(.system(size: 16))
            }
        }
        ForEach(store.accounts) { account in
            RailIcon(selected: store.mailbox?.account == account.email, badge: inboxUnread(account.email), help: account.email,
                     action: { select(.label(account: account.email, id: SystemLabel.inbox)) }) {
                Avatar(name: account.title, size: 26, color: account.color)
            }
        }
    }
}

struct ComposeButton: View {
    @EnvironmentObject private var store: MailStore
    let expanded: Bool
    @State private var hover = false

    var body: some View {
        Button {
            _ = store.newMessage()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "pencil").font(.system(size: 20))
                if expanded { Text("Compose").font(.system(size: 14, weight: .medium)) }
            }
            .foregroundStyle(Theme.composeText)
            .padding(.horizontal, expanded ? 20 : 0)
            .frame(width: expanded ? nil : 56, height: 56)
            .background(Theme.compose, in: RoundedRectangle(cornerRadius: 16))
            .shadow(color: Color.black.opacity(hover ? 0.25 : 0), radius: 3, x: 0, y: 1)
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .disabled(store.accounts.isEmpty)
        .help("Compose")
    }
}

/// Gmail's navigation highlight: flat on the left, rounded on the right.
@MainActor private var navShape: UnevenRoundedRectangle {
    UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0, bottomTrailingRadius: 16, topTrailingRadius: 16)
}

struct NavItem: View {
    let title: String
    let icon: String
    let count: Int
    let emphasize: Bool
    let selected: Bool
    var tint: Color? = nil
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        let bold = selected || (emphasize && count > 0)
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: selected ? filledIcon : icon)
                    .font(.system(size: 15))
                    .frame(width: 20)
                Text(title)
                    .font(.system(size: 14, weight: bold ? .bold : .regular))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if count > 0 {
                    Text(String(count)).font(.system(size: 12, weight: bold ? .bold : .regular))
                }
            }
            .foregroundStyle(tint ?? (selected ? Theme.navSelectedText : Theme.text))
            .padding(.leading, 26)
            .padding(.trailing, 12)
            .frame(height: 32)
            .background(selected ? Theme.navSelected : (hover ? Theme.hover : Color.clear), in: navShape)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .padding(.trailing, 16)
    }

    private var filledIcon: String {
        ["plus", "chevron.down", "chevron.up", "exclamationmark.circle"].contains(icon) ? icon : icon + ".fill"
    }
}

struct AccountHeader: View {
    let account: Account
    let isOpen: Bool
    let unread: Int
    let toggle: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 10) {
                Avatar(name: account.title, size: 26, color: account.color)
                VStack(alignment: .leading, spacing: 0) {
                    Text(account.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    if !account.displayName.isEmpty {
                        Text(account.email)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.mutedText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 4)
                if !isOpen && unread > 0 {
                    Text(String(unread)).font(.system(size: 12, weight: .bold))
                }
                Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.mutedText)
            }
            .foregroundStyle(Theme.text)
            .padding(.leading, 18)
            .padding(.trailing, 12)
            .frame(height: 44)
            .background(hover ? Theme.hover : Color.clear, in: navShape)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .padding(.trailing, 16)
        .padding(.top, 6)
    }
}

struct RailIcon<Content: View>: View {
    let selected: Bool
    let badge: Int
    let help: String
    let action: () -> Void
    let content: Content
    @State private var hover = false

    init(selected: Bool, badge: Int, help: String, action: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.selected = selected
        self.badge = badge
        self.help = help
        self.action = action
        self.content = content()
    }

    var body: some View {
        Button(action: action) {
            content
                .foregroundStyle(Theme.text)
                .frame(width: 56, height: 32)
                .background(selected ? Theme.navSelected : (hover ? Theme.hover : Color.clear), in: Capsule())
                .overlay(alignment: .topTrailing) {
                    if badge > 0 {
                        Text(badge > 99 ? "99+" : String(badge))
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 4)
                            .frame(minWidth: 16, minHeight: 16)
                            .background(Theme.badge, in: Capsule())
                            .offset(x: 2, y: -4)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
        .padding(.leading, 8)
        .padding(.vertical, 4)
    }
}

/// Gmail's dark message box in the bottom-left corner, for undo and errors.
struct Snackbar: View {
    @EnvironmentObject private var store: MailStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let undo = store.undo {
                bar {
                    Text(undo.title)
                    Button("Undo") { Task { await store.performUndo() } }
                        .buttonStyle(.plain)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.snackbarAction)
                    closeButton { store.undo = nil }
                }
                .task(id: undo.title + String(undo.targets.count)) {
                    try? await Task.sleep(nanoseconds: 7_000_000_000)
                    if !Task.isCancelled { store.undo = nil }
                }
            }
            if let banner = store.banner {
                bar {
                    Text(banner).lineLimit(3)
                    closeButton { store.banner = nil }
                }
                .task(id: banner) {
                    try? await Task.sleep(nanoseconds: 12_000_000_000)
                    if !Task.isCancelled, store.banner == banner { store.banner = nil }
                }
            }
        }
        .frame(maxWidth: 560, alignment: .leading)
        .padding(.leading, 24)
        .padding(.bottom, 24)
    }

    private func bar<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 24) { content() }
            .font(.system(size: 14))
            .foregroundStyle(Theme.snackbarText)
            .padding(.leading, 24)
            .padding(.trailing, 12)
            .padding(.vertical, 12)
            .background(Theme.snackbar, in: RoundedRectangle(cornerRadius: 4))
            .shadow(color: Color.black.opacity(0.3), radius: 6, x: 0, y: 2)
    }

    private func closeButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark").font(.system(size: 12))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.snackbarText)
    }
}
