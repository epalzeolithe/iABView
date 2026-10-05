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

struct ContentView: View {
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif
    var initialBundleURL: URL? = nil
    @State private var model = FlightViewModel()
    @State private var recorder = ScreenRecorder()
    @State private var detachedWindows = DetachedWindowManager()
    @State private var isChaseCamPresented = false
    @State private var isKeyboardHelpPresented = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .detailOnly
    @State private var preferredCompactColumn: NavigationSplitViewColumn = .detail
    @State private var bookmarkName = ""
    @State private var isBookmarkDialogPresented = false
    @State private var isLastBundleDialogPresented = false
    @State private var didAskToRestoreLastBundle = false
    @State private var isBundleImporterPresented = false

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
                    recorder.toggleRecording(destinationDirectory: model.bundleURL)
                },
                onOpenChaseCam: { isChaseCamPresented = true },
                onAddBookmark: { isBookmarkDialogPresented = true },
                onDetachFront: { detachedWindows.showFrontVideo(model: model) },
                onDetachBack: { detachedWindows.showBackVideo(model: model) },
                onDetachAircraft: { detachedWindows.showAircraft(model: model) },
                onDetachFlightPath: { detachedWindows.showGPS(model: model) }
            )
        }
        #if os(macOS)
        .frame(minWidth: 1_100, minHeight: 720)
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
            Text("Le bookmark sera créé à \(model.currentTime.clockString).")
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
                        Label("Cam", systemImage: "map")
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
                    Button(model.isTimelineZoomed ? "Désactiver le zoom timeline" : "Zoomer la timeline") {
                        model.toggleTimelineZoom()
                    }
                    .keyboardShortcut("z", modifiers: [])

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
                    recorder.toggleRecording(destinationDirectory: model.bundleURL)
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

struct FlightSidebar: View {
    let bundleName: String?
    let recentBundles: [RecentBundle]
    let bookmarks: [FlightBookmark]
    let onOpen: () -> Void
    let onSelectRecent: (RecentBundle) -> Void
    let onShowFlight: () -> Void
    let onSelectBookmark: (FlightBookmark) -> Void

