import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

struct HTTPResult { var status: Int; var data: Data; var retryAfter: Double? }

protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResult
}

struct URLSessionTransport: HTTPTransport {
    let session: URLSession
    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 600
        session = URLSession(configuration: config)
    }
    func send(_ request: URLRequest) async throws -> HTTPResult {
        try await withCheckedThrowingContinuation { continuation in
            session.dataTask(with: request) { data, response, error in
                if let error { continuation.resume(throwing: error); return }
                guard let http = response as? HTTPURLResponse else {
                    continuation.resume(throwing: MailError.invalidResponse); return
                }
                let retry = (http.allHeaderFields["Retry-After"] as? String).flatMap(Double.init)
                continuation.resume(returning: HTTPResult(status: http.statusCode, data: data ?? Data(), retryAfter: retry))
            }.resume()
        }
    }
}

struct OAuthClientConfig: Codable, Equatable {
    var clientID: String
    var clientSecret: String

    /// Reads the JSON file downloaded from Google Cloud for a Desktop app client.
    static func parse(json: Data) throws -> OAuthClientConfig {
        guard let root = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] else {
            throw MailError.invalidClientFile("That file isn't a Google client JSON file.")
        }
        if root["web"] != nil {
            throw MailError.invalidClientFile("This is a Web client. In Google Cloud, create a client with the type “Desktop app”.")
        }
        guard let installed = root["installed"] as? [String: Any],
              let id = installed["client_id"] as? String, !id.isEmpty else {
            throw MailError.invalidClientFile("That file doesn't contain a Desktop app client.")
        }
        return OAuthClientConfig(clientID: id, clientSecret: installed["client_secret"] as? String ?? "")
    }
}

struct TokenSet: Codable, Equatable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
}

enum PKCE {
    static func randomString(bytes: Int = 48) -> String {
        var generator = SystemRandomNumberGenerator()
        let data = Data((0..<bytes).map { _ in UInt8.random(in: 0...255, using: &generator) })
        return base64URL(data)
    }

    static func challenge(for verifier: String) -> String { base64URL(sha256(Data(verifier.utf8))) }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func sha256(_ data: Data) -> Data {
        #if canImport(CryptoKit)
        return Data(SHA256.hash(data: data))
        #else
        return softwareSHA256(data)
        #endif
    }

    /// Only used where CryptoKit doesn't exist (the Linux unit-test build).
    static func softwareSHA256(_ data: Data) -> Data {
        let k: [UInt32] = [
            0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
            0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
            0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
            0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
            0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
            0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
            0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
            0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2]
        var h: [UInt32] = [0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19]
        var message = [UInt8](data)
        let bitLength = UInt64(message.count) * 8
        message.append(0x80)
        while message.count % 64 != 56 { message.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) { message.append(UInt8((bitLength >> UInt64(shift)) & 0xff)) }
        func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
        for chunk in stride(from: 0, to: message.count, by: 64) {
            var w = [UInt32](repeating: 0, count: 64)
            for i in 0..<16 {
                let j = chunk + i * 4
                w[i] = UInt32(message[j]) << 24 | UInt32(message[j+1]) << 16 | UInt32(message[j+2]) << 8 | UInt32(message[j+3])
            }
            for i in 16..<64 {
                let s0 = rotr(w[i-15], 7) ^ rotr(w[i-15], 18) ^ (w[i-15] >> 3)
                let s1 = rotr(w[i-2], 17) ^ rotr(w[i-2], 19) ^ (w[i-2] >> 10)
                w[i] = w[i-16] &+ s0 &+ w[i-7] &+ s1
            }
            var v = h
            for i in 0..<64 {
                let s1 = rotr(v[4], 6) ^ rotr(v[4], 11) ^ rotr(v[4], 25)
                let ch = (v[4] & v[5]) ^ (~v[4] & v[6])
                let t1 = v[7] &+ s1 &+ ch &+ k[i] &+ w[i]
                let s0 = rotr(v[0], 2) ^ rotr(v[0], 13) ^ rotr(v[0], 22)
                let maj = (v[0] & v[1]) ^ (v[0] & v[2]) ^ (v[1] & v[2])
                let t2 = s0 &+ maj
                v = [t1 &+ t2, v[0], v[1], v[2], v[3] &+ t1, v[4], v[5], v[6]]
            }
            for i in 0..<8 { h[i] = h[i] &+ v[i] }
        }
        var out = Data()
        for value in h { for shift in stride(from: 24, through: 0, by: -8) { out.append(UInt8((value >> UInt32(shift)) & 0xff)) } }
        return out
    }
}

