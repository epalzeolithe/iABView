import SwiftUI

// Pictogrammes Aresti tracés à partir de la bibliothèque aresti.fr (voir AerobaticCatalog.swift et
// AerobaticCatalogDataArestiFR.swift, licence GPL v3). Les instructions de tracé du catalogue sont interprétées par un petit
// automate de tortue : lignes, arcs de boucle, coins, marteaux, cloches et symboles de tonneau.

/// Figure Aresti reconnue dans le nom d'un favori : par son numéro (« 7.4.1.1 ») ou par un nom courant.
struct AerobaticFigure: Equatable {
    enum Roll: Equatable {
        case full, half
    }

    struct Mark: Equatable {
        enum Kind: Equatable { case fullRoll, halfRoll, hammer, tailslide }
        var kind: Kind
        var point: CGPoint
        /// Cap en degrés (0 = vers la droite, sens trigonométrique).
        var heading: CGFloat
    }

    /// Identifiant Aresti ou nom d'alias.
    let key: String
    /// Numéro du catalogue (nil pour une figure tracée depuis un nom courant).
    var catalogCode: String? { AerobaticCatalog.figures[key] == nil ? nil : key }
    /// Coefficient de difficulté K (moteur) du catalogue.
    var k: Int? { AerobaticCatalog.figures[key]?.k }
    fileprivate let points: [CGPoint]
    fileprivate let marks: [Mark]

    /// Noms courants → (instructions de tracé, tours aux emplacements `_`), ou numéro du catalogue.
    private enum Alias {
        case draw(String, [Roll?])
        case catalog(String)
    }

    private static let aliases: [(keywords: [String], alias: Alias)] = [
        // Chaque entrée regroupe les termes français et anglais ; les plus spécifiques passent en premier.
        (["demi-tonneau", "demi tonneau", "demi-roulade", "half roll", "half-roll"], .draw("~_~", [.half])),
        (["demi-looping", "demi looping", "demi-boucle", "demi boucle", "half loop"], .draw("~''m''~", [])),
        (["immelmann", "immelman"], .draw("~m_~", [.half])),
        (["split s", "split-s", "splits"], .draw("~_M~", [.half])),
        (["renversement", "hammerhead", "stall turn", "stallturn"], .catalog("5.2.1.1")),
        (["looping", "loop", "boucle"], .draw("~''o''~", [])),
        (["tonneau", "roulade", "roll"], .draw("~_~", [.full]))
    ]

    /// Figure du catalogue désignée par son numéro Aresti exact (« 7.4.1.1 »).
    init?(code: String) {
        guard let figure = Self.catalogFigure(code.trimmingCharacters(in: .whitespaces)) else { return nil }
        self = figure
    }

    /// Numéros du catalogue actif, triés dans l'ordre naturel (1.1.1.1, 1.1.1.2, …, 9.1.1.1).
    static var catalogCodes: [String] { AerobaticCatalog.sortedCodes }

