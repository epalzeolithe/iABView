#if os(macOS)
import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

struct ABVEditorView: View {
    @State private var model = ABVEditorModel()
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            if model.hasSource {
                editor
            } else {
                emptyState
            }
            if case .failed(let message) = model.state {
                Divider()
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
        }
        .frame(minWidth: 760, minHeight: 600)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            Task { await model.load(url) }
            return true
        } isTargeted: { isDropTargeted = $0 }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 8).strokeBorder(.tint, lineWidth: 3).padding(6).allowsHitTesting(false)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "scissors")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("Éditer un fichier ABV")
                .font(.title2.weight(.semibold))
            Text("Glissez un bundle .abv ici ou choisissez-le. Le fichier d’origine n’est jamais modifié.")
                .foregroundStyle(.secondary)
            Button("Choisir un fichier ABV…", action: chooseSource)
                .keyboardShortcut("o")
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var editor: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "shippingbox").foregroundStyle(.tint)
                Text(model.sourceURL?.lastPathComponent ?? "")
                    .font(.headline)
                Spacer()
                Button("Ouvrir un autre…", action: chooseSource)
                    .disabled(model.state == .running)
            }
            .padding(10)
            Divider()

            ABVEditorPlayerView(player: model.player)
                .background(.black)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            transport
                .padding(.horizontal, 12)
                .padding(.top, 8)

            ABVEditorTimeline(model: model)
                .frame(height: 74)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            Divider()
            options
            Divider()
            footer
        }
        // Raccourcis d’édition : espace, I/O pour les bornes, flèches pour avancer image par image.
        .background {
            Group {
                Button("") { model.togglePlayback() }.keyboardShortcut(.space, modifiers: [])
                Button("") { model.markStartAtPlayhead() }.keyboardShortcut("i", modifiers: [])
                Button("") { model.markEndAtPlayhead() }.keyboardShortcut("o", modifiers: [])
                Button("") { model.step(frames: -1) }.keyboardShortcut(.leftArrow, modifiers: [])
                Button("") { model.step(frames: 1) }.keyboardShortcut(.rightArrow, modifiers: [])
                Button("") { model.step(frames: -10) }.keyboardShortcut(.leftArrow, modifiers: .shift)
                Button("") { model.step(frames: 10) }.keyboardShortcut(.rightArrow, modifiers: .shift)
            }
            .opacity(0)
            .allowsHitTesting(false)
        }
    }

    private var transport: some View {
        HStack(spacing: 10) {
            Button { model.togglePlayback() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").frame(width: 18)
            }
            .help("Lecture / pause (espace)")
            Button { model.step(frames: -1) } label: { Image(systemName: "backward.frame.fill") }
                .help("Image précédente (←)")
            Button { model.step(frames: 1) } label: { Image(systemName: "forward.frame.fill") }
                .help("Image suivante (→)")

            Text(model.playhead.preciseClock)
                .font(.body.monospacedDigit())
                .frame(width: 84, alignment: .leading)

            Button { model.jumpToBookmark(forward: false) } label: { Image(systemName: "bookmark.slash") }
                .help("Favori précédent")
                .disabled(model.bookmarks.isEmpty)
            Button { model.jumpToBookmark(forward: true) } label: { Image(systemName: "bookmark") }
                .help("Favori suivant")
                .disabled(model.bookmarks.isEmpty)

            Spacer()

            Button("Segment +", systemImage: "plus.rectangle.on.rectangle") { model.addSegment() }
                .help("Ajouter une plage à conserver (à partir de la tête de lecture)")
                .disabled(!model.canAddSegment)
            Button("Segment −", systemImage: "minus.rectangle") { model.removeSelectedSegment() }
                .help("Retirer la plage sélectionnée")
                .disabled(model.segments.count < 2)

            Button("Début ici", systemImage: "arrow.down.to.line.compact") { model.markStartAtPlayhead() }
                .help("Placer le début de la coupe à la position courante (I)")
            Button("Fin ici", systemImage: "arrow.up.to.line.compact") { model.markEndAtPlayhead() }
                .help("Placer la fin de la coupe à la position courante (O)")
            Button("Tout garder", systemImage: "arrow.uturn.backward") { model.resetBounds() }
                .help("Réinitialiser les bornes")
        }
        .controlSize(.regular)
        .disabled(model.state == .running)
    }

    private var options: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Picker("Vidéos", selection: $model.mode) {
                    ForEach(ABVEditorMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.radioGroup)
                .disabled(model.state == .running)
                Text(model.mode.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                GridRow {
                    Text("Début").foregroundStyle(.secondary)
                    Text(model.start.preciseClock).monospacedDigit()
                    Text("Fin").foregroundStyle(.secondary)
                    Text(model.end.preciseClock).monospacedDigit()
                }
                GridRow {
                    Text("Conservé").foregroundStyle(.secondary)
                    Text(model.croppedDuration.preciseClock).monospacedDigit()
                    Text("sur").foregroundStyle(.secondary)
                    Text("\(model.duration.preciseClock) · \(model.segments.count) segment(s)").monospacedDigit()
                }
                GridRow {
                    Text("Taille").foregroundStyle(.secondary)
                    Text(ABVEditorView.format(model.sourceBytes))
                    Text("≈").foregroundStyle(.secondary)
                    Text(ABVEditorView.format(model.estimatedBytes))
                }
            }
            .font(.callout)
            Spacer()
        }
        .padding(12)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            switch model.state {
            case .running:
                ProgressView(value: model.progress).frame(maxWidth: 260)
                Text(model.currentStep ?? "Export en cours…").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Annuler") { model.cancel() }
            case .succeeded:
                if let report = model.report {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(model.outputURL?.lastPathComponent ?? "") créé")
                            .font(.callout.weight(.medium))
                        Text("\(Self.format(report.originalBytes)) → \(Self.format(report.newBytes)) · gain \(Self.format(report.savedBytes)) (\(Int((report.savedFraction * 100).rounded())) %)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let url = model.outputURL {
                    Button("Afficher dans le Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
                exportButton
            default:
                Text("Le fichier d’origine reste intact : le résultat est enregistré sous un nouveau nom.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                exportButton
            }
        }
        .padding(12)
    }

    private var exportButton: some View {
        Button("Exporter…", systemImage: "square.and.arrow.down", action: chooseDestinationAndExport)
            .keyboardShortcut("e")
            .buttonStyle(.borderedProminent)
            .disabled(!model.canExport)
    }

    // MARK: - Actions

    private func chooseSource() {
        let panel = NSOpenPanel()
        panel.title = "Choisir le fichier ABV à éditer"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.load(url) }
    }

    private func chooseDestinationAndExport() {
        guard let source = model.sourceURL else { return }
        let panel = NSSavePanel()
        panel.title = "Enregistrer le fichier ABV édité"
        panel.nameFieldStringValue = model.suggestedName
        panel.directoryURL = source.deletingLastPathComponent()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowedContentTypes = [UTType(filenameExtension: "abv") ?? .package]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let destination = url.pathExtension.lowercased() == "abv" ? url : url.appendingPathExtension("abv")

        if destination.standardizedFileURL.path == source.standardizedFileURL.path {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Impossible d’écraser le fichier d’origine."
            alert.informativeText = "Choisissez un autre nom pour conserver l’original intact."
            alert.runModal()
            return
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Le fichier « \(destination.lastPathComponent) » existe déjà."
            alert.informativeText = "Il sera remplacé (placé dans la corbeille)."
            alert.addButton(withTitle: "Remplacer")
            alert.addButton(withTitle: "Annuler")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        model.export(to: destination)
    }

    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

extension TimeInterval {
    /// « 01:23.4 » : minutes, secondes et dixièmes.
    fileprivate var preciseClock: String {
        guard isFinite else { return "00:00.0" }
        let tenths = Int((max(0, self) * 10).rounded())
        return String(format: "%02d:%02d.%d", tenths / 600, (tenths / 10) % 60, tenths % 10)
    }
}

// MARK: - Timeline

/// Frise de vignettes avec deux poignées (début / fin) et une tête de lecture ; clic ou glisser pour se déplacer.
private struct ABVEditorTimeline: View {
    let model: ABVEditorModel
    private let handleWidth: CGFloat = 12

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let x = { (time: TimeInterval) in position(of: time, width: width) }
            let time = { (x: CGFloat) in self.time(at: x, width: width) }

            ZStack(alignment: .leading) {
                // Vignettes
                HStack(spacing: 0) {
                    ForEach(Array(model.thumbnails.enumerated()), id: \.offset) { _, image in
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(maxWidth: .infinity)
                            .clipped()
                    }
                }
                .frame(height: proxy.size.height)
                .background(.black)
                .padding(.horizontal, handleWidth)
                .clipShape(RoundedRectangle(cornerRadius: 4))

                // Zones coupées : tout ce qui n'est pas dans un segment.
                ForEach(Array(gaps().enumerated()), id: \.offset) { _, gap in
                    Rectangle().fill(.black.opacity(0.65))
                        .frame(width: max(0, x(gap.upperBound) - x(gap.lowerBound)))
                        .offset(x: x(gap.lowerBound))
                }

                // Favoris : un clic place la tête de lecture dessus ; le menu contextuel cale les bornes.
                ForEach(model.bookmarks) { bookmark in
                    Image(systemName: "bookmark.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.yellow)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                        .offset(x: x(bookmark.time) - 8, y: -proxy.size.height / 2 + 8)
                        .help(bookmark.name)
                        .onTapGesture {
                            model.pause()
                            model.seek(to: bookmark.time)
                        }
                        .contextMenu {
                            Button("Début de la coupe ici") { model.setStart(bookmark.time) }
                            Button("Fin de la coupe ici") { model.setEnd(bookmark.time) }
                        }
                }

                // Cadres des segments : le sélectionné est en jaune plein, les autres plus discrets.
                ForEach(Array(model.segments.enumerated()), id: \.element.id) { index, segment in
                    Rectangle()
                        .strokeBorder(index == model.selectedIndex ? Color.yellow : Color.yellow.opacity(0.45), lineWidth: 3)
                        .frame(width: max(0, x(segment.end) - x(segment.start)))
                        .offset(x: x(segment.start))
                        .allowsHitTesting(false)
                }

                handle(systemImage: "chevron.compact.right")
                    .offset(x: x(model.start) - handleWidth)
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline")).onChanged {
                        model.setStart(time($0.location.x + handleWidth / 2))
                        model.seek(to: model.start)
                    })
                handle(systemImage: "chevron.compact.left")
                    .offset(x: x(model.end))
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline")).onChanged {
                        model.setEnd(time($0.location.x - handleWidth / 2))
                        model.seek(to: model.end)
                    })

                // Tête de lecture
                Rectangle().fill(.white).frame(width: 2)
                    .shadow(radius: 1)
                    .offset(x: x(model.playhead) - 1)
                    .allowsHitTesting(false)
            }
            .coordinateSpace(name: "timeline")
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline")).onChanged {
                    model.pause()
                    let target = time($0.location.x)
                    model.selectSegment(containing: target)
                    model.seek(to: target)
                },
                including: .all
            )
        }
        .disabled(model.state == .running)
    }

    /// Intervalles de la timeline situés hors de tout segment.
    private func gaps() -> [ClosedRange<TimeInterval>] {
        var result: [ClosedRange<TimeInterval>] = []
        var cursor = 0.0
        for segment in model.segments {
            if segment.start > cursor { result.append(cursor...segment.start) }
            cursor = segment.end
        }
        if cursor < model.duration { result.append(cursor...model.duration) }
        return result
    }

    private func position(of time: TimeInterval, width: CGFloat) -> CGFloat {
        handleWidth + CGFloat(time / max(model.duration, 0.001)) * max(1, width - handleWidth * 2)
    }

    private func time(at x: CGFloat, width: CGFloat) -> TimeInterval {
        let track = max(1, width - handleWidth * 2)
        return min(model.duration, max(0, Double((x - handleWidth) / track) * model.duration))
    }

    private func handle(systemImage: String) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(.yellow)
            .frame(width: handleWidth)
            .overlay(Image(systemName: systemImage).font(.caption2.bold()).foregroundStyle(.black))
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
    }
}

// MARK: - Lecteur

private struct ABVEditorPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerLayerHost {
        let view = PlayerLayerHost()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ view: PlayerLayerHost, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }

    final class PlayerLayerHost: NSView {
        let playerLayer = AVPlayerLayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            playerLayer.videoGravity = .resizeAspect
            layer?.addSublayer(playerLayer)
        }

        required init?(coder: NSCoder) { nil }

        override func layout() {
            super.layout()
            playerLayer.frame = bounds
        }
    }
}
#endif
