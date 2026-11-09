import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

private var isRunningOnIPhone: Bool {
    #if os(iOS)
    UIDevice.current.userInterfaceIdiom == .phone
    #else
    false
    #endif
}

#if os(macOS)
// `.navigationTitle` on a NavigationSplitView column doesn't reliably drive
// the actual NSWindow title bar text, so the CPU readout never showed up
// there. Reaching the window directly through its hosting NSView is the
// dependable way to set it from SwiftUI.
private struct WindowTitleSetter: NSViewRepresentable {
    let title: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { view.window?.title = title }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.window?.title = title
    }
}
#endif

struct ContentView: View {
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    @State private var cpuMonitor = CPUMonitor()
    #endif
    var initialBundleURL: URL? = nil
    @State private var model = FlightViewModel()
    @State private var recorder = ScreenRecorder()
    @State private var detachedWindows = DetachedWindowManager()
    @State private var isChaseCamPresented = false
    @State private var isChaseCam3DPresented = false
    @State private var isKeyboardHelpPresented = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .detailOnly
    @State private var preferredCompactColumn: NavigationSplitViewColumn = .detail
    @State private var bookmarkName = ""
    @State private var isBookmarkDialogPresented = false
    @State private var bookmarkTimeText = ""
    @State private var isLastBundleDialogPresented = false
    @State private var didAskToRestoreLastBundle = false
    @State private var isBundleImporterPresented = false

    private var cpuUsageText: String {
        #if os(macOS)
        cpuMonitor.usageText
        #else
        ""
        #endif
    }

    #if os(macOS)
    /// « ABView — <vol>.abv — CPU xx % » : le nom du bundle ouvert et la charge CPU, quand ils sont connus.
    private var windowTitle: String {
        ["ABView", model.bundleURL?.lastPathComponent, cpuUsageText.isEmpty ? nil : cpuUsageText]
            .compactMap { $0 }
            .joined(separator: " — ")
    }
    #endif

