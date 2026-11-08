#if os(macOS)
import Darwin
import Foundation
import Observation
import simd

struct ABVSourceFile: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable {
        case insta360 = "Insta360"
        case gpx = "GPX"
        case nmea = "GNS3000"
        case sensorLog = "iPhone"
        case unsupported = "Non reconnu"
    }

    let url: URL
    let kind: Kind
    var id: String { url.path }

    nonisolated init(url: URL) {
        self.url = url
        let name = url.lastPathComponent.lowercased()
        if url.pathExtension.lowercased() == "insv" {
            kind = .insta360
        } else if url.pathExtension.lowercased() == "gpx" {
            kind = .gpx
        } else if url.pathExtension.lowercased() == "txt" || name.hasPrefix("log") {
            kind = .nmea
        } else if url.pathExtension.lowercased() == "csv" && name.contains("sensorlog") {
            kind = .sensorLog
        } else {
            kind = .unsupported
        }
    }
}

struct ABVCreatorProgress: Sendable {
    var fraction: Double
    var message: String?
    var ffmpegCPUUsage: Double?
    var step: String?
}

enum ABVCreatorError: LocalizedError {
    case invalidSources(String)
    case missingTool(String)
    case commandFailed(String, String)
    case invalidData(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidSources(let message), .invalidData(let message):
            message
        case .missingTool(let name):
            "L’outil \(name) est introuvable. Installez-le puis relancez la création."
        case .commandFailed(let command, let output):
            "Échec de \(command).\n\(output.suffix(2_000))"
        case .cancelled:
            "Création annulée."
        }
    }
}

final class ABVCreatorCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private nonisolated(unsafe) var cancelled = false
    private nonisolated(unsafe) var paused = false
    private nonisolated(unsafe) var pausedSince: Date?
    private nonisolated(unsafe) var accumulatedPause: TimeInterval = 0
    private nonisolated(unsafe) weak var currentProcess: Process?

    nonisolated init() {}

    nonisolated var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    nonisolated func checkCancelled() throws {
        if isCancelled { throw ABVCreatorError.cancelled }
    }

    nonisolated func cancel() {
        lock.lock()
        cancelled = true
        let process = currentProcess
        lock.unlock()
        process?.terminate()
        // A stopped process only handles SIGTERM once it is resumed.
        if let process, process.isRunning { kill(process.processIdentifier, SIGCONT) }
    }

    /// Suspends the running child process (SIGSTOP); processes started while paused are
    /// suspended as soon as they are tracked.
    nonisolated func pause() {
        lock.lock()
        guard !paused, !cancelled else { lock.unlock(); return }
        paused = true
        pausedSince = Date()
        let process = currentProcess
        lock.unlock()
        if let process, process.isRunning { kill(process.processIdentifier, SIGSTOP) }
    }

    nonisolated func resume() {
        lock.lock()
        guard paused else { lock.unlock(); return }
        paused = false
        if let pausedSince { accumulatedPause += Date().timeIntervalSince(pausedSince) }
        pausedSince = nil
        let process = currentProcess
        lock.unlock()
        if let process, process.isRunning { kill(process.processIdentifier, SIGCONT) }
    }

    /// Total time spent paused so far, including a pause currently in progress.
    nonisolated var totalPausedDuration: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return accumulatedPause + (pausedSince.map { Date().timeIntervalSince($0) } ?? 0)
    }

    nonisolated func track(_ process: Process) {
        lock.lock()
        currentProcess = process
        let shouldTerminate = cancelled
        let shouldStop = paused
        lock.unlock()
        if shouldTerminate { process.terminate() }
        else if shouldStop { kill(process.processIdentifier, SIGSTOP) }
    }

    nonisolated func untrack() {
        lock.lock()
        currentProcess = nil
        lock.unlock()
    }
}

/// Tracks in-flight creations so their child processes (ffmpeg, Gyroflow, gyro2bb) can be
/// killed explicitly on app quit — macOS does not terminate them on its own, since they are
/// independent processes once spawned.
enum ABVCreatorProcessRegistry {
    private nonisolated static let lock = NSLock()
    private nonisolated(unsafe) static var activeTokens: [ObjectIdentifier: ABVCreatorCancellationToken] = [:]

    nonisolated static func register(_ token: ABVCreatorCancellationToken) {
        lock.lock(); defer { lock.unlock() }
        activeTokens[ObjectIdentifier(token)] = token
    }

    nonisolated static func unregister(_ token: ABVCreatorCancellationToken) {
        lock.lock(); defer { lock.unlock() }
        activeTokens.removeValue(forKey: ObjectIdentifier(token))
    }

    nonisolated static func terminateAll() {
        lock.lock()
        let tokens = Array(activeTokens.values)
        lock.unlock()
        tokens.forEach { $0.cancel() }
    }
}

/// Dernier état lu dans les statistiques de ffmpeg (`time=00:01:23.45 … speed=1.23x`).
final class ABVFFmpegStatus: @unchecked Sendable {
    private let lock = NSLock()
    private nonisolated(unsafe) var time: TimeInterval?
    private nonisolated(unsafe) var speed: Double?

    nonisolated init() {}

    /// Position atteinte dans la vidéo de sortie (s) et vitesse moyenne (×), si déjà connues.
    nonisolated var snapshot: (time: TimeInterval?, speed: Double?) {
        lock.lock(); defer { lock.unlock() }
        return (time, speed)
    }

    /// Analyse un morceau de sortie ffmpeg et retient les dernières valeurs `time=` et `speed=`.
    nonisolated func ingest(_ chunk: String) {
        func lastMatch(_ pattern: String) -> [String]? {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.matches(in: chunk, range: NSRange(chunk.startIndex..., in: chunk)).last
            else { return nil }
            return (1..<match.numberOfRanges).compactMap { index in
                Range(match.range(at: index), in: chunk).map { String(chunk[$0]) }
            }
        }
        let parsedTime = lastMatch(#"time=\s*(\d+):(\d{2}):(\d{2}(?:\.\d+)?)"#).flatMap { parts -> TimeInterval? in
            guard parts.count == 3, let hours = Double(parts[0]), let minutes = Double(parts[1]),
                  let seconds = Double(parts[2]) else { return nil }
            return hours * 3_600 + minutes * 60 + seconds
        }
        let parsedSpeed = lastMatch(#"speed=\s*(\d+(?:\.\d+)?)x"#).flatMap { Double($0.first ?? "") }
        lock.lock()
        if let parsedTime { time = parsedTime }
        if let parsedSpeed { speed = parsedSpeed }
        lock.unlock()
    }
}

/// Reçoit en direct les lignes de commande et leur sortie, pour la console de débogage.
enum ABVDebugConsole {
    private nonisolated(unsafe) static var handler: (@Sendable (String) -> Void)?
    private static let lock = NSLock()

    nonisolated static func setHandler(_ newHandler: (@Sendable (String) -> Void)?) {
        lock.lock(); defer { lock.unlock() }
        handler = newHandler
    }

    nonisolated static func emit(_ text: String) {
        lock.lock()
        let current = handler
        lock.unlock()
        current?(text)
    }

    nonisolated static func quoted(_ argument: String) -> String {
        let safe = argument.allSatisfy { $0.isLetter || $0.isNumber || "/._-=:,+@%".contains($0) }
        return safe && !argument.isEmpty ? argument : "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Outil qui fournit les accélérations du CSV (le quaternion vient toujours de Gyroflow).
enum ABVAccelerationSource: String, CaseIterable, Identifiable, Sendable {
    /// gyro2bb : `accSmooth` en LSB, converti en m/s².
    case gyro2bb
    /// Gyroflow : export de tous les échantillons IMU, déjà en m/s².
    case gyroflow

    static let storageKey = "ABVCreator.accelerationSource"

    var id: String { rawValue }

    nonisolated var displayName: String {
        switch self {
        case .gyro2bb: "gyro2bb"
        case .gyroflow: "Gyroflow"
        }
    }

    /// Valeur choisie dans le créateur (Gyroflow par défaut).
    static var stored: ABVAccelerationSource {
        UserDefaults.standard.string(forKey: storageKey).flatMap(ABVAccelerationSource.init(rawValue:)) ?? .gyroflow
    }
}

/// Option « Haute résolution » de la conversion vidéo (proposée uniquement pour les vidéos X6).
enum ABVHighResolution {
    static let storageKey = "ABVCreator.highResolution"

    static var stored: Bool {
        UserDefaults.standard.bool(forKey: storageKey)
    }
}

enum ABVTool: String, CaseIterable, Identifiable, Sendable {
    case exiftool
    case ffmpeg
    case gyro2bb
    case gyroflow

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .exiftool: "exiftool"
        case .ffmpeg: "ffmpeg"
        case .gyro2bb: "gyro2bb"
        case .gyroflow: "Gyroflow"
        }
    }

