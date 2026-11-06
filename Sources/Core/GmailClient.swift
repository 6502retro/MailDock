import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// JSON shapes returned by the Gmail API.
struct GmailHeader: Decodable { var name: String; var value: String }
struct GmailBody: Decodable { var attachmentId: String?; var size: Int?; var data: String? }
struct GmailPart: Decodable {
    var partId: String?
    var mimeType: String?
    var filename: String?
    var headers: [GmailHeader]?
    var body: GmailBody?
    var parts: [GmailPart]?
    func header(_ name: String) -> String? {
        headers?.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}
struct GmailMessage: Decodable {
    var id: String
    var threadId: String?
    var labelIds: [String]?
    var snippet: String?
    var historyId: String?
    var internalDate: String?
    var payload: GmailPart?
}
struct GmailThread: Decodable { var id: String; var historyId: String?; var snippet: String?; var messages: [GmailMessage]? }

protocol GmailAPI: Sendable {
    func profile() async throws -> (email: String, historyID: String)
    func sendAsIdentity() async throws -> (displayName: String, signatureHTML: String)
    func labels() async throws -> [MailLabel]
    func listThreads(labelIDs: [String], query: String?, pageToken: String?, includeSpamTrash: Bool, maxResults: Int) async throws -> ThreadPage
    func threadMetadata(id: String) async throws -> GmailThread
    func threadFull(id: String) async throws -> GmailThread
    func modifyThread(id: String, add: [String], remove: [String]) async throws
    func trashThread(id: String) async throws
    func untrashThread(id: String) async throws
    func attachment(messageID: String, attachmentID: String) async throws -> Data
    func send(raw: Data, threadID: String?) async throws
    func saveDraft(id: String?, raw: Data, threadID: String?) async throws -> String
    func deleteDraft(id: String) async throws
    func draftID(forMessage messageID: String) async throws -> String?
}

final class GmailClient: GmailAPI, @unchecked Sendable {
    typealias TokenProvider = @Sendable (_ forceRefresh: Bool) async throws -> String

    private let token: TokenProvider
    private let transport: HTTPTransport
    private let maxAttempts = 5
    private let baseDelay: Double
    private static let api = "https://gmail.googleapis.com/gmail/v1/users/me/"
    private static let upload = "https://gmail.googleapis.com/upload/gmail/v1/users/me/"

    init(transport: HTTPTransport, baseDelay: Double = 1, token: @escaping TokenProvider) {
        self.transport = transport
        self.baseDelay = baseDelay
        self.token = token
    }

    static func url(_ base: String, _ path: String, query: [(String, String)] = []) -> URL {
        var components = URLComponents(string: base + path)!
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
            // URLComponents leaves "+" alone, but Google reads a bare "+" as a space.
            components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        return components.url!
    }

    private func perform(_ original: URLRequest) async throws -> Data {
        var forceRefresh = false
        var attempt = 0
        while true {
            attempt += 1
            var request = original
            request.setValue("Bearer \(try await token(forceRefresh))", forHTTPHeaderField: "Authorization")
            let result = try await transport.send(request)
            if (200..<300).contains(result.status) { return result.data }
            let problem = Self.parseError(result.data)
            if result.status == 401 && !forceRefresh {
                forceRefresh = true
                continue
            }
            let rateLimited = result.status == 429
                || (result.status == 403 && ["rateLimitExceeded", "userRateLimitExceeded"].contains(problem.reason))
            if (rateLimited || (500...599).contains(result.status)) && attempt < maxAttempts {
                let delay = result.retryAfter ?? baseDelay * pow(2, Double(attempt - 1))
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                continue
            }
            throw MailError.api(status: result.status, message: problem.message)
        }
    }

    static func parseError(_ data: Data) -> (message: String, reason: String?) {
        struct Envelope: Decodable {
            struct Inner: Decodable {
                struct Item: Decodable { var reason: String? }
                var message: String?
                var errors: [Item]?
            }
            var error: Inner?
        }
        let inner = (try? JSONDecoder().decode(Envelope.self, from: data))?.error
        return (inner?.message ?? "The request failed.", inner?.errors?.first?.reason)
    }

