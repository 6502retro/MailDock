import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum ComposeStyle { case docked, inline, maximized }

/// New-message windows lined up along the bottom right, as in Gmail.
struct ComposeDock: View {
    @EnvironmentObject private var store: MailStore

    var body: some View {
        HStack(alignment: .bottom, spacing: 16) {
            ForEach(store.dockedSessions) { session in
                ComposeBox(session: session)
            }
        }
    }
}

struct MaximizedCompose: View {
    @EnvironmentObject private var store: MailStore

    var body: some View {
        if let id = store.maximizedCompose, let session = store.composeSessions[id] {
            ZStack {
                Color.black.opacity(0.45)
                    .ignoresSafeArea()
                    .onTapGesture { store.toggleMaximized(id) }
                ComposeBox(session: session, maximized: true)
                    .frame(maxWidth: 1100, maxHeight: 820)
                    .padding(48)
            }
        }
    }
}

struct ComposeBox: View {
    @EnvironmentObject private var store: MailStore
    @ObservedObject var session: ComposeSession
    let maximized: Bool

    init(session: ComposeSession, maximized: Bool = false) {
        _session = ObservedObject(wrappedValue: session)
        self.maximized = maximized
    }

    private var minimized: Bool { session.isMinimized && !maximized }

    var body: some View {
        VStack(spacing: 0) {
            header
            if !minimized {
                ComposeForm(session: session, style: maximized ? .maximized : .docked)
            }
        }
        .frame(width: maximized ? nil : (minimized ? 280 : 540), height: maximized ? nil : (minimized ? 40 : 560))
        .frame(maxWidth: maximized ? .infinity : nil, maxHeight: maximized ? .infinity : nil)
        .background(Theme.surface)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: maximized ? 10 : 0,
                                          bottomTrailingRadius: maximized ? 10 : 0, topTrailingRadius: 10))
        .shadow(color: Color.black.opacity(0.28), radius: 14, x: 0, y: 4)
    }

    private var header: some View {
        HStack(spacing: 2) {
            Text(session.draft.subject.isEmpty ? "New Message" : session.draft.subject)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            Spacer()
            if !maximized {
                IconButton(systemName: "minus", help: minimized ? "Expand" : "Minimize", size: 26, iconSize: 12) {
                    session.isMinimized.toggle()
                }
            }
            IconButton(systemName: maximized ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                       help: maximized ? "Exit full screen" : "Full screen", size: 26, iconSize: 12) {
                session.isMinimized = false
                store.toggleMaximized(session.id)
            }
            IconButton(systemName: "xmark", help: "Save & close", size: 26, iconSize: 12) {
                let id = session.id
                Task {
                    await session.closeKeepingDraft()
                    store.endCompose(id)
                }
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .frame(height: 40)
        .background(Theme.composeHeader)
        .contentShape(Rectangle())
        .onTapGesture { if session.isMinimized { session.isMinimized = false } }
    }
}

/// A reply or forward written directly under the conversation.
struct InlineCompose: View {
    @EnvironmentObject private var store: MailStore
    @ObservedObject var session: ComposeSession

    init(session: ComposeSession) {
        _session = ObservedObject(wrappedValue: session)
    }

    var body: some View {
        let account = store.account(session.draft.account)
        HStack(alignment: .top, spacing: 16) {
            Avatar(name: account?.title ?? session.draft.account, size: 40, color: account?.color)
            ComposeForm(session: session, style: .inline)
                .background(Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.divider, lineWidth: 1))
                .shadow(color: Color.black.opacity(0.18), radius: 4, x: 0, y: 1)
        }
        .padding(.leading, 16)
        .padding(.trailing, 24)
        .padding(.vertical, 16)
    }
}

struct ComposeForm: View {
    private enum Field { case to, body }

    @EnvironmentObject private var store: MailStore
    @ObservedObject var session: ComposeSession
    let style: ComposeStyle
    @State private var showCc: Bool
    @State private var confirmDiscard = false
    @FocusState private var focus: Field?

    init(session: ComposeSession, style: ComposeStyle) {
        _session = ObservedObject(wrappedValue: session)
        self.style = style
        _showCc = State(initialValue: !session.draft.cc.isEmpty || !session.draft.bcc.isEmpty)
    }

    private var isForward: Bool { session.draft.threadID == nil && session.originThreadID != nil }
    private var showsFrom: Bool { store.accounts.count > 1 && session.draft.threadID == nil }

