import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Combine)
import Combine
#else
// Lets the app logic compile for its unit tests on systems without Combine.
protocol ObservableObject: AnyObject {}
@propertyWrapper struct Published<Value> {
    var wrappedValue: Value
    init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
}
#endif

/// Saves small JSON files in Application Support, readable only by this user.
struct DiskStore: Sendable {
    let root: URL

    init(root: URL) {
        self.root = root
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
    }

    private func url(_ name: String) -> URL { root.appendingPathComponent(name + ".json") }

    func load<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        guard let data = try? Data(contentsOf: url(name)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    func save<T: Encodable>(_ value: T, _ name: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url(name), options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url(name).path)
    }

    func delete(_ name: String) { try? FileManager.default.removeItem(at: url(name)) }
}

struct AccountCache: Codable {
    var summaries: [String: ThreadSummary] = [:]
    var lists: [String: [String]] = [:]

    mutating func trim(keeping limit: Int = 1500) {
        guard summaries.count > limit else { return }
        let listed = Set(lists.values.flatMap { $0 })
        let extras = summaries.values.filter { !listed.contains($0.threadID) }.sorted { $0.date > $1.date }
        let room = max(0, limit - listed.count)
        for item in extras.dropFirst(room) { summaries[item.threadID] = nil }
    }
}

struct SidebarEntry: Identifiable, Hashable {
    var title: String
    var icon: String
    var mailbox: Mailbox
    var count: Int
    var id: Mailbox { mailbox }
}

@MainActor
final class MailStore: ObservableObject {
    @Published var clientConfig: OAuthClientConfig?
    @Published var accounts: [Account] = []
    @Published var labels: [String: [MailLabel]] = [:]
    @Published var mailbox: Mailbox?
    @Published var threads: [ThreadSummary] = []
    @Published var selection: Set<String> = []
    @Published var detail: ThreadDetail?
    @Published var isLoadingList = false
    @Published var isLoadingDetail = false
    @Published var isSigningIn = false
    @Published var searchText = ""
    @Published var activeSearch = ""
    @Published var category: InboxCategory = .all
    @Published var banner: String?
    @Published var undo: (title: String, action: ThreadAction, targets: [ThreadSummary])?
    @Published var isOffline = false
    /// The conversation shown in place of the list, as in Gmail.
    @Published var openThread: ThreadSummary?
    /// Compose windows in the order they were opened.
    @Published var composeOrder: [UUID] = []
    @Published var maximizedCompose: UUID?

    var backgroundSyncEnabled = true
    var onNewMail: (([ThreadSummary]) -> Void)?
    var openURL: ((URL) -> Void)?

    private let secrets: SecretStore
    private let disk: DiskStore
    private let transport: HTTPTransport
    private let apiOverride: ((String) -> GmailAPI)?
    private var auth: AuthManager?
    private var clients: [String: GmailAPI] = [:]
    private var caches: [String: AccountCache] = [:]
    private var pageTokens: [String: String] = [:]
    private var listGeneration = 0
    private var detailGeneration = 0
    private var historyIDs: [String: String] = [:]
    private var seenInbox: [String: Set<String>] = [:]
    private var syncTask: Task<Void, Never>?
    private var sawNetworkFailure = false
    private var signInServer: LoopbackServer?
    private(set) var composeSessions: [UUID: ComposeSession] = [:]

    private static let pageSize = 30
    private static let clientKey = "oauth-client"

    init(secrets: SecretStore, disk: DiskStore, transport: HTTPTransport = URLSessionTransport(),
         apiOverride: ((String) -> GmailAPI)? = nil) {
        self.secrets = secrets
        self.disk = disk
        self.transport = transport
        self.apiOverride = apiOverride
        if let data = secrets.read(Self.clientKey), let config = try? JSONDecoder().decode(OAuthClientConfig.self, from: data) {
            applyClient(config)
        }
        accounts = disk.load([Account].self, "accounts") ?? []
        for account in accounts { caches[account.email] = disk.load(AccountCache.self, cacheName(account.email)) ?? AccountCache() }
        labels = disk.load([String: [MailLabel]].self, "labels") ?? [:]
    }

    private func cacheName(_ email: String) -> String {
        "cache-" + PKCE.base64URL(Data(email.lowercased().utf8))
    }

    private func applyClient(_ config: OAuthClientConfig) {
        clientConfig = config
        auth = AuthManager(client: config, secrets: secrets, transport: transport)
        clients = [:]
    }

