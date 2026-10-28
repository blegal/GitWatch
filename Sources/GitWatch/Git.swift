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
    /// Erreur du dernier fetch (réseau, identifiants…).
    var error: String?

    var isClean: Bool { changedFiles == 0 }
}

/// Appels à git (l'exécutable du système : identifiants, clés SSH et trousseau de l'utilisateur).
enum Git {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Exécute git dans `repo`. Jamais de demande interactive : sans identifiants, la commande échoue.
    @discardableResult
    static func run(_ arguments: [String], in repo: URL, timeout: TimeInterval = 30) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
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
        try process.run()

        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        // Lecture avant waitUntilExit : une sortie volumineuse bloquerait sinon le processus.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        killer.cancel()

        guard process.terminationStatus == 0 else {
            if process.terminationReason == .uncaughtSignal { throw Failure(message: "Délai dépassé (\(Int(timeout)) s).") }
            let message = String(decoding: errorData, as: UTF8.self)
                .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty && !$0.hasPrefix("hint:") } ?? "git \(arguments.first ?? "") a échoué."
            throw Failure(message: message.replacingOccurrences(of: "fatal: ", with: ""))
        }
        return String(decoding: data, as: UTF8.self)
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
            }
        }
        if status.changedFiles > 0 {
            // Échoue sans commit initial : on garde alors 0.
            (status.added, status.removed) = (try? run(["diff", "HEAD", "--shortstat"], in: repo)).map(parseShortStat) ?? (0, 0)
        }
        return status
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

    /// Tirage sûr : avance rapide uniquement, sur l'amont déjà récupéré par fetch.
    static func fastForward(_ repo: URL) throws {
        try run(["merge", "--ff-only", "--quiet", "@{upstream}"], in: repo, timeout: 60)
    }
}
