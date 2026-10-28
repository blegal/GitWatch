import SwiftUI

/// Contenu du menu de la barre des menus : présentation « Liste » (A) ou « Par action » (B).
struct MenuView: View {
    @Environment(Monitor.self) private var monitor
    @Environment(Preferences.self) private var preferences
    @Environment(\.openWindow) private var openWindow
    @State private var showUpToDate = false

    private var repos: [Repo] { monitor.followedRepos }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if repos.isEmpty {
                empty
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if preferences.layout == .list { list } else { grouped }
                    }
                    .padding(.vertical, 6)
                }
                .frame(maxHeight: 460)
                .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            footer
        }
        .frame(width: 340)
    }

    // MARK: En-tête et pied

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.branch")
                .font(.title3)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Dépôts Git").font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if monitor.isChecking {
                ProgressView().controlSize(.small)
            } else {
                Button { Task { await monitor.refresh(fetch: true) } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Vérifier maintenant")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var subtitle: String {
        let count = repos.count == 1 ? "1 dépôt" : "\(repos.count) dépôts"
        guard let last = monitor.lastCheck else { return monitor.isChecking ? "Vérification…" : count }
        return "Vérifié \(last.formatted(.relative(presentation: .named))) · \(count)"
    }

    private var footer: some View {
        HStack {
            let pullable = monitor.safelyPullable.count
            Button(pullable > 0 ? "Tout tirer (\(pullable))" : "Tout tirer") { Task { await monitor.pullAll() } }
                .disabled(pullable == 0)
                .help("Tire les dépôts en retard qui n’ont ni commit ni modification locale.")
            Spacer()
            Button("Réglages…") {
                openWindow(id: "settings")
                NSApp.activate()
            }
            Button("Quitter") { NSApp.terminate(nil) }
        }
        .buttonStyle(.borderless)
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "folder.badge.questionmark").font(.largeTitle).foregroundStyle(.tertiary)
            Text(preferences.roots.isEmpty ? "Aucun dossier à explorer" : "Aucun dépôt suivi").font(.headline)
            Text("Choisissez les dossiers où chercher vos dépôts dans les réglages.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(24)
    }

    // MARK: A · Liste

    private var list: some View {
        let counts = Dictionary(grouping: repos, by: RepoCategory.init).mapValues(\.count)
        let sorted = repos.sorted { RepoCategory($0).rawValue < RepoCategory($1).rawValue }
        let visible = showUpToDate ? sorted : sorted.filter { RepoCategory($0) != .upToDate }
        let hidden = sorted.count - visible.count
        return Group {
            HStack(spacing: 6) {
                summaryPill(counts[.upToDate, default: 0] + counts[.pulled, default: 0], "à jour", .green)
                summaryPill(counts[.toPull, default: 0], "à tirer", .orange)
                summaryPill(counts[.toPush, default: 0], "à pousser", .blue)
                summaryPill(counts[.modified, default: 0], "modifié", .indigo)
                summaryPill(counts[.error, default: 0], "erreur", .red)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 6)
            ForEach(visible) { RepoRow(repo: $0, style: .dot) }
            if hidden > 0 { disclosure(hidden) }
        }
    }

    @ViewBuilder
    private func summaryPill(_ count: Int, _ label: String, _ color: Color) -> some View {
        if count > 0 {
            Text("\(count) \(label)")
                .font(.caption)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .foregroundStyle(color)
                .background(color.opacity(0.12), in: .capsule)
        }
    }

    // MARK: B · Par action

    private var grouped: some View {
        let groups = Dictionary(grouping: repos, by: RepoCategory.init)
        return ForEach(RepoCategory.allCases) { category in
            if let members = groups[category], !members.isEmpty {
                Text("\(category.title) · \(members.count)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.top, 8)
                    .padding(.bottom, 2)
                if category == .upToDate && !showUpToDate {
                    disclosure(members.count)
                } else {
                    ForEach(members) { RepoRow(repo: $0, style: .icon) }
                }
            }
        }
    }

    private func disclosure(_ count: Int) -> some View {
        Button {
            withAnimation(.snappy) { showUpToDate.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right").font(.caption2.weight(.semibold))
                Text(preferences.layout == .list ? "\(count) autres à jour" : "Afficher")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// Ligne d'un dépôt dans le menu.
struct RepoRow: View {
    enum Style { case dot, icon }
    let repo: Repo
    let style: Style
    @Environment(Monitor.self) private var monitor
    @State private var hovered = false

    private var category: RepoCategory { RepoCategory(repo) }
    private var status: RepoStatus? { repo.status }

    var body: some View {
        HStack(spacing: 9) {
            marker
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(repo.name).fontWeight(.medium).lineLimit(1)
                    if let branch = status?.branch {
                        Text(branch).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
                if let error = repo.pullError ?? status?.error {
                    Text(error).font(.caption).foregroundStyle(.red).lineLimit(2).help(error)
                }
            }
            Spacer(minLength: 6)
            if monitor.pulling.contains(repo.id) {
                ProgressView().controlSize(.mini)
            } else if hovered, (status?.behind ?? 0) > 0 {
                Button("Tirer") { Task { await monitor.pull(repo) } }
                    .controlSize(.small)
            } else {
                counters
            }
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(hovered ? Color.primary.opacity(0.06) : .clear, in: .rect(cornerRadius: 6))
        .padding(.horizontal, 5)
        .contentShape(.rect)
        .onHover { hovered = $0 }
        .onTapGesture { NSWorkspace.shared.open(repo.url) }
        .contextMenu { RepoActions(repo: repo) }
        .help(repo.url.path)
    }

    @ViewBuilder
    private var marker: some View {
        switch style {
        case .dot:
            Circle().fill(color).frame(width: 7, height: 7).frame(width: 16)
        case .icon:
            Image(systemName: symbol).foregroundStyle(color).frame(width: 16)
        }
    }

    private var color: Color {
        switch category {
        case .error: .red
        case .toPull: .orange
        case .toPush: .blue
        case .modified: .indigo
        case .pulled, .upToDate: .green
        case .unknown: .gray
        }
    }

    private var symbol: String {
        switch category {
        case .error: "exclamationmark.triangle"
        case .toPull: (status?.ahead ?? 0) > 0 ? "arrow.triangle.branch" : "arrow.down.circle"
        case .toPush: "arrow.up.circle"
        case .modified: "pencil.circle"
        case .pulled: "checkmark.circle.fill"
        case .upToDate: "checkmark.circle"
        case .unknown: "circle.dotted"
        }
    }

    private var counters: some View {
        HStack(spacing: 6) {
            if let status {
                if status.behind > 0 { Text("↓\(status.behind)") }
                if status.ahead > 0 { Text("↑\(status.ahead)") }
                if status.added > 0 || status.removed > 0 {
                    HStack(spacing: 3) {
                        Text("+\(status.added)").foregroundStyle(.green)
                        Text("−\(status.removed)").foregroundStyle(.red)
                    }
                } else if status.changedFiles > 0 {
                    Text(status.changedFiles == 1 ? "1 fichier" : "\(status.changedFiles) fichiers")
                }
                if category == .pulled, let date = repo.lastPull {
                    Text("tiré à \(date.formatted(date: .omitted, time: .shortened))").foregroundStyle(.tertiary)
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
}

/// Actions d'un dépôt (menu contextuel du menu et de la fenêtre de réglages).
struct RepoActions: View {
    let repo: Repo
    @Environment(Monitor.self) private var monitor

    var body: some View {
        Button("Tirer (avance rapide)") { Task { await monitor.pull(repo) } }
            .disabled((repo.status?.behind ?? 0) == 0)
        Divider()
        Button("Ouvrir dans le Finder") { NSWorkspace.shared.open(repo.url) }
        Button("Ouvrir dans le Terminal") {
            if let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
                NSWorkspace.shared.open([repo.url], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
            }
        }
        Button("Copier le chemin") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(repo.url.path, forType: .string)
        }
        Divider()
        Button("Ne plus suivre") {
            Preferences.shared.update(repo.id) { $0.followed = false }
        }
    }
}
