import AppKit
import SwiftUI

struct ConversationPage: View {
    @EnvironmentObject private var store: MailStore
    let summary: ThreadSummary

    var body: some View {
        VStack(spacing: 0) {
            ConversationToolbar(summary: summary)
            Rectangle().fill(Theme.divider).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    SubjectHeader(summary: summary)
                    if let detail = store.detail, detail.summaryID == summary.id {
                        ConversationBody(detail: detail)
                            .id(detail.summaryID)
                    } else {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                        .padding(40)
                    }
                }
                .padding(.bottom, 120)
            }
        }
    }
}

struct ConversationToolbar: View {
    @EnvironmentObject private var store: MailStore
    let summary: ThreadSummary

    var body: some View {
        HStack(spacing: 2) {
            IconButton(systemName: "arrow.left", help: "Back to \(store.title(of: store.mailbox))") { store.closeThread() }
            Color.clear.frame(width: 8, height: 1)
            ThreadActionButtons(targets: [summary])
            Spacer()
            if let position {
                Text("\(position.index + 1) of \(position.total)")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.mutedText)
                    .padding(.trailing, 4)
                IconButton(systemName: "chevron.left", help: "Newer") { Task { await store.openNeighbor(-1) } }
                    .disabled(position.index == 0)
                    .opacity(position.index == 0 ? 0.4 : 1)
                IconButton(systemName: "chevron.right", help: "Older") { Task { await store.openNeighbor(1) } }
                    .disabled(position.index == position.total - 1)
                    .opacity(position.index == position.total - 1 ? 0.4 : 1)
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 16)
        .frame(height: 48)
    }

    private var position: (index: Int, total: Int)? {
        store.threads.firstIndex { $0.id == summary.id }.map { (index: $0, total: store.threads.count) }
    }
}

struct SubjectHeader: View {
    @EnvironmentObject private var store: MailStore
    let summary: ThreadSummary

    private struct Chip: Hashable { var id: String; var name: String }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(summary.subject.isEmpty ? "(no subject)" : summary.subject)
                .font(.system(size: 22))
                .foregroundStyle(Theme.text)
                .textSelection(.enabled)
            ForEach(chips, id: \.self) { chip in
                RemovableChip(name: chip.name) { remove(chip) }
            }
            Spacer(minLength: 8)
            if store.accounts.count > 1, let account = store.account(summary.account) {
                HStack(spacing: 6) {
                    Circle().fill(account.color).frame(width: 8, height: 8)
                    Text(account.email).font(.system(size: 12)).foregroundStyle(Theme.mutedText)
                }
            }
        }
        .padding(.leading, 72)
        .padding(.trailing, 24)
        .padding(.top, 20)
        .padding(.bottom, 12)
    }

    private var chips: [Chip] {
        var list = [Chip]()
        if summary.labelIDs.contains(SystemLabel.inbox) { list.append(Chip(id: SystemLabel.inbox, name: "Inbox")) }
        if summary.labelIDs.contains(SystemLabel.spam) { list.append(Chip(id: SystemLabel.spam, name: "Spam")) }
        if summary.labelIDs.contains(SystemLabel.trash) { list.append(Chip(id: SystemLabel.trash, name: "Trash")) }
        list += store.userLabels(summary.account)
            .filter { summary.labelIDs.contains($0.id) }
            .map { Chip(id: $0.id, name: $0.name) }
        return list
    }

    private func remove(_ chip: Chip) {
        let action: ThreadAction
        switch chip.id {
        case SystemLabel.inbox: action = .archive
        case SystemLabel.spam: action = .notSpam
        case SystemLabel.trash: action = .untrash
        default: action = .removeLabel(chip.id)
        }
        Task { await store.perform(action, on: [summary]) }
    }
}

struct RemovableChip: View {
    let name: String
    let remove: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 3) {
            Text(name).font(.system(size: 12))
            Button(action: remove) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .opacity(hover ? 1 : 0)
            .help("Remove label")
        }
        .foregroundStyle(Theme.secondaryText)
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(Theme.chip, in: RoundedRectangle(cornerRadius: 4))
        .onHover { hover = $0 }
    }
}

struct ConversationBody: View {
    @EnvironmentObject private var store: MailStore
    let detail: ThreadDetail
    @State private var expanded: Set<String>
    @State private var showAll: Bool

    private struct Item: Identifiable {
        enum Kind { case message(RenderedMessage), hidden(Int) }
        var id: String
        var kind: Kind
    }

