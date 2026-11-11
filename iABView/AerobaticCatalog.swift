import Foundation

/// Bibliothèque de figures Aresti : celle d'aresti.fr.
enum AerobaticCatalog {
    static let figures = AerobaticCatalogDataArestiFR.figures

    /// Numéros du catalogue, triés dans l'ordre naturel (1.1.1.1, 1.1.1.2, …, 9.1.1.1).
    static let sortedCodes: [String] = figures.keys.sorted {
        $0.compare($1, options: .numeric) == .orderedAscending
    }
}
