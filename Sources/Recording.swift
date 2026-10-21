import Foundation
import AVFoundation
import AudioToolbox

// Used only on CaptureEngine's serial media queue, including both input callbacks.
final class MovieRecorder {
    let destination: URL
    let temporary: URL
    let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let audio: AVAssetWriterInput?
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private(set) var start: CMTime?
    private var lastVideo = CMTime.invalid
    private var lastAudio = CMTime.invalid
    private var frameDuration = CMTime(value: 1, timescale: 30)
    private(set) var videoFrames = 0
    private(set) var audioSamples = 0
    private(set) var videoDrops = 0
    private(set) var audioDrops = 0
    private(set) var failure: Error?
    private var finishing = false
    var elapsed: Double { guard let start, lastVideo.isValid else { return 0 }; return max(0, (lastVideo - start).seconds) }

    init(destination: URL, width: Int, height: Int, withAudio: Bool) throws {
        self.destination = destination
        guard destination.pathExtension.lowercased() == "mp4" else { throw StudioError("Choose a filename ending in .mp4.") }
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw StudioError("A file already exists at that location. Choose a new filename; existing recordings are never overwritten.") }
        if let available = Self.availableBytes(at: destination), available < 150_000_000 {
            throw StudioError("There is less than 150 MB free at the save location. Free some storage or choose another disk.")
        }
        temporary = destination.deletingLastPathComponent().appendingPathComponent(".\(destination.deletingPathExtension().lastPathComponent).\(UUID().uuidString).partial.mp4")
        writer = try AVAssetWriter(outputURL: temporary, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        let settings: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2, AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2],
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: height >= 1080 ? 8_000_000 : 4_500_000,
                AVVideoExpectedSourceFrameRateKey: 30, AVVideoMaxKeyFrameIntervalKey: 60,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel, AVVideoAllowFrameReorderingKey: false]]
        guard writer.canApply(outputSettings: settings, forMediaType: .video) else { throw StudioError("H.264 encoding is unavailable for this capture mode.") }
        video = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        video.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true])
        guard writer.canAdd(video) else { throw StudioError("Could not create the video encoder.") }; writer.add(video)
        if withAudio {
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 128_000]
            guard writer.canApply(outputSettings: settings, forMediaType: .audio) else { throw StudioError("AAC encoding is unavailable.") }
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw StudioError("Could not create the audio encoder.") }; writer.add(input); audio = input
        } else { audio = nil }
        guard writer.startWriting() else { throw writer.error ?? StudioError("Could not start the MP4 writer.") }
    }
    static func availableBytes(at destination: URL) -> Int64? {
        let parent = destination.deletingLastPathComponent()
        if let values = try? parent.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]), let bytes = values.volumeAvailableCapacityForImportantUsage { return bytes }
        let attributes = try? FileManager.default.attributesOfFileSystem(forPath: parent.path)
        return (attributes?[.systemFreeSize] as? NSNumber)?.int64Value
    }
    func appendVideo(_ pixelBuffer: CVPixelBuffer, at pts: CMTime, duration: CMTime) {
        guard !finishing, failure == nil, pts.isValid, pts.isNumeric else { return }
        guard !lastVideo.isValid || pts > lastVideo else { videoDrops += 1; return }
        if start == nil { start = pts; writer.startSession(atSourceTime: pts) }
        guard video.isReadyForMoreMediaData else { videoDrops += 1; checkFailure(); return }
        guard adaptor.append(pixelBuffer, withPresentationTime: pts) else { failure = writer.error ?? StudioError("Video encoding failed. Check available storage."); return }
        lastVideo = pts; videoFrames += 1
        if duration.isValid && duration.isNumeric && duration.seconds > 0 && duration.seconds < 1 { frameDuration = duration }
    }
    func appendAudio(_ sample: CMSampleBuffer) {
        guard !finishing, failure == nil, let audio, let start else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        // Both outputs belong to one capture session. Keep its shared sample timeline.
        guard pts.isValid, pts.isNumeric, pts >= start, !lastAudio.isValid || pts > lastAudio else { return }
        guard audio.isReadyForMoreMediaData else { audioDrops += 1; checkFailure(); return }
        guard audio.append(sample) else { failure = writer.error ?? StudioError("Audio encoding failed."); return }
        lastAudio = pts; audioSamples += 1
    }
    private func checkFailure() { if writer.status == .failed { failure = writer.error ?? StudioError("The encoder stopped unexpectedly.") } }
    func finish(completion: @escaping (Result<URL, Error>, String) -> Void) {
        guard !finishing else { return }; finishing = true
        let details = "\(videoFrames) video frames · \(audioSamples) audio buffers · dropped: video \(videoDrops), audio \(audioDrops)"
        guard let _ = start, videoFrames > 0, failure == nil else {
            writer.cancelWriting()
            completion(.failure(failure ?? StudioError("No camera frames were recorded. Check the camera and try again.")), details); return
        }
        writer.endSession(atSourceTime: lastVideo + frameDuration)
        video.markAsFinished(); audio?.markAsFinished()
        writer.finishWriting {
            guard self.writer.status == .completed else {
                completion(.failure(self.writer.error ?? StudioError("The recording could not be finalised.")), details); return
            }
            do {
                // moveItem fails if the destination appeared during recording. It never replaces it.
                try FileManager.default.moveItem(at: self.temporary, to: self.destination)
                let warning = self.audio != nil && self.audioSamples == 0 ? " No microphone samples arrived; this file is silent." : ""
                completion(.success(self.destination), details + warning)
            } catch { completion(.failure(StudioError("The MP4 was finalised but could not be moved to your chosen filename. It is preserved at \(self.temporary.path). \(error.localizedDescription)")), details) }
        }
    }
}
