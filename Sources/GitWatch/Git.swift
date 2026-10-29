import Foundation

/// État d'un dépôt à un instant donné.
struct RepoStatus: Equatable, Sendable {
    var branch: String?
    /// Branche suivie (« origin/main »), nil si aucune.
    var upstream: String?
    /// Commits locaux non poussés / commits distants non tirés.
    var ahead = 0
    var behind = 0
    /// Fichiers modifiés ou non suivis, et lignes ajoutées / supprimées non commitées.
    var changedFiles = 0
    var added = 0
    var removed = 0
    /// Fichiers non suivis (compris dans changedFiles) et stashes en attente.
    var untracked = 0
    var stashes = 0
    /// Branche par défaut du serveur (« main ») et son retard quand on travaille sur une autre branche.
    var defaultBranch: String?
    var defaultBehind = 0
    /// Branches locales dont des commits ne sont pas sur le serveur (hors branche courante suivie, comptée dans `ahead`).
    var unpushedBranches: [BranchWork] = []
    /// Commits à récupérer, du plus récent au plus ancien (10 au plus).
    var incoming: [Commit] = []
    /// Page web du dépôt (GitHub, GitLab…), déduite de l'URL du remote.
    var webURL: URL?
    /// Erreur du dernier fetch (réseau, identifiants…).
    var error: String?

    var isClean: Bool { changedFiles == 0 }
    var onOtherBranch: Bool { branch != nil && defaultBranch != nil && branch != defaultBranch }
    /// Travail local à ne pas oublier : modifications, stashes, commits sur d'autres branches.
    var hasLocalWork: Bool { !isClean || stashes > 0 || !unpushedBranches.isEmpty }
}

struct Commit: Equatable, Sendable, Identifiable {
    let hash: String
    let subject: String
    let author: String
    let date: Date
    var id: String { hash }
}

struct BranchWork: Equatable, Sendable, Identifiable {
    let name: String
    let commits: Int
    /// Aucune branche suivie sur le serveur (jamais poussée, ou supprimée depuis).
    let local: Bool
    var id: String { name }
}

/// Appels à git (l'exécutable du système : identifiants, clés SSH et trousseau de l'utilisateur).
enum Git {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Le vrai git des outils de développement : /usr/bin/git n'est qu'un relais vers xcrun, plus lent à chaque appel.
    private static let executable: URL = {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["--find", "git"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return URL(fileURLWithPath: "/usr/bin/git") }
        let path = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmed
        process.waitUntilExit()
        return process.terminationStatus == 0 && FileManager.default.isExecutableFile(atPath: path)
            ? URL(fileURLWithPath: path) : URL(fileURLWithPath: "/usr/bin/git")
    }()

    /// Exécute git dans `repo`. Jamais de demande interactive : sans identifiants, la commande échoue.
    @discardableResult
    static func run(_ arguments: [String], in repo: URL, timeout: TimeInterval = 30) throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["-C", repo.path] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes -o ConnectTimeout=15"
        environment["LC_ALL"] = "C"
        process.environment = environment
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        // waitUntilExit attend par sondage (~75 ms par appel) : un sémaphore rend la main dès la fin du processus.
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()

        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        // Lecture avant waitUntilExit : une sortie volumineuse bloquerait sinon le processus.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        finished.wait()
        killer.cancel()

        guard process.terminationStatus == 0 else {
            if process.terminationReason == .uncaughtSignal { throw Failure(message: "Délai dépassé (\(Int(timeout)) s).") }
            let message = String(decoding: errorData, as: UTF8.self)
                .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty && !$0.hasPrefix("hint:") } ?? "git \(arguments.first ?? "") a échoué."
            throw Failure(message: explain(String(decoding: errorData, as: UTF8.self), fallback: message))
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Traduit les erreurs git les plus courantes ; sinon, première ligne utile du message d'origine.
    static func explain(_ output: String, fallback: String) -> String {
        let text = output.lowercased()
        if let range = output.range(of: #"could not read (Username|Password) for '([^']+)'"#, options: .regularExpression) {
            let host = URL(string: output[range].components(separatedBy: "'")[1])?.host ?? "le serveur"
            return "Identifiants HTTPS manquants pour \(host) : enregistrez-les dans le trousseau (un git pull dans le Terminal suffit)."
        }
        if text.contains("repository not found") || text.contains("does not appear to be a git repository") {
            return "Dépôt introuvable sur le serveur : supprimé, renommé ou accès refusé."
        }
        if text.contains("access to repository not granted") || text.contains("403") {
            return "Accès refusé par le serveur."
        }
        if text.contains("permission denied (publickey") || text.contains("host key verification failed") {
            return "Accès SSH refusé : clé absente de l’agent ou hôte inconnu."
        }
        if text.contains("could not resolve host") || text.contains("unable to access") && text.contains("resolve") {
            return "Serveur injoignable (réseau ou nom d’hôte)."
        }
        if text.contains("would be overwritten") {
            return "Pull refusé : modifications locales en conflit."
        }
        if text.contains("unmerged files") || text.contains("merging is not possible") || text.contains("you have not concluded your merge") {
            return "Fusion en cours : terminez-la ou annulez-la."
        }
        if text.contains("[rejected]") || text.contains("non-fast-forward") || text.contains("fetch first") {
            return "Push refusé : le serveur a des commits plus récents, faites d’abord un pull."
        }
        if text.contains("not possible to fast-forward") || text.contains("diverging branches") {
            return "Branches divergentes : avance rapide impossible."
        }
        return fallback.replacingOccurrences(of: "fatal: ", with: "").replacingOccurrences(of: "error: ", with: "")
    }

