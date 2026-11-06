import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import MailDockCore

final class MemorySecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func read(_ key: String) -> Data? { lock.lock(); defer { lock.unlock() }; return values[key] }
    func write(_ key: String, _ value: Data) throws { lock.lock(); defer { lock.unlock() }; values[key] = value }
    func delete(_ key: String) { lock.lock(); defer { lock.unlock() }; values[key] = nil }
}

final class ScriptedTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    var responses: [HTTPResult] = []
    var requests: [URLRequest] = []
    func send(_ request: URLRequest) async throws -> HTTPResult {
        lock.lock(); defer { lock.unlock() }
        requests.append(request)
        return responses.isEmpty ? HTTPResult(status: 200, data: Data("{}".utf8), retryAfter: nil) : responses.removeFirst()
    }
}

func b64(_ text: String) -> String { PKCE.base64URL(Data(text.utf8)) }
func text(_ block: EmailBlock) -> String {
    if case .text(let runs, _) = block.kind { return runs.map(\.text).joined() }
    return ""
}

final class SignInTests: XCTestCase {
    func testPKCEMatchesRFC7636Example() {
        XCTAssertEqual(PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
                       "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }
    func testSoftwareSHA256KnownValuesAcrossPaddingBoundaries() {
        func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
        XCTAssertEqual(hex(PKCE.softwareSHA256(Data())), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(hex(PKCE.softwareSHA256(Data("abc".utf8))), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(hex(PKCE.softwareSHA256(Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8))),
                       "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    }
    func testVerifierIsLongEnoughAndURLSafe() {
        let verifier = PKCE.randomString()
        XCTAssertGreaterThanOrEqual(verifier.count, 43)
        XCTAssertLessThanOrEqual(verifier.count, 128)
        XCTAssertTrue(verifier.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        XCTAssertNotEqual(verifier, PKCE.randomString())
    }
    func testAuthorizationURL() {
        let url = GoogleOAuth.authorizationURL(client: .init(clientID: "id", clientSecret: "s"), redirectURI: "http://127.0.0.1:5000", state: "st", challenge: "ch")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        func v(_ n: String) -> String? { items.first { $0.name == n }?.value }
        XCTAssertEqual(v("redirect_uri"), "http://127.0.0.1:5000")
        XCTAssertEqual(v("code_challenge_method"), "S256")
        XCTAssertEqual(v("access_type"), "offline")
        XCTAssertEqual(v("scope"), "https://www.googleapis.com/auth/gmail.modify")
        XCTAssertTrue(v("prompt")!.contains("select_account"))
        XCTAssertFalse(url.absoluteString.contains("s&")) // secret never in the browser URL
    }
    func testClientFileParsing() throws {
        let ok = #"{"installed":{"client_id":"abc.apps.googleusercontent.com","client_secret":"sec"}}"#
        XCTAssertEqual(try OAuthClientConfig.parse(json: Data(ok.utf8)), .init(clientID: "abc.apps.googleusercontent.com", clientSecret: "sec"))
        XCTAssertThrowsError(try OAuthClientConfig.parse(json: Data(#"{"web":{"client_id":"x"}}"#.utf8)))
        XCTAssertThrowsError(try OAuthClientConfig.parse(json: Data("garbage".utf8)))
    }
    func testCallbackParsing() {
        let good = "GET /?state=abc&code=4%2F0Ab&scope=x HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
        XCTAssertEqual(LoopbackServer.parseCallback(request: good, expectedState: "abc"), .code("4/0Ab"))
        XCTAssertEqual(LoopbackServer.parseCallback(request: good, expectedState: "other"), .ignored)
        XCTAssertEqual(LoopbackServer.parseCallback(request: "GET /favicon.ico HTTP/1.1\r\n\r\n", expectedState: "abc"), .ignored)
        XCTAssertEqual(LoopbackServer.parseCallback(request: "GET /?state=abc&error=access_denied HTTP/1.1\r\n\r\n", expectedState: "abc"), .denied)
        XCTAssertEqual(LoopbackServer.parseCallback(request: "", expectedState: "abc"), .ignored)
    }
    func testLoopbackServerEndToEnd() async throws {
        let server = try LoopbackServer()
        XCTAssertGreaterThan(server.port, 0)
        let waiter = Task { try await server.waitForCode(state: "xyz", timeout: 10) }
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        let session = URLSession(configuration: config)
        func fetch(_ path: String) async throws -> Int {
            try await withCheckedThrowingContinuation { c in
                session.dataTask(with: URL(string: server.redirectURI + path)!) { _, r, e in
                    if let e { c.resume(throwing: e) } else { c.resume(returning: (r as! HTTPURLResponse).statusCode) }
                }.resume()
            }
        }
        // A wrong-state request (a forged redirect) must not complete sign-in.
        let bad = try await fetch("/?state=wrong&code=evil")
        XCTAssertEqual(bad, 404)
        let ok = try await fetch("/?state=xyz&code=real-code")
        XCTAssertEqual(ok, 200)
        let code = try await waiter.value
        XCTAssertEqual(code, "real-code")
    }
    func testLoopbackCancelAndTimeout() async throws {
        let server = try LoopbackServer()
        let waiter = Task { try await server.waitForCode(state: "x", timeout: 30) }
        server.cancel()
        do { _ = try await waiter.value; XCTFail() } catch { XCTAssertEqual(error as? MailError, .signInCancelled) }
        let second = try LoopbackServer()
        do { _ = try await second.waitForCode(state: "x", timeout: 0.1); XCTFail() } catch { XCTAssertEqual(error as? MailError, .signInTimedOut) }
    }
    func testTokenExchangeAndRefreshRequests() async throws {
        let transport = ScriptedTransport()
        transport.responses = [HTTPResult(status: 200, data: Data(#"{"access_token":"a","refresh_token":"r","expires_in":3600}"#.utf8), retryAfter: nil)]
        let now = Date(timeIntervalSince1970: 1000)
        let set = try await GoogleOAuth.exchange(code: "c/d", verifier: "v", redirectURI: "http://127.0.0.1:1", client: .init(clientID: "i", clientSecret: "s"), transport: transport, now: now)
        XCTAssertEqual(set, TokenSet(accessToken: "a", refreshToken: "r", expiresAt: Date(timeIntervalSince1970: 4600)))
        let body = String(decoding: transport.requests[0].httpBody!, as: UTF8.self)
        XCTAssertTrue(body.contains("code=c%2Fd"))
        XCTAssertTrue(body.contains("code_verifier=v"))
        XCTAssertTrue(body.contains("redirect_uri=http%3A%2F%2F127.0.0.1%3A1"))
    }
    func testExpiredGrantAsksForSignIn() async throws {
        let secrets = MemorySecrets()
        let transport = ScriptedTransport()
        transport.responses = [HTTPResult(status: 400, data: Data(#"{"error":"invalid_grant","error_description":"Token has been expired or revoked."}"#.utf8), retryAfter: nil)]
        let manager = AuthManager(client: .init(clientID: "i", clientSecret: ""), secrets: secrets, transport: transport)
        try await manager.save(TokenSet(accessToken: "old", refreshToken: "r", expiresAt: .distantPast), for: "a@b.c")
        do { _ = try await manager.accessToken(for: "a@b.c"); XCTFail() } catch { XCTAssertEqual(error as? MailError, .needsSignIn("a@b.c")) }
    }
    func testConcurrentCallersShareOneRefresh() async throws {
        let transport = ScriptedTransport()
        transport.responses = [HTTPResult(status: 200, data: Data(#"{"access_token":"new","expires_in":3600}"#.utf8), retryAfter: nil)]
        let manager = AuthManager(client: .init(clientID: "i", clientSecret: ""), secrets: MemorySecrets(), transport: transport)
        try await manager.save(TokenSet(accessToken: "old", refreshToken: "keep", expiresAt: .distantPast), for: "a@b.c")
        let tokens = try await concurrentMap(Array(0..<10), limit: 10) { _ in try await manager.accessToken(for: "a@b.c") }
        XCTAssertEqual(Set(tokens), ["new"])
        XCTAssertEqual(transport.requests.count, 1)
    }
}

final class GmailClientTests: XCTestCase {
    func client(_ transport: ScriptedTransport) -> GmailClient {
        GmailClient(transport: transport, baseDelay: 0.001) { force in force ? "fresh" : "stale" }
    }
    func testPlusInSearchIsEncoded() {
        let url = GmailClient.url("https://x/", "threads", query: [("q", "from:a+b@c.d subject:\"hi there\"")])
        XCTAssertTrue(url.absoluteString.contains("a%2Bb"))
        let decoded = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems![0].value
        XCTAssertEqual(decoded, "from:a+b@c.d subject:\"hi there\"")
    }
    func testRepeatsLabelParametersAndPagination() async throws {
        let t = ScriptedTransport()
        t.responses = [HTTPResult(status: 200, data: Data(#"{"threads":[{"id":"1","historyId":"9","snippet":"hi"}],"nextPageToken":"n"}"#.utf8), retryAfter: nil)]
        let page = try await client(t).listThreads(labelIDs: ["INBOX"], query: "category:primary", pageToken: "p", includeSpamTrash: true, maxResults: 30)
        XCTAssertEqual(page.threads, [ThreadRef(id: "1", historyID: "9", snippet: "hi")])
        XCTAssertEqual(page.nextPageToken, "n")
        let u = t.requests[0].url!.absoluteString
        for part in ["labelIds=INBOX", "q=category:primary", "pageToken=p", "includeSpamTrash=true", "maxResults=30"] { XCTAssertTrue(u.contains(part), u) }
    }
    func testRetriesWithFreshTokenOn401() async throws {
        let t = ScriptedTransport()
        t.responses = [HTTPResult(status: 401, data: Data(), retryAfter: nil),
                       HTTPResult(status: 200, data: Data(#"{"emailAddress":"a@b.c","historyId":"5"}"#.utf8), retryAfter: nil)]
        let p = try await client(t).profile()
        XCTAssertEqual(p.email, "a@b.c")
        XCTAssertEqual(t.requests.map { $0.value(forHTTPHeaderField: "Authorization") }, ["Bearer stale", "Bearer fresh"])
    }
    func testBacksOffOnRateLimitThenSucceeds() async throws {
        let rate = Data(#"{"error":{"code":403,"message":"slow","errors":[{"reason":"userRateLimitExceeded"}]}}"#.utf8)
        let t = ScriptedTransport()
        t.responses = [HTTPResult(status: 403, data: rate, retryAfter: nil), HTTPResult(status: 429, data: Data(), retryAfter: 0.001),
                       HTTPResult(status: 503, data: Data(), retryAfter: nil), HTTPResult(status: 200, data: Data(#"{"emailAddress":"a","historyId":"1"}"#.utf8), retryAfter: nil)]
        _ = try await client(t).profile()
        XCTAssertEqual(t.requests.count, 4)
    }
    func testPermissionErrorIsNotRetriedAndShowsGoogleMessage() async {
        let t = ScriptedTransport()
        t.responses = [HTTPResult(status: 403, data: Data(#"{"error":{"message":"Gmail API has not been used in project","errors":[{"reason":"accessNotConfigured"}]}}"#.utf8), retryAfter: nil)]
        do { _ = try await client(t).profile(); XCTFail() } catch {
            XCTAssertEqual(error as? MailError, .api(status: 403, message: "Gmail API has not been used in project"))
            XCTAssertEqual(t.requests.count, 1)
        }
    }
    func testGivesUpAfterRepeatedServerErrors() async {
        let t = ScriptedTransport()
        t.responses = Array(repeating: HTTPResult(status: 500, data: Data(), retryAfter: nil), count: 20)
        do { _ = try await client(t).profile(); XCTFail() } catch { XCTAssertEqual(t.requests.count, 5) }
    }
    func testSendUsesMultipartUploadWithThreadID() async throws {
        let t = ScriptedTransport()
        try await client(t).send(raw: Data("RAW-MIME".utf8), threadID: "thread1")
        let r = t.requests[0]
        XCTAssertEqual(r.url!.path, "/upload/gmail/v1/users/me/messages/send")
        XCTAssertTrue(r.url!.query!.contains("uploadType=multipart"))
        let type = r.value(forHTTPHeaderField: "Content-Type")!
        XCTAssertTrue(type.hasPrefix("multipart/related; boundary="))
        let boundary = type.components(separatedBy: "boundary=")[1]
        let body = String(decoding: r.httpBody!, as: UTF8.self)
        XCTAssertTrue(body.contains(#"{"threadId":"thread1"}"#))
        XCTAssertTrue(body.contains("Content-Type: message/rfc822\r\n\r\nRAW-MIME\r\n--\(boundary)--"))
    }
    func testDraftCreateThenUpdate() async throws {
        let t = ScriptedTransport()
        t.responses = [HTTPResult(status: 200, data: Data(#"{"id":"d1"}"#.utf8), retryAfter: nil),
                       HTTPResult(status: 200, data: Data(#"{"id":"d1"}"#.utf8), retryAfter: nil)]
        let c = client(t)
        let id = try await c.saveDraft(id: nil, raw: Data("x".utf8), threadID: nil)
        _ = try await c.saveDraft(id: id, raw: Data("y".utf8), threadID: nil)
        XCTAssertEqual(t.requests[0].httpMethod, "POST")
        XCTAssertEqual(t.requests[1].httpMethod, "PUT")
        XCTAssertTrue(t.requests[1].url!.path.hasSuffix("/drafts/d1"))
    }
    func testLabelsFetchCounts() async throws {
        let t = ScriptedTransport()
        t.responses = [HTTPResult(status: 200, data: Data(#"{"labels":[{"id":"INBOX","name":"INBOX","type":"system"}]}"#.utf8), retryAfter: nil),
                       HTTPResult(status: 200, data: Data(#"{"id":"INBOX","name":"INBOX","type":"system","threadsUnread":7,"threadsTotal":70}"#.utf8), retryAfter: nil)]
        let labels = try await client(t).labels()
        XCTAssertEqual(labels, [MailLabel(id: "INBOX", name: "INBOX", isSystem: true, threadsUnread: 7, threadsTotal: 70)])
    }
    func testFindsDraftAcrossPages() async throws {
        let t = ScriptedTransport()
        t.responses = [HTTPResult(status: 200, data: Data(#"{"drafts":[{"id":"a","message":{"id":"m1"}}],"nextPageToken":"p"}"#.utf8), retryAfter: nil),
                       HTTPResult(status: 200, data: Data(#"{"drafts":[{"id":"b","message":{"id":"m2"}}]}"#.utf8), retryAfter: nil)]
        let id = try await client(t).draftID(forMessage: "m2")
        XCTAssertEqual(id, "b")
    }
}

final class ParsingTests: XCTestCase {
    func decode(_ json: String) -> GmailMessage { try! JSONDecoder().decode(GmailMessage.self, from: Data(json.utf8)) }

    func testParsesRealisticMultipartMessage() {
        let json = """
        {"id":"m1","threadId":"t1","labelIds":["INBOX","UNREAD"],"snippet":"It&#39;s here","internalDate":"1700000000000",
         "payload":{"mimeType":"multipart/mixed","headers":[
           {"name":"From","value":"\\"Doe, Jane\\" <jane@example.com>"},
           {"name":"to","value":"me@x.com, Bob <bob@y.com>"},{"name":"Cc","value":"c@z.com"},
           {"name":"Subject","value":"Report"},{"name":"Message-ID","value":"<abc@mail>"},{"name":"References","value":"<r1@mail>"}],
          "parts":[{"mimeType":"multipart/related","parts":[
             {"mimeType":"multipart/alternative","parts":[
               {"mimeType":"text/plain","body":{"data":"\(b64("héllo plain"))"}},
               {"mimeType":"text/html","body":{"data":"\(b64("<b>héllo</b> <img src=cid:logo1 width=100>"))"}}]},
             {"mimeType":"image/png","filename":"logo.png","headers":[{"name":"Content-ID","value":"<logo1>"},{"name":"Content-Disposition","value":"inline"}],"body":{"attachmentId":"att-inline","size":10}}]},
            {"mimeType":"application/pdf","filename":"report.pdf","headers":[{"name":"Content-Disposition","value":"attachment"}],"body":{"attachmentId":"att1","size":999}}]}}
        """
        let m = MessageParser.parse(decode(json))
        XCTAssertEqual(m.from, EmailAddress(name: "Doe, Jane", email: "jane@example.com"))
        XCTAssertEqual(m.to.map(\.email), ["me@x.com", "bob@y.com"])
        XCTAssertEqual(m.plainBody, "héllo plain")
        XCTAssertTrue(m.htmlBody!.contains("<b>héllo</b>"))
        XCTAssertEqual(m.attachments.map(\.filename), ["report.pdf"])
        XCTAssertEqual(m.attachments[0].attachmentID, "att1")
        XCTAssertEqual(m.inlineImages.map(\.contentID), ["logo1"])
        XCTAssertEqual(m.snippet, "It's here")
        XCTAssertEqual(m.date, Date(timeIntervalSince1970: 1_700_000_000))
        let doc = EmailRenderer.render(message: m)
        XCTAssertTrue(doc.blocks.contains { if case .image(let i) = $0.kind { return i.source == .contentID("logo1") }; return false })
        XCTAssertFalse(doc.hasRemoteImages)
    }
    func testSinglePartPlainMessage() {
        let m = MessageParser.parse(decode(#"{"id":"1","payload":{"mimeType":"text/plain","body":{"data":"\#(b64("just text"))"}}}"#))
        XCTAssertEqual(m.plainBody, "just text")
        XCTAssertNil(m.htmlBody)
    }
    func testMalformedMessageDoesNotCrash() {
        let m = MessageParser.parse(decode(#"{"id":"1"}"#))
        XCTAssertEqual(m.from.email, "")
        XCTAssertEqual(EmailRenderer.render(message: m).blocks.count, 0)
    }
    func testBase64URLWithoutPaddingAndBinary() {
        XCTAssertEqual(Base64URL.decode("_-8"), Data([0xff, 0xef]))
        XCTAssertEqual(Base64URL.decode("YQ"), Data("a".utf8))
        XCTAssertEqual(Base64URL.decode("YQ=="), Data("a".utf8))
    }
    func testSummary() {
        let thread = """
        {"id":"t","historyId":"88","messages":[
         {"id":"1","labelIds":["INBOX"],"internalDate":"1000","payload":{"headers":[{"name":"From","value":"Ann <a@x.com>"},{"name":"Subject","value":"Hello"}]}},
         {"id":"2","labelIds":["SENT"],"internalDate":"2000","payload":{"headers":[{"name":"From","value":"Me <ME@x.com>"},{"name":"Subject","value":"Re: Hello"},{"name":"Content-Type","value":"multipart/mixed; boundary=a"}]}},
         {"id":"3","labelIds":["INBOX","UNREAD"],"internalDate":"3000","payload":{"headers":[{"name":"From","value":"Ann <a@x.com>"}]}},
         {"id":"4","labelIds":["DRAFT"],"internalDate":"9000","payload":{"headers":[{"name":"From","value":"Me <me@x.com>"}]}}]}
        """
        let t = try! JSONDecoder().decode(GmailThread.self, from: Data(thread.utf8))
        let s = MessageParser.summary(t, ref: ThreadRef(id: "t", historyID: "88", snippet: "a &amp; b"), account: "me@x.com")
        XCTAssertEqual(s.subject, "Hello")
        XCTAssertEqual(s.senders, "Ann, me")
        XCTAssertEqual(s.snippet, "a & b")
        XCTAssertEqual(s.messageCount, 4)
        XCTAssertTrue(s.isUnread)
        XCTAssertTrue(s.hasAttachment)
        XCTAssertEqual(s.date, Date(timeIntervalSince1970: 3)) // the draft doesn't count as latest
    }
    func testAddressParser() {
        XCTAssertEqual(AddressParser.split(#""A, B" <a@b.c>; d@e.f, <g@h.i>"#).count, 3)
        XCTAssertEqual(AddressParser.parseOne(#""Quo\"ted" <a@b.c>"#)?.name, #"Quo"ted"#)
        XCTAssertEqual(AddressParser.parseOne("plain@x.y"), EmailAddress(name: "", email: "plain@x.y"))
        XCTAssertEqual(AddressParser.parseList(" , ,").count, 0)
    }
}

final class RendererTests: XCTestCase {
    func testScriptsStylesAndHeadAreRemoved() {
        let d = EmailRenderer.renderHTML("<html><head><title>T</title><style>p{color:red}</style></head><body><script>alert(1)</script><p>Visible</p></body></html>")
        XCTAssertEqual(d.blocks.map(text), ["Visible"])
    }
    func testUnclosedHeadAndCaseInsensitiveTags() {
        let d = EmailRenderer.renderHTML("<HTML><HEAD><META charset=utf-8><BODY><P>Hi</P><SCRIPT>x</ScRiPt>after")
        XCTAssertEqual(d.blocks.map(text), ["Hi", "after"])
    }
    func testHiddenPreheaderIsRemovedButSmallFontIsNot() {
        let d = EmailRenderer.renderHTML(#"<div style="display:none;max-height:0">Preheader <div>nested</div> text</div><span style="font-size: 0px">zero</span><p style="font-size:0.9em;opacity:0.8">kept</p><div hidden>h</div><p style="max-height: 0; overflow:hidden">gone</p>"#)
        XCTAssertEqual(d.blocks.map(text), ["kept"])
    }
    func testInlineStyles() throws {
        let d = EmailRenderer.renderHTML(#"<p>a <b>b <i>c</i></b> <span style="font-weight:700">d</span> <s>e</s> <code>f</code></p>"#)
        guard case .text(let runs, _) = d.blocks[0].kind else { return XCTFail() }
        XCTAssertEqual(runs.map(\.text).joined(), "a b c d e f")
        XCTAssertTrue(runs.first { $0.text.contains("c") }!.italic && runs.first { $0.text.contains("c") }!.bold)
        XCTAssertTrue(runs.first { $0.text.contains("d") }!.bold)
        XCTAssertTrue(runs.first { $0.text.contains("e") }!.strike)
        XCTAssertTrue(runs.first { $0.text == "f" }!.code)
    }
    func testDangerousLinksDropped() {
        let d = EmailRenderer.renderHTML(#"<a href="javascript:alert(1)">x</a> <a href="https://ok.com/a?b=1&amp;c=2">y</a> <a href="file:///etc/passwd">z</a> <a href="mailto:a@b.c">m</a>"#)
        guard case .text(let runs, _) = d.blocks[0].kind else { return XCTFail() }
        let links = runs.compactMap(\.link).map(\.absoluteString)
        XCTAssertEqual(links, ["https://ok.com/a?b=1&c=2", "mailto:a@b.c"])
    }
    func testEntitiesIncludingMalformed() {
        XCTAssertEqual(HTMLEntities.decode("&lt;a&gt; &amp;amp; &#39;x&#x27; &copy; &unknown; AT&T & &#0; &#xFFFFFFFF;"), "<a> &amp; 'x' © &unknown; AT&T & &#0; &#xFFFFFFFF;")
    }
    func testWhitespaceAndBreaks() {
        let d = EmailRenderer.renderHTML("<p>  one\n   two<br>three<br><br><br><br>four&nbsp;&nbsp;five </p><p>&nbsp;</p><div> </div>")
        XCTAssertEqual(d.blocks.map(text), ["one two\nthree\n\nfour five"])
    }
    func testListsTablesRulesAndHeadings() {
        let d = EmailRenderer.renderHTML("<h2>Title</h2><ol><li>a</li><li>b<ul><li>c</li></ul></li></ol><table><tr><th>Name</th><td>Val</td></tr><tr><td>x</td><td>y</td></tr></table><hr><pre>  keep\n  this</pre>")
        XCTAssertEqual(d.blocks.map(text), ["Title", "a", "b", "c", "Name   Val", "x   y", "", "  keep\n  this"])
        XCTAssertEqual(d.blocks[1].prefix, "1. ")
        XCTAssertEqual(d.blocks[2].prefix, "2. ")
        XCTAssertEqual(d.blocks[3].prefix, "• ")
        XCTAssertEqual(d.blocks[3].indent, 1)
        if case .text(_, let style) = d.blocks[0].kind { XCTAssertEqual(style, .heading(2)) } else { XCTFail() }
        if case .rule = d.blocks[6].kind {} else { XCTFail() }
        if case .text(_, let style) = d.blocks[7].kind { XCTAssertEqual(style, .preformatted) } else { XCTFail() }
    }
    func testImagesTrackingPixelsAndIcons() {
        let html = #"<img src="https://t.co/open.gif" width="1" height="1"><img src="https://x.com/i.png" width=16 height=16 alt="star"><a href="https://shop.com"><img src="https://x.com/banner.jpg" width="600" alt="Sale"></a><img src="data:image/png;base64,iVBORw0K"><img src="javascript:x" alt="bad">"#
        let d = EmailRenderer.renderHTML(html)
        let images = d.blocks.compactMap { b -> EmailImage? in if case .image(let i) = b.kind { return i }; return nil }
        XCTAssertEqual(images.count, 2)
        XCTAssertEqual(images[0].link?.host, "shop.com")
        XCTAssertEqual(images[0].width, 600)
        XCTAssertTrue(d.hasRemoteImages)
        if case .data = images[1].source {} else { XCTFail() }
        XCTAssertEqual(d.blocks.map(text).filter { !$0.isEmpty }, ["star", "bad"])
    }
    func testGmailQuoteCollapse() {
        let d = EmailRenderer.renderHTML(#"<div>New reply</div><div class="gmail_quote"><div class="gmail_attr">On Mon, Ann wrote:</div><blockquote class="gmail_quote"><div>Old text</div></blockquote></div>"#)
        XCTAssertEqual(d.blocks.map(\.quoteDepth), [0, 1, 2])
        XCTAssertTrue(d.hasCollapsibleQuote)
        XCTAssertEqual(d.mainBlocks.map(text), ["New reply"])
        XCTAssertTrue(d.plainText.contains("> > Old text"))
    }
    func testNothingButQuoteIsNotCollapsed() {
        XCTAssertFalse(EmailRenderer.renderHTML("<blockquote>only</blockquote>").hasCollapsibleQuote)
    }
    func testBrokenMarkupNeverCrashesOrHangs() {
        let samples = ["<", "<<<>>>", "<a", "<a href=", "<a href=\"x", "</", "</div>", "<!--", "<!-- x", "<!", "<?xml", "<script>", "<script", "<style>x", "<div style=\"display:none\">x",
                       "<img", "<img src=", "<b><i></b></i>", "&", "&#", "&#x;", "<p/>", "<br/>", "<td>", "<li>", "<ul><li>", "</ol></ol>", "a < b > c", "<textarea>", String(repeating: "<div>", count: 20000), String(repeating: "</b>", count: 5000), "\u{0}<p>\u{FFFD}</p>"]
        for s in samples { _ = EmailRenderer.renderHTML(s) }
        var generator = SystemRandomNumberGenerator()
        let alphabet = Array("<>/=\"' abpdivhrimgsctyle&#;!-\n")
        for _ in 0..<3000 {
            let s = String((0..<Int.random(in: 0...120, using: &generator)).map { _ in alphabet.randomElement(using: &generator)! })
            _ = EmailRenderer.renderHTML(s)
        }
    }
    func testLargeMailRendersQuickly() {
        let html = String(repeating: #"<table><tr><td style="padding:4px"><a href="https://x.co/1"><b>Item</b></a> text &amp; more</td></tr></table>"#, count: 20000)
        let start = Date()
        let d = EmailRenderer.renderHTML(html)
        XCTAssertEqual(d.blocks.count, 20000)
        XCTAssertLessThan(Date().timeIntervalSince(start), 15)
    }
    func testPlainTextQuotesAndLinks() {
        let d = EmailRenderer.renderPlain("Hello\r\nsee https://a.com/x?y=1.\n\n> quoted\n>> deeper\nback")
        XCTAssertEqual(d.blocks.map(\.quoteDepth), [0, 1, 2, 0])
        guard case .text(let runs, _) = d.blocks[0].kind else { return XCTFail() }
        XCTAssertEqual(runs.compactMap(\.link).first?.absoluteString, "https://a.com/x?y=1")
        XCTAssertEqual(runs.map(\.text).joined(), "Hello\nsee https://a.com/x?y=1.")
    }
}

final class OutgoingTests: XCTestCase {
    let me = EmailAddress(name: "Jo Ádar", email: "me@x.com")
    let fixed = Date(timeIntervalSince1970: 1_700_000_000)

    /// Parses a built message the way a receiving mail server would.
    func split(_ data: Data) -> (headers: [String: String], body: String) {
        let s = String(decoding: data, as: UTF8.self)
        let parts = s.components(separatedBy: "\r\n\r\n")
        var headers = [String: String]()
        let unfolded = parts[0].replacingOccurrences(of: "\r\n ", with: " ")
        for line in unfolded.components(separatedBy: "\r\n") {
            let pair = line.split(separator: ":", maxSplits: 1).map(String.init)
            headers[pair[0]] = pair[1].trimmingCharacters(in: .whitespaces)
        }
        return (headers, parts.dropFirst().joined(separator: "\r\n\r\n"))
    }
    func testPlainMessage() throws {
        var d = ComposeDraft(account: "me@x.com")
        d.to = #""Doe, Jane" <jane@e.com>, bob@y.com"#; d.cc = "c@z.com"; d.bcc = "secret@z.com"
        d.subject = "Hello"; d.body = "line1\nline2 ñ"; d.inReplyTo = "<a@b>"; d.references = "<x@y> <a@b>"
        let (h, body) = split(try MIMEBuilder.build(draft: d, from: me, validate: true, date: fixed))
        XCTAssertEqual(h["To"], #""Doe, Jane" <jane@e.com>, bob@y.com"#)
        XCTAssertEqual(h["Bcc"], "secret@z.com")
        XCTAssertEqual(h["In-Reply-To"], "<a@b>")
        XCTAssertEqual(h["References"], "<x@y> <a@b>")
        XCTAssertTrue(h["From"]!.hasPrefix("=?UTF-8?B?"))
        XCTAssertTrue(h["From"]!.hasSuffix("<me@x.com>"))
        XCTAssertEqual(String(decoding: Data(base64Encoded: body.filter { !$0.isWhitespace })!, as: UTF8.self), "line1\r\nline2 ñ")
    }
    func testUnicodeSubjectStaysValidAcrossEncodedWords() throws {
        let subject = String(repeating: "日本語🙂", count: 30)
        let encoded = MIMEBuilder.encodeHeader(subject)
        var bytes = Data()
        for word in encoded.components(separatedBy: "\r\n ") {
            XCTAssertLessThanOrEqual(word.count, 75)
            let inner = word.dropFirst("=?UTF-8?B?".count).dropLast(2)
            let chunk = Data(base64Encoded: String(inner))!
            XCTAssertNotNil(String(data: chunk, encoding: .utf8)) // no character cut in half
            bytes.append(chunk)
        }
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self), subject)
    }
    func testHeaderInjectionIsBlocked() throws {
        var d = ComposeDraft(account: "me@x.com")
        d.to = "a@b.co"; d.subject = "Hi\r\nBcc: evil@x.com\r\n\r\nbody"
        let raw = String(decoding: try MIMEBuilder.build(draft: d, from: EmailAddress(name: "x\r\nBcc: e@x", email: "me@x.com"), validate: true), as: UTF8.self)
        XCTAssertFalse(raw.contains("\r\nBcc:"))
        var d2 = ComposeDraft(account: "me@x.com")
        d2.to = "a@b.co\r\nBcc: evil@x.com"
        XCTAssertThrowsError(try MIMEBuilder.build(draft: d2, from: me, validate: true))
    }
    func testRecipientValidation() {
        var d = ComposeDraft(account: "me@x.com")
        XCTAssertThrowsError(try MIMEBuilder.build(draft: d, from: me, validate: true)) { XCTAssertEqual($0 as? MailError, .noRecipients) }
        d.to = "not an address"
        XCTAssertThrowsError(try MIMEBuilder.build(draft: d, from: me, validate: true)) { XCTAssertEqual($0 as? MailError, .invalidRecipient("not an address")) }
        XCTAssertNoThrow(try MIMEBuilder.build(draft: d, from: me, validate: false)) // half-typed drafts can still save
    }
    func testAttachments() throws {
        var d = ComposeDraft(account: "me@x.com")
        d.to = "a@b.co"; d.subject = "x"; d.body = "see attached"
        let payload = Data((0..<500).map { UInt8($0 % 256) })
        d.attachments = [DraftAttachment(filename: "résumé \"v2\".pdf", mimeType: "application/pdf", data: payload),
                         DraftAttachment(filename: "../../a.txt", mimeType: "bad type\r\nX: y", data: Data("t".utf8))]
        let raw = String(decoding: try MIMEBuilder.build(draft: d, from: me, validate: true, date: fixed, boundary: "BOUND"), as: UTF8.self)
        XCTAssertTrue(raw.contains("Content-Type: multipart/mixed; boundary=\"BOUND\""))
        XCTAssertTrue(raw.contains("filename*=UTF-8''r%C3%A9sum%C3%A9%20%22v2%22.pdf"))
        XCTAssertTrue(raw.contains("filename=\".._.._a.txt\""))
        XCTAssertTrue(raw.contains("Content-Type: application/octet-stream"))
        XCTAssertFalse(raw.contains("X: y"))
        XCTAssertTrue(raw.hasSuffix("--BOUND--\r\n"))
        let section = raw.components(separatedBy: "--BOUND\r\n")[2].components(separatedBy: "\r\n\r\n")[1]
        XCTAssertEqual(Data(base64Encoded: section.filter { !$0.isWhitespace }), payload)
        for line in raw.components(separatedBy: "\r\n") { XCTAssertLessThanOrEqual(line.utf8.count, 998) }
    }
    func testAttachmentSizeLimit() {
        var d = ComposeDraft(account: "me@x.com"); d.to = "a@b.co"
        d.attachments = [DraftAttachment(filename: "big", mimeType: "a/b", data: Data(count: MIMEBuilder.maxAttachmentBytes + 1))]
        XCTAssertThrowsError(try MIMEBuilder.build(draft: d, from: me, validate: true)) { XCTAssertEqual($0 as? MailError, .attachmentsTooLarge) }
    }

    func rendered(from: String, to: [String], cc: [String] = [], replyTo: [String] = [], subject: String = "Topic") -> RenderedMessage {
        let parse = { (s: [String]) in s.compactMap(AddressParser.parseOne) }
        let m = MailMessage(id: "m", threadID: "t", labelIDs: [], from: AddressParser.parseOne(from)!, to: parse(to), cc: parse(cc), replyTo: parse(replyTo),
                            subject: subject, date: fixed, messageIDHeader: "<m@x>", references: "<r@x>", snippet: "", plainBody: "Hello\n> old", htmlBody: nil, attachments: [], inlineImages: [])
        return RenderedMessage(message: m, document: EmailRenderer.render(message: m))
    }
    let account = Account(email: "me@x.com", displayName: "Me", colorIndex: 0, signature: "-- Me")

    func testReplyThreadingAndQuote() {
        let d = ComposeFactory.reply(to: rendered(from: "Ann <a@x.com>", to: ["me@x.com"]), account: account, replyAll: false)
        XCTAssertEqual(d.to, "Ann <a@x.com>")
        XCTAssertEqual(d.subject, "Re: Topic")
        XCTAssertEqual(d.threadID, "t")
        XCTAssertEqual(d.inReplyTo, "<m@x>")
        XCTAssertEqual(d.references, "<r@x> <m@x>")
        XCTAssertTrue(d.body.contains("-- Me"))
        XCTAssertTrue(d.body.contains("a@x.com> wrote:\n> Hello\n"))
        XCTAssertTrue(d.body.contains(">> old"))
        XCTAssertLessThan(d.body.range(of: "-- Me")!.lowerBound, d.body.range(of: "wrote:")!.lowerBound)
    }
    func testReplyDoesNotDoublePrefixAndHonorsReplyTo() {
        let d = ComposeFactory.reply(to: rendered(from: "a@x.com", to: ["me@x.com"], replyTo: ["list@x.com"], subject: "RE: Topic"), account: account, replyAll: false)
        XCTAssertEqual(d.subject, "RE: Topic")
        XCTAssertEqual(d.to, "list@x.com")
    }
    func testReplyAllExcludesMeAndDuplicates() {
        let d = ComposeFactory.reply(to: rendered(from: "Ann <a@x.com>", to: ["ME@x.com", "b@x.com", "a@x.com"], cc: ["c@x.com", "b@x.com"]), account: account, replyAll: true)
        XCTAssertEqual(d.to, "Ann <a@x.com>")
        XCTAssertEqual(d.cc, "b@x.com, c@x.com")
    }
    func testReplyToMyOwnSentMessageGoesToOriginalRecipients() {
        let d = ComposeFactory.reply(to: rendered(from: "me@x.com", to: ["bob@x.com"]), account: account, replyAll: false)
        XCTAssertEqual(d.to, "bob@x.com")
    }
    func testForward() {
        let d = ComposeFactory.forward(rendered(from: "Ann <a@x.com>", to: ["me@x.com"]), account: account)
        XCTAssertEqual(d.subject, "Fwd: Topic")
        XCTAssertEqual(d.to, "")
        XCTAssertNil(d.threadID)
        XCTAssertTrue(d.body.contains("Forwarded message"))
        XCTAssertTrue(d.body.contains("Hello"))
    }
}

/// An in-memory Gmail mailbox for exercising the app logic.
final class FakeGmail: GmailAPI, @unchecked Sendable {
    let email: String
    private let lock = NSLock()
    var threads: [String: (labels: Set<String>, subject: String, history: Int, date: Double)] = [:]
    var order: [String] = []
    var history = 1
    var failNext: Error?
    var metadataCalls = 0
    var sent: [(Data, String?)] = []
    var drafts: [String: Data] = [:]
    var deletedDrafts: [String] = []
    var saveDelay: UInt64 = 0
    var nextPage: String?

    init(_ email: String) { self.email = email }
    func add(_ id: String, labels: Set<String> = ["INBOX", "UNREAD"], subject: String = "S", date: Double = 1000) {
        lock.lock(); defer { lock.unlock() }
        history += 1
        threads[id] = (labels, subject, history, date)
        order.insert(id, at: 0)
    }
    private func takeFailure() throws { lock.lock(); defer { lock.unlock() }; if let e = failNext { failNext = nil; throw e } }
    func profile() async throws -> (email: String, historyID: String) { try takeFailure(); return (email, String(history)) }
    func sendAsIdentity() async throws -> (displayName: String, signatureHTML: String) { ("Name", "<b>Sig</b>") }
    func labels() async throws -> [MailLabel] {
        let unread = threads.values.filter { $0.labels.contains("INBOX") && $0.labels.contains("UNREAD") }.count
        return [MailLabel(id: "INBOX", name: "INBOX", isSystem: true, threadsUnread: unread, threadsTotal: threads.count),
                MailLabel(id: "Label_1", name: "Work", isSystem: false, threadsUnread: 2, threadsTotal: 3),
                MailLabel(id: "CHAT", name: "CHAT", isSystem: true, threadsUnread: 0, threadsTotal: 0)]
    }
    func listThreads(labelIDs: [String], query: String?, pageToken: String?, includeSpamTrash: Bool, maxResults: Int) async throws -> ThreadPage {
        try takeFailure()
        let ids = order.filter { id in
            let l = threads[id]!.labels
            if !labelIDs.allSatisfy(l.contains) { return false }
            if query == "is:unread", !l.contains("UNREAD") { return false }
            return includeSpamTrash || (!l.contains("TRASH") && !l.contains("SPAM"))
        }
        let start = Int(pageToken ?? "0")!
        let slice = Array(ids.dropFirst(start).prefix(maxResults))
        let next = start + maxResults < ids.count ? String(start + maxResults) : nil
        return ThreadPage(threads: slice.map { ThreadRef(id: $0, historyID: String(threads[$0]!.history), snippet: "snip") }, nextPageToken: next)
    }
    func threadMetadata(id: String) async throws -> GmailThread {
        lock.lock(); metadataCalls += 1; lock.unlock()
        return gmail(id)
    }
    private func gmail(_ id: String) -> GmailThread {
        let t = threads[id]!
        let json = #"{"id":"\#(id)","historyId":"\#(t.history)","messages":[{"id":"\#(id)m","threadId":"\#(id)","labelIds":\#(Array(t.labels).sorted().debugDescription),"internalDate":"\#(Int(t.date))","payload":{"mimeType":"text/plain","headers":[{"name":"From","value":"Ann <a@x.com>"},{"name":"To","value":"\#(email)"},{"name":"Subject","value":"\#(t.subject)"},{"name":"Message-ID","value":"<\#(id)@x>"}],"body":{"data":"\#(b64("body of \(id)"))"}}}]}"#
        return try! JSONDecoder().decode(GmailThread.self, from: Data(json.utf8))
    }
    func threadFull(id: String) async throws -> GmailThread { try takeFailure(); return gmail(id) }
    func modifyThread(id: String, add: [String], remove: [String]) async throws {
        try takeFailure()
        lock.lock(); defer { lock.unlock() }
        threads[id]!.labels.formUnion(add); threads[id]!.labels.subtract(remove)
        history += 1; threads[id]!.history = history
    }
    func trashThread(id: String) async throws { try await modifyThread(id: id, add: ["TRASH"], remove: ["INBOX"]) }
    func untrashThread(id: String) async throws { try await modifyThread(id: id, add: ["INBOX"], remove: ["TRASH"]) }
    func attachment(messageID: String, attachmentID: String) async throws -> Data { Data("att".utf8) }
    func send(raw: Data, threadID: String?) async throws { try takeFailure(); lock.lock(); sent.append((raw, threadID)); lock.unlock() }
    func saveDraft(id: String?, raw: Data, threadID: String?) async throws -> String {
        if saveDelay > 0 { try await Task.sleep(nanoseconds: saveDelay) }
        lock.lock(); defer { lock.unlock() }
        let key = id ?? "draft\(drafts.count + 1)"
        drafts[key] = raw
        return key
    }
    func deleteDraft(id: String) async throws { lock.lock(); deletedDrafts.append(id); lock.unlock() }
    func draftID(forMessage messageID: String) async throws -> String? { "draftX" }
}

@MainActor
final class StoreTests: XCTestCase {
    var dir: URL!
    var work: FakeGmail!
    var home: FakeGmail!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        work = FakeGmail("work@x.com")
        home = FakeGmail("home@x.com")
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    func makeStore() -> MailStore {
        let apis: [String: FakeGmail] = ["work@x.com": work, "home@x.com": home]
        let store = MailStore(secrets: MemorySecrets(), disk: DiskStore(root: dir), transport: ScriptedTransport(), apiOverride: { apis[$0]! })
        store.backgroundSyncEnabled = false // Each test drives syncing itself.
        return store
    }
    func signedInStore() async -> MailStore {
        let s = makeStore()
        await s.finishAdding(email: "work@x.com", api: work)
        await s.finishAdding(email: "home@x.com", api: home)
        return s
    }

    func testTwoAccountsSideBySideInAllInboxes() async {
        work.add("w1", date: 1000); home.add("h1", date: 2000); work.add("w2", date: 3000)
        work.add("w3", labels: ["SENT"], date: 4000)
        let s = await signedInStore()
        await s.selectMailbox(.allInboxes)
        XCTAssertEqual(s.threads.map(\.threadID), ["w2", "h1", "w1"])
        XCTAssertEqual(s.threads.map(\.account), ["work@x.com", "home@x.com", "work@x.com"])
        XCTAssertEqual(s.unreadInboxTotal, 3)
        await s.selectMailbox(.label(account: "home@x.com", id: "INBOX"))
        XCTAssertEqual(s.threads.map(\.threadID), ["h1"])
    }
    func testSidebarLayout() async {
        let s = await signedInStore()
        let titles = s.sidebarEntries(for: "work@x.com").map(\.title)
        XCTAssertEqual(titles, ["Inbox", "Starred", "Important", "Sent", "Drafts", "All Mail", "Spam", "Trash", "Work"])
        XCTAssertEqual(s.sidebarEntries(for: "work@x.com").last?.count, 2)
    }
    func testAccountsPersistAcrossRelaunchAndCachedListShowsInstantly() async {
        work.add("w1", subject: "Saved")
        let s = await signedInStore()
        await s.selectMailbox(.label(account: "work@x.com", id: "INBOX"))
        let relaunched = makeStore()
        XCTAssertEqual(relaunched.accounts.map(\.email), ["work@x.com", "home@x.com"])
        work.failNext = URLError(.notConnectedToInternet)
        relaunched.mailbox = .label(account: "work@x.com", id: "INBOX")
        relaunched.start()
        XCTAssertEqual(relaunched.threads.map(\.subject), ["Saved"])
    }
    func testOnlyChangedThreadsAreRefetched() async {
        for i in 0..<10 { work.add("t\(i)") }
        let s = await signedInStore()
        await s.selectMailbox(.label(account: "work@x.com", id: "INBOX"))
        let calls = work.metadataCalls
        await s.reload()
        XCTAssertEqual(work.metadataCalls, calls)
        work.add("new")
        await s.reload()
        XCTAssertEqual(work.metadataCalls, calls + 1)
    }
    func testPaginationAcrossAccounts() async {
        for i in 0..<45 { work.add("w\(i)", date: Double(1000 + i)) }
        home.add("h", date: 1)
        let s = await signedInStore()
        await s.selectMailbox(.allInboxes)
        XCTAssertEqual(s.threads.count, 31)
        XCTAssertTrue(s.canLoadMore)
        await s.loadMore()
        XCTAssertEqual(s.threads.count, 46)
        XCTAssertFalse(s.canLoadMore)
        XCTAssertEqual(Set(s.threads.map(\.id)).count, 46)
    }
    func testOpeningThreadRendersAndMarksRead() async {
        work.add("w1")
        let s = await signedInStore()
        await s.selectMailbox(.label(account: "work@x.com", id: "INBOX"))
        s.selection = [s.threads[0].id]
        await s.openSelected()
        XCTAssertEqual(s.detail?.messages.count, 1)
        XCTAssertEqual(s.detail?.messages[0].document.plainText, "body of w1")
        XCTAssertFalse(s.threads[0].isUnread)
        XCTAssertFalse(work.threads["w1"]!.labels.contains("UNREAD"))
    }
    func testArchiveMovesToNextThreadAndUndoRestores() async {
        work.add("a", date: 1); work.add("b", date: 2); work.add("c", date: 3)
        let s = await signedInStore()
        await s.selectMailbox(.label(account: "work@x.com", id: "INBOX"))
        let b = s.threads.first { $0.threadID == "b" }!
        s.selection = [b.id]
        await s.perform(.archive, on: [b])
        XCTAssertEqual(s.threads.map(\.threadID), ["c", "a"])
        XCTAssertEqual(s.selectedThreads.map(\.threadID), ["a"])
        XCTAssertFalse(work.threads["b"]!.labels.contains("INBOX"))
        XCTAssertEqual(s.undo?.title, "Conversation archived")
        await s.performUndo()
        XCTAssertEqual(s.threads.map(\.threadID), ["c", "b", "a"])
        XCTAssertNil(s.undo)
    }
    func testFailedActionPutsEverythingBack() async {
        work.add("a")
        let s = await signedInStore()
        await s.selectMailbox(.label(account: "work@x.com", id: "INBOX"))
        s.selection = [s.threads[0].id]
        work.failNext = MailError.api(status: 500, message: "boom")
        await s.perform(.trash, on: s.threads)
        XCTAssertEqual(s.threads.map(\.threadID), ["a"])
        XCTAssertEqual(s.selection.count, 1)
        XCTAssertNotNil(s.banner)
        XCTAssertNil(s.undo)
    }
    func testActionsAcrossAccountsGoToTheRightAccount() async {
        work.add("w"); home.add("h")
        let s = await signedInStore()
        await s.selectMailbox(.allInboxes)
        await s.perform(.star, on: s.threads)
        XCTAssertTrue(work.threads["w"]!.labels.contains("STARRED"))
        XCTAssertTrue(home.threads["h"]!.labels.contains("STARRED"))
        XCTAssertEqual(s.threads.count, 2) // starring keeps them in view
        await s.perform(.spam, on: s.threads)
        XCTAssertEqual(s.threads.count, 0)
    }
    func testLabelTransitions() async {
        XCTAssertEqual(MailStore.applied(.trash, to: ["INBOX", "X"]), ["TRASH", "X"])
        XCTAssertEqual(MailStore.applied(.untrash, to: ["TRASH"]), ["INBOX"])
        XCTAssertEqual(MailStore.applied(.notSpam, to: ["SPAM"]), ["INBOX"])
        XCTAssertEqual(MailStore.applied(.markUnread, to: []), ["UNREAD"])
        XCTAssertEqual(MailStore.applied(.removeLabel("X"), to: ["X"]), [])
    }
    func testTrashViewAskedForWithSpamTrashFlag() async {
        work.add("t", labels: ["TRASH"])
        let s = await signedInStore()
        await s.selectMailbox(.label(account: "work@x.com", id: "TRASH"))
        XCTAssertEqual(s.threads.map(\.threadID), ["t"])
    }
    func testSearchClearsWithMailboxChange() async {
        work.add("a")
        let s = await signedInStore()
        await s.selectMailbox(.label(account: "work@x.com", id: "INBOX"))
        s.searchText = "  is:unread "
        await s.applySearch()
        XCTAssertEqual(s.activeSearch, "is:unread")
        XCTAssertEqual(s.title(of: s.mailbox), "Search")
        await s.selectMailbox(.allMail(account: "work@x.com"))
        XCTAssertEqual(s.activeSearch, "")
    }
    func testSyncNotifiesOnlyForMailArrivingAfterLaunch() async {
        work.add("old")
        let s = await signedInStore()
        await s.selectMailbox(.label(account: "work@x.com", id: "INBOX"))
        var notified = [String]()
        s.onNewMail = { notified += $0.map(\.threadID) }
        await s.syncAll()
        XCTAssertEqual(notified, [])
        await s.syncAll()
        XCTAssertEqual(notified, [], "nothing changed")
        work.add("fresh", subject: "New one", date: 9000)
        await s.syncAll()
        XCTAssertEqual(notified, ["fresh"])
        XCTAssertEqual(s.threads.first?.subject, "New one")
    }
    func testExpiredAccountIsFlaggedWithoutBlockingTheOther() async {
        work.add("w"); home.add("h")
        let s = await signedInStore()
        work.failNext = MailError.needsSignIn("work@x.com")
        await s.selectMailbox(.allInboxes)
        XCTAssertEqual(s.threads.map(\.threadID), ["h"])
        XCTAssertTrue(s.account("work@x.com")!.needsSignIn)
        XCTAssertNil(s.banner)
    }
    func testOfflineSyncStaysQuietAndKeepsList() async {
        work.add("w")
        let s = await signedInStore()
        await s.selectMailbox(.label(account: "work@x.com", id: "INBOX"))
        work.failNext = URLError(.notConnectedToInternet)
        await s.syncAll()
        XCTAssertTrue(s.isOffline)
        XCTAssertNil(s.banner)
        XCTAssertEqual(s.threads.count, 1)
    }
    func testRemoveAccount() async {
        work.add("w"); home.add("h")
        let s = await signedInStore()
        await s.selectMailbox(.label(account: "work@x.com", id: "INBOX"))
        await s.removeAccount("work@x.com")
        XCTAssertEqual(s.accounts.map(\.email), ["home@x.com"])
        XCTAssertEqual(s.mailbox, .label(account: "home@x.com", id: "INBOX"))
        XCTAssertEqual(s.threads.map(\.threadID), ["h"])
        XCTAssertEqual(makeStore().accounts.map(\.email), ["home@x.com"])
    }
    func testSignatureLoadedAsPlainText() async {
        let s = await signedInStore()
        XCTAssertEqual(s.account("work@x.com")?.signature, "Sig")
        XCTAssertEqual(s.account("work@x.com")?.displayName, "Name")
    }
    func testReplySendsFromThatAccountInThatThread() async throws {
        work.add("w")
        let s = await signedInStore()
        await s.selectMailbox(.label(account: "work@x.com", id: "INBOX"))
        s.selection = [s.threads[0].id]
        await s.openSelected()
        let id = s.reply(s.detail!.replyTarget!, all: false, account: "work@x.com")!
        let session = s.composeSessions[id]!
        session.draft.body = "Thanks!\n" + session.draft.body
        let sent = await session.send()
        XCTAssertTrue(sent)
        XCTAssertEqual(work.sent.count, 1)
        XCTAssertEqual(work.sent[0].1, "w")
        let raw = String(decoding: work.sent[0].0, as: UTF8.self)
        XCTAssertTrue(raw.contains("In-Reply-To: <w@x>"))
        XCTAssertTrue(raw.contains("From: \"Name\" <work@x.com>"))
        XCTAssertEqual(home.sent.count, 0)
    }
    func testAutosaveThenSendRemovesDraftAndNeverOrphansOne() async throws {
        let s = await signedInStore()
        let composeID = s.beginCompose(ComposeDraft(account: "work@x.com"))
        let session = s.composeSessions[composeID]!
        session.autosaveDelay = 1_000_000
        session.draft.to = "a@b.co"; session.draft.body = "hello"
        await session.saveNow()
        XCTAssertEqual(session.draft.gmailDraftID, "draft1")
        session.draft.body = "hello again"
        await session.saveNow()
        XCTAssertEqual(work.drafts.count, 1, "second save updates, not duplicates")
        // Change text, start a slow save, and send while it is still running.
        work.saveDelay = 50_000_000
        session.draft.body = "final"
        let saving = Task { await session.saveNow() }
        await Task.yield()
        let sent = await session.send()
        await saving.value
        XCTAssertTrue(sent)
        XCTAssertEqual(work.sent.count, 1)
        XCTAssertEqual(work.deletedDrafts, ["draft1"])
        XCTAssertEqual(work.drafts.count, 1)
    }
    func testFailedSendKeepsDraftAndCanRetry() async {
        let s = await signedInStore()
        let composeID = s.beginCompose(ComposeDraft(account: "work@x.com"))
        let session = s.composeSessions[composeID]!
        session.draft.to = "a@b.co"
        work.failNext = URLError(.timedOut)
        let first = await session.send()
        XCTAssertFalse(first)
        XCTAssertNotNil(session.errorText)
        let second = await session.send()
        XCTAssertTrue(second)
        XCTAssertEqual(work.sent.count, 1)
    }
    func testInvalidRecipientNeverReachesGmail() async {
        let s = await signedInStore()
        let composeID = s.beginCompose(ComposeDraft(account: "work@x.com"))
        let session = s.composeSessions[composeID]!
        session.draft.to = "oops"
        let result = await session.send()
        XCTAssertFalse(result)
        XCTAssertEqual(work.sent.count, 0)
        XCTAssertTrue(session.errorText!.contains("oops"))
    }
    func testBlankComposeSavesNothingAndDiscardDeletes() async {
        let s = await signedInStore()
        let composeID = s.beginCompose(ComposeDraft(account: "work@x.com"))
        let session = s.composeSessions[composeID]!
        await session.saveNow()
        XCTAssertEqual(work.drafts.count, 0)
        session.draft.subject = "x"
        await session.saveNow()
        await session.discard()
        XCTAssertEqual(work.deletedDrafts, ["draft1"])
    }
    func testSwitchingFromAccountMovesTheDraft() async {
        let s = await signedInStore()
        let composeID = s.beginCompose(ComposeDraft(account: "work@x.com"))
        let session = s.composeSessions[composeID]!
        session.draft.subject = "x"
        await session.saveNow()
        await session.changeAccount(to: "home@x.com")
        XCTAssertEqual(work.deletedDrafts, ["draft1"])
        await session.saveNow()
        XCTAssertEqual(home.drafts.count, 1)
    }
    func testRelaunchRefreshesCachedListFromGmail() async throws {
        work.add("w1", subject: "Saved")
        let s = await signedInStore()
        await s.selectMailbox(.label(account: "work@x.com", id: "INBOX"))
        work.add("w2", subject: "Arrived while closed", date: 5000)
        let relaunched = makeStore()
        relaunched.mailbox = .label(account: "work@x.com", id: "INBOX")
        relaunched.backgroundSyncEnabled = true
        relaunched.start()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(relaunched.threads.first?.subject, "Arrived while closed")
    }
    func testForwardBringsAttachments() async {
        let s = await signedInStore()
        let info = AttachmentInfo(messageID: "m", attachmentID: "a", filename: "f.pdf", mimeType: "application/pdf", size: 3, contentID: nil, inlineData: nil)
        let m = MailMessage(id: "m", threadID: "t", labelIDs: [], from: .init(name: "", email: "a@x.com"), to: [], cc: [], replyTo: [], subject: "S", date: Date(), messageIDHeader: "", references: "", snippet: "", plainBody: "b", htmlBody: nil, attachments: [info], inlineImages: [])
        let id = await s.forward(RenderedMessage(message: m, document: EmailRenderer.render(message: m)), account: "work@x.com")
        XCTAssertEqual(s.composeSessions[id!]!.draft.attachments.map(\.data), [Data("att".utf8)])
    }
    func testCacheFilesArePrivate() async throws {
        work.add("w")
        let s = await signedInStore()
        await s.selectMailbox(.label(account: "work@x.com", id: "INBOX"))
        for file in try FileManager.default.contentsOfDirectory(atPath: dir.path) {
            let perms = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(file).path)[.posixPermissions] as! NSNumber
            XCTAssertEqual(perms.intValue, 0o600, file)
        }
    }
}
