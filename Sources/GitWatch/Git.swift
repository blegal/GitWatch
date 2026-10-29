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

    /// Jamais de demande interactive : sans identifiants, la commande échoue.
    /// Pas de verrou facultatif : `git status` ne réécrit pas l'index (moins d'écritures disque, pas de conflit avec l'éditeur).
    private static let environment: [String: String] = {
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes -o ConnectTimeout=15"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["LC_ALL"] = "C"
        return environment
    }()

    /// Exécute git dans `repo`.
    @discardableResult
    static func run(_ arguments: [String], in repo: URL, timeout: TimeInterval = 30) throws -> String {
        // Les fils de Swift Concurrency ne vident pas de pool d'autorelease : sans celui-ci, Process et Pipe s'accumulent.
        try autoreleasepool { try execute(arguments, in: repo, timeout: timeout) }
    }

    private static func execute(_ arguments: [String], in repo: URL, timeout: TimeInterval) throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["-C", repo.path] + arguments
        process.environment = environment
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        // waitUntilExit attend par sondage (~75 ms par appel) : un sémaphore rend la main dès la fin du processus.
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()

        // Une source de minuterie annulée est libérée aussitôt (un DispatchWorkItem annulé resterait en file
        // jusqu'à son échéance, avec le processus, ses tubes et son environnement).
        let killer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        killer.schedule(deadline: .now() + timeout)
        killer.setEventHandler { [weak process] in if let process, process.isRunning { process.terminate() } }
        killer.resume()
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
        let refs = References(try? run(["for-each-ref", "--format=%(refname)%09%(upstream:short)%09%(upstream:track)%09%(symref)",
                                         "refs/heads", "refs/remotes", "refs/stash"], in: repo))
        if refs.hasStash {
            status.stashes = (try? run(["rev-list", "--walk-reflogs", "--count", "refs/stash"], in: repo)).flatMap { Int($0.trimmed) } ?? 0
        }

        // « remote.origin.url git@github.com:… » : noms et URL des remotes en un seul appel.
        let remotes = remoteURLs(of: repo)
        guard let (remote, url) = remotes.first(where: { $0.name == "origin" }) ?? remotes.first else { return status }
        status.webURL = webURL(fromRemote: url)
        status.defaultBranch = refs.defaultBranch(remote: remote)
        if status.onOtherBranch, let main = status.defaultBranch, let local = refs.heads.first(where: { $0.name == main }) {
            status.defaultBehind = local.upstream == "\(remote)/\(main)" ? local.behind
                : (try? run(["rev-list", "--count", "refs/heads/\(main)..refs/remotes/\(remote)/\(main)"], in: repo)).flatMap { Int($0.trimmed) } ?? 0
        }
        status.unpushedBranches = unpushedBranches(of: repo, refs: refs, current: status.upstream == nil ? nil : status.branch)
        if status.behind > 0 {
            status.incoming = incoming(of: repo)
        }
        return status
    }

    /// Références lues d'un coup par for-each-ref : branches locales, branches distantes, origin/HEAD, stash.
    private struct References {
        struct Head { let name: String, upstream: String, gone: Bool, ahead: Int, behind: Int }
        var heads: [Head] = []
        var remoteRefs: Set<String> = []
        var remoteHeads: [String: String] = [:]
        var hasStash = false

        init(_ output: String?) {
            for line in (output ?? "").split(separator: "\n") {
                let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard fields.count == 4 else { continue }
                let (ref, upstream, track, symref) = (fields[0], fields[1], fields[2], fields[3])
                if ref.hasPrefix("refs/heads/") {
                    // « [ahead 3] », « [ahead 3, behind 1] », « [gone] »
                    heads.append(Head(name: String(ref.dropFirst("refs/heads/".count)), upstream: upstream, gone: track.contains("gone"),
                                      ahead: Self.count("ahead", in: track), behind: Self.count("behind", in: track)))
                } else if ref.hasPrefix("refs/remotes/") {
                    let name = String(ref.dropFirst("refs/remotes/".count))
                    if name.hasSuffix("/HEAD") { remoteHeads[String(name.dropLast("/HEAD".count))] = symref } else { remoteRefs.insert(name) }
                } else if ref == "refs/stash" {
                    hasStash = true
                }
            }
        }

        private static func count(_ word: String, in track: String) -> Int {
            guard let range = track.range(of: word + #" \d+"#, options: .regularExpression) else { return 0 }
            return Int(track[range].dropFirst(word.count + 1)) ?? 0
        }

        /// Branche vers laquelle pointe « origin/HEAD », sinon main ou master s'ils existent sur le serveur.
        func defaultBranch(remote: String) -> String? {
            let prefix = "refs/remotes/\(remote)/"
            if let head = remoteHeads[remote], head.hasPrefix(prefix) { return String(head.dropFirst(prefix.count)) }
            return ["main", "master"].first { remoteRefs.contains("\(remote)/\($0)") }
        }
    }

    /// Branches locales avec des commits absents du serveur. `current` : branche courante suivie, déjà comptée.
    private static func unpushedBranches(of repo: URL, refs: References, current: String?) -> [BranchWork] {
        // Sans branche distante récupérée (dépôts gérés par west, par exemple), « absent du serveur » n'a pas de sens.
        let hasRemoteRefs = !refs.remoteRefs.isEmpty || !refs.remoteHeads.isEmpty
        var result: [BranchWork] = []
        // manifest-rev : branche technique de west (Zephyr), jamais poussée.
        for head in refs.heads where head.name != current && head.name != "manifest-rev" {
            if !head.upstream.isEmpty, !head.gone {
                if head.ahead > 0 { result.append(BranchWork(name: head.name, commits: head.ahead, local: false)) }
            } else if hasRemoteRefs,
                      let count = (try? run(["rev-list", "--count", "refs/heads/\(head.name)", "--not", "--remotes"], in: repo)).flatMap({ Int($0.trimmed) }),
                      count > 0 {
                result.append(BranchWork(name: head.name, commits: count, local: true))
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

    /// Remotes du dépôt et leur URL (aussi pour reconnaître les dépôts déjà clonés).
    static func remoteURLs(of repo: URL) -> [(name: String, url: String)] {
        ((try? run(["config", "--get-regexp", #"^remote\..*\.url$"#], in: repo)) ?? "")
            .split(separator: "\n").compactMap { line in
                let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { return nil }
                return (String(parts[0].dropFirst("remote.".count).dropLast(".url".count)), parts[1])
            }
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