    nonisolated var candidates: [String] {
        switch self {
        case .exiftool:
            [
                Bundle.main.url(forResource: "exiftool", withExtension: nil)?.path ?? "",
                Bundle.main.resourceURL?.appendingPathComponent("exiftool").path ?? "",
                "/opt/homebrew/bin/exiftool",
                "/usr/local/bin/exiftool",
                "/Users/drax/Dev/ABView/ressources/exiftool"
            ]
        case .ffmpeg:
            [
                "/opt/homebrew/bin/ffmpeg",
                "/usr/local/bin/ffmpeg",
                "/Applications/ffmpeg"
            ]
        case .gyro2bb:
            [
                Bundle.main.url(forResource: "gyro2bb-mac-arm64", withExtension: nil)?.path ?? "",
                Bundle.main.resourceURL?.appendingPathComponent("gyro2bb-mac-arm64").path ?? "",
                "/Users/drax/Dev/ABView/ressources/gyro2bb-mac-arm64",
                "/usr/local/bin/gyro2bb"
            ]
        case .gyroflow:
            [
                "/Applications/Gyroflow.app/Contents/MacOS/gyroflow",
                NSHomeDirectory() + "/Applications/Gyroflow.app/Contents/MacOS/gyroflow",
                "/opt/homebrew/bin/gyroflow",
                "/usr/local/bin/gyroflow"
            ]
        }
    }

    /// Lance l'outil pour vérifier qu'il démarre réellement (et pas seulement qu'il existe).
    /// Renvoie un message de succès (version détectée) ou lève une erreur décrivant le problème.
    nonisolated func selfTest() throws -> String {
        guard let path = candidates.first(where: { !$0.isEmpty && FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw ABVCreatorError.invalidData("\(displayName) est introuvable.")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--help"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        // Garde-fou : un outil qui ne rend pas la main est arrêté après 15 s.
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: watchdog)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        let output = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0, output.localizedCaseInsensitiveContains("gyroflow") else {
            throw ABVCreatorError.invalidData(
                "\(displayName) ne démarre pas correctement (code \(process.terminationStatus))."
            )
        }
        if let range = output.range(of: #"Gyroflow v?\d+(\.\d+)+"#, options: .regularExpression) {
            return String(output[range])
        }
        return displayName
    }

    nonisolated var isAvailable: Bool {
        candidates.contains { !$0.isEmpty && FileManager.default.isExecutableFile(atPath: $0) }
    }
}

@MainActor
@Observable
final class ABVCreatorModel {
    var sources: [ABVSourceFile] = []
    /// Modèle de caméra détecté (exiftool) pour chaque fichier .insv.
    var cameraModels: [URL: String] = [:]
    var state: State = .ready
    var log: [String] = []
    var outputURL: URL?
    var progress: Double = 0
    var ffmpegCPUUsage: Double?
    var creationStartDate: Date?
    var lastDuration: TimeInterval?
    var currentStep: String?
    var isPaused = false
    var pauseStartDate: Date?
    /// Mode aperçu : seule 1 minute de vidéo est convertie, à partir de `previewOffsetMinutes`.
    var isPreview = false
    var consoleLines: [String] = []
    private static let maxConsoleLines = 2_000
    var previewOffsetMinutes = 15
    private var cancellationToken: ABVCreatorCancellationToken?

    private static let lastSessionBookmarksKey = "ABVCreator.lastSessionBookmarks"

    enum State: Equatable {
        case ready
        case running
        case succeeded
        case failed(String)
    }

    /// Vrai si au moins un des fichiers .insv a été détecté comme provenant d'un X6.
    var hasX6Camera: Bool {
        sources.contains {
            $0.kind == .insta360
                && ABVCreatorPipeline.CameraModel(detected: cameraModels[$0.url]) == .x6
        }
    }

    var canCreate: Bool {
        state != .running
            && (1...2).contains(sources.filter { $0.kind == .insta360 }.count)
            && sources.contains { $0.kind == .gpx || $0.kind == .nmea }
    }

    var suggestedName: String {
        guard let camera = sortedCameras.first else { return "Nouveau vol.abv" }
        let components = camera.url.lastPathComponent.split(separator: "_")
        guard components.count > 1, components[1].count == 8 else { return "Nouveau vol.abv" }
        let date = components[1]
        return "Vol_\(date.prefix(4))_\(date.dropFirst(4).prefix(2))_\(date.suffix(2)).abv"
    }

    private var sortedCameras: [ABVSourceFile] {
        sources.filter { $0.kind == .insta360 }
            .sorted { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }
    }

    func add(_ urls: [URL]) {
        guard state != .running else { return }
        let additions = urls.map(ABVSourceFile.init(url:))
        for source in additions where !sources.contains(where: { $0.url == source.url }) {
            sources.append(source)
        }
        sources.sort {
            if $0.kind == $1.kind {
                return $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
            }
            return $0.kind.rawValue < $1.kind.rawValue
        }
        state = .ready
        outputURL = nil
        saveLastSession()
        detectCameraModels(for: additions)
    }

    /// Détecte en arrière-plan le modèle de caméra des nouveaux fichiers .insv.
    private func detectCameraModels(for additions: [ABVSourceFile]) {
        for source in additions where source.kind == .insta360 && cameraModels[source.url] == nil {
            let url = source.url
            Task {
                let model = await Task.detached(priority: .utility) {
                    ABVCreatorPipeline.detectCameraModel(of: url)
                }.value
                if let model { cameraModels[url] = model }
            }
        }
    }

    func remove(_ source: ABVSourceFile) {
        sources.removeAll { $0.id == source.id }
        state = .ready
    }

    func reset() {
        guard state != .running else { return }
        sources = []
        log = []
        outputURL = nil
        state = .ready
    }

    /// Vrai si le paquet de destination contient déjà une conversion vidéo réutilisable.
    func hasConvertedVideo(at url: URL) -> Bool {
        ABVCreatorPipeline.hasConvertedVideo(in: url)
    }

    func appendConsole(_ chunk: String) {
        // ffmpeg -stats rafraîchit sa ligne avec \r : on traite chaque rafraîchissement comme une ligne.
        let lines = chunk.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).map(String.init)
        for line in lines {
            // Les lignes de progression de ffmpeg se remplacent : sinon elles saturent la console
            // (des milliers de lignes à recomposer) et figent l'interface pendant les longues conversions.
            if Self.isFFmpegStatsLine(line), let last = consoleLines.last, Self.isFFmpegStatsLine(last) {
                consoleLines[consoleLines.count - 1] = line
            } else {
                consoleLines.append(line)
            }
        }
        if consoleLines.count > Self.maxConsoleLines {
            consoleLines.removeFirst(consoleLines.count - Self.maxConsoleLines)
        }
    }

    private static func isFFmpegStatsLine(_ line: String) -> Bool {
        line.hasPrefix("frame=") || (line.contains("fps=") && line.contains("time="))
    }

    func clearConsole() {
        consoleLines.removeAll()
    }

    func cancel() {
        guard state == .running else { return }
        log.append("Annulation demandée…")
        cancellationToken?.cancel()
        isPaused = false
        pauseStartDate = nil
    }

    func togglePause() {
        guard state == .running, let token = cancellationToken else { return }
        if isPaused {
            token.resume()
            // Shift the start date so the elapsed timer excludes the pause.
            if let pausedAt = pauseStartDate, let start = creationStartDate {
                creationStartDate = start.addingTimeInterval(Date().timeIntervalSince(pausedAt))
            }
            pauseStartDate = nil
            isPaused = false
            log.append("Reprise de la création.")
        } else {
            token.pause()
            pauseStartDate = Date()
            isPaused = true
            log.append("Création mise en pause.")
        }
    }

    var canReloadLastSession: Bool {
        UserDefaults.standard.array(forKey: Self.lastSessionBookmarksKey) != nil
    }

    func reloadLastSession() {
        guard state != .running else { return }
        guard let bookmarks = UserDefaults.standard.array(forKey: Self.lastSessionBookmarksKey) as? [Data] else { return }
        var urls: [URL] = []
        for bookmark in bookmarks {
            var isStale = false
            guard let url = try? URL(
                resolvingBookmarkData: bookmark,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) else { continue }
            _ = url.startAccessingSecurityScopedResource()
            urls.append(url)
        }
        guard !urls.isEmpty else { return }
        add(urls)
    }

    private func saveLastSession() {
        let bookmarks: [Data] = sources.compactMap {
            try? $0.url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        }
        guard !bookmarks.isEmpty else { return }
        UserDefaults.standard.set(bookmarks, forKey: Self.lastSessionBookmarksKey)
    }