    var body: some View {
        NavigationSplitView(
            columnVisibility: $columnVisibility,
            preferredCompactColumn: $preferredCompactColumn
        ) {
            FlightSidebar(
                bundleName: model.bundleURL?.lastPathComponent,
                recentBundles: model.recentBundles,
                bookmarks: model.bookmarks,
                onOpen: openBundlePanel,
                onSelectRecent: { recent in
                    model.openBundle(recent.url)
                    preferredCompactColumn = .detail
                },
                onShowFlight: { preferredCompactColumn = .detail },
                onOpenBookmarksFile: model.openBookmarksFile,
                onReloadBookmarks: model.reloadBookmarks,
                onSelectBookmark: { bookmark in
                    model.goToBookmark(bookmark)
                    preferredCompactColumn = .detail
                }
            )
            .navigationSplitViewColumnWidth(min: 190, ideal: 240)
        } detail: {
            FlightWorkspace(
                model: model,
                isRecording: recorder.isRecording,
                onOpen: openBundlePanel,
                onToggleRecording: {
                    recorder.toggleRecording()
                },
                onOpenChaseCam: { isChaseCamPresented = true },
                onAddBookmark: { isBookmarkDialogPresented = true },
                onDetachFront: { detachedWindows.showFrontVideo(model: model) },
                onDetachBack: { detachedWindows.showBackVideo(model: model) },
                onDetachAircraft: { detachedWindows.showAircraft(model: model) },
                onDetachFlightPath: { detachedWindows.showGPS(model: model) },
                onOpenChaseCam3D: {
                    #if os(macOS)
                    detachedWindows.showChaseCam3D(model: model)
                    #else
                    isChaseCam3DPresented = true
                    #endif
                }
            )
        }
        #if os(macOS)
        .frame(minWidth: 1_100, minHeight: 720)
        .background(
            WindowTitleSetter(title: windowTitle)
        )
        // Le raccourci Z vit hors du Menu de la toolbar : les raccourcis d'un Menu ne sont pas
        // fiables tant que le menu n'a pas été ouvert.
        .background(
            Button("Zoom timeline") { model.toggleTimelineZoom() }
                .keyboardShortcut("z", modifiers: [])
                .opacity(0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        )
        .task {
            cpuMonitor.start()
        }
        #endif
        .onAppear {
            guard !didAskToRestoreLastBundle else { return }
            didAskToRestoreLastBundle = true
            if let initialBundleURL {
                model.openBundle(initialBundleURL)
                preferredCompactColumn = .detail
            } else {
                isLastBundleDialogPresented = model.lastBundleName != nil
            }
        }
        #if os(macOS)
        // Fermer la fenêtre ne quitte pas l'app : sans cela la vidéo (et son son) continuerait, y compris
        // dans les fenêtres détachées qui partagent les mêmes lecteurs.
        .onDisappear {
            model.pausePlayback()
            detachedWindows.closeAll()
        }
        #endif
        .onOpenURL { url in
            model.openBundle(url)
            preferredCompactColumn = .detail
        }
        .task(id: isLastBundleDialogPresented) {
            guard isLastBundleDialogPresented else { return }
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }
            guard isLastBundleDialogPresented else { return }
            isLastBundleDialogPresented = false
            model.openLastBundle()
        }
        .alert("Ouvrir le dernier vol ?", isPresented: $isLastBundleDialogPresented) {
            Button("Ouvrir") {
                model.openLastBundle()
            }
            Button("Non", role: .cancel) {}
        } message: {
            Text(model.lastBundleName ?? "Dernier bundle ABView")
        }
        .alert("Ajouter un bookmark", isPresented: $isBookmarkDialogPresented) {
            TextField("Nom", text: $bookmarkName)
            Button("Ajouter") {
                let name = bookmarkName.trimmingCharacters(in: .whitespacesAndNewlines)
                model.addBookmark(named: name.isEmpty ? "Bookmark" : name)
                bookmarkName = ""
            }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Le bookmark sera créé à \(bookmarkTimeText).")
        }
        // Heure figée à l'ouverture du dialogue : lire `currentTime` dans le message ferait
        // réévaluer tout `ContentView` (et donc l'espace de travail) à chaque tick de lecture.
        .onChange(of: isBookmarkDialogPresented) { _, isPresented in
            if isPresented { bookmarkTimeText = model.currentTime.clockString }
        }
        .sheet(isPresented: $isChaseCamPresented) {
            #if os(macOS)
            ChaseCamView(
                samples: model.samples,
                sample: model.currentSample,
                maximumSpeed: model.maximumSpeed
            )
                .frame(minWidth: 900, minHeight: 650)
            #else
            ChaseCamView(
                samples: model.samples,
                sample: model.currentSample,
                maximumSpeed: model.maximumSpeed
            )
            #endif
        }
        #if !os(macOS)
        .sheet(isPresented: $isChaseCam3DPresented) {
            ChaseCam3DView(model: model)
        }
        .onChange(of: isChaseCam3DPresented) { _, isPresented in
            model.setChaseCam3DWindowOpen(isPresented)
        }
        #endif
        .sheet(isPresented: $isKeyboardHelpPresented) {
            KeyboardShortcutsView()
        }
        .fileImporter(
            isPresented: $isBundleImporterPresented,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            _ = url.startAccessingSecurityScopedResource()
            model.openBundle(url)
            preferredCompactColumn = .detail
        }
        .modifier(FlightErrorAlerts(model: model, recorder: recorder))
        .toolbar {
            ToolbarItemGroup {
                Button {
                    openBundlePanel()
                } label: {
                    Label("Ouvrir un vol", systemImage: "folder")
                }

                if !isRunningOnIPhone {
                    Button {
                        isChaseCamPresented = true
                    } label: {
                        Label("Cam", systemImage: "binoculars.fill")
                    }
                    .disabled(model.samples.isEmpty)

                    Button {
                        #if os(macOS)
                        detachedWindows.showChaseCam3D(model: model)
                        #else
                        isChaseCam3DPresented = true
                        #endif
                    } label: {
                        Label("Cam 3D", systemImage: "cube.transparent")
                    }
                    .disabled(model.samples.isEmpty)

                #if os(macOS)
                Button {
                    openWindow(id: "abv-creator")
                } label: {
                    Label("Créer un fichier ABV…", systemImage: "shippingbox.and.arrow.backward")
                }
                .help("Assembler les sources d’un vol (caméra, GPS, iPhone) en un fichier ABV")

                Button(action: updateHistoricalMETAR) {
                    if model.isUpdatingMETAR {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Mise à jour METAR en cours")
                    } else {
                        Label("Mettre à jour les METAR", systemImage: "cloud.sun.rain")
                    }
                }
                .disabled(model.samples.isEmpty || model.isUpdatingMETAR)
                .help("Télécharger les METAR historiques LFMT et mettre à jour metar.csv")

                Menu {
                    Button("Caméra avant") {
                        detachedWindows.showFrontVideo(model: model)
                    }
                    Button("Caméra arrière") {
                        detachedWindows.showBackVideo(model: model)
                    }
                    Button("Vue 3D") {
                        detachedWindows.showAircraft(model: model)
                    }
                    Button("Trajectoire GPS") {
                        detachedWindows.showGPS(model: model)
                    }
                } label: {
                    Label("Détacher une vue", systemImage: "macwindow.on.rectangle")
                }
                .disabled(model.samples.isEmpty)
                #endif

                Menu {
                    Button("Pitch caméra +1°") {
                        model.adjustMountingPitch(by: 1)
                    }
                    Button("Pitch caméra −1°") {
                        model.adjustMountingPitch(by: -1)
                    }
                    Button("Calibrer sur l’image courante") {
                        model.calibrateAtCurrentFrame()
                    }
                    Divider()
                    Text("Décalage GPS : \(model.gpsOffset, format: .number.precision(.fractionLength(1))) s")
                    Button("Avancer le GPS de 1 s (GPS en retard)") {
                        model.adjustGPSOffset(by: 1)
                    }
                    Button("Avancer le GPS de 0,1 s") {
                        model.adjustGPSOffset(by: 0.1)
                    }
                    Button("Retarder le GPS de 0,1 s") {
                        model.adjustGPSOffset(by: -0.1)
                    }
                    Button("Retarder le GPS de 1 s (GPS en avance)") {
                        model.adjustGPSOffset(by: -1)
                    }
                    Button("Réinitialiser le décalage GPS") {
                        model.resetGPSOffset()
                    }
                    .disabled(model.gpsOffset == 0)
                    Divider()
                    Button(model.isTimelineZoomed ? "Désactiver le zoom timeline" : "Zoomer la timeline") {
                        model.toggleTimelineZoom()
                    }

                    Toggle(
                        "Afficher les axes 3D",
                        isOn: Binding(
                            get: { model.shows3DAxes },
                            set: { _ in model.toggle3DAxes() }
                        )
                    )
                    Toggle(
                        "Afficher la grille verticale",
                        isOn: Binding(
                            get: { model.showsVerticalGrid },
                            set: { _ in model.toggleVerticalGrid() }
                        )
                    )
                    Toggle(
                        "Afficher la traînée 3D",
                        isOn: Binding(
                            get: { model.showsTrajectoryTrail },
                            set: { _ in model.toggleTrajectoryTrail() }
                        )
                    )
                    Toggle(
                        "Incruster la Cam 3D sur la vidéo de droite",
                        isOn: Binding(
                            get: { model.showsChaseCamInset },
                            set: { _ in model.toggleChaseCamInset() }
                        )
                    )
                    Toggle(
                        "Orienter l'avion sur le cap absolu",
                        isOn: Binding(
                            get: { model.usesAbsoluteHeading },
                            set: { _ in model.toggleAbsoluteHeading() }
                        )
                    )
                    if model.hasSecondaryGPS {
                        Divider()
                        Toggle(
                            "Source GPS : principal GNS3000",
                            isOn: Binding(
                                get: { model.activeGPSSource == .primary },
                                set: { _ in model.setGPSSource(.primary) }
                            )
                        )
                        Toggle(
                            "Source GPS : GPS2 GPX",
                            isOn: Binding(
                                get: { model.activeGPSSource == .secondary },
                                set: { _ in model.setGPSSource(.secondary) }
                            )
                        )
                        Toggle(
                            "Afficher les 2 GPS en 3D",
                            isOn: Binding(
                                get: { model.showsBothGPSTrajectories },
                                set: { _ in model.toggleBothGPSTrajectories() }
                            )
                        )
                        Divider()
                    }

                    Toggle(
                        "Montage caméra inversé",
                        isOn: Binding(
                            get: { model.isCameraInverted },
                            set: { _ in model.toggleCameraInversion() }
                        )
                    )
                    .keyboardShortcut("i", modifiers: [])
                } label: {
                    Label(
                        "Calibration \(model.mountingPitch, format: .number.precision(.fractionLength(1)))°",
                        systemImage: "airplane.circle"
                    )
                }
                .disabled(model.samples.isEmpty)

                #if os(macOS)
                Button {
                    recorder.toggleRecording()
                } label: {
                    Label(
                        recorder.isRecording ? "Arrêter l’enregistrement" : "Enregistrer",
                        systemImage: recorder.isRecording ? "stop.circle.fill" : "record.circle"
                    )
                }
                .tint(recorder.isRecording ? .red : nil)
                #endif

                Button {
                    model.toggleAudioMuted()
                } label: {
                    Label(
                        model.isAudioMuted ? "Réactiver le son" : "Couper le son",
                        systemImage: model.isAudioMuted ? "speaker.slash.fill" : "speaker.wave.2.fill"
                    )
                }
                .keyboardShortcut("m", modifiers: [])
                .disabled(model.samples.isEmpty)

                Menu {
                    Button("Ajouter un bookmark") {
                        isBookmarkDialogPresented = true
                    }

                    Button("Recharger bookmark.csv") {
                        model.reloadBookmarks()
                    }
                    .keyboardShortcut("r", modifiers: .control)

                    Button("Ouvrir bookmark.csv") {
                        model.openBookmarksFile()
                    }
                } label: {
                    Label("Favoris", systemImage: "bookmark")
                }
                .disabled(model.samples.isEmpty)

                    Button {
                        isKeyboardHelpPresented = true
                    } label: {
                        Label("Raccourcis clavier", systemImage: "keyboard")
                    }
                }
            }
        }
    }