    var body: some View {
        VStack(spacing: 0) {
            if style == .inline {
                inlineHeader
            } else {
                if showsFrom { fromRow }
                recipientRow("To", text: $session.draft.to, offersCc: true)
                    .focused($focus, equals: .to)
            }
            if showCc {
                recipientRow("Cc", text: $session.draft.cc)
                recipientRow("Bcc", text: $session.draft.bcc)
            }
            if style != .inline {
                TextField("Subject", text: $session.draft.subject)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .padding(.horizontal, 16)
                    .frame(height: 40)
                    .overlay(alignment: .bottom) { fieldDivider }
            }
            TextEditor(text: $session.draft.body)
                .font(.system(size: 14))
                .foregroundStyle(Theme.text)
                .scrollContentBackground(.hidden)
                .focused($focus, equals: .body)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .frame(minHeight: style == .inline ? 170 : 120, maxHeight: style == .inline ? 420 : .infinity)
            if !session.draft.attachments.isEmpty { attachmentChips }
            if let error = session.errorText {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
            }
            bottomBar
        }
        .onChange(of: session.draft) { _, _ in session.draftChanged() }
        .onAppear { focus = session.draft.to.isEmpty ? .to : .body }
        .dropDestination(for: URL.self) { urls, _ in
            attach(urls)
            return true
        }
        .alert("Discard this draft?", isPresented: $confirmDiscard) {
            Button("Discard", role: .destructive) {
                let id = session.id
                Task {
                    await session.discard()
                    store.endCompose(id)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var fieldDivider: some View {
        Rectangle().fill(Theme.divider).frame(height: 1).padding(.horizontal, 16)
    }

    private var inlineHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: isForward ? "arrowshape.turn.up.right" : "arrowshape.turn.up.left")
                .font(.system(size: 13))
                .foregroundStyle(Theme.mutedText)
            TextField(isForward ? "To" : "Recipients", text: $session.draft.to)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($focus, equals: .to)
            if !showCc {
                Button("Cc Bcc") { showCc = true }
                    .buttonStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryText)
            }
            IconButton(systemName: "arrow.up.forward.square", help: "Pop out reply", size: 28, iconSize: 13) {
                store.popOut(session.id)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .overlay(alignment: .bottom) { fieldDivider }
    }

    private var fromRow: some View {
        HStack(spacing: 8) {
            Text("From").font(.system(size: 14)).foregroundStyle(Theme.mutedText)
            Menu {
                ForEach(store.accounts) { account in
                    Button(account.email) { Task { await session.changeAccount(to: account.email) } }
                }
            } label: {
                Text(session.draft.account).font(.system(size: 14))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(height: 40)
        .overlay(alignment: .bottom) { fieldDivider }
    }

    private func recipientRow(_ label: String, text: Binding<String>, offersCc: Bool = false) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 14)).foregroundStyle(Theme.mutedText)
            TextField("", text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
            if offersCc && !showCc {
                Button("Cc Bcc") { showCc = true }
                    .buttonStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 40)
        .overlay(alignment: .bottom) { fieldDivider }
    }

    private var attachmentChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(session.draft.attachments) { attachment in
                    HStack(spacing: 6) {
                        Image(systemName: "paperclip").font(.system(size: 11))
                        Text(attachment.filename).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.data.count), countStyle: .file))
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.mutedText)
                        Button {
                            session.draft.attachments.removeAll { $0.id == attachment.id }
                        } label: {
                            Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                        }
                        .buttonStyle(.plain)
                        .help("Remove attachment")
                    }
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Theme.readRow, in: RoundedRectangle(cornerRadius: 6))
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 6)
    }

    private var bottomBar: some View {
        HStack(spacing: 4) {
            Button {
                let id = session.id
                Task {
                    if await session.send() { store.endCompose(id) }
                }
            } label: {
                Group {
                    if session.isSending {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Send")
                    }
                }
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.onAccent)
                .frame(minWidth: 52)
                .padding(.horizontal, 20)
                .frame(height: 36)
                .background(Theme.accent, in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(session.isSending)
            .help("Send")
            IconButton(systemName: "paperclip", help: "Attach files", size: 36) { addAttachments() }
            Text(session.status)
                .font(.system(size: 12))
                .foregroundStyle(Theme.mutedText)
                .padding(.leading, 6)
            Spacer()
            IconButton(systemName: "trash", help: "Discard draft", size: 36) { confirmDiscard = true }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func addAttachments() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        attach(panel.urls)
    }

    private func attach(_ urls: [URL]) {
        for url in urls {
            do {
                let data = try Data(contentsOf: url)
                let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                session.draft.attachments.append(DraftAttachment(filename: url.lastPathComponent, mimeType: type, data: data))
            } catch {
                session.errorText = "Couldn't attach \(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
    }
}