    private func get<T: Decodable>(_ path: String, query: [(String, String)] = []) async throws -> T {
        let data = try await perform(URLRequest(url: Self.url(Self.api, path, query: query)))
        do { return try JSONDecoder().decode(T.self, from: data) } catch { throw MailError.invalidResponse }
    }

    @discardableResult
    private func post(_ path: String, json: [String: Any]? = nil, method: String = "POST") async throws -> Data {
        var request = URLRequest(url: Self.url(Self.api, path))
        request.httpMethod = method
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        return try await perform(request)
    }

    func profile() async throws -> (email: String, historyID: String) {
        struct Response: Decodable { var emailAddress: String; var historyId: String }
        let response: Response = try await get("profile")
        return (response.emailAddress, response.historyId)
    }

    func sendAsIdentity() async throws -> (displayName: String, signatureHTML: String) {
        struct Response: Decodable {
            struct Item: Decodable { var displayName: String?; var signature: String?; var isDefault: Bool?; var isPrimary: Bool? }
            var sendAs: [Item]?
        }
        let response: Response = try await get("settings/sendAs")
        let items = response.sendAs ?? []
        let chosen = items.first { $0.isDefault == true } ?? items.first { $0.isPrimary == true } ?? items.first
        return (chosen?.displayName ?? "", chosen?.signature ?? "")
    }

    func labels() async throws -> [MailLabel] {
        struct Item: Decodable {
            var id: String
            var name: String
            var type: String?
            var threadsUnread: Int?
            var threadsTotal: Int?
        }
        struct Response: Decodable { var labels: [Item]? }
        let list: Response = try await get("labels")
        // The list call has no counts, so each label is fetched for its numbers.
        return try await concurrentMap(list.labels ?? [], limit: 8) { item in
            let full: Item = try await self.get("labels/\(item.id)")
            return MailLabel(id: full.id, name: full.name, isSystem: full.type == "system",
                             threadsUnread: full.threadsUnread ?? 0, threadsTotal: full.threadsTotal ?? 0)
        }
    }

    func listThreads(labelIDs: [String], query: String?, pageToken: String?, includeSpamTrash: Bool, maxResults: Int) async throws -> ThreadPage {
        struct Response: Decodable {
            struct Item: Decodable { var id: String; var historyId: String?; var snippet: String? }
            var threads: [Item]?
            var nextPageToken: String?
        }
        var items = [("maxResults", String(maxResults))]
        items += labelIDs.map { ("labelIds", $0) }
        if let query, !query.isEmpty { items.append(("q", query)) }
        if let pageToken { items.append(("pageToken", pageToken)) }
        if includeSpamTrash { items.append(("includeSpamTrash", "true")) }
        let response: Response = try await get("threads", query: items)
        return ThreadPage(
            threads: (response.threads ?? []).map {
                ThreadRef(id: $0.id, historyID: $0.historyId ?? "", snippet: $0.snippet ?? "")
            },
            nextPageToken: response.nextPageToken)
    }

    func threadMetadata(id: String) async throws -> GmailThread {
        try await get("threads/\(id)", query: [
            ("format", "metadata"), ("metadataHeaders", "From"), ("metadataHeaders", "Subject"),
            ("metadataHeaders", "Date"), ("metadataHeaders", "Content-Type"),
        ])
    }

    func threadFull(id: String) async throws -> GmailThread {
        try await get("threads/\(id)", query: [("format", "full")])
    }

    func modifyThread(id: String, add: [String], remove: [String]) async throws {
        try await post("threads/\(id)/modify", json: ["addLabelIds": add, "removeLabelIds": remove])
    }

    func trashThread(id: String) async throws { try await post("threads/\(id)/trash") }
    func untrashThread(id: String) async throws { try await post("threads/\(id)/untrash") }

    func attachment(messageID: String, attachmentID: String) async throws -> Data {
        struct Response: Decodable { var data: String? }
        let response: Response = try await get("messages/\(messageID)/attachments/\(attachmentID)")
        guard let data = response.data.flatMap(Base64URL.decode) else { throw MailError.invalidResponse }
        return data
    }

