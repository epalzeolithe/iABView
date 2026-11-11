import Foundation
import SwiftUI

/// Associations apprises entre le texte d'un favori et un numéro Aresti du catalogue.
/// Elles sont créées quand on désigne une figure à la création d'un favori, et réutilisées ensuite
/// pour tout favori dont le nom est identique ou contient ce texte.
enum AerobaticFigureLibrary {
    private static let storageKey = "AerobaticFigureLibrary.associations"
    private static var cache: [String: String] = {
        UserDefaults.standard.dictionary(forKey: storageKey) as? [String: String] ?? [:]
    }()

    /// Texte sans accents, en minuscules, sans espaces superflus.
    static func normalized(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    /// Code appris pour ce nom : correspondance exacte, sinon le plus long texte appris contenu dans le nom.
    static func code(for name: String) -> String? {
        let key = normalized(name)
        guard !key.isEmpty else { return nil }
        if let exact = cache[key] { return exact }
        return cache
            .filter { key.contains($0.key) }
            .max { $0.key.count < $1.key.count }?
            .value
    }

    static func learn(name: String, code: String) {
        let key = normalized(name)
        guard !key.isEmpty, AerobaticFigure(code: code) != nil else { return }
        cache[key] = code
        UserDefaults.standard.set(cache, forKey: storageKey)
    }

    static func forget(name: String) {
        cache.removeValue(forKey: normalized(name))
        UserDefaults.standard.set(cache, forKey: storageKey)
    }

    static var count: Int { cache.count }

    /// Toutes les associations, triées par texte.
    static var entries: [(name: String, code: String)] {
        cache.map { (name: $0.key, code: $0.value) }.sorted { $0.name < $1.name }
    }
}

/// Réglage de la superposition du schéma Aresti sur la vidéo de gauche.
enum AerobaticOverlay {
    static let cornerKey = "AerobaticOverlay.corner"
    static let sizeKey = "AerobaticOverlay.size"

    enum Corner: String, CaseIterable, Identifiable {
        case topTrailing, topLeading, bottomTrailing, bottomLeading
        var id: String { rawValue }

        var title: String {
            switch self {
            case .topTrailing: "Haut à droite"
            case .topLeading: "Haut à gauche"
            case .bottomTrailing: "Bas à droite"
            case .bottomLeading: "Bas à gauche"
            }
        }

        var alignment: Alignment {
            switch self {
            case .topTrailing: .topTrailing
            case .topLeading: .topLeading
            case .bottomTrailing: .bottomTrailing
            case .bottomLeading: .bottomLeading
            }
        }
    }

    enum Size: Int, CaseIterable, Identifiable {
        case small = 90, medium = 120, large = 180
        var id: Int { rawValue }

        /// Côté affiché (pt) : la valeur brute est conservée telle quelle pour les préférences déjà enregistrées.
        var side: CGFloat { CGFloat(rawValue) * 1.5 }

        var title: String {
            switch self {
            case .small: "Petit"
            case .medium: "Moyen"
            case .large: "Grand"
            }
        }
    }
}
