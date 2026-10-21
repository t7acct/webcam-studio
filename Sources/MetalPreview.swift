import SwiftUI
import MetalKit
import CoreImage

final class FrameStore {
    private let lock = NSLock()
    private var original: CIImage?
    private var enhanced: CIImage?
    private var mode = "Enhanced"
    private var mirror = false
    func set(_ image: CIImage?, enhanced: CIImage? = nil) { lock.lock(); original = image; self.enhanced = enhanced ?? image; lock.unlock() }
    func configure(mode: String, mirror: Bool) { lock.lock(); self.mode = mode; self.mirror = mirror; lock.unlock() }
    func get() -> CIImage? {
        lock.lock(); defer { lock.unlock() }
        guard let original, let enhanced else { return nil }
        var image = mode == "Original" ? original : enhanced
        if mode == "Compare" {
            let e = original.extent
            image = original.cropped(to: CGRect(x: 0, y: 0, width: e.width / 2, height: e.height)).composited(over: enhanced)
            let line = CIImage(color: CIColor.white).cropped(to: CGRect(x: e.width/2 - 1, y: 0, width: 2, height: e.height))
            image = line.composited(over: image)
        }
        if mirror { image = image.transformed(by: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: image.extent.width, ty: 0)) }
        return image
    }
}

final class GPU {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let context: CIContext
    // Match AVFoundation/QuickTime's SDR decoding transfer curve end to end.
    static let videoColorSpace = CGColorSpace(name: CGColorSpace.coreMedia709)!
    let colorSpace = GPU.videoColorSpace
    init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        self.device = device; self.queue = queue
        context = CIContext(mtlDevice: device, options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!, .cacheIntermediates: false])
    }
}

struct MetalPreview: NSViewRepresentable {
    let frames: FrameStore
    let gpu: GPU
    func makeCoordinator() -> Renderer { Renderer(frames: frames, gpu: gpu) }
    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: gpu.device)
        view.framebufferOnly = false
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColorMake(0.025, 0.025, 0.03, 1)
        view.preferredFramesPerSecond = 30
        (view.layer as? CAMetalLayer)?.colorspace = gpu.colorSpace
        view.delegate = context.coordinator
        return view
    }
    func updateNSView(_ nsView: MTKView, context: Context) {}
    final class Renderer: NSObject, MTKViewDelegate {
        let frames: FrameStore; let gpu: GPU
        // Three in-flight frames at most; never accumulate GPU work if preview is slow.
        let inFlight = DispatchSemaphore(value: 3)
        init(frames: FrameStore, gpu: GPU) { self.frames = frames; self.gpu = gpu }
        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
        func draw(in view: MTKView) {
            guard inFlight.wait(timeout: .now()) == .success else { return }
            guard let drawable = view.currentDrawable, let command = gpu.queue.makeCommandBuffer() else { inFlight.signal(); return }
            let bounds = CGRect(origin: .zero, size: view.drawableSize)
            var canvas = CIImage(color: CIColor(red: 0.025, green: 0.025, blue: 0.03)).cropped(to: bounds)
            if let image = frames.get() {
                let scale = min(bounds.width / image.extent.width, bounds.height / image.extent.height)
                let fit = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                    .transformed(by: CGAffineTransform(translationX: (bounds.width - image.extent.width * scale)/2, y: (bounds.height - image.extent.height * scale)/2))
                canvas = fit.composited(over: canvas)
            }
            gpu.context.render(canvas, to: drawable.texture, commandBuffer: command, bounds: bounds, colorSpace: gpu.colorSpace)
            command.present(drawable)
            command.addCompletedHandler { [inFlight] _ in inFlight.signal() }
            command.commit()
        }
    }
}
