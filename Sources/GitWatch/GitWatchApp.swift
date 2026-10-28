import SwiftUI

@main
struct GitWatchApp: App {
    @State private var monitor = Monitor.shared
    @State private var preferences = Preferences.shared

    init() {
        Task { @MainActor in Monitor.shared.start() }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environment(monitor)
                .environment(preferences)
        } label: {
            MenuBarLabel(count: preferences.showBadge ? monitor.attentionCount : 0, checking: monitor.isChecking)
        }
        .menuBarExtraStyle(.window)

        Window("GitWatch", id: "settings") {
            SettingsView()
                .environment(monitor)
                .environment(preferences)
        }
        .defaultSize(width: 760, height: 520)
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(.suppressed)
    }
}

/// Icône de la barre des menus, avec le nombre de dépôts à tirer ou en erreur.
struct MenuBarLabel: View {
    let count: Int
    let checking: Bool

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: count > 0 ? "arrow.triangle.branch" : "checkmark.circle")
            if count > 0 { Text("\(count)").monospacedDigit() }
        }
        .accessibilityLabel(count > 0 ? "GitWatch : \(count) dépôts demandent votre attention" : "GitWatch : tout est à jour")
    }
}
