import SwiftUI

/// Choix d'une figure du catalogue Aresti : onglets par famille, rangées comme sur aresti.fr,
/// saisie du numéro (filtre par préfixe) ou clic sur une vignette.
struct AerobaticFigurePicker: View {
    @Binding var code: String
    /// Famille affichée (nil = toutes).
    @State private var family: Int?
    /// Affiche la liste des associations déjà faites (texte de favori → code) au lieu du catalogue.
    @State private var showsAssociations = false

    private struct Row: Identifiable {
        let id: String
        let title: String
        let codes: [String]
    }

    private var matches: [String] {
        let query = code.trimmingCharacters(in: .whitespaces)
        return AerobaticFigure.catalogCodes.filter { candidate in
            if let family, candidate.split(separator: ".").first.flatMap({ Int($0) }) != family { return false }
            return query.isEmpty || candidate.hasPrefix(query)
        }
    }

    /// Figures regroupées par rangée « famille.rangée », dans l'ordre du catalogue.
    private var rows: [Row] {
        var order: [String] = []
        var grouped: [String: [String]] = [:]
        for candidate in matches {
            let key = candidate.split(separator: ".").prefix(2).joined(separator: ".")
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(candidate)
        }
        return order.map { key in
            let name = AerobaticCatalogFamilies.rowNames[key]
            return Row(id: key, title: name.map { "\(key) · \($0)" } ?? key, codes: grouped[key] ?? [])
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Code Aresti (ex. 7.4.1.1)", text: $code)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospacedDigit())
                if !code.isEmpty {
                    Button("Aucune", systemImage: "xmark.circle") { code = "" }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .help("Effacer la figure")
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Button("Associations (\(AerobaticFigureLibrary.count))", systemImage: "link") {
                        showsAssociations = true
                    }
                    .buttonStyle(.bordered)
                    .tint(showsAssociations ? .accentColor : .secondary)
                    .controlSize(.small)
                    familyButton(title: "Toutes", id: nil)
                    ForEach(AerobaticCatalogFamilies.families) { item in
                        familyButton(title: "\(item.id) · \(item.name)", id: item.id)
                    }
                    familyButton(title: "0 · Autres", id: 0)
                }
            }
            if showsAssociations {
                associationsList
            } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10, pinnedViews: .sectionHeaders) {
                    ForEach(rows) { row in
                        Section {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 6)], spacing: 6) {
                                ForEach(row.codes, id: \.self) { candidate in
                                    figureButton(candidate)
                                }
                            }
                        } header: {
                            Text(row.title)
                                .font(.subheadline.weight(.semibold))
                                .padding(.vertical, 3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.regularMaterial)
                        }
                    }
                    if rows.isEmpty {
                        Text("Aucune figure.").foregroundStyle(.secondary).padding()
                    }
                }
            }
            .frame(maxHeight: .infinity)
            }
        }
    }

    /// Associations apprises : un clic reprend le code associé.
    private var associationsList: some View {
        let entries = AerobaticFigureLibrary.entries
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(entries, id: \.name) { entry in
                    Button {
                        code = entry.code
                    } label: {
                        HStack(spacing: 10) {
                            if let figure = AerobaticFigure(code: entry.code) {
                                AerobaticFigureSymbol(figure: figure, color: .primary)
                                    .frame(width: 44, height: 44)
                            }
                            Text(entry.name)
                            Spacer()
                            Text(entry.code).font(.body.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        .padding(4)
                        .background(
                            entry.code == code ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if entries.isEmpty {
                    Text("Aucune association.").foregroundStyle(.secondary).padding()
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func familyButton(title: String, id: Int?) -> some View {
        Button(title) { family = id; showsAssociations = false }
            .buttonStyle(.bordered)
            .tint(!showsAssociations && family == id ? .accentColor : .secondary)
            .controlSize(.small)
    }

    private func figureButton(_ candidate: String) -> some View {
        Button {
            code = candidate
        } label: {
            VStack(spacing: 2) {
                if let figure = AerobaticFigure(code: candidate) {
                    AerobaticFigureSymbol(figure: figure, color: .primary)
                        .frame(width: 84, height: 84)
                }
                Text(candidate).font(.caption.monospacedDigit())
            }
            .padding(4)
            .frame(maxWidth: .infinity)
            .background(
                candidate == code ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 6)
            )
        }
        .buttonStyle(.plain)
    }
}

/// Création d'un favori : nom, et figure Aresti facultative dont l'association au texte est mémorisée.
struct BookmarkCreationSheet: View {
    let timeText: String
    let onAdd: (String, String?) -> Void
    let onCancel: () -> Void

    @State private var name = ""
    @State private var code = ""
    @State private var codeEdited = false

    /// Figure affichée : celle du code saisi, sinon celle que l'app reconnaît déjà d'après le nom.
    private var previewFigure: AerobaticFigure? {
        AerobaticFigure(code: code) ?? (codeEdited ? nil : AerobaticFigure(bookmarkName: name))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ajouter un bookmark").font(.headline)
            Text("Le bookmark sera créé à \(timeText).").font(.callout).foregroundStyle(.secondary)

            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Nom", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(add)
                    AerobaticFigurePicker(code: Binding(
                        get: { code },
                        set: { code = $0; codeEdited = true }
                    ))
                }
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(.black)
                    if let previewFigure {
                        AerobaticFigureSymbol(figure: previewFigure).padding(10)
                    } else {
                        Text("Pas de figure").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 220, height: 220)
            }

            Text(AerobaticFigureLibrary.count == 0
                 ? "Choisir une figure associe ce texte à son code : l'app s'en souviendra pour les prochains favoris."
                 : "\(AerobaticFigureLibrary.count) association(s) mémorisée(s). Choisir une figure met à jour la mémoire pour ce texte.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Annuler", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Ajouter", action: add)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(minWidth: 900, idealWidth: 1300, maxWidth: .infinity, minHeight: 600, idealHeight: 850, maxHeight: .infinity)
        // Un nom déjà connu pré-remplit le code correspondant tant qu'on ne l'a pas modifié à la main.
        .onChange(of: name) {
            guard !codeEdited else { return }
            if let learned = AerobaticFigureLibrary.code(for: name) { code = learned }
        }
    }

    private func add() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty ? "Bookmark" : trimmed
        let validCode = AerobaticFigure(code: code) != nil ? code.trimmingCharacters(in: .whitespaces) : nil
        onAdd(finalName, validCode)
    }
}

/// Association d'une figure à un favori existant : mémorise le texte du favori pour les prochains.
struct AerobaticAssociationSheet: View {
    let name: String
    let onDone: () -> Void

    @State private var code: String

    init(name: String, onDone: @escaping () -> Void) {
        self.name = name
        self.onDone = onDone
        _code = State(initialValue: AerobaticFigureLibrary.code(for: name) ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Figure Aresti de « \(name) »").font(.headline)
            HStack(alignment: .top, spacing: 14) {
                AerobaticFigurePicker(code: $code)
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(.black)
                    if let figure = AerobaticFigure(code: code) {
                        AerobaticFigureSymbol(figure: figure).padding(10)
                    } else {
                        Text("Pas de figure").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 220, height: 220)
            }
            HStack {
                Button("Oublier l'association", role: .destructive) {
                    AerobaticFigureLibrary.forget(name: name)
                    onDone()
                }
                .disabled(AerobaticFigureLibrary.code(for: name) == nil)
                Spacer()
                Button("Annuler", role: .cancel, action: onDone)
                    .keyboardShortcut(.cancelAction)
                Button("Associer") {
                    if AerobaticFigure(code: code) != nil {
                        AerobaticFigureLibrary.learn(name: name, code: code.trimmingCharacters(in: .whitespaces))
                    }
                    onDone()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(AerobaticFigure(code: code) == nil)
            }
        }
        .padding(16)
        .frame(minWidth: 900, idealWidth: 1300, maxWidth: .infinity, minHeight: 600, idealHeight: 850, maxHeight: .infinity)
    }
}

/// Liste des associations apprises, avec suppression.
struct AerobaticAssociationsManager: View {
    let onDone: () -> Void
    @State private var entries = AerobaticFigureLibrary.entries

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Associations texte → figure Aresti").font(.headline)
            if entries.isEmpty {
                Text("Aucune association mémorisée.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                List {
                    ForEach(entries, id: \.name) { entry in
                        HStack(spacing: 10) {
                            if let figure = AerobaticFigure(code: entry.code) {
                                AerobaticFigureSymbol(figure: figure, color: .primary).frame(width: 34, height: 34)
                            }
                            Text(entry.name)
                            Spacer()
                            Text(entry.code).font(.body.monospacedDigit()).foregroundStyle(.secondary)
                            Button("Supprimer", systemImage: "trash") {
                                AerobaticFigureLibrary.forget(name: entry.name)
                                entries = AerobaticFigureLibrary.entries
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(height: 260)
            }
            HStack {
                Spacer()
                Button("Fermer", action: onDone).keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 480)
    }
}

/// Rapport des figures du vol : symbole, code Aresti, K, fenêtre et charges, avec le total de K.
struct AerobaticFlightReportView: View {
    let rows: [FlightViewModel.FigureReportRow]
    let onDone: () -> Void

    private var totalK: Int { rows.reduce(0) { $0 + ($1.figure?.k ?? 0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Figures du vol").font(.headline)
                Spacer()
                Text("Total K : \(totalK)").font(.headline.monospacedDigit())
            }
            if rows.isEmpty {
                Text("Aucun favori.").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 120)
            } else {
                Table(rows) {
                    TableColumn("") { row in
                        if let figure = row.figure {
                            AerobaticFigureSymbol(figure: figure, color: .primary).frame(width: 30, height: 30)
                        }
                    }
                    .width(40)
                    TableColumn("Favori") { row in
                        VStack(alignment: .leading) {
                            Text(row.name)
                            Text(row.displayTime).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    TableColumn("Code") { row in
                        Text(row.figure?.catalogCode ?? "—").monospacedDigit()
                    }
                    .width(70)
                    TableColumn("K") { row in
                        Text(row.figure?.k.map(String.init) ?? "—").monospacedDigit()
                    }
                    .width(36)
                    TableColumn("Fenêtre") { row in
                        Text("\(Int(row.window.rounded())) s").monospacedDigit()
                    }
                    .width(56)
                    TableColumn("G min") { row in
                        Text(row.minimumLoadFactor, format: .number.precision(.fractionLength(1))).monospacedDigit()
                    }
                    .width(52)
                    TableColumn("G max") { row in
                        Text(row.maximumLoadFactor, format: .number.precision(.fractionLength(1))).monospacedDigit()
                    }
                    .width(52)
                }
                .frame(height: 320)
            }
            Text("K : coefficient de difficulté (bibliothèque aresti.fr, catégorie moteur). Les figures sans code du catalogue ne sont pas comptées.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Fermer", action: onDone).keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 560)
    }
}
