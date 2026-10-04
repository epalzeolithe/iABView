#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ABVCreatorView: View {
    @State private var model = ABVCreatorModel()
    @State private var isImporterPresented = false
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            sourceList
            Divider()
            footer
        }
        .frame(minWidth: 720, idealWidth: 820, minHeight: 560, idealHeight: 650)
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            guard case .success(let urls) = result else { return }
            urls.forEach { _ = $0.startAccessingSecurityScopedResource() }
            model.add(urls)
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.add(urls)
            return true
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "shippingbox.and.arrow.backward")
                .font(.largeTitle)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text("Créer un fichier ABV")
                    .font(.title2.weight(.semibold))
                Text("Déposez les sources du vol, puis lancez la conversion et la fusion.")
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Ajouter des fichiers…", systemImage: "plus") {
                isImporterPresented = true
            }
            .disabled(model.state == .running)
        }
        .padding(20)
    }

    private var sourceList: some View {
        VStack(spacing: 14) {
            requirements

            if model.sources.isEmpty {
                ContentUnavailableView {
                    Label("Déposez les fichiers ici", systemImage: "arrow.down.doc")
                } description: {
                    Text("1 ou 2 fichiers .insv et un fichier GPS .gpx ou GNS3000 .txt")
                } actions: {
                    Button("Choisir les fichiers") {
                        isImporterPresented = true
                    }
                    if model.canReloadLastSession {
                        Button("Recharger les fichiers précédents") {
                            model.reloadLastSession()
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background {
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(
                            isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.35),
                            style: StrokeStyle(lineWidth: isDropTargeted ? 3 : 1.5, dash: [8])
                        )
                        .padding(16)
                }
            } else {
                List(model.sources) { source in
                    sourceRow(source)
                }
                .listStyle(.inset)
                .overlay {
                    if isDropTargeted {
                        RoundedRectangle(cornerRadius: 16)
                            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                    }
                }
            }

            status
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var requirements: some View {
        HStack(spacing: 18) {
            requirement(
                title: "Caméra",
                detail: "1–2 fichiers INSV",
                satisfied: (1...2).contains(model.sources.filter { $0.kind == .insta360 }.count)
            )
            requirement(
                title: "Position",
                detail: "GPX ou GNS3000",
                satisfied: model.sources.contains { $0.kind == .gpx || $0.kind == .nmea }
            )
            requirement(
                title: "iPhone",
                detail: "sensorlog.csv (optionnel)",
                satisfied: model.sources.contains { $0.kind == .sensorLog },
                optional: true
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func requirement(
        title: LocalizedStringKey,
        detail: LocalizedStringKey,
        satisfied: Bool,
        optional: Bool = false
    ) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: satisfied ? "checkmark.circle.fill" : optional ? "circle.dotted" : "circle")
                .foregroundStyle(satisfied ? Color.green : Color.secondary)
        }
    }

    private func sourceRow(_ source: ABVSourceFile) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon(for: source.kind))
                .frame(width: 24)
                .foregroundStyle(source.kind == .unsupported ? Color.orange : Color.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(source.url.lastPathComponent)
                    .lineLimit(1)
                Text(source.kind.rawValue)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if source.kind == .unsupported {
                Text("Ignoré")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Button("Retirer", systemImage: "xmark.circle.fill") {
                model.remove(source)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .disabled(model.state == .running)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var status: some View {
        switch model.state {
        case .ready:
            EmptyView()
        case .running:
            VStack(alignment: .leading, spacing: 8) {
                Text(model.currentStep ?? "Création en cours…")
                    .font(.callout.weight(.medium))

                HStack {
                    ProgressView(value: model.progress)
                    Text(model.progress, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 16) {
                    if let start = model.creationStartDate {
                        Label {
                            Text(start, style: .timer)
                                .monospacedDigit()
                        } icon: {
                            Image(systemName: "clock")
                        }
                    }

                    if let cpu = model.ffmpegCPUUsage {
                        Label("ffmpeg : \(Int(cpu)) % CPU", systemImage: "cpu")
                            .monospacedDigit()
                    }

                    Spacer()

                    Button("Arrêter", systemImage: "stop.circle.fill") {
                        model.cancel()
                    }
                    .foregroundStyle(.red)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        case .succeeded:
            VStack(alignment: .leading, spacing: 2) {
                Label("Le fichier ABV a été créé avec succès.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                if let duration = model.lastDuration {
                    Text("Terminé en \(formattedDuration(duration)).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func formattedDuration(_ duration: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: duration) ?? "\(Int(duration)) s"
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            toolStatusRow

            HStack {
                if let outputURL = model.outputURL {
                    Button("Afficher dans le Finder", systemImage: "folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([outputURL])
                    }
                } else {
                    Text(model.suggestedName)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Effacer") {
                    model.reset()
                }
                .disabled(model.sources.isEmpty || model.state == .running)

                Button("Créer le fichier ABV…") {
                    chooseDestinationAndCreate()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canCreate)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }

    private var toolStatusRow: some View {
        HStack(spacing: 16) {
            ForEach(ABVTool.allCases) { tool in
                toolStatusBadge(tool)
            }
            Spacer()
        }
    }

    private func toolStatusBadge(_ tool: ABVTool) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(tool.isAvailable ? Color.green : Color.red)
                .frame(width: 8, height: 8)
            Text(tool.displayName)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func chooseDestinationAndCreate() {
        let panel = NSSavePanel()
        panel.title = "Créer le fichier ABV"
        panel.nameFieldStringValue = model.suggestedName
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowedContentTypes = [
            UTType(filenameExtension: "abv") ?? .package
        ]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let finalURL = url.pathExtension.lowercased() == "abv" ? url : url.appendingPathExtension("abv")
        guard FileManager.default.fileExists(atPath: finalURL.path) else {
            model.create(at: url)
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Le fichier « \(finalURL.lastPathComponent) » existe déjà."
        alert.informativeText = "Voulez-vous le remplacer ? Cette action est irréversible."
        alert.addButton(withTitle: "Remplacer")
        alert.addButton(withTitle: "Annuler")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        model.create(at: url, overwrite: true)
    }

    private func icon(for kind: ABVSourceFile.Kind) -> String {
        switch kind {
        case .insta360: "video.fill"
        case .gpx: "map.fill"
        case .nmea: "location.fill"
        case .sensorLog: "iphone.gen3"
        case .unsupported: "questionmark.diamond"
        }
    }
}
#endif