    func create(at destination: URL, overwrite: Bool = false, keepVideo: Bool = false) {
        guard canCreate else { return }
        state = .running
        isPaused = false
        pauseStartDate = nil
        log = ["Validation des fichiers…"]
        consoleLines.removeAll()
        ABVDebugConsole.setHandler { [weak self] text in
            Task { @MainActor in self?.appendConsole(text) }
        }
        outputURL = nil
        progress = 0
        ffmpegCPUUsage = nil
        currentStep = "Validation des fichiers…"
        let startDate = Date()
        creationStartDate = startDate
        lastDuration = nil
        let selectedSources = sources
        let accelerationSource = ABVAccelerationSource.stored
        let highResolution = ABVHighResolution.stored && hasX6Camera
        let previewOffset: TimeInterval? = isPreview ? Double(max(0, previewOffsetMinutes)) * 60 : nil
        saveLastSession()
        let token = ABVCreatorCancellationToken()
        cancellationToken = token
        ABVCreatorProcessRegistry.register(token)

        let (stream, continuation) = AsyncStream<ABVCreatorProgress>.makeStream()

        Task {
            for await update in stream {
                progress = update.fraction
                if let step = update.step {
                    currentStep = step
                }
                if let message = update.message {
                    log.append(message)
                }
                ffmpegCPUUsage = update.ffmpegCPUUsage
            }
        }

        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try ABVCreatorPipeline.create(
                        sources: selectedSources, destination: destination,
                        overwrite: overwrite, keepVideo: keepVideo, previewOffset: previewOffset,
                        accelerationSource: accelerationSource, highResolution: highResolution, cancellation: token
                    ) { update in
                        continuation.yield(update)
                    }
                }.value
                continuation.finish()
                ABVCreatorProcessRegistry.unregister(token)
                ABVDebugConsole.setHandler(nil)
                ffmpegCPUUsage = nil
                currentStep = "Téléchargement des METAR…"
                do {
                    _ = try await METARHistoryService.update(
                        bundleURL: result.url,
                        flightDate: result.flightDate
                    )
                    log.append("METAR historiques ajoutés.")
                } catch {
                    log.append("METAR non téléchargés : \(error.localizedDescription)")
                }
                outputURL = result.url
                log.append("Terminé : \(result.url.lastPathComponent)")
                progress = 1
                lastDuration = Date().timeIntervalSince(startDate)
                creationStartDate = nil
                state = .succeeded
            } catch {
                continuation.finish()
                ABVCreatorProcessRegistry.unregister(token)
                ABVDebugConsole.setHandler(nil)
                ffmpegCPUUsage = nil
                lastDuration = Date().timeIntervalSince(startDate)
                creationStartDate = nil
                let message = error.localizedDescription
                log.append(message)
                state = .failed(message)
            }
        }
    }
}

private enum ABVCreatorPipeline {
    struct CreationResult: Sendable {
        let url: URL
        let flightDate: Date
    }

    struct CameraSample: Sendable {
        var date: Date
        var milliseconds: Double
        var accelerationX: Double
        var accelerationY: Double
        var accelerationZ: Double
        var quaternionW: Double
        var quaternionX: Double
        var quaternionY: Double
        var quaternionZ: Double
    }

    /// Pipeline de télémétrie à appliquer, d'après le modèle lu dans le fichier .insv.
    /// Tout modèle non reconnu retombe sur le pipeline X4 (comportement historique).
    enum CameraModel {
        case x4
        case x6

        nonisolated init(detected: String?) {
            if let detected, detected.localizedCaseInsensitiveContains("X6") {
                self = .x6
            } else {
                self = .x4
            }
        }
    }

    struct GPSSample: Sendable {
        var date: Date
        var latitude: Double
        var longitude: Double
        var altitude: Double
        var speed: Double
        var heading: Double
        var verticalSpeed: Double
    }

    struct IPhoneSample: Sendable {
        var date: Date
        var values: [String: Double]
    }

    private nonisolated static let previewDuration: TimeInterval = 60
    private nonisolated static let stageWeight = 0.05
    private nonisolated static let videoWeight = 0.5
    private nonisolated static let cameraWeight = 0.35
    private nonisolated static let gpsWeight = 0.03
    private nonisolated static let phoneWeight = 0.02
    private nonisolated static let mergeWeight = 0.05

