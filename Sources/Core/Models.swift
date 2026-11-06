import Foundation

enum MailError: LocalizedError, Equatable {
    case notConfigured
    case needsSignIn(String)
    case api(status: Int, message: String)
    case invalidResponse
    case invalidClientFile(String)
    case signInDenied
    case signInTimedOut
    case signInCancelled
    case noRecipients
    case invalidRecipient(String)
    case attachmentsTooLarge

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Google sign-in has not been set up yet."
        case .needsSignIn(let email): return "\(email) needs to sign in again."
        case .api(let status, let message): return "Gmail error \(status): \(message)"
        case .invalidResponse: return "Gmail sent a response MailDock could not read."
        case .invalidClientFile(let why): return why
        case .signInDenied: return "Google sign-in was cancelled or denied."
        case .signInTimedOut: return "Google sign-in timed out. Please try again."
        case .signInCancelled: return "Sign-in cancelled."
        case .noRecipients: return "Add at least one recipient."
        case .invalidRecipient(let value): return "“\(value)” is not a valid email address."
        case .attachmentsTooLarge: return "Attachments are over Gmail's 25 MB limit."
        }
    }
}

struct Account: Identifiable, Codable, Hashable {
    var email: String
    var displayName: String
    var colorIndex: Int
    var needsSignIn: Bool = false
    var signature: String = ""
    var id: String { email }
}

struct MailLabel: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var isSystem: Bool
    var threadsUnread: Int
    var threadsTotal: Int
}

enum SystemLabel {
    static let inbox = "INBOX", sent = "SENT", draft = "DRAFT", spam = "SPAM", trash = "TRASH"
    static let starred = "STARRED", important = "IMPORTANT", unread = "UNREAD"
}

enum Mailbox: Hashable, Codable {
    case allInboxes
    case label(account: String, id: String)
    case allMail(account: String)

    var labelFilter: [String] {
        switch self {
        case .allInboxes: return [SystemLabel.inbox]
        case .label(_, let id): return [id]
        case .allMail: return []
        }
    }

    var includesSpamAndTrash: Bool {
        if case .label(_, let id) = self { return id == SystemLabel.spam || id == SystemLabel.trash }
        return false
    }

    /// The key used for this mailbox's saved list on disk.
    var cacheKey: String {
        switch self {
        case .allInboxes: return SystemLabel.inbox
        case .label(_, let id): return id
        case .allMail: return "ALL_MAIL"
        }
    }

    func contains(labels: Set<String>) -> Bool {
        switch self {
        case .allInboxes: return labels.contains(SystemLabel.inbox)
        case .label(_, let id): return labels.contains(id)
        case .allMail: return !labels.contains(SystemLabel.spam) && !labels.contains(SystemLabel.trash)
        }
    }
}

enum InboxCategory: String, CaseIterable, Identifiable {
    case all, primary, promotions, social, updates, forums
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var query: String? { self == .all ? nil : "category:\(rawValue)" }
}

struct ThreadSummary: Identifiable, Codable, Hashable {
    var threadID: String
    var account: String
    var subject: String
    var snippet: String
    var senders: String
    var date: Date
    var messageCount: Int
    var labelIDs: Set<String>
    var historyID: String
    var hasAttachment: Bool

    var id: String { account + "|" + threadID }
    var isUnread: Bool { labelIDs.contains(SystemLabel.unread) }
    var isStarred: Bool { labelIDs.contains(SystemLabel.starred) }
    var isImportant: Bool { labelIDs.contains(SystemLabel.important) }
}

struct ThreadRef: Hashable { var id: String; var historyID: String; var snippet: String }
struct ThreadPage { var threads: [ThreadRef]; var nextPageToken: String? }

struct EmailAddress: Hashable, Codable {
    var name: String
    var email: String
    var displayName: String { name.isEmpty ? email : name }
}

struct AttachmentInfo: Identifiable, Hashable {
    var messageID: String
    var attachmentID: String?
    var filename: String
    var mimeType: String
    var size: Int
    var contentID: String?
    var inlineData: Data?
    var id: String { messageID + "|" + (attachmentID ?? contentID ?? filename) }
}

struct MailMessage: Identifiable, Hashable {
    var id: String
    var threadID: String
    var labelIDs: Set<String>
    var from: EmailAddress
    var to: [EmailAddress]
    var cc: [EmailAddress]
    var replyTo: [EmailAddress]
    var subject: String
    var date: Date
    var messageIDHeader: String
    var references: String
    var snippet: String
    var plainBody: String?
    var htmlBody: String?
    var attachments: [AttachmentInfo]
    var inlineImages: [AttachmentInfo]
    var isDraft: Bool { labelIDs.contains(SystemLabel.draft) }
}

struct RenderedMessage: Identifiable, Hashable {
    var message: MailMessage
    var document: EmailDocument
    var id: String { message.id }
}

struct ThreadDetail: Equatable {
    var summaryID: String
    var account: String
    var threadID: String
    var subject: String
    var messages: [RenderedMessage]
    /// The newest message that has actually been sent or received.
    var replyTarget: RenderedMessage? { messages.last { !$0.message.isDraft } ?? messages.last }
}

struct DraftAttachment: Identifiable, Hashable {
    var id = UUID()
    var filename: String
    var mimeType: String
    var data: Data
}

struct ComposeDraft: Identifiable, Hashable {
    var id = UUID()
    var account: String
    var to = ""
    var cc = ""
    var bcc = ""
    var subject = ""
    var body = ""
    var threadID: String?
    var inReplyTo: String?
    var references: String?
    var attachments: [DraftAttachment] = []
    var gmailDraftID: String?

    var isBlank: Bool {
        to.isEmpty && cc.isEmpty && bcc.isEmpty && subject.isEmpty
            && body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty
    }
}

enum ThreadAction: Hashable {
    case archive, moveToInbox, trash, untrash, spam, notSpam
    case markRead, markUnread, star, unstar
    case addLabel(String), removeLabel(String)

    var undoTitle: String? {
        switch self {
        case .archive: return "Conversation archived"
        case .trash: return "Moved to Trash"
        case .spam: return "Marked as spam"
        default: return nil
        }
    }
    var inverse: ThreadAction? {
        switch self {
        case .archive: return .moveToInbox
        case .trash: return .untrash
        case .spam: return .notSpam
        default: return nil
        }
    }
}

/// Runs `body` over `items` with at most `limit` running at once, keeping the input order.
func concurrentMap<T: Sendable, R: Sendable>(
    _ items: [T], limit: Int, _ body: @escaping @Sendable (T) async throws -> R
) async throws -> [R] {
    guard !items.isEmpty else { return [] }
    return try await withThrowingTaskGroup(of: (Int, R).self) { group in
        var results = [R?](repeating: nil, count: items.count)
        var next = 0
        func enqueue() {
            let index = next
            let item = items[index]
            next += 1
            group.addTask { (index, try await body(item)) }
        }
        while next < min(limit, items.count) { enqueue() }
        while let (index, value) = try await group.next() {
            results[index] = value
            if next < items.count { enqueue() }
        }
        return results.compactMap { $0 }
    }
}
