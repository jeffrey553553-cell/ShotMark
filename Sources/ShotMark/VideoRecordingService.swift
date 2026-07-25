import AppKit
import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

enum VideoRecordingServiceError: LocalizedError {
    case alreadyRecording
    case notRecording
    case alreadyPaused
    case notPaused
    case operationInProgress
    case operationTimedOut
    case noDisplay
    case addRecordingOutputFailed
    case outputURLMissing

    var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            return "当前已经在录制。"
        case .notRecording:
            return "当前没有正在进行的录制。"
        case .alreadyPaused:
            return "录制已经暂停。"
        case .notPaused:
            return "录制当前没有暂停。"
        case .operationInProgress:
            return "正在切换录制状态，请稍候。"
        case .operationTimedOut:
            return "录制状态切换超时，请重新开始录制。"
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
    private var pausingOutput: SCRecordingOutput?
    private var outputURL: URL?
    private var sessionDirectory: URL?
    private var segmentURLs: [URL] = []
    private var startCompletion: ((Result<URL, Error>) -> Void)?
    private var pauseCompletion: ((Result<Void, Error>) -> Void)?
    private var stopCompletion: ((Result<URL, Error>) -> Void)?
    private var stopCaptureFinished = false
    private var recordingFinished = false
    private var stopError: Error?
    private var isFinalizing = false
    private(set) var isPaused = false

    var isRecording: Bool {
        stream != nil
    }

