#if os(macOS)
import Darwin
import Foundation
import Observation

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
    }

    nonisolated func track(_ process: Process) {
        lock.lock()
        currentProcess = process
        let shouldTerminate = cancelled
        lock.unlock()
        if shouldTerminate { process.terminate() }
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

enum ABVTool: String, CaseIterable, Identifiable, Sendable {
    case exiftool
    case ffmpeg
    case gyro2bb

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .exiftool: "exiftool"
        case .ffmpeg: "ffmpeg"
        case .gyro2bb: "gyro2bb"
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
        }
    }

    nonisolated var isAvailable: Bool {
        candidates.contains { !$0.isEmpty && FileManager.default.isExecutableFile(atPath: $0) }
    }
}

@MainActor
@Observable
final class ABVCreatorModel {
    var sources: [ABVSourceFile] = []
    var state: State = .ready
    var log: [String] = []
    var outputURL: URL?
    var progress: Double = 0
    var ffmpegCPUUsage: Double?
    var creationStartDate: Date?
    var lastDuration: TimeInterval?
    var currentStep: String?
    private var cancellationToken: ABVCreatorCancellationToken?

    private static let lastSessionBookmarksKey = "ABVCreator.lastSessionBookmarks"

    enum State: Equatable {
        case ready
        case running
        case succeeded
        case failed(String)
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

