import JavaScriptCore
import SwiftUI

// Rendu des figures de la bibliothèque aresti.fr : le moteur de tracé du site (ArestiEngine.js) est exécuté
// par JavaScriptCore, puis ses éléments SVG (lignes, arcs, symboles de tour) sont convertis en `Path`.

/// Figure telle que dessinée par le moteur aresti.fr, en coordonnées SVG (y vers le bas).
struct ArestiFRDrawing {
    struct Element {
        var path: Path?
        var style: String
        var text: String?
        var textPoint: CGPoint = .zero
    }

    var elements: [Element]
    var bounds: CGRect
}

enum ArestiFRRenderer {
    private static let lock = NSLock()
    private static var cache: [String: ArestiFRDrawing?] = [:]
    private static let context: JSContext? = {
        guard let url = Bundle.main.url(forResource: "ArestiEngine", withExtension: "js"),
              let script = try? String(contentsOf: url, encoding: .utf8),
              let context = JSContext() else { return nil }
        context.evaluateScript(script)
        return context
    }()

    /// Dessin du numéro Aresti (première variante du catalogue aresti.fr), nil si le numéro est inconnu.
    static func drawing(code: String) -> ArestiFRDrawing? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[code] { return cached }
        let drawing = makeDrawing(code: code)
        cache[code] = .some(drawing)
        return drawing
    }

    private static func makeDrawing(code: String) -> ArestiFRDrawing? {
        guard let engine = context?.objectForKeyedSubscript("ArestiEngine"),
              let json = engine.invokeMethod("drawCode", withArguments: [code])?.toString(),
              let data = json.data(using: .utf8),
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }

        var elements: [ArestiFRDrawing.Element] = []
        var cursor = CGPoint.zero
        var bounds = CGRect.null
        for item in items {
            let style = item["style"] as? String ?? ""
            if let text = item["text"] as? String {
                let x = (item["x"] as? Double ?? 0) + cursor.x
                let y = (item["y"] as? Double ?? 0) + cursor.y
                elements.append(.init(path: nil, style: style, text: text, textPoint: CGPoint(x: x, y: y)))
            } else if let source = item["path"] as? String, !source.isEmpty {
                let path = SVGPathParser.path(from: source, origin: cursor)
                if !path.isEmpty {
                    elements.append(.init(path: path, style: style))
                    bounds = bounds.union(path.boundingRect)
                }
            }
            cursor.x += item["dx"] as? Double ?? 0
            cursor.y += item["dy"] as? Double ?? 0
        }
        guard !elements.isEmpty, !bounds.isNull else { return nil }
        return ArestiFRDrawing(elements: elements, bounds: bounds)
    }
}

/// Lecture des chemins SVG relatifs produits par le moteur (m, l, h, v, a, z), arcs échantillonnés en segments.
private enum SVGPathParser {
    static func path(from source: String, origin: CGPoint) -> Path {
        var path = Path()
        var current = origin
        var subpathStart = origin
        path.move(to: origin)

        // Découpe en (commande, nombres) : une lettre suivie de ses paramètres.
        var tokens: [(command: Character, numbers: [Double])] = []
        var letter: Character?
        var buffer = ""
        func flush() {
            guard let command = letter else { return }
            tokens.append((command, numbers(in: buffer)))
            buffer = ""
        }
        for character in source {
            if character.isLetter {
                flush()
                letter = character
            } else {
                buffer.append(character)
            }
        }
        flush()

        for (command, values) in tokens {
            let relative = command.isLowercase
            func absolute(_ x: Double, _ y: Double) -> CGPoint {
                relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
            }
            switch command.lowercased() {
            case "m":
                for (offset, pair) in stride(from: 0, to: values.count - 1, by: 2).enumerated() {
                    current = absolute(values[pair], values[pair + 1])
                    if offset == 0 {
                        path.move(to: current)
                        subpathStart = current
                    } else {
                        path.addLine(to: current)
                    }
                }
            case "l":
                for pair in stride(from: 0, to: values.count - 1, by: 2) {
                    current = absolute(values[pair], values[pair + 1])
                    path.addLine(to: current)
                }
            case "h":
                for value in values {
                    current = CGPoint(x: relative ? current.x + value : value, y: current.y)
                    path.addLine(to: current)
                }
            case "v":
                for value in values {
                    current = CGPoint(x: current.x, y: relative ? current.y + value : value)
                    path.addLine(to: current)
                }
            case "a":
                for start in stride(from: 0, to: values.count - 6, by: 7) {
                    let end = absolute(values[start + 5], values[start + 6])
                    addArc(to: &path, from: current, to: end,
                           rx: values[start], ry: values[start + 1], rotation: values[start + 2],
                           largeArc: values[start + 3] != 0, sweep: values[start + 4] != 0)
                    current = end
                }
            case "z":
                path.closeSubpath()
                current = subpathStart
            default:
                break
            }
        }
        return path
    }

