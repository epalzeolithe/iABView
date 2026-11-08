#if os(macOS)
import AppKit
#else
import UIKit
#endif
import AVFoundation
import CoreLocation
import Foundation
import Observation

enum GPSSourceChoice: Sendable {
    case primary
    case secondary
}

struct RecentBundle: Identifiable, Hashable, Sendable {
    var id: String { url.path }
    let name: String
    let url: URL
}

private struct RecentBundleRecord: Codable {
    let path: String
    let name: String
    let bookmarkData: Data?
}

@MainActor
@Observable
final class FlightViewModel {
    private static let bundleBookmarkKey = "ABView.lastBundleBookmark"
    private static let recentBundlesKey = "ABView.recentBundles"

    private(set) var bundleURL: URL?
    private(set) var recentBundles: [RecentBundle] = []
    /// Échantillons tels que lus dans merged_data.csv ; `samples` en dérive en appliquant `gpsOffset`.
    private var rawSamples: [FlightSample] = []
    private(set) var samples: [FlightSample] = []
    /// Incrémenté à chaque remplacement de `samples`, pour invalider les caches des vues 3D.
    private(set) var samplesRevision = 0
    /// Avance du GPS en secondes (mémorisée par ABV dans gps_offset.txt) : positive, le GPS est
    /// affiché plus tôt ; à utiliser quand la trajectoire GPS est en retard sur la vidéo.
    private(set) var gpsOffset = 0.0
    private(set) var chartSamples: [FlightSample] = []
    private(set) var routeCoordinates: [CLLocationCoordinate2D] = []
    private(set) var bookmarks: [FlightBookmark] = []
    private(set) var metar: [METARReading] = []
    private(set) var currentIndex = 0
    private(set) var isLoading = false
    private(set) var loadingProgress: Double = 0
    private(set) var isUpdatingMETAR = false
    private(set) var hasBundleWriteAuthorization = false
    private(set) var metarUpdateMessage: String?
    private(set) var errorMessage: String?
    private(set) var isPlaying = false
    private(set) var aircraftModelURL = Bundle.main.url(
        forResource: "CAP10",
        withExtension: "stl"
    )
    private(set) var mountingPitch = 15.0
    private(set) var isCameraInverted = false
    private(set) var isTimelineZoomed = false
    private(set) var frontVideoOffset: TimeInterval = 0
    private(set) var backVideoOffset: TimeInterval = 0
    private(set) var frontVideoFrameRate = 30.0
    private(set) var minimumLoadFactor = 0.0
    private(set) var maximumLoadFactor = 0.0
    private(set) var maximumAltitude = 0.0
    private(set) var maximumSpeed = 0.0
    private(set) var shows3DAxes = true
    private(set) var showsVerticalGrid = false
    private(set) var showsTrajectoryTrail = true
    /// Jeu GPS affiché (le GPS2 n'existe que si l'ABV contient des colonnes `gps2_*`).
    private(set) var activeGPSSource: GPSSourceChoice = .primary
    /// Affiche aussi l'autre jeu GPS dans la vue trajectoire 3D.
    private(set) var showsBothGPSTrajectories = false
    private(set) var secondaryMaximumAltitude = 0.0
    private(set) var secondaryMaximumSpeed = 0.0
    private(set) var isAudioMuted = false
    private(set) var playbackCorrectionCount = 0

    let frontPlayer = AVPlayer()
    let backPlayer = AVPlayer()
    private var timeObserver: Any?
    private var securityScopedURL: URL?
    private var isCorrectingVideoDrift = false
    /// Seeks en cours sur le lecteur avant : tant qu'il y en a, l'observateur de lecture voit encore
    /// l'ancien temps et ne doit pas ramener `currentIndex` en arrière.
    private var pendingSeekCount = 0
    private var loadTask: Task<FlightBundle, Error>?
    private var loadGeneration = 0
    private var lastDriftSeekTime: TimeInterval = 0
    private let videoDriftSeekThreshold: TimeInterval = 0.15
    private let videoDriftSeekCooldown: TimeInterval = 1.0

    init() {
        self.recentBundles = loadRecentBundles()
    }

    var currentSample: FlightSample? {
        guard samples.indices.contains(currentIndex) else { return nil }
        return samples[currentIndex]
    }

    var renderingSample: FlightSample? {
        guard !samples.isEmpty else { return nil }
        return samples[sampleIndex(at: min(duration, currentVideoTime))]
    }

