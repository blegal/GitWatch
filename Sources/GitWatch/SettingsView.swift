import SwiftUI
import UpdateKit

/// Fenêtre de l'application : dépôts, dossiers explorés, réglages généraux.
struct SettingsView: View {
    enum Pane: String, CaseIterable, Identifiable {
        case repos, folders, remote, appearance, general
        var id: String { rawValue }
        var title: String {
            switch self {
            case .repos: L("Dépôts")
            case .folders: L("Dossiers")
            case .remote: L("À cloner")
            case .appearance: L("Apparence")
            case .general: L("Général")
            }
        }
        var symbol: String {
            switch self {
            case .repos: "arrow.triangle.branch"
            case .folders: "folder.badge.gearshape"
            case .remote: "icloud.and.arrow.down"
            case .appearance: "textformat"
            case .general: "gearshape"
            }
        }
    }

    @Environment(WindowRouter.self) private var router

    var body: some View {
        NavigationSplitView {
            @Bindable var router = router
            List(Pane.allCases, selection: $router.pane) { pane in
                Label(pane.title, systemImage: pane.symbol).tag(pane)
            }
            .navigationSplitViewColumnWidth(170)
        } detail: {
            switch router.pane {
            case .repos: ReposPane()
            case .folders: FoldersPane()
            case .remote: RemotePane()
            case .appearance: AppearancePane()
            case .general: GeneralPane()
            }
        }
    }
}

// MARK: - Dépôts

struct ReposPane: View {
    @Environment(Monitor.self) private var monitor
    @Environment(Preferences.self) private var preferences
    @State private var filter = ""
    @State private var selection: Set<String> = []

