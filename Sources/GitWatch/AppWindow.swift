import SwiftUI

/// Onglet et panneau affichés par la fenêtre (le menu de la barre des menus y ouvre directement le bon onglet).
@MainActor @Observable
final class WindowRouter {
    static let shared = WindowRouter()
    enum Tab: Hashable { case dashboard, settings }
    var tab: Tab = .dashboard
    var pane: SettingsView.Pane = .repos
}

/// Fenêtre de l'application : tableau de bord et réglages, en deux onglets.
struct AppWindow: View {
    @Environment(WindowRouter.self) private var router

    var body: some View {
        @Bindable var router = router
        Group {
            switch router.tab {
            case .dashboard: DashboardView()
            case .settings: SettingsView()
            }
        }
        .frame(minWidth: 820, minHeight: 460)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Affichage", selection: $router.tab) {
                    Text("Tableau de bord").tag(WindowRouter.Tab.dashboard)
                    Text("Réglages").tag(WindowRouter.Tab.settings)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }
    }
}
