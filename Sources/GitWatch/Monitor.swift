import AppKit
import Network
import UserNotifications

/// Dépôt trouvé dans un des dossiers explorés.
struct Repo: Identifiable, Equatable {
    let url: URL
    var status: RepoStatus?
    /// Dernier tirage automatique (ou manuel) et nombre de commits tirés.
    var lastPull: Date?
    var pulledCommits = 0
    var pullError: String?

    var id: String { url.path }
    var name: String { url.lastPathComponent }
    /// Chemin abrégé (« ~/GitHub/… »).
    var displayPath: String { (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath }
}

/// Classement des dépôts suivis, du plus urgent au moins urgent (présentation « Par action »).
enum RepoCategory: Int, CaseIterable, Identifiable {
    case error, toPull, toPush, modified, pulled, upToDate, unknown
    var id: Int { rawValue }

    var title: String {
        switch self {
        case .error: "Erreurs"
        case .toPull: "Pull à faire"
        case .toPush: "Push à faire"
        case .modified: "Modifications locales"
        case .pulled: "Pull du jour"
        case .upToDate: "À jour"
        case .unknown: "En cours de vérification"
        }
    }

    init(_ repo: Repo) {
        guard let status = repo.status else { self = .unknown; return }
        // Un tirage refusé (modifications locales…) n'est pas une erreur de serveur : le dépôt reste « À tirer ».
        if status.error != nil { self = .error }
        else if status.behind > 0 { self = .toPull }
        else if status.ahead > 0 { self = .toPush }
        else if status.hasLocalWork { self = .modified }
        else if let pull = repo.lastPull, Calendar.current.isDateInToday(pull) { self = .pulled }
        else { self = .upToDate }
    }

    /// Catégories comptées dans le badge de la barre des menus.
    var needsAttention: Bool { self == .error || self == .toPull }
}

/// Surveille les dépôts : découverte, fetch périodique, état, tirage automatique, notifications.
@MainActor @Observable
final class Monitor {
    static let shared = Monitor()

    private(set) var repos: [Repo] = []
    private(set) var lastCheck: Date?
    private(set) var isChecking = false
    /// Dépôts en cours de pull ou de push manuel.
    private(set) var busy: Set<String> = []

    private let preferences = Preferences.shared
    private var timer: Timer?
    private let network = NWPathMonitor()
    private var online = true

    var followedRepos: [Repo] { repos.filter { preferences.settings(for: $0.id).followed } }
    var attentionCount: Int { followedRepos.filter { RepoCategory($0).needsAttention }.count }