    #if os(macOS)
    private func updateHistoricalMETAR() {
        guard !model.hasBundleWriteAuthorization else {
            model.updateHistoricalMETAR()
            return
        }
        guard let bundleURL = model.bundleURL else { return }

        let panel = NSOpenPanel()
        panel.title = "Autoriser la mise à jour du vol"
        panel.message = "Sélectionnez à nouveau \(bundleURL.lastPathComponent) pour autoriser l’écriture de metar.csv."
        panel.prompt = "Autoriser"
        panel.directoryURL = bundleURL.deletingLastPathComponent()
        panel.nameFieldStringValue = bundleURL.lastPathComponent
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let authorizedURL = panel.url else { return }
        model.authorizeBundleForWritingAndUpdateMETAR(authorizedURL)
    }
    #endif

    private func openBundlePanel() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.title = "Ouvrir un bundle ABView"
        panel.message = "Sélectionnez un dossier ou un paquet .abv contenant merged_data.csv."
        panel.prompt = "Ouvrir"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = []

        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.openBundle(url)
        preferredCompactColumn = .detail
        #else
        isBundleImporterPresented = true
        #endif
    }
}

/// Alertes d'erreur du vol, de l'enregistrement et de la mise à jour METAR. Extraites du `body` de
/// `ContentView`, dont la chaîne de modificateurs devenait trop longue pour le compilateur.
private struct FlightErrorAlerts: ViewModifier {
    let model: FlightViewModel
    let recorder: ScreenRecorder

