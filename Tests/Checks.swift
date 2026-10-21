import Foundation
import CoreImage
import AVFoundation
import Darwin

@main struct Checks {
    static func main() async throws {
        setbuf(stdout, nil)
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fatalError("FAIL: \(message)") }
            checks += 1; print("PASS: \(message)")
        }
        var auto = AutoLighting()
        let dark = LightStatistics(median: 0.1, highlight: 0.6, clippedFraction: 0)
        auto.step(dark, at: 0)
        check(auto.exposure > 0 && auto.exposure < 0.12, "dark-scene correction enters gradually")
        for i in 1...200 { auto.step(dark, at: Double(i) * 0.25) }
        check(auto.exposure <= 0.8 && auto.shadows <= 0.25, "automatic compensation stays bounded")
        let before = auto.exposure
        auto.step(LightStatistics(median: 0.8, highlight: 1, clippedFraction: 0.3), at: 50.25)
        check(before - auto.exposure < 0.25 && auto.exposure > 0, "one bright frame cannot produce an exposure jump")
        for i in 202...500 { auto.step(LightStatistics(median: 0.1, highlight: 0.99, clippedFraction: 0.1), at: Double(i) * 0.25) }
        check(auto.exposure <= 0.181, "bright backgrounds limit positive exposure to 0.18 EV")
        auto.reset(); check(auto.exposure == 0 && auto.shadows == 0, "reset clears accumulated automatic gain")
        auto.step(dark, at: 50); let stable = auto.exposure
        auto.step(dark, at: 49); check(auto.exposure == stable, "out-of-order metering timestamps do not change gain")
        let ranges = CaptureEngine.cameraDevices().flatMap { $0.formats }.flatMap { $0.videoSupportedFrameRateRanges }
        if ranges.isEmpty { print("SKIP: frame-duration negotiation requires a connected camera") }
        else {
            check(ranges.allSatisfy { range in
                let d = CaptureEngine.frameDuration(in: range, targetFPS: 30)
                return d >= range.minFrameDuration && d <= range.maxFrameDuration
            }, "negotiated 30 fps durations remain within every connected camera's exact bounds")
        }
        guard let gpu = GPU() else { fatalError("Metal unavailable") }
        let pipeline = EnhancementPipeline(gpu: gpu)
        let image = CIImage(color: CIColor(red: 0.16, green: 0.12, blue: 0.09)).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 36))
        func pixels(_ image: CIImage) -> [UInt8] {
            var data = [UInt8](repeating: 0, count: 64*36*4)
            data.withUnsafeMutableBytes { gpu.context.render(image, toBitmap: $0.baseAddress!, rowBytes: 64*4, bounds: image.extent, format: .RGBA8, colorSpace: gpu.colorSpace) }
            return data
        }
        let raw = pixels(image)
        let neutral = pipeline.process(image, settings: .neutral, at: 0)
        check(pixels(neutral) == raw, "neutral pipeline is pixel-identical to original")
        var bypass = EnhancementSettings(); bypass.enabled = false; bypass.autoLighting = true; bypass.exposure = 1.5
        check(pixels(pipeline.process(image, settings: bypass, at: 1)) == raw, "master bypass ignores manual and automatic adjustments")
        var bright = EnhancementSettings.neutral; bright.exposure = 0.5
        check(pixels(pipeline.process(image, settings: bright, at: 2))[0] > raw[0], "processed pixels contain exposure enhancement")
        let darkPatch = CIImage(color: CIColor(red: 0.05, green: 0.05, blue: 0.05)).cropped(to: image.extent)
        check(pixels(pipeline.process(darkPatch, settings: EnhancementSettings(), at: 2))[0] > 5, "gentle contrast preserves dark shadow detail")
        var warm = EnhancementSettings.neutral; warm.warmth = 1000
        let warmPixels = pixels(pipeline.process(image, settings: warm, at: 3))
        check(Double(warmPixels[0])/Double(max(1,warmPixels[2])) > Double(raw[0])/Double(raw[2]), "positive warmth increases red relative to blue")
        let store = FrameStore()
        let enhanced = pipeline.process(image, settings: bright, at: 4)
        store.set(image, enhanced: enhanced); store.configure(mode: "Original", mirror: false)
        check(pixels(store.get()!) == raw, "Original preview bypasses enhancement")
        store.configure(mode: "Enhanced", mirror: false)
        check(pixels(store.get()!) == pixels(enhanced), "Enhanced preview uses the processed output")
        let backgroundProcessor = BackgroundProcessor(gpu: gpu)
        let off = BackgroundSettings()
        backgroundProcessor.configure(off)
        check(pixels(backgroundProcessor.apply(to: image, source: image, at: 0, settings: off)) == raw, "background Off is pixel-identical and independent of lighting controls")
        var backgroundSettings = BackgroundSettings(); backgroundSettings.mode = .colour
        backgroundSettings.red = 0.04; backgroundSettings.green = 0.08; backgroundSettings.blue = 0.4
        let backdrop = BackgroundProcessor.backdrop(for: image, settings: backgroundSettings, photo: nil)
        let whiteMask = CIImage(color: .white).cropped(to: image.extent)
        let blackMask = CIImage(color: .black).cropped(to: image.extent)
        check(pixels(BackgroundProcessor.composite(foreground: image, background: backdrop, mask: whiteMask)) == raw, "person mask keeps foreground detail unchanged")
        check(pixels(BackgroundProcessor.composite(foreground: image, background: backdrop, mask: blackMask)) == pixels(backdrop), "background mask replaces only the background")
        backgroundProcessor.configure(backgroundSettings)
        let covered = backgroundProcessor.apply(to: image, source: image, at: 0, settings: backgroundSettings)
        check(pixels(covered) == pixels(backdrop), "missing person mask covers the frame instead of revealing the untreated room")
        backgroundProcessor.waitUntilIdle()
        var photoSettings = backgroundSettings; photoSettings.mode = .photo
        check(pixels(BackgroundProcessor.backdrop(for: image, settings: photoSettings, photo: nil)) == pixels(backdrop), "missing photo falls back to the selected solid colour")
        let widePhoto = CIImage(color: CIColor(red: 0.1, green: 0.3, blue: 0.2)).cropped(to: CGRect(x: 0, y: 0, width: 200, height: 100))
        check(BackgroundProcessor.backdrop(for: image, settings: photoSettings, photo: widePhoto).extent == image.extent, "photo background fills the exact frame without changing video dimensions")
        var smallMask: CVPixelBuffer?
        CVPixelBufferCreate(nil, 64, 36, kCVPixelFormatType_OneComponent8, nil, &smallMask)
        let maskBuffer = smallMask!
        CVPixelBufferLockBaseAddress(maskBuffer, [])
        let maskBytes = CVPixelBufferGetBaseAddress(maskBuffer)!.assumingMemoryBound(to: UInt8.self)
        let maskStride = CVPixelBufferGetBytesPerRow(maskBuffer)
        maskBytes.initialize(repeating: 0, count: maskStride * 36)
        for y in 6..<32 { for x in 16..<40 { maskBytes[y * maskStride + x] = 255 } }
        for y in 25..<28 { for x in 60..<63 { maskBytes[y * maskStride + x] = 255 } }
        CVPixelBufferUnlockBaseAddress(maskBuffer, [])
        let cleanedMask = pixels(PersonMaskCleaner().clean(maskBuffer)!)
        check(cleanedMask[(18 * 64 + 24) * 4] > 250, "mask cleanup preserves the main presenter")
        check(cleanedMask[(26 * 64 + 61) * 4] < 5, "mask cleanup removes disconnected background objects")
        let work = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("webcam-check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let existing = work.appendingPathComponent("existing.mp4")
        try Data("preserve me".utf8).write(to: existing)
        do { _ = try MovieRecorder(destination: existing, width: 1280, height: 720, withAudio: false); fatalError("overwrote file") }
        catch { check(try! String(contentsOf: existing, encoding: .utf8) == "preserve me", "existing files are rejected without modifying content") }
        // Encode and decode actual processed pixels using the same class as the app.
        let movie = work.appendingPathComponent("processed.mp4")
        let writer = try MovieRecorder(destination: movie, width: 1280, height: 720, withAudio: false)
        let pool = PixelPool()
        let source = image.transformed(by: CGAffineTransform(scaleX: 20, y: 20))
        let enhancedSource = pipeline.process(source, settings: bright, at: 5)
        let movieBackground = BackgroundProcessor.backdrop(for: enhancedSource, settings: backgroundSettings, photo: nil)
        let splitMask = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 36)).composited(over: blackMask)
        let movieImage = BackgroundProcessor.composite(foreground: enhancedSource, background: movieBackground, mask: BackgroundProcessor.fittedMask(splitMask, to: source.extent))
        for i in 0..<30 {
            let buffer = pool.get(width: 1280, height: 720)!
            gpu.context.render(movieImage, to: buffer, bounds: source.extent, colorSpace: gpu.colorSpace)
            writer.appendVideo(buffer, at: CMTime(value: Int64(300 + i), timescale: 30), duration: CMTime(value: 1, timescale: 30))
            try await Task.sleep(nanoseconds: 34_000_000)
        }
        let done = DispatchSemaphore(value: 0)
        var result: Result<URL, Error>?
        writer.finish { r, _ in result = r; done.signal() }
        check(done.wait(timeout: .now() + 10) == .success, "MP4 finalisation completes")
        _ = try result!.get()
        let asset = AVURLAsset(url: movie)
        let track = try await asset.loadTracks(withMediaType: .video).first!
        let size = try await track.load(.naturalSize)
        let duration = try await asset.load(.duration)
        check(size == CGSize(width: 1280, height: 720), "encoded resolution is 1280x720")
        check(abs(duration.seconds - 1) < 0.1, "recording timeline starts at zero and lasts one second")
        let generator = AVAssetImageGenerator(asset: asset)
        let decoded = try await generator.image(at: .zero).image
        let decodedData = decoded.dataProvider!.data! as Data
        // Inspect the decoded CGImage by re-rendering to a known RGBA format.
        let decodedImage = CIImage(cgImage: decoded).transformed(by: CGAffineTransform(scaleX: 0.05, y: 0.05))
        let decodedPixel = pixels(decodedImage)[0]
        check(abs(Int(decodedPixel) - Int(pixels(enhanced)[0])) <= 5, "MP4 decodes to processed colour, not the untouched frame")
        let backgroundIndex = (18 * 64 + 48) * 4 + 2
        check(abs(Int(pixels(decodedImage)[backgroundIndex]) - Int(pixels(backdrop)[backgroundIndex])) <= 5, "MP4 includes the background replacement used in preview")
        check(decodedData.count > 0, "encoded MP4 decodes successfully")
        print("\(checks) focused checks passed. Synthetic MP4: \(movie.path)")
    }
}