    init?(bookmarkName: String) {
        // Associations apprises lors de la création des favoris : prioritaires.
        if let code = AerobaticFigureLibrary.code(for: bookmarkName), let figure = Self.catalogFigure(code) {
            self = figure
            return
        }
        if let range = bookmarkName.range(of: #"\d\.\d{1,2}\.\d\.\d"#, options: .regularExpression),
           let figure = Self.catalogFigure(String(bookmarkName[range])) {
            self = figure
            return
        }
        let name = bookmarkName.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .lowercased()
        for entry in Self.aliases where entry.keywords.contains(where: name.contains) {
            switch entry.alias {
            case .draw(let draw, let rolls):
                self = Self.build(key: entry.keywords[0], draw: draw, rolls: rolls)
            case .catalog(let id):
                guard let figure = Self.catalogFigure(id) else { continue }
                self = figure
            }
            return
        }
        return nil
    }

    private static func catalogFigure(_ id: String) -> AerobaticFigure? {
        guard let entry = AerobaticCatalog.figures[id] else { return nil }
        // Les jetons de tour du motif (_ entier, ^ demi, & ou $ facultatif) se suivent dans l'ordre des
        // emplacements `_` du tracé ; si les nombres diffèrent, on n'affiche aucun symbole de tour.
        let tokens: [Roll?] = entry.pattern.compactMap { character in
            switch character {
            case "_": .some(.full)
            case "^": .some(.half)
            case "&", "$": .some(nil)
            default: nil
            }
        }
        let slots = entry.draw.filter { $0 == "_" }.count
        return build(key: id, draw: entry.draw, rolls: tokens.count == slots ? tokens : [])
    }

    /// Interprète les instructions de tracé : cap initial vers la droite, unité = une « ligne courte ».
    private static func build(key: String, draw: String, rolls: [Roll?]) -> AerobaticFigure {
        let characters = Array(draw)
        var position = CGPoint.zero
        var heading: CGFloat = 0
        var points = [position]
        var marks: [Mark] = []
        var slot = 0

        func radians(_ degrees: CGFloat) -> CGFloat { degrees * .pi / 180 }
        func advance(_ length: CGFloat) {
            position.x += length * cos(radians(heading))
            position.y += length * sin(radians(heading))
            points.append(position)
        }
        func placeRoll() {
            defer { slot += 1 }
            guard slot < rolls.count, let roll = rolls[slot] else { return }
            marks.append(Mark(kind: roll == .full ? .fullRoll : .halfRoll, point: position, heading: heading))
        }
        func arc(_ angle: CGFloat, radius: CGFloat) {
            let side: CGFloat = angle > 0 ? 1 : -1
            let center = CGPoint(
                x: position.x + radius * cos(radians(heading + 90 * side)),
                y: position.y + radius * sin(radians(heading + 90 * side))
            )
            let start = heading - 90 * side
            let steps = max(2, Int(abs(angle) / 6))
            for step in 1...steps {
                let current = radians(start + angle * CGFloat(step) / CGFloat(steps))
                points.append(CGPoint(x: center.x + radius * cos(current), y: center.y + radius * sin(current)))
            }
            position = points[points.count - 1]
            heading += angle
        }
        func pivot(_ kind: Mark.Kind) {
            marks.append(Mark(kind: kind, point: position, heading: heading))
            // Le demi-tour sur place décale légèrement la branche descendante.
            let sideways = radians(heading - 90)
            position.x += 1.2 * cos(sideways)
            position.y += 1.2 * sin(sideways)
            points.append(position)
            heading += 180
        }

        let angles: [Character: CGFloat] = [
            "d": 45, "v": 90, "z": 135, "m": 180, "c": 225, "p": 270, "r": 315, "o": 360,
            "D": -45, "V": -90, "Z": -135, "M": -180, "C": -225, "P": -270, "R": -315, "O": -360
        ]
        var index = 0
        while index < characters.count {
            let character = characters[index]
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            switch character {
            case "~": advance(4)
            case "'": advance(1)
            case "_": placeRoll()
            case "h", "H": pivot(.hammer)
            case "t", "T": pivot(.tailslide)
            case "j", "J":
                // Virage (figures de la famille 2) : non tracé, on saute ses paramètres.
                while index + 1 < characters.count, "ioIO0123456789".contains(characters[index + 1]) { index += 1 }
            default:
                guard let angle = angles[character] else { break }
                if abs(angle) < 180, next != "=" {
                    heading += angle
                } else {
                    let radius: CGFloat = next == "/" ? 2 : 4
                    if next == "!" {
                        // Tour au sommet de la boucle : arc coupé en deux autour de l'emplacement.
                        arc(angle / 2, radius: radius)
                        placeRoll()
                        arc(angle / 2, radius: radius)
                        index += 1
                        if index + 1 < characters.count, characters[index + 1] == "_" { index += 1 }
                    } else {
                        arc(angle, radius: radius)
                    }
                }
            }
            index += 1
        }
        return AerobaticFigure(key: key, points: points, marks: marks)
    }

    private init(key: String, points: [CGPoint], marks: [Mark]) {
        self.key = key
        self.points = points
        self.marks = marks
    }
}

private struct AerobaticFigureShape: Shape {
    enum Part { case strokes, fills }

    let figure: AerobaticFigure
    let part: Part

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard figure.points.count > 1 else { return path }
        let xs = figure.points.map(\.x)
        let ys = figure.points.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return path }
        // Marges pour les symboles ; le tracé est mis à l'échelle sans déformation, y vers le haut.
        let side = min(rect.width, rect.height)
        let inset = side * 0.12
        let scale = (side - inset * 2) / max(maxX - minX, maxY - minY, 0.001)
        let offsetX = rect.midX - (maxX - minX) * scale / 2
        let offsetY = rect.midY + (maxY - minY) * scale / 2
        func map(_ point: CGPoint) -> CGPoint {
            CGPoint(x: offsetX + (point.x - minX) * scale, y: offsetY - (point.y - minY) * scale)
        }
        // Direction d'un cap en coordonnées écran (y vers le bas).
        func direction(_ heading: CGFloat) -> CGPoint {
            CGPoint(x: cos(heading * .pi / 180), y: -sin(heading * .pi / 180))
        }
        let span = side * 0.1