    func body(content: Content) -> some View {
        content
            .alert(
                "Erreur d’enregistrement",
                isPresented: Binding(
                    get: { recorder.errorMessage != nil },
                    set: { if !$0 { recorder.dismissError() } }
                )
            ) {
                Button("OK") { recorder.dismissError() }
            } message: {
                Text(recorder.errorMessage ?? "")
            }
            .alert(
                "Impossible d’ouvrir le vol",
                isPresented: Binding(
                    get: { model.errorMessage != nil },
                    set: { if !$0 { model.dismissError() } }
                )
            ) {
                Button("OK") { model.dismissError() }
            } message: {
                Text(model.errorMessage ?? "")
            }
            .alert(
                "Mise à jour METAR",
                isPresented: Binding(
                    get: { model.metarUpdateMessage != nil },
                    set: { if !$0 { model.dismissMETARUpdateMessage() } }
                )
            ) {
                Button("OK") { model.dismissMETARUpdateMessage() }
            } message: {
                Text(model.metarUpdateMessage ?? "")
            }
    }
}

struct FlightSidebar: View {
    let bundleName: String?
    let recentBundles: [RecentBundle]
    let bookmarks: [FlightBookmark]
    let onOpen: () -> Void
    let onSelectRecent: (RecentBundle) -> Void
    let onShowFlight: () -> Void
    let onOpenBookmarksFile: () -> Void
    let onReloadBookmarks: () -> Void
    let onSelectBookmark: (FlightBookmark) -> Void