    /// Cherche les dépôts sous `root`, jusqu'à `depth` niveaux (0 : `root` seulement).
    /// On ne descend pas dans un dépôt trouvé (sous-modules et dépôts imbriqués ignorés).
    static func discover(in root: URL, depth: Int) -> [URL] {
        let manager = FileManager.default
        if manager.fileExists(atPath: root.appendingPathComponent(".git").path) { return [root] }
        guard depth > 0,
              let children = try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                                                              options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        let skipped: Set<String> = ["node_modules", "Library", "build", "DerivedData"]
        return children
            .filter { url in
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                return values?.isDirectory == true && values?.isSymbolicLink != true && !skipped.contains(url.lastPathComponent)
            }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .flatMap { discover(in: $0, depth: depth - 1) }
    }

    static func fetch(_ repo: URL) throws {
        try run(["fetch", "--quiet", "--prune", "--no-recurse-submodules"], in: repo, timeout: 90)
    }

    /// Lit l'état local (aucun accès réseau).
    static func status(of repo: URL) throws -> RepoStatus {
        var status = RepoStatus()
        // « --porcelain=v2 --branch » donne en une fois la branche, l'amont, l'avance et le retard.
        let porcelain = try run(["status", "--porcelain=v2", "--branch", "--untracked-files=normal"], in: repo)
        for line in porcelain.split(separator: "\n") {
            if line.hasPrefix("# branch.head ") {
                let head = String(line.dropFirst("# branch.head ".count))
                status.branch = head == "(detached)" ? nil : head
            } else if line.hasPrefix("# branch.upstream ") {
                status.upstream = String(line.dropFirst("# branch.upstream ".count))
            } else if line.hasPrefix("# branch.ab ") {
                let parts = line.split(separator: " ")
                status.ahead = parts.count > 2 ? abs(Int(parts[2]) ?? 0) : 0
                status.behind = parts.count > 3 ? abs(Int(parts[3]) ?? 0) : 0
            } else if !line.hasPrefix("#") {
                status.changedFiles += 1
                if line.hasPrefix("? ") { status.untracked += 1 }
            }
        }
        if status.changedFiles > 0 {
            // Échoue sans commit initial : on garde alors 0.
            (status.added, status.removed) = (try? run(["diff", "HEAD", "--shortstat"], in: repo)).map(parseShortStat) ?? (0, 0)
        }
        // Échoue sans stash : 0.
        status.stashes = (try? run(["rev-list", "--walk-reflogs", "--count", "refs/stash"], in: repo)).flatMap { Int($0.trimmed) } ?? 0

        let remotes = ((try? run(["remote"], in: repo)) ?? "").split(separator: "\n").map(String.init)
        guard let remote = remotes.contains("origin") ? "origin" : remotes.first else { return status }
        status.webURL = (try? run(["remote", "get-url", remote], in: repo)).flatMap { webURL(fromRemote: $0) }
        status.defaultBranch = defaultBranch(of: repo, remote: remote)
        if status.onOtherBranch, let main = status.defaultBranch {
            status.defaultBehind = (try? run(["rev-list", "--count", "refs/heads/\(main)..refs/remotes/\(remote)/\(main)"], in: repo))
                .flatMap { Int($0.trimmed) } ?? 0
        }
        status.unpushedBranches = unpushedBranches(of: repo, current: status.upstream == nil ? nil : status.branch)
        if status.behind > 0 {
            status.incoming = incoming(of: repo)
        }
        return status
    }

    /// Branche vers laquelle pointe « origin/HEAD », sinon main ou master s'ils existent sur le serveur.
    private static func defaultBranch(of repo: URL, remote: String) -> String? {
        if let head = try? run(["symbolic-ref", "--quiet", "--short", "refs/remotes/\(remote)/HEAD"], in: repo).trimmed, !head.isEmpty {
            return String(head.dropFirst(remote.count + 1))
        }
        return ["main", "master"].first { (try? run(["rev-parse", "--verify", "--quiet", "refs/remotes/\(remote)/\($0)"], in: repo)) != nil }
    }

