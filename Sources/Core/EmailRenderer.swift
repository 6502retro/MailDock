import Foundation

struct InlineRun: Hashable {
    var text: String
    var bold = false
    var italic = false
    var code = false
    var strike = false
    var link: URL?
}

enum EmailImageSource: Hashable {
    case remote(URL)
    case contentID(String)
    case data(Data)
}

struct EmailImage: Hashable {
    var source: EmailImageSource
    var alt: String
    var width: Double?
    var height: Double?
    var link: URL?
}

enum BlockTextStyle: Hashable { case body, heading(Int), preformatted }

enum BlockKind: Hashable {
    case text([InlineRun], BlockTextStyle)
    case image(EmailImage)
    case rule
}

struct EmailBlock: Identifiable, Hashable {
    var id: Int
    var kind: BlockKind
    var quoteDepth: Int
    var indent: Int
    var prefix: String?
}

struct EmailDocument: Hashable {
    var blocks: [EmailBlock]

    var hasRemoteImages: Bool {
        blocks.contains { if case .image(let image) = $0.kind, case .remote = image.source { return true }; return false }
    }

    var mainBlocks: [EmailBlock] { blocks.filter { $0.quoteDepth == 0 } }

    var hasText: Bool {
        blocks.contains { if case .text(let runs, _) = $0.kind { return runs.contains { !$0.text.isEmpty } }; return false }
    }

    /// True when there's quoted history that can be folded away under a new message.
    var hasCollapsibleQuote: Bool { !mainBlocks.isEmpty && mainBlocks.count < blocks.count }

    var plainText: String {
        var lines = [String]()
        for block in blocks {
            let quote = String(repeating: "> ", count: block.quoteDepth)
            switch block.kind {
            case .rule: lines.append(quote + "---")
            case .image(let image): if !image.alt.isEmpty { lines.append(quote + "[" + image.alt + "]") }
            case .text(let runs, _):
                let body = (block.prefix ?? "") + runs.map(\.text).joined()
                lines.append(contentsOf: body.components(separatedBy: "\n").map { quote + $0 })
            }
            lines.append(quote.trimmingCharacters(in: .whitespaces))
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }
}

enum HTMLEntities {
    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{A0}",
        "copy": "©", "reg": "®", "trade": "™", "mdash": "—", "ndash": "–", "hellip": "…",
        "rsquo": "’", "lsquo": "‘", "rdquo": "”", "ldquo": "“", "sbquo": "‚", "bdquo": "„",
        "bull": "•", "middot": "·", "laquo": "«", "raquo": "»", "euro": "€", "pound": "£",
        "yen": "¥", "cent": "¢", "times": "×", "divide": "÷", "deg": "°", "plusmn": "±",
        "sect": "§", "para": "¶", "dagger": "†", "larr": "←", "rarr": "→", "uarr": "↑",
        "darr": "↓", "zwnj": "\u{200C}", "zwj": "\u{200D}", "shy": "", "ensp": " ", "emsp": " ",
        "thinsp": " ", "frac12": "½", "frac14": "¼", "frac34": "¾", "eacute": "é", "egrave": "è",
        "agrave": "à", "aacute": "á", "ccedil": "ç", "ntilde": "ñ", "uuml": "ü", "ouml": "ö",
        "auml": "ä", "szlig": "ß", "iexcl": "¡", "iquest": "¿",
    ]

    static func decode(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var output = ""
        output.reserveCapacity(text.count)
        var index = text.startIndex
        while index < text.endIndex {
            guard text[index] == "&" else { output.append(text[index]); index = text.index(after: index); continue }
            let limit = text.index(index, offsetBy: 12, limitedBy: text.endIndex) ?? text.endIndex
            if let semi = text[index..<limit].firstIndex(of: ";"),
               let value = entity(String(text[text.index(after: index)..<semi])) {
                output += value
                index = text.index(after: semi)
            } else {
                output.append("&")
                index = text.index(after: index)
            }
        }
        return output
    }

    private static func entity(_ name: String) -> String? {
        if name.hasPrefix("#") {
            let digits = name.dropFirst()
            let number = digits.first == "x" || digits.first == "X"
                ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits, radix: 10)
            guard let number, number != 0, let scalar = Unicode.Scalar(number) else { return nil }
            return String(Character(scalar))
        }
        return named[name]
    }
}

