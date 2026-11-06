import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ComposeWindow: View {
    @EnvironmentObject private var store: MailStore
    @Environment(\.dismiss) private var dismiss
    let sessionID: UUID?

    var body: some View {
        if let sessionID, let session = store.composeSessions[sessionID] {
            ComposeView(session: session)
                .frame(minWidth: 520, minHeight: 420)
        } else {
            Color.clear.onAppear { dismiss() }
        }
    }
}

struct ComposeView: View {
    private enum Field { case to, body }

    @EnvironmentObject private var store: MailStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var session: ComposeSession
    @FocusState private var focus: Field?
    @State private var showCc = false
    @State private var confirmDiscard = false

    init(session: ComposeSession) { self.session = session }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                if store.accounts.count > 1 {
                    HStack {
                        Text("From").foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                        Picker("From", selection: accountBinding) {
                            ForEach(store.accounts) { Text($0.email).tag($0.email) }
                        }
                        .labelsHidden()
                        .disabled(session.draft.threadID != nil)
                    }
                    .padding(.vertical, 6)
                    Divider()
                }
                HStack {
                    addressField("To", text: $session.draft.to)
                        .focused($focus, equals: .to)
                    if !showCc {
                        Button("Cc/Bcc") { showCc = true }.buttonStyle(.link).font(.caption)
                    }
                }
                Divider()
                if showCc {
                    addressField("Cc", text: $session.draft.cc)
                    Divider()
                    addressField("Bcc", text: $session.draft.bcc)
                    Divider()
                }
                addressField("Subject", text: $session.draft.subject)
                Divider()
            }
            .padding(.horizontal, 14)

            TextEditor(text: $session.draft.body)
                .font(.body)
                .focused($focus, equals: .body)
                .scrollContentBackground(.hidden)
                .padding(10)

            if !session.draft.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(session.draft.attachments) { attachment in
                            HStack(spacing: 5) {
                                Image(systemName: "paperclip")
                                Text(attachment.filename).lineLimit(1)
                                Button {
                                    session.draft.attachments.removeAll { $0.id == attachment.id }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.secondary.opacity(0.12), in: Capsule())
                        }
                    }
                    .padding(.horizontal, 14)
                }
                .padding(.bottom, 6)
            }

            if let error = session.errorText {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 6)
            }

            Divider()
            HStack(spacing: 12) {
                Button {
                    Task {
                        if await session.send() { dismiss() }
                    }
                } label: {
                    if session.isSending { ProgressView().controlSize(.small) } else { Text("Send") }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(session.isSending)

                Button(action: addAttachments) {
                    Image(systemName: "paperclip")
                }
                .help("Attach files")

                Text(session.status).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    confirmDiscard = true
                } label: {
                    Image(systemName: "trash")
                }
                .help("Discard draft")
            }
            .padding(12)
        }
        .navigationTitle(session.draft.subject.isEmpty ? "New Message" : session.draft.subject)
        .onChange(of: session.draft) { _, _ in session.draftChanged() }
        .onAppear { focus = session.draft.to.isEmpty ? .to : .body }
        .onDisappear {
            let id = session.id
            Task {
                await session.closeKeepingDraft()
                store.endCompose(id)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            attach(urls)
            return true
        }
        .alert("Discard this draft?", isPresented: $confirmDiscard) {
            Button("Discard", role: .destructive) {
                Task {
                    await session.discard()
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var accountBinding: Binding<String> {
        Binding(get: { session.draft.account }, set: { new in Task { await session.changeAccount(to: new) } })
    }

    private func addressField(_ title: String, text: Binding<String>) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
            TextField(title, text: text)
                .textFieldStyle(.plain)
                .labelsHidden()
        }
        .padding(.vertical, 7)
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