    func setClient(_ config: OAuthClientConfig) throws {
        try secrets.write(Self.clientKey, JSONEncoder().encode(config))
        applyClient(config)
    }

    func api(for email: String) -> GmailAPI? {
        if let apiOverride { return apiOverride(email) }
        if let existing = clients[email] { return existing }
        guard let auth else { return nil }
        let client = GmailClient(transport: transport) { force in
            try await auth.accessToken(for: email, forceRefresh: force)
        }
        clients[email] = client
        return client
    }

    func account(_ email: String) -> Account? { accounts.first { $0.email == email } }

    // MARK: Start-up and background checks

    func start() {
        if mailbox == nil { mailbox = defaultMailbox() }
        showCachedList()
        guard syncTask == nil, backgroundSyncEnabled else { return }
        syncTask = Task { [weak self] in
            await self?.reload()
            while !Task.isCancelled {
                guard let self else { return }
                await self.syncAll()
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
    }

    private func defaultMailbox() -> Mailbox? {
        if accounts.count > 1 { return .allInboxes }
        return accounts.first.map { .label(account: $0.email, id: SystemLabel.inbox) }
    }

    /// Checks each account cheaply and refreshes only those where something changed.
    func syncAll() async {
        sawNetworkFailure = false
        for account in accounts where !account.needsSignIn { await sync(account.email) }
        isOffline = sawNetworkFailure
    }

    private func sync(_ email: String) async {
        guard let api = api(for: email) else { return }
        do {
            let profile = try await api.profile()
            let previous = historyIDs[email]
            guard previous != profile.historyID else { return }
            historyIDs[email] = profile.historyID
            await refreshLabels(email)
            await checkForNewMail(email, api: api)
            if previous != nil, scopeAccounts().contains(email) { await refreshFirstPage(email, api: api) }
        } catch {
            handle(error, account: email, quietWhenOffline: true)
        }
    }

    private func checkForNewMail(_ email: String, api: GmailAPI) async {
        do {
            let page = try await api.listThreads(labelIDs: [SystemLabel.inbox], query: "is:unread", pageToken: nil, includeSpamTrash: false, maxResults: 15)
            let ids = Set(page.threads.map(\.id))
            defer { seenInbox[email, default: []].formUnion(ids) }
            guard let seen = seenInbox[email] else { return } // First check after launch only records what's there.
            let fresh = page.threads.filter { !seen.contains($0.id) }
            guard !fresh.isEmpty else { return }
            let summaries = try await hydrate(fresh, email: email, api: api)
            onNewMail?(summaries)
        } catch {
            handle(error, account: email, quietWhenOffline: true)
        }
    }

    func refreshLabels(_ email: String) async {
        guard let api = api(for: email) else { return }
        do {
            labels[email] = try await api.labels()
            disk.save(labels, "labels")
        } catch {
            handle(error, account: email, quietWhenOffline: true)
        }
    }

    private func handle(_ error: Error, account email: String?, quietWhenOffline: Bool = false) {
        if case MailError.needsSignIn(let who) = error {
            setNeedsSignIn(who, true)
            return
        }
        if let urlError = error as? URLError, urlError.code != .cancelled {
            sawNetworkFailure = true
            isOffline = true
            if quietWhenOffline { return }
        }
        if error is CancellationError { return }
        if let urlError = error as? URLError, urlError.code == .cancelled { return }
        banner = error.localizedDescription
    }

    private func setNeedsSignIn(_ email: String, _ value: Bool) {
        guard let index = accounts.firstIndex(where: { $0.email == email }), accounts[index].needsSignIn != value else { return }
        accounts[index].needsSignIn = value
        disk.save(accounts, "accounts")
    }

    // MARK: Accounts

    func addAccount() async {
        guard let config = clientConfig, let auth else { banner = MailError.notConfigured.errorDescription; return }
        isSigningIn = true
        defer { isSigningIn = false; signInServer = nil }
        do {
            let server = try LoopbackServer()
            signInServer = server
            let verifier = PKCE.randomString()
            let state = PKCE.randomString(bytes: 24)
            let url = GoogleOAuth.authorizationURL(client: config, redirectURI: server.redirectURI, state: state,
                                                   challenge: PKCE.challenge(for: verifier))
            openURL?(url)
            let code = try await server.waitForCode(state: state, timeout: 300)
            let tokens = try await GoogleOAuth.exchange(code: code, verifier: verifier, redirectURI: server.redirectURI,
                                                        client: config, transport: transport)
            let bootstrap = GmailClient(transport: transport) { _ in tokens.accessToken }
            let profile = try await bootstrap.profile()
            let email = profile.email
            try await auth.save(tokens, for: email)
            await finishAdding(email: email, api: bootstrap)
        } catch MailError.signInCancelled {
            return
        } catch {
            banner = error.localizedDescription
        }
    }

    func cancelSignIn() { signInServer?.cancel() }

    func finishAdding(email: String, api: GmailAPI) async {
        var entry = accounts.first { $0.email == email } ?? Account(email: email, displayName: "", colorIndex: nextColor())
        entry.needsSignIn = false
        if let identity = try? await api.sendAsIdentity() {
            entry.displayName = identity.displayName
            entry.signature = EmailRenderer.renderHTML(identity.signatureHTML).plainText
        }
        if let index = accounts.firstIndex(where: { $0.email == email }) {
            accounts[index] = entry
        } else {
            accounts.append(entry)
            caches[email] = AccountCache()
        }
        disk.save(accounts, "accounts")
        clients[email] = nil
        await refreshLabels(email)
        if mailbox == nil { mailbox = defaultMailbox() }
        await reload()
        start()
    }

    private func nextColor() -> Int {
        let used = Set(accounts.map(\.colorIndex))
        return (0..<AccountPalette.count).first { !used.contains($0) } ?? accounts.count
    }

    func removeAccount(_ email: String) async {
        accounts.removeAll { $0.email == email }
        disk.save(accounts, "accounts")
        labels[email] = nil
        disk.save(labels, "labels")
        caches[email] = nil
        disk.delete(cacheName(email))
        clients[email] = nil
        historyIDs[email] = nil
        seenInbox[email] = nil
        await auth?.remove(email)
        if mailbox?.account == email { mailbox = defaultMailbox() }
        threads.removeAll { $0.account == email }
        selection = []
        if openThread?.account == email { closeThread() }
        await reload()
    }

    // MARK: Sidebar

    var unreadInboxTotal: Int {
        accounts.reduce(0) { total, account in
            total + (labels[account.email]?.first { $0.id == SystemLabel.inbox }?.threadsUnread ?? 0)
        }
    }

    func systemEntries(for email: String) -> [SidebarEntry] {
        let list = labels[email] ?? []
        func label(_ id: String) -> MailLabel? { list.first { $0.id == id } }
        func entry(_ title: String, _ icon: String, _ id: String, total: Bool = false) -> SidebarEntry {
            let item = label(id)
            return SidebarEntry(title: title, icon: icon, mailbox: .label(account: email, id: id),
                                count: total ? (item?.threadsTotal ?? 0) : (item?.threadsUnread ?? 0))
        }
        var entries = [
            entry("Inbox", "tray", SystemLabel.inbox),
            entry("Starred", "star", SystemLabel.starred),
            entry("Sent", "paperplane", SystemLabel.sent),
            entry("Drafts", "doc", SystemLabel.draft, total: true),
            entry("Important", "bookmark", SystemLabel.important),
            SidebarEntry(title: "All Mail", icon: "envelope", mailbox: .allMail(account: email), count: 0),
            entry("Spam", "exclamationmark.octagon", SystemLabel.spam),
            entry("Trash", "trash", SystemLabel.trash),
        ]
        // Gmail shows no counts beside Starred, Sent, Important or Trash.
        for index in [1, 2, 4, 7] { entries[index].count = 0 }
        return entries
    }

    func labelEntries(for email: String) -> [SidebarEntry] {
        userLabels(email).map {
            SidebarEntry(title: $0.name, icon: "tag", mailbox: .label(account: email, id: $0.id), count: $0.threadsUnread)
        }
    }

    func sidebarEntries(for email: String) -> [SidebarEntry] { systemEntries(for: email) + labelEntries(for: email) }

    func userLabels(_ email: String) -> [MailLabel] {
        (labels[email] ?? []).filter { !$0.isSystem }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func title(of mailbox: Mailbox?) -> String {
        if !activeSearch.isEmpty { return "Search" }
        switch mailbox {
        case .allInboxes: return "All Inboxes"
        case .allMail: return "All Mail"
        case .label(let email, let id):
            return sidebarEntries(for: email).first { $0.mailbox == .label(account: email, id: id) }?.title ?? id
        case nil: return "MailDock"
        }
    }

    // MARK: Thread lists

    var isInboxView: Bool {
        switch mailbox {
        case .allInboxes: return activeSearch.isEmpty
        case .label(_, let id): return id == SystemLabel.inbox && activeSearch.isEmpty
        default: return false
        }
    }

    var canLoadMore: Bool { !pageTokens.isEmpty }

    func scopeAccounts() -> [String] {
        guard let mailbox else { return [] }
        if let email = mailbox.account { return [email] }
        return accounts.filter { !$0.needsSignIn }.map(\.email)
    }

    private func currentQuery() -> (labels: [String], query: String?, spamTrash: Bool) {
        guard let mailbox else { return ([], nil, false) }
        if !activeSearch.isEmpty { return ([], activeSearch, false) }
        let query = isInboxView ? category.query : nil
        return (mailbox.labelFilter, query, mailbox.includesSpamAndTrash)
    }

    private func showCachedList() {
        guard let mailbox, activeSearch.isEmpty, category == .all else { return }
        var merged = [ThreadSummary]()
        for email in scopeAccounts() {
            guard let cache = caches[email], let ids = cache.lists[mailbox.cacheKey] else { continue }
            merged += ids.compactMap { cache.summaries[$0] }
        }
        threads = merged.sorted { $0.date > $1.date }
    }

    func selectMailbox(_ new: Mailbox?) async {
        guard new != nil else { return }
        mailbox = new
        searchText = ""
        activeSearch = ""
        category = .all
        selection = []
        closeThread()
        showCachedList()
        await reload()
    }

    func applySearch() async {
        activeSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        selection = []
        closeThread()
        threads = []
        await reload()
    }

    func selectCategory(_ new: InboxCategory) async {
        category = new
        selection = []
        closeThread()
        threads = []
        await reload()
    }

    func reload() async {
        listGeneration += 1
        let generation = listGeneration
        pageTokens = [:]
        let scope = scopeAccounts()
        guard !scope.isEmpty else { isLoadingList = false; threads = []; return }
        isLoadingList = true
        let collected = await fetchPages(scope, tokens: [:])
        guard generation == listGeneration else { return }
        isLoadingList = false
        if collected.allFailed { return }
        threads = collected.summaries.sorted { $0.date > $1.date }
        pageTokens = collected.tokens
        saveCaches(for: collected.summaries, accounts: collected.succeeded)
        dropSelectionNotInList()
    }

    func loadMore() async {
        guard canLoadMore, !isLoadingList else { return }
        let generation = listGeneration
        isLoadingList = true
        let collected = await fetchPages(Array(pageTokens.keys), tokens: pageTokens)
        guard generation == listGeneration else { return }
        isLoadingList = false
        if collected.allFailed { return }
        let existing = Set(threads.map(\.id))
        threads = (threads + collected.summaries.filter { !existing.contains($0.id) }).sorted { $0.date > $1.date }
        for email in collected.succeeded { pageTokens[email] = nil }
        pageTokens.merge(collected.tokens) { _, new in new }
    }

    private struct PageResult { var summaries: [ThreadSummary]; var tokens: [String: String]; var succeeded: [String]; var allFailed: Bool }

    private func fetchPages(_ scope: [String], tokens: [String: String]) async -> PageResult {
        let (labelFilter, query, spamTrash) = currentQuery()
        var result = PageResult(summaries: [], tokens: [:], succeeded: [], allFailed: false)
        await withTaskGroup(of: (String, Result<(ThreadPage, [ThreadSummary]), Error>).self) { group in
            for email in scope {
                guard let api = api(for: email) else { continue }
                let token = tokens[email]
                group.addTask { @MainActor in
                    do {
                        let page = try await api.listThreads(labelIDs: labelFilter, query: query, pageToken: token,
                                                             includeSpamTrash: spamTrash, maxResults: Self.pageSize)
                        let summaries = try await self.hydrate(page.threads, email: email, api: api)
                        return (email, .success((page, summaries)))
                    } catch {
                        return (email, .failure(error))
                    }
                }
            }
            for await (email, outcome) in group {
                switch outcome {
                case .success(let (page, summaries)):
                    result.summaries += summaries
                    result.succeeded.append(email)
                    if let next = page.nextPageToken { result.tokens[email] = next }
                    setNeedsSignIn(email, false)
                case .failure(let error):
                    handle(error, account: email, quietWhenOffline: true)
                }
            }
        }
        result.allFailed = result.succeeded.isEmpty && !scope.isEmpty
        return result
    }

    /// Turns list entries into rows, skipping any thread that hasn't changed since last time.
    private func hydrate(_ refs: [ThreadRef], email: String, api: GmailAPI) async throws -> [ThreadSummary] {
        var cache = caches[email] ?? AccountCache()
        var rows = [String: ThreadSummary]()
        var missing = [ThreadRef]()
        for ref in refs {
            if var known = cache.summaries[ref.id], known.historyID == ref.historyID, !ref.historyID.isEmpty {
                known.snippet = MessageParser.decodeEntities(ref.snippet)
                rows[ref.id] = known
            } else {
                missing.append(ref)
            }
        }
        let fetched: [ThreadSummary] = try await concurrentMap(missing, limit: 8) { ref in
            MessageParser.summary(try await api.threadMetadata(id: ref.id), ref: ref, account: email)
        }
        for summary in fetched {
            rows[summary.threadID] = summary
            cache.summaries[summary.threadID] = summary
        }
        caches[email] = cache
        return refs.compactMap { rows[$0.id] }
    }

    private func saveCaches(for summaries: [ThreadSummary], accounts emails: [String]) {
        guard activeSearch.isEmpty, category == .all, let mailbox else { return }
        for email in emails {
            var cache = caches[email] ?? AccountCache()
            cache.lists[mailbox.cacheKey] = summaries.filter { $0.account == email }.sorted { $0.date > $1.date }.map(\.threadID)
            cache.trim()
            caches[email] = cache
            disk.save(cache, cacheName(email))
        }
    }

    private func refreshFirstPage(_ email: String, api: GmailAPI) async {
        let (labelFilter, query, spamTrash) = currentQuery()
        let generation = listGeneration
        do {
            let page = try await api.listThreads(labelIDs: labelFilter, query: query, pageToken: nil,
                                                 includeSpamTrash: spamTrash, maxResults: Self.pageSize)
            let fresh = try await hydrate(page.threads, email: email, api: api)
            guard generation == listGeneration else { return }
            let oldest = fresh.map(\.date).min() ?? .distantPast
            let freshIDs = Set(fresh.map(\.id))
            let others = threads.filter { $0.account != email || ($0.date < oldest && !freshIDs.contains($0.id)) }
            threads = (fresh + others).sorted { $0.date > $1.date }
            saveCaches(for: threads, accounts: [email])
            dropSelectionNotInList()
            if let open = openThread, open.account == email, let row = fresh.first(where: { $0.id == open.id }),
               row.messageCount != (detail?.messages.count ?? 0) {
                openThread = row
                await loadOpenThread()
            }
        } catch {
            handle(error, account: email, quietWhenOffline: true)
        }
    }

    private func dropSelectionNotInList() {
        let visible = Set(threads.map(\.id))
        let kept = selection.intersection(visible)
        if kept != selection { selection = kept }
    }

    // MARK: Reading

    var selectedThreads: [ThreadSummary] { threads.filter { selection.contains($0.id) } }

    /// Opens a conversation in place of the list and marks it read.
    func open(_ row: ThreadSummary) async {
        openThread = row
        selection = []
        await loadOpenThread()
    }

    func closeThread() {
        detailGeneration += 1
        openThread = nil
        detail = nil
        isLoadingDetail = false
        // Replies being written under the conversation move to the corner instead of vanishing.
        let inline = composeSessions.values.filter(\.isInline)
        guard !inline.isEmpty else { return }
        for session in inline { session.isInline = false }
        composeOrder = composeOrder
    }

    /// Moves to the next (1) or previous (-1) conversation in the list.
    func openNeighbor(_ offset: Int) async {
        guard let current = openThread, let index = threads.firstIndex(where: { $0.id == current.id }),
              threads.indices.contains(index + offset) else { return }
        await open(threads[index + offset])
    }

    /// The conversations a toolbar button or menu command acts on.
    var actionTargets: [ThreadSummary] {
        if let openThread { return [openThread] }
        return selectedThreads
    }

    func loadOpenThread() async {
        guard let row = openThread, let api = api(for: row.account) else { return }
        detailGeneration += 1
        let generation = detailGeneration
        if detail?.summaryID != row.id { detail = nil }
        isLoadingDetail = true
        do {
            let raw = try await api.threadFull(id: row.threadID)
            let rendered: [RenderedMessage] = await Task.detached(priority: .userInitiated) {
                (raw.messages ?? []).map { item in
                    let message = MessageParser.parse(item)
                    return RenderedMessage(message: message, document: EmailRenderer.render(message: message))
                }
            }.value
            guard generation == detailGeneration else { return }
            detail = ThreadDetail(summaryID: row.id, account: row.account, threadID: row.threadID,
                                  subject: row.subject, messages: rendered)
            isLoadingDetail = false
            if row.isUnread { await perform(.markRead, on: [row], offerUndo: false) }
        } catch {
            guard generation == detailGeneration else { return }
            isLoadingDetail = false
            handle(error, account: row.account)
        }
    }

    func attachmentData(_ info: AttachmentInfo, account: String) async throws -> Data {
        if let data = info.inlineData { return data }
        guard let id = info.attachmentID, let api = api(for: account) else { throw MailError.invalidResponse }
        return try await api.attachment(messageID: info.messageID, attachmentID: id)
    }

    // MARK: Actions

    nonisolated static func applied(_ action: ThreadAction, to labels: Set<String>) -> Set<String> {
        var result = labels
        switch action {
        case .archive: result.remove(SystemLabel.inbox)
        case .moveToInbox: result.insert(SystemLabel.inbox); result.remove(SystemLabel.spam); result.remove(SystemLabel.trash)
        case .trash: result.insert(SystemLabel.trash); result.remove(SystemLabel.inbox)
        case .untrash: result.remove(SystemLabel.trash); result.insert(SystemLabel.inbox)
        case .spam: result.insert(SystemLabel.spam); result.remove(SystemLabel.inbox)
        case .notSpam: result.remove(SystemLabel.spam); result.insert(SystemLabel.inbox)
        case .markRead: result.remove(SystemLabel.unread)
        case .markUnread: result.insert(SystemLabel.unread)
        case .star: result.insert(SystemLabel.starred)
        case .unstar: result.remove(SystemLabel.starred)
        case .addLabel(let id): result.insert(id)
        case .removeLabel(let id): result.remove(id)
        }
        return result
    }

    private func belongsInView(_ labels: Set<String>) -> Bool {
        guard let mailbox else { return true }
        if !activeSearch.isEmpty { return !labels.contains(SystemLabel.trash) && !labels.contains(SystemLabel.spam) }
        return mailbox.contains(labels: labels)
    }

    private func send(_ action: ThreadAction, threadID: String, api: GmailAPI) async throws {
        switch action {
        case .archive: try await api.modifyThread(id: threadID, add: [], remove: [SystemLabel.inbox])
        case .moveToInbox: try await api.modifyThread(id: threadID, add: [SystemLabel.inbox], remove: [SystemLabel.spam])
        case .trash: try await api.trashThread(id: threadID)
        case .untrash: try await api.untrashThread(id: threadID)
        case .spam: try await api.modifyThread(id: threadID, add: [SystemLabel.spam], remove: [SystemLabel.inbox])
        case .notSpam: try await api.modifyThread(id: threadID, add: [SystemLabel.inbox], remove: [SystemLabel.spam])
        case .markRead: try await api.modifyThread(id: threadID, add: [], remove: [SystemLabel.unread])
        case .markUnread: try await api.modifyThread(id: threadID, add: [SystemLabel.unread], remove: [])
        case .star: try await api.modifyThread(id: threadID, add: [SystemLabel.starred], remove: [])
        case .unstar: try await api.modifyThread(id: threadID, add: [], remove: [SystemLabel.starred])
        case .addLabel(let id): try await api.modifyThread(id: threadID, add: [id], remove: [])
        case .removeLabel(let id): try await api.modifyThread(id: threadID, add: [], remove: [id])
        }
    }

    func perform(_ action: ThreadAction, on targets: [ThreadSummary], offerUndo: Bool = true) async {
        guard !targets.isEmpty else { return }
        let before = threads
        let previousSelection = selection
        let previousOpen = openThread
        let previousDetail = detail
        let targetIDs = Set(targets.map(\.id))

        // Show the change straight away; put it back if Gmail refuses.
        var updated = [ThreadSummary]()
        for var thread in threads {
            if targetIDs.contains(thread.id) {
                thread.labelIDs = Self.applied(action, to: thread.labelIDs)
                updateCachedLabels(thread)
                if !belongsInView(thread.labelIDs) {
                    selection.remove(thread.id)
                    continue
                }
            }
            updated.append(thread)
        }
        threads = updated

        var leftConversation = false
        if var open = openThread, targetIDs.contains(open.id) {
            switch action {
            case .archive, .trash, .spam, .moveToInbox, .untrash, .notSpam, .markUnread:
                // Like Gmail, moving or un-reading a conversation goes back to the list.
                closeThread()
                leftConversation = true
            default:
                open.labelIDs = Self.applied(action, to: open.labelIDs)
                openThread = open
            }
        }

        if offerUndo, let title = action.undoTitle, let inverse = action.inverse {
            undo = (title, inverse, targets)
        }

        var failure: Error?
        for target in targets {
            guard let api = api(for: target.account) else { continue }
            do {
                try await send(action, threadID: target.threadID, api: api)
            } catch {
                failure = error
                break
            }
        }
        if let failure {
            threads = before
            selection = previousSelection
            openThread = previousOpen
            if leftConversation { detail = previousDetail }
            undo = nil
            handle(failure, account: targets.first?.account)
            return
        }
        for email in Set(targets.map(\.account)) { await refreshLabels(email) }
    }

    private func updateCachedLabels(_ thread: ThreadSummary) {
        guard caches[thread.account]?.summaries[thread.threadID] != nil else { return }
        caches[thread.account]?.summaries[thread.threadID]?.labelIDs = thread.labelIDs
    }

    func performUndo() async {
        guard let undo else { return }
        self.undo = nil
        await perform(undo.action, on: undo.targets, offerUndo: false)
        await reload()
    }

    // MARK: Compose

    func beginCompose(_ draft: ComposeDraft, inline: Bool = false, origin: String? = nil) -> UUID {
        let session = ComposeSession(draft: draft, store: self)
        session.isInline = inline
        session.originThreadID = origin ?? draft.threadID
        composeSessions[session.id] = session
        composeOrder.append(session.id)
        return session.id
    }

    var dockedSessions: [ComposeSession] {
        composeOrder.compactMap { composeSessions[$0] }.filter { !$0.isInline && $0.id != maximizedCompose }
    }

    func inlineSessions(for threadID: String) -> [ComposeSession] {
        composeOrder.compactMap { composeSessions[$0] }.filter { $0.isInline && $0.originThreadID == threadID }
    }

    /// Moves a reply from under the conversation into its own window in the corner.
    func popOut(_ id: UUID) {
        guard let session = composeSessions[id] else { return }
        session.isInline = false
        composeOrder.removeAll { $0 == id }
        composeOrder.append(id)
    }

    func toggleMaximized(_ id: UUID) {
        maximizedCompose = maximizedCompose == id ? nil : id
    }

    func newMessage() -> UUID? {
        let email = mailbox?.account ?? accounts.first(where: { !$0.needsSignIn })?.email
        return email.map { beginCompose(ComposeDraft(account: $0)) }
    }

    func reply(_ rendered: RenderedMessage, all: Bool, account email: String, inline: Bool = false) -> UUID? {
        guard let account = account(email) else { return nil }
        return beginCompose(ComposeFactory.reply(to: rendered, account: account, replyAll: all), inline: inline)
    }

    func forward(_ rendered: RenderedMessage, account email: String, inline: Bool = false) async -> UUID? {
        guard let account = account(email) else { return nil }
        var draft = ComposeFactory.forward(rendered, account: account)
        for info in rendered.message.attachments {
            do {
                let data = try await attachmentData(info, account: email)
                draft.attachments.append(DraftAttachment(filename: info.filename, mimeType: info.mimeType, data: data))
            } catch {
                banner = "Couldn't include \(info.filename) in the forward: \(error.localizedDescription)"
            }
        }
        return beginCompose(draft, inline: inline, origin: rendered.message.threadID)
    }

    func resumeDraft(_ rendered: RenderedMessage, account email: String) async -> UUID? {
        guard let account = account(email), let api = api(for: email) else { return nil }
        do {
            let draftID = try await api.draftID(forMessage: rendered.message.id)
            var draft = ComposeFactory.resume(rendered, account: account, gmailDraftID: draftID)
            for info in rendered.message.attachments {
                let data = try await attachmentData(info, account: email)
                draft.attachments.append(DraftAttachment(filename: info.filename, mimeType: info.mimeType, data: data))
            }
            return beginCompose(draft)
        } catch {
            handle(error, account: email)
            return nil
        }
    }

    func endCompose(_ id: UUID) {
        composeSessions[id] = nil
        composeOrder.removeAll { $0 == id }
        if maximizedCompose == id { maximizedCompose = nil }
    }

    func didSendMail(account email: String) async {
        historyIDs[email] = nil
        await refreshLabels(email)
        await reload()
        if openThread?.account == email { await loadOpenThread() }
    }
}

extension Mailbox {
    var account: String? {
        switch self {
        case .allInboxes: return nil
        case .label(let account, _), .allMail(let account): return account
        }
    }
}

enum AccountPalette { static let count = 6 }

/// One open compose window: keeps its Gmail draft up to date and sends the message.
@MainActor
final class ComposeSession: ObservableObject, Identifiable {
    let id = UUID()
    @Published var draft: ComposeDraft
    @Published var isSending = false
    @Published var status = ""
    @Published var errorText: String?
    @Published var isInline = false
    @Published var isMinimized = false
    /// The conversation this reply or forward was started from.
    var originThreadID: String?

    private unowned let store: MailStore
    private var lastSaved: ComposeDraft?
    private var debounce: Task<Void, Never>?
    private var saving: Task<Void, Never>?
    private var finished = false
    var autosaveDelay: UInt64 = 4_000_000_000

    init(draft: ComposeDraft, store: MailStore) {
        self.draft = draft
        self.store = store
        lastSaved = draft
    }

    private func sender() -> EmailAddress {
        EmailAddress(name: store.account(draft.account)?.displayName ?? "", email: draft.account)
    }

    func draftChanged() {
        debounce?.cancel()
        guard !finished else { return }
        let delay = autosaveDelay
        debounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            await self?.saveNow()
        }
    }

    func saveNow() async {
        await saving?.value
        guard !finished, !draft.isBlank, draft != lastSaved, let api = store.api(for: draft.account) else { return }
        let snapshot = draft
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let raw = try MIMEBuilder.build(draft: snapshot, from: self.sender(), validate: false)
                let saved = try await api.saveDraft(id: snapshot.gmailDraftID, raw: raw, threadID: snapshot.threadID)
                var recorded = snapshot
                recorded.gmailDraftID = saved
                self.lastSaved = recorded
                self.draft.gmailDraftID = saved
                self.status = "Draft saved"
            } catch {
                self.status = "Couldn't save draft"
            }
        }
        saving = task
        await task.value
        saving = nil
    }

