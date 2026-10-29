import SwiftUI
import UpdateKit

/// Contenu du menu de la barre des menus : présentation « Liste » (A) ou « Par action » (B).
struct MenuView: View {
    @Environment(Monitor.self) private var monitor
    @Environment(Preferences.self) private var preferences
    @Environment(WindowRouter.self) private var router
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
            Button { show(.dashboard) } label: { Image(systemName: "macwindow") }
                .buttonStyle(.borderless)
                .help("Ouvrir le tableau de bord")
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
            let pushable = monitor.pushable.count
            Button { Task { await monitor.pullAll() } } label: {
                Label(pullable > 0 ? "Pull all (\(pullable))" : "Pull all", systemImage: "arrow.down")
            }
            .disabled(pullable == 0)
            .help("Pull des dépôts en retard qui n’ont ni commit ni modification locale.")
            Button { Task { await monitor.pushAll() } } label: {
                Label(pushable > 0 ? "Push all (\(pushable))" : "Push all", systemImage: "arrow.up")
            }
            .disabled(pushable == 0)
            .help("Push des dépôts en avance et à jour avec le serveur.")
            Spacer()
            HStack(spacing: 12) {
                UpdateIndicator()
                Button { show(.settings) } label: { Image(systemName: "gearshape") }
                    .help("Réglages…")
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                    .help("Quitter GitWatch")
            }
            .imageScale(.large)
        }
        .buttonStyle(.borderless)
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private func show(_ tab: WindowRouter.Tab) {
        router.tab = tab
        openWindow(id: "main")
        NSApp.activate()
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
                summaryPill(counts[.toPull, default: 0], "pull", .orange)
                summaryPill(counts[.toPush, default: 0], "push", .blue)
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
                    if let status { BranchLabel(status: status) }
                }
                if let error = status?.error {
                    Text(error).font(.caption).foregroundStyle(.red).lineLimit(2).help(error)
                } else if let error = repo.pullError {
                    Text(error).font(.caption).foregroundStyle(.orange).lineLimit(2).help(error)
                }
            }
            Spacer(minLength: 6)
            if monitor.busy.contains(repo.id) {
                ProgressView().controlSize(.mini)
            } else if hovered, let action = quickAction {
                action
            } else {
                RepoCounters(repo: repo)
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
        .help(RepoSummary.tooltip(repo))
    }

    /// Boutons proposés au survol. Dépôt modifié : Pull ou Push s'ils sont possibles, puis VS Code, GitHub Desktop, Claude.
    /// Sinon : Pull, Push, ou GitHub Desktop quand une fusion manuelle est nécessaire.
    private var quickAction: AnyView? {
        guard let status else { return nil }
        let canPush = status.ahead > 0 && status.behind == 0 && status.upstream != nil
        let tools = ExternalTool.allCases.filter(\.isAvailable)
        if status.hasLocalWork, !tools.isEmpty {
            return AnyView(HStack(spacing: 4) {
                // Pull reste possible : git refuse seulement si des fichiers modifiés sont touchés.
                if status.behind > 0, status.ahead == 0 {
                    Button { Task { await monitor.pull(repo) } } label: { Image(systemName: "arrow.down") }
                        .buttonStyle(.borderless).help("Pull (avance rapide)")
                }
                if canPush {
                    Button { Task { await monitor.push(repo) } } label: { Image(systemName: "arrow.up") }
                        .buttonStyle(.borderless).help("Push")
                }
                ForEach(tools) { tool in
                    Button { tool.open(repo.url) } label: {
                        Image(nsImage: tool.icon).resizable().frame(width: 18, height: 18)
                    }
                    .buttonStyle(.borderless)
                    .help(tool.help)
                }
            })
        }
        if status.behind > 0, status.ahead > 0 || repo.pullError != nil, ExternalTool.githubDesktop.isAvailable {
            return AnyView(Button { ExternalTool.githubDesktop.open(repo.url) } label: { Label("Desktop", systemImage: "arrow.triangle.merge") }
                .controlSize(.small).help("Fusion manuelle dans GitHub Desktop"))
        }
        if status.behind > 0, status.ahead == 0 {
            return AnyView(Button { Task { await monitor.pull(repo) } } label: { Label("Pull", systemImage: "arrow.down") }
                .controlSize(.small))
        }
        if canPush {
            return AnyView(Button { Task { await monitor.push(repo) } } label: { Label("Push", systemImage: "arrow.up") }
                .controlSize(.small))
        }
        return nil
    }

    @ViewBuilder
    private var marker: some View {
        switch style {
        case .dot:
            Circle().fill(category.color).frame(width: 7, height: 7).frame(width: 16)
        case .icon:
            Image(systemName: category.symbol(repo)).foregroundStyle(category.color).frame(width: 16)
        }
    }
}

/// Actions d'un dépôt (menu contextuel du menu et de la fenêtre de réglages).
struct RepoActions: View {
    let repo: Repo
    @Environment(Monitor.self) private var monitor