    nonisolated static func create(
        sources: [ABVSourceFile],
        destination: URL,
        overwrite: Bool,
        keepVideo: Bool = false,
        previewOffset: TimeInterval? = nil,
        accelerationSource: ABVAccelerationSource = .gyroflow,
        highResolution: Bool = false,
        cancellation: ABVCreatorCancellationToken,
        progress: @escaping @Sendable (ABVCreatorProgress) -> Void
    ) throws -> CreationResult {
        var fraction = 0.0
        func advance(_ delta: Double, message: String? = nil) {
            fraction = min(1, fraction + delta)
            progress(ABVCreatorProgress(fraction: fraction, message: message, ffmpegCPUUsage: nil))
        }
        func announce(_ step: String) {
            progress(ABVCreatorProgress(fraction: fraction, message: nil, ffmpegCPUUsage: nil, step: step))
        }

        let fileManager = FileManager.default
        let cameras = sources.filter { $0.kind == .insta360 }.sorted {
            $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
        }
        guard (1...2).contains(cameras.count) else {
            throw ABVCreatorError.invalidSources("Déposez un ou deux fichiers .insv.")
        }
        // Avec un GNS3000 et un GPX, le GNS3000 fournit les données principales et le GPX le second jeu (GPS2).
        let gpsSource = sources.first { $0.kind == .nmea } ?? sources.first { $0.kind == .gpx }
        let secondaryGPSSource = gpsSource?.kind == .nmea ? sources.first { $0.kind == .gpx } : nil
        guard let gpsSource else {
            throw ABVCreatorError.invalidSources("Déposez un fichier GPS .gpx ou un journal GNS3000 .txt.")
        }

        let output = destination.pathExtension.lowercased() == "abv"
            ? destination
            : destination.appendingPathExtension("abv")
        if fileManager.fileExists(atPath: output.path) {
            guard overwrite else {
                throw ABVCreatorError.invalidSources("Le fichier \(output.lastPathComponent) existe déjà.")
            }
            if keepVideo {
                removeAllExceptVideos(in: output)
            } else {
                try fileManager.removeItem(at: output)
            }
        }
        try fileManager.createDirectory(at: output, withIntermediateDirectories: true)
        markAsPackage(output)
        let work = output.appendingPathComponent(".creation", isDirectory: true)
        do {
            try fileManager.createDirectory(at: work, withIntermediateDirectories: true)
            defer { try? fileManager.removeItem(at: work) }

            announce("Copie des fichiers sources…")
            let stagedCameras = try cameras.map { source in
                // En aperçu, on lit les originaux pour éviter de copier des dizaines de Go.
                if previewOffset != nil || keepVideo { return source.url }
                let target = work.appendingPathComponent(source.url.lastPathComponent)
                try fileManager.copyItem(at: source.url, to: target)
                return target
            }
            let stagedGPS = work.appendingPathComponent(gpsSource.url.lastPathComponent)
            try fileManager.copyItem(at: gpsSource.url, to: stagedGPS)
            var stagedGPS2: URL?
            if let secondaryGPSSource {
                let target = work.appendingPathComponent("gps2_" + secondaryGPSSource.url.lastPathComponent)
                try fileManager.copyItem(at: secondaryGPSSource.url, to: target)
                stagedGPS2 = target
            }
            advance(stageWeight, message: "Fichiers copiés.")

            var cameraSamples: [CameraSample] = []
            var segmentStart: Date?
            var segmentDurations: [TimeInterval] = []
            var usesX6 = false
            for camera in stagedCameras {
                try cancellation.checkCancelled()
                announce("Extraction de la télémétrie caméra : \(camera.lastPathComponent) (accélérations : \(accelerationSource.displayName))…")
                var segment: [CameraSample]
                switch CameraModel(detected: detectCameraModel(of: camera)) {
                case .x6:
                    usesX6 = true
                    segment = try cameraDataX6(
                        from: camera, work: work, accelerationSource: accelerationSource, cancellation: cancellation
                    )
                case .x4:
                    segment = try cameraData(
                        from: camera, work: work, accelerationSource: accelerationSource, cancellation: cancellation
                    )
                }
                if let first = segment.first?.date, let last = segment.last?.date {
                    segmentDurations.append(last.timeIntervalSince(first))
                } else {
                    segmentDurations.append(0)
                }
                if let previousEnd = cameraSamples.last?.date, let first = segment.first?.date {
                    let offset = previousEnd.timeIntervalSince(first)
                    for index in segment.indices {
                        segment[index].date = segment[index].date.addingTimeInterval(offset)
                    }
                } else {
                    segmentStart = segment.first?.date
                }
                cameraSamples.append(contentsOf: segment)
                advance(cameraWeight / Double(stagedCameras.count), message: "Télémétrie extraite : \(camera.lastPathComponent).")
            }
            guard !cameraSamples.isEmpty, segmentStart != nil else {
                throw ABVCreatorError.invalidData("Aucune télémétrie caméra n’a été extraite.")
            }

            // Durée de chaque fichier (exiftool, à défaut celle de la télémétrie) : elle sert à
            // convertir la vitesse mesurée par ffmpeg en progression et en temps restant.
            let fileDurations = stagedCameras.enumerated().map { index, url in
                videoDuration(of: url) ?? segmentDurations[index]
            }
            var videoOutputDuration = fileDurations.reduce(0, +)

            // Aperçu : on ne garde que la minute demandée, dans le fichier caméra qui la contient.
            var videoCameras = stagedCameras
            var videoWindow: (offset: TimeInterval, duration: TimeInterval)?
            if let previewOffset {
                var elapsed = 0.0
                var selected: Int?
                for (index, duration) in segmentDurations.enumerated() {
                    if previewOffset < elapsed + duration { selected = index; break }
                    elapsed += duration
                }
                guard let selected else {
                    throw ABVCreatorError.invalidData(
                        "Le décalage de l’aperçu dépasse la durée du vol (\(formattedMinutes(elapsed)))."
                    )
                }
                let windowStart = cameraSamples[0].date.addingTimeInterval(previewOffset)
                let windowEnd = windowStart.addingTimeInterval(previewDuration)
                cameraSamples = cameraSamples.filter { $0.date >= windowStart && $0.date <= windowEnd }
                for index in cameraSamples.indices {
                    cameraSamples[index].milliseconds = cameraSamples[index].date.timeIntervalSince(windowStart) * 1_000
                }
                guard !cameraSamples.isEmpty else {
                    throw ABVCreatorError.invalidData("Aucune télémétrie caméra dans la fenêtre d’aperçu.")
                }
                videoCameras = [stagedCameras[selected]]
                videoWindow = (previewOffset - elapsed, previewDuration)
                let available = fileDurations[selected] - (previewOffset - elapsed)
                videoOutputDuration = available > 0 ? min(previewDuration, available) : previewDuration
                announce("Aperçu : 1 min à partir de \(formattedMinutes(previewOffset)).")
            }

            try cancellation.checkCancelled()
            let totalBytes: Int64 = videoCameras.reduce(0) { total, url in
                let attributes = try? fileManager.attributesOfItem(atPath: url.path)
                let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
                return total + size
            }
            let totalGB = Double(totalBytes) / 1_000_000_000
            // Calibré sur un retour empirique de cette machine : 46 min pour 22 Go, soit ~2.1 min/Go.
            let estimatedSeconds = videoWindow == nil ? totalGB * 125.5 : 60
            let estimateText = totalGB > 0.05
                ? " (~\(formattedMinutes(estimatedSeconds)) estimées pour \(String(format: "%.1f", totalGB)) Go)"
                : ""
            let front = output.appendingPathComponent("front.mp4")
            let back = output.appendingPathComponent("back.mp4")
            let videoStepFraction = fraction
            let videoStart = Date()
            let pausedAtVideoStart = cancellation.totalPausedDuration
            let outputDuration = videoOutputDuration
            let ffmpegStatus = ABVFFmpegStatus()
            if keepVideo {
                announce("Vidéo existante conservée.")
            } else {
                announce("Conversion vidéo en cours…" + estimateText)
            try convertVideo(
                cameras: videoCameras, window: videoWindow, front: front, back: back, work: work,
                highResolution: highResolution,
                status: ffmpegStatus, cancellation: cancellation
            ) { cpu in
                let snapshot = ffmpegStatus.snapshot
                if outputDuration > 0, let time = snapshot.time {
                    // Progression réelle (position ffmpeg / durée) ; la vitesse moyenne donne le temps restant.
                    let liveFraction = min(1, videoStepFraction + videoWeight * min(time / outputDuration, 0.99))
                    var step: String?
                    if let speed = snapshot.speed, speed > 0 {
                        let remaining = max(0, outputDuration - time) / speed
                        let remainingText = remaining < 60 ? "moins d’une minute" : "~" + formattedMinutes(remaining)
                        step = "Conversion vidéo en cours… \(String(format: "%.2f", speed))× — temps restant : \(remainingText)"
                    }
                    progress(ABVCreatorProgress(fraction: liveFraction, message: nil, ffmpegCPUUsage: cpu, step: step))
                } else {
                    // Pas encore de statistiques ffmpeg : estimation initiale d'après la taille des fichiers.
                    // Exclude time spent paused so the estimate doesn't jump after a resume.
                    let elapsed = Date().timeIntervalSince(videoStart)
                        - (cancellation.totalPausedDuration - pausedAtVideoStart)
                    let estimatedProgress = estimatedSeconds > 0 ? min(elapsed / estimatedSeconds, 0.96) : 0
                    let liveFraction = min(1, videoStepFraction + videoWeight * estimatedProgress)
                    progress(ABVCreatorProgress(fraction: liveFraction, message: nil, ffmpegCPUUsage: cpu))
                }
            }
            }
            advance(videoWeight, message: keepVideo ? "Vidéo conservée." : "Conversion vidéo terminée.")

            announce("Chargement des données GPS…")
            let gps = try loadGPS(from: stagedGPS, flightDate: cameraSamples[0].date)
            guard !gps.isEmpty else {
                throw ABVCreatorError.invalidData("Le fichier GPS ne contient aucun point utilisable.")
            }
            var gps2: [GPSSample] = []
            if let stagedGPS2 {
                announce("Chargement des données GPS2…")
                gps2 = try loadGPS(from: stagedGPS2, flightDate: cameraSamples[0].date)
                guard !gps2.isEmpty else {
                    throw ABVCreatorError.invalidData("Le fichier GPX ne contient aucun point utilisable.")
                }
            }
            advance(gpsWeight, message: "Données GPS chargées.")
            let phoneSource = sources.first { $0.kind == .sensorLog }
            if phoneSource != nil {
                announce("Chargement des données iPhone…")
            }
            let phone = try phoneSource.map { try loadIPhone(from: $0.url) } ?? []
            advance(phoneWeight)
            announce("Fusion des données…")
            try writeMergedCSV(camera: cameraSamples, gps: gps, gps2: gps2, phone: phone, to: output)
            try "1.11-native".write(to: output.appendingPathComponent("version.txt"), atomically: true, encoding: .utf8)
            if usesX6 {
                // Angle de montage par défaut : 0° pour l'X6 (15° pour l'X4, valeur du viewer).
                try "0.0".write(to: output.appendingPathComponent("mounting_pitch.txt"), atomically: true, encoding: .utf8)
            }
            try writeMETARPlaceholder(to: output, start: cameraSamples[0].date)
            advance(mergeWeight, message: "Fusion des données terminée.")
            return CreationResult(url: output, flightDate: cameraSamples[0].date)
        } catch {
            if keepVideo {
                removeAllExceptVideos(in: output)
            } else {
                try? fileManager.removeItem(at: output)
            }
            throw error
        }
    }

    /// Supprime tout le contenu du paquet sauf les vidéos déjà converties.
    nonisolated static func removeAllExceptVideos(in package: URL) {
        let keep: Set<String> = ["front.mp4", "back.mp4"]
        let items = (try? FileManager.default.contentsOfDirectory(atPath: package.path)) ?? []
        for name in items where !keep.contains(name) {
            try? FileManager.default.removeItem(at: package.appendingPathComponent(name))
        }
    }

    /// Indique si le paquet contient déjà les deux vidéos converties.
    nonisolated static func hasConvertedVideo(in package: URL) -> Bool {
        ["front.mp4", "back.mp4"].allSatisfy {
            FileManager.default.fileExists(atPath: package.appendingPathComponent($0).path)
        }
    }

    /// Sets the HFS "has bundle" Finder flag so the folder is shown and handled as a
    /// package (single selectable item) instead of a browsable directory.
    nonisolated static func markAsPackage(_ url: URL) {
        var finderInfo = [UInt8](repeating: 0, count: 32)
        let hasBundleFlag: UInt16 = 0x2000
        finderInfo[8] = UInt8(hasBundleFlag >> 8)
        finderInfo[9] = UInt8(hasBundleFlag & 0xFF)
        _ = url.path.withCString { path in
            finderInfo.withUnsafeBytes { buffer in
                setxattr(path, "com.apple.FinderInfo", buffer.baseAddress, 32, 0, 0)
            }
        }
    }