    var currentSignedLoadFactor: Double {
        currentSample?.signedLoadFactor(mountingPitch: mountingPitch) ?? 0
    }

    var routeProgress: Double {
        guard samples.count > 1 else { return 0 }
        return Double(currentIndex) / Double(samples.count - 1)
    }

    var displayedFrontPlayer: AVPlayer {
        isCameraInverted ? backPlayer : frontPlayer
    }

    var displayedBackPlayer: AVPlayer {
        isCameraInverted ? frontPlayer : backPlayer
    }

    var currentVideoFrame: Int {
        max(0, Int(currentVideoTime * frontVideoFrameRate))
    }

    private var currentVideoTime: TimeInterval {
        let time = frontPlayer.currentTime().seconds
        return time.isFinite ? max(0, time) : 0
    }

    var videoSynchronizationError: TimeInterval {
        let frontTime = frontPlayer.currentTime().seconds
        let backTime = backPlayer.currentTime().seconds
        guard frontTime.isFinite, backTime.isFinite else { return 0 }
        return backTime - max(0, frontTime + backVideoOffset)
    }

    var duration: TimeInterval {
        samples.last?.elapsed ?? 0
    }

    var currentTime: TimeInterval {
        currentSample?.elapsed ?? 0
    }

    var currentMETAR: String {
        guard let timestamp = currentSample?.timestamp else { return "" }
        return metar.min(by: {
            abs($0.date.timeIntervalSince(timestamp)) < abs($1.date.timeIntervalSince(timestamp))
        })?.report ?? ""
    }

    var previousBookmarkName: String? {
        bookmarks.last(where: {
            Double($0.frame) / frontVideoFrameRate <= currentVideoTime
        })?.name
    }

    var upcomingBookmarkName: String? {
        bookmarks.first(where: {
            let bookmarkTime = Double($0.frame) / frontVideoFrameRate
            let delay = bookmarkTime - currentVideoTime
            return delay >= 0 && delay <= 1.1
        })?.name
    }

    var lastBundleName: String? {
        recentBundles.first?.name ?? resolvedLastBundleURL()?.lastPathComponent
    }

    func openLastBundle() {
        if let firstRecent = recentBundles.first {
            openBundle(firstRecent.url, grantsWriteAccess: false)
        } else if let url = resolvedLastBundleURL() {
            openBundle(url, grantsWriteAccess: false)
        }
    }

    func openBundle(_ url: URL, grantsWriteAccess: Bool = true) {
        // `loadTask` is the detached task doing the actual work, not a thin
        // wrapper, so cancelling it is what makes the `Task.checkCancellation()`
        // calls inside `FlightBundleLoader` observe cancellation — a wrapper
        // `Task { try await Task.detached { … }.value }` would only mark itself
        // cancelled while the unrelated detached task kept running to completion.
        loadTask?.cancel()
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        loadingProgress = 0
        errorMessage = nil
        let accessGranted = url.startAccessingSecurityScopedResource()
        let model = WeakFlightViewModel(self)

        let task = Task.detached(priority: .userInitiated) {
            try FlightBundleLoader.load(from: url) { fraction in
                Task { @MainActor in
                    guard model.value?.loadGeneration == generation else { return }
                    model.value?.loadingProgress = fraction
                }
            }
        }
        loadTask = task

        Task {
            do {
                let loaded = try await task.value
                guard generation == loadGeneration else { return }
                if let previousURL = securityScopedURL {
                    previousURL.stopAccessingSecurityScopedResource()
                }
                securityScopedURL = accessGranted ? url : nil
                hasBundleWriteAuthorization = grantsWriteAccess
                apply(loaded)
                saveRecentBundle(url)
            } catch is CancellationError {
                if accessGranted { url.stopAccessingSecurityScopedResource() }
            } catch {
                if accessGranted { url.stopAccessingSecurityScopedResource() }
                guard generation == loadGeneration else { return }
                errorMessage = error.localizedDescription
            }
            guard generation == loadGeneration else { return }
            isLoading = false
        }
    }

    func cancelLoading() {
        loadTask?.cancel()
    }

    func dismissError() {
        errorMessage = nil
    }