    private static func numbers(in text: String) -> [Double] {
        var result: [Double] = []
        var token = ""
        func flush() {
            if let value = Double(token) { result.append(value) }
            token = ""
        }
        var previous: Character = " "
        for character in text {
            if character == "-" || character == "+" {
                // Un signe commence un nombre, sauf après l'exposant d'un nombre flottant.
                if previous != "e" && previous != "E" { flush() }
                token.append(character)
            } else if character == "." {
                if token.contains(".") { flush() }
                token.append(character)
            } else if character.isNumber || character == "e" || character == "E" {
                token.append(character)
            } else {
                flush()
            }
            previous = character
        }
        flush()
        return result
    }

    /// Arc elliptique SVG (conversion extrémités → centre) tracé par petits segments.
    private static func addArc(to path: inout Path, from start: CGPoint, to end: CGPoint,
                               rx rawRx: Double, ry rawRy: Double, rotation: Double, largeArc: Bool, sweep: Bool) {
        var rx = abs(rawRx), ry = abs(rawRy)
        guard rx > 0, ry > 0, start != end else {
            path.addLine(to: end)
            return
        }
        let phi = rotation * .pi / 180
        let cosPhi = cos(phi), sinPhi = sin(phi)
        let dx = (start.x - end.x) / 2, dy = (start.y - end.y) / 2
        let x1 = cosPhi * dx + sinPhi * dy
        let y1 = -sinPhi * dx + cosPhi * dy
        let lambda = x1 * x1 / (rx * rx) + y1 * y1 / (ry * ry)
        if lambda > 1 {
            rx *= lambda.squareRoot()
            ry *= lambda.squareRoot()
        }
        let numerator = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let denominator = rx * rx * y1 * y1 + ry * ry * x1 * x1
        let sign: Double = largeArc == sweep ? -1 : 1
        let coefficient = sign * (max(0, numerator / denominator)).squareRoot()
        let cxPrime = coefficient * rx * y1 / ry
        let cyPrime = -coefficient * ry * x1 / rx
        let cx = cosPhi * cxPrime - sinPhi * cyPrime + (start.x + end.x) / 2
        let cy = sinPhi * cxPrime + cosPhi * cyPrime + (start.y + end.y) / 2

        let startAngle = atan2((y1 - cyPrime) / ry, (x1 - cxPrime) / rx)
        let endAngle = atan2((-y1 - cyPrime) / ry, (-x1 - cxPrime) / rx)
        var delta = endAngle - startAngle
        if !sweep && delta > 0 { delta -= 2 * .pi }
        if sweep && delta < 0 { delta += 2 * .pi }

        let steps = max(2, Int((abs(delta) / (.pi / 36)).rounded(.up)))
        for step in 1...steps {
            let angle = startAngle + delta * Double(step) / Double(steps)
            let x = cx + rx * cos(angle) * cosPhi - ry * sin(angle) * sinPhi
            let y = cy + rx * cos(angle) * sinPhi + ry * sin(angle) * cosPhi
            path.addLine(to: CGPoint(x: x, y: y))
        }
    }
}

/// Dessin d'une figure aresti.fr dans un Canvas : traits d'épaisseur constante, pleins et pointillés selon le style.
struct ArestiFRFigureSymbol: View {
    let drawing: ArestiFRDrawing
    var color: Color

    var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            let bounds = drawing.bounds
            let inset = side * 0.08
            let scale = (side - inset * 2) / max(bounds.width, bounds.height, 0.001)
            let transform = CGAffineTransform(translationX: size.width / 2 - bounds.midX * scale,
                                              y: size.height / 2 - bounds.midY * scale)
                .scaledBy(x: scale, y: scale)
            let lineWidth: CGFloat = 1.5

            for element in drawing.elements {
                if let text = element.text {
                    // Les libellés (« 90° », « 1/2 ») ne sont lisibles que sur un symbole assez grand.
                    guard side >= 90 else { continue }
                    let point = element.textPoint.applying(transform)
                    context.draw(Text(text).font(.system(size: max(8, 12 * scale), weight: .bold)).foregroundColor(color),
                                 at: point)
                    continue
                }
                guard let path = element.path?.applying(transform) else { continue }
                switch element.style {
                case "blackfill", "figureStartMarker", "negfill":
                    context.fill(path, with: .color(color))
                    context.stroke(path, with: .color(color), lineWidth: lineWidth)
                case "neg":
                    context.stroke(path, with: .color(color),
                                   style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round, dash: [5, 3]))
                case "dotted":
                    context.stroke(path, with: .color(color),
                                   style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round, dash: [1, 3]))
                default:
                    context.stroke(path, with: .color(color),
                                   style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

#Preview("Figures aresti.fr") {
    let codes = ["8.5.6.1", "7.4.1.1", "5.2.1.1", "1.1.1.1", "7.8.21.1", "9.1.1.1", "8.8.1.1", "2.1.1.1"]
    LazyVGrid(columns: Array(repeating: GridItem(.fixed(130)), count: 4), spacing: 16) {
        ForEach(codes, id: \.self) { code in
            VStack {
                if let drawing = ArestiFRRenderer.drawing(code: code) {
                    ArestiFRFigureSymbol(drawing: drawing, color: .white).frame(width: 110, height: 110)
                } else {
                    Text("?").frame(width: 110, height: 110)
                }
                Text(code).font(.caption)
            }
        }
    }
    .padding()
    .background(.black)
    .foregroundStyle(.white)
}
