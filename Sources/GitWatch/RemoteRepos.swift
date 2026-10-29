import Foundation
import Security

/// Dépôt d'un compte GitHub ou GitLab.
struct RemoteRepo: Identifiable, Hashable, Sendable {
    /// Clé « hôte/propriétaire/nom » en minuscules (voir `URL.repoKey`).
    let id: String
    let fullName: String
    let cloneURL: String
    let web: URL
    let archived: Bool
    let fork: Bool
    /// Faux pour un dépôt partagé (collaborateur) qui n'appartient pas à l'utilisateur.
    let owned: Bool
    let updated: Date?
    var name: String { (fullName as NSString).lastPathComponent }
    var host: String { web.host ?? "" }
}

/// Dépôts des comptes distants qui ne sont pas clonés sur ce Mac.
@MainActor @Observable
final class RemoteCatalog {
    static let shared = RemoteCatalog()

    private(set) var remote: [RemoteRepo] = []
    private(set) var localKeys: Set<String> = []
    private(set) var isLoading = false
    private(set) var lastLoad: Date?
    /// Erreur par source (« GitHub », hôte GitLab).
    private(set) var errors: [String: String] = [:]
    private(set) var cloning: Set<String> = []
    private(set) var cloneErrors: [String: String] = [:]

    var missing: [RemoteRepo] { remote.filter { !localKeys.contains($0.id) } }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let urls = Monitor.shared.repos.map(\.url)
        let keysTask = Task.detached {
            Set(urls.flatMap { Git.remoteURLs(of: $0) }.compactMap { Git.webURL(fromRemote: $0.url)?.repoKey })
        }
        var all: [RemoteRepo] = []
        var errors: [String: String] = [:]
        do { all += try await Task.detached { try Self.github() }.value } catch { errors["GitHub"] = error.localizedDescription }
        for host in Self.gitlabHosts(in: Monitor.shared.repos) {
            guard let token = Keychain.token(for: host) else { continue }
            do { all += try await Self.gitlab(host: host, token: token) } catch { errors[host] = error.localizedDescription }
        }
        var seen = Set<String>()
        remote = all.filter { seen.insert($0.id).inserted }.sorted { ($0.updated ?? .distantPast) > ($1.updated ?? .distantPast) }
        localKeys = await keysTask.value
        self.errors = errors
        lastLoad = Date()
    }

    func clone(_ repo: RemoteRepo, into folder: URL) async {
        guard !cloning.contains(repo.id) else { return }
        cloning.insert(repo.id)
        cloneErrors[repo.id] = nil
        defer { cloning.remove(repo.id) }
        let target = folder.appendingPathComponent(repo.name)
        if FileManager.default.fileExists(atPath: target.path) {
            cloneErrors[repo.id] = "\((target.path as NSString).abbreviatingWithTildeInPath) existe déjà."
            return
        }
        do {
            try await Task.detached { try Git.clone(repo.cloneURL, into: folder, name: repo.name) }.value
            localKeys.insert(repo.id)
            await Monitor.shared.refresh(fetch: false)
        } catch {
            cloneErrors[repo.id] = error.localizedDescription
        }
    }

    /// Serveurs GitLab rencontrés dans les remotes des dépôts locaux.
    static func gitlabHosts(in repos: [Repo]) -> [String] {
        Set(repos.compactMap { $0.status?.webURL?.host }.filter { $0.contains("gitlab") }).sorted()
    }

    // MARK: Sources

    /// Dépôts GitHub de l'utilisateur et ceux qui lui sont partagés, via GitHub CLI (son jeton, dans le trousseau).
    nonisolated private static func github() throws -> [RemoteRepo] {
        guard let gh = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw Git.Failure(message: "GitHub CLI introuvable : installez-le (brew install gh) puis connectez-vous (gh auth login).")
        }
        return try ["owner", "collaborator"].flatMap { affiliation in
            let output = try run(gh, ["api", "--paginate", "user/repos?per_page=100&affiliation=\(affiliation)",
                                      "--jq", ".[] | [.full_name, .clone_url, .html_url, .archived, .fork, .pushed_at] | @tsv"])
            return output.split(separator: "\n").compactMap { line -> RemoteRepo? in
                let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard f.count == 6, let web = URL(string: f[2]) else { return nil }
                return RemoteRepo(id: web.repoKey, fullName: f[0], cloneURL: f[1], web: web, archived: f[3] == "true",
                                  fork: f[4] == "true", owned: affiliation == "owner", updated: date(f[5]))
            }
        }
    }

    private struct GitLabProject: Decodable {
        let path_with_namespace: String
        let http_url_to_repo: String
        let web_url: String
        let archived: Bool?
        let last_activity_at: String?
        let forked_from_project: Forked?
        struct Forked: Decodable {}
    }

    /// Projets GitLab dont l'utilisateur est membre (jeton personnel, portée read_api).
    private static func gitlab(host: String, token: String) async throws -> [RemoteRepo] {
        var result: [RemoteRepo] = []
        var page = 1
        while page > 0, page < 50 {
            var request = URLRequest(url: URL(string: "https://\(host)/api/v4/projects?membership=true&per_page=100&page=\(page)")!)
            request.setValue(token, forHTTPHeaderField: "PRIVATE-TOKEN")
            request.timeoutInterval = 30
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = response as? HTTPURLResponse
            switch http?.statusCode ?? 0 {
            case 200: break
            case 401, 403: throw Git.Failure(message: "Jeton GitLab refusé par \(host) (portée read_api nécessaire).")
            case let code: throw Git.Failure(message: "\(host) a répondu \(code).")
            }
            for project in try JSONDecoder().decode([GitLabProject].self, from: data) {
                guard let web = URL(string: project.web_url) else { continue }
                result.append(RemoteRepo(id: web.repoKey, fullName: project.path_with_namespace, cloneURL: project.http_url_to_repo, web: web,
                                         archived: project.archived ?? false, fork: project.forked_from_project != nil, owned: true,
                                         updated: project.last_activity_at.flatMap(date)))
            }
            page = Int(http?.value(forHTTPHeaderField: "X-Next-Page") ?? "") ?? 0
        }
        return result
    }

    nonisolated private static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }

    nonisolated private static func run(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        finished.wait()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errorData, as: UTF8.self).trimmed
            throw Git.Failure(message: message.contains("auth login") || message.contains("401")
                              ? "GitHub CLI n’est pas connecté : lancez gh auth login dans le Terminal." : message)
        }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Jetons d'accès des serveurs GitLab, dans le trousseau de session.
enum Keychain {
    private static let service = "GitWatch"

    static func token(for host: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: host, kSecReturnData as String: true]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func setToken(_ token: String?, for host: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: host]
        SecItemDelete(query as CFDictionary)
        guard let token, !token.isEmpty else { return }
        var attributes = query
        attributes[kSecValueData as String] = Data(token.utf8)
        attributes[kSecAttrLabel as String] = "GitWatch — jeton GitLab \(host)"
        SecItemAdd(attributes as CFDictionary, nil)
    }
}