    /// Branches locales avec des commits absents du serveur. `current` : branche courante suivie, déjà comptée.
    private static func unpushedBranches(of repo: URL, current: String?) -> [BranchWork] {
        guard let refs = try? run(["for-each-ref", "--format=%(refname:short)%09%(upstream:short)%09%(upstream:track)", "refs/heads"], in: repo)
        else { return [] }
        // Sans branche distante récupérée (dépôts gérés par west, par exemple), « absent du serveur » n'a pas de sens.
        let hasRemoteRefs = !((try? run(["for-each-ref", "--count=1", "refs/remotes"], in: repo)) ?? "").trimmed.isEmpty
        var result: [BranchWork] = []
        for line in refs.split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            // manifest-rev : branche technique de west (Zephyr), jamais poussée.
            guard fields.count == 3, fields[0] != current, fields[0] != "manifest-rev" else { continue }
            let (name, upstream, track) = (fields[0], fields[1], fields[2])
            if !upstream.isEmpty, !track.contains("gone") {
                // « [ahead 3] » ou « [ahead 3, behind 1] »
                if let range = track.range(of: #"ahead \d+"#, options: .regularExpression),
                   let count = Int(track[range].dropFirst("ahead ".count)), count > 0 {
                    result.append(BranchWork(name: name, commits: count, local: false))
                }
            } else if hasRemoteRefs, let count = (try? run(["rev-list", "--count", "refs/heads/\(name)", "--not", "--remotes"], in: repo)).flatMap({ Int($0.trimmed) }),
                      count > 0 {
                result.append(BranchWork(name: name, commits: count, local: true))
            }
        }
        return result
    }

    private static func incoming(of repo: URL) -> [Commit] {
        guard let log = try? run(["log", "-n", "10", "--format=%h%x1f%s%x1f%an%x1f%ct", "HEAD..@{upstream}"], in: repo) else { return [] }
        return log.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 4 else { return nil }
            return Commit(hash: fields[0], subject: fields[1], author: fields[2],
                          date: Date(timeIntervalSince1970: TimeInterval(fields[3]) ?? 0))
        }
    }

    /// « git@github.com:owner/repo.git », « ssh://git@host/owner/repo », « https://user@host/owner/repo.git » → https://host/owner/repo
    static func webURL(fromRemote remote: String) -> URL? {
        var text = remote.trimmed
        if text.hasSuffix(".git") { text.removeLast(4) }
        if text.contains("://") {
            guard let url = URL(string: text), let host = url.host, url.scheme != "file" else { return nil }
            return URL(string: "https://\(host)\(url.path)")
        }
        // Syntaxe scp : [utilisateur@]hôte:chemin
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let host = text[..<colon].split(separator: "@").last.map(String.init) ?? ""
        let path = text[text.index(after: colon)...].trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return host.isEmpty || path.isEmpty ? nil : URL(string: "https://\(host)/\(path)")
    }

    /// URL de tous les remotes du dépôt (pour reconnaître les dépôts déjà clonés).
    static func remoteURLs(of repo: URL) -> [String] {
        ((try? run(["config", "--get-regexp", #"^remote\..*\.url$"#], in: repo)) ?? "")
            .split(separator: "\n").compactMap { $0.split(separator: " ", maxSplits: 1).last.map(String.init) }
    }

    /// Clone `url` dans `folder`/`name`.
    static func clone(_ url: String, into folder: URL, name: String) throws {
        try run(["clone", "--quiet", url, name], in: folder, timeout: 600)
    }

    /// « 3 files changed, 48 insertions(+), 12 deletions(-) » → (48, 12).
    static func parseShortStat(_ text: String) -> (Int, Int) {
        var added = 0, removed = 0
        for part in text.split(separator: ",") {
            let words = part.split(separator: " ")
            guard let value = words.first.flatMap({ Int($0) }) else { continue }
            if part.contains("insertion") { added = value } else if part.contains("deletion") { removed = value }
        }
        return (added, removed)
    }

    /// Envoie la branche courante vers sa branche suivie (refusé par le serveur s'il a des commits plus récents).
    static func push(_ repo: URL) throws {
        try run(["push", "--quiet"], in: repo, timeout: 120)
    }

    /// Tirage sûr : avance rapide uniquement, sur l'amont déjà récupéré par fetch.
    static func fastForward(_ repo: URL) throws {
        try run(["merge", "--ff-only", "--quiet", "@{upstream}"], in: repo, timeout: 60)
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

extension URL {
    /// Clé de comparaison « hôte/chemin » en minuscules : github.com/blegal/gitwatch
    var repoKey: String { ((host ?? "") + path).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
}
