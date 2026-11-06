import AppKit
import SwiftUI

struct ThreadListPage: View {
    @EnvironmentObject private var store: MailStore
    @Binding var cursor: String?

    var body: some View {
        VStack(spacing: 0) {
            ListToolbar()
            if store.isInboxView { CategoryTabs() }
            Rectangle().fill(Theme.divider).frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(store.threads) { thread in
                            ThreadRow(thread: thread, isCursor: cursor == thread.id)
                                .id(thread.id)
                                .onAppear {
                                    if thread.id == store.threads.last?.id { Task { await store.loadMore() } }
                                }
                        }
                        if store.isLoadingList && !store.threads.isEmpty {
                            ProgressView().controlSize(.small).padding(16)
                        }
                    }
                    // Leave room so the last rows can scroll out from under compose windows.
                    .padding(.bottom, 80)
                }
                .onChange(of: cursor) { _, id in
                    if let id { withAnimation { proxy.scrollTo(id) } }
                }
            }
            .overlay {
                if store.threads.isEmpty { EmptyListView() }
            }
        }
    }
}

struct EmptyListView: View {
    @EnvironmentObject private var store: MailStore

    var body: some View {
        if store.isLoadingList {
            ProgressView()
        } else {
            Text(message)
                .font(.system(size: 14))
                .foregroundStyle(Theme.mutedText)
        }
    }

    private var message: String {
        if !store.activeSearch.isEmpty { return "No messages matched your search." }
        if store.isInboxView && store.category != .all { return "Your \(store.category.title) tab is empty." }
        return "No conversations in \(store.title(of: store.mailbox))."
    }
}

struct ListToolbar: View {
    @EnvironmentObject private var store: MailStore

    var body: some View {
        let selected = store.selectedThreads
        HStack(spacing: 2) {
            SelectAllBox()
            if selected.isEmpty {
                IconButton(systemName: "arrow.clockwise", help: "Refresh") { Task { await store.reload() } }
                ToolbarMenu(systemName: "ellipsis", help: "More") {
                    let unread = store.threads.filter(\.isUnread)
                    Button("Mark all as read") { Task { await store.perform(.markRead, on: unread) } }
                        .disabled(unread.isEmpty)
                }
            } else {
                ThreadActionButtons(targets: selected)
            }
            Spacer()
            if store.isLoadingList {
                ProgressView().controlSize(.small).padding(.trailing, 8)
            }
            Text(rangeText)
                .font(.system(size: 12))
                .foregroundStyle(Theme.mutedText)
        }
        .padding(.leading, 8)
        .padding(.trailing, 16)
        .frame(height: 48)
    }

    private var rangeText: String {
        let count = store.threads.count
        guard count > 0 else { return "" }
        return "1–\(count) of " + (store.canLoadMore ? "many" : String(count))
    }
}

struct SelectAllBox: View {
    @EnvironmentObject private var store: MailStore

    var body: some View {
        let all = Set(store.threads.map(\.id))
        let picked = store.selection.count
        let icon = picked == 0 ? "square" : (picked >= all.count ? "checkmark.square.fill" : "minus.square.fill")
        Menu {
            Button("All") { store.selection = all }
            Button("None") { store.selection = [] }
            Button("Read") { store.selection = Set(store.threads.filter { !$0.isUnread }.map(\.id)) }
            Button("Unread") { store.selection = Set(store.threads.filter(\.isUnread).map(\.id)) }
            Button("Starred") { store.selection = Set(store.threads.filter(\.isStarred).map(\.id)) }
            Button("Unstarred") { store.selection = Set(store.threads.filter { !$0.isStarred }.map(\.id)) }
        } label: {
            Image(systemName: icon).font(.system(size: 15))
        } primaryAction: {
            store.selection = picked == 0 ? all : []
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .frame(width: 52, height: 40)
        .help("Select")
    }
}

/// Archive, spam, delete, read state and labels, shared by the list and conversation toolbars.
struct ThreadActionButtons: View {
    @EnvironmentObject private var store: MailStore
    let targets: [ThreadSummary]

    var body: some View {
        if let first = targets.first {
            HStack(spacing: 2) {
                if first.labelIDs.contains(SystemLabel.trash) {
                    IconButton(systemName: "tray.and.arrow.up", help: "Move to Inbox") { run(.untrash) }
                } else if first.labelIDs.contains(SystemLabel.spam) {
                    IconButton(systemName: "checkmark.shield", help: "Not spam") { run(.notSpam) }
                } else {
                    if first.labelIDs.contains(SystemLabel.inbox) {
                        IconButton(systemName: "archivebox", help: "Archive") { run(.archive) }
                    } else {
                        IconButton(systemName: "tray.and.arrow.down", help: "Move to Inbox") { run(.moveToInbox) }
                    }
                    IconButton(systemName: "exclamationmark.octagon", help: "Report spam") { run(.spam) }
                    IconButton(systemName: "trash", help: "Delete") { run(.trash) }
                }
                Color.clear.frame(width: 12, height: 1)
                if first.isUnread {
                    IconButton(systemName: "envelope.open", help: "Mark as read") { run(.markRead) }
                } else {
                    IconButton(systemName: "envelope.badge", help: "Mark as unread") { run(.markUnread) }
                }
                LabelMenu(targets: targets)
                ToolbarMenu(systemName: "ellipsis", help: "More") {
                    ThreadMenu(targets: targets)
                }
            }
        }
    }