enum EmailRenderer {
    static func render(message: MailMessage) -> EmailDocument {
        if let html = message.htmlBody, !html.isEmpty {
            let document = renderHTML(html)
            if document.hasText { return document }
        }
        // Never show a blank message: fall back to the plain-text version, then the preview.
        if let plain = message.plainBody, !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return renderPlain(plain)
        }
        if let html = message.htmlBody, !html.isEmpty {
            let document = renderHTML(html)
            if !document.blocks.isEmpty { return document }
        }
        return renderPlain(message.snippet)
    }

    static func safeLink(_ value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              ["http", "https", "mailto"].contains(scheme) else { return nil }
        return url
    }

    // MARK: Plain text

    private static let urlPattern = try! NSRegularExpression(pattern: #"https?://[^\s<>"]+"#, options: [.caseInsensitive])

    static func linkified(_ text: String) -> [InlineRun] {
        let source = text as NSString
        var runs = [InlineRun]()
        var position = 0
        for match in urlPattern.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            var range = match.range
            while range.length > 0, ".,;:!?)]'".contains(source.substring(with: NSRange(location: range.location + range.length - 1, length: 1))) {
                range.length -= 1
            }
            guard range.length > 0, let url = safeLink(source.substring(with: range)) else { continue }
            if range.location > position {
                runs.append(InlineRun(text: source.substring(with: NSRange(location: position, length: range.location - position))))
            }
            runs.append(InlineRun(text: source.substring(with: range), link: url))
            position = range.location + range.length
        }
        if position < source.length { runs.append(InlineRun(text: source.substring(from: position))) }
        return runs
    }

    static func renderPlain(_ text: String) -> EmailDocument {
        var blocks = [EmailBlock]()
        var buffer = [String]()
        var bufferDepth = 0
        func flush() {
            let joined = buffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            buffer = []
            guard !joined.isEmpty else { return }
            blocks.append(EmailBlock(id: blocks.count, kind: .text(linkified(joined), .body), quoteDepth: bufferDepth, indent: 0, prefix: nil))
        }
        for rawLine in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            var line = Substring(rawLine)
            var depth = 0
            while line.hasPrefix(">") {
                depth += 1
                line = line.dropFirst()
                if line.hasPrefix(" ") { line = line.dropFirst() }
            }
            if depth != bufferDepth { flush(); bufferDepth = depth }
            if line.trimmingCharacters(in: .whitespaces).isEmpty { flush() } else { buffer.append(String(line)) }
        }
        flush()
        return EmailDocument(blocks: blocks)
    }

    // MARK: HTML

    static func renderHTML(_ html: String) -> EmailDocument {
        var builder = HTMLBuilder()
        builder.run(Array(html.utf8))
        return EmailDocument(blocks: builder.blocks)
    }
}

private struct HTMLBuilder {
    struct Element {
        var name: String
        var bold = false, italic = false, strike = false, code = false, quote = false, pre = false
        var heading: Int?
        var link = false
        var list = false
    }