    var body: some View {
        List {
            Section("Vol") {
                if let bundleName {
                    Label(bundleName, systemImage: "airplane")
                }
                Button(action: onOpen) {
                    Label(
                        bundleName == nil ? "Ouvrir un bundle .abv" : "Ouvrir un autre fichier…",
                        systemImage: "folder.badge.plus"
                    )
                }
            }

            if !recentBundles.isEmpty {
                Section("Derniers vols") {
                    ForEach(recentBundles) { recent in
                        Button {
                            onSelectRecent(recent)
                        } label: {
                            HStack {
                                Label(recent.name, systemImage: "clock.arrow.circlepath")
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                if recent.name == bundleName {
                                    Image(systemName: "checkmark")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Section("Favoris") {
                Button(action: onOpenBookmarksFile) {
                    Label("Éditer bookmark.csv", systemImage: "square.and.pencil")
                }
                .disabled(bundleName == nil)
                Button(action: onReloadBookmarks) {
                    Label("Recharger bookmark.csv", systemImage: "arrow.clockwise")
                }
                .disabled(bundleName == nil)
                if bookmarks.isEmpty {
                    Text("Aucun favori")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(bookmarks) { bookmark in
                        Button {
                            onSelectBookmark(bookmark)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(bookmark.name)
                                Text(bookmark.displayTime)
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .navigationTitle("ABView")
        #if os(iOS)
        .toolbar {
            if isRunningOnIPhone, bundleName != nil {
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: onShowFlight) {
                        Label("Retour au vol", systemImage: "airplane")
                    }
                }
            }
        }
        #endif
    }
}

struct FlightWorkspace: View {
    let model: FlightViewModel
    let isRecording: Bool
    let onOpen: () -> Void
    let onToggleRecording: () -> Void
    let onOpenChaseCam: () -> Void
    let onAddBookmark: () -> Void
    let onDetachFront: () -> Void
    let onDetachBack: () -> Void
    let onDetachAircraft: () -> Void
    let onDetachFlightPath: () -> Void
    let onOpenChaseCam3D: () -> Void
    @State private var fullScreenVideo: FlightVideoSelection?
    @State private var fullScreenInstrument: FlightInstrumentSelection?

    var body: some View {
        if model.isLoading {
            VStack(spacing: 14) {
                ProgressView(value: model.loadingProgress) {
                    Text("Chargement du vol…")
                } currentValueLabel: {
                    Text(model.loadingProgress, format: .percent.precision(.fractionLength(0)))
                }
                .progressViewStyle(.linear)
                .frame(maxWidth: 320)

                Button("Annuler", role: .cancel) {
                    model.cancelLoading()
                }
                .buttonStyle(.bordered)
            }
            .padding()
        } else if model.samples.isEmpty {
            ContentUnavailableView {
                Label("Aucun vol ouvert", systemImage: "airplane.circle")
            } description: {
                Text("Sélectionnez un dossier .abv contenant merged_data.csv et les vidéos.")
            } actions: {
                Button("Ouvrir un vol", action: onOpen)
                    .buttonStyle(.borderedProminent)
            }
        } else {
            GeometryReader { proxy in
                #if os(iOS)
                if UIDevice.current.userInterfaceIdiom == .phone {
                    if proxy.size.height > proxy.size.width {
                        IPhonePortraitFlightView(
                            model: model,
                            onAddBookmark: onAddBookmark,
                            onOpenFullScreen: { fullScreenVideo = $0 }
                        )
                    } else {
                        IPhoneLandscapeFlightView(
                            model: model,
                            onAddBookmark: onAddBookmark,
                            onOpenFullScreen: { fullScreenVideo = $0 }
                        )
                    }
                } else {
                    regularWorkspace(in: proxy.size)
                }
                #else
                regularWorkspace(in: proxy.size)
                #endif
            }
            #if os(iOS)
            .toolbar {
                if !isRunningOnIPhone {
                    ToolbarItem(placement: .navigation) {
                        playbackControls
                    }
                }
            }
            .fullScreenCover(item: $fullScreenVideo) { selection in
                FullScreenFlightVideo(
                    model: model,
                    selection: selection,
                    onDismiss: { fullScreenVideo = nil }
                )
            }
            .fullScreenCover(item: $fullScreenInstrument) { selection in
                FullScreenFlightInstrument(model: model, onDismiss: { fullScreenInstrument = nil }) {
                    instrumentContent(for: selection)
                }
            }
            #endif
        }
    }

    @ViewBuilder
    private func instrumentContent(for selection: FlightInstrumentSelection) -> some View {
        switch selection {
        case .aircraft:
            aircraftView(sample: model.renderingSample)
        case .flightPath:
            FlightPath3DView(model: model)
        case .map:
            FlightMapView(
                coordinates: model.routeCoordinates,
                sample: model.currentSample,
                metar: model.currentMETAR,
                routeProgress: model.routeProgress
            )
        }
    }

    private func regularWorkspace(in size: CGSize) -> some View {
        // Ce corps ne lit aucune valeur du modèle qui change pendant la lecture : chaque bloc
        // est enveloppé dans un `ObservationScope` pour que seul le bloc concerné soit
        // réévalué à chaque tick de `currentIndex`, et non tout l'espace de travail.
        VStack(spacing: 6) {
            ObservationScope { videoRow }
                .frame(height: max(320, size.height * 0.48))

            instrumentRow
                .frame(maxHeight: .infinity)
                .layoutPriority(1)

            ObservationScope {
                CompactTelemetryStrips(
                    samples: model.chartSamples,
                    currentTime: model.slowTime,
                    duration: model.duration,
                    isZoomed: model.isTimelineZoomed,
                    mountingPitch: model.mountingPitch,
                    maximumAltitude: model.maximumAltitude,
                    bookmarks: model.bookmarks,
                    videoFrameRate: model.frontVideoFrameRate
                )
            }
            .frame(height: 54)

            ObservationScope {
                ZStack(alignment: .leading) {
                    BookmarkTimelineSlider(
                        value: Binding(
                            get: { model.slowTime },
                            set: model.seek
                        ),
                        duration: model.duration,
                        bookmarks: model.bookmarks,
                        videoFrameRate: model.frontVideoFrameRate
                    )

                    Text(model.slowTime.clockString)
                        .font(.caption.monospacedDigit())
                        .frame(width: 48, alignment: .trailing)
                }
            }

            #if os(macOS)
            ObservationScope { playbackControls }
            #endif
        }
        .padding(6)
    }

    /// Chase cam 3D en petit format, en haut à gauche de la vidéo de droite ; un clic ouvre la fenêtre.
    private var chaseCamInset: some View {
        ChaseCamInsetView(model: model, onOpen: onOpenChaseCam3D)
    }

    private var videoRow: some View {
        HStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                VideoPane(
                    title: "Caméra avant",
                    player: model.displayedFrontPlayer,
                    timestamp: nil,
                    elapsedTime: model.currentTime,
                    previousBookmark: model.previousBookmarkName,
                    upcomingBookmark: model.upcomingBookmarkName,
                    flightSample: model.currentSample,
                    showsFlightData: true,
                    timestampAlignment: .topTrailing,
                    mountingPitch: model.mountingPitch,
                    isCameraInverted: model.isCameraInverted,
                    overlayStyle: isRunningOnIPhone ? .headingOnly : .standard
                )
                #if os(macOS)
                detachButton(action: onDetachFront)
                #endif
            }
            #if os(macOS)
            .contentShape(Rectangle())
            .onTapGesture(count: 2, perform: onDetachFront)
            #else
            .contentShape(Rectangle())
            .onTapGesture {
                fullScreenVideo = .front
            }
            #endif
            ZStack(alignment: .topTrailing) {
                VideoPane(
                    title: "Caméra arrière",
                    player: model.displayedBackPlayer,
                    timestamp: model.currentSample?.timestamp,
                    elapsedTime: model.currentTime,
                    previousBookmark: model.previousBookmarkName,
                    upcomingBookmark: model.upcomingBookmarkName,
                    flightSample: model.currentSample,
                    timestampAlignment: .bottomTrailing,
                    overlayStyle: isRunningOnIPhone ? .headingOnly : .standard
                )
                VStack(alignment: .trailing, spacing: 4) {
                    #if os(macOS)
                    detachButton(action: onDetachBack)
                    #endif
                    PlaybackDiagnosticsOverlay(
                        currentFrame: model.currentVideoFrame,
                        playbackCorrectionCount: model.playbackCorrectionCount,
                        videoFrameRate: model.frontVideoFrameRate,
                        synchronizationError: model.videoSynchronizationError
                    )
                }
                .padding(8)
            }
            #if os(macOS)
            .contentShape(Rectangle())
            .onTapGesture(count: 2, perform: onDetachBack)
            #else
            .contentShape(Rectangle())
            .onTapGesture {
                fullScreenVideo = .back
            }
            #endif
            // Posée après les gestes de la vidéo : un clic sur l'incrustation n'ouvre pas la vidéo.
            .overlay(alignment: .topLeading) {
                if model.showsChaseCamInset && !model.isChaseCam3DWindowOpen {
                    chaseCamInset
                }
            }
        }
    }

    private var instrumentRow: some View {
        GeometryReader { proxy in
            instrumentRowContent(in: proxy.size)
        }
    }

    private func instrumentRowContent(in workspaceSize: CGSize) -> some View {
        HStack(spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    ObservationScope { aircraftView(sample: model.renderingSample) }
                    ObservationScope {
                        AircraftReadoutOverlay(
                            sample: model.currentSample,
                            loadFactor: model.currentSignedLoadFactor,
                            minimumLoadFactor: model.minimumLoadFactor,
                            maximumLoadFactor: model.maximumLoadFactor,
                            mountingPitch: model.mountingPitch,
                            isCameraInverted: model.isCameraInverted
                        )
                    }
                    .padding(8)
                }
                #if os(macOS)
                // En overlay du conteneur plutôt qu'en frère plein cadre dans le ZStack : un
                // frère `.frame(maxWidth: .infinity, maxHeight: .infinity)` au-dessus d'une
                // SCNView NSViewRepresentable n'est pas fiable pour recevoir le clic.
                // En bas à gauche : le coin bas droit porte déjà les lectures Pitch/Bank.
                .overlay(alignment: .bottomLeading) {
                    detachButton(action: onDetachAircraft)
                }
                #endif
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .frame(minWidth: 280)
                .layoutPriority(1)
                #if !os(macOS)
                .contentShape(Rectangle())
                .onTapGesture {
                    fullScreenInstrument = .aircraft
                }
                #endif

                // The two horizon gauges stack vertically with 8pt between them;
                // sizing from that so their combined height matches the STL pane
                // next to them, instead of a width-driven proportion that could
                // run taller than the row and get clipped.
                let horizonSize = max(60, (workspaceSize.height - 8) / 2)

                ObservationScope {
                    TelemetryPanel(
                        sample: model.currentSample,
                        signedLoadFactor: model.currentSignedLoadFactor,
                        mountingPitch: model.mountingPitch,
                        isCameraInverted: model.isCameraInverted,
                        horizonSize: horizonSize
                    )
                }
                .frame(width: horizonSize, height: horizonSize * 2 + 8)
                .frame(maxHeight: .infinity)

                ZStack(alignment: .bottom) {
                    FlightPath3DView(model: model)
                    #if os(macOS)
                    detachButton(action: onDetachFlightPath)
                    #endif
                }
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .frame(minWidth: 280)
                .layoutPriority(1)
                #if !os(macOS)
                .contentShape(Rectangle())
                .onTapGesture {
                    fullScreenInstrument = .flightPath
                }
                #endif

                ObservationScope {
                    FlightMapView(
                        coordinates: model.routeCoordinates,
                        sample: model.slowSample,
                        metar: model.slowMETAR,
                        routeProgress: model.slowRouteProgress
                    )
                }
                .frame(minWidth: 260)
                #if !os(macOS)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    fullScreenInstrument = .map
                }
                #endif
        }
    }

    private func aircraftView(sample: FlightSample?) -> some View {
        Aircraft3DView(
            quaternionW: sample?.quaternionW ?? 1,
            quaternionX: sample?.quaternionX ?? 0,
            quaternionY: sample?.quaternionY ?? 0,
            quaternionZ: sample?.quaternionZ ?? 0,
            modelURL: model.aircraftModelURL,
            mountingPitch: model.mountingPitch,
            isInverted: model.isCameraInverted,
            showsAxes: model.shows3DAxes,
            showsVerticalGrid: model.showsVerticalGrid,
            showsTrajectoryTrail: model.showsTrajectoryTrail,
            usesAbsoluteHeading: model.usesAbsoluteHeading,
            accelerationX: sample?.accelerationX ?? 0,
            accelerationY: sample?.accelerationY ?? 0,
            accelerationZ: sample?.accelerationZ ?? 0,
            speed: sample?.speed ?? 0,
            samples: model.samples,
            samplesRevision: model.samplesRevision,
            player: model.frontPlayer
        )
    }

    private var playbackControls: some View {
        PlaybackControls(
            isPlaying: model.isPlaying,
            duration: model.duration,
            isRecording: isRecording,
            onPlayPause: model.togglePlayback,
            onJumpBackward: { model.jump(by: -10) },
            onJumpForward: { model.jump(by: 10) },
            onFineJumpBackward: { model.jump(by: -2) },
            onFineJumpForward: { model.jump(by: 2) },
            onToggleRecording: onToggleRecording,
            onOpenChaseCam: onOpenChaseCam,
            onAddBookmark: onAddBookmark,
            onPreviousBookmark: model.previousBookmark,
            onNextBookmark: model.nextBookmark,
            onTakeoff: model.goToTakeoff,
            onLevelFlight: model.seekNextLevelFlight
        )
    }

    private func detachButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label("Détacher", systemImage: "arrow.up.forward.app")
        }
        .labelStyle(.titleAndIcon)
        .buttonStyle(.plain)
        .font(.caption)
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.black.opacity(0.65), in: Capsule())
        .padding(6)
        .help("Détacher cette vue")
    }
}

/// Évalue son contenu dans son propre corps : les valeurs observées lues par `content`
/// n'invalident que cette vue, et non la vue parente qui la construit.
/// Incrustation de la chase cam 3D (en haut à gauche de la vidéo de droite) ; un clic ouvre la fenêtre.
/// Vue isolée avec ses propres options : le menu contextuel n'est pas reconstruit (clignotement)
/// quand `FlightWorkspace` se réévalue.
private struct ChaseCamInsetView: View {
    let model: FlightViewModel
    let onOpen: () -> Void
    @State private var options = ChaseCam3DOptions()

    var body: some View {
        ChaseCam3DView(model: model, isInset: true, insetOptions: options)
            .frame(width: 240, height: 150)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.5), lineWidth: 1))
            // La vue SceneKit capte les clics : un calque transparent les reçoit à sa place.
            .overlay {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onOpen)
                    .contextMenu {
                        ForEach(ChaseCam3DPreset.allCases) { preset in
                            Button {
                                options.preset = preset
                            } label: {
                                if options.preset == preset {
                                    Label(preset.rawValue, systemImage: "checkmark")
                                } else {
                                    Text(preset.rawValue)
                                }
                            }
                        }
                        Divider()
                        Toggle("Trajectoire complète", isOn: $options.showsFullPath)
                        Toggle("Vue satellite", isOn: $options.showsSatellite)
                        Toggle("GPS Smoothing", isOn: $options.smoothsGPS)
                        Divider()
                        Button("Ouvrir la fenêtre Cam 3D", action: onOpen)
                        Button("Masquer l'incrustation") { model.toggleChaseCamInset() }
                    }
            }
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .accessibilityLabel("Chase cam 3D")
            .accessibilityAddTraits(.isButton)
    }
}

