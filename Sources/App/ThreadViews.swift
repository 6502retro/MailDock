import AppKit
import SwiftUI

enum DateText {
    static func short(_ date: Date) -> String {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        if calendar.isDateInToday(date) {
            formatter.timeStyle = .short
            formatter.dateStyle = .none
        } else if calendar.isDate(date, equalTo: Date(), toGranularity: .year) {
            formatter.setLocalizedDateFormatFromTemplate("MMMd")
        } else {
            formatter.dateStyle = .short
            formatter.timeStyle = .none
        }
        return formatter.string(from: date)
    }

    static func full(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

struct ThreadListView: View {
    @EnvironmentObject private var store: MailStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        List(selection: $store.selection) {
            ForEach(store.threads) { thread in
                ThreadRow(thread: thread)
                    .tag(thread.id)
                    .onAppear {
                        if thread.id == store.threads.last?.id {
                            Task { await store.loadMore() }
                        }
                    }
            }
            if store.isLoadingList && !store.threads.isEmpty {
                HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
            }
        }
        .listStyle(.inset)
        .overlay {
            if store.threads.isEmpty {
                if store.isLoadingList {
                    ProgressView()
                } else {
                    Text(store.activeSearch.isEmpty ? "Nothing here" : "No results")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .safeAreaInset(edge: .top) {
            if store.isInboxView {
                Picker("Category", selection: Binding(
                    get: { store.category },
                    set: { new in Task { await store.selectCategory(new) } })) {
                    ForEach(InboxCategory.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(8)
                .background(.bar)
            }
        }
        .navigationTitle(store.title(of: store.mailbox))
        .searchable(text: $store.searchText, placement: .toolbar, prompt: "Search mail")
        .onSubmit(of: .search) { Task { await store.applySearch() } }
        .onChange(of: store.searchText) { _, value in
            if value.isEmpty && !store.activeSearch.isEmpty { Task { await store.applySearch() } }
        }
        .onChange(of: store.selection) { _, _ in
            Task { await store.openSelected() }
        }
        .contextMenu(forSelectionType: String.self) { ids in
            let targets = store.threads.filter { ids.contains($0.id) }
            ThreadMenu(targets: targets)
        }
        .onKeyPress(phases: .down) { press in
            handleKey(press.characters) ? .handled : .ignored
        }
    }

    /// Gmail's single-key shortcuts, active while the message list has focus.
    private func handleKey(_ key: String) -> Bool {
        let targets = store.selectedThreads
        switch key {
        case "e": run(.archive, targets)
        case "#": run(.trash, targets)
        case "!": run(.spam, targets)
        case "s":
            guard let first = targets.first else { return false }
            run(first.isStarred ? .unstar : .star, targets)
        case "U", "u": run(.markUnread, targets)
        case "j": move(by: 1)
        case "k": move(by: -1)
        case "c":
            if let id = store.newMessage() { openWindow(id: "compose", value: id) }
        case "r", "a":
            guard let detail = store.detail, let target = detail.replyTarget,
                  let id = store.reply(target, all: key == "a", account: detail.account) else { return false }
            openWindow(id: "compose", value: id)
        case "f":
            guard let detail = store.detail, let target = detail.replyTarget else { return false }
            Task {
                if let id = await store.forward(target, account: detail.account) { openWindow(id: "compose", value: id) }
            }
        default:
            return false
        }
        return true
    }

    private func run(_ action: ThreadAction, _ targets: [ThreadSummary]) {
        Task { await store.perform(action, on: targets) }
    }

    private func move(by offset: Int) {
        guard !store.threads.isEmpty else { return }
        let current = store.threads.firstIndex { store.selection.contains($0.id) } ?? -offset
        let next = min(max(current + offset, 0), store.threads.count - 1)
        store.selection = [store.threads[next].id]
    }
}

struct ThreadMenu: View {
    @EnvironmentObject private var store: MailStore
    let targets: [ThreadSummary]

    var body: some View {
        if let first = targets.first {
            Button(first.isUnread ? "Mark as Read" : "Mark as Unread") { run(first.isUnread ? .markRead : .markUnread) }
            Button(first.isStarred ? "Remove Star" : "Add Star") { run(first.isStarred ? .unstar : .star) }
            Divider()
            if first.labelIDs.contains(SystemLabel.trash) {
                Button("Restore from Trash") { run(.untrash) }
            } else if first.labelIDs.contains(SystemLabel.spam) {
                Button("Not Spam") { run(.notSpam) }
            } else {
                if first.labelIDs.contains(SystemLabel.inbox) {
                    Button("Archive") { run(.archive) }
                } else {
                    Button("Move to Inbox") { run(.moveToInbox) }
                }
                Button("Move to Trash") { run(.trash) }
                Button("Mark as Spam") { run(.spam) }
            }
            let sameAccount = Set(targets.map(\.account)).count == 1
            let labels = store.userLabels(first.account)
            if sameAccount && !labels.isEmpty {
                Divider()
                Menu("Labels") {
                    ForEach(labels) { label in
                        let isOn = first.labelIDs.contains(label.id)
                        Button((isOn ? "✓ " : "") + label.name) {
                            run(isOn ? .removeLabel(label.id) : .addLabel(label.id))
                        }
                    }
                }
            }
        }
    }

    private func run(_ action: ThreadAction) {
        Task { await store.perform(action, on: targets) }
    }
}

struct ThreadRow: View {
    @EnvironmentObject private var store: MailStore
    let thread: ThreadSummary

    private var showsAccount: Bool { store.mailbox == .allInboxes || store.mailbox == nil }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(thread.isUnread ? Color.accentColor : Color.clear)
                .frame(width: 8, height: 8)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if showsAccount, let account = store.account(thread.account) {
                        Circle().fill(account.color).frame(width: 7, height: 7).help(account.email)
                    }
                    Text(thread.senders.isEmpty ? thread.account : thread.senders)
                        .fontWeight(thread.isUnread ? .semibold : .regular)
                        .lineLimit(1)
                    if thread.messageCount > 1 {
                        Text("\(thread.messageCount)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 6)
                    if thread.hasAttachment {
                        Image(systemName: "paperclip").font(.caption).foregroundStyle(.secondary)
                    }
                    Text(DateText.short(thread.date))
                        .font(.caption)
                        .foregroundStyle(thread.isUnread ? .primary : .secondary)
                }
                Text(thread.subject.isEmpty ? "(no subject)" : thread.subject)
                    .fontWeight(thread.isUnread ? .medium : .regular)
                    .lineLimit(1)
                HStack(alignment: .top) {
                    Text(thread.snippet)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    Button {
                        Task { await store.perform(thread.isStarred ? .unstar : .star, on: [thread]) }
                    } label: {
                        Image(systemName: thread.isStarred ? "star.fill" : "star")
                            .foregroundStyle(thread.isStarred ? Color.yellow : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(thread.isStarred ? "Remove star" : "Add star")
                }
            }
        }
        .padding(.vertical, 3)
    }
}

struct ReaderView: View {
    @EnvironmentObject private var store: MailStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if store.selection.count > 1 {
                VStack(spacing: 8) {
                    Image(systemName: "tray.full").font(.system(size: 42)).foregroundStyle(.secondary)
                    Text("\(store.selection.count) conversations selected").font(.title3)
                }
            } else if let detail = store.detail {
                ConversationView(detail: detail)
                    .id(detail.summaryID)
            } else if store.isLoadingDetail {
                ProgressView()
            } else {
                Text("Select a conversation").foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                let targets = store.selectedThreads
                Button { run(.archive, targets) } label: { Label("Archive", systemImage: "archivebox") }
                    .help("Archive").disabled(targets.isEmpty)
                Button { run(.trash, targets) } label: { Label("Trash", systemImage: "trash") }
                    .help("Move to Trash").disabled(targets.isEmpty)
                Button { run(.spam, targets) } label: { Label("Spam", systemImage: "exclamationmark.octagon") }
                    .help("Mark as Spam").disabled(targets.isEmpty)
                Button { run(.markUnread, targets) } label: { Label("Unread", systemImage: "envelope.badge") }
                    .help("Mark as Unread").disabled(targets.isEmpty)
                Menu {
                    ThreadMenu(targets: targets)
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .disabled(targets.isEmpty)
            }
        }
    }

    private func run(_ action: ThreadAction, _ targets: [ThreadSummary]) {
        Task { await store.perform(action, on: targets) }
    }
}

struct ConversationView: View {
    let detail: ThreadDetail

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(detail.subject.isEmpty ? "(no subject)" : detail.subject)
                    .font(.title2.weight(.semibold))
                    .textSelection(.enabled)
                    .padding(.horizontal, 4)
                ForEach(detail.messages) { rendered in
                    MessageCard(rendered: rendered, account: detail.account,
                                startsExpanded: rendered.id == detail.messages.last?.id
                                    || rendered.message.labelIDs.contains(SystemLabel.unread))
                }
            }
            .padding(18)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }
}

struct MessageCard: View {
    @EnvironmentObject private var store: MailStore
    @Environment(\.openWindow) private var openWindow
    let rendered: RenderedMessage
    let account: String
    @State private var expanded: Bool
    @State private var showDetails = false

    init(rendered: RenderedMessage, account: String, startsExpanded: Bool) {
        self.rendered = rendered
        self.account = account
        _expanded = State(initialValue: startsExpanded)
    }

    private var message: MailMessage { rendered.message }

    private var recipientLine: String {
        let names = (message.to + message.cc).map { address -> String in
            address.email.caseInsensitiveCompare(account) == .orderedSame ? "me" : address.displayName
        }
        return "to " + (names.isEmpty ? "undisclosed recipients" : names.joined(separator: ", "))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if expanded {
                if showDetails { details }
                EmailBodyView(document: rendered.document, message: message, account: account)
                if !message.attachments.isEmpty { attachments }
                actions
            }
        }
        .padding(14)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.2)))
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle().fill(Color.accentColor.opacity(0.18))
                Text(String(message.from.displayName.prefix(1)).uppercased()).fontWeight(.semibold)
            }
            .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(message.from.displayName).fontWeight(.semibold).lineLimit(1)
                    if !message.from.name.isEmpty {
                        Text("<\(message.from.email)>").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                if expanded {
                    Button { showDetails.toggle() } label: {
                        HStack(spacing: 3) {
                            Text(recipientLine).lineLimit(1)
                            Image(systemName: showDetails ? "chevron.up" : "chevron.down").font(.caption2)
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else {
                    Text(message.snippet).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Text(DateText.full(message.date)).font(.caption).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture { expanded.toggle() }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 3) {
            detailRow("From", ComposeFactory.display(message.from))
            detailRow("To", message.to.map(ComposeFactory.display).joined(separator: ", "))
            if !message.cc.isEmpty { detailRow("Cc", message.cc.map(ComposeFactory.display).joined(separator: ", ")) }
            detailRow("Date", DateText.full(message.date))
            detailRow("Subject", message.subject)
        }
        .font(.caption)
        .padding(8)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title + ":").foregroundStyle(.secondary).frame(width: 52, alignment: .trailing)
            Text(value).textSelection(.enabled)
        }
    }

    private var attachments: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                ForEach(message.attachments) { info in
                    Button {
                        save(info)
                    } label: {
                        Label("\(info.filename) (\(ByteCountFormatter.string(fromByteCount: Int64(info.size), countStyle: .file)))", systemImage: "arrow.down.doc")
                    }
                    .help("Save \(info.filename)")
                }
            }
        }
    }

    private func save(_ info: AttachmentInfo) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = (info.filename as NSString).lastPathComponent
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                try await store.attachmentData(info, account: account).write(to: url, options: .atomic)
            } catch {
                store.banner = "Couldn't save \(info.filename): \(error.localizedDescription)"
            }
        }
    }

    @ViewBuilder private var actions: some View {
        HStack {
            if message.isDraft {
                Button("Continue Editing") {
                    Task {
                        if let id = await store.resumeDraft(rendered, account: account) { openWindow(id: "compose", value: id) }
                    }
                }
            } else {
                Button { reply(all: false) } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }
                Button { reply(all: true) } label: { Label("Reply All", systemImage: "arrowshape.turn.up.left.2") }
                Button {
                    Task {
                        if let id = await store.forward(rendered, account: account) { openWindow(id: "compose", value: id) }
                    }
                } label: {
                    Label("Forward", systemImage: "arrowshape.turn.up.right")
                }
            }
        }
    }

    private func reply(all: Bool) {
        if let id = store.reply(rendered, all: all, account: account) { openWindow(id: "compose", value: id) }
    }
}

