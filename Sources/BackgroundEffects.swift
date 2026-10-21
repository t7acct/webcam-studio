import Foundation
import CoreImage
import Vision
import ImageIO

enum BackgroundMode: String, Codable, CaseIterable, Identifiable {
    case off, blur, colour, photo
    var id: String { rawValue }
    var label: String {
        switch self { case .off: return "Off"; case .blur: return "Blur"; case .colour: return "Solid colour"; case .photo: return "Photo" }
    }
}

struct BackgroundSettings: Codable, Equatable {
    var mode: BackgroundMode = .off
    var blurAmount = 0.6
    var red = 0.12
    var green = 0.15
    var blue = 0.20
    var photoPath: String?
    var photoName: String?
    static func load() -> Self {
        guard let data = UserDefaults.standard.data(forKey: "background"), let s = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return s
    }
    func save() { UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: "background") }
}

// Vision runs on its own queue. There is at most one pending segmentation job,
// so cold model startup and slow inference cannot block microphone capture or
// build a queue of old video frames. Preview/encoder share the resulting pixels.
final class BackgroundProcessor {
    private let gpu: GPU
    private let worker = DispatchQueue(label: "uk.tamim.webcam.person-mask", qos: .userInitiated)
    private let lock = NSLock()
    private var generation = 0
    private var active = false
    private var busy = false
    private var mask: CIImage?
    private var maskTime = -Double.infinity
    private var photo: CIImage?
    private var photoError: String?
    private var segmentationError: String?
    private var lastInferenceMS = 0.0
    private var lastMode: BackgroundMode = .off
    private var selectedPhotoPath: String?
    // Only the worker accesses these properties.
    private var request: VNGeneratePersonSegmentationRequest?
    private var requestGeneration = -1
    private var loadedPhotoPath: String?
    private var loadedPhoto: CIImage?
    private var loadedPhotoError: String?
    private var attemptedPhotoLoad = false
    private let maskCleaner = PersonMaskCleaner()