    init(detail: ThreadDetail) {
        self.detail = detail
        let unread = detail.messages.filter { $0.message.labelIDs.contains(SystemLabel.unread) }.map(\.id)
        _expanded = State(initialValue: Set(unread + [detail.messages.last?.id].compactMap { $0 }))
        _showAll = State(initialValue: detail.messages.count <= 4)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(items) { item in
                switch item.kind {
                case .message(let rendered):
                    MessageView(rendered: rendered, account: detail.account, expanded: expanded.contains(rendered.id)) {
                        if expanded.contains(rendered.id) { expanded.remove(rendered.id) } else { expanded.insert(rendered.id) }
                    }
                case .hidden(let count):
                    HiddenMessagesRow(count: count) { showAll = true }
                }
                Rectangle().fill(Theme.divider).frame(height: 1).padding(.leading, 72)
            }
            let inline = store.inlineSessions(for: detail.threadID)
            ForEach(inline) { session in
                InlineCompose(session: session)
            }
            if inline.isEmpty, let target = detail.replyTarget, !target.message.isDraft {
                ReplyButtons(target: target, account: detail.account)
            }
        }
        .onChange(of: detail.messages.count) { _, _ in
            if let last = detail.messages.last?.id { expanded.insert(last) }
        }
    }

    private var items: [Item] {
        let messages = detail.messages
        if showAll || messages.count <= 4 { return messages.map { Item(id: $0.id, kind: .message($0)) } }
        return [Item(id: messages[0].id, kind: .message(messages[0])), Item(id: "hidden", kind: .hidden(messages.count - 3))]
            + messages.suffix(2).map { Item(id: $0.id, kind: .message($0)) }
    }
}

struct HiddenMessagesRow: View {
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .leading) {
                VStack(spacing: 4) {
                    Rectangle().fill(Theme.divider).frame(height: 1)
                    Rectangle().fill(Theme.divider).frame(height: 1)
                }
                Text(String(count))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: 40, height: 40)
                    .background(Theme.surface, in: Circle())
                    .overlay(Circle().stroke(Theme.divider, lineWidth: 1))
                    .padding(.leading, 16)
            }
            .frame(height: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show \(count) older messages")
    }
}

struct MessageView: View {
    @EnvironmentObject private var store: MailStore
    let rendered: RenderedMessage
    let account: String
    let expanded: Bool
    let toggle: () -> Void
    @State private var showDetails = false

    private var message: MailMessage { rendered.message }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Avatar(name: message.from.displayName, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                header
                if expanded {
                    recipients
                    if showDetails { DetailsPanel(message: message).padding(.top, 6) }
                    EmailBodyView(document: rendered.document, message: message, account: account)
                        .padding(.top, 14)
                    if !message.attachments.isEmpty {
                        AttachmentsSection(message: message, account: account)
                    }
                } else {
                    Text(message.snippet)
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.mutedText)
                        .lineLimit(1)
                        .contentShape(Rectangle())
                        .onTapGesture(perform: toggle)
                }
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 24)
        .padding(.vertical, expanded ? 16 : 10)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(message.from.displayName)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            if expanded && !message.from.name.isEmpty {
                Text("<\(message.from.email)>")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.mutedText)
                    .lineLimit(1)
            }
            if message.isDraft {
                Text("Draft").font(.system(size: 13)).foregroundStyle(Theme.danger)
            }
            Spacer(minLength: 8)
            if !expanded && !message.attachments.isEmpty {
                Image(systemName: "paperclip").font(.system(size: 12)).foregroundStyle(Theme.mutedText)
            }
            Text(expanded ? DateText.conversation(message.date) : DateText.short(message.date))
                .font(.system(size: 12))
                .foregroundStyle(Theme.mutedText)
            if expanded { actions }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
    }

    @ViewBuilder private var actions: some View {
        if message.isDraft {
            PillButton(title: "Edit", icon: "pencil") {
                Task { _ = await store.resumeDraft(rendered, account: account) }
            }
            .padding(.leading, 8)
        } else {
            IconButton(systemName: "arrowshape.turn.up.left", help: "Reply", size: 32, iconSize: 14) {
                _ = store.reply(rendered, all: false, account: account, inline: true)
            }
            ToolbarMenu(systemName: "ellipsis", help: "More") {
                Button("Reply") { _ = store.reply(rendered, all: false, account: account, inline: true) }
                Button("Reply all") { _ = store.reply(rendered, all: true, account: account, inline: true) }
                Button("Forward") { Task { _ = await store.forward(rendered, account: account, inline: true) } }
            }
        }
    }

    private var recipients: some View {
        Button {
            showDetails.toggle()
        } label: {
            HStack(spacing: 3) {
                Text(recipientLine).lineLimit(1)
                Image(systemName: showDetails ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill")
                    .font(.system(size: 7))
            }
            .font(.system(size: 12))
            .foregroundStyle(Theme.mutedText)
        }
        .buttonStyle(.plain)
    }

    private var recipientLine: String {
        let names = (message.to + message.cc).map { address -> String in
            address.email.caseInsensitiveCompare(account) == .orderedSame ? "me" : address.displayName
        }
        return "to " + (names.isEmpty ? "undisclosed recipients" : names.joined(separator: ", "))
    }
}