    /// Uploads a finished email with its thread ID in a multipart request (allows up to 35 MB).
    private func uploadRequest(path: String, method: String, metadata: [String: Any], raw: Data) throws -> URLRequest {
        let boundary = "maildock-" + UUID().uuidString
        var body = Data()
        body.append(Data("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".utf8))
        body.append(try JSONSerialization.data(withJSONObject: metadata))
        body.append(Data("\r\n--\(boundary)\r\nContent-Type: message/rfc822\r\n\r\n".utf8))
        body.append(raw)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var request = URLRequest(url: Self.url(Self.upload, path, query: [("uploadType", "multipart")]))
        request.httpMethod = method
        request.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return request
    }

    func send(raw: Data, threadID: String?) async throws {
        var metadata: [String: Any] = [:]
        if let threadID { metadata["threadId"] = threadID }
        _ = try await perform(try uploadRequest(path: "messages/send", method: "POST", metadata: metadata, raw: raw))
    }

    func saveDraft(id: String?, raw: Data, threadID: String?) async throws -> String {
        struct Response: Decodable { var id: String }
        var message: [String: Any] = [:]
        if let threadID { message["threadId"] = threadID }
        let path = id.map { "drafts/\($0)" } ?? "drafts"
        let request = try uploadRequest(path: path, method: id == nil ? "POST" : "PUT", metadata: ["message": message], raw: raw)
        let data = try await perform(request)
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else { throw MailError.invalidResponse }
        return response.id
    }

    func deleteDraft(id: String) async throws { try await post("drafts/\(id)", method: "DELETE") }

    func draftID(forMessage messageID: String) async throws -> String? {
        struct Response: Decodable {
            struct Item: Decodable { struct Message: Decodable { var id: String }; var id: String; var message: Message? }
            var drafts: [Item]?
            var nextPageToken: String?
        }
        var pageToken: String?
        repeat {
            var query = [("maxResults", "100")]
            if let pageToken { query.append(("pageToken", pageToken)) }
            let response: Response = try await get("drafts", query: query)
            if let match = response.drafts?.first(where: { $0.message?.id == messageID }) { return match.id }
            pageToken = response.nextPageToken
        } while pageToken != nil
        return nil
    }
}

enum Base64URL {
    static func decode(_ value: String) -> Data? {
        var text = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        text = text.filter { !$0.isWhitespace }
        text = text.replacingOccurrences(of: "=", with: "")
        let remainder = text.count % 4
        if remainder > 0 { text += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: text)
    }
}

enum MessageParser {
    static func parse(_ raw: GmailMessage) -> MailMessage {
        let payload = raw.payload
        var collector = Collector(messageID: raw.id)
        if let payload { collector.walk(payload) }
        let millis = raw.internalDate.flatMap(Double.init) ?? 0
        return MailMessage(
            id: raw.id,
            threadID: raw.threadId ?? "",
            labelIDs: Set(raw.labelIds ?? []),
            from: AddressParser.parseList(payload?.header("From") ?? "").first ?? EmailAddress(name: "", email: ""),
            to: AddressParser.parseList(payload?.header("To") ?? ""),
            cc: AddressParser.parseList(payload?.header("Cc") ?? ""),
            replyTo: AddressParser.parseList(payload?.header("Reply-To") ?? ""),
            subject: payload?.header("Subject") ?? "",
            date: Date(timeIntervalSince1970: millis / 1000),
            messageIDHeader: payload?.header("Message-ID") ?? "",
            references: payload?.header("References") ?? "",
            snippet: decodeEntities(raw.snippet ?? ""),
            plainBody: collector.plain,
            htmlBody: collector.html,
            attachments: collector.attachments,
            inlineImages: collector.inline)
    }

    private struct Collector {
        let messageID: String
        var plain: String?
        var html: String?
        var attachments: [AttachmentInfo] = []
        var inline: [AttachmentInfo] = []