    init(gpu: GPU) { self.gpu = gpu }
    func reset() {
        lock.lock(); generation += 1; mask = nil; maskTime = -.infinity
        segmentationError = nil; lock.unlock()
    }
    func configure(_ settings: BackgroundSettings) {
        lock.lock(); defer { lock.unlock() }
        let enabled = settings.mode != .off
        if enabled != active {
            generation += 1; mask = nil; maskTime = -.infinity; segmentationError = nil
        }
        active = enabled; lastMode = settings.mode
        if selectedPhotoPath != settings.photoPath { photo = nil; photoError = nil; selectedPhotoPath = settings.photoPath }
    }
    // Called on the serial capture/media queue. An old/missing mask never reveals
    // an untreated room: the whole frame gets the selected background treatment.
    func apply(to image: CIImage, source: CIImage, at time: Double, settings: BackgroundSettings) -> CIImage {
        guard settings.mode != .off else { return image }
        submit(source, at: time, settings: settings)
        lock.lock()
        let fresh = time >= maskTime && time - maskTime <= 0.18
        let currentMask = fresh ? mask : nil
        let currentPhoto = photo
        lock.unlock()
        let background = Self.backdrop(for: image, settings: settings, photo: currentPhoto)
        guard let currentMask else { return background }
        let fittedMask = Self.fittedMask(currentMask, to: image.extent)
        return Self.composite(foreground: image, background: background, mask: fittedMask)
    }
    private func submit(_ source: CIImage, at time: Double, settings: BackgroundSettings) {
        lock.lock()
        guard active, !busy else { lock.unlock(); return }
        busy = true
        let token = generation
        lock.unlock()
        worker.async {
            autoreleasepool {
                var result: CIImage?
                var failure: String?
                let started = ProcessInfo.processInfo.systemUptime
                do {
                    if self.request == nil || self.requestGeneration != token {
                        let request = VNGeneratePersonSegmentationRequest()
                        request.qualityLevel = .balanced
                        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
                        self.request = request; self.requestGeneration = token
                    }
                    // Keep Vision's input bounded independently of capture resolution.
                    let scale = min(1, 512 / max(source.extent.width, source.extent.height))
                    let small = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                    try VNImageRequestHandler(ciImage: small, orientation: .up, options: [:]).perform([self.request!])
                    guard let buffer = self.request?.results?.first?.pixelBuffer else { throw StudioError("No person mask returned.") }
                    guard let cleaned = self.maskCleaner.clean(buffer) else { throw StudioError("Could not prepare the person mask.") }
                    result = cleaned
                } catch { failure = error.localizedDescription }
                if settings.mode == .photo { self.loadPhoto(settings.photoPath) }
                self.lock.lock()
                if self.generation == token && self.active {
                    self.mask = result; self.maskTime = time; self.segmentationError = failure
                    self.lastInferenceMS = (ProcessInfo.processInfo.systemUptime - started) * 1000
                    if self.selectedPhotoPath == settings.photoPath {
                        self.photo = self.loadedPhoto; self.photoError = self.loadedPhotoError
                    }
                }
                self.busy = false
                self.lock.unlock()
            }
        }
    }
    private func loadPhoto(_ path: String?) {
        guard loadedPhotoPath != path || !attemptedPhotoLoad else { return }
        attemptedPhotoLoad = true
        loadedPhotoPath = path; loadedPhoto = nil
        guard let path else { loadedPhotoError = "Choose a photo; using solid colour until then."; return }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 2560,
            kCGImageSourceShouldCacheImmediately: true]
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            loadedPhotoError = "Photo unavailable — using solid colour. Choose another photo."; return
        }
        loadedPhoto = CIImage(cgImage: cgImage); loadedPhotoError = nil
    }
    var status: String {
        lock.lock(); defer { lock.unlock() }
        guard active else { return "Background effects are off." }
        if let segmentationError { return "Person effect unavailable — covering the whole frame. \(segmentationError)" }
        if lastMode == .photo, let photoError { return photoError }
        if mask == nil { return "Preparing person cutout…" }
        return "Applied to preview and recording."
    }
    var inferenceMS: Double { lock.lock(); defer { lock.unlock() }; return lastInferenceMS }
    // Wait only on shutdown or in offline verification, never from the UI/media queue.
    func waitUntilIdle() { worker.sync {} }

    static func fittedMask(_ mask: CIImage, to extent: CGRect) -> CIImage {
        // A very small expansion/feather protects hair edges without a hard outline.
        let softened = mask.clampedToExtent()
            .applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: 0.7])
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 0.55])
            .cropped(to: mask.extent)
        return softened.transformed(by: CGAffineTransform(scaleX: extent.width / mask.extent.width, y: extent.height / mask.extent.height))
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY)).cropped(to: extent)
    }
    static func backdrop(for image: CIImage, settings: BackgroundSettings, photo: CIImage?) -> CIImage {
        switch settings.mode {
        case .off: return image
        case .blur:
            let radius = (8 + min(1, max(0, settings.blurAmount)) * 46) * image.extent.width / 1280
            return image.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius]).cropped(to: image.extent)
        case .photo:
            if let photo {
                let scale = max(image.extent.width / photo.extent.width, image.extent.height / photo.extent.height)
                let sized = photo.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                return sized.transformed(by: CGAffineTransform(translationX: image.extent.midX - sized.extent.midX, y: image.extent.midY - sized.extent.midY)).cropped(to: image.extent)
            }
            fallthrough
        case .colour:
            return CIImage(color: CIColor(red: settings.red, green: settings.green, blue: settings.blue)).cropped(to: image.extent)
        }
    }
    static func composite(foreground: CIImage, background: CIImage, mask: CIImage) -> CIImage {
        foreground.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: background, kCIInputMaskImageKey: mask]).cropped(to: foreground.extent)
    }
}

