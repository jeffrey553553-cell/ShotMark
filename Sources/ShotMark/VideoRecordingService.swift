import AppKit
import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

enum VideoRecordingServiceError: LocalizedError {
    case alreadyRecording
    case notRecording
    case noDisplay
    case addRecordingOutputFailed
    case outputURLMissing

    var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            return "当前已经在录制。"
        case .notRecording:
            return "当前没有正在进行的录制。"
        case .noDisplay:
            return "没有找到要录制的显示器。"
        case .addRecordingOutputFailed:
            return "无法创建录制输出。"
        case .outputURLMissing:
            return "录制文件地址丢失。"
        }
    }
}

final class VideoRecordingService: NSObject, SCRecordingOutputDelegate {
    var onUnexpectedFailure: ((Error) -> Void)?

    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private var outputURL: URL?
    private var startCompletion: ((Result<URL, Error>) -> Void)?
    private var stopCompletion: ((Result<URL, Error>) -> Void)?
    private var stopCaptureFinished = false
    private var recordingFinished = false
    private var stopError: Error?

    var isRecording: Bool {
        stream != nil
    }

    func start(
        selection: CaptureSelection,
        quality: VideoQualityPreset,
        audioMode: VideoAudioMode,
        outputURL: URL,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        guard stream == nil else {
            completion(.failure(VideoRecordingServiceError.alreadyRecording))
            return
        }

        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { [weak self] content, error in
            guard let self else { return }
            if let error {
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }

            guard
                let displayID = selection.screen.displayID,
                let display = content?.displays.first(where: { $0.displayID == displayID })
            else {
                DispatchQueue.main.async { completion(.failure(VideoRecordingServiceError.noDisplay)) }
                return
            }

            let recordingOutputConfiguration = SCRecordingOutputConfiguration()
            recordingOutputConfiguration.outputURL = outputURL
            recordingOutputConfiguration.outputFileType = .mp4
            recordingOutputConfiguration.videoCodecType = .h264

            let recordingOutput = SCRecordingOutput(configuration: recordingOutputConfiguration, delegate: self)
            let streamConfiguration = self.streamConfiguration(for: selection, quality: quality, audioMode: audioMode)
            let filter: SCContentFilter
            if let currentApplication = content?.applications.first(where: { $0.processID == getpid() }) {
                filter = SCContentFilter(
                    display: display,
                    excludingApplications: [currentApplication],
                    exceptingWindows: []
                )
            } else {
                filter = SCContentFilter(display: display, excludingWindows: [])
            }
            let stream = SCStream(
                filter: filter,
                configuration: streamConfiguration,
                delegate: nil
            )

            do {
                try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: outputURL)
                try stream.addRecordingOutput(recordingOutput)
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }

            DispatchQueue.main.async {
                self.stream = stream
                self.recordingOutput = recordingOutput
                self.outputURL = outputURL
                self.startCompletion = completion

                stream.startCapture { [weak self] error in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        guard self.startCompletion != nil, self.stream === stream else { return }
                        if let error {
                            self.cleanupRecordingState()
                            completion(.failure(error))
                            return
                        }

                        self.startCompletion = nil
                        completion(.success(outputURL))
                    }
                }
            }
        }
    }

    func stop(completion: @escaping (Result<URL, Error>) -> Void) {
        guard let stream else {
            completion(.failure(VideoRecordingServiceError.notRecording))
            return
        }

        stopCompletion = completion
        stopCaptureFinished = false
        recordingFinished = false
        stopError = nil

        stream.stopCapture { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    self.stopError = error
                }
                self.stopCaptureFinished = true
                self.finishStopIfPossible()
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self, weak stream] in
            guard let self, self.stream === stream, self.stopCompletion != nil else { return }
            self.recordingFinished = true
            self.finishStopIfPossible()
        }
    }

    func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {}

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        DispatchQueue.main.async {
            if let startCompletion = self.startCompletion {
                self.startCompletion = nil
                self.cleanupRecordingState()
                startCompletion(.failure(error))
                return
            }

            if self.stopCompletion != nil {
                self.stopError = error
                self.recordingFinished = true
                self.finishStopIfPossible()
                return
            }

            let stream = self.stream
            self.cleanupRecordingState()
            stream?.stopCapture(completionHandler: nil)
            self.onUnexpectedFailure?(error)
        }
    }

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        DispatchQueue.main.async {
            self.recordingFinished = true
            self.finishStopIfPossible()
        }
    }

    private func streamConfiguration(
        for selection: CaptureSelection,
        quality: VideoQualityPreset,
        audioMode: VideoAudioMode
    ) -> SCStreamConfiguration {
        let outputSize = quality.outputPixelSize(for: selection)
        let configuration = SCStreamConfiguration()
        configuration.width = Int(outputSize.width)
        configuration.height = Int(outputSize.height)
        configuration.sourceRect = sourceRect(for: selection)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.scalesToFit = false
        configuration.preservesAspectRatio = true
        configuration.showsCursor = true
        configuration.showMouseClicks = false
        configuration.capturesAudio = audioMode.capturesSystemAudio
        configuration.excludesCurrentProcessAudio = true
        configuration.captureMicrophone = audioMode.capturesMicrophone
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.queueDepth = 8
        configuration.captureResolution = .best
        configuration.shouldBeOpaque = true
        return configuration
    }

    private func sourceRect(for selection: CaptureSelection) -> CGRect {
        let screenFrame = selection.screen.frame
        let local = selection.rectInScreen.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
        return CGRect(
            x: local.minX,
            y: screenFrame.height - local.maxY,
            width: local.width,
            height: local.height
        ).integral
    }

    private func finishStopIfPossible() {
        guard stopCaptureFinished, recordingFinished, let completion = stopCompletion else { return }
        let result: Result<URL, Error>
        if let stopError {
            result = .failure(stopError)
        } else if let outputURL {
            result = .success(outputURL)
        } else {
            result = .failure(VideoRecordingServiceError.outputURLMissing)
        }

        cleanupRecordingState()
        completion(result)
    }

    private func cleanupRecordingState() {
        stream = nil
        recordingOutput = nil
        outputURL = nil
        startCompletion = nil
        stopCompletion = nil
        stopCaptureFinished = false
        recordingFinished = false
        stopError = nil
    }
}

private extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}