private struct ObservationScope<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
    }
}

private struct PlaybackDiagnosticsOverlay: View {
    let currentFrame: Int
    let playbackCorrectionCount: Int
    let videoFrameRate: Double
    let synchronizationError: TimeInterval

    var body: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text("Frame : \(currentFrame)")
            Text("Corrections : \(playbackCorrectionCount)")
            Text("FPS : \(videoFrameRate, format: .number.precision(.fractionLength(2)))")
            Text("Dérive : \(synchronizationError * 1_000, format: .number.precision(.fractionLength(0))) ms")
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.black.opacity(0.7))
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(.white.opacity(0.78), in: RoundedRectangle(cornerRadius: 4))
        .allowsHitTesting(false)
    }
}

enum FlightVideoSelection: String, Identifiable {
    case front
    case back

    var id: String { rawValue }
}

private struct FullScreenFlightVideo: View {
    let model: FlightViewModel
    let selection: FlightVideoSelection
    let onDismiss: () -> Void

    private var isFrontVideo: Bool {
        selection == .front
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black
                .ignoresSafeArea()

            VideoPane(
                title: isFrontVideo ? "Caméra avant" : "Caméra arrière",
                player: isFrontVideo ? model.displayedFrontPlayer : model.displayedBackPlayer,
                timestamp: isFrontVideo ? nil : model.currentSample?.timestamp,
                elapsedTime: model.currentTime,
                previousBookmark: model.previousBookmarkName,
                upcomingBookmark: model.upcomingBookmarkName,
                flightSample: model.currentSample,
                showsFlightData: isFrontVideo,
                timestampAlignment: isFrontVideo ? .topTrailing : .topLeading,
                mountingPitch: model.mountingPitch,
                isCameraInverted: model.isCameraInverted,
                overlayStyle: isRunningOnIPhone ? .headingOnly : .standard
            )
            .ignoresSafeArea()

            Button(action: onDismiss) {
                Label("Fermer le plein écran", systemImage: "xmark.circle.fill")
                    .font(.title)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .padding(20)

            FullScreenPlaybackScrubber(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onDismiss)
        #if os(iOS)
        .task {
            guard isRunningOnIPhone else { return }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(100))
            AppOrientationController.request(.landscape)
        }
        .onDisappear {
            guard isRunningOnIPhone else { return }
            AppOrientationController.request(.portrait)
        }
        #endif
    }
}

