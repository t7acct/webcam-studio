import Foundation
import AVFoundation
import AudioToolbox

@main struct InspectRecording {
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else {
            print("Usage: ./inspect.sh /absolute/path/recording.mp4"); return
        }
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let videos = try await asset.loadTracks(withMediaType: .video)
        let audios = try await asset.loadTracks(withMediaType: .audio)
        guard let video = videos.first else { throw StudioInspectionError("No video track") }
        let size = try await video.load(.naturalSize)
        let transform = try await video.load(.preferredTransform)
        let formats = try await video.load(.formatDescriptions)
        guard let format = formats.first, CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_H264 else { throw StudioInspectionError("Video is not H.264") }
        guard transform == .identity else { throw StudioInspectionError("Unexpected rotation or mirroring transform") }
        let reader = try AVAssetReader(asset: asset)
        let videoOutput = AVAssetReaderTrackOutput(track: video, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        videoOutput.alwaysCopiesSampleData = false
        reader.add(videoOutput)
        guard reader.startReading() else { throw reader.error ?? StudioInspectionError("Video reader failed") }
        var frames = 0; var last = -Double.infinity; var maxGap = 0.0; var first = 0.0
        while let sample = videoOutput.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard pts > last else { throw StudioInspectionError("Video timestamps are not strictly increasing") }
            if frames > 0 { maxGap = max(maxGap, pts-last) } else { first = pts }
            last = pts; frames += 1
        }
        guard reader.status == .completed, frames > 0 else { throw reader.error ?? StudioInspectionError("Could not decode complete video") }
        var audioReport = "No audio track (silent clip)."
        if let audio = audios.first {
            let descriptions = try await audio.load(.formatDescriptions)
            guard let audioFormat = descriptions.first, CMFormatDescriptionGetMediaSubType(audioFormat) == kAudioFormatMPEG4AAC else { throw StudioInspectionError("Audio is not AAC") }
            let range = try await audio.load(.timeRange)
            let audioReader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: audio, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false])
            output.alwaysCopiesSampleData = false; audioReader.add(output)
            guard audioReader.startReading() else { throw audioReader.error ?? StudioInspectionError("Audio reader failed") }
            var peak: Float = 0; var energy = 0.0; var samples = 0
            while let sample = output.copyNextSampleBuffer() {
                guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
                var values = [Float](repeating: 0, count: CMBlockBufferGetDataLength(block)/4)
                let status = values.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
                guard status == kCMBlockBufferNoErr else { throw StudioInspectionError("Unreadable PCM samples") }
                for value in values { peak = max(peak, abs(value)); energy += Double(value*value) }
                samples += values.count
            }
            guard audioReader.status == .completed else { throw audioReader.error ?? StudioInspectionError("Could not decode complete audio") }
            let rms = samples > 0 ? sqrt(energy/Double(samples)) : 0
            audioReport = String(format: "AAC audio: %d decoded samples, peak %.1f dBFS, RMS %.1f dBFS, start %.3fs, end %.3fs%@", samples, 20*log10(max(1e-10,Double(peak))), 20*log10(max(1e-10,rms)), range.start.seconds, (range.start+range.duration).seconds, peak < 0.0001 ? " — WARNING: effectively silent" : "")
        }
        print("File: \(url.path)")
        print(String(format: "H.264 video: %.0f × %.0f, %d decoded frames, %.3fs asset duration, %.2f average fps, maximum frame gap %.3fs", size.width, size.height, frames, duration.seconds, Double(max(0, frames-1))/max(0.001,last-first), maxGap))
        print("Video transform: identity (unmirrored, no rotation).")
        print(audioReport)
        print("Complete decode and timestamp checks passed. Physical lip sync still needs playback with speech/claps.")
    }
}
struct StudioInspectionError: LocalizedError {
    let text: String
    init(_ text: String) { self.text = text }
    var errorDescription: String? { text }
}