    private func run(_ action: ThreadAction) {
        Task { await store.perform(action, on: targets) }
    }
}

struct LabelMenu: View {
    @EnvironmentObject private var store: MailStore
    let targets: [ThreadSummary]

    var body: some View {
        let sameAccount = Set(targets.map(\.account)).count == 1
        let labels = targets.first.map { store.userLabels($0.account) } ?? []
        ToolbarMenu(systemName: "tag", help: "Labels") {
            if sameAccount, let first = targets.first {
                ForEach(labels) { label in
                    let isOn = first.labelIDs.contains(label.id)
                    Button((isOn ? "✓ " : "") + label.name) {
                        Task { await store.perform(isOn ? .removeLabel(label.id) : .addLabel(label.id), on: targets) }
                    }
                }
            }
        }
        .disabled(!sameAccount || labels.isEmpty)
    }
}

struct ThreadMenu: View {
    @EnvironmentObject private var store: MailStore
    let targets: [ThreadSummary]

    var body: some View {
        if let first = targets.first {
            Button(first.isUnread ? "Mark as read" : "Mark as unread") { run(first.isUnread ? .markRead : .markUnread) }
            Button(first.isStarred ? "Remove star" : "Add star") { run(first.isStarred ? .unstar : .star) }
            Divider()
            if first.labelIDs.contains(SystemLabel.trash) {
                Button("Move to Inbox") { run(.untrash) }
            } else if first.labelIDs.contains(SystemLabel.spam) {
                Button("Not spam") { run(.notSpam) }
            } else {
                if first.labelIDs.contains(SystemLabel.inbox) {
                    Button("Archive") { run(.archive) }
                } else {
                    Button("Move to Inbox") { run(.moveToInbox) }
                }
                Button("Delete") { run(.trash) }
                Button("Report spam") { run(.spam) }
            }
        }
    }

    private func run(_ action: ThreadAction) {
        Task { await store.perform(action, on: targets) }
    }
}

struct CategoryTabs: View {
    @EnvironmentObject private var store: MailStore

    var body: some View {
        HStack(spacing: 0) {
            ForEach(InboxCategory.allCases) { category in
                CategoryTab(category: category, selected: store.category == category) {
                    Task { await store.selectCategory(category) }
                }
            }
            Spacer(minLength: 0)
        }
    }
}

struct CategoryTab: View {
    let category: InboxCategory
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 16))
                Text(category.title).font(.system(size: 14, weight: selected ? .semibold : .regular))
                Spacer(minLength: 0)
            }
            .foregroundStyle(selected ? color : Theme.secondaryText)
            .padding(.leading, 16)
            .frame(minWidth: 0, maxWidth: 210, minHeight: 52, maxHeight: 52, alignment: .leading)
            .background(hover ? Theme.hover : Color.clear)
            .overlay(alignment: .bottom) {
                if selected {
                    UnevenRoundedRectangle(topLeadingRadius: 3, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: 3)
                        .fill(color)
                        .frame(height: 3)
                        .padding(.horizontal, 8)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }

    private var icon: String {
        switch category {
        case .all: return "tray.full"
        case .primary: return "tray"
        case .promotions: return "tag"
        case .social: return "person.2"
        case .updates: return "info.circle"
        case .forums: return "bubble.left.and.bubble.right"
        }
    }

    private var color: Color {
        switch category {
        case .promotions: return Theme.color(0x188038, 0x81C995)
        case .updates: return Theme.color(0xB06000, 0xFCAD70)
        case .forums: return Theme.color(0x7B1FA2, 0xD7AEFB)
        default: return Theme.accent
        }
    }
}

struct CheckBox: View {
    let checked: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: checked ? "checkmark.square.fill" : "square")
                .font(.system(size: 15))
                .foregroundStyle(checked ? Theme.text : Theme.mutedText)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(checked ? "Deselect" : "Select")
    }
}

struct StarButton: View {
    let starred: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: starred ? "star.fill" : "star")
                .font(.system(size: 15))
                .foregroundStyle(starred ? Theme.star : Theme.mutedText)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(starred ? "Starred" : "Not starred")
    }
}

/// One line per conversation, like Gmail: checkbox, star, sender, subject and
/// preview, then the date, which turns into quick actions on hover.
struct ThreadRow: View {
    @EnvironmentObject private var store: MailStore
    let thread: ThreadSummary
    let isCursor: Bool
    @State private var hover = false

    private var checked: Bool { store.selection.contains(thread.id) }
    private var showsAccount: Bool { store.accounts.count > 1 && store.mailbox?.account == nil }