enum FlightInstrumentSelection: String, Identifiable {
    case aircraft
    case flightPath
    case map

    var id: String { rawValue }
}

private struct FullScreenFlightInstrument<Content: View>: View {
    let model: FlightViewModel
    let onDismiss: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black
                .ignoresSafeArea()

            content
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(count: 2, perform: onDismiss)

            Button(action: onDismiss) {
                Label("Fermer le plein écran", systemImage: "xmark.circle.fill")
                    .font(.title)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .padding(20)

            FullScreenPlaybackScrubber(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        #if os(iOS)
        .task {
            guard isRunningOnIPhone else { return }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(100))
            AppOrientationController.request(.landscape)
        }
        .onDisappear {
            guard isRunningOnIPhone else { return }
            AppOrientationController.request(.portrait)
        }
        #endif
    }
}

private struct FullScreenPlaybackScrubber: View {
    let model: FlightViewModel

    var body: some View {
        ZStack(alignment: .leading) {
            BookmarkTimelineSlider(
                value: Binding(
                    get: { model.currentTime },
                    set: model.seek
                ),
                duration: model.duration,
                bookmarks: model.bookmarks,
                videoFrameRate: model.frontVideoFrameRate
            )

            Text(model.currentTime.clockString)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: 48, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 20)
    }
}

