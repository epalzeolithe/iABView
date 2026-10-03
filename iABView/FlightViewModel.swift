#if os(macOS)
import AppKit
#else
import UIKit
#endif
import AVFoundation
import CoreLocation
import Foundation
import Observation

@MainActor
@Observable
final class FlightViewModel {
    private static let bundleBookmarkKey = "ABView.lastBundleBookmark"

    private(set) var bundleURL: URL?
    private(set) var samples: [FlightSample] = []
    private(set) var chartSamples: [FlightSample] = []
    private(set) var routeCoordinates: [CLLocationCoordinate2D] = []
    private(set) var bookmarks: [FlightBookmark] = []
    private(set) var metar: [METARReading] = []
    private(set) var currentIndex = 0
    private(set) var isLoading = false
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
    private(set) var shows3DAxes = false
    private(set) var showsVerticalGrid = false
    private(set) var isAudioMuted = false
    private(set) var playbackCorrectionCount = 0

    let frontPlayer = AVPlayer()
    let backPlayer = AVPlayer()
    private var timeObserver: Any?
    private var securityScopedURL: URL?
    private var isCorrectingVideoDrift = false

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
        resolvedLastBundleURL()?.lastPathComponent
    }

    func openLastBundle() {
        guard let url = resolvedLastBundleURL() else { return }
        openBundle(url)
    }

    func openBundle(_ url: URL) {
        isLoading = true
        errorMessage = nil
        let accessGranted = url.startAccessingSecurityScopedResource()

        Task {
            do {
                let loaded = try await Task.detached(priority: .userInitiated) {
                    try FlightBundleLoader.load(from: url)
                }.value
                if let previousURL = securityScopedURL {
                    previousURL.stopAccessingSecurityScopedResource()
                }
                securityScopedURL = accessGranted ? url : nil
                apply(loaded)
                saveLastBundleBookmark(url)
            } catch {
                if accessGranted { url.stopAccessingSecurityScopedResource() }
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }

    func dismissError() {
        errorMessage = nil
    }

    private func saveLastBundleBookmark(_ url: URL) {
        do {
            #if os(macOS)
            let options: URL.BookmarkCreationOptions = [
                .withSecurityScope,
                .securityScopeAllowOnlyReadAccess
            ]
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
        frontPlayer.seek(to: frontTarget, toleranceBefore: .zero, toleranceAfter: .zero)
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
        samples = bundle.samples
        bookmarks = bundle.bookmarks
        metar = bundle.metar
        currentIndex = 0
        playbackCorrectionCount = 0

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
        let model = WeakFlightViewModel(self)
        timeObserver = frontPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600),
            queue: .main
        ) { time in
            let seconds = time.seconds
            MainActor.assumeIsolated {
                guard let value = model.value, !value.samples.isEmpty else { return }
                value.currentIndex = value.sampleIndex(at: seconds)
                value.correctVideoDrift(frontTime: seconds)
            }
        }
    }

    private func correctVideoDrift(frontTime: TimeInterval) {
        guard !isCorrectingVideoDrift, backPlayer.currentItem != nil else { return }
        let expectedBackTime = max(0, frontTime + backVideoOffset)
        let actualBackTime = backPlayer.currentTime().seconds
        guard actualBackTime.isFinite,
              abs(actualBackTime - expectedBackTime) > 0.10 else {
            return
        }

        let target = CMTime(seconds: expectedBackTime, preferredTimescale: 600)
        let tolerance = CMTime(seconds: 0.02, preferredTimescale: 600)
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