// Keep the main presenter, suppressing low-confidence background traces and
// isolated objects. This touches only Vision's small mask, never camera pixels.
final class PersonMaskCleaner {
    private var labels: [Int32] = []
    private var frontier: [Int] = []
    private var pool: CVPixelBufferPool?
    private var size = (0, 0)

    func clean(_ buffer: CVPixelBuffer) -> CIImage? {
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent8 else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bytes = base.assumingMemoryBound(to: UInt8.self), stride = CVPixelBufferGetBytesPerRow(buffer)
        let count = w * h
        if labels.count != count { labels = [Int32](repeating: 0, count: count); frontier.reserveCapacity(count) }
        labels.withUnsafeMutableBytes { _ = $0.initializeMemory(as: UInt8.self, repeating: 0) }
        var label: Int32 = 0, largestLabel: Int32 = 0, largestCount = 0
        for y in 0..<h { for x in 0..<w {
            let index = y * w + x
            guard labels[index] == 0, bytes[y * stride + x] >= 128 else { continue }
            label += 1; frontier.removeAll(keepingCapacity: true)
            frontier.append(index); labels[index] = label
            var head = 0
            while head < frontier.count {
                let current = frontier[head]; head += 1
                let cy = current / w, cx = current - cy * w
                if cx > 0 { visit(current - 1, x: cx - 1, y: cy, label: label, bytes: bytes, stride: stride) }
                if cx + 1 < w { visit(current + 1, x: cx + 1, y: cy, label: label, bytes: bytes, stride: stride) }
                if cy > 0 { visit(current - w, x: cx, y: cy - 1, label: label, bytes: bytes, stride: stride) }
                if cy + 1 < h { visit(current + w, x: cx, y: cy + 1, label: label, bytes: bytes, stride: stride) }
            }
            if frontier.count > largestCount { largestCount = frontier.count; largestLabel = label }
        } }
        let extent = CGRect(x: 0, y: 0, width: w, height: h)
        if largestCount == 0 { return CIImage(color: .black).cropped(to: extent) }
        if pool == nil || size != (w, h) {
            size = (w, h)
            CVPixelBufferPoolCreate(nil, nil, [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_OneComponent8,
                kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:], kCVPixelBufferMetalCompatibilityKey as String: true] as CFDictionary, &pool)
        }
        guard let pool else { return nil }
        var output: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, [kCVPixelBufferPoolAllocationThresholdKey as String: 6] as CFDictionary, &output) == kCVReturnSuccess, let output else { return nil }
        CVPixelBufferLockBaseAddress(output, [])
        let outputStride = CVPixelBufferGetBytesPerRow(output)
        let destination = CVPixelBufferGetBaseAddress(output)!.assumingMemoryBound(to: UInt8.self)
        destination.initialize(repeating: 0, count: outputStride * h)
        for y in 0..<h { for x in 0..<w where labels[y * w + x] == largestLabel { destination[y * outputStride + x] = 255 } }
        CVPixelBufferUnlockBaseAddress(output, [])
        let gate = CIImage(cvPixelBuffer: output, options: [.colorSpace: NSNull()]).clampedToExtent()
            .applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: 1.5])
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 0.5]).cropped(to: extent)
        let refined = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: NSNull()])
            .applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: 1.25, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 1.25, z: 0, w: 0), "inputBVector": CIVector(x: 0, y: 0, z: 1.25, w: 0),
                "inputBiasVector": CIVector(x: -0.125, y: -0.125, z: -0.125, w: 0)])
            .applyingFilter("CIColorClamp", parameters: ["inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0), "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)])
        return refined.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: gate]).cropped(to: extent)
    }
    @inline(__always) private func visit(_ index: Int, x: Int, y: Int, label: Int32, bytes: UnsafePointer<UInt8>, stride: Int) {
        guard labels[index] == 0, bytes[y * stride + x] >= 128 else { return }
        labels[index] = label; frontier.append(index)
    }
}
