import AppKit

/// Langue de l'interface : celle du système par défaut (français si le système est en français, anglais sinon),
/// ou imposée dans Réglages → Général (prise en compte au prochain lancement).
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, fr, en

    private static let key = "appLanguage"

    var id: String { rawValue }

    static var chosen: AppLanguage {
        get { UserDefaults.standard.string(forKey: key).flatMap(AppLanguage.init(rawValue:)) ?? .system }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }

    /// Nom affiché dans le menu, chaque langue dans sa propre langue.
    var title: String {
        switch self {
        case .system: L("Langue du système")
        case .fr: "Français"
        case .en: "English"
        }
    }

    /// À appeler avant tout texte affiché : impose la langue choisie à Bundle.main.
    static func applyAtLaunch() {
        switch chosen {
        case .system: UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        case .fr, .en: UserDefaults.standard.set([chosen.rawValue], forKey: "AppleLanguages")
        }
    }

    /// Relance GitWatch : la nouvelle langue s'applique au démarrage.
    @MainActor static func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    /// Langue effectivement utilisée par l'interface (« fr » ou « en »).
    static var current: String { Bundle.main.preferredLocalizations.first ?? "en" }

    /// Locale des dates affichées, accordée à la langue de l'interface (pas à la région du système).
    static var locale: Locale { Locale(identifier: current == "fr" ? "fr_FR" : "en_US") }
}

extension Date {
    /// « il y a 3 min », « hier »… dans la langue de l'interface.
    var relativeText: String { formatted(.relative(presentation: .named).locale(AppLanguage.locale)) }

    /// Heure courte (« 14:05 », « 2:05 PM ») dans la langue de l'interface.
    var timeText: String { formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: AppLanguage.locale)) }
}

/// Texte d'interface écrit en français dans le code, traduit d'après `<langue>.lproj/Localizable.strings`.
/// Chaque interpolation devient « %@ » dans la clé (« \(n) dépôts » → « %@ dépôts ») ; la traduction
/// peut réordonner les valeurs avec « %1$@ », « %2$@ »… (même mécanisme qu'iExplorer et iBaobab).
struct LocalizedText: ExpressibleByStringInterpolation {
    var key = ""
    var arguments: [String] = []

    init(stringLiteral value: String) {
        key = value.replacingOccurrences(of: "%", with: "%%")
    }

    init(stringInterpolation: Interpolation) {
        key = stringInterpolation.key
        arguments = stringInterpolation.arguments
    }

    struct Interpolation: StringInterpolationProtocol {
        var key = ""
        var arguments: [String] = []

        init(literalCapacity: Int, interpolationCount: Int) {}

        mutating func appendLiteral(_ literal: String) {
            key += literal.replacingOccurrences(of: "%", with: "%%")
        }

        mutating func appendInterpolation<T>(_ value: T) {
            key += "%@"
            arguments.append("\(value)")
        }
    }
}

/// Texte traduit dans la langue de l'interface (voir `LocalizedText`).
func L(_ text: LocalizedText) -> String {
    let template = Bundle.main.localizedString(forKey: text.key, value: text.key, table: nil)
    var result = ""
    var index = 0
    var characters = template[...]
    while let percent = characters.firstIndex(of: "%") {
        result += characters[..<percent]
        let rest = characters[characters.index(after: percent)...]
        if rest.hasPrefix("%") {
            result += "%"
            characters = rest.dropFirst()
        } else if rest.hasPrefix("@") {
            result += index < text.arguments.count ? text.arguments[index] : ""
            index += 1
            characters = rest.dropFirst()
        } else if let dollar = rest.firstIndex(of: "$"), let position = Int(rest[..<dollar]),
                  rest[rest.index(after: dollar)...].hasPrefix("@") {
            result += position - 1 < text.arguments.count && position > 0 ? text.arguments[position - 1] : ""
            characters = rest[rest.index(dollar, offsetBy: 2)...]
        } else {
            result += "%"
            characters = rest
        }
    }
    return result + characters
}
