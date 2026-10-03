import SwiftUI

struct KeyboardShortcutsView: View {
    private let shortcuts = [
        KeyboardShortcutEntry(keys: "Espace", action: "Lecture / Pause"),
        KeyboardShortcutEntry(keys: "← / →", action: "Reculer / avancer de 10 secondes"),
        KeyboardShortcutEntry(keys: "⇧← / ⇧→", action: "Reculer / avancer de 2 secondes"),
        KeyboardShortcutEntry(keys: "⌃← / ⌃→", action: "Favori précédent / suivant"),
        KeyboardShortcutEntry(keys: "⌃B", action: "Ajouter un favori"),
        KeyboardShortcutEntry(keys: "⌃R", action: "Recharger bookmark.csv"),
        KeyboardShortcutEntry(keys: "Z", action: "Activer ou désactiver le zoom timeline"),
        KeyboardShortcutEntry(keys: "I", action: "Inverser le montage caméra"),
        KeyboardShortcutEntry(keys: "M", action: "Couper ou réactiver le son"),
        KeyboardShortcutEntry(keys: "⌃W", action: "Fermer la fenêtre")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Raccourcis clavier", systemImage: "keyboard")
                .font(.title2.bold())

            Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 10) {
                ForEach(shortcuts) { shortcut in
                    GridRow {
                        Text(shortcut.keys)
                            .font(.body.monospaced().bold())
                            .frame(minWidth: 110, alignment: .trailing)
                        Text(shortcut.action)
                    }
                }
            }
        }
        .padding(28)
        .frame(minWidth: 520)
    }
}

struct KeyboardShortcutEntry: Identifiable {
    let keys: String
    let action: String

    var id: String { keys }
}