    nonisolated static func formattedMinutes(_ seconds: Double) -> String {
        guard seconds >= 60 else { return "moins d'une minute" }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: seconds) ?? "\(Int(seconds / 60)) min"
    }

    nonisolated static func executable(_ name: String, candidates: [String]) throws -> URL {
        for path in candidates where !path.isEmpty && FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        throw ABVCreatorError.missingTool(name)
    }

    nonisolated static func findExiftool() throws -> URL {
        try executable("exiftool", candidates: ABVTool.exiftool.candidates)
    }

    /// Lit le modèle de caméra dans les métadonnées d'un fichier .insv via exiftool
    /// (ex. « Insta360 X3 »). Renvoie nil si exiftool est absent ou si le tag est vide.
    nonisolated static func detectCameraModel(of url: URL) -> String? {
        // Le modèle est stocké en clair (« Insta360 X6 », suivi de la version du firmware) dans le
        // trailer en fin de fichier : on lit seulement la fin du fichier, sans dépendre d'exiftool.
        guard let handle = try? FileHandle(forReadingFrom: url), let end = try? handle.seekToEnd() else { return nil }
        defer { try? handle.close() }
        let window: UInt64 = 1_000_000
        guard (try? handle.seek(toOffset: end > window ? end - window : 0)) != nil,
              let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .isoLatin1),
              let range = text.range(of: #"Insta360 [A-Za-z0-9 ]+"#, options: .regularExpression)
        else { return nil }
        return text[range].trimmingCharacters(in: .whitespaces)
    }

    /// Durée (en secondes) d'un fichier vidéo, lue par exiftool. Nil si elle est illisible.
    nonisolated static func videoDuration(of url: URL) -> TimeInterval? {
        guard let text = exiftoolValue(tag: "Duration", numeric: true, of: url),
              let duration = Double(text), duration > 0 else { return nil }
        return duration
    }

    /// Première ligne non vide renvoyée par `exiftool -s3 -<tag>`, ou nil.
    private nonisolated static func exiftoolValue(tag: String, numeric: Bool = false, of url: URL) -> String? {
        guard let exiftool = try? findExiftool() else { return nil }
        let process = Process()
        process.executableURL = exiftool
        process.arguments = ["-s3"] + (numeric ? ["-n"] : []) + ["-\(tag)", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        // Garde-fou : exiftool ne doit pas bloquer la détection indéfiniment.
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: watchdog)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
    }

    nonisolated static func run(
        _ executable: URL,
        _ arguments: [String],
        work: URL,
        cancellation: ABVCreatorCancellationToken,
        onCPUSample: (@Sendable (Double) -> Void)? = nil,
        onOutput: (@Sendable (String) -> Void)? = nil
    ) throws {
        try cancellation.checkCancelled()
        let logURL = work.appendingPathComponent("process.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: logURL)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = handle
        process.standardError = handle
        process.currentDirectoryURL = work
        ABVDebugConsole.emit("$ " + ([executable.path] + arguments).map(ABVDebugConsole.quoted).joined(separator: " "))
        try process.run()
        cancellation.track(process)
        defer { cancellation.untrack() }

        // Diffuse la sortie de la commande vers la console au fil de l'eau.
        let tail = Thread {
            guard let reader = try? FileHandle(forReadingFrom: logURL) else { return }
            defer { try? reader.close() }
            func flush() {
                let data = reader.availableData
                if !data.isEmpty {
                    let text = String(decoding: data, as: UTF8.self)
                    ABVDebugConsole.emit(text)
                    onOutput?(text)
                }
            }
            while process.isRunning {
                flush()
                Thread.sleep(forTimeInterval: 0.5)
            }
            flush()
        }
        tail.start()

        if let onCPUSample {
            let pid = process.processIdentifier
            let monitor = Thread {
                while process.isRunning {
                    Thread.sleep(forTimeInterval: 1)
                    guard process.isRunning, let cpu = cpuUsage(forPID: pid) else { continue }
                    onCPUSample(cpu)
                }
            }
            monitor.start()
        }

        process.waitUntilExit()
        Thread.sleep(forTimeInterval: 0.6) // laisse le dernier vidage de la sortie se terminer
        ABVDebugConsole.emit("→ \(executable.lastPathComponent) terminé (code \(process.terminationStatus))")
        if cancellation.isCancelled {
            throw ABVCreatorError.cancelled
        }
        guard process.terminationStatus == 0 else {
            let data = (try? Data(contentsOf: logURL)) ?? Data()
            let output = String(decoding: data, as: UTF8.self)
            throw ABVCreatorError.commandFailed(executable.lastPathComponent, output)
        }
    }

    nonisolated static func cpuUsage(forPID pid: Int32) -> Double? {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-o", "%cpu=", "-p", String(pid)]
        let outputPipe = Pipe()
        ps.standardOutput = outputPipe
        ps.standardError = Pipe()
        guard (try? ps.run()) != nil else { return nil }
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return Double(text)
    }

    nonisolated static func convertVideo(
        cameras: [URL], window: (offset: TimeInterval, duration: TimeInterval)? = nil,
        front: URL, back: URL, work: URL,
        highResolution: Bool = false,
        status: ABVFFmpegStatus? = nil,
        cancellation: ABVCreatorCancellationToken,
        onCPUSample: @escaping @Sendable (Double) -> Void
    ) throws {
        let ffmpeg = try executable("FFmpeg", candidates: ABVTool.ffmpeg.candidates)
        var arguments = ["-hide_banner", "-loglevel", "error", "-stats", "-y", "-hwaccel", "videotoolbox"]
        cameras.forEach {
            if let window { arguments += ["-ss", String(format: "%.3f", window.offset)] }
            arguments += ["-i", $0.path]
        }
        // Vues avant/arrière. En haute résolution, v360 produit une projection assez grande pour que la
        // zone recadrée fasse déjà 1920×1080 en pixels natifs (pas d'agrandissement après le crop).
        let views: String
        if highResolution {
            views = """
            [vf]v360=input=hammer:output=hammer:yaw=0:pitch=-25:w=3413:h=1920,crop=1920:1080[front];
            [vb]v360=input=hammer:output=hammer:yaw=180:w=3840:h=2160,crop=1920:1080[back]
            """
        } else {
            views = """
            [vf]v360=input=hammer:output=hammer:yaw=0:pitch=-25:w=1920:h=1080,crop=1080:608,scale=1920:1080:flags=lanczos[front];
            [vb]v360=input=hammer:output=hammer:yaw=180:w=1920:h=1080,crop=960:540,scale=1920:1080:flags=lanczos[back]
            """
        }
        let filter: String
        if cameras.count == 2 {
            filter = """
            [0:v:0][0:v:1]hstack[v0];[1:v:0][1:v:1]hstack[v1];
            [v0][v1]concat=n=2:v=1:a=0[v];
            [0:a][1:a]concat=n=2:v=0:a=1[a];[a]asplit=2[a1][a2];
            [v]v360=input=dfisheye:output=hammer:ih_fov=193:iv_fov=193[vh];[vh]split=2[vf][vb];
            \(views)
            """
        } else {
            filter = """
            [0:v:0][0:v:1]hstack[v];[0:a]asplit=2[a1][a2];
            [v]v360=input=dfisheye:output=hammer:ih_fov=193:iv_fov=193[vh];[vh]split=2[vf][vb];
            \(views)
            """
        }
        arguments += ["-filter_complex", filter]
        func outputArguments(map: String, audio: String, url: URL) -> [String] {
            (window.map { ["-t", String(format: "%.3f", $0.duration)] } ?? []) + ["-map", map, "-map", audio, "-c:v", "h264_videotoolbox", "-b:v", "8M",
             "-maxrate", "8M", "-bufsize", "24M", "-profile:v", "high", "-g", "60",
             "-allow_sw", "1", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k", url.path]
        }
        arguments += outputArguments(map: "[front]", audio: "[a1]", url: front)
        arguments += outputArguments(map: "[back]", audio: "[a2]", url: back)
        try run(
            ffmpeg, arguments, work: work, cancellation: cancellation, onCPUSample: onCPUSample,
            onOutput: status.map { status in { @Sendable text in status.ingest(text) } }
        )
    }

    nonisolated static func cameraData(
        from camera: URL, work: URL, accelerationSource: ABVAccelerationSource = .gyroflow,
        cancellation: ABVCreatorCancellationToken
    ) throws -> [CameraSample] {
        let gyroflow = try executable("Gyroflow", candidates: ABVTool.gyroflow.candidates)
        let quaternionURL = work.appendingPathComponent(camera.lastPathComponent + ".cli.csv")
        try? FileManager.default.removeItem(at: quaternionURL)
        do {
            try run(
                gyroflow, gyroflowExportArguments(camera: camera, output: quaternionURL, source: accelerationSource),
                work: work, cancellation: cancellation
            )
        } catch ABVCreatorError.commandFailed(let name, let output) {
            // Gyroflow 1.6.x peut planter à la fermeture (assertion libc++ dans Allocator.cpp)
            // après avoir écrit l'export : on accepte alors le fichier produit.
            let size = (try? FileManager.default.attributesOfItem(atPath: quaternionURL.path)[.size] as? NSNumber)?.intValue ?? 0
            guard size > 0 else { throw ABVCreatorError.commandFailed(name, output) }
        }
        if accelerationSource == .gyroflow {
            // Quaternion et accélération (m/s²) viennent du même export Gyroflow, un échantillon IMU sur 10.
            guard let firstDate = dateFromCameraName(camera.lastPathComponent) else {
                throw ABVCreatorError.invalidData("La date est absente du nom \(camera.lastPathComponent).")
            }
            var samples = try gyroflowSamples(at: quaternionURL).map { row in
                CameraSample(
                    date: firstDate.addingTimeInterval(row.milliseconds / 1_000),
                    milliseconds: row.milliseconds,
                    accelerationX: row.accelerationX, accelerationY: row.accelerationY, accelerationZ: row.accelerationZ,
                    quaternionW: row.quaternionW, quaternionX: row.quaternionX,
                    quaternionY: row.quaternionY, quaternionZ: row.quaternionZ
                )
            }
            smoothAccelerations(&samples, radius: 25)
            return samples
        }
        let gyro2bb = try executable("gyro2bb", candidates: ABVTool.gyro2bb.candidates)
        // gyro2bb écrit « <fichier>.csv » à côté du fichier qu'on lui donne. Quand la caméra n'a pas été
        // copiée dans `work` (aperçu, vidéo conservée), on passe par un lien symbolique pour que le CSV
        // arrive dans `work` et non dans le dossier des originaux.
        let fileManager = FileManager.default
        let motionURL = work.appendingPathComponent(camera.lastPathComponent + ".csv")
        var gyroInput = camera
        if camera.deletingLastPathComponent().standardizedFileURL != work.standardizedFileURL {
            let link = work.appendingPathComponent(camera.lastPathComponent)
            try? fileManager.removeItem(at: link)
            try fileManager.createSymbolicLink(at: link, withDestinationURL: camera)
            gyroInput = link
        }
        let gyroStart = Date()
        try run(gyro2bb, [gyroInput.path], work: work, cancellation: cancellation)
        if !fileManager.fileExists(atPath: motionURL.path), gyroInput != camera {
            // Si gyro2bb a résolu le lien, le CSV est à côté de l'original : on le récupère s'il est récent.
            let beside = camera.appendingPathExtension("csv")
            let modified = (try? beside.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified >= gyroStart.addingTimeInterval(-1) {
                try fileManager.moveItem(at: beside, to: motionURL)
            }
        }
        guard fileManager.fileExists(atPath: motionURL.path) else {
            throw ABVCreatorError.invalidData("gyro2bb n’a pas produit \(motionURL.lastPathComponent).")
        }

        let quaternions = try numericCSV(at: quaternionURL)
        let motion = try numericCSV(at: motionURL, headerLine: 66)
        guard let firstDate = dateFromCameraName(camera.lastPathComponent) else {
            throw ABVCreatorError.invalidData("La date est absente du nom \(camera.lastPathComponent).")
        }
        let qTimes = quaternions.compactMap { $0["timestamp_ms"] }
        guard !qTimes.isEmpty else {
            throw ABVCreatorError.invalidData("Export Gyroflow vide.")
        }
        var samples: [CameraSample] = []
        samples.reserveCapacity(motion.count / 10)
        for (index, row) in motion.enumerated() where index.isMultiple(of: 10) {
            guard let rawTime = row["time"] else { continue }
            let milliseconds = rawTime / 1_000
            guard milliseconds >= 0 else { continue }
            let qIndex = nearestIndex(in: qTimes, to: milliseconds)
            let q = quaternions[qIndex]
            samples.append(CameraSample(
                date: firstDate.addingTimeInterval(milliseconds / 1_000),
                milliseconds: milliseconds,
                accelerationX: (row["accSmooth[0]"] ?? 0) * 9.81 / 20_234,
                accelerationY: (row["accSmooth[1]"] ?? 0) * 9.81 / 20_234,
                accelerationZ: (row["accSmooth[2]"] ?? 0) * 9.81 / 20_234,
                quaternionW: q["org_quat_w"] ?? 1,
                quaternionX: q["org_quat_x"] ?? 0,
                quaternionY: q["org_quat_y"] ?? 0,
                quaternionZ: q["org_quat_z"] ?? 0
            ))
        }
        smoothAccelerations(&samples, radius: 25)
        return samples
    }

    /// Rotation du repère capteur X6 vers le repère X4 attendu par la chaîne d'attitude :
    /// Rz(−90°) · Ry(−90°), soit le quaternion (w, x, y, z) = (½, −½, −½, −½).
    /// Vérifiée numériquement : à plat → roulis/tangage 0 ; roulis ±30° → ±30° ; cabré 20° → +20°.
    private nonisolated static let x6SensorCorrection = simd_quatd(
        angle: -.pi / 2, axis: SIMD3<Double>(0, 0, 1)
    ) * simd_quatd(angle: -.pi / 2, axis: SIMD3<Double>(0, 1, 0))

    /// Pipeline Insta360 X6 : copie de `cameraData` (X4), à adapter aux particularités de l'X6
    /// (format du CSV gyro2bb, échelle de l'accéléromètre, axes…).
    nonisolated static func cameraDataX6(
        from camera: URL, work: URL, accelerationSource: ABVAccelerationSource = .gyroflow,
        cancellation: ABVCreatorCancellationToken
    ) throws -> [CameraSample] {
        let gyroflow = try executable("Gyroflow", candidates: ABVTool.gyroflow.candidates)
        let quaternionURL = work.appendingPathComponent(camera.lastPathComponent + ".cli.csv")
        try? FileManager.default.removeItem(at: quaternionURL)
        do {
            try run(
                gyroflow, gyroflowExportArguments(camera: camera, output: quaternionURL, source: accelerationSource),
                work: work, cancellation: cancellation
            )
        } catch ABVCreatorError.commandFailed(let name, let output) {
            // Gyroflow 1.6.x peut planter à la fermeture (assertion libc++ dans Allocator.cpp)
            // après avoir écrit l'export : on accepte alors le fichier produit.
            let size = (try? FileManager.default.attributesOfItem(atPath: quaternionURL.path)[.size] as? NSNumber)?.intValue ?? 0
            guard size > 0 else { throw ABVCreatorError.commandFailed(name, output) }
        }
        if accelerationSource == .gyroflow {
            // Mêmes corrections de repère que ci-dessous : q · x6SensorCorrection, accélération (−x, −y, z).
            guard let firstDate = dateFromCameraName(camera.lastPathComponent) else {
                throw ABVCreatorError.invalidData("La date est absente du nom \(camera.lastPathComponent).")
            }
            var samples = try gyroflowSamples(at: quaternionURL).map { row in
                let corrected = simd_quatd(
                    ix: row.quaternionX, iy: row.quaternionY, iz: row.quaternionZ, r: row.quaternionW
                ) * x6SensorCorrection
                return CameraSample(
                    date: firstDate.addingTimeInterval(row.milliseconds / 1_000),
                    milliseconds: row.milliseconds,
                    accelerationX: -row.accelerationX, accelerationY: -row.accelerationY, accelerationZ: row.accelerationZ,
                    quaternionW: corrected.real, quaternionX: corrected.imag.x,
                    quaternionY: corrected.imag.y, quaternionZ: corrected.imag.z
                )
            }
            smoothAccelerations(&samples, radius: 25)
            return samples
        }
        let gyro2bb = try executable("gyro2bb", candidates: ABVTool.gyro2bb.candidates)
        // gyro2bb écrit « <fichier>.csv » à côté du fichier qu'on lui donne. Quand la caméra n'a pas été
        // copiée dans `work` (aperçu, vidéo conservée), on passe par un lien symbolique pour que le CSV
        // arrive dans `work` et non dans le dossier des originaux.
        let fileManager = FileManager.default
        let motionURL = work.appendingPathComponent(camera.lastPathComponent + ".csv")
        var gyroInput = camera
        if camera.deletingLastPathComponent().standardizedFileURL != work.standardizedFileURL {
            let link = work.appendingPathComponent(camera.lastPathComponent)
            try? fileManager.removeItem(at: link)
            try fileManager.createSymbolicLink(at: link, withDestinationURL: camera)
            gyroInput = link
        }
        let gyroStart = Date()
        try run(gyro2bb, [gyroInput.path], work: work, cancellation: cancellation)
        if !fileManager.fileExists(atPath: motionURL.path), gyroInput != camera {
            // Si gyro2bb a résolu le lien, le CSV est à côté de l'original : on le récupère s'il est récent.
            let beside = camera.appendingPathExtension("csv")
            let modified = (try? beside.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified >= gyroStart.addingTimeInterval(-1) {
                try fileManager.moveItem(at: beside, to: motionURL)
            }
        }
        guard fileManager.fileExists(atPath: motionURL.path) else {
            throw ABVCreatorError.invalidData("gyro2bb n’a pas produit \(motionURL.lastPathComponent).")
        }

        let quaternions = try numericCSV(at: quaternionURL)
        let motion = try numericCSV(at: motionURL, headerLine: 66)
        guard let firstDate = dateFromCameraName(camera.lastPathComponent) else {
            throw ABVCreatorError.invalidData("La date est absente du nom \(camera.lastPathComponent).")
        }
        let qTimes = quaternions.compactMap { $0["timestamp_ms"] }
        guard !qTimes.isEmpty else {
            throw ABVCreatorError.invalidData("Export Gyroflow vide.")
        }
        var samples: [CameraSample] = []
        samples.reserveCapacity(motion.count / 10)
        for (index, row) in motion.enumerated() where index.isMultiple(of: 10) {
            guard let rawTime = row["time"] else { continue }
            let milliseconds = rawTime / 1_000
            guard milliseconds >= 0 else { continue }
            let qIndex = nearestIndex(in: qTimes, to: milliseconds)
            let q = quaternions[qIndex]
            // Repère capteur X6 différent du X4 : q ← q · x6SensorCorrection.
            // Accélération gyro2bb : l'axe avant est −Z comme sur l'X4 (corrélé à l'accélération GPS au
            // décollage), mais la gravité est sur −Y au lieu de +Y. Le repère X6 est donc celui de l'X4
            // tourné de 180° autour de l'axe avant : (x, y, z) → (−x, −y, z).
            let raw = simd_quatd(
                ix: q["org_quat_x"] ?? 0, iy: q["org_quat_y"] ?? 0, iz: q["org_quat_z"] ?? 0, r: q["org_quat_w"] ?? 1
            )
            let corrected = raw * x6SensorCorrection
            samples.append(CameraSample(
                date: firstDate.addingTimeInterval(milliseconds / 1_000),
                milliseconds: milliseconds,
                accelerationX: -(row["accSmooth[0]"] ?? 0) * 9.81 / 20_234,
                accelerationY: -(row["accSmooth[1]"] ?? 0) * 9.81 / 20_234,
                accelerationZ: (row["accSmooth[2]"] ?? 0) * 9.81 / 20_234,
                quaternionW: corrected.real,
                quaternionX: corrected.imag.x,
                quaternionY: corrected.imag.y,
                quaternionZ: corrected.imag.z
            ))
        }
        smoothAccelerations(&samples, radius: 25)
        return samples
    }

    /// Champs exportés par Gyroflow avec `export_all_samples` : un échantillon par mesure IMU, quaternion
    /// et accéléromètre (m/s²) inclus. Toutes les clés sont requises : Gyroflow plante si l'une manque.
    private nonisolated static let gyroflowAllSamplesFields = """
        { 'export_all_samples': true, 'original': { 'quaternion': true, 'euler_angles': true, \
        'gyroscope': true, 'accelerometer': true }, 'stabilized': { 'quaternion': true, \
        'euler_angles': true }, 'zooming': { 'minimal_fovs': true, 'fovs': true, 'focal_length': true } }
        """

    nonisolated static func gyroflowExportArguments(
        camera: URL, output: URL, source: ABVAccelerationSource
    ) -> [String] {
        var arguments = [camera.path, "--export-metadata", "3:\(output.path)"]
        if source == .gyroflow {
            arguments += ["--export-metadata-fields", gyroflowAllSamplesFields]
        }
        return arguments
    }

    struct GyroflowSample: Sendable {
        var milliseconds: Double
        var accelerationX: Double
        var accelerationY: Double
        var accelerationZ: Double
        var quaternionW: Double
        var quaternionX: Double
        var quaternionY: Double
        var quaternionZ: Double
    }

    /// Lit l'export Gyroflow « tous les échantillons » (~1,8 million de lignes, ~400 Mo pour 30 min)
    /// sans le charger en mémoire sous forme de dictionnaires : seule une ligne sur `step` est analysée.
    nonisolated static func gyroflowSamples(at url: URL, step: Int = 10) throws -> [GyroflowSample] {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        let wanted = ["timestamp_ms", "org_acc_x", "org_acc_y", "org_acc_z",
                      "org_quat_w", "org_quat_x", "org_quat_y", "org_quat_z"]
        var columns: [Int] = []
        var samples: [GyroflowSample] = []
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            let count = raw.count
            var offset = 0
            var line = -1
            while offset < count {
                let newline = memchr(base + offset, 0x0A, count - offset)
                var length = newline.map { base.advanced(by: offset).distance(to: UnsafeRawPointer($0)) } ?? count - offset
                let lineStart = offset
                offset += length + 1
                line += 1
                if line > 0, (line - 1) % step != 0 { continue }
                if length > 0, base.load(fromByteOffset: lineStart + length - 1, as: UInt8.self) == 0x0D { length -= 1 }
                let text = String(decoding: UnsafeRawBufferPointer(start: base + lineStart, count: length), as: UTF8.self)
                let fields = text.split(separator: ",", omittingEmptySubsequences: false)
                if line == 0 {
                    let names = fields.map(String.init)
                    columns = wanted.compactMap { names.firstIndex(of: $0) }
                    guard columns.count == wanted.count else {
                        throw ABVCreatorError.invalidData("Export Gyroflow : colonnes quaternion/accélération absentes.")
                    }
                    continue
                }
                let values = columns.compactMap { fields.indices.contains($0) ? Double(fields[$0]) : nil }
                guard values.count == wanted.count, values[0] >= 0 else { continue }
                samples.append(GyroflowSample(
                    milliseconds: values[0],
                    accelerationX: values[1], accelerationY: values[2], accelerationZ: values[3],
                    quaternionW: values[4], quaternionX: values[5], quaternionY: values[6], quaternionZ: values[7]
                ))
            }
        }
        guard !samples.isEmpty else { throw ABVCreatorError.invalidData("Export Gyroflow vide.") }
        return samples
    }

    nonisolated static func numericCSV(at url: URL, headerLine: Int = 0) throws -> [[String: Double]] {
        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.split(whereSeparator: \.isNewline)
        guard lines.indices.contains(headerLine) else { return [] }
        let headers = CSVParser.fields(in: String(lines[headerLine]))
        return lines.dropFirst(headerLine + 1).map { line in
            let fields = CSVParser.fields(in: String(line))
            return Dictionary(uniqueKeysWithValues: headers.enumerated().compactMap { index, name in
                guard fields.indices.contains(index), let value = Double(fields[index]) else { return nil }
                return (name, value)
            })
        }
    }

    nonisolated static func loadGPS(from url: URL, flightDate: Date) throws -> [GPSSample] {
        if url.pathExtension.lowercased() == "gpx" {
            let parser = GPXPointParser()
            guard XMLParser(contentsOf: url)?.parse(using: parser) == true else {
                throw ABVCreatorError.invalidData("Le fichier GPX est invalide.")
            }
            // Le GPX de la caméra répète un même point des centaines de fois (même horodatage) et n'est
            // pas ordonné : on trie puis on écarte les points quasi simultanés, sinon la vitesse
            // dérivée (distance / intervalle) explose.
            var unique: [GPSSample] = []
            for point in parser.points.sorted(by: { $0.date < $1.date }) {
                if let last = unique.last, point.date.timeIntervalSince(last.date) < 0.05 { continue }
                unique.append(point)
            }
            return enrichGPS(unique)
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        var pending: (time: String, lat: Double, lon: Double, alt: Double)?
        var points: [GPSSample] = []
        for line in text.split(whereSeparator: \.isNewline).map(String.init) {
            let parts = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            if line.hasPrefix("$GNGGA"), parts.count > 9,
               let lat = nmeaCoordinate(parts[2], direction: parts[3]),
               let lon = nmeaCoordinate(parts[4], direction: parts[5]),
               let altitude = Double(parts[9]) {
                pending = (parts[1], lat, lon, altitude * 3.28084)
            } else if line.hasPrefix("$GNRMC"), parts.count > 8, let pending,
                      let date = nmeaDate(parts[1], dateField: parts.count > 9 ? parts[9] : nil, fallbackDay: flightDate) {
                points.append(GPSSample(
                    date: date, latitude: pending.lat, longitude: pending.lon, altitude: pending.alt,
                    speed: (Double(parts[7]) ?? 0) * 1.852, heading: Double(parts[8]) ?? 0, verticalSpeed: 0
                ))
            }
        }
        return enrichGPS(points)
    }

    nonisolated static func enrichGPS(_ source: [GPSSample]) -> [GPSSample] {
        let sorted = source.filter { $0.latitude != 0 || $0.longitude != 0 }.sorted { $0.date < $1.date }
        guard !sorted.isEmpty else { return [] }
        var result = sorted
        var launchAltitude = 0.0
        for index in result.indices {
            guard index > 0 else { continue }
            let interval = max(0.001, result[index].date.timeIntervalSince(result[index - 1].date))
            if result[index].speed == 0 {
                let distance = haversine(result[index - 1], result[index])
                result[index].speed = distance / interval * 3.6
                result[index].heading = bearing(result[index - 1], result[index])
            }
            result[index].verticalSpeed = (result[index].altitude - result[index - 1].altitude) / interval * 60
            if launchAltitude == 0, result[index].speed > 80 { launchAltitude = result[index].altitude }
        }
        for index in result.indices { result[index].altitude += 7 - launchAltitude }
        return result
    }

    nonisolated static func loadIPhone(from url: URL) throws -> [IPhoneSample] {
        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.split(whereSeparator: \.isNewline)
        guard let first = lines.first else { return [] }
        let headers = CSVParser.fields(in: String(first))
        guard let timeIndex = headers.firstIndex(of: "loggingTime(txt)") else { return [] }
        let mapped: [(String, String, Double)] = [
            ("locationLatitude(WGS84)", "iphone_lat", 1), ("locationLongitude(WGS84)", "iphone_lon", 1),
            ("locationAltitude(m)", "iphone_alt", 3.28084), ("locationSpeed(m/s)", "iphone_speed", 3.6),
            ("locationTrueHeading(°)", "iphone_heading", 1),
            ("accelerometerAccelerationX(G)", "iphone_acc_x", 1),
            ("accelerometerAccelerationY(G)", "iphone_acc_y", 1),
            ("accelerometerAccelerationZ(G)", "iphone_acc_z", 1),
            ("motionQuaternionW(R)", "iphone_quat_w", 1), ("motionQuaternionX(R)", "iphone_quat_x", 1),
            ("motionQuaternionY(R)", "iphone_quat_y", 1), ("motionQuaternionZ(R)", "iphone_quat_z", 1)
        ]
        let iso = ISO8601DateFormatter()
        return lines.dropFirst().enumerated().compactMap { offset, line in
            guard offset.isMultiple(of: 5) else { return nil }
            let fields = CSVParser.fields(in: String(line))
            guard fields.indices.contains(timeIndex), let date = iso.date(from: fields[timeIndex]) else { return nil }
            var values: [String: Double] = [:]
            for (source, target, multiplier) in mapped {
                guard let index = headers.firstIndex(of: source), fields.indices.contains(index) else { continue }
                values[target] = (Double(fields[index]) ?? 0) * multiplier
            }
            return IPhoneSample(date: date, values: values)
        }.sorted { $0.date < $1.date }
    }

    nonisolated static func writeMergedCSV(
        camera: [CameraSample], gps: [GPSSample], gps2: [GPSSample] = [], phone: [IPhoneSample], to output: URL
    ) throws {
        let phoneColumns = ["iphone_lat", "iphone_lon", "iphone_alt", "iphone_speed", "iphone_heading",
                            "iphone_acc_x", "iphone_acc_y", "iphone_acc_z",
                            "iphone_quat_w", "iphone_quat_x", "iphone_quat_y", "iphone_quat_z"]
        var headers = ["", "timestamp", "x4_acc_x", "x4_acc_y", "x4_acc_z",
                       "x4_quat_w", "x4_quat_x", "x4_quat_y", "x4_quat_z", "timestamp_ms"]
        headers += phoneColumns
        headers += ["gps_lat", "gps_lon", "gps_alt", "gps_speed", "gps_heading", "gps_fpm",
                    "era5_wind_speed", "era5_wind_direction", "gps_ias"]
        let hasGPS2 = !gps2.isEmpty
        if hasGPS2 {
            headers += ["gps2_lat", "gps2_lon", "gps2_alt", "gps2_speed", "gps2_heading", "gps2_fpm", "gps2_ias"]
        }
        var outputText = headers.joined(separator: ",") + "\n"
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let gpsDates = gps.map(\.date)
        let gps2Dates = gps2.map(\.date)
        let phoneDates = phone.map(\.date)
        for (index, sample) in camera.enumerated() {
            let g = gps[nearestIndex(in: gpsDates, to: sample.date)]
            let p = phone.isEmpty ? nil : phone[nearestIndex(in: phoneDates, to: sample.date)]
            var values: [String] = [
                String(index), formatter.string(from: sample.date),
                number(sample.accelerationX), number(sample.accelerationY), number(sample.accelerationZ),
                number(sample.quaternionW), number(sample.quaternionX), number(sample.quaternionY), number(sample.quaternionZ),
                number(sample.milliseconds)
            ] + phoneColumns.map { number(p?.values[$0] ?? 0) } + [
                number(g.latitude), number(g.longitude), number(g.altitude), number(g.speed),
                number(g.heading), number(g.verticalSpeed), "0", "0", number(g.speed)
            ]
            if hasGPS2 {
                let g2 = gps2[nearestIndex(in: gps2Dates, to: sample.date)]
                values += [
                    number(g2.latitude), number(g2.longitude), number(g2.altitude), number(g2.speed),
                    number(g2.heading), number(g2.verticalSpeed), number(g2.speed)
                ]
            }
            outputText += values.joined(separator: ",") + "\n"
        }
        try outputText.write(to: output.appendingPathComponent("merged_data.csv"), atomically: true, encoding: .utf8)
    }

    nonisolated static func writeMETARPlaceholder(to output: URL, start: Date) throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let text = "time,metar\n\(formatter.string(from: start)),METAR indisponible lors de la création\n"
        try text.write(to: output.appendingPathComponent("metar.csv"), atomically: true, encoding: .utf8)
    }

    nonisolated static func smoothAccelerations(_ samples: inout [CameraSample], radius: Int) {
        guard samples.count > 1 else { return }
        let original = samples
        for index in samples.indices {
            let range = max(0, index - radius)...min(samples.count - 1, index + radius)
            let count = Double(range.count)
            samples[index].accelerationX = range.reduce(0) { $0 + original[$1].accelerationX } / count
            samples[index].accelerationY = range.reduce(0) { $0 + original[$1].accelerationY } / count
            samples[index].accelerationZ = range.reduce(0) { $0 + original[$1].accelerationZ } / count
        }
    }

    nonisolated static func dateFromCameraName(_ name: String) -> Date? {
        let components = name.split(separator: "_")
        guard components.count > 2 else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Europe/Paris")
        formatter.dateFormat = "yyyyMMddHHmmss"
        return formatter.date(from: String(components[1] + components[2]))
    }

    nonisolated static func nmeaCoordinate(_ value: String, direction: String) -> Double? {
        guard let raw = Double(value) else { return nil }
        let degrees = floor(raw / 100)
        var decimal = degrees + (raw - degrees * 100) / 60
        if direction == "S" || direction == "W" { decimal *= -1 }
        return decimal
    }

    /// Date absolue d'une trame NMEA. L'heure (`hhmmss.sss`) et la date (`ddmmyy`) sont en UTC ;
    /// sans champ date valide, on retombe sur le jour UTC de `fallbackDay`.
    nonisolated static func nmeaDate(_ value: String, dateField: String?, fallbackDay: Date) -> Date? {
        guard let raw = Double(value) else { return nil }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        var components = DateComponents()
        if let dateField, dateField.count == 6, let ddmmyy = Int(dateField) {
            components.day = ddmmyy / 10_000
            components.month = ddmmyy / 100 % 100
            components.year = 2_000 + ddmmyy % 100
        } else {
            components = utc.dateComponents([.year, .month, .day], from: fallbackDay)
        }
        components.hour = Int(raw / 10_000)
        components.minute = Int(raw.truncatingRemainder(dividingBy: 10_000) / 100)
        components.second = Int(raw.truncatingRemainder(dividingBy: 100))
        components.timeZone = utc.timeZone
        // Les fractions de seconde (4 trames par seconde) évitent les dates en double.
        return utc.date(from: components)?.addingTimeInterval(raw.truncatingRemainder(dividingBy: 1))
    }

    nonisolated static func nearestIndex(in values: [Double], to target: Double) -> Int {
        guard values.count > 1 else { return 0 }
        var low = 0
        var high = values.count
        while low < high {
            let middle = (low + high) / 2
            if values[middle] < target { low = middle + 1 } else { high = middle }
        }
        if low == 0 { return 0 }
        if low == values.count { return values.count - 1 }
        return abs(values[low] - target) < abs(values[low - 1] - target) ? low : low - 1
    }

    nonisolated static func nearestIndex(in values: [Date], to target: Date) -> Int {
        nearestIndex(in: values.map(\.timeIntervalSinceReferenceDate), to: target.timeIntervalSinceReferenceDate)
    }

    nonisolated static func haversine(_ a: GPSSample, _ b: GPSSample) -> Double {
        let radius = 6_371_000.0
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let dLat = (b.latitude - a.latitude) * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let value = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * radius * atan2(sqrt(value), sqrt(1 - value))
    }

    nonisolated static func bearing(_ a: GPSSample, _ b: GPSSample) -> Double {
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }

    nonisolated static func number(_ value: Double) -> String {
        value.isFinite ? String(format: "%.8f", locale: Locale(identifier: "en_US_POSIX"), value) : ""
    }
}

private final class GPXPointParser: NSObject, XMLParserDelegate {
    var points: [ABVCreatorPipeline.GPSSample] = []
    private var latitude: Double?
    private var longitude: Double?
    private var elevation: Double?
    private var date: Date?
    private var currentElement = ""
    private var text = ""
    private let iso = ISO8601DateFormatter()
    /// Les GPX d'exiftool datent leurs points avec des millisecondes (`08:07:19.166Z`),
    /// que `ISO8601DateFormatter` n'accepte pas sans l'option `.withFractionalSeconds`.
    private let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]
    ) {
        currentElement = elementName
        text = ""
        if elementName == "trkpt" {
            latitude = attributeDict["lat"].flatMap(Double.init)
            longitude = attributeDict["lon"].flatMap(Double.init)
            elevation = nil
            date = nil
        }
    }

    nonisolated func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    nonisolated func parser(
        _ parser: XMLParser, didEndElement elementName: String,
        namespaceURI: String?, qualifiedName qName: String?
    ) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if elementName == "ele" { elevation = Double(value) }
        if elementName == "time" { date = isoFractional.date(from: value) ?? iso.date(from: value) }
        if elementName == "trkpt", let latitude, let longitude, let date {
            points.append(.init(
                date: date, latitude: latitude, longitude: longitude,
                altitude: (elevation ?? 0) * 3.28084, speed: 0, heading: 0, verticalSpeed: 0
            ))
        }
        currentElement = ""
    }
}

private extension XMLParser {
    nonisolated func parse(using delegate: XMLParserDelegate) -> Bool {
        self.delegate = delegate
        return parse()
    }
}
#endif