    func cancel() {
        guard state == .running else { return }
        log.append("Annulation demandée…")
        cancellationToken?.cancel()
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

    func create(at destination: URL, overwrite: Bool = false) {
        guard canCreate else { return }
        state = .running
        log = ["Validation des fichiers…"]
        outputURL = nil
        progress = 0
        ffmpegCPUUsage = nil
        currentStep = "Validation des fichiers…"
        let startDate = Date()
        creationStartDate = startDate
        lastDuration = nil
        let selectedSources = sources
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
                if let cpu = update.ffmpegCPUUsage {
                    ffmpegCPUUsage = cpu
                }
            }
        }

        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try ABVCreatorPipeline.create(
                        sources: selectedSources, destination: destination,
                        overwrite: overwrite, cancellation: token
                    ) { update in
                        continuation.yield(update)
                    }
                }.value
                continuation.finish()
                ABVCreatorProcessRegistry.unregister(token)
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
        let gpsSource = sources.first { $0.kind == .gpx || $0.kind == .nmea }
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
            try fileManager.removeItem(at: output)
        }
        try fileManager.createDirectory(at: output, withIntermediateDirectories: true)
        markAsPackage(output)
        let work = output.appendingPathComponent(".creation", isDirectory: true)
        do {
            try fileManager.createDirectory(at: work, withIntermediateDirectories: true)
            defer { try? fileManager.removeItem(at: work) }

            announce("Copie des fichiers sources…")
            let stagedCameras = try cameras.map { source in
                let target = work.appendingPathComponent(source.url.lastPathComponent)
                try fileManager.copyItem(at: source.url, to: target)
                return target
            }
            let stagedGPS = work.appendingPathComponent(gpsSource.url.lastPathComponent)
            try fileManager.copyItem(at: gpsSource.url, to: stagedGPS)
            advance(stageWeight, message: "Fichiers copiés.")

            try cancellation.checkCancelled()
            let totalBytes: Int64 = stagedCameras.reduce(0) { total, url in
                let attributes = try? fileManager.attributesOfItem(atPath: url.path)
                let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
                return total + size
            }
            let totalGB = Double(totalBytes) / 1_000_000_000
            // Calibré sur un retour empirique de cette machine : ~40–50 min pour 20–30 Go, soit ~1.8 min/Go.
            let estimatedSeconds = totalGB * 108
            let estimateText = totalGB > 0.05
                ? " (~\(formattedMinutes(estimatedSeconds)) estimées pour \(String(format: "%.1f", totalGB)) Go)"
                : ""
            announce("Conversion vidéo en cours…" + estimateText)
            let front = output.appendingPathComponent("front.mp4")
            let back = output.appendingPathComponent("back.mp4")
            let videoStepFraction = fraction
            let videoStart = Date()
            try convertVideo(
                cameras: stagedCameras, front: front, back: back, work: work, cancellation: cancellation
            ) { cpu in
                let elapsed = Date().timeIntervalSince(videoStart)
                let estimatedProgress = estimatedSeconds > 0 ? min(elapsed / estimatedSeconds, 0.96) : 0
                let liveFraction = min(1, videoStepFraction + videoWeight * estimatedProgress)
                progress(ABVCreatorProgress(fraction: liveFraction, message: nil, ffmpegCPUUsage: cpu))
            }
            advance(videoWeight, message: "Conversion vidéo terminée.")

            var cameraSamples: [CameraSample] = []
            var segmentStart: Date?
            for camera in stagedCameras {
                try cancellation.checkCancelled()
                announce("Extraction de la télémétrie caméra : \(camera.lastPathComponent)…")
                var segment = try cameraData(from: camera, work: work, cancellation: cancellation)
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

            announce("Chargement des données GPS…")
            let gps = try loadGPS(from: stagedGPS, flightDate: cameraSamples[0].date)
            guard !gps.isEmpty else {
                throw ABVCreatorError.invalidData("Le fichier GPS ne contient aucun point utilisable.")
            }
            advance(gpsWeight, message: "Données GPS chargées.")
            let phoneSource = sources.first { $0.kind == .sensorLog }
            if phoneSource != nil {
                announce("Chargement des données iPhone…")
            }
            let phone = try phoneSource.map { try loadIPhone(from: $0.url) } ?? []
            advance(phoneWeight)
            announce("Fusion des données…")
            try writeMergedCSV(camera: cameraSamples, gps: gps, phone: phone, to: output)
            try "1.11-native".write(to: output.appendingPathComponent("version.txt"), atomically: true, encoding: .utf8)
            try writeMETARPlaceholder(to: output, start: cameraSamples[0].date)
            advance(mergeWeight, message: "Fusion des données terminée.")
            return CreationResult(url: output, flightDate: cameraSamples[0].date)
        } catch {
            try? fileManager.removeItem(at: output)
            throw error
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

    nonisolated static func run(
        _ executable: URL,
        _ arguments: [String],
        work: URL,
        cancellation: ABVCreatorCancellationToken,
        onCPUSample: (@Sendable (Double) -> Void)? = nil
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
        try process.run()
        cancellation.track(process)
        defer { cancellation.untrack() }

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
        cameras: [URL], front: URL, back: URL, work: URL,
        cancellation: ABVCreatorCancellationToken,
        onCPUSample: @escaping @Sendable (Double) -> Void
    ) throws {
        let ffmpeg = try executable("FFmpeg", candidates: ABVTool.ffmpeg.candidates)
        var arguments = ["-hide_banner", "-loglevel", "error", "-stats", "-y", "-hwaccel", "videotoolbox"]
        cameras.forEach { arguments += ["-i", $0.path] }
        let filter: String
        if cameras.count == 2 {
            filter = """
            [0:v:0][0:v:1]hstack[v0];[1:v:0][1:v:1]hstack[v1];
            [v0][v1]concat=n=2:v=1:a=0[v];
            [0:a][1:a]concat=n=2:v=0:a=1[a];[a]asplit=2[a1][a2];
            [v]v360=input=dfisheye:output=hammer:ih_fov=193:iv_fov=193[vh];[vh]split=2[vf][vb];
            [vf]v360=input=hammer:output=hammer:yaw=0:pitch=-25:w=1920:h=1080,crop=1080:608,scale=1920:1080:flags=lanczos[front];
            [vb]v360=input=hammer:output=hammer:yaw=180:w=1920:h=1080,crop=960:540,scale=1920:1080:flags=lanczos[back]
            """
        } else {
            filter = """
            [0:v:0][0:v:1]hstack[v];[0:a]asplit=2[a1][a2];
            [v]v360=input=dfisheye:output=hammer:ih_fov=193:iv_fov=193[vh];[vh]split=2[vf][vb];
            [vf]v360=input=hammer:output=hammer:yaw=0:pitch=-25:w=1920:h=1080,crop=1080:608,scale=1920:1080:flags=lanczos[front];
            [vb]v360=input=hammer:output=hammer:yaw=180:w=1920:h=1080,crop=960:540,scale=1920:1080:flags=lanczos[back]
            """
        }
        arguments += ["-filter_complex", filter]
        func outputArguments(map: String, audio: String, url: URL) -> [String] {
            ["-map", map, "-map", audio, "-c:v", "h264_videotoolbox", "-b:v", "8M",
             "-maxrate", "8M", "-bufsize", "24M", "-profile:v", "high", "-g", "60",
             "-allow_sw", "1", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k", url.path]
        }
        arguments += outputArguments(map: "[front]", audio: "[a1]", url: front)
        arguments += outputArguments(map: "[back]", audio: "[a2]", url: back)
        try run(ffmpeg, arguments, work: work, cancellation: cancellation, onCPUSample: onCPUSample)
    }

    nonisolated static func cameraData(
        from camera: URL, work: URL, cancellation: ABVCreatorCancellationToken
    ) throws -> [CameraSample] {
        let gyroflow = try executable("Gyroflow", candidates: [
            "/Applications/Gyroflow.app/Contents/MacOS/gyroflow"
        ])
        let gyro2bb = try executable("gyro2bb", candidates: ABVTool.gyro2bb.candidates)
        let quaternionURL = work.appendingPathComponent(camera.lastPathComponent + ".cli.csv")
        try run(gyroflow, [camera.path, "--export-metadata", "3:\(quaternionURL.path)"], work: work, cancellation: cancellation)
        try run(gyro2bb, [camera.path], work: work, cancellation: cancellation)
        let motionURL = work.appendingPathComponent(camera.lastPathComponent + ".csv")
        guard FileManager.default.fileExists(atPath: motionURL.path) else {
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
            return enrichGPS(parser.points)
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        var pending: (time: String, lat: Double, lon: Double, alt: Double)?
        var points: [GPSSample] = []
        let calendar = Calendar(identifier: .gregorian)
        let start = calendar.startOfDay(for: flightDate)
        for line in text.split(whereSeparator: \.isNewline).map(String.init) {
            let parts = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            if line.hasPrefix("$GNGGA"), parts.count > 9,
               let lat = nmeaCoordinate(parts[2], direction: parts[3]),
               let lon = nmeaCoordinate(parts[4], direction: parts[5]),
               let altitude = Double(parts[9]) {
                pending = (parts[1], lat, lon, altitude * 3.28084)
            } else if line.hasPrefix("$GNRMC"), parts.count > 8, let pending,
                      let date = nmeaDate(parts[1], day: start) {
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
        camera: [CameraSample], gps: [GPSSample], phone: [IPhoneSample], to output: URL
    ) throws {
        let phoneColumns = ["iphone_lat", "iphone_lon", "iphone_alt", "iphone_speed", "iphone_heading",
                            "iphone_acc_x", "iphone_acc_y", "iphone_acc_z",
                            "iphone_quat_w", "iphone_quat_x", "iphone_quat_y", "iphone_quat_z"]
        var headers = ["", "timestamp", "x4_acc_x", "x4_acc_y", "x4_acc_z",
                       "x4_quat_w", "x4_quat_x", "x4_quat_y", "x4_quat_z", "timestamp_ms"]
        headers += phoneColumns
        headers += ["gps_lat", "gps_lon", "gps_alt", "gps_speed", "gps_heading", "gps_fpm",
                    "era5_wind_speed", "era5_wind_direction", "gps_ias"]
        var outputText = headers.joined(separator: ",") + "\n"
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let gpsDates = gps.map(\.date)
        let phoneDates = phone.map(\.date)
        for (index, sample) in camera.enumerated() {
            let g = gps[nearestIndex(in: gpsDates, to: sample.date)]
            let p = phone.isEmpty ? nil : phone[nearestIndex(in: phoneDates, to: sample.date)]
            let values: [String] = [
                String(index), formatter.string(from: sample.date),
                number(sample.accelerationX), number(sample.accelerationY), number(sample.accelerationZ),
                number(sample.quaternionW), number(sample.quaternionX), number(sample.quaternionY), number(sample.quaternionZ),
                number(sample.milliseconds)
            ] + phoneColumns.map { number(p?.values[$0] ?? 0) } + [
                number(g.latitude), number(g.longitude), number(g.altitude), number(g.speed),
                number(g.heading), number(g.verticalSpeed), "0", "0", number(g.speed)
            ]
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

    nonisolated static func nmeaDate(_ value: String, day: Date) -> Date? {
        guard let raw = Double(value) else { return nil }
        let hour = Int(raw / 10_000)
        let minute = Int(raw.truncatingRemainder(dividingBy: 10_000) / 100)
        let second = Int(raw.truncatingRemainder(dividingBy: 100))
        return Calendar(identifier: .gregorian).date(bySettingHour: hour, minute: minute, second: second, of: day)
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
        if elementName == "time" { date = iso.date(from: value) }
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