    func authorizeBundleForWritingAndUpdateMETAR(_ authorizedURL: URL) {
        guard let bundleURL,
              authorizedURL.standardizedFileURL == bundleURL.standardizedFileURL else {
            metarUpdateMessage = "Sélectionnez le fichier .abv actuellement ouvert."
            return
        }

        let accessGranted = authorizedURL.startAccessingSecurityScopedResource()
        guard accessGranted else {
            metarUpdateMessage = "L’autorisation d’écriture sur ce fichier .abv n’a pas été accordée."
            return
        }

        if let previousURL = securityScopedURL {
            previousURL.stopAccessingSecurityScopedResource()
        }
        securityScopedURL = authorizedURL
        self.bundleURL = authorizedURL
        hasBundleWriteAuthorization = true
        saveRecentBundle(authorizedURL)
        updateHistoricalMETAR()
    }

    func updateHistoricalMETAR() {
        guard let bundleURL, let flightDate = samples.first?.timestamp else { return }

        isUpdatingMETAR = true
        metarUpdateMessage = nil
        Task {
            do {
                let playbackPosition = currentVideoTime
                let updatedReadings = try await METARHistoryService.update(
                    bundleURL: bundleURL,
                    flightDate: flightDate
                )
                let refreshedBundle = try await Task.detached(priority: .userInitiated) {
                    try FlightBundleLoader.load(from: bundleURL)
                }.value

                rawSamples = refreshedBundle.samples
                metar = updatedReadings
                refreshSamples()
                updateLoadFactorExtrema()
                currentIndex = sampleIndex(at: playbackPosition)
                metarUpdateMessage = "\(updatedReadings.count) relevés METAR enregistrés et gps_ias recalculé dans merged_data.csv."
            } catch {
                metarUpdateMessage = "Échec de la mise à jour METAR : \(error.localizedDescription)"
            }
            isUpdatingMETAR = false
        }
    }

    func dismissMETARUpdateMessage() {
        metarUpdateMessage = nil
    }

    private func saveRecentBundle(_ url: URL) {
        #if os(macOS)
        let options: URL.BookmarkCreationOptions = .withSecurityScope
        #else
        let options: URL.BookmarkCreationOptions = []
        #endif
        let bookmarkData = try? url.bookmarkData(
            options: options,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )

        saveLastBundleBookmark(url)

        var records: [RecentBundleRecord] = []
        if let data = UserDefaults.standard.data(forKey: Self.recentBundlesKey),
           let existingRecords = try? JSONDecoder().decode([RecentBundleRecord].self, from: data) {
            records = existingRecords
        }

        let canonicalPath = url.standardizedFileURL.path
        records.removeAll { record in
            URL(fileURLWithPath: record.path).standardizedFileURL.path == canonicalPath
        }

        let newRecord = RecentBundleRecord(
            path: url.path,
            name: url.lastPathComponent,
            bookmarkData: bookmarkData
        )
        records.insert(newRecord, at: 0)

        if records.count > 5 {
            records = Array(records.prefix(5))
        }

        if let data = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(data, forKey: Self.recentBundlesKey)
        }

