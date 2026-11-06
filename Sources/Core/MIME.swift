import Foundation

enum MIMEBuilder {
    static let maxAttachmentBytes = 25 * 1024 * 1024

    static func build(draft: ComposeDraft, from: EmailAddress, validate: Bool,
                      date: Date = Date(), boundary: String = "maildock_" + UUID().uuidString) throws -> Data {
        if draft.attachments.reduce(0, { $0 + $1.data.count }) > maxAttachmentBytes { throw MailError.attachmentsTooLarge }
        let to = try addressHeader(draft.to, validate: validate)
        let cc = try addressHeader(draft.cc, validate: validate)
        let bcc = try addressHeader(draft.bcc, validate: validate)
        if validate, to.isEmpty, cc.isEmpty, bcc.isEmpty { throw MailError.noRecipients }

        var headers = [
            "From: " + format(from),
            "Date: " + rfc5322Date(date),
            "Subject: " + encodeHeader(draft.subject),
            "MIME-Version: 1.0",
        ]
        if !to.isEmpty { headers.append("To: " + to) }
        if !cc.isEmpty { headers.append("Cc: " + cc) }
        if !bcc.isEmpty { headers.append("Bcc: " + bcc) }
        if let value = draft.inReplyTo.map(cleanHeader), !value.isEmpty { headers.append("In-Reply-To: " + value) }
        if let value = draft.references.map(cleanHeader), !value.isEmpty { headers.append("References: " + value) }

        let normalized = draft.body.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
        let textHeaders = "Content-Type: text/plain; charset=UTF-8\r\nContent-Transfer-Encoding: base64\r\n\r\n"
        let textBody = base64Lines(Data(normalized.utf8))

        var message = Data()
        func add(_ text: String) { message.append(Data(text.utf8)) }
        if draft.attachments.isEmpty {
            add(headers.joined(separator: "\r\n") + "\r\n" + textHeaders + textBody + "\r\n")
            return message
        }
        add(headers.joined(separator: "\r\n") + "\r\n")
        add("Content-Type: multipart/mixed; boundary=\"\(boundary)\"\r\n\r\n")
        add("--\(boundary)\r\n" + textHeaders + textBody + "\r\n")
        for attachment in draft.attachments {
            add("--\(boundary)\r\n")
            add("Content-Type: \(cleanMime(attachment.mimeType))\r\n")
            add("Content-Disposition: attachment; \(filenameParameter(attachment.filename))\r\n")
            add("Content-Transfer-Encoding: base64\r\n\r\n")
            add(base64Lines(attachment.data) + "\r\n")
        }
        add("--\(boundary)--\r\n")
        return message
    }

    private static func base64Lines(_ data: Data) -> String {
        data.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
    }

    static func rfc5322Date(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter.string(from: date)
    }