struct DetailsPanel: View {
    let message: MailMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            row("from:", ComposeFactory.display(message.from))
            row("to:", message.to.map(ComposeFactory.display).joined(separator: ", "))
            if !message.cc.isEmpty { row("cc:", message.cc.map(ComposeFactory.display).joined(separator: ", ")) }
            row("date:", DateText.full(message.date))
            row("subject:", message.subject)
        }
        .font(.system(size: 12))
        .padding(12)
        .frame(maxWidth: 560, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.divider, lineWidth: 1))
        .shadow(color: Color.black.opacity(0.12), radius: 4, x: 0, y: 2)
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).foregroundStyle(Theme.mutedText).frame(width: 56, alignment: .trailing)
            Text(value).foregroundStyle(Theme.text).textSelection(.enabled)
        }
    }
}

struct AttachmentsSection: View {
    let message: MailMessage
    let account: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Rectangle().fill(Theme.divider).frame(height: 1)
            Text(message.attachments.count == 1 ? "One attachment" : "\(message.attachments.count) attachments")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.text)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(message.attachments) { AttachmentCard(info: $0, account: account) }
                }
            }
        }
        .padding(.top, 20)
    }
}

struct AttachmentCard: View {
    @EnvironmentObject private var store: MailStore
    let info: AttachmentInfo
    let account: String
    @State private var preview: NSImage?
    @State private var hover = false

    var body: some View {
        Button(action: save) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack {
                    Theme.readRow
                    if let preview {
                        Image(nsImage: preview).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: icon.name).font(.system(size: 30)).foregroundStyle(icon.color)
                    }
                }
                .frame(width: 180, height: 80)
                .clipped()
                HStack(spacing: 8) {
                    Image(systemName: icon.name).font(.system(size: 13)).foregroundStyle(icon.color)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(info.filename).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
                        Text(ByteCountFormatter.string(fromByteCount: Int64(info.size), countStyle: .file))
                            .font(.system(size: 11)).foregroundStyle(Theme.mutedText)
                    }
                    Spacer(minLength: 0)
                    if hover { Image(systemName: "arrow.down.circle").foregroundStyle(Theme.secondaryText) }
                }
                .padding(8)
            }
            .frame(width: 180, height: 124)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.divider, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("Download \(info.filename)")
        .task {
            guard info.mimeType.hasPrefix("image/"), info.size < 8_000_000,
                  let data = try? await store.attachmentData(info, account: account) else { return }
            preview = NSImage(data: data)
        }
    }

    private var icon: (name: String, color: Color) {
        let mime = info.mimeType
        let ext = (info.filename as NSString).pathExtension.lowercased()
        if mime == "application/pdf" { return ("doc.richtext", Theme.color(0xD93025, 0xF28B82)) }
        if mime.hasPrefix("image/") { return ("photo", Theme.color(0xD93025, 0xF28B82)) }
        if ["xls", "xlsx", "csv", "numbers"].contains(ext) { return ("tablecells", Theme.color(0x188038, 0x81C995)) }
        if ["zip", "gz", "tar", "rar", "7z"].contains(ext) { return ("doc.zipper", Theme.mutedText) }
        if ["ppt", "pptx", "key"].contains(ext) { return ("rectangle.on.rectangle", Theme.color(0xE37400, 0xFCAD70)) }
        return ("doc.text", Theme.accent)
    }

    private func save() {
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
}

struct ReplyButtons: View {
    @EnvironmentObject private var store: MailStore
    let target: RenderedMessage
    let account: String

    var body: some View {
        HStack(spacing: 12) {
            PillButton(title: "Reply", icon: "arrowshape.turn.up.left") {
                _ = store.reply(target, all: false, account: account, inline: true)
            }
            if target.message.to.count + target.message.cc.count > 1 {
                PillButton(title: "Reply all", icon: "arrowshape.turn.up.left.2") {
                    _ = store.reply(target, all: true, account: account, inline: true)
                }
            }
            PillButton(title: "Forward", icon: "arrowshape.turn.up.right") {
                Task { _ = await store.forward(target, account: account, inline: true) }
            }
        }
        .padding(.leading, 72)
        .padding(.vertical, 20)
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
                HStack(spacing: 10) {
                    Image(systemName: "photo.badge.exclamationmark")
                    Text("Images are hidden so senders can't tell you opened this.")
                    Button("Display images below") { showImages = true }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.accent)
                    Spacer()
                }
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondaryText)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Theme.readRow, in: RoundedRectangle(cornerRadius: 6))
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
                        .background(Theme.chip, in: Capsule())
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
                Rectangle().fill(Theme.divider).frame(width: 2)
            }
            content
                .foregroundStyle(block.quoteDepth > 0 ? Theme.mutedText : Theme.text)
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
                .lineSpacing(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .image(let image):
            EmailImageView(image: image, message: message, account: account, showImages: showImages)
        }
    }

    private func font(_ style: BlockTextStyle) -> Font {
        switch style {
        case .body: return .system(size: 14)
        case .preformatted: return .system(size: 13, design: .monospaced)
        case .heading(1): return .system(size: 24, weight: .semibold)
        case .heading(2): return .system(size: 20, weight: .semibold)
        case .heading(3): return .system(size: 17, weight: .semibold)
        case .heading: return .system(size: 15, weight: .semibold)
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