enum GoogleOAuth {
    static let scope = "https://www.googleapis.com/auth/gmail.modify"
    static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
    static let revokeURL = URL(string: "https://oauth2.googleapis.com/revoke")!

    static func authorizationURL(client: OAuthClientConfig, redirectURI: String, state: String, challenge: String) -> URL {
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: client.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "access_type", value: "offline"),
            // Always show the account chooser so a second account can be added.
            URLQueryItem(name: "prompt", value: "select_account consent"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        return components.url!
    }

    static func formRequest(url: URL, fields: [(String, String)]) -> URLRequest {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let body = fields.map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)
        return request
    }

    struct TokenResponse: Decodable {
        var access_token: String
        var refresh_token: String?
        var expires_in: Double
    }
    struct TokenError: Decodable { var error: String; var error_description: String? }

    static func exchange(code: String, verifier: String, redirectURI: String, client: OAuthClientConfig,
                         transport: HTTPTransport, now: Date = Date()) async throws -> TokenSet {
        var fields = [("client_id", client.clientID), ("code", code), ("code_verifier", verifier),
                      ("grant_type", "authorization_code"), ("redirect_uri", redirectURI)]
        if !client.clientSecret.isEmpty { fields.append(("client_secret", client.clientSecret)) }
        let response = try await tokenRequest(fields, transport: transport)
        guard let refresh = response.refresh_token else {
            throw MailError.api(status: 400, message: "Google did not return a refresh token.")
        }
        return TokenSet(accessToken: response.access_token, refreshToken: refresh,
                        expiresAt: now.addingTimeInterval(response.expires_in))
    }

    static func refresh(_ tokens: TokenSet, email: String, client: OAuthClientConfig,
                        transport: HTTPTransport, now: Date = Date()) async throws -> TokenSet {
        var fields = [("client_id", client.clientID), ("grant_type", "refresh_token"),
                      ("refresh_token", tokens.refreshToken)]
        if !client.clientSecret.isEmpty { fields.append(("client_secret", client.clientSecret)) }
        do {
            let response = try await tokenRequest(fields, transport: transport)
            return TokenSet(accessToken: response.access_token,
                            refreshToken: response.refresh_token ?? tokens.refreshToken,
                            expiresAt: now.addingTimeInterval(response.expires_in))
        } catch MailError.api(_, let message) where message.contains("invalid_grant") {
            throw MailError.needsSignIn(email)
        }
    }

    private static func tokenRequest(_ fields: [(String, String)], transport: HTTPTransport) async throws -> TokenResponse {
        let result = try await transport.send(formRequest(url: tokenURL, fields: fields))
        guard result.status == 200 else {
            let detail = try? JSONDecoder().decode(TokenError.self, from: result.data)
            let message = [detail?.error, detail?.error_description].compactMap { $0 }.joined(separator: ": ")
            throw MailError.api(status: result.status, message: message.isEmpty ? "Sign-in failed." : message)
        }
        guard let decoded = try? JSONDecoder().decode(TokenResponse.self, from: result.data) else {
            throw MailError.invalidResponse
        }
        return decoded
    }

    static func revoke(token: String, transport: HTTPTransport) async {
        _ = try? await transport.send(formRequest(url: revokeURL, fields: [("token", token)]))
    }
}

protocol SecretStore: Sendable {
    func read(_ key: String) -> Data?
    func write(_ key: String, _ value: Data) throws
    func delete(_ key: String)
}