    /// Removes line breaks so typed text can't add extra email headers.
    static func cleanHeader(_ value: String) -> String {
        value.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    private static func cleanMime(_ value: String) -> String {
        let cleaned = cleanHeader(value)
        let valid = cleaned.range(of: #"^[A-Za-z0-9.+-]+/[A-Za-z0-9.+-]+$"#, options: .regularExpression) != nil
        return valid ? cleaned : "application/octet-stream"
    }

    private static func filenameParameter(_ name: String) -> String {
        var cleaned = cleanHeader(name).replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "\\", with: "_")
        if cleaned.isEmpty { cleaned = "attachment" }
        if cleaned.allSatisfy({ $0.isASCII && $0 != "\"" && $0 != "%" }) { return "filename=\"\(cleaned)\"" }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        allowed.formIntersection(CharacterSet(charactersIn: "\u{0}"..."\u{7F}"))
        return "filename*=UTF-8''" + (cleaned.addingPercentEncoding(withAllowedCharacters: allowed) ?? "attachment")
    }

    static func encodeHeader(_ value: String) -> String {
        let cleaned = cleanHeader(value)
        if cleaned.allSatisfy(\.isASCII) && cleaned.utf8.count <= 900 { return cleaned }
        var words = [String]()
        var chunk = ""
        for character in cleaned {
            if chunk.utf8.count + String(character).utf8.count > 45 { words.append(chunk); chunk = "" }
            chunk.append(character)
        }
        if !chunk.isEmpty { words.append(chunk) }
        return words.map { "=?UTF-8?B?" + Data($0.utf8).base64EncodedString() + "?=" }.joined(separator: "\r\n ")
    }

    static func format(_ address: EmailAddress) -> String {
        let email = cleanHeader(address.email)
        let name = cleanHeader(address.name)
        guard !name.isEmpty else { return email }
        if name.allSatisfy(\.isASCII) {
            let quoted = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(quoted)\" <\(email)>"
        }
        return encodeHeader(name) + " <" + email + ">"
    }

    static func isValid(email: String) -> Bool {
        email.range(of: #"^[^\s@<>,;]+@[^\s@<>,;]+\.[^\s@<>,;]+$"#, options: .regularExpression) != nil
    }

    private static func addressHeader(_ value: String, validate: Bool) throws -> String {
        var parts = [String]()
        for item in AddressParser.split(value) {
            guard let address = AddressParser.parseOne(item), isValid(email: address.email) else {
                if validate { throw MailError.invalidRecipient(item) }
                parts.append(cleanHeader(item))
                continue
            }
            parts.append(format(address))
        }
        return parts.joined(separator: ", ")
    }
}

enum ComposeFactory {
    static func display(_ address: EmailAddress) -> String {
        guard !address.name.isEmpty else { return address.email }
        let needsQuotes = address.name.contains { ",;<>\"".contains($0) }
        let name = needsQuotes ? "\"" + address.name.replacingOccurrences(of: "\"", with: "\\\"") + "\"" : address.name
        return "\(name) <\(address.email)>"
    }

    private static func displayList(_ addresses: [EmailAddress]) -> String { addresses.map(display).joined(separator: ", ") }

    private static func same(_ left: String, _ right: String) -> Bool { left.caseInsensitiveCompare(right) == .orderedSame }

    private static func prefixed(_ subject: String, _ prefix: String, alternatives: [String]) -> String {
        let lower = subject.lowercased()
        return alternatives.contains { lower.hasPrefix($0) } ? subject : prefix + subject
    }

    private static func dateLine(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = "EEE, MMM d, yyyy 'at' h:mm a"
        return formatter.string(from: date)
    }

    private static func signatureBlock(_ signature: String) -> String { signature.isEmpty ? "" : "\n\n" + signature }

    static func reply(to rendered: RenderedMessage, account: Account, replyAll: Bool) -> ComposeDraft {
        let message = rendered.message
        let sentByMe = same(message.from.email, account.email)
        var recipients = sentByMe ? message.to : (message.replyTo.isEmpty ? [message.from] : message.replyTo)
        var copies = [EmailAddress]()
        if replyAll {
            var seen = Set(recipients.map { $0.email.lowercased() })
            seen.insert(account.email.lowercased())
            for address in (sentByMe ? [] : message.to) + message.cc where seen.insert(address.email.lowercased()).inserted {
                copies.append(address)
            }
        }
        if recipients.isEmpty { recipients = [message.from] }
        var draft = ComposeDraft(account: account.email)
        draft.to = displayList(recipients)
        draft.cc = displayList(copies)
        draft.subject = prefixed(message.subject, "Re: ", alternatives: ["re:"])
        draft.threadID = message.threadID
        draft.inReplyTo = message.messageIDHeader
        draft.references = (message.references + " " + message.messageIDHeader).trimmingCharacters(in: .whitespaces)
        let quoted = rendered.document.plainText.components(separatedBy: "\n")
            .map { $0.hasPrefix(">") ? ">" + $0 : ($0.isEmpty ? ">" : "> " + $0) }.joined(separator: "\n")
        draft.body = "\n" + signatureBlock(account.signature)
            + "\n\nOn \(dateLine(message.date)), \(display(message.from)) wrote:\n" + quoted
        return draft
    }

    static func forward(_ rendered: RenderedMessage, account: Account) -> ComposeDraft {
        let message = rendered.message
        var draft = ComposeDraft(account: account.email)
        draft.subject = prefixed(message.subject, "Fwd: ", alternatives: ["fwd:", "fw:"])
        var header = "---------- Forwarded message ---------\n"
        header += "From: \(display(message.from))\nDate: \(dateLine(message.date))\nSubject: \(message.subject)\n"
        header += "To: \(displayList(message.to))\n"
        if !message.cc.isEmpty { header += "Cc: \(displayList(message.cc))\n" }
        draft.body = "\n" + signatureBlock(account.signature) + "\n\n" + header + "\n" + rendered.document.plainText
        return draft
    }

    static func resume(_ rendered: RenderedMessage, account: Account, gmailDraftID: String?) -> ComposeDraft {
        let message = rendered.message
        var draft = ComposeDraft(account: account.email)
        draft.to = displayList(message.to)
        draft.cc = displayList(message.cc)
        draft.subject = message.subject
        draft.body = message.plainBody ?? rendered.document.plainText
        draft.threadID = message.threadID
        draft.gmailDraftID = gmailDraftID
        draft.references = message.references.isEmpty ? nil : message.references
        return draft
    }
}
