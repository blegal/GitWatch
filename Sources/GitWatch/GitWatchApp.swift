import SwiftUI
import UpdateKit

@main
struct GitWatchApp: App {
    @State private var monitor = Monitor.shared
    @State private var preferences = Preferences.shared
    @State private var router = WindowRouter.shared

    init() {
        Task { @MainActor in
            Monitor.shared.start()
            Updater.shared.checkAtLaunch()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environment(monitor)
                .environment(preferences)
                .environment(router)
        } label: {
            MenuBarLabel(count: preferences.showBadge ? monitor.attentionCount : 0, checking: monitor.isChecking)
        }
        .menuBarExtraStyle(.window)

        Window("GitWatch", id: "main") {
            AppWindow()
                .environment(monitor)
                .environment(preferences)
                .environment(router)
        }
        .defaultSize(width: 1080, height: 640)
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