    func start() {
        Notifier.requestAuthorizationIfNeeded()
        schedule()
        Task { await refresh(fetch: true) }
        // Au réveil du Mac et au retour du réseau, on vérifie sans attendre la prochaine échéance.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(15))
                await Monitor.shared.refreshIfStale()
            }
        }
        network.pathUpdateHandler = { path in
            let satisfied = path.status == .satisfied
            Task { @MainActor in
                let monitor = Monitor.shared
                defer { monitor.online = satisfied }
                guard satisfied, !monitor.online else { return }
                try? await Task.sleep(for: .seconds(5))
                await monitor.refreshIfStale()
            }
        }
        network.start(queue: .global(qos: .utility))
    }

    /// Vérifie si la dernière vérification date de plus de deux minutes.
    func refreshIfStale() async {
        if let lastCheck, Date().timeIntervalSince(lastCheck) < 120 { return }
        await refresh(fetch: true)
    }

    /// (Re)programme la vérification périodique selon l'intervalle choisi.
    func schedule() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(preferences.interval * 60), repeats: true) { _ in
            Task { @MainActor in await Monitor.shared.refresh(fetch: true) }
        }
        timer?.tolerance = 30
    }

    /// Redécouvre les dépôts puis lit leur état ; avec `fetch`, interroge aussi les serveurs.
    func refresh(fetch: Bool) async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        let roots = preferences.roots
        let urls = await Task.detached {
            var seen = Set<String>()
            return roots.flatMap { Git.discover(in: $0.url, depth: $0.depth) }.filter { seen.insert($0.path).inserted }
        }.value
        let previous = Dictionary(repos.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        repos = urls.map { previous[$0.path] ?? Repo(url: $0) }

        let jobs = repos.compactMap { repo -> (URL, Bool)? in
            let settings = preferences.settings(for: repo.id)
            return settings.followed ? (repo.url, settings.autoPull) : nil
        }
        var newlyBehind: [(String, Int)] = []
        var autoPulled: [(String, Int)] = []
        var pullFailures: [String] = []

        await withTaskGroup(of: Outcome.self) { group in
            var pending = jobs[...]
            // Au plus 6 dépôts à la fois : assez pour aller vite, sans saturer le réseau ni les serveurs.
            for _ in 0..<6 {
                guard let (url, autoPull) = pending.popFirst() else { break }
                group.addTask { Self.check(url, fetch: fetch, autoPull: autoPull) }
            }
            for await outcome in group {
                if let (url, autoPull) = pending.popFirst() {
                    group.addTask { Self.check(url, fetch: fetch, autoPull: autoPull) }
                }
                guard let index = repos.firstIndex(where: { $0.id == outcome.url.path }) else { continue }
                let old = repos[index]
                repos[index].status = outcome.status
                repos[index].pullError = outcome.pullError
                if outcome.pulled > 0 {
                    repos[index].lastPull = Date()
                    repos[index].pulledCommits = outcome.pulled
                    autoPulled.append((old.name, outcome.pulled))
                }
                if outcome.pullError != nil { pullFailures.append(old.name) }
                let behind = outcome.status.behind
                if fetch, behind > (old.status?.behind ?? 0) { newlyBehind.append((old.name, behind)) }
            }
        }
        if fetch { lastCheck = Date() }

        if preferences.notifyBehind, !newlyBehind.isEmpty { Notifier.behind(newlyBehind) }
        if preferences.notifyAutoPull, !autoPulled.isEmpty || !pullFailures.isEmpty {
            Notifier.autoPulled(autoPulled, failures: pullFailures)
        }
    }

    /// Tirage manuel (avance rapide uniquement).
    func pull(_ repo: Repo) async {
        guard !busy.contains(repo.id) else { return }
        busy.insert(repo.id)
        defer { busy.remove(repo.id) }
        let url = repo.url
        let outcome = await Task.detached { () -> (RepoStatus?, String?) in
            do {
                try Git.fetch(url)
                try Git.fastForward(url)
                return (try? Git.status(of: url), nil)
            } catch {
                return (try? Git.status(of: url), error.localizedDescription)
            }
        }.value
        guard let index = repos.firstIndex(where: { $0.id == repo.id }) else { return }
        if let status = outcome.0 { repos[index].status = status }
        repos[index].pullError = outcome.1
        if outcome.1 == nil, let before = repo.status?.behind, before > 0 {
            repos[index].lastPull = Date()
            repos[index].pulledCommits = before
        }
    }

    /// Push manuel de la branche courante.
    func push(_ repo: Repo) async {
        guard !busy.contains(repo.id) else { return }
        busy.insert(repo.id)
        defer { busy.remove(repo.id) }
        let url = repo.url
        let outcome = await Task.detached { () -> (RepoStatus?, String?) in
            do {
                try Git.push(url)
                return (try? Git.status(of: url), nil)
            } catch {
                return (try? Git.status(of: url), error.localizedDescription)
            }
        }.value
        guard let index = repos.firstIndex(where: { $0.id == repo.id }) else { return }
        if let status = outcome.0 { repos[index].status = status }
        repos[index].pullError = outcome.1
    }

    /// Dépôts que « Push all » peut envoyer : en avance, pas en retard, avec une branche suivie.
    var pushable: [Repo] {
        followedRepos.filter { repo in
            guard let status = repo.status else { return false }
            return status.ahead > 0 && status.behind == 0 && status.upstream != nil && status.error == nil
        }
    }

    func pushAll(_ selection: [Repo]? = nil) async {
        let candidates = selection ?? pushable
        await withTaskGroup(of: Void.self) { group in
            for repo in candidates { group.addTask { await self.push(repo) } }
        }
    }

    /// Dépôts que « Pull all » peut mettre à jour sans risque : en retard, sans commit ni modification locale.
    var safelyPullable: [Repo] {
        followedRepos.filter { repo in
            guard let status = repo.status else { return false }
            return status.behind > 0 && status.ahead == 0 && status.isClean
        }
    }

    /// Tire tous les dépôts en retard qui peuvent l'être sans risque (comme le tirage automatique).
    func pullAll(_ selection: [Repo]? = nil) async {
        let candidates = selection ?? safelyPullable
        await withTaskGroup(of: Void.self) { group in
            for repo in candidates { group.addTask { await self.pull(repo) } }
        }
    }

    // MARK: Vérification d'un dépôt (hors du fil principal)

    private struct Outcome: Sendable {
        let url: URL
        let status: RepoStatus
        let pulled: Int
        let pullError: String?
    }

    nonisolated private static func check(_ url: URL, fetch: Bool, autoPull: Bool) -> Outcome {
        var fetchError: String?
        if fetch {
            do { try Git.fetch(url) } catch { fetchError = error.localizedDescription }
        }
        var status: RepoStatus
        do { status = try Git.status(of: url) } catch {
            return Outcome(url: url, status: RepoStatus(error: error.localizedDescription), pulled: 0, pullError: nil)
        }
        status.error = fetchError
        // Tirage automatique seulement s'il est sans risque : avance rapide, aucun commit ni modification locale.
        guard autoPull, fetchError == nil, status.upstream != nil, status.behind > 0, status.ahead == 0, status.isClean else {
            return Outcome(url: url, status: status, pulled: 0, pullError: nil)
        }
        do {
            try Git.fastForward(url)
            let pulled = status.behind
            return Outcome(url: url, status: (try? Git.status(of: url)) ?? status, pulled: pulled, pullError: nil)
        } catch {
            return Outcome(url: url, status: status, pulled: 0, pullError: error.localizedDescription)
        }
    }
}

/// Notifications du système (nécessitent le paquet .app : identifiant de bundle).
enum Notifier {
    private static var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    static func requestAuthorizationIfNeeded() {
        center?.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func behind(_ repos: [(String, Int)]) {
        if repos.count == 1, let (name, count) = repos.first {
            post("\(name) : pull à faire", count == 1 ? "1 nouveau commit." : "\(count) nouveaux commits.")
        } else {
            post("\(repos.count) dépôts : pull à faire", repos.map(\.0).joined(separator: ", "))
        }
    }

    static func autoPulled(_ repos: [(String, Int)], failures: [String]) {
        if !repos.isEmpty {
            let detail = repos.map { "\($0.0) (\($0.1))" }.joined(separator: ", ")
            post(repos.count == 1 ? "Pull automatique : \(repos[0].0)" : "Pull automatique de \(repos.count) dépôts", detail)
        }
        if !failures.isEmpty {
            post("Échec du pull automatique", failures.joined(separator: ", "))
        }
    }

    private static func post(_ title: String, _ body: String) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