    var body: some View {
        Button { Task { await monitor.pull(repo) } } label: { Label("Pull (avance rapide)", systemImage: "arrow.down") }
            .disabled((repo.status?.behind ?? 0) == 0)
        Button { Task { await monitor.push(repo) } } label: { Label("Push", systemImage: "arrow.up") }
            .disabled((repo.status?.ahead ?? 0) == 0 || repo.status?.upstream == nil)
        if let incoming = repo.status?.incoming, !incoming.isEmpty {
            Menu("Commits à récupérer (\(repo.status?.behind ?? incoming.count))") {
                ForEach(incoming) { Text("\($0.subject) — \($0.author)") }
            }
        }
        Divider()
        ForEach(ExternalTool.allCases.filter(\.isAvailable)) { tool in
            Button(tool.help) { tool.open(repo.url) }
        }
        Button("Ouvrir dans le Finder") { NSWorkspace.shared.open(repo.url) }
        Button("Ouvrir dans le Terminal") {
            if let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
                NSWorkspace.shared.open([repo.url], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
            }
        }
        if let web = repo.status?.webURL {
            Button("Ouvrir sur \(RepoSummary.hostName(web))") { NSWorkspace.shared.open(web) }
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

/// Applications proposées pour travailler sur un dépôt modifié.
enum ExternalTool: String, CaseIterable, Identifiable {
    case vscode, zed, githubDesktop, claude
    var id: String { rawValue }

    var help: String {
        switch self {
        case .vscode: "Ouvrir dans VS Code"
        case .zed: "Ouvrir dans Zed"
        case .githubDesktop: "Ouvrir dans GitHub Desktop"
        case .claude: "Ouvrir Claude Code dans le Terminal"
        }
    }

    private var bundleIdentifier: String {
        switch self {
        case .vscode: "com.microsoft.VSCode"
        case .zed: "dev.zed.Zed"
        case .githubDesktop: "com.github.GitHubClient"
        case .claude: "com.anthropic.claudefordesktop"
        }
    }

    /// Application et icône, cherchées une fois puis gardées : chaque ligne du menu les demande à chaque affichage.
    /// `reload()` (à chaque vérification) prend en compte les applications installées ou supprimées depuis.
    @MainActor private static var cache: [ExternalTool: (application: URL?, icon: NSImage)] = [:]

    @MainActor static func reload() { cache.removeAll() }

    @MainActor private var resolved: (application: URL?, icon: NSImage) {
        if let cached = Self.cache[self] { return cached }
        let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        // Pour Claude, icône de l'app Claude si elle est installée, sinon celle du Terminal.
        let iconSource = application ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal")
        let icon = iconSource.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSImage()
        icon.size = NSSize(width: 20, height: 20)
        Self.cache[self] = (application, icon)
        return (application, icon)
    }

    @MainActor private var application: URL? { resolved.application }

    /// Claude Code (ligne de commande) : emplacements d'installation habituels.
    private static let claudeCommand: String? = {
        let home = NSHomeDirectory()
        return ["/opt/homebrew/bin/claude", "/usr/local/bin/claude", home + "/.local/bin/claude", home + "/.claude/local/claude"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    @MainActor var isAvailable: Bool { self == .claude ? Self.claudeCommand != nil : application != nil }

    @MainActor var icon: NSImage { resolved.icon }

    @MainActor func open(_ repo: URL) {
        if self == .claude {
            openClaude(in: repo)
        } else if let application {
            NSWorkspace.shared.open([repo], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    /// Un script .command s'ouvre dans le Terminal : il se place dans le dépôt et lance claude
    /// (shell de connexion, pour retrouver le PATH de l'utilisateur), puis s'efface.
    private func openClaude(in repo: URL) {
        guard let command = Self.claudeCommand else { return }
        func quoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("claude-\(repo.lastPathComponent)-\(UUID().uuidString.prefix(8)).command")
        let content = "#!/bin/zsh -l\nrm -f \"$0\"\ncd \(quoted(repo.path)) && exec \(quoted(command))\n"
        do {
            try content.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            NSWorkspace.shared.open(script)
        } catch {
            NSLog("GitWatch : lancement de Claude impossible : \(error.localizedDescription)")
        }
    }
}

/// État de la mise à jour : rechercher, version disponible (vert), installation et redémarrage (jaune).
struct UpdateIndicator: View {
    @State private var state = Updater.shared.state

    var body: some View {
        Button {
            Updater.shared.checkForUpdates(nil)
            NSApp.activate()
        } label: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
        .disabled(state == .checking)
        .help(help)
        .onReceive(NotificationCenter.default.publisher(for: Updater.stateDidChange)) { _ in
            state = Updater.shared.state
        }
    }

    private var symbol: String {
        switch state {
        case .idle, .checking: "arrow.trianglehead.clockwise"
        case .available: "arrow.down.circle.fill"
        case .installing: "arrow.triangle.2.circlepath.circle.fill"
        }
    }

    private var tint: Color {
        switch state {
        case .idle: .secondary
        case .checking: Color(nsColor: .tertiaryLabelColor)
        case .available: .green
        case .installing: .yellow
        }
    }

    private var help: String {
        switch state {
        case .idle: "Rechercher les mises à jour (version \(Updater.shared.currentVersion))"
        case .checking: "Recherche des mises à jour…"
        case .available(let version): "Version \(version) disponible : cliquer pour l’installer"
        case .installing: "Installation de la mise à jour, puis redémarrage…"
        }
    }
}
