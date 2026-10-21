import Foundation
import CoreImage

struct EnhancementSettings: Codable, Equatable {
    var enabled = true
    var autoLighting = false
    var exposure = 0.18
    var shadows = 0.24
    var highlights = 0.12
    var warmth = 0.0
    var contrast = 1.02
    var saturation = 1.0
    var noise = 0.012
    var sharpness = 0.18
    static var neutral: Self {
        var s = Self()
        s.exposure = 0; s.shadows = 0; s.highlights = 0; s.contrast = 1
        s.noise = 0; s.sharpness = 0
        return s
    }
    static func load() -> Self {
        guard let data = UserDefaults.standard.data(forKey: "enhancement"), let s = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return s
    }
    func save() { UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: "enhancement") }
}

struct LightStatistics {
    let median: Double
    let highlight: Double
    let clippedFraction: Double
}

// Independent of frame rate; step uses sample timestamps, not an animation timer.
struct AutoLighting {
    private(set) var exposure = 0.0
    private(set) var shadows = 0.0
    private var lastTime: Double?
    mutating func reset() { exposure = 0; shadows = 0; lastTime = nil }
    mutating func step(_ stats: LightStatistics, at time: Double) {
        let dt = min(max(time - (lastTime ?? time - 0.25), 0), 0.5)
        lastTime = time
        let desired = log2(0.42 / max(0.06, stats.median)) * 0.72
        // Bright background: use shadows instead of pushing the entire frame into clipping.
        let ceiling = stats.highlight > 0.92 || stats.clippedFraction > 0.02 ? 0.18 : 0.8
        let target = min(ceiling, max(-0.4, desired))
        let targetShadows = min(0.25, max(0, (0.42 - stats.median) * 0.9))
        let alpha = 1 - exp(-dt / (target < exposure ? 1.2 : 1.8))
        exposure += (target - exposure) * alpha
        shadows += (targetShadows - shadows) * alpha
    }
}

final class EnhancementPipeline {
    private let gpu: GPU
    private let exposure = CIFilter(name: "CIExposureAdjust")!
    private let tone = CIFilter(name: "CIHighlightShadowAdjust")!
    private let temperature = CIFilter(name: "CITemperatureAndTint")!
    private let color = CIFilter(name: "CIColorControls")!
    private let toPerceptual = CIFilter(name: "CILinearToSRGBToneCurve")!
    private let toLinear = CIFilter(name: "CISRGBToneCurveToLinear")!
    private let noise = CIFilter(name: "CINoiseReduction")!
    private let sharpen = CIFilter(name: "CISharpenLuminance")!
    private var thumbnail = [UInt8](repeating: 0, count: 64 * 36 * 4)
    private var lastAnalysis = -Double.infinity
    private(set) var lighting = AutoLighting()
    init(gpu: GPU) { self.gpu = gpu }
    func resetLighting() { lighting.reset(); lastAnalysis = -.infinity }
    func process(_ original: CIImage, settings s: EnhancementSettings, at time: Double) -> CIImage {
        guard s.enabled else { resetLighting(); return original }
        if s.autoLighting {
            if time - lastAnalysis >= 0.25 {
                lighting.step(analyse(original), at: time); lastAnalysis = time
            }
        } else { resetLighting() }
        var image = original
        // Denoise before gain/sharpening, with no extra sharpening hidden in the denoiser.
        if s.noise > 0 {
            noise.setValue(image.clampedToExtent(), forKey: kCIInputImageKey)
            noise.setValue(s.noise, forKey: "inputNoiseLevel")
            noise.setValue(0, forKey: "inputSharpness")
            image = noise.outputImage!.cropped(to: original.extent)
        }
        if s.warmth != 0 {
            temperature.setValue(image, forKey: kCIInputImageKey)
            temperature.setValue(CIVector(x: 6500, y: 0), forKey: "inputNeutral")
            temperature.setValue(CIVector(x: 6500 - s.warmth, y: 0), forKey: "inputTargetNeutral")
            image = temperature.outputImage!
        }
        let ev = min(1.5, max(-1.5, s.exposure + lighting.exposure))
        if ev != 0 { exposure.setValue(image, forKey: kCIInputImageKey); exposure.setValue(ev, forKey: "inputEV"); image = exposure.outputImage! }
        let shadows = min(0.65, s.shadows + lighting.shadows)
        if shadows != 0 || s.highlights != 0 {
            tone.setValue(image, forKey: kCIInputImageKey)
            tone.setValue(shadows, forKey: "inputShadowAmount")
            tone.setValue(1 - s.highlights, forKey: "inputHighlightAmount")
            image = tone.outputImage!
        }
        if s.contrast != 1 || s.saturation != 1 {
            // Contrast about 0.5 in linear light crushes dark skin/shadows even at 1.02.
            // Apply colour controls in perceptual light, then return to the linear workspace.
            toPerceptual.setValue(image, forKey: kCIInputImageKey)
            color.setValue(toPerceptual.outputImage!, forKey: kCIInputImageKey)
            color.setValue(s.contrast, forKey: kCIInputContrastKey)
            color.setValue(s.saturation, forKey: kCIInputSaturationKey)
            color.setValue(0, forKey: kCIInputBrightnessKey)
            toLinear.setValue(color.outputImage!, forKey: kCIInputImageKey)
            image = toLinear.outputImage!
        }
        if s.sharpness > 0 {
            sharpen.setValue(image.clampedToExtent(), forKey: kCIInputImageKey)
            sharpen.setValue(s.sharpness, forKey: kCIInputSharpnessKey)
            image = sharpen.outputImage!.cropped(to: original.extent)
        }
        return image.cropped(to: original.extent)
    }
    private func analyse(_ image: CIImage) -> LightStatistics {
        let small = image.transformed(by: CGAffineTransform(scaleX: 64 / image.extent.width, y: 36 / image.extent.height))
        thumbnail.withUnsafeMutableBytes {
            gpu.context.render(small, toBitmap: $0.baseAddress!, rowBytes: 64 * 4, bounds: CGRect(x: 0, y: 0, width: 64, height: 36), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        }
        var center: [Double] = []; var all: [Double] = []; var clipped = 0
        for y in 0..<36 { for x in 0..<64 {
            let i = (y * 64 + x) * 4
            let l = (0.2126 * Double(thumbnail[i]) + 0.7152 * Double(thumbnail[i+1]) + 0.0722 * Double(thumbnail[i+2])) / 255
            all.append(l)
            if l > 0.97 { clipped += 1 }
            if x >= 16 && x < 48 && y >= 5 && y < 30 { center.append(l) }
        } }
        center.sort(); all.sort()
        return LightStatistics(median: center[center.count/2], highlight: all[Int(Double(all.count - 1) * 0.98)], clippedFraction: Double(clipped)/Double(all.count))
    }
}

final class PixelPool {
    private var pool: CVPixelBufferPool?
    private var width = 0; private var height = 0
    func get(width: Int, height: Int) -> CVPixelBuffer? {
        if pool == nil || self.width != width || self.height != height {
            self.width = width; self.height = height
            let attributes: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferMetalCompatibilityKey as String: true, kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
            CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey as String: 4] as CFDictionary, attributes as CFDictionary, &pool)
        }
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        let result = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, [kCVPixelBufferPoolAllocationThresholdKey as String: 8] as CFDictionary, &buffer)
        if let buffer {
            CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey, GPU.videoColorSpace, .shouldPropagate)
        }
        return result == kCVReturnSuccess ? buffer : nil
    }
}