    func start(
        selection: CaptureSelection,
        options: VideoRecordingOptions,
        outputURL: URL,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        guard stream == nil else {
            completion(.failure(VideoRecordingServiceError.alreadyRecording))
            return
        }

        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { [weak self] content, error in
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

            var createdSessionDirectory: URL?
            do {
                let sessionDirectory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("ShotMarkRecording-\(UUID().uuidString)", isDirectory: true)
                createdSessionDirectory = sessionDirectory
                try FileManager.default.createDirectory(
                    at: sessionDirectory,
                    withIntermediateDirectories: true
                )
                try FileManager.default.createDirectory(
                    at: outputURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try? FileManager.default.removeItem(at: outputURL)

                let segmentURL = Self.segmentURL(index: 0, directory: sessionDirectory)
                let recordingOutput = Self.makeRecordingOutput(url: segmentURL, delegate: self)
                let streamConfiguration = Self.streamConfiguration(for: selection, options: options)
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
                try stream.addRecordingOutput(recordingOutput)

                DispatchQueue.main.async {
                    self.stream = stream
                    self.recordingOutput = recordingOutput
                    self.outputURL = outputURL
                    self.sessionDirectory = sessionDirectory
                    self.segmentURLs = [segmentURL]
                    self.startCompletion = completion
                    self.isPaused = false

                    stream.startCapture { [weak self] error in
                        DispatchQueue.main.async {
                            guard let self else { return }
                            guard self.startCompletion != nil, self.stream === stream else { return }
                            if let error {
                                self.cleanupRecordingState(removeSessionDirectory: true)
                                completion(.failure(error))
                                return
                            }

                            self.startCompletion = nil
                            completion(.success(outputURL))
                        }
                    }
                }
            } catch {
                if let createdSessionDirectory {
                    try? FileManager.default.removeItem(at: createdSessionDirectory)
                }
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    func pause(completion: @escaping (Result<Void, Error>) -> Void) {
        guard let stream, let recordingOutput else {
            completion(.failure(isPaused
                ? VideoRecordingServiceError.alreadyPaused
                : VideoRecordingServiceError.notRecording))
            return
        }
        guard pauseCompletion == nil, stopCompletion == nil else {
            completion(.failure(VideoRecordingServiceError.operationInProgress))
            return
        }
        guard !isPaused else {
            completion(.failure(VideoRecordingServiceError.alreadyPaused))
            return
        }

        do {
            pauseCompletion = completion
            pausingOutput = recordingOutput
            try stream.removeRecordingOutput(recordingOutput)
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self, weak recordingOutput] in
                guard
                    let self,
                    let recordingOutput,
                    self.pausingOutput === recordingOutput,
                    let completion = self.pauseCompletion
                else { return }

                self.pauseCompletion = nil
                self.pausingOutput = nil
                let stream = self.stream
                self.cleanupRecordingState(removeSessionDirectory: true)
                let error = VideoRecordingServiceError.operationTimedOut
                completion(.failure(error))
                stream?.stopCapture(completionHandler: nil)
                self.onUnexpectedFailure?(error)
            }
        } catch {
            pauseCompletion = nil
            pausingOutput = nil
            completion(.failure(error))
        }
    }

    func resume(completion: @escaping (Result<Void, Error>) -> Void) {
        guard let stream, let sessionDirectory else {
            completion(.failure(VideoRecordingServiceError.notRecording))
            return
        }
        guard pauseCompletion == nil, stopCompletion == nil else {
            completion(.failure(VideoRecordingServiceError.operationInProgress))
            return
        }
        guard isPaused, recordingOutput == nil else {
            completion(.failure(VideoRecordingServiceError.notPaused))
            return
        }

        do {
            let segmentURL = Self.segmentURL(index: segmentURLs.count, directory: sessionDirectory)
            let nextOutput = Self.makeRecordingOutput(url: segmentURL, delegate: self)
            try stream.addRecordingOutput(nextOutput)
            segmentURLs.append(segmentURL)
            recordingOutput = nextOutput
            isPaused = false
            completion(.success(()))
        } catch {
            completion(.failure(error))
        }
    }

    func stop(completion: @escaping (Result<URL, Error>) -> Void) {
        guard let stream else {
            completion(.failure(VideoRecordingServiceError.notRecording))
            return
        }
        guard pauseCompletion == nil, stopCompletion == nil, !isFinalizing else {
            completion(.failure(VideoRecordingServiceError.operationInProgress))
            return
        }

        stopCompletion = completion
        stopCaptureFinished = false
        recordingFinished = recordingOutput == nil
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
                self.cleanupRecordingState(removeSessionDirectory: true)
                startCompletion(.failure(error))
                return
            }

            if let pauseCompletion = self.pauseCompletion, self.pausingOutput === recordingOutput {
                self.pauseCompletion = nil
                self.pausingOutput = nil
                let stream = self.stream
                self.cleanupRecordingState(removeSessionDirectory: true)
                pauseCompletion(.failure(error))
                stream?.stopCapture(completionHandler: nil)
                self.onUnexpectedFailure?(error)
                return
            }

            if self.stopCompletion != nil {
                self.stopError = error
                self.recordingFinished = true
                self.finishStopIfPossible()
                return
            }

            let stream = self.stream
            self.cleanupRecordingState(removeSessionDirectory: true)
            stream?.stopCapture(completionHandler: nil)
            self.onUnexpectedFailure?(error)
        }
    }

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        DispatchQueue.main.async {
            if self.pausingOutput === recordingOutput, let completion = self.pauseCompletion {
                self.pauseCompletion = nil
                self.pausingOutput = nil
                self.recordingOutput = nil
                self.isPaused = true
                completion(.success(()))
                return
            }

            if self.stopCompletion != nil {
                self.recordingFinished = true
                self.finishStopIfPossible()
            }
        }
    }

    static func streamConfiguration(
        for selection: CaptureSelection,
        options: VideoRecordingOptions
    ) -> SCStreamConfiguration {
        let outputSize = nativeOutputPixelSize(for: selection)
        let configuration = SCStreamConfiguration()
        configuration.width = Int(outputSize.width)
        configuration.height = Int(outputSize.height)
        configuration.sourceRect = sourceRect(for: selection)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.scalesToFit = false
        configuration.preservesAspectRatio = true
        configuration.showsCursor = true
        configuration.showMouseClicks = options.showsMouseClicks
        configuration.capturesAudio = options.audioMode.capturesSystemAudio
        configuration.excludesCurrentProcessAudio = true
        configuration.captureMicrophone = options.audioMode.capturesMicrophone
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.queueDepth = 8
        configuration.captureResolution = .best
        configuration.shouldBeOpaque = true
        return configuration
    }

    static func nativeOutputPixelSize(for selection: CaptureSelection) -> CGSize {
        selection.nativePixelSize
    }

    private static func sourceRect(for selection: CaptureSelection) -> CGRect {
        let screenFrame = selection.screen.frame
        let local = selection.rectInScreen.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
        return CGRect(
            x: local.minX,
            y: screenFrame.height - local.maxY,
            width: local.width,
            height: local.height
        ).integral
    }

    private static func makeRecordingOutput(
        url: URL,
        delegate: SCRecordingOutputDelegate
    ) -> SCRecordingOutput {
        let configuration = SCRecordingOutputConfiguration()
        configuration.outputURL = url
        configuration.outputFileType = .mp4
        configuration.videoCodecType = .h264
        return SCRecordingOutput(configuration: configuration, delegate: delegate)
    }

    private static func segmentURL(index: Int, directory: URL) -> URL {
        directory.appendingPathComponent(String(format: "segment-%03d.mp4", index))
    }

    private func finishStopIfPossible() {
        guard
            stopCaptureFinished,
            recordingFinished,
            !isFinalizing,
            let completion = stopCompletion,
            let outputURL
        else { return }

        isFinalizing = true
        stopCompletion = nil
        let segmentURLs = segmentURLs
        let sessionDirectory = sessionDirectory
        let stopError = stopError
        stream = nil
        recordingOutput = nil
        pausingOutput = nil

        if let stopError {
            cleanupRecordingState(removeSessionDirectory: true)
            completion(.failure(stopError))
            return
        }

        Task {
            let result: Result<URL, Error>
            do {
                try await VideoSegmentMerger.merge(segmentURLs: segmentURLs, outputURL: outputURL)
                result = .success(outputURL)
            } catch {
                result = .failure(error)
            }

            await MainActor.run {
                if let sessionDirectory {
                    try? FileManager.default.removeItem(at: sessionDirectory)
                }
                self.cleanupRecordingState(removeSessionDirectory: false)
                completion(result)
            }
        }
    }

    private func cleanupRecordingState(removeSessionDirectory: Bool) {
        if removeSessionDirectory, let sessionDirectory {
            try? FileManager.default.removeItem(at: sessionDirectory)
        }
        stream = nil
        recordingOutput = nil
        pausingOutput = nil
        outputURL = nil
        sessionDirectory = nil
        segmentURLs = []
        startCompletion = nil
        pauseCompletion = nil
        stopCompletion = nil
        stopCaptureFinished = false
        recordingFinished = false
        stopError = nil
        isFinalizing = false
        isPaused = false
    }
}

private extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}