    var body: some View {
        List {
            Section("Vol") {
                if let bundleName {
                    Label(bundleName, systemImage: "airplane")
                } else {
                    Button(action: onOpen) {
                        Label("Ouvrir un bundle .abv", systemImage: "folder.badge.plus")
                    }
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
    @State private var fullScreenVideo: FlightVideoSelection?

    var body: some View {
        if model.isLoading {
            ProgressView("Chargement du vol…")
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
            #endif
        }
    }

    private func regularWorkspace(in size: CGSize) -> some View {
        VStack(spacing: 6) {
            videoRow
                .frame(height: max(250, size.height * 0.36))

            instrumentRow(in: size)
                .frame(maxHeight: .infinity)
                .layoutPriority(1)

            CompactTelemetryStrips(
                samples: model.chartSamples,
                currentTime: model.currentTime,
                duration: model.duration,
                isZoomed: model.isTimelineZoomed,
                mountingPitch: model.mountingPitch,
                maximumAltitude: model.maximumAltitude,
                bookmarks: model.bookmarks,
                videoFrameRate: model.frontVideoFrameRate
            )
            .frame(height: 54)

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
                    .frame(width: 48, alignment: .trailing)
            }

            #if os(macOS)
            playbackControls
            #endif
        }
        .padding(6)
    }

    private var videoRow: some View {
        HStack(spacing: 6) {
            ZStack(alignment: .topLeading) {
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
            .onTapGesture(count: 2) {
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
                #if os(macOS)
                detachButton(action: onDetachBack)
                #endif
            }
            #if os(macOS)
            .contentShape(Rectangle())
            .onTapGesture(count: 2, perform: onDetachBack)
            #else
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                fullScreenVideo = .back
            }
            #endif
        }
    }

    private func instrumentRow(in workspaceSize: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    aircraftView(sample: model.renderingSample)
                    AircraftReadoutOverlay(
                        sample: model.currentSample,
                        loadFactor: model.currentSignedLoadFactor,
                        minimumLoadFactor: model.minimumLoadFactor,
                        maximumLoadFactor: model.maximumLoadFactor,
                        currentFrame: model.currentVideoFrame,
                        playbackCorrectionCount: model.playbackCorrectionCount,
                        videoFrameRate: model.frontVideoFrameRate,
                        videoOffset: model.frontVideoOffset,
                        synchronizationError: model.videoSynchronizationError,
                        mountingPitch: model.mountingPitch,
                        isCameraInverted: model.isCameraInverted
                    )
                    .padding(8)
                    #if os(macOS)
                    detachButton(action: onDetachAircraft)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    #endif
                }
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .frame(minWidth: 280)
                .layoutPriority(1)

                ZStack(alignment: .bottom) {
                    FlightPath3DView(model: model)
                    #if os(macOS)
                    detachButton(action: onDetachFlightPath)
                    #endif
                }
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .frame(minWidth: 280)
                .layoutPriority(1)

                FlightMapView(
                    coordinates: model.routeCoordinates,
                    sample: model.currentSample,
                    metar: model.currentMETAR
                )
                .frame(minWidth: 260)
            }

            #if os(macOS)
            let windowScale = min(workspaceSize.width / 1_440, workspaceSize.height / 900)
            let horizonSize = min(140, max(56, 140 * windowScale))

            TelemetryPanel(
                sample: model.currentSample,
                signedLoadFactor: model.currentSignedLoadFactor,
                mountingPitch: model.mountingPitch,
                isCameraInverted: model.isCameraInverted,
                horizonSize: horizonSize
            )
            .frame(
                width: horizonSize,
                height: horizonSize * 2 + 8,
                alignment: .leading
            )
            .padding(.leading, 8)
            .padding(.top, max(12, workspaceSize.height * 0.015))
            .allowsHitTesting(false)
            #else
            TelemetryPanel(
                sample: model.currentSample,
                signedLoadFactor: model.currentSignedLoadFactor,
                mountingPitch: model.mountingPitch,
                isCameraInverted: model.isCameraInverted
            )
            .frame(width: 145, height: 288, alignment: .leading)
            .padding(.leading, 6)
            .frame(maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, 6)
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
            accelerationX: sample?.accelerationX ?? 0,
            accelerationY: sample?.accelerationY ?? 0,
            accelerationZ: sample?.accelerationZ ?? 0,
            speed: sample?.speed ?? 0,
            samples: model.samples,
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
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(6)
        .help("Détacher cette vue")
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
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onDismiss)
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

private struct AircraftReadoutOverlay: View {
    let sample: FlightSample?
    let loadFactor: Double
    let minimumLoadFactor: Double
    let maximumLoadFactor: Double
    let currentFrame: Int
    let playbackCorrectionCount: Int
    let videoFrameRate: Double
    let videoOffset: TimeInterval
    let synchronizationError: TimeInterval
    let mountingPitch: Double
    let isCameraInverted: Bool

    private var attitude: Attitude {
        sample?.attitude(mountingPitch: mountingPitch, isInverted: isCameraInverted)
            ?? Attitude(roll: 0, pitch: 0)
    }

    var body: some View {
        VStack {
            HStack(alignment: .top) {
                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    readout("GS", value: sample?.speed ?? 0, unit: "km/h", color: .green, prominent: true)
                    readout("Alt", value: sample?.altitude ?? 0, unit: "ft", color: .blue, prominent: true)
                    Text("\(sample?.verticalSpeed ?? 0, format: .number.precision(.fractionLength(0))) ft/min")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

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

            Spacer()

            VStack(spacing: 1) {
                Text("Frame : \(currentFrame)")
                Text("Corrections : \(playbackCorrectionCount)")
                Text("FPS : \(videoFrameRate, format: .number.precision(.fractionLength(2)))")
                Text("Dérive : \(synchronizationError * 1_000, format: .number.precision(.fractionLength(0))) ms")
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.white.opacity(0.78), in: RoundedRectangle(cornerRadius: 4))
        }
        .padding(8)
        .overlay(alignment: .bottomTrailing) {
            VStack(alignment: .trailing, spacing: 4) {
                readout("Pitch", value: attitude.pitch, unit: "°", color: .green)
                readout("Bank", value: attitude.roll, unit: "°", color: .blue)
            }
            .padding(.trailing, 8)
            .padding(.bottom, 42)
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
