import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var model = FlightViewModel()
    @State private var recorder = ScreenRecorder()
    @State private var detachedWindows = DetachedWindowManager()
    @State private var isImporterPresented = false
    @State private var isSTLImporterPresented = false
    @State private var isChaseCamPresented = false
    @State private var isKeyboardHelpPresented = false
    @State private var bookmarkName = ""
    @State private var isBookmarkDialogPresented = false

    var body: some View {
        NavigationSplitView {
            FlightSidebar(
                bundleName: model.bundleURL?.lastPathComponent,
                bookmarks: model.bookmarks,
                figures: model.figures,
                onOpen: { isImporterPresented = true },
                onSelectBookmark: model.goToBookmark,
                onSelectFigure: model.goToFigure
            )
            .navigationSplitViewColumnWidth(min: 190, ideal: 240)
        } detail: {
            FlightWorkspace(
                model: model,
                onOpen: { isImporterPresented = true }
            )
        }
        .frame(minWidth: 1_100, minHeight: 720)
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                model.openBundle(url)
            }
        }
        .fileImporter(
            isPresented: $isSTLImporterPresented,
            allowedContentTypes: [UTType(filenameExtension: "stl") ?? .data],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                model.setAircraftModel(url)
            }
        }
        .alert("Ajouter un favori", isPresented: $isBookmarkDialogPresented) {
            TextField("Nom", text: $bookmarkName)
            Button("Ajouter") {
                let name = bookmarkName.trimmingCharacters(in: .whitespacesAndNewlines)
                model.addBookmark(named: name.isEmpty ? "Favori" : name)
                bookmarkName = ""
            }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Le favori sera créé à (model.currentTime.clockString).")
        }
        .sheet(isPresented: $isChaseCamPresented) {
            ChaseCamView(samples: model.samples, sample: model.currentSample)
        }
        .sheet(isPresented: $isKeyboardHelpPresented) {
            KeyboardShortcutsView()
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
        .toolbar {
            ToolbarItemGroup {
                Button {
                    isImporterPresented = true
                } label: {
                    Label("Ouvrir un vol", systemImage: "folder")
                }
                Button {
                    isChaseCamPresented = true
                } label: {
                    Label("Chase Cam", systemImage: "map")
                }
                .disabled(model.samples.isEmpty)

                Button {
                    model.analyzeFlight()
                } label: {
                    if model.isAnalyzingFlight {
                        Label("Analyse en cours…", systemImage: "waveform.path.ecg")
                    } else {
                        Label("Analyser les figures", systemImage: "figure.mind.and.body")
                    }
                }
                .disabled(model.samples.isEmpty || model.isAnalyzingFlight)

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

                Menu {
                    Button("Importer un modèle STL…") {
                        isSTLImporterPresented = true
                    }
                    Divider()
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

                    Menu("Fenêtre timeline : \(Int(model.timelineWindow)) s") {
                        Button("Trace +20 s") {
                            model.increaseTimelineWindow()
                        }
                        Button("Trace −20 s") {
                            model.decreaseTimelineWindow()
                        }
                        Button("Réinitialiser à 60 s") {
                            model.resetTimelineWindow()
                        }
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

                Button {
                    recorder.toggleRecording(destinationDirectory: model.bundleURL)
                } label: {
                    Label(
                        recorder.isRecording ? "Arrêter l’enregistrement" : "Enregistrer",
                        systemImage: recorder.isRecording ? "stop.circle.fill" : "record.circle"
                    )
                }
                .tint(recorder.isRecording ? .red : nil)

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
                    Button("Ajouter un favori") {
                        isBookmarkDialogPresented = true
                    }
                    .keyboardShortcut("b", modifiers: .control)

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

struct FlightSidebar: View {
    let bundleName: String?
    let bookmarks: [FlightBookmark]
    let figures: [FlightFigure]
    let onOpen: () -> Void
    let onSelectBookmark: (FlightBookmark) -> Void
    let onSelectFigure: (FlightFigure) -> Void

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

            Section("Figures détectées") {
                if figures.isEmpty {
                    Text("Aucune figure détectée")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(figures) { figure in
                        Button {
                            onSelectFigure(figure)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(figure.kind.rawValue)
                                Text("\(figure.startTime.clockString) · \(figure.duration, format: .number.precision(.fractionLength(1))) s")
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
    }
}

struct FlightWorkspace: View {
    let model: FlightViewModel
    let onOpen: () -> Void

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
            VStack(spacing: 10) {
                HSplitView {
                    VStack(spacing: 8) {
                        HStack(spacing: 8) {
                            VideoPane(
                                title: "Caméra avant",
                                player: model.displayedFrontPlayer,
                                timestamp: model.currentSample?.timestamp,
                                elapsedTime: model.currentTime,
                                previousBookmark: model.previousBookmarkName,
                                upcomingBookmark: model.upcomingBookmarkName,
                                flightSample: model.currentSample,
                                showsFlightData: true,
                                mountingPitch: model.mountingPitch,
                                isCameraInverted: model.isCameraInverted
                            )
                            VideoPane(
                                title: "Caméra arrière",
                                player: model.displayedBackPlayer,
                                timestamp: model.currentSample?.timestamp,
                                elapsedTime: model.currentTime,
                                previousBookmark: model.previousBookmarkName,
                                upcomingBookmark: model.upcomingBookmarkName,
                                flightSample: model.currentSample
                            )
                        }
                        .frame(minHeight: 260)

                        HStack(spacing: 8) {
                            FlightMapView(
                                coordinates: model.routeCoordinates,
                                sample: model.currentSample,
                                metar: model.currentMETAR
                            )
                            .frame(minWidth: 300)

                            Aircraft3DView(
                                quaternionW: model.currentSample?.quaternionW ?? 1,
                                quaternionX: model.currentSample?.quaternionX ?? 0,
                                quaternionY: model.currentSample?.quaternionY ?? 0,
                                quaternionZ: model.currentSample?.quaternionZ ?? 0,
                                modelURL: model.aircraftModelURL,
                                mountingPitch: model.mountingPitch,
                                isInverted: model.isCameraInverted,
                                showsAxes: model.shows3DAxes,
                                showsVerticalGrid: model.showsVerticalGrid,
                                accelerationX: model.currentSample?.accelerationX ?? 0,
                                accelerationY: model.currentSample?.accelerationY ?? 0,
                                accelerationZ: model.currentSample?.accelerationZ ?? 0,
                                speed: model.currentSample?.speed ?? 0
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .frame(minWidth: 280)

                            TelemetryPanel(
                                sample: model.currentSample,
                                signedLoadFactor: model.currentSignedLoadFactor,
                                mountingPitch: model.mountingPitch,
                                isCameraInverted: model.isCameraInverted
                            )
                            .frame(width: 300)
                        }
                        .frame(minHeight: 280)
                    }
                }

                if !model.currentMETAR.isEmpty {
                    Text(model.currentMETAR)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                }

                FlightStatisticsView(
                    minimumLoadFactor: model.minimumLoadFactor,
                    maximumLoadFactor: model.maximumLoadFactor,
                    maximumAltitude: model.maximumAltitude,
                    videoOffset: model.backVideoOffset,
                    currentFrame: model.currentVideoFrame,
                    synchronizationError: model.videoSynchronizationError
                )

                HStack(spacing: 8) {
                    TelemetryTimeline(
                        samples: model.chartSamples,
                        currentTime: model.currentTime,
                        duration: model.duration,
                        isZoomed: model.isTimelineZoomed,
                        window: model.timelineWindow,
                        mountingPitch: model.mountingPitch
                    )
                    EnergyTimelineView(
                        samples: model.chartSamples,
                        currentTime: model.currentTime,
                        duration: model.duration,
                        isZoomed: model.isTimelineZoomed,
                        window: model.timelineWindow
                    )
                }

                Slider(
                    value: Binding(
                        get: { model.currentTime },
                        set: model.seek
                    ),
                    in: 0...max(0.01, model.duration)
                )

                PlaybackControls(
                    isPlaying: model.isPlaying,
                    currentTime: model.currentTime,
                    duration: model.duration,
                    onPlayPause: model.togglePlayback,
                    onJump: model.jump,
                    onPreviousBookmark: model.previousBookmark,
                    onNextBookmark: model.nextBookmark,
                    onPreviousFigure: model.previousFigure,
                    onNextFigure: model.nextFigure,
                    onTakeoff: model.goToTakeoff,
                    onLevelFlight: model.seekNextLevelFlight
                )

            }
            .padding(10)
        }
    }
}

#Preview {
    ContentView()
}