    private static let voidTags: Set<String> = ["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"]
    private static let rawTags: Set<String> = ["script", "style", "title", "textarea", "xmp"]
    private static let droppedTags: Set<String> = ["head", "svg", "object", "embed", "iframe", "template", "select", "map", "audio", "video", "canvas", "math"]
    private static let blockTags: Set<String> = [
        "p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "li", "table", "tbody", "thead", "tfoot", "tr",
        "blockquote", "pre", "section", "article", "aside", "header", "footer", "nav", "main", "center", "address",
        "dl", "dt", "dd", "form", "fieldset", "figure", "figcaption", "body", "html", "caption",
    ]
    private static let hiddenPattern = try! NSRegularExpression(
        // font-size:0 is left out on purpose: email layouts use it on column wrappers.
        pattern: #"(?:^|;)(?:max-height|opacity):0(?:px|pt|em|rem|%)?(?:!important)?(?:;|$)"#)

    var blocks = [EmailBlock]()
    private var stack = [Element]()
    private var runs = [InlineRun]()
    private var boldCount = 0, italicCount = 0, strikeCount = 0, codeCount = 0, quoteCount = 0, preCount = 0
    private var links = [URL?]()
    private var headings = [Int]()
    private var lists = [(ordered: Bool, counter: Int)]()
    private var pendingPrefix: String?
    private var skipName: String?
    private var skipDepth = 0

    private var endsInSpace: Bool {
        guard let last = runs.last?.text.last else { return true }
        return last == " " || last == "\n"
    }

    mutating func run(_ bytes: [UInt8]) {
        var index = 0
        let count = bytes.count
        while index < count {
            guard bytes[index] == UInt8(ascii: "<") else {
                var end = index
                while end < count, bytes[end] != UInt8(ascii: "<") { end += 1 }
                if skipName == nil { text(String(decoding: bytes[index..<end], as: UTF8.self)) }
                index = end
                continue
            }
            if hasPrefix(bytes, index, "<!--") {
                index = find(bytes, "-->", from: index + 4).map { $0 + 3 } ?? count
            } else if index + 1 < count, bytes[index + 1] == UInt8(ascii: "!") || bytes[index + 1] == UInt8(ascii: "?") {
                index = (bytes[index...].firstIndex(of: UInt8(ascii: ">")) ?? count - 1) + 1
            } else if index + 1 < count, isTagStart(bytes[index + 1]) {
                index = tag(bytes, at: index)
            } else {
                if skipName == nil { text("<") }
                index += 1
            }
        }
        flush()
    }

    private func isTagStart(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: "/") || (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
    }

    private func hasPrefix(_ bytes: [UInt8], _ index: Int, _ prefix: String) -> Bool {
        let wanted = Array(prefix.utf8)
        guard index + wanted.count <= bytes.count else { return false }
        return Array(bytes[index..<index + wanted.count]) == wanted
    }

    private func find(_ bytes: [UInt8], _ needle: String, from start: Int, ignoreCase: Bool = false) -> Int? {
        let wanted = Array((ignoreCase ? needle.lowercased() : needle).utf8)
        guard bytes.count >= wanted.count, start <= bytes.count - wanted.count else { return nil }
        var index = start
        while index <= bytes.count - wanted.count {
            var matched = true
            for offset in 0..<wanted.count {
                var byte = bytes[index + offset]
                if ignoreCase, byte >= 65, byte <= 90 { byte += 32 }
                if byte != wanted[offset] { matched = false; break }
            }
            if matched { return index }
            index += 1
        }
        return nil
    }

    private mutating func tag(_ bytes: [UInt8], at start: Int) -> Int {
        var index = start + 1
        let closing = bytes[index] == UInt8(ascii: "/")
        if closing { index += 1 }
        let nameStart = index
        while index < bytes.count, !isSpace(bytes[index]), bytes[index] != UInt8(ascii: ">"), bytes[index] != UInt8(ascii: "/") { index += 1 }
        let name = String(decoding: bytes[nameStart..<index], as: UTF8.self).lowercased()

        var attributes = [String: String]()
        var selfClosing = false
        while index < bytes.count, bytes[index] != UInt8(ascii: ">") {
            if isSpace(bytes[index]) { index += 1; continue }
            if bytes[index] == UInt8(ascii: "/") { selfClosing = true; index += 1; continue }
            selfClosing = false
            let keyStart = index
            while index < bytes.count, !isSpace(bytes[index]), bytes[index] != UInt8(ascii: "="), bytes[index] != UInt8(ascii: ">") { index += 1 }
            let key = String(decoding: bytes[keyStart..<index], as: UTF8.self).lowercased()
            while index < bytes.count, isSpace(bytes[index]) { index += 1 }
            var value = ""
            if index < bytes.count, bytes[index] == UInt8(ascii: "=") {
                index += 1
                while index < bytes.count, isSpace(bytes[index]) { index += 1 }
                if index < bytes.count, bytes[index] == UInt8(ascii: "\"") || bytes[index] == UInt8(ascii: "'") {
                    let quote = bytes[index]
                    index += 1
                    let valueStart = index
                    while index < bytes.count, bytes[index] != quote { index += 1 }
                    value = String(decoding: bytes[valueStart..<index], as: UTF8.self)
                    index += 1
                } else {
                    let valueStart = index
                    while index < bytes.count, !isSpace(bytes[index]), bytes[index] != UInt8(ascii: ">") { index += 1 }
                    value = String(decoding: bytes[valueStart..<index], as: UTF8.self)
                }
            }
            if !key.isEmpty, attributes[key] == nil { attributes[key] = HTMLEntities.decode(value) }
        }
        let end = min(index + 1, bytes.count)

        if let skip = skipName {
            if !closing, skip == "head", name == "body" {
                skipName = nil
            } else {
                if name == skip {
                    if closing { skipDepth -= 1 } else if !selfClosing { skipDepth += 1 }
                    if skipDepth == 0 { skipName = nil }
                }
                return end
            }
        }

        if closing { close(name); return end }

        if Self.rawTags.contains(name) {
            guard !selfClosing else { return end }
            guard let closeAt = find(bytes, "</" + name, from: end, ignoreCase: true) else { return bytes.count }
            return (bytes[closeAt...].firstIndex(of: UInt8(ascii: ">")) ?? bytes.count - 1) + 1
        }
        let isVoid = Self.voidTags.contains(name)
        if !isVoid, !selfClosing, Self.droppedTags.contains(name) || isHidden(attributes) {
            skipName = name
            skipDepth = 1
            return end
        }
        if isHidden(attributes) { return end }
        open(name, attributes: attributes, selfClosing: selfClosing || isVoid)
        return end
    }

    private func isSpace(_ byte: UInt8) -> Bool { byte == 32 || byte == 9 || byte == 10 || byte == 13 || byte == 12 }

    private func cleanStyle(_ attributes: [String: String]) -> String {
        (attributes["style"] ?? "").lowercased().filter { !$0.isWhitespace }
    }

    private func isHidden(_ attributes: [String: String]) -> Bool {
        if attributes["hidden"] != nil { return true }
        let style = cleanStyle(attributes)
        guard !style.isEmpty else { return false }
        if style.contains("display:none") || style.contains("visibility:hidden") || style.contains("mso-hide:all") { return true }
        return Self.hiddenPattern.firstMatch(in: style, range: NSRange(style.startIndex..., in: style)) != nil
    }

    private mutating func open(_ name: String, attributes: [String: String], selfClosing: Bool) {
        switch name {
        case "br":
            if !runs.isEmpty, !(runs.last?.text.hasSuffix("\n\n") ?? false) { append("\n") }
            return
        case "hr":
            flush()
            addBlock(.rule)
            return
        case "img":
            image(attributes)
            return
        case "td", "th":
            if !runs.isEmpty { appendRaw("   ") }
        default:
            break
        }
        if Self.blockTags.contains(name) { flush() }
        if name == "li", let current = lists.last {
            var prefix = "• "
            if current.ordered {
                lists[lists.count - 1].counter += 1
                prefix = "\(lists[lists.count - 1].counter). "
            }
            pendingPrefix = prefix
        }
        guard !selfClosing else { return }

        var element = Element(name: name)
        let style = cleanStyle(attributes)
        let weightBold = ["font-weight:bold", "font-weight:bolder", "font-weight:600", "font-weight:700", "font-weight:800", "font-weight:900"].contains { style.contains($0) }
        element.bold = ["b", "strong", "th", "dt"].contains(name) || weightBold
        element.italic = ["i", "em", "cite", "dfn", "var"].contains(name) || style.contains("font-style:italic")
        element.strike = ["s", "strike", "del"].contains(name) || style.contains("text-decoration:line-through")
        element.code = ["code", "kbd", "samp", "tt"].contains(name)
        let classes = (attributes["class"] ?? "").lowercased().split(separator: " ").map(String.init)
        element.quote = name == "blockquote" || (name == "div" && classes.contains("gmail_quote"))
        element.pre = name == "pre"
        if name.count == 2, name.hasPrefix("h"), let level = Int(name.dropFirst()), (1...6).contains(level) { element.heading = level }
        element.list = name == "ul" || name == "ol"
        if name == "a" { element.link = true }

        if element.bold { boldCount += 1 }
        if element.italic { italicCount += 1 }
        if element.strike { strikeCount += 1 }
        if element.code { codeCount += 1 }
        if element.quote { quoteCount += 1 }
        if element.pre { preCount += 1 }
        if let level = element.heading { headings.append(level) }
        if element.list { lists.append((name == "ol", 0)) }
        if element.link { links.append(attributes["href"].flatMap(EmailRenderer.safeLink)) }
        stack.append(element)
    }

    private mutating func close(_ name: String) {
        if name == "br" { if !runs.isEmpty { append("\n") }; return }
        guard let position = stack.lastIndex(where: { $0.name == name }) else {
            if name == "p" || Self.blockTags.contains(name) { flush() }
            return
        }
        // Headings, quotes and lists change how text is laid out, so finish the paragraph first.
        if Self.blockTags.contains(name) { flush() }
        for element in stack[position...].reversed() {
            if element.bold { boldCount -= 1 }
            if element.italic { italicCount -= 1 }
            if element.strike { strikeCount -= 1 }
            if element.code { codeCount -= 1 }
            if element.quote { quoteCount -= 1 }
            if element.pre { preCount -= 1 }
            if element.heading != nil { headings.removeLast() }
            if element.list { lists.removeLast() }
            if element.link { links.removeLast() }
        }
        stack.removeSubrange(position...)
    }

    private mutating func image(_ attributes: [String: String]) {
        let width = attributes["width"].flatMap { Double($0.replacingOccurrences(of: "px", with: "")) }
        let height = attributes["height"].flatMap { Double($0.replacingOccurrences(of: "px", with: "")) }
        if let width, width <= 2 { return }
        if let height, height <= 2 { return }
        let alt = HTMLEntities.decode(attributes["alt"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if let width, let height, width <= 24, height <= 24 {
            if !alt.isEmpty { text(alt) }
            return
        }
        let src = (attributes["src"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var source: EmailImageSource?
        if src.lowercased().hasPrefix("cid:") {
            source = .contentID(String(src.dropFirst(4)))
        } else if src.lowercased().hasPrefix("data:image/"), let comma = src.firstIndex(of: ","),
                  src[..<comma].lowercased().hasSuffix(";base64") {
            source = Data(base64Encoded: String(src[src.index(after: comma)...]).filter { !$0.isWhitespace }).map(EmailImageSource.data)
        } else if src.lowercased().hasPrefix("http://") || src.lowercased().hasPrefix("https://"), let url = URL(string: src) {
            source = .remote(url)
        }
        guard let source else {
            if !alt.isEmpty { text(alt) }
            return
        }
        flush()
        addBlock(.image(EmailImage(source: source, alt: alt, width: width, height: height, link: links.last ?? nil)))
    }

    private mutating func text(_ raw: String) {
        let decoded = HTMLEntities.decode(raw).replacingOccurrences(of: "\u{A0}", with: " ").replacingOccurrences(of: "\u{200C}", with: "")
        if preCount > 0 { appendRaw(decoded.replacingOccurrences(of: "\r\n", with: "\n")); return }
        var collapsed = ""
        collapsed.reserveCapacity(decoded.count)
        var pendingSpace = false
        for character in decoded {
            if character.isWhitespace { pendingSpace = true; continue }
            if pendingSpace, !(collapsed.isEmpty && endsInSpace) { collapsed.append(" ") }
            pendingSpace = false
            collapsed.append(character)
        }
        if pendingSpace, !(collapsed.isEmpty && endsInSpace) { collapsed.append(" ") }
        if !collapsed.isEmpty { append(collapsed) }
    }

    private mutating func append(_ value: String) { appendRaw(value) }

    private mutating func appendRaw(_ value: String) {
        let new = InlineRun(text: value, bold: boldCount > 0, italic: italicCount > 0, code: codeCount > 0,
                            strike: strikeCount > 0, link: links.last ?? nil)
        if var last = runs.last, last.bold == new.bold, last.italic == new.italic, last.code == new.code,
           last.strike == new.strike, last.link == new.link {
            last.text += value
            runs[runs.count - 1] = last
        } else {
            runs.append(new)
        }
    }

    private mutating func addBlock(_ kind: BlockKind) {
        blocks.append(EmailBlock(id: blocks.count, kind: kind, quoteDepth: quoteCount, indent: max(0, lists.count - 1), prefix: nil))
    }

    private mutating func flush() {
        defer { runs = [] }
        guard runs.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { return }
        if preCount == 0 {
            runs[0].text = String(runs[0].text.drop { $0.isWhitespace })
            let last = runs.count - 1
            while let character = runs[last].text.last, character.isWhitespace { runs[last].text.removeLast() }
            runs.removeAll { $0.text.isEmpty }
        }
        guard !runs.isEmpty else { return }
        let style: BlockTextStyle = preCount > 0 ? .preformatted : headings.last.map(BlockTextStyle.heading) ?? .body
        var block = EmailBlock(id: blocks.count, kind: .text(runs, style), quoteDepth: quoteCount,
                               indent: max(0, lists.count - 1), prefix: pendingPrefix)
        pendingPrefix = nil
        if block.prefix == nil, lists.isEmpty { block.indent = 0 }
        blocks.append(block)
    }
}