    var body: some View {
        HStack(spacing: 0) {
            CheckBox(checked: checked) {
                if checked { store.selection.remove(thread.id) } else { store.selection.insert(thread.id) }
            }
            StarButton(starred: thread.isStarred) {
                Task { await store.perform(thread.isStarred ? .unstar : .star, on: [thread]) }
            }
            HStack(spacing: 6) {
                if showsAccount, let account = store.account(thread.account) {
                    Circle().fill(account.color).frame(width: 8, height: 8).help(account.email)
                }
                senderText.font(.system(size: 14)).lineLimit(1)
            }
            .frame(width: 200, alignment: .leading)
            .padding(.leading, 6)
            .padding(.trailing, 16)
            let chips = chipNames
            if !chips.isEmpty {
                HStack(spacing: 4) {
                    ForEach(chips, id: \.self) { LabelChip(name: $0) }
                }
                .padding(.trailing, 6)
            }
            subjectLine.frame(maxWidth: .infinity, alignment: .leading)
            trailing.frame(width: 140, alignment: .trailing)
        }
        .padding(.leading, 8)
        .padding(.trailing, 16)
        .frame(height: 40)
        .background(background)
        .overlay(alignment: .leading) {
            if isCursor { Rectangle().fill(Theme.accent).frame(width: 3) }
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.rowDivider).frame(height: 1)
        }
        .shadow(color: Color.black.opacity(hover ? 0.18 : 0), radius: 2, x: 0, y: 1)
        .zIndex(hover ? 1 : 0)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { Task { await store.open(thread) } }
        .contextMenu { ThreadMenu(targets: checked ? store.selectedThreads : [thread]) }
    }

    private var background: Color {
        checked ? Theme.checkedRow : (thread.isUnread ? Theme.unreadRow : Theme.readRow)
    }

    private var senderText: Text {
        let isDraftOnly = thread.messageCount == 1 && thread.labelIDs.contains(SystemLabel.draft)
        if isDraftOnly { return Text("Draft").foregroundStyle(Theme.danger) }
        var text = Text(thread.senders.isEmpty ? thread.account : thread.senders)
            .fontWeight(thread.isUnread ? .bold : .regular)
            .foregroundStyle(Theme.text)
        if thread.messageCount > 1 {
            text = text + Text(" \(thread.messageCount)").font(.system(size: 12)).foregroundStyle(Theme.mutedText)
        }
        if thread.labelIDs.contains(SystemLabel.draft) {
            text = text + Text(", ").foregroundStyle(Theme.mutedText) + Text("Draft").foregroundStyle(Theme.danger)
        }
        return text
    }

    private var subjectLine: some View {
        (Text(thread.subject.isEmpty ? "(no subject)" : thread.subject)
            .fontWeight(thread.isUnread ? .bold : .regular)
            .foregroundStyle(Theme.text)
         + Text(thread.snippet.isEmpty ? "" : " - " + thread.snippet)
            .foregroundStyle(Theme.mutedText))
            .font(.system(size: 14))
            .lineLimit(1)
    }

    private var chipNames: [String] {
        var names = [String]()
        if !store.activeSearch.isEmpty && thread.labelIDs.contains(SystemLabel.inbox) { names.append("Inbox") }
        var current: String?
        if case .label(_, let id) = store.mailbox { current = id }
        names += store.userLabels(thread.account)
            .filter { thread.labelIDs.contains($0.id) && $0.id != current }
            .map(\.name)
        return Array(names.prefix(3))
    }

    @ViewBuilder private var trailing: some View {
        if hover {
            HStack(spacing: 0) {
                if thread.labelIDs.contains(SystemLabel.trash) {
                    IconButton(systemName: "tray.and.arrow.up", help: "Move to Inbox", size: 32, iconSize: 15) { run(.untrash) }
                } else {
                    if thread.labelIDs.contains(SystemLabel.inbox) {
                        IconButton(systemName: "archivebox", help: "Archive", size: 32, iconSize: 15) { run(.archive) }
                    }
                    IconButton(systemName: "trash", help: "Delete", size: 32, iconSize: 15) { run(.trash) }
                }
                if thread.isUnread {
                    IconButton(systemName: "envelope.open", help: "Mark as read", size: 32, iconSize: 15) { run(.markRead) }
                } else {
                    IconButton(systemName: "envelope.badge", help: "Mark as unread", size: 32, iconSize: 15) { run(.markUnread) }
                }
            }
        } else {
            HStack(spacing: 8) {
                if thread.hasAttachment {
                    Image(systemName: "paperclip").font(.system(size: 12)).foregroundStyle(Theme.mutedText)
                }
                Text(DateText.short(thread.date))
                    .font(.system(size: 12, weight: thread.isUnread ? .bold : .regular))
                    .foregroundStyle(thread.isUnread ? Theme.text : Theme.mutedText)
            }
        }
    }

    private func run(_ action: ThreadAction) {
        Task { await store.perform(action, on: [thread]) }
    }
}