    /// Returns true once the mail has gone and the window can close.
    func send() async -> Bool {
        guard !isSending else { return false }
        debounce?.cancel()
        isSending = true
        errorText = nil
        defer { isSending = false }
        await saving?.value
        guard let api = store.api(for: draft.account) else {
            errorText = MailError.notConfigured.errorDescription
            return false
        }
        do {
            let raw = try MIMEBuilder.build(draft: draft, from: sender(), validate: true)
            finished = true
            do {
                try await api.send(raw: raw, threadID: draft.threadID)
            } catch {
                finished = false
                throw error
            }
            if let id = draft.gmailDraftID { try? await api.deleteDraft(id: id) }
            await store.didSendMail(account: draft.account)
            return true
        } catch {
            errorText = error.localizedDescription
            return false
        }
    }

    /// Moves a new message to another account, taking any saved draft with it.
    func changeAccount(to email: String) async {
        guard email != draft.account, draft.threadID == nil else { return }
        debounce?.cancel()
        await saving?.value
        if let id = draft.gmailDraftID, let api = store.api(for: draft.account) { try? await api.deleteDraft(id: id) }
        draft.gmailDraftID = nil
        draft.account = email
        lastSaved = nil
        draftChanged()
    }

    func discard() async {
        debounce?.cancel()
        await saving?.value
        finished = true
        if let id = draft.gmailDraftID, let api = store.api(for: draft.account) { try? await api.deleteDraft(id: id) }
    }

    /// Keeps what was typed when a window closes, without waiting for the timer.
    func closeKeepingDraft() async {
        debounce?.cancel()
        await saveNow()
        finished = true
    }
}