        if part == .strokes {
            path.move(to: map(figure.points[0]))
            figure.points.dropFirst().forEach { path.addLine(to: map($0)) }
            // Trait d'arrivée perpendiculaire.
            let end = map(figure.points[figure.points.count - 1])
            let before = map(figure.points[figure.points.count - 2])
            let length = max(hypot(end.x - before.x, end.y - before.y), 0.001)
            let normal = CGPoint(x: -(end.y - before.y) / length * span * 0.8, y: (end.x - before.x) / length * span * 0.8)
            path.move(to: CGPoint(x: end.x - normal.x, y: end.y - normal.y))
            path.addLine(to: CGPoint(x: end.x + normal.x, y: end.y + normal.y))
            // Barre des symboles de tour.
            for mark in figure.marks where mark.kind == .fullRoll || mark.kind == .halfRoll {
                let center = map(mark.point)
                let along = direction(mark.heading)
                path.move(to: CGPoint(x: center.x - along.y * span, y: center.y + along.x * span))
                path.addLine(to: CGPoint(x: center.x + along.y * span, y: center.y - along.x * span))
            }
        } else {
            let start = map(figure.points[0])
            let dot = side * 0.045
            path.addEllipse(in: CGRect(x: start.x - dot, y: start.y - dot, width: dot * 2, height: dot * 2))
            for mark in figure.marks {
                let center = map(mark.point)
                let along = direction(mark.heading)
                let normal = CGPoint(x: -along.y, y: along.x)
                switch mark.kind {
                case .fullRoll, .halfRoll:
                    // Fanions pleins aux extrémités de la barre : un seul pour un demi-tour.
                    let flag = span * 0.9
                    for sign: CGFloat in mark.kind == .fullRoll ? [1, -1] : [1] {
                        let tip = CGPoint(x: center.x + normal.x * span * sign, y: center.y + normal.y * span * sign)
                        path.move(to: tip)
                        path.addLine(to: CGPoint(x: tip.x + along.x * flag, y: tip.y + along.y * flag))
                        path.addLine(to: CGPoint(x: tip.x + along.x * flag * 0.2 - normal.x * flag * sign * 0.9,
                                                 y: tip.y + along.y * flag * 0.2 - normal.y * flag * sign * 0.9))
                        path.closeSubpath()
                    }
                case .hammer, .tailslide:
                    // Triangle plein posé sur le sommet de la ligne verticale.
                    let size = span * 0.9
                    path.move(to: CGPoint(x: center.x - normal.x * size, y: center.y - normal.y * size))
                    path.addLine(to: CGPoint(x: center.x + normal.x * size, y: center.y + normal.y * size))
                    path.addLine(to: CGPoint(x: center.x + along.x * size * 1.4, y: center.y + along.y * size * 1.4))
                    path.closeSubpath()
                }
            }
        }
        return path
    }
}

/// Dessin d'une figure : trait fin, point de départ et fanions pleins.
struct AerobaticFigureSymbol: View {
    let figure: AerobaticFigure
    var color: Color = .white

    var body: some View {
        Group {
            // Figures du catalogue : dessin du moteur d'aresti.fr ; sinon tracé simplifié (noms courants).
            if let code = figure.catalogCode,
               let drawing = ArestiFRRenderer.drawing(code: code) {
                ArestiFRFigureSymbol(drawing: drawing, color: color)
            } else {
                AerobaticFigureShape(figure: figure, part: .strokes)
                    .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    .overlay(AerobaticFigureShape(figure: figure, part: .fills).fill(color))
                    .aspectRatio(1, contentMode: .fit)
            }
        }
        .accessibilityHidden(true)
    }
}

#Preview("Figures Aresti") {
    let names = ["Immelmann", "Split S", "Looping", "Tonneau", "Renversement", "7.4.1.1", "7.3.1.1", "5.2.1.1"]
    LazyVGrid(columns: Array(repeating: GridItem(.fixed(110)), count: 4), spacing: 16) {
        ForEach(names, id: \.self) { name in
            VStack {
                if let figure = AerobaticFigure(bookmarkName: name) {
                    AerobaticFigureSymbol(figure: figure).frame(width: 90, height: 90)
                }
                Text(name).font(.caption)
            }
        }
    }
    .padding()
    .background(.black)
    .foregroundStyle(.white)
}