        recentBundles = loadRecentBundles()
    }

    private func loadRecentBundles() -> [RecentBundle] {
        #if os(macOS)
        let resOptions: URL.BookmarkResolutionOptions = .withSecurityScope
        #else
        let resOptions: URL.BookmarkResolutionOptions = []
        #endif

        if let data = UserDefaults.standard.data(forKey: Self.recentBundlesKey),
           let records = try? JSONDecoder().decode([RecentBundleRecord].self, from: data) {
            var items: [RecentBundle] = []
            for record in records {
                var resolvedURL: URL? = nil
                if let bookmarkData = record.bookmarkData {
                    var isStale = false
                    if let url = try? URL(
                        resolvingBookmarkData: bookmarkData,
                        options: resOptions,
                        relativeTo: nil,
                        bookmarkDataIsStale: &isStale
                    ) {
                        resolvedURL = url
                    }
                }
                if resolvedURL == nil {
                    let fileURL = URL(fileURLWithPath: record.path)
                    if FileManager.default.fileExists(atPath: fileURL.path) {
                        resolvedURL = fileURL
                    }
                }
                if let url = resolvedURL, FileManager.default.fileExists(atPath: url.path) {
                    if !items.contains(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) {
                        items.append(RecentBundle(name: record.name, url: url))
                    }
                }
            }
            if !items.isEmpty {
                return Array(items.prefix(5))
            }
        }

        if let legacyURL = resolvedLastBundleURL() {
            return [RecentBundle(name: legacyURL.lastPathComponent, url: legacyURL)]
        }

        return []
    }

    private func saveLastBundleBookmark(_ url: URL) {
        do {
            #if os(macOS)
            let options: URL.BookmarkCreationOptions = .withSecurityScope
            #else
            let options: URL.BookmarkCreationOptions = []
            #endif
            let bookmark = try url.bookmarkData(
                options: options,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(bookmark, forKey: Self.bundleBookmarkKey)
        } catch {
            // Le vol reste utilisable même si sa mémorisation échoue.
        }
    }

    private func resolvedLastBundleURL() -> URL? {
        guard let bookmark = UserDefaults.standard.data(forKey: Self.bundleBookmarkKey) else {
            return nil
        }
        do {
            var isStale = false
            #if os(macOS)
            let options: URL.BookmarkResolutionOptions = .withSecurityScope
            #else
            let options: URL.BookmarkResolutionOptions = []
            #endif
            let url = try URL(
                resolvingBookmarkData: bookmark,
                options: options,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            guard FileManager.default.fileExists(atPath: url.path) else {
                UserDefaults.standard.removeObject(forKey: Self.bundleBookmarkKey)
                return nil
            }
            if isStale {
                saveLastBundleBookmark(url)
            }
            return url
        } catch {
            UserDefaults.standard.removeObject(forKey: Self.bundleBookmarkKey)
            return nil
        }
    }

    func adjustMountingPitch(by delta: Double) {
        mountingPitch = max(-90, min(90, mountingPitch + delta))
        updateLoadFactorExtrema()
        saveCalibration()
    }

    func toggleCameraInversion() {
        isCameraInverted.toggle()
        saveCalibration()
    }

    /// Avance (delta > 0) ou retarde (delta < 0) la trajectoire GPS par rapport à la vidéo et à
    /// l'orientation. Le réglage est enregistré dans l'ABV (gps_offset.txt).
    func adjustGPSOffset(by delta: Double) {
        setGPSOffset(gpsOffset + delta)
    }

    func resetGPSOffset() {
        setGPSOffset(0)
    }

    private func setGPSOffset(_ value: Double) {
        let rounded = (max(-60, min(60, value)) * 10).rounded() / 10
        guard rounded != gpsOffset else { return }
        gpsOffset = rounded
        refreshSamples()
        saveGPSOffset()
    }

    /// Recalcule `samples` (GPS décalé) et tout ce qui en dérive. L'indice courant reste valable :
    /// le nombre d'échantillons et leurs temps ne changent pas.
    private func refreshSamples() {
        samples = Self.applyingGPSOffset(gpsOffset, to: Self.selectingGPS(activeGPSSource, in: rawSamples))
        samplesRevision += 1
        let strideValue = max(1, samples.count / 2_500)
        chartSamples = samples.enumerated().compactMap { index, sample in
            index.isMultiple(of: strideValue) ? sample : nil
        }
        let routeStride = max(1, samples.count / 3_000)
        routeCoordinates = samples.enumerated().compactMap { index, sample in
            index.isMultiple(of: routeStride) ? sample.coordinate : nil
        }
        maximumAltitude = samples.map(\.altitude).max() ?? 0
        maximumSpeed = samples.map(\.speed).max() ?? 0
        secondaryMaximumAltitude = samples.compactMap { $0.gps2?.altitude }.max() ?? 0
        secondaryMaximumSpeed = samples.compactMap { $0.gps2?.speed }.max() ?? 0
    }

    /// Avec le GPS2 actif, ses valeurs prennent la place des champs GPS principaux (le vent reste celui
    /// de l'ABV) et le GPS principal passe dans `gps2`, pour pouvoir afficher les deux trajectoires.
    nonisolated private static func selectingGPS(_ source: GPSSourceChoice, in raw: [FlightSample]) -> [FlightSample] {
        guard source == .secondary else { return raw }
        return raw.map { sample in
            guard let other = sample.gps2 else { return sample }
            return FlightSample(
                id: sample.id, timestamp: sample.timestamp, elapsed: sample.elapsed,
                latitude: other.latitude, longitude: other.longitude, altitude: other.altitude,
                speed: other.speed, heading: other.heading, verticalSpeed: other.verticalSpeed,
                indicatedAirspeed: other.indicatedAirspeed,
                windSpeed: sample.windSpeed, windDirection: sample.windDirection,
                accelerationX: sample.accelerationX, accelerationY: sample.accelerationY,
                accelerationZ: sample.accelerationZ,
                quaternionW: sample.quaternionW, quaternionX: sample.quaternionX,
                quaternionY: sample.quaternionY, quaternionZ: sample.quaternionZ,
                gps2: SecondaryGPS(
                    latitude: sample.latitude, longitude: sample.longitude, altitude: sample.altitude,
                    speed: sample.speed, heading: sample.heading, verticalSpeed: sample.verticalSpeed,
                    indicatedAirspeed: sample.indicatedAirspeed
                )
            )
        }
    }

    /// Reprend, pour chaque instant, les champs dérivés du GPS (position, altitude, vitesses, cap,
    /// vent) à l'instant `elapsed + offset` ; orientation et accélération restent à leur instant.
    nonisolated private static func applyingGPSOffset(_ offset: Double, to raw: [FlightSample]) -> [FlightSample] {
        guard offset != 0, raw.count > 1 else { return raw }
        var result = raw
        var source = 0
        for index in raw.indices {
            let target = raw[index].elapsed + offset
            // Le pointeur source avance presque toujours dans le même sens : parcours en O(n).
            while source < raw.count - 1,
                  abs(raw[source + 1].elapsed - target) <= abs(raw[source].elapsed - target) { source += 1 }
            while source > 0,
                  abs(raw[source - 1].elapsed - target) < abs(raw[source].elapsed - target) { source -= 1 }
            let own = raw[index]
            let gps = raw[source]
            result[index] = FlightSample(
                id: own.id, timestamp: own.timestamp, elapsed: own.elapsed,
                latitude: gps.latitude, longitude: gps.longitude, altitude: gps.altitude,
                speed: gps.speed, heading: gps.heading, verticalSpeed: gps.verticalSpeed,
                indicatedAirspeed: gps.indicatedAirspeed, windSpeed: gps.windSpeed, windDirection: gps.windDirection,
                accelerationX: own.accelerationX, accelerationY: own.accelerationY, accelerationZ: own.accelerationZ,
                quaternionW: own.quaternionW, quaternionX: own.quaternionX,
                quaternionY: own.quaternionY, quaternionZ: own.quaternionZ,
                gps2: gps.gps2
            )
        }
        return result
    }

    func toggleAudioMuted() {
        isAudioMuted.toggle()
        frontPlayer.isMuted = isAudioMuted
        backPlayer.isMuted = true
    }

    func toggleTimelineZoom() {
        isTimelineZoomed.toggle()
    }

    func toggle3DAxes() {
        shows3DAxes.toggle()
    }

    func toggleVerticalGrid() {
        showsVerticalGrid.toggle()
    }

    var hasSecondaryGPS: Bool {
        rawSamples.first?.gps2 != nil
    }

    func setGPSSource(_ source: GPSSourceChoice) {
        let target = hasSecondaryGPS ? source : .primary
        guard target != activeGPSSource else { return }
        activeGPSSource = target
        refreshSamples()
    }

    func toggleGPSSource() {
        setGPSSource(activeGPSSource == .primary ? .secondary : .primary)
    }

    func toggleBothGPSTrajectories() {
        showsBothGPSTrajectories.toggle()
        samplesRevision += 1
    }

    func toggleTrajectoryTrail() {
        showsTrajectoryTrail.toggle()
    }

    func reloadBookmarks() {
        guard let bundleURL else { return }
        bookmarks = FlightBundleLoader.loadBookmarks(
            from: bundleURL.appendingPathComponent("bookmark.csv")
        )
    }

    func openBookmarksFile() {
        guard let bundleURL else { return }
        let url = bundleURL.appendingPathComponent("bookmark.csv")
        guard FileManager.default.fileExists(atPath: url.path) else {
            errorMessage = "Le fichier bookmark.csv est introuvable."
            return
        }
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }

    func seekNextLevelFlight() {
        let window = 200
        let start = min(samples.count, currentIndex + 1_000)
        guard start < samples.count - window else { return }

        for index in start..<(samples.count - window) {
            let range = samples[index..<(index + window)]
            if range.allSatisfy({
                abs($0.verticalSpeed) < 150 && $0.speed > 150
            }) {
                seek(to: samples[index].elapsed)
                return
            }
        }
        errorMessage = "Aucun palier détecté après la position actuelle."
    }

    func calibrateAtCurrentFrame() {
        guard !samples.isEmpty else { return }
        let lowerBound = max(0, currentIndex - 50)
        let upperBound = min(samples.count, currentIndex + 50)
        guard lowerBound < upperBound else { return }

        let range = samples[lowerBound..<upperBound]
        let averageY = range.reduce(0.0) { $0 + $1.accelerationY } / Double(range.count)
        let magnitude = range.reduce(0.0) {
            $0 + sqrt(
                $1.accelerationX * $1.accelerationX
                    + $1.accelerationY * $1.accelerationY
                    + $1.accelerationZ * $1.accelerationZ
            )
        } / Double(range.count)
        guard magnitude > 0.000_001 else { return }
        mountingPitch = acos(max(-1, min(1, averageY / magnitude))) * 180 / .pi - 2
        updateLoadFactorExtrema()
        saveCalibration()
    }

    func togglePlayback() {
        guard !samples.isEmpty else { return }
        if isPlaying {
            frontPlayer.pause()
            backPlayer.pause()
            isPlaying = false
        } else {
            guard frontPlayer.currentItem != nil else {
                errorMessage = "La vidéo front.mp4 n’est pas disponible."
                return
            }
            activateAudioSession()
            if currentVideoTime >= duration - 0.1 {
                seek(to: 0)
            }
            frontPlayer.playImmediately(atRate: 1)
            if backPlayer.currentItem != nil {
                backPlayer.playImmediately(atRate: 1)
            }
            isPlaying = true
        }
    }

    func seek(to time: TimeInterval) {
        guard !samples.isEmpty else { return }
        let clamped = max(0, min(duration, time))
        let frontTime = clamped
        let frontTarget = CMTime(seconds: frontTime, preferredTimescale: 600)
        let backTime = max(0, frontTime + backVideoOffset)
        let backTarget = CMTime(seconds: backTime, preferredTimescale: 600)
        pendingSeekCount += 1
        let model = WeakFlightViewModel(self)
        // Un seek remplacé par un plus récent est aussi terminé (finished == false) : le compte reste juste.
        frontPlayer.seek(to: frontTarget, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
            Task { @MainActor in
                if let value = model.value { value.pendingSeekCount = max(0, value.pendingSeekCount - 1) }
            }
        }
        backPlayer.seek(to: backTarget, toleranceBefore: .zero, toleranceAfter: .zero)
        currentIndex = sampleIndex(at: clamped)
    }

    func jump(by seconds: TimeInterval) {
        seek(to: currentTime + seconds)
    }

    func goToTakeoff() {
        guard let index = samples.firstIndex(where: { $0.speed > 80 }) else { return }
        seek(to: samples[index].elapsed)
    }

    func goToBookmark(_ bookmark: FlightBookmark) {
        seek(to: Double(bookmark.frame) / frontVideoFrameRate)
    }

    func previousBookmark() {
        guard let bookmark = bookmarks.last(where: {
            Double($0.frame) / frontVideoFrameRate < currentVideoTime - 0.25
        }) else { return }
        goToBookmark(bookmark)
    }

    func nextBookmark() {
        guard let bookmark = bookmarks.first(where: {
            Double($0.frame) / frontVideoFrameRate > currentVideoTime + 0.25
        }) else { return }
        goToBookmark(bookmark)
    }

    func addBookmark(named name: String) {
        let frame = Int(currentVideoTime * frontVideoFrameRate)
        bookmarks.append(
            FlightBookmark(name: name, frame: frame, displayTime: currentVideoTime.clockString)
        )
        bookmarks.sort { $0.frame < $1.frame }
        saveBookmarks()
    }

    private func apply(_ bundle: FlightBundle) {
        bundleURL = bundle.url
        rawSamples = bundle.samples
        bookmarks = bundle.bookmarks
        metar = bundle.metar
        currentIndex = 0
        playbackCorrectionCount = 0

        loadGPSOffset()
        activeGPSSource = .primary
        refreshSamples()

        configure(player: frontPlayer, file: "front.mp4")
        configure(player: backPlayer, file: "back.mp4")
        frontPlayer.isMuted = isAudioMuted
        backPlayer.isMuted = true
        loadVideoSynchronization()
        loadCalibration()
        updateLoadFactorExtrema()
        installTimeObserver()
        goToTakeoff()
        if frontPlayer.currentItem != nil {
            activateAudioSession()
            frontPlayer.playImmediately(atRate: 1)
            if backPlayer.currentItem != nil {
                backPlayer.playImmediately(atRate: 1)
            }
            isPlaying = true
        }
    }

    private func activateAudioSession() {
        #if os(iOS)
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .moviePlayback)
            try audioSession.setActive(true)
        } catch {
            errorMessage = "Impossible d’activer le son : \(error.localizedDescription)"
        }
        #endif
    }

    private func configure(player: AVPlayer, file: String) {
        guard let bundleURL else { return }
        let url = bundleURL.appendingPathComponent(file)
        guard FileManager.default.fileExists(atPath: url.path) else {
            player.replaceCurrentItem(with: nil)
            return
        }
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
    }

    private func loadVideoSynchronization() {
        guard let bundleURL else { return }
        let frontAsset = AVURLAsset(url: bundleURL.appendingPathComponent("front.mp4"))
        let backAsset = AVURLAsset(url: bundleURL.appendingPathComponent("back.mp4"))

        Task {
            do {
                async let frontDate = creationDate(for: frontAsset)
                async let backDate = creationDate(for: backAsset)
                async let detectedFrameRate = videoFrameRate(for: frontAsset)
                let front = try await frontDate
                let back = try await backDate
                frontVideoFrameRate = try await detectedFrameRate
                if let front {
                    frontVideoOffset = samples.first?.timestamp.timeIntervalSince(front) ?? 0
                } else {
                    frontVideoOffset = 0
                }
                if let front, let back {
                    backVideoOffset = front.timeIntervalSince(back)
                } else {
                    backVideoOffset = 0
                }
                seek(to: currentTime)
            } catch {
                frontVideoOffset = 0
                backVideoOffset = 0
                frontVideoFrameRate = 30
            }
        }
    }

    private func creationDate(for asset: AVAsset) async throws -> Date? {
        guard let metadata = try await asset.load(.creationDate) else { return nil }
        return try await metadata.load(.dateValue)
    }

    private func videoFrameRate(for asset: AVAsset) async throws -> Double {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            return 30
        }
        let frameRate = Double(try await track.load(.nominalFrameRate))
        return frameRate.isFinite && frameRate > 0 ? frameRate : 30
    }

    private func loadCalibration() {
        guard let bundleURL else { return }
        let inversionURL = bundleURL.appendingPathComponent("inverted.txt")
        if let value = try? String(contentsOf: inversionURL, encoding: .utf8) {
            isCameraInverted = value.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
        }
        let pitchURL = bundleURL.appendingPathComponent("mounting_pitch.txt")
        if let value = try? String(contentsOf: pitchURL, encoding: .utf8),
           let pitch = Double(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
            mountingPitch = pitch
        }
    }

    private func loadGPSOffset() {
        gpsOffset = 0
        guard let bundleURL,
              let value = try? String(contentsOf: bundleURL.appendingPathComponent("gps_offset.txt"), encoding: .utf8),
              let offset = Double(value.trimmingCharacters(in: .whitespacesAndNewlines)),
              offset.isFinite else { return }
        gpsOffset = max(-60, min(60, offset))
    }

    private func saveGPSOffset() {
        guard let bundleURL else { return }
        do {
            try String(gpsOffset).write(
                to: bundleURL.appendingPathComponent("gps_offset.txt"),
                atomically: true,
                encoding: .utf8
            )
        } catch {
            errorMessage = "Impossible d’enregistrer le décalage GPS : \(error.localizedDescription)"
        }
    }

    private func updateLoadFactorExtrema() {
        let values = samples.map {
            $0.signedLoadFactor(mountingPitch: mountingPitch)
        }
        minimumLoadFactor = values.min() ?? 0
        maximumLoadFactor = values.max() ?? 0
    }

    private func saveCalibration() {
        guard let bundleURL else { return }
        do {
            try (isCameraInverted ? "1" : "0").write(
                to: bundleURL.appendingPathComponent("inverted.txt"),
                atomically: true,
                encoding: .utf8
            )
            try String(mountingPitch).write(
                to: bundleURL.appendingPathComponent("mounting_pitch.txt"),
                atomically: true,
                encoding: .utf8
            )
        } catch {
            errorMessage = "Impossible d’enregistrer la calibration : \(error.localizedDescription)"
        }
    }

    private func sampleIndex(at time: TimeInterval) -> Int {
        guard !samples.isEmpty else { return 0 }
        var lower = 0
        var upper = samples.count

        while lower < upper {
            let middle = (lower + upper) / 2
            if samples[middle].elapsed < time {
                lower = middle + 1
            } else {
                upper = middle
            }
        }

        guard lower > 0 else { return 0 }
        guard lower < samples.count else { return samples.count - 1 }
        let before = samples[lower - 1]
        let after = samples[lower]
        return time - before.elapsed <= after.elapsed - time ? lower - 1 : lower
    }

    private func installTimeObserver() {
        if let timeObserver {
            frontPlayer.removeTimeObserver(timeObserver)
        }
        // This drives `currentIndex`, which every readout, gauge, map annotation
        // and overlay in the UI observes — at 30 Hz that's the whole surrounding
        // interface (not the video itself, which AVPlayer renders independently)
        // re-diffing and redrawing 30 times a second, continuously, for as long
        // as a flight plays. None of these are frame-accurate instruments; 15 Hz
        // is still visually smooth for numeric readouts and gauges and halves
        // that cost.
        let model = WeakFlightViewModel(self)
        timeObserver = frontPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1.0 / 15.0, preferredTimescale: 600),
            queue: .main
        ) { time in
            let seconds = time.seconds
            MainActor.assumeIsolated {
                guard let value = model.value, !value.samples.isEmpty, value.pendingSeekCount == 0 else { return }
                value.currentIndex = value.sampleIndex(at: seconds)
                value.correctVideoDrift(frontTime: seconds)
            }
        }
    }

    // Seek-only correction, deliberately never touching `backPlayer.rate`.
    // An earlier version nudged the rate a few percent for small drift to
    // avoid visible seek hitches, but that meant the back player spent most
    // of playback sitting at a non-1.0 rate — which keeps AVFoundation's
    // audio time-pitch processing continuously engaged even on a muted
    // player, and was heavy enough to make the whole app feel laggy. A seek
    // only costs something at the moment it happens, so it's throttled
    // (`videoDriftSeekCooldown`) and given a loose tolerance so it resolves
    // in one step instead of requiring several frames to be decoded — the
    // combination that used to make corrections "pump" back-to-back.
    private func correctVideoDrift(frontTime: TimeInterval) {
        guard isPlaying, backPlayer.currentItem != nil, !isCorrectingVideoDrift else { return }
        let expectedBackTime = max(0, frontTime + backVideoOffset)
        let actualBackTime = backPlayer.currentTime().seconds
        guard actualBackTime.isFinite, abs(actualBackTime - expectedBackTime) > videoDriftSeekThreshold else {
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastDriftSeekTime > videoDriftSeekCooldown else { return }
        lastDriftSeekTime = now

        let target = CMTime(seconds: expectedBackTime, preferredTimescale: 600)
        let tolerance = CMTime(seconds: 0.1, preferredTimescale: 600)
        playbackCorrectionCount += 1
        isCorrectingVideoDrift = true
        let model = WeakFlightViewModel(self)
        backPlayer.seek(
            to: target,
            toleranceBefore: tolerance,
            toleranceAfter: tolerance
        ) { _ in
            Task { @MainActor in
                model.value?.isCorrectingVideoDrift = false
            }
        }
    }

    private func saveBookmarks() {
        guard let bundleURL else { return }
        let header = "time,name,frame\n"
        let body = bookmarks.map {
            "\($0.displayTime),\(CSVParser.escape($0.name)),\($0.frame)"
        }.joined(separator: "\n")
        do {
            try (header + body + "\n").write(
                to: bundleURL.appendingPathComponent("bookmark.csv"),
                atomically: true,
                encoding: .utf8
            )
        } catch {
            errorMessage = "Impossible d’enregistrer les favoris : \(error.localizedDescription)"
        }
    }
}

private final class WeakFlightViewModel: @unchecked Sendable {
    weak var value: FlightViewModel?

    init(_ value: FlightViewModel) {
        self.value = value
    }
}

private extension CSVParser {
    static func escape(_ field: String) -> String {
        guard field.contains(",") || field.contains("\"") else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

extension TimeInterval {
    var clockString: String {
        guard isFinite else { return "00:00" }
        let total = max(0, Int(self))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
