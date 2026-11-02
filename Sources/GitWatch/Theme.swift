import SwiftUI

/// Styles de texte de l'interface, aux tailles de macOS pour un corps de 13 pt.
enum TextRole {
    case largeTitle, title2, title3, headline, body, callout, subheadline, caption, caption2

    var baseSize: Double {
        switch self {
        case .largeTitle: 26
        case .title2: 17
        case .title3: 15
        case .headline, .body: 13
        case .callout: 12
        case .subheadline: 11
        case .caption, .caption2: 10
        }
    }
}

extension Font {
    /// Police choisie dans Réglages → Apparence, à l'échelle de la taille choisie.
    /// Lit `Preferences` : les vues qui l'utilisent se redessinent quand l'apparence change.
    @MainActor static func app(_ role: TextRole, weight: Font.Weight? = nil) -> Font {
        let preferences = Preferences.shared
        let size = role.baseSize * preferences.fontSize / 13
        let weight = weight ?? (role == .headline ? .semibold : .regular)
        switch preferences.fontChoice {
        case .system: return .system(size: size, weight: weight)
        case .rounded: return .system(size: size, weight: weight, design: .rounded)
        case .monospaced: return .system(size: size, weight: weight, design: .monospaced)
        case .serif: return .system(size: size, weight: weight, design: .serif)
        case .dyslexic: return .custom("OpenDyslexic", size: size).weight(weight)
        case .custom: return .custom(preferences.customFontFamily, size: size).weight(weight)
        }
    }
}

/// Largeur du menu : 340 points à 13 pt, plus large pour un texte plus grand ou une police large (OpenDyslexic).
enum MenuMetrics {
    @MainActor static var width: CGFloat {
        let preferences = Preferences.shared
        let wide = preferences.fontChoice == .dyslexic ? 1.25 : 1
        return 340 * max(1, preferences.fontSize / 13) * wide
    }
}

/// Animations de l'interface : coupées par le réglage ou par « Réduire les animations » de macOS.
enum Motion {
    @MainActor static var enabled: Bool {
        Preferences.shared.animations && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    @MainActor static func animation(_ animation: Animation) -> Animation? { enabled ? animation : nil }

    /// Ressort des apparitions et des changements d'état.
    static let spring = Animation.spring(response: 0.42, dampingFraction: 0.78)

    @MainActor static func perform(_ animation: Animation = spring, _ body: () -> Void) {
        if enabled { withAnimation(animation, body) } else { body() }
    }
}

/// Anneau de santé : part de chaque catégorie parmi les dépôts suivis, pourcentage à jour au centre.
struct HealthRing: View {
    let repos: [Repo]
    var lineWidth: CGFloat = 4

    private static let order: [RepoCategory] = [.upToDate, .pulled, .toPull, .toPush, .modified, .error, .unknown]

    private var segments: [(category: RepoCategory, start: Double, end: Double)] {
        let counts = Dictionary(grouping: repos, by: RepoCategory.init).mapValues(\.count)
        let total = Double(max(repos.count, 1))
        var start = 0.0
        return Self.order.compactMap { category in
            guard let count = counts[category], count > 0 else { return nil }
            defer { start += Double(count) / total }
            return (category, start, start + Double(count) / total)
        }
    }

    private var upToDateShare: Int {
        guard !repos.isEmpty else { return 0 }
        let ok = repos.filter { [.upToDate, .pulled].contains(RepoCategory($0)) }.count
        return Int((Double(ok) / Double(repos.count) * 100).rounded())
    }

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: lineWidth)
            ForEach(segments, id: \.category) { segment in
                // Petit espace entre les segments, sauf s'il n'y en a qu'un.
                let gap = segments.count > 1 ? 0.012 : 0
                Circle()
                    .trim(from: segment.start + gap / 2, to: max(segment.start + gap / 2, segment.end - gap / 2))
                    .stroke(segment.category.color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            Text("\(upToDateShare)%")
                .font(.system(size: 9, weight: .semibold, design: .rounded).monospacedDigit())
                .contentTransition(.numericText(value: Double(upToDateShare)))
        }
        .animation(Motion.animation(.spring(response: 0.6, dampingFraction: 0.85)), value: repos.map { RepoCategory($0) })
        .accessibilityElement()
        .accessibilityLabel(L("\(upToDateShare) % des dépôts à jour"))
    }
}

/// Pastille qui pulse doucement (catégories à traiter).
struct PulsingDot: View {
    let color: Color
    var pulsing = true
    @State private var expanded = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .background {
                if pulsing && Motion.enabled {
                    Circle()
                        .stroke(color, lineWidth: 1.5)
                        .scaleEffect(expanded ? 2.6 : 1)
                        .opacity(expanded ? 0 : 0.7)
                        .animation(.easeOut(duration: 1.6).repeatForever(autoreverses: false), value: expanded)
                        .onAppear { expanded = true }
                }
            }
    }
}
