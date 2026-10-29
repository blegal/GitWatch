import SwiftUI

/// Onglet « Tableau de bord » de la fenêtre : le contenu du menu en grand, avec un panneau de détail.
struct DashboardView: View {
    @Environment(Monitor.self) private var monitor
    @State private var filter: RepoCategory? = nil
    @State private var showAll = true
    @State private var selection: Set<String> = []
    @State private var search = ""

    private var repos: [Repo] {
        monitor.followedRepos
            .filter { showAll || filter == nil || RepoCategory($0) == filter }
            .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.displayPath.localizedCaseInsensitiveContains(search) }
            .sorted { (RepoCategory($0).rawValue, $0.name.lowercased()) < (RepoCategory($1).rawValue, $1.name.lowercased()) }
    }

    private var selectedRepos: [Repo] { monitor.followedRepos.filter { selection.contains($0.id) } }

    var body: some View {
        NavigationSplitView {
            sidebar.navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } content: {
            content.navigationSplitViewColumnWidth(min: 340, ideal: 440)
        } detail: {
            detail
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Filtrer")
        .toolbar {
            ToolbarItemGroup {
                let pullable = monitor.safelyPullable.count
                let pushable = monitor.pushable.count
                Button { Task { await monitor.pullAll() } } label: { Label(pullable > 0 ? "Pull all (\(pullable))" : "Pull all", systemImage: "arrow.down") }
                    .labelStyle(.titleAndIcon)
                    .disabled(pullable == 0)
                    .help("Pull des dépôts en retard qui n’ont ni commit ni modification locale.")
                Button { Task { await monitor.pushAll() } } label: { Label(pushable > 0 ? "Push all (\(pushable))" : "Push all", systemImage: "arrow.up") }
                    .labelStyle(.titleAndIcon)
                    .disabled(pushable == 0)
                    .help("Push des dépôts en avance et à jour avec le serveur.")
                if monitor.isChecking {
                    ProgressView().controlSize(.small)
                } else {
                    Button { Task { await monitor.refresh(fetch: true) } } label: { Label("Vérifier", systemImage: "arrow.clockwise") }
                        .help("Vérifier maintenant")
                }
            }
        }
    }

    // MARK: Colonnes

    private var sidebar: some View {
        let counts = Dictionary(grouping: monitor.followedRepos, by: RepoCategory.init).mapValues(\.count)
        return List(selection: Binding(get: { showAll ? nil : filter }, set: { showAll = $0 == nil; filter = $0 })) {
            Label("Tous les dépôts", systemImage: "tray.2")
                .badge(monitor.followedRepos.count)
                .tag(RepoCategory?.none)
            Section("État") {
                ForEach(RepoCategory.allCases) { category in
                    if let count = counts[category], count > 0 {
                        Label { Text(category.title) } icon: {
                            Image(systemName: category.sidebarSymbol).foregroundStyle(category.color)
                        }
                        .badge(count)
                        .tag(RepoCategory?.some(category))
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private var content: some View {
        List(repos, selection: $selection) { repo in
            DashboardRow(repo: repo).contextMenu { RepoActions(repo: repo) }
        }
        .overlay {
            if repos.isEmpty {
                ContentUnavailableView(search.isEmpty ? "Aucun dépôt" : "Aucun résultat", systemImage: "checkmark.circle",
                                       description: Text(search.isEmpty ? "Rien à signaler dans cette catégorie." : "Aucun dépôt ne correspond au filtre."))
            }
        }
        .navigationTitle(showAll || filter == nil ? "Tous les dépôts" : filter!.title)
        .navigationSubtitle(monitor.lastCheck.map { "Vérifié \($0.formatted(.relative(presentation: .named)))" } ?? "")
    }

    @ViewBuilder
    private var detail: some View {
        let selected = selectedRepos
        if selected.count == 1, let repo = selected.first {
            RepoDetail(repo: repo)
        } else if selected.count > 1 {
            SelectionSummary(repos: selected)
        } else {
            ContentUnavailableView("Aucune sélection", systemImage: "sidebar.right",
                                   description: Text("Sélectionnez un dépôt pour voir ses commits à récupérer, ses branches et ses stashes."))
        }
    }
}

extension RepoCategory {
    var sidebarSymbol: String {
        switch self {
        case .error: "exclamationmark.triangle"
        case .toPull: "arrow.down.circle"
        case .toPush: "arrow.up.circle"
        case .modified: "pencil.circle"
        case .pulled: "checkmark.circle.fill"
        case .upToDate: "checkmark.circle"
        case .unknown: "circle.dotted"
        }
    }
}

/// Ligne d'un dépôt dans le tableau de bord : boutons toujours visibles.
struct DashboardRow: View {
    let repo: Repo

    var body: some View {
        let category = RepoCategory(repo)
        HStack(spacing: 10) {
            Image(systemName: category.symbol(repo)).foregroundStyle(category.color).font(.title3).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(repo.name).fontWeight(.medium).lineLimit(1)
                    if let status = repo.status { BranchLabel(status: status) }
                }
                if let error = repo.status?.error {
                    Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
                } else if let error = repo.pullError {
                    Text(error).font(.caption).foregroundStyle(.orange).lineLimit(2)
                } else if let commit = repo.status?.incoming.first {
                    Text("↓ \(commit.subject)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Text(repo.displayPath).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            RepoCounters(repo: repo)
            RepoSyncButtons(repo: repo)
        }
        .padding(.vertical, 3)
        .help(RepoSummary.tooltip(repo))
    }
}

/// Pull, Push ou fusion dans GitHub Desktop selon l'état du dépôt.
struct RepoSyncButtons: View {
    let repo: Repo
    var bordered = false
    @Environment(Monitor.self) private var monitor

    var body: some View {
        if monitor.busy.contains(repo.id) {
            ProgressView().controlSize(.small).frame(width: 40)
        } else if let status = repo.status {
            let canPull = status.behind > 0 && status.ahead == 0
            let canPush = status.ahead > 0 && status.behind == 0 && status.upstream != nil
            let needsMerge = status.behind > 0 && (status.ahead > 0 || repo.pullError != nil)
            HStack(spacing: 6) {
                if canPull {
                    button("Pull", "arrow.down", help: "Pull (avance rapide)") { Task { await monitor.pull(repo) } }
                }
                if canPush {
                    button("Push", "arrow.up", help: "Push") { Task { await monitor.push(repo) } }
                }
                if needsMerge, ExternalTool.githubDesktop.isAvailable {
                    button("Fusionner", "arrow.triangle.merge", help: "Fusion manuelle dans GitHub Desktop") { ExternalTool.githubDesktop.open(repo.url) }
                }
            }
        }
    }

    @ViewBuilder
    private func button(_ title: String, _ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        if bordered {
            Button(action: action) { Label(title, systemImage: symbol) }.help(help)
        } else {
            Button(action: action) { Label(title, systemImage: symbol) }.controlSize(.small).help(help)
        }
    }
}

/// Panneau de détail d'un dépôt.
struct RepoDetail: View {
    let repo: Repo

    var body: some View {
        let category = RepoCategory(repo)
        Form {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: category.symbol(repo)).font(.largeTitle).foregroundStyle(category.color)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(repo.name).font(.title2.weight(.semibold))
                        Text((repo.url.path as NSString).abbreviatingWithTildeInPath).font(.callout).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Spacer()
                }
                HStack(spacing: 8) {
                    RepoSyncButtons(repo: repo, bordered: true)
                    Spacer()
                    ForEach(ExternalTool.allCases.filter(\.isAvailable)) { tool in
                        Button { tool.open(repo.url) } label: { Image(nsImage: tool.icon).resizable().frame(width: 20, height: 20) }
                            .buttonStyle(.borderless).help(tool.help)
                    }
                    Button { NSWorkspace.shared.open(repo.url) } label: { Image(systemName: "folder") }
                        .buttonStyle(.borderless).help("Ouvrir dans le Finder")
                    if let web = repo.status?.webURL {
                        Button { NSWorkspace.shared.open(web) } label: { Image(systemName: "safari") }
                            .buttonStyle(.borderless).help("Ouvrir sur \(RepoSummary.hostName(web))")
                    }
                }
            }
            if let error = repo.status?.error ?? repo.pullError {
                Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(repo.status?.error != nil ? .red : .orange) }
            }
            if let status = repo.status {
                Section("État") {
                    LabeledContent("Branche") {
                        Text("\(status.branch ?? "détachée")\(status.onOtherBranch ? " (pas sur \(status.defaultBranch ?? ""))" : "")")
                    }
                    if status.onOtherBranch, status.defaultBehind > 0, let main = status.defaultBranch {
                        LabeledContent(main) { Text("↓\(status.defaultBehind) à récupérer").foregroundStyle(.orange) }
                    }
                    LabeledContent("Suit", value: status.upstream ?? "aucune branche distante")
                    if status.ahead > 0 || status.behind > 0 {
                        LabeledContent("Serveur", value: [status.behind > 0 ? "↓\(status.behind) à récupérer" : nil,
                                                         status.ahead > 0 ? "↑\(status.ahead) à envoyer" : nil].compactMap { $0 }.joined(separator: " · "))
                    }
                    LabeledContent("Modifications") {
                        if status.isClean { Text("aucune") } else {
                            HStack(spacing: 4) {
                                Text("\(status.changedFiles - status.untracked) modifié(s), \(status.untracked) non suivi(s) ·")
                                Text("+\(status.added)").foregroundStyle(.green)
                                Text("−\(status.removed)").foregroundStyle(.red)
                            }
                        }
                    }
                    if status.stashes > 0 { LabeledContent("Stashes", value: "\(status.stashes)") }
                }
                if !status.incoming.isEmpty {
                    Section(status.behind > status.incoming.count ? "À récupérer (\(status.incoming.count) derniers sur \(status.behind))" : "À récupérer") {
                        ForEach(status.incoming) { commit in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(commit.subject).lineLimit(2)
                                Text("\(commit.hash) · \(commit.author) · \(commit.date.formatted(.relative(presentation: .named)))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if !status.unpushedBranches.isEmpty {
                    Section("Commits non poussés sur d’autres branches") {
                        ForEach(status.unpushedBranches) { branch in
                            LabeledContent(branch.name, value: "\(branch.commits) commit\(branch.commits > 1 ? "s" : "")"
                                           + (branch.local ? " · branche locale" : ""))
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Plusieurs dépôts sélectionnés : actions groupées.
struct SelectionSummary: View {
    let repos: [Repo]
    @Environment(Monitor.self) private var monitor

    var body: some View {
        let pullable = repos.filter { monitor.safelyPullable.map(\.id).contains($0.id) }
        let pushable = repos.filter { monitor.pushable.map(\.id).contains($0.id) }
        VStack(spacing: 14) {
            Image(systemName: "square.stack.3d.up").font(.system(size: 40)).foregroundStyle(.secondary)
            Text("\(repos.count) dépôts sélectionnés").font(.title3.weight(.semibold))
            HStack {
                Button { Task { await monitor.pullAll(pullable) } } label: { Label("Pull (\(pullable.count))", systemImage: "arrow.down") }
                    .disabled(pullable.isEmpty)
                Button { Task { await monitor.pushAll(pushable) } } label: { Label("Push (\(pushable.count))", systemImage: "arrow.up") }
                    .disabled(pushable.isEmpty)
            }
            .controlSize(.large)
            Text("Pull en avance rapide pour les dépôts sans commit ni modification locale ; Push pour ceux en avance et à jour avec le serveur.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 320)
        }
        .padding()
    }
}