        mutating func walk(_ part: GmailPart) {
            let mime = (part.mimeType ?? "").lowercased()
            let disposition = (part.header("Content-Disposition") ?? "").lowercased()
            let filename = part.filename ?? ""
            let contentID = part.header("Content-ID").map {
                $0.trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
            }
            let isAttachment = !filename.isEmpty || part.body?.attachmentId != nil || disposition.hasPrefix("attachment")
            if isAttachment {
                let info = AttachmentInfo(
                    messageID: messageID, attachmentID: part.body?.attachmentId,
                    filename: filename.isEmpty ? "attachment" : filename, mimeType: mime,
                    size: part.body?.size ?? 0, contentID: contentID,
                    inlineData: part.body?.data.flatMap(Base64URL.decode))
                if mime.hasPrefix("image/"), contentID != nil, !disposition.hasPrefix("attachment") {
                    inline.append(info)
                } else {
                    attachments.append(info)
                }
            } else if mime == "text/plain" || mime == "text/html", let encoded = part.body?.data,
                      let data = Base64URL.decode(encoded) {
                let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
                if mime == "text/plain" {
                    plain = plain.map { $0 + "\n\n" + text } ?? text
                } else {
                    html = html.map { $0 + "<hr>" + text } ?? text
                }
            }
            for child in part.parts ?? [] { walk(child) }
        }
    }

    /// Builds the row shown in the message list from a metadata-only thread.
    static func summary(_ thread: GmailThread, ref: ThreadRef, account: String) -> ThreadSummary {
        let messages = thread.messages ?? []
        var labels = Set<String>()
        var seen = Set<String>()
        var names = [String]()
        var attachment = false
        for message in messages {
            labels.formUnion(message.labelIds ?? [])
            if (message.payload?.header("Content-Type") ?? "").lowercased().hasPrefix("multipart/mixed") { attachment = true }
            guard let from = message.payload?.header("From"), let sender = AddressParser.parseList(from).first else { continue }
            let isMe = sender.email.caseInsensitiveCompare(account) == .orderedSame
            let name = isMe ? "me" : shortName(sender)
            if seen.insert(name).inserted { names.append(name) }
        }
        let newest = messages.last { !($0.labelIds ?? []).contains(SystemLabel.draft) } ?? messages.last
        let millis = newest?.internalDate.flatMap(Double.init) ?? 0
        return ThreadSummary(
            threadID: thread.id,
            account: account,
            subject: messages.first?.payload?.header("Subject") ?? "",
            snippet: decodeEntities(ref.snippet.isEmpty ? (newest?.snippet ?? "") : ref.snippet),
            senders: names.joined(separator: ", "),
            date: Date(timeIntervalSince1970: millis / 1000),
            messageCount: messages.count,
            labelIDs: labels,
            historyID: thread.historyId ?? ref.historyID,
            hasAttachment: attachment)
    }

    private static func shortName(_ address: EmailAddress) -> String {
        if !address.name.isEmpty { return address.name }
        return address.email.split(separator: "@").first.map(String.init) ?? address.email
    }

    /// Gmail's snippets contain HTML entities such as &#39;.
    static func decodeEntities(_ text: String) -> String { HTMLEntities.decode(text) }
}

enum AddressParser {
    static func parseList(_ value: String) -> [EmailAddress] { split(value).compactMap(parseOne) }

    /// Splits on commas and semicolons that aren't inside quotes or angle brackets.
    static func split(_ value: String) -> [String] {
        var items = [String](), current = ""
        var inQuotes = false, inAngle = false, escaped = false
        for character in value {
            if escaped { current.append(character); escaped = false; continue }
            switch character {
            case "\\" where inQuotes: current.append(character); escaped = true
            case "\"": inQuotes.toggle(); current.append(character)
            case "<" where !inQuotes: inAngle = true; current.append(character)
            case ">" where !inQuotes: inAngle = false; current.append(character)
            case ",", ";":
                if inQuotes || inAngle { current.append(character) } else { items.append(current); current = "" }
            default: current.append(character)
            }
        }
        items.append(current)
        return items.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    static func parseOne(_ text: String) -> EmailAddress? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if let open = value.lastIndex(of: "<"), let close = value.lastIndex(of: ">"), open < close {
            let email = String(value[value.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
            var name = String(value[..<open]).trimmingCharacters(in: .whitespaces)
            if name.count >= 2, name.hasPrefix("\""), name.hasSuffix("\"") {
                name = String(name.dropFirst().dropLast())
                    .replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
            }
            return EmailAddress(name: name, email: email)
        }
        return EmailAddress(name: "", email: value)
    }
}
