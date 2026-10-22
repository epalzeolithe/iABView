#if os(macOS)
import AppKit
import CoreMedia
import Observation
import ScreenCaptureKit

@MainActor
@Observable
final class ScreenRecorder: NSObject {
    private(set) var isRecording = false
    private(set) var lastRecordingURL: URL?
    private(set) var errorMessage: String?

    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?

    func toggleRecording(destinationDirectory: URL?) {
        Task {
            if isRecording {
                await stopRecording()
            } else {
                await startRecording(destinationDirectory: destinationDirectory)
            }
        }
    }

    func dismissError() {
        errorMessage = nil
    }

    private func startRecording(destinationDirectory: URL?) async {
        do {
            try ensureScreenCapturePermission()

            guard let appWindow = NSApp.keyWindow ?? NSApp.mainWindow else {
                throw RecorderError.windowUnavailable
            }

            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            guard let captureWindow = content.windows.first(where: {
                $0.windowID == CGWindowID(appWindow.windowNumber)
            }) else {
                throw RecorderError.windowUnavailable
            }

            let directory = destinationDirectory
                ?? FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            let outputURL = nextRecordingURL(in: directory)
            let filter = SCContentFilter(desktopIndependentWindow: captureWindow)

            let configuration = SCStreamConfiguration()
            configuration.width = max(2, Int(captureWindow.frame.width) * 2)
            configuration.height = max(2, Int(captureWindow.frame.height) * 2)
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
            configuration.queueDepth = 5
            configuration.capturesAudio = true
            configuration.excludesCurrentProcessAudio = false
            configuration.showsCursor = true

            let outputConfiguration = SCRecordingOutputConfiguration()
            outputConfiguration.outputURL = outputURL
            let recordingOutput = SCRecordingOutput(
                configuration: outputConfiguration,
                delegate: self
            )
            let stream = SCStream(
                filter: filter,
                configuration: configuration,
                delegate: self
            )
            try stream.addRecordingOutput(recordingOutput)
            try await stream.startCapture()

            self.stream = stream
            self.recordingOutput = recordingOutput
            lastRecordingURL = outputURL
            isRecording = true
        } catch {
            errorMessage = error.localizedDescription
            isRecording = false
        }
    }

    private func ensureScreenCapturePermission() throws {
        guard !CGPreflightScreenCaptureAccess() else { return }

        if CGRequestScreenCaptureAccess() {
            throw RecorderError.permissionRequiresRelaunch
        }
        throw RecorderError.permissionDenied
    }

    private func stopRecording() async {
        guard let stream else { return }
        do {
            if let recordingOutput {
                try stream.removeRecordingOutput(recordingOutput)
            }
            try await stream.stopCapture()
            self.stream = nil
            self.recordingOutput = nil
            isRecording = false
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func nextRecordingURL(in directory: URL) -> URL {
        for index in 1...9_999 {
            let url = directory.appendingPathComponent(
                String(format: "record_%03d.mp4", index)
            )
            if !FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return directory.appendingPathComponent("record_\(UUID().uuidString).mp4")
    }
}

extension ScreenRecorder: SCRecordingOutputDelegate {
    nonisolated func recordingOutputDidStartRecording(
        _ recordingOutput: SCRecordingOutput
    ) {}

    nonisolated func recordingOutputDidFinishRecording(
        _ recordingOutput: SCRecordingOutput
    ) {}

    nonisolated func recordingOutput(
        _ recordingOutput: SCRecordingOutput,
        didFailWithError error: any Error
    ) {
        Task { @MainActor [weak self] in
            self?.errorMessage = error.localizedDescription
            self?.isRecording = false
        }
    }
}

extension ScreenRecorder: SCStreamDelegate {
    nonisolated func stream(
        _ stream: SCStream,
        didStopWithError error: any Error
    ) {
        Task { @MainActor [weak self] in
            self?.errorMessage = error.localizedDescription
            self?.isRecording = false
        }
    }
}

enum RecorderError: LocalizedError {
    case permissionDenied
    case permissionRequiresRelaunch
    case windowUnavailable

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "Autorisez iABView dans Réglages Système > Confidentialité et sécurité > Enregistrement de l’écran et de l’audio système."
        case .permissionRequiresRelaunch:
            "L’autorisation est accordée. Quittez complètement iABView, puis relancez l’app pour commencer l’enregistrement."
        case .windowUnavailable:
            "La fenêtre ABView n’est pas disponible pour l’enregistrement."
        }
    }
}
#else
import Foundation
import Observation

@MainActor
@Observable
final class ScreenRecorder {
    private(set) var isRecording = false
    private(set) var lastRecordingURL: URL?
    private(set) var errorMessage: String?

    func toggleRecording(destinationDirectory: URL?) {
        errorMessage = "L’enregistrement de la fenêtre n’est disponible que sur Mac."
    }

    func dismissError() {
        errorMessage = nil
    }
}
#endif