/// Hands out a fresh access token per account, sharing one refresh among concurrent callers.
actor AuthManager {
    private let client: OAuthClientConfig
    private let secrets: SecretStore
    private let transport: HTTPTransport
    private var tokens: [String: TokenSet] = [:]
    private var refreshing: [String: Task<TokenSet, Error>] = [:]

    init(client: OAuthClientConfig, secrets: SecretStore, transport: HTTPTransport) {
        self.client = client
        self.secrets = secrets
        self.transport = transport
    }

    private func key(_ email: String) -> String { "tokens." + email }

    func save(_ set: TokenSet, for email: String) throws {
        tokens[email] = set
        try secrets.write(key(email), JSONEncoder().encode(set))
    }

    private func stored(_ email: String) -> TokenSet? {
        if let cached = tokens[email] { return cached }
        guard let data = secrets.read(key(email)),
              let set = try? JSONDecoder().decode(TokenSet.self, from: data) else { return nil }
        tokens[email] = set
        return set
    }

    func accessToken(for email: String, forceRefresh: Bool = false) async throws -> String {
        guard let current = stored(email) else { throw MailError.needsSignIn(email) }
        if !forceRefresh && current.expiresAt.timeIntervalSinceNow > 60 { return current.accessToken }
        if let running = refreshing[email] { return try await running.value.accessToken }
        let client = self.client, transport = self.transport
        let task = Task { try await GoogleOAuth.refresh(current, email: email, client: client, transport: transport) }
        refreshing[email] = task
        defer { refreshing[email] = nil }
        let updated = try await task.value
        try save(updated, for: email)
        return updated.accessToken
    }

    func remove(_ email: String) async {
        if let set = stored(email) { await GoogleOAuth.revoke(token: set.refreshToken, transport: transport) }
        tokens[email] = nil
        secrets.delete(key(email))
    }
}

/// A tiny web listener on 127.0.0.1 that catches Google's redirect after sign-in.
final class LoopbackServer: @unchecked Sendable {
    let port: UInt16
    private let socketFD: Int32
    private let lock = NSLock()
    private var cancelled = false

    var redirectURI: String { "http://127.0.0.1:\(port)" }

    init() throws {
        signal(SIGPIPE, SIG_IGN)
        #if canImport(Darwin)
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #else
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard fd >= 0 else { throw MailError.api(status: 0, message: "Could not open a local socket.") }
        var address = sockaddr_in()
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        guard bound == 0, listen(fd, 8) == 0 else {
            close(fd)
            throw MailError.api(status: 0, message: "Could not start the local sign-in listener.")
        }
        var actual = sockaddr_in()
        var actualSize = size
        _ = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &actualSize) }
        }
        socketFD = fd
        port = UInt16(bigEndian: actual.sin_port)
    }

    deinit { close(socketFD) }

    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    func waitForCode(state: String, timeout: TimeInterval) async throws -> String {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result { try self.acceptLoop(state: state, timeout: timeout) })
                }
            }
        } onCancel: { self.cancel() }
    }

    private func acceptLoop(state: String, timeout: TimeInterval) throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if isCancelled { throw MailError.signInCancelled }
            if Date() >= deadline { throw MailError.signInTimedOut }
            var descriptor = pollfd(fd: socketFD, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, 250) > 0 else { continue }
            let connection = accept(socketFD, nil, nil)
            guard connection >= 0 else { continue }
            defer { close(connection) }
            let request = readRequest(connection)
            switch Self.parseCallback(request: request, expectedState: state) {
            case .ignored:
                respond(connection, status: "404 Not Found", message: "Not found.")
            case .denied:
                respond(connection, status: "200 OK", message: "Sign-in was cancelled. You can close this tab.")
                throw MailError.signInDenied
            case .code(let code):
                respond(connection, status: "200 OK", message: "You're signed in. You can close this tab and go back to MailDock.")
                return code
            }
        }
    }

    enum Callback: Equatable { case ignored, denied, code(String) }

    static func parseCallback(request: String, expectedState: String) -> Callback {
        guard let line = request.split(separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: false).first else { return .ignored }
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET",
              let components = URLComponents(string: "http://127.0.0.1" + parts[1]) else { return .ignored }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard value("state") == expectedState else { return .ignored }
        if value("error") != nil { return .denied }
        guard let code = value("code"), !code.isEmpty else { return .ignored }
        return .code(code)
    }

    private func readRequest(_ connection: Int32) -> String {
        var collected = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while collected.count < 16_384 {
            var descriptor = pollfd(fd: connection, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, 2000) > 0 else { break }
            let count = read(connection, &buffer, buffer.count)
            guard count > 0 else { break }
            collected.append(contentsOf: buffer[0..<count])
            if String(decoding: collected, as: UTF8.self).contains("\r\n\r\n") { break }
        }
        return String(decoding: collected, as: UTF8.self)
    }

    private func respond(_ connection: Int32, status: String, message: String) {
        let html = "<!doctype html><meta charset=utf-8><title>MailDock</title><body style=\"font:16px -apple-system,sans-serif;margin:4em;text-align:center\">\(message)</body>"
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
        let bytes = Array(response.utf8)
        _ = bytes.withUnsafeBytes { write(connection, $0.baseAddress, $0.count) }
    }
}
