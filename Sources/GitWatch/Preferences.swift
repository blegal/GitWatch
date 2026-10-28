import Foundation
import ServiceManagement

/// Dossier dans lequel chercher les dépôts.
struct SearchRoot: Codable, Hashable, Identifiable {
    var path: String
    /// Profondeur d'exploration (0 : le dossier lui-même doit être un dépôt).
    var depth: Int
    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
}

/// Réglages propres à un dépôt.
struct RepoSettings: Codable, Equatable {
    var followed = true
    var autoPull = false
}

/// Présentation du menu de la barre des menus.
enum MenuLayout: String, Codable, CaseIterable, Identifiable {
    case list, grouped
    var id: String { rawValue }
    var title: String { self == .list ? "Liste" : "Par action" }
}

/// Réglages de l'application (UserDefaults).
@MainActor @Observable
final class Preferences {
    static let shared = Preferences()
    private let defaults = UserDefaults.standard

    var roots: [SearchRoot] { didSet { save(roots, "roots") } }
    var repos: [String: RepoSettings] { didSet { save(repos, "repos") } }
    /// Intervalle entre deux vérifications, en minutes.
    var interval: Int { didSet { defaults.set(interval, forKey: "interval") } }
    var layout: MenuLayout { didSet { defaults.set(layout.rawValue, forKey: "layout") } }
    var notifyBehind: Bool { didSet { defaults.set(notifyBehind, forKey: "notifyBehind") } }
    var notifyAutoPull: Bool { didSet { defaults.set(notifyAutoPull, forKey: "notifyAutoPull") } }
    var showBadge: Bool { didSet { defaults.set(showBadge, forKey: "showBadge") } }

    static let intervals = [5, 10, 15, 30, 60, 120, 240]

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let github = home.appendingPathComponent("GitHub").path
        roots = Self.load("roots") ?? (FileManager.default.fileExists(atPath: github) ? [SearchRoot(path: github, depth: 2)] : [])
        repos = Self.load("repos") ?? [:]
        interval = defaults.object(forKey: "interval") as? Int ?? 15
        layout = MenuLayout(rawValue: defaults.string(forKey: "layout") ?? "") ?? .grouped
        notifyBehind = defaults.object(forKey: "notifyBehind") as? Bool ?? true
        notifyAutoPull = defaults.object(forKey: "notifyAutoPull") as? Bool ?? true
        showBadge = defaults.object(forKey: "showBadge") as? Bool ?? true
    }

    func settings(for path: String) -> RepoSettings { repos[path] ?? RepoSettings() }

    func update(_ path: String, _ change: (inout RepoSettings) -> Void) {
        var value = settings(for: path)
        change(&value)
        repos[path] = value
    }

    /// Ouverture à l'ouverture de session (SMAppService : nécessite l'application dans un paquet .app).
    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("GitWatch : ouverture à la connexion impossible : \(error.localizedDescription)")
            }
        }
    }

    private func save<T: Encodable>(_ value: T, _ key: String) {
        defaults.set(try? JSONEncoder().encode(value), forKey: key)
    }

    private static func load<T: Decodable>(_ key: String) -> T? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }
}
