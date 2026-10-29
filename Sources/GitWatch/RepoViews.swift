import SwiftUI

extension RepoCategory {
    var color: Color {
        switch self {
        case .error: .red
        case .toPull: .orange
        case .toPush: .blue
        case .modified: .indigo
        case .pulled, .upToDate: .green
        case .unknown: .gray
        }
    }

    func symbol(_ repo: Repo) -> String {
        switch self {
        case .error: "exclamationmark.triangle"
        case .toPull: (repo.status?.ahead ?? 0) > 0 ? "arrow.triangle.branch" : "arrow.down.circle"
        case .toPush: "arrow.up.circle"
        case .modified: "pencil.circle"
        case .pulled: "checkmark.circle.fill"
        case .upToDate: "checkmark.circle"
        case .unknown: "circle.dotted"
        }
    }
}

/// Branche courante ; en orange quand ce n'est pas la branche par défaut, avec le retard de celle-ci.
struct BranchLabel: View {
    let status: RepoStatus

    var body: some View {
        if let branch = status.branch {
            HStack(spacing: 3) {
                Text(branch).foregroundStyle(status.onOtherBranch ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
                if status.onOtherBranch, status.defaultBehind > 0, let main = status.defaultBranch {
                    Text("· \(main) ↓\(status.defaultBehind)").foregroundStyle(.orange)
                }
            }
            .font(.caption)
            .lineLimit(1)
            .help(status.onOtherBranch ? "Vous n’êtes pas sur \(status.defaultBranch ?? "la branche par défaut")."
                  + (status.defaultBehind > 0 ? " \(status.defaultBranch ?? "") a \(status.defaultBehind) commit(s) à récupérer." : "") : branch)
        }
    }
}

/// Compteurs d'un dépôt : retard, avance, lignes modifiées, fichiers non suivis, stashes, autres branches.
struct RepoCounters: View {
    let repo: Repo

    var body: some View {
        HStack(spacing: 6) {
            if let status = repo.status {
                let category = RepoCategory(repo)
                if status.behind > 0 { Text("↓\(status.behind)") }
                if status.ahead > 0 { Text("↑\(status.ahead)") }
                if status.added > 0 || status.removed > 0 {
                    HStack(spacing: 3) {
                        Text("+\(status.added)").foregroundStyle(.green)
                        Text("−\(status.removed)").foregroundStyle(.red)
                    }
                } else if status.changedFiles > status.untracked {
                    let n = status.changedFiles - status.untracked
                    Text(n == 1 ? "1 fichier" : "\(n) fichiers")
                }
                if status.untracked > 0 {
                    item("doc.badge.plus", status.untracked, status.untracked == 1 ? "1 fichier non suivi" : "\(status.untracked) fichiers non suivis")
                }
                if status.stashes > 0 {
                    item("tray.full", status.stashes, status.stashes == 1 ? "1 stash en attente" : "\(status.stashes) stashes en attente")
                }
                if !status.unpushedBranches.isEmpty {
                    item("arrow.triangle.branch", status.unpushedBranches.count, RepoSummary.branches(status))
                }
                if category == .pulled, let date = repo.lastPull {
                    Text("pull à \(date.formatted(date: .omitted, time: .shortened))").foregroundStyle(.tertiary)
                } else if category == .upToDate, status.upstream == nil {
                    Text("sans amont").foregroundStyle(.tertiary)
                }
            }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .lineLimit(1)
        // Les compteurs gardent toujours leur largeur : c'est le nom qui se tronque.
        .fixedSize()
    }

    private func item(_ symbol: String, _ count: Int, _ help: String) -> some View {
        HStack(spacing: 2) {
            Image(systemName: symbol).imageScale(.small)
            Text("\(count)")
        }
        .help(help)
    }
}

/// Textes décrivant un dépôt (bulles d'aide, panneau de détail).
enum RepoSummary {
    static func tooltip(_ repo: Repo) -> String {
        var lines = [repo.url.path]
        guard let status = repo.status else { return lines[0] }
        if !status.incoming.isEmpty {
            lines.append("")
            lines.append("À récupérer :")
            lines += status.incoming.map { "• \($0.subject) — \($0.author)" }
            if status.behind > status.incoming.count { lines.append("• … et \(status.behind - status.incoming.count) autres") }
        }
        if !status.unpushedBranches.isEmpty {
            lines.append("")
            lines.append(branches(status))
        }
        if status.stashes > 0 {
            lines.append(status.stashes == 1 ? "1 stash en attente" : "\(status.stashes) stashes en attente")
        }
        if status.untracked > 0 {
            lines.append(status.untracked == 1 ? "1 fichier non suivi" : "\(status.untracked) fichiers non suivis")
        }
        return lines.joined(separator: "\n")
    }

    static func branches(_ status: RepoStatus) -> String {
        "Commits non poussés : " + status.unpushedBranches.map { branch in
            "\(branch.name) (\(branch.commits)\(branch.local ? ", locale" : ""))"
        }.joined(separator: ", ")
    }

    /// « GitHub », « GitLab » ou le nom d'hôte.
    static func hostName(_ url: URL) -> String {
        let host = url.host ?? ""
        if host.contains("github") { return "GitHub" }
        if host.contains("gitlab") { return "GitLab" }
        return host
    }
}