private struct AircraftReadoutOverlay: View {
    let sample: FlightSample?
    let loadFactor: Double
    let minimumLoadFactor: Double
    let maximumLoadFactor: Double
    let mountingPitch: Double
    let isCameraInverted: Bool

    private var attitude: Attitude {
        sample?.attitude(mountingPitch: mountingPitch, isInverted: isCameraInverted)
            ?? Attitude(roll: 0, pitch: 0)
    }

    var body: some View {
        VStack {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    readout("GS", value: sample?.speed ?? 0, unit: "km/h", color: .green, prominent: true)
                    readout("Alt", value: sample?.altitude ?? 0, unit: "ft", color: .blue, prominent: true)
                    Text("\(sample?.verticalSpeed ?? 0, format: .number.precision(.fractionLength(0))) ft/min")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 1) {
                    Text("G: \(loadFactor, format: .number.precision(.fractionLength(1)))")
                        .font(.title2.monospacedDigit().bold())
                        .foregroundStyle(loadFactorColor)
                    Text("Gmin \(minimumLoadFactor, format: .number.precision(.fractionLength(1)))")
                    Text("Gmax \(maximumLoadFactor, format: .number.precision(.fractionLength(1)))")
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(8)
        .overlay(alignment: .bottomTrailing) {
            VStack(alignment: .trailing, spacing: 4) {
                readout("Pitch", value: attitude.pitch, unit: "°", color: .green)
                readout("Bank", value: attitude.roll, unit: "°", color: .blue)
            }
            .padding(.trailing, 8)
            .padding(.bottom, 8)
        }
        .allowsHitTesting(false)
    }

    private func readout(
        _ label: LocalizedStringKey,
        value: Double,
        unit: LocalizedStringKey,
        color: Color,
        prominent: Bool = false
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(label)
            Text(value, format: .number.precision(.fractionLength(0)))
            Text(unit)
        }
        .font(prominent ? .title2.monospacedDigit() : .body.monospacedDigit())
        .fontWeight(.bold)
        .foregroundStyle(color)
    }

    private var loadFactorColor: Color {
        if loadFactor < 0.8 { return .blue }
        if loadFactor > 2 { return .red }
        return .green
    }
}

#Preview {
    ContentView()
}
