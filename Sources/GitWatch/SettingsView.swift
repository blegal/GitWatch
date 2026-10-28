import SwiftUI

/// Fenêtre de l'application : dépôts, dossiers explorés, réglages généraux.
struct SettingsView: View {
    enum Pane: String, CaseIterable, Identifiable {
        case repos, folders, general
        var id: String { rawValue }
        var title: String {
            switch self {
            case .repos: "Dépôts"
            case .folders: "Dossiers"
            case .general: "Général"
            }
        }
        var symbol: String {
            switch self {
            case .repos: "arrow.triangle.branch"
            case .folders: "folder.badge.gearshape"
            case .general: "gearshape"
            }
        }
    }

    @State private var pane: Pane = .repos

    var body: some View {
        NavigationSplitView {
            List(Pane.allCases, selection: $pane) { pane in
                Label(pane.title, systemImage: pane.symbol).tag(pane)
            }
            .navigationSplitViewColumnWidth(170)
        } detail: {
            switch pane {
            case .repos: ReposPane()
            case .folders: FoldersPane()
            case .general: GeneralPane()
            }
        }
        .frame(minWidth: 680, minHeight: 420)
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
            TableColumn("Dépôt") { repo in
                VStack(alignment: .leading, spacing: 1) {
                    Text(repo.name).fontWeight(.medium)
                    Text(location(repo)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .opacity(preferences.settings(for: repo.id).followed ? 1 : 0.5)
                .contextMenu { RepoActions(repo: repo) }
            }
            .width(min: 200, ideal: 300)
            TableColumn("État") { repo in StateLabel(repo: repo, followed: preferences.settings(for: repo.id).followed) }
                .width(min: 110, ideal: 140)
            TableColumn("Suivre") { repo in
                Toggle("Suivre", isOn: binding(repo.id, \.followed)).labelsHidden().toggleStyle(.switch).controlSize(.mini)
            }
            .width(56)
            TableColumn("Auto-pull") { repo in
                Toggle("Tirer automatiquement", isOn: binding(repo.id, \.autoPull))
                    .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                    .disabled(!preferences.settings(for: repo.id).followed)
            }
            .width(64)
        }
        .searchable(text: $filter, placement: .toolbar, prompt: "Filtrer")
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text("Le tirage automatique se fait en avance rapide, seulement sans commit ni modification locale.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(monitor.repos.count == 1 ? "1 dépôt" : "\(monitor.repos.count) dépôts").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .toolbar {
            ToolbarItemGroup {
                Menu {
                    Button("Suivre la sélection") { setSelected(\.followed, true) }
                    Button("Ne plus suivre la sélection") { setSelected(\.followed, false) }
                    Divider()
                    Button("Activer l’auto-pull") { setSelected(\.autoPull, true) }
                    Button("Désactiver l’auto-pull") { setSelected(\.autoPull, false) }
                } label: { Label("Sélection", systemImage: "checklist") }
                .disabled(selection.isEmpty)
                Button {
                    Task { await monitor.refresh(fetch: true) }
                } label: { Label("Vérifier", systemImage: "arrow.clockwise") }
                .disabled(monitor.isChecking)
            }
        }
        .navigationTitle("Dépôts")
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
        guard followed else { return ("Non suivi", .secondary) }
        guard let status = repo.status else { return ("—", .secondary) }
        switch RepoCategory(repo) {
        case .error: return ("Erreur", .red)
        case .toPull: return (status.ahead > 0 ? "↓\(status.behind) ↑\(status.ahead) divergé" : "↓\(status.behind) en retard", .orange)
        case .toPush: return ("↑\(status.ahead) à pousser", .blue)
        case .modified: return ("+\(status.added) −\(status.removed)", .indigo)
        case .pulled: return ("Tiré aujourd’hui", .green)
        case .upToDate: return (status.upstream == nil ? "Sans amont" : "À jour", status.upstream == nil ? .secondary : .green)
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
                    Text("Aucun dossier. Ajoutez les dossiers qui contiennent vos dépôts.").foregroundStyle(.secondary)
                }
                ForEach($preferences.roots) { $root in
                    HStack(spacing: 10) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: root.path)).resizable().frame(width: 22, height: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text((root.path as NSString).abbreviatingWithTildeInPath)
                            Text(count(root)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("Profondeur \(root.depth)").monospacedDigit().foregroundStyle(.secondary)
                        Stepper("Profondeur", value: $root.depth, in: 0...6)
                            .labelsHidden()
                            .onChange(of: root.depth) { Task { await monitor.refresh(fetch: false) } }
                        Button { remove(root) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .help("Retirer ce dossier")
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("Dossiers explorés")
            } footer: {
                HStack {
                    Text("La profondeur indique sur combien de niveaux chercher des dépôts sous chaque dossier.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Ajouter un dossier…", action: add)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Dossiers")
    }

    private func count(_ root: SearchRoot) -> String {
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        let n = monitor.repos.filter { $0.id == root.path || $0.id.hasPrefix(prefix) }.count
        return n == 1 ? "1 dépôt" : "\(n) dépôts"
    }

    private func add() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Ajouter"
        panel.message = "Choisissez les dossiers qui contiennent vos dépôts Git."
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

    var body: some View {
        @Bindable var preferences = preferences
        Form {
            Section("Vérification") {
                Picker("Vérifier toutes les", selection: $preferences.interval) {
                    ForEach(Preferences.intervals, id: \.self) { minutes in
                        Text(minutes < 60 ? "\(minutes) minutes" : minutes == 60 ? "heure" : "\(minutes / 60) heures").tag(minutes)
                    }
                }
                .onChange(of: preferences.interval) { monitor.schedule() }
            }
            Section("Menu") {
                Picker("Présentation", selection: $preferences.layout) {
                    ForEach(MenuLayout.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Afficher le nombre de dépôts à tirer dans la barre des menus", isOn: $preferences.showBadge)
            }
            Section("Notifications") {
                Toggle("Quand un dépôt a de nouveaux commits à tirer", isOn: $preferences.notifyBehind)
                Toggle("Après un tirage automatique", isOn: $preferences.notifyAutoPull)
            }
            .onChange(of: preferences.notifyBehind || preferences.notifyAutoPull) { _, on in
                if on { Notifier.requestAuthorizationIfNeeded() }
            }
            Section {
                Toggle("Ouvrir GitWatch à l’ouverture de session", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, value in
                        preferences.launchAtLogin = value
                        launchAtLogin = preferences.launchAtLogin
                    }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Général")
    }
}