/// Draws an email with native text and image views. No web engine is involved,
/// so scripts can't run and nothing is fetched until "Show Images" is clicked.
struct EmailBodyView: View {
    let document: EmailDocument
    let message: MailMessage
    let account: String
    @State private var showImages = false
    @State private var showQuoted = false

    private var visible: [EmailBlock] {
        document.hasCollapsibleQuote && !showQuoted ? document.mainBlocks : document.blocks
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if document.hasRemoteImages && !showImages {
                HStack {
                    Image(systemName: "eye.slash")
                    Text("Images are hidden so senders can't tell you opened this.")
                    Spacer()
                    Button("Show Images") { showImages = true }
                }
                .font(.caption)
                .padding(8)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }
            ForEach(visible) { block in
                EmailBlockView(block: block, message: message, account: account, showImages: showImages)
            }
            if document.hasCollapsibleQuote {
                Button {
                    showQuoted.toggle()
                } label: {
                    Image(systemName: "ellipsis")
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.secondary.opacity(0.14), in: Capsule())
                }
                .buttonStyle(.plain)
                .help(showQuoted ? "Hide quoted text" : "Show quoted text")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct EmailBlockView: View {
    let block: EmailBlock
    let message: MailMessage
    let account: String
    let showImages: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach(0..<min(block.quoteDepth, 4), id: \.self) { _ in
                Rectangle().fill(Color.secondary.opacity(0.35)).frame(width: 2)
            }
            content
                .foregroundStyle(block.quoteDepth > 0 ? Color.secondary : Color.primary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.leading, CGFloat(block.indent) * 20)
    }

    @ViewBuilder private var content: some View {
        switch block.kind {
        case .rule:
            Divider()
        case .text(let runs, let style):
            Text(attributed(runs))
                .font(font(style))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .image(let image):
            EmailImageView(image: image, message: message, account: account, showImages: showImages)
        }
    }

    private func font(_ style: BlockTextStyle) -> Font {
        switch style {
        case .body: return .body
        case .preformatted: return .system(.body, design: .monospaced)
        case .heading(1): return .title.weight(.semibold)
        case .heading(2): return .title2.weight(.semibold)
        case .heading(3): return .title3.weight(.semibold)
        case .heading: return .headline
        }
    }

    private func attributed(_ runs: [InlineRun]) -> AttributedString {
        var output = AttributedString(block.prefix ?? "")
        for run in runs {
            var piece = AttributedString(run.text)
            var intent: InlinePresentationIntent = []
            if run.bold { intent.insert(.stronglyEmphasized) }
            if run.italic { intent.insert(.emphasized) }
            if run.code { intent.insert(.code) }
            if run.strike { intent.insert(.strikethrough) }
            if !intent.isEmpty { piece.inlinePresentationIntent = intent }
            if let link = run.link { piece.link = link }
            output += piece
        }
        return output
    }
}

/// Fetches pictures with a private session that sends no cookies.
actor ImageLoader {
    static let shared = ImageLoader()
    private var cache: [URL: Data] = [:]
    private let session = URLSession(configuration: .ephemeral)

    func data(for url: URL) async throws -> Data {
        if let cached = cache[url] { return cached }
        let (data, _) = try await session.data(from: url)
        cache[url] = data
        return data
    }
}

struct EmailImageView: View {
    @EnvironmentObject private var store: MailStore
    @Environment(\.openURL) private var openURL
    let image: EmailImage
    let message: MailMessage
    let account: String
    let showImages: Bool
    @State private var loaded: NSImage?

    private var maySource: Bool {
        if case .remote = image.source { return showImages }
        return true
    }

    private var taskKey: String { "\(image.source.hashValue)-\(showImages)" }

    var body: some View {
        Group {
            if let loaded {
                picture(loaded)
            } else if !image.alt.isEmpty {
                Label(image.alt, systemImage: "photo")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: taskKey) { await load() }
    }

    @ViewBuilder private func picture(_ nsImage: NSImage) -> some View {
        let view = Image(nsImage: nsImage)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(maxWidth: min(image.width ?? nsImage.size.width, 760), alignment: .leading)
        if let link = image.link {
            Button { openURL(link) } label: { view }
                .buttonStyle(.plain)
                .help(link.absoluteString)
        } else {
            view
        }
    }

    private func load() async {
        guard maySource, loaded == nil else { return }
        var data: Data?
        switch image.source {
        case .data(let inline):
            data = inline
        case .remote(let url):
            data = try? await ImageLoader.shared.data(for: url)
        case .contentID(let id):
            if let info = message.inlineImages.first(where: { $0.contentID == id }) {
                data = try? await store.attachmentData(info, account: account)
            }
        }
        if let data { loaded = NSImage(data: data) }
    }
}
