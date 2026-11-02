import SwiftUI

/// Réglages → Apparence : police, taille, densité et animations du menu et du tableau de bord.
struct AppearancePane: View {
    @Environment(Preferences.self) private var preferences

    /// Familles de polices installées (pour « Autre police… »).
    private static let families = NSFontManager.shared.availableFontFamilies.filter { !$0.hasPrefix(".") }

    var body: some View {
        @Bindable var preferences = preferences
        Form {
            Section(L("Texte")) {
                Picker(L("Police"), selection: $preferences.fontChoice) {
                    ForEach(FontChoice.allCases) { choice in
                        Text(choice.title).font(sample(choice)).tag(choice)
                    }
                }
                if preferences.fontChoice == .custom {
                    Picker(L("Famille"), selection: $preferences.customFontFamily) {
                        ForEach(Self.families, id: \.self) { family in
                            Text(family).font(.custom(family, size: 13)).tag(family)
                        }
                    }
                }
                LabeledContent(L("Taille")) {
                    HStack(spacing: 10) {
                        Image(systemName: "textformat.size.smaller").foregroundStyle(.secondary)
                        Slider(value: $preferences.fontSize, in: 11...17, step: 1).frame(width: 180)
                        Image(systemName: "textformat.size.larger").foregroundStyle(.secondary)
                        Text("\(Int(preferences.fontSize)) pt").monospacedDigit().frame(width: 40, alignment: .trailing)
                    }
                }
                Picker(L("Densité"), selection: $preferences.density) {
                    ForEach(Density.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                if preferences.fontChoice != .system || preferences.fontSize != 13 || preferences.density != .comfortable {
                    Button(L("Rétablir les réglages par défaut")) {
                        Motion.perform {
                            preferences.fontChoice = .system
                            preferences.fontSize = 13
                            preferences.density = .comfortable
                        }
                    }
                }
            }
            Section {
                Toggle(L("Animations"), isOn: $preferences.animations)
            } footer: {
                Text(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                     ? L("« Réduire les animations » est activé dans Réglages Système → Accessibilité : les animations restent coupées.")
                     : L("Anneau de santé, compteurs qui défilent, lignes qui glissent d’une section à l’autre, rebond de l’icône quand des commits arrivent."))
                    .foregroundStyle(.secondary)
            }
            Section(L("Aperçu")) {
                AppearancePreview()
                    .frame(maxWidth: .infinity)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(L("Apparence"))
        .animation(Motion.animation(Motion.spring), value: preferences.fontSize)
    }

    /// Chaque police s'affiche dans sa propre forme dans le menu déroulant.
    private func sample(_ choice: FontChoice) -> Font {
        switch choice {
        case .system: .system(size: 13)
        case .rounded: .system(size: 13, design: .rounded)
        case .monospaced: .system(size: 13, design: .monospaced)
        case .serif: .system(size: 13, design: .serif)
        case .dyslexic: .custom("OpenDyslexic", size: 12)
        case .custom: .system(size: 13)
        }
    }
}

/// Quelques lignes du menu, avec de faux dépôts, rendues avec l'apparence choisie.
private struct AppearancePreview: View {
    private static let samples: [Repo] = {
        func repo(_ name: String, _ change: (inout RepoStatus) -> Void) -> Repo {
            var status = RepoStatus()
            status.branch = "main"
            status.defaultBranch = "main"
            status.upstream = "origin/main"
            change(&status)
            return Repo(url: URL(fileURLWithPath: "/Exemple/\(name)"), status: status)
        }
        return [
            repo("iExplorer") { $0.behind = 3 },
            repo("GitWatch") { $0.ahead = 1 },
            repo("iBaobab") { $0.changedFiles = 4; $0.added = 42; $0.removed = 7; $0.stashes = 1 },
            repo("zephyr") { _ in },
        ]
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                HealthRing(repos: Self.samples).frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(L("Dépôts Git")).font(.app(.headline))
                    Text(L("Vérifié il y a 3 min · 3 dépôts")).font(.app(.caption)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Self.samples) { RepoRow(repo: $0, style: .icon) }
            }
            .padding(.vertical, 6)
            .allowsHitTesting(false)
        }
        .frame(width: MenuMetrics.width)
        .background(.background, in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
    }
}