    private var repos: [Repo] {
        let all = monitor.repos
        guard !filter.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(filter) || $0.displayPath.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        Table(repos, selection: $selection) {
            TableColumn(L("Dépôt")) { repo in
                VStack(alignment: .leading, spacing: 1) {
                    Text(repo.name).fontWeight(.medium)
                    Text(location(repo)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .opacity(preferences.settings(for: repo.id).followed ? 1 : 0.5)
                .contextMenu { RepoActions(repo: repo) }
            }
            .width(min: 200, ideal: 300)
            TableColumn(L("État")) { repo in StateLabel(repo: repo, followed: preferences.settings(for: repo.id).followed) }
                .width(min: 110, ideal: 140)
            TableColumn(L("Suivre")) { repo in
                Toggle(L("Suivre"), isOn: binding(repo.id, \.followed)).labelsHidden().toggleStyle(.switch).controlSize(.mini)
            }
            .width(56)
            TableColumn("Auto-pull") { repo in
                Toggle(L("Tirer automatiquement"), isOn: binding(repo.id, \.autoPull))
                    .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                    .disabled(!preferences.settings(for: repo.id).followed)
            }
            .width(64)
        }
        .searchable(text: $filter, placement: .toolbar, prompt: L("Filtrer"))
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text(L("L’auto-pull se fait en avance rapide, seulement sans commit ni modification locale."))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(monitor.repos.count == 1 ? L("1 dépôt") : L("\(monitor.repos.count) dépôts")).font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .toolbar {
            ToolbarItemGroup {
                Menu {
                    Button(L("Suivre la sélection")) { setSelected(\.followed, true) }
                    Button(L("Ne plus suivre la sélection")) { setSelected(\.followed, false) }
                    Divider()
                    Button(L("Activer l’auto-pull")) { setSelected(\.autoPull, true) }
                    Button(L("Désactiver l’auto-pull")) { setSelected(\.autoPull, false) }
                } label: { Label(L("Sélection"), systemImage: "checklist") }
                .disabled(selection.isEmpty)
                Button {
                    Task { await monitor.refresh(fetch: true) }
                } label: { Label(L("Vérifier"), systemImage: "arrow.clockwise") }
                .disabled(monitor.isChecking)
            }
        }
        .navigationTitle(L("Dépôts"))
    }

    private func location(_ repo: Repo) -> String {
        var parts = [repo.displayPath]
        if let branch = repo.status?.branch {
            parts.append(repo.status?.upstream.map { "\(branch) → \($0)" } ?? branch)
        }
        return parts.joined(separator: " · ")
    }

    private func binding(_ path: String, _ key: WritableKeyPath<RepoSettings, Bool>) -> Binding<Bool> {
        Binding(get: { preferences.settings(for: path)[keyPath: key] },
                set: { value in
                    preferences.update(path) { $0[keyPath: key] = value }
                    // Un dépôt nouvellement suivi est vérifié sans attendre (sans fetch).
                    if key == \.followed, value { Task { await monitor.refresh(fetch: false) } }
                })
    }

    private func setSelected(_ key: WritableKeyPath<RepoSettings, Bool>, _ value: Bool) {
        for path in selection { preferences.update(path) { $0[keyPath: key] = value } }
        Task { await monitor.refresh(fetch: false) }
    }
}

/// Résumé de l'état d'un dépôt dans le tableau.
struct StateLabel: View {
    let repo: Repo
    let followed: Bool

    var body: some View {
        let (text, color) = describe()
        Text(text).font(.callout).foregroundStyle(color).lineLimit(1)
            .help(repo.status?.error ?? repo.pullError ?? text)
    }

    private func describe() -> (String, Color) {
        guard followed else { return (L("Non suivi"), .secondary) }
        guard let status = repo.status else { return ("—", .secondary) }
        switch RepoCategory(repo) {
        case .error: return (L("Erreur"), .red)
        case .toPull: return (status.ahead > 0 ? L("↓\(status.behind) ↑\(status.ahead) divergé") : "↓\(status.behind) pull", .orange)
        case .toPush: return ("↑\(status.ahead) push", .blue)
        case .modified:
            if !status.isClean { return ("+\(status.added) −\(status.removed)", .indigo) }
            return (status.stashes > 0 ? L("Stash en attente") : L("Branche non poussée"), .indigo)
        case .pulled: return (L("Pull aujourd’hui"), .green)
        case .upToDate: return (status.upstream == nil ? L("Sans amont") : L("À jour"), status.upstream == nil ? .secondary : .green)
        case .unknown: return ("—", .secondary)
        }
    }
}

// MARK: - Dossiers

struct FoldersPane: View {
    @Environment(Monitor.self) private var monitor
    @Environment(Preferences.self) private var preferences
    @State private var selection: String?

    var body: some View {
        @Bindable var preferences = preferences
        Form {
            Section {
                if preferences.roots.isEmpty {
                    Text(L("Aucun dossier. Ajoutez les dossiers qui contiennent vos dépôts.")).foregroundStyle(.secondary)
                }
                ForEach($preferences.roots) { $root in
                    HStack(spacing: 10) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: root.path)).resizable().frame(width: 22, height: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text((root.path as NSString).abbreviatingWithTildeInPath)
                            Text(count(root)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(L("Profondeur \(root.depth)")).monospacedDigit().foregroundStyle(.secondary)
                        Stepper(L("Profondeur"), value: $root.depth, in: 0...6)
                            .labelsHidden()
                            .onChange(of: root.depth) { Task { await monitor.refresh(fetch: false) } }
                        Button { remove(root) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .help(L("Retirer ce dossier"))
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text(L("Dossiers explorés"))
            } footer: {
                HStack {
                    Text(L("La profondeur indique sur combien de niveaux chercher des dépôts sous chaque dossier."))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(L("Ajouter un dossier…"), action: add)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(L("Dossiers"))
    }

    private func count(_ root: SearchRoot) -> String {
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        let n = monitor.repos.filter { $0.id == root.path || $0.id.hasPrefix(prefix) }.count
        return n == 1 ? L("1 dépôt") : L("\(n) dépôts")
    }

    private func add() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = L("Ajouter")
        panel.message = L("Choisissez les dossiers qui contiennent vos dépôts Git.")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !preferences.roots.contains(where: { $0.path == url.path }) {
            preferences.roots.append(SearchRoot(path: url.path, depth: 2))
        }
        Task { await monitor.refresh(fetch: true) }
    }

    private func remove(_ root: SearchRoot) {
        preferences.roots.removeAll { $0.path == root.path }
        Task { await monitor.refresh(fetch: false) }
    }
}

// MARK: - Général

struct GeneralPane: View {
    @Environment(Monitor.self) private var monitor
    @Environment(Preferences.self) private var preferences
    @State private var launchAtLogin = Preferences.shared.launchAtLogin
    @State private var language = AppLanguage.chosen
    @State private var askRelaunch = false

    var body: some View {
        @Bindable var preferences = preferences
        Form {
            Section {
                Picker(L("Langue"), selection: $language) {
                    ForEach(AppLanguage.allCases) { Text($0.title).tag($0) }
                }
                .onChange(of: language) { _, value in
                    guard value != AppLanguage.chosen else { return }
                    AppLanguage.chosen = value
                    askRelaunch = true
                }
            }
            Section(L("Vérification")) {
                Picker(L("Vérifier toutes les"), selection: $preferences.interval) {
                    ForEach(Preferences.intervals, id: \.self) { minutes in
                        Text(minutes < 60 ? L("\(minutes) minutes") : minutes == 60 ? L("heure") : L("\(minutes / 60) heures")).tag(minutes)
                    }
                }
                .onChange(of: preferences.interval) { monitor.schedule() }
            }
            Section(L("Menu")) {
                Picker(L("Présentation"), selection: $preferences.layout) {
                    ForEach(MenuLayout.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle(L("Afficher le nombre de pull à faire dans la barre des menus"), isOn: $preferences.showBadge)
            }
            Section(L("Notifications")) {
                Toggle(L("Quand un pull est à faire (nouveaux commits sur le serveur)"), isOn: $preferences.notifyBehind)
                Toggle(L("Après un auto-pull"), isOn: $preferences.notifyAutoPull)
            }
            .onChange(of: preferences.notifyBehind || preferences.notifyAutoPull) { _, on in
                if on { Notifier.requestAuthorizationIfNeeded() }
            }
            AccountsSection()
            Section {
                Toggle(L("Ouvrir GitWatch à l’ouverture de session"), isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, value in
                        preferences.launchAtLogin = value
                        launchAtLogin = preferences.launchAtLogin
                    }
                LabeledContent(L("Version \(Updater.shared.currentVersion.description)")) {
                    Button(L("Rechercher les mises à jour…")) { Updater.shared.checkForUpdates(nil) }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(L("Général"))
        .alert(L("Relancer GitWatch maintenant ?"), isPresented: $askRelaunch) {
            Button(L("Relancer")) { AppLanguage.relaunch() }
            Button(L("Plus tard"), role: .cancel) {}
        } message: {
            Text(L("La nouvelle langue s’appliquera au redémarrage."))
        }
    }
}

// MARK: - Comptes distants

/// GitHub (via GitHub CLI) et les serveurs GitLab de vos dépôts (un jeton chacun) pour proposer les dépôts à cloner.
struct AccountsSection: View {
    @Environment(Monitor.self) private var monitor

    var body: some View {
        Section {
            LabeledContent("GitHub", value: L("via GitHub CLI (gh auth login)"))
            ForEach(RemoteCatalog.gitlabHosts(in: monitor.repos), id: \.self) { host in
                GitLabTokenRow(host: host)
            }
        } header: {
            Text(L("Comptes distants"))
        } footer: {
            Text(L("Pour la liste des dépôts à cloner. Les serveurs GitLab sont ceux de vos dépôts ; chaque jeton (portée read_api) est gardé dans le trousseau."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct GitLabTokenRow: View {
    let host: String
    @State private var token = ""
    @State private var hasToken = false

    var body: some View {
        LabeledContent(host) {
            HStack {
                SecureField(L("Jeton"), text: $token, prompt: Text(hasToken ? L("Enregistré dans le trousseau") : L("Jeton d’accès (glpat-…)")))
                    .labelsHidden()
                    .frame(maxWidth: 260)
                Button(hasToken && token.isEmpty ? L("Supprimer") : L("Enregistrer")) {
                    Keychain.setToken(token.isEmpty ? nil : token.trimmed, for: host)
                    token = ""
                    hasToken = Keychain.token(for: host) != nil
                }
                .disabled(!hasToken && token.isEmpty)
                if !hasToken, let url = URL(string: "https://\(host)/-/user_settings/personal_access_tokens?name=GitWatch&scopes=read_api") {
                    Link(L("Créer…"), destination: url)
                }
            }
        }
        .task { hasToken = Keychain.token(for: host) != nil }
    }
}

// MARK: - À cloner

/// Dépôts des comptes GitHub et GitLab absents de ce Mac.
struct RemotePane: View {
    @Environment(Preferences.self) private var preferences
    @State private var catalog = RemoteCatalog.shared
    @State private var filter = ""
    @State private var showArchived = false
    @State private var showShared = false
    @State private var showForks = true
    @State private var showIgnored = false

    private var repos: [RemoteRepo] {
        catalog.missing.filter { repo in
            (showArchived || !repo.archived) && (showShared || repo.owned) && (showForks || !repo.fork)
                && (showIgnored || !preferences.ignoredRemotes.contains(repo.id))
                && (filter.isEmpty || repo.fullName.localizedCaseInsensitiveContains(filter))
        }
    }

    private var destination: URL? {
        (preferences.cloneFolder ?? preferences.roots.first?.path).map { URL(fileURLWithPath: $0) }
    }

    var body: some View {
        @Bindable var preferences = preferences
        Table(repos) {
            TableColumn(L("Dépôt")) { repo in
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(repo.name).fontWeight(.medium)
                        if repo.archived { tag(L("archivé")) }
                        if repo.fork { tag("fork") }
                        if !repo.owned { tag(L("partagé")) }
                    }
                    if let error = catalog.cloneErrors[repo.id] {
                        Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
                    } else {
                        Text(verbatim: "\(RepoSummary.hostName(repo.web)) · \(repo.fullName)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .opacity(preferences.ignoredRemotes.contains(repo.id) ? 0.5 : 1)
                .contextMenu {
                    Button(L("Ouvrir sur \(RepoSummary.hostName(repo.web))")) { NSWorkspace.shared.open(repo.web) }
                    Button(preferences.ignoredRemotes.contains(repo.id) ? L("Ne plus ignorer") : L("Ignorer")) { toggleIgnored(repo) }
                }
            }
            .width(min: 220, ideal: 320)
            TableColumn(L("Activité")) { repo in
                Text(repo.updated.map(\.relativeText) ?? "—").foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 120)
            TableColumn("") { repo in
                HStack(spacing: 6) {
                    if catalog.cloning.contains(repo.id) {
                        ProgressView().controlSize(.small)
                    } else {
                        Button(L("Cloner")) { if let destination { Task { await catalog.clone(repo, into: destination) } } }
                            .controlSize(.small)
                            .disabled(destination == nil)
                    }
                    Button { toggleIgnored(repo) } label: {
                        Image(systemName: preferences.ignoredRemotes.contains(repo.id) ? "eye" : "eye.slash")
                    }
                    .buttonStyle(.borderless)
                    .help(preferences.ignoredRemotes.contains(repo.id) ? L("Ne plus ignorer") : L("Ignorer ce dépôt"))
                }
            }
            .width(110)
        }
        .overlay {
            if catalog.isLoading && catalog.remote.isEmpty {
                ProgressView(L("Interrogation des serveurs…"))
            } else if repos.isEmpty, catalog.lastLoad != nil {
                ContentUnavailableView(L("Rien à cloner"), systemImage: "checkmark.icloud",
                                       description: Text(L("Tous les dépôts de vos comptes sont présents sur ce Mac.")))
            }
        }
        .searchable(text: $filter, placement: .toolbar, prompt: L("Filtrer"))
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(catalog.errors.sorted(by: { $0.key < $1.key }), id: \.key) { source, message in
                    Label(L("\(source) : \(message)"), systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
                }
                HStack {
                    Picker(L("Cloner dans"), selection: Binding(get: { destination?.path ?? "" }, set: { preferences.cloneFolder = $0 })) {
                        ForEach(preferences.roots) { root in
                            Text((root.path as NSString).abbreviatingWithTildeInPath).tag(root.path)
                        }
                    }
                    .fixedSize()
                    Spacer()
                    Text(repos.count == 1 ? L("1 dépôt") : L("\(repos.count) dépôts")).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .toolbar {
            ToolbarItemGroup {
                Menu {
                    Toggle(L("Dépôts archivés"), isOn: $showArchived)
                    Toggle(L("Dépôts partagés avec moi"), isOn: $showShared)
                    Toggle("Forks", isOn: $showForks)
                    Toggle(L("Dépôts ignorés"), isOn: $showIgnored)
                } label: { Label(L("Afficher"), systemImage: "line.3.horizontal.decrease.circle") }
                Button { Task { await catalog.load() } } label: { Label(L("Actualiser"), systemImage: "arrow.clockwise") }
                    .disabled(catalog.isLoading)
            }
        }
        .navigationTitle(L("À cloner"))
        .task { if catalog.lastLoad == nil { await catalog.load() } }
    }

    private func tag(_ text: String) -> some View {
        Text(text).font(.caption2).foregroundStyle(.secondary)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(.quaternary, in: .capsule)
    }

    private func toggleIgnored(_ repo: RemoteRepo) {
        if preferences.ignoredRemotes.contains(repo.id) { preferences.ignoredRemotes.remove(repo.id) } else { preferences.ignoredRemotes.insert(repo.id) }
    }
}
