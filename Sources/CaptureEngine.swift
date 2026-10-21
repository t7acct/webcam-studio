import Foundation
import AVFoundation
import CoreImage
import Combine
import AppKit
import UniformTypeIdentifiers
import ImageIO

struct DeviceChoice: Identifiable { let id: String; let name: String }
struct CaptureMode: Identifiable {
    let width: Int32; let height: Int32; let fps: Double
    var id: String { "\(width)x\(height)" }
    var label: String { "\(height)p · \(String(format: "%.0f", fps)) fps" }
}

final class CaptureEngine: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    @Published var cameras: [DeviceChoice] = []
    @Published var microphones: [DeviceChoice] = []
    @Published var modes: [CaptureMode] = []
    @Published var cameraID = ""
    @Published var microphoneID = ""
    @Published var modeID = "1280x720"
    @Published var status = "Requesting camera access…"
    @Published var audioStatus = ""
    @Published var running = false
    @Published var configuring = false
    @Published var micLevel = 0.0
    @Published var settings = EnhancementSettings.load()
    @Published var backgroundSettings = BackgroundSettings.load()
    @Published var backgroundStatus = "Background effects are off."
    @Published var previewMode = "Enhanced"
    @Published var mirroredPreview = false
    @Published var lightStatus = ""
    @Published var diagnostics = "Waiting for camera frames."
    @Published var errorMessage: String?
    @Published var recording = false
    @Published var finalizing = false
    @Published var elapsed = 0.0
    @Published var savedURL: URL?
    let frames = FrameStore()
    let gpu: GPU
    let session = AVCaptureSession()
    let queue = DispatchQueue(label: "uk.tamim.webcam.media", qos: .userInitiated)
    let sessionQueue = DispatchQueue(label: "uk.tamim.webcam.session", qos: .userInitiated)
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let pipeline: EnhancementPipeline
    private let background: BackgroundProcessor
    private let pool = PixelPool()
    private var mediaSettings: EnhancementSettings
    private var mediaBackground = BackgroundSettings.load()
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?
    private var started = false
    private var count = 0; private var dropped = 0; private var poolDrops = 0
    private var lastReport = 0.0; private var lastFrame = 0.0; private var processingMS = 0.0
    private var dimensions = (width: 0, height: 0)
    private var audioAllowed = false
    private var acceptingFrames = false
    private var recorder: MovieRecorder?
    private var audioConnected = false
    private var audioIsConnected = false
    private var finishWaiters: [() -> Void] = []
    private var lastRecordingReport = 0.0
    private var qaDestination: URL?
    private var qaDuration = 0.0
    private var qaStarted = false
    private var qaLog: URL?
    private var qaRepeat = false
    private var permissionsReady = false
    private var receivedAudio = false
    private var qaSnapshots = false
    private var qaMicrophone: String?
    private var recordingDetails = ""

    override init() {
        guard let gpu = GPU() else { fatalError("Webcam Studio requires a Metal-capable Mac.") }
        self.gpu = gpu; self.pipeline = EnhancementPipeline(gpu: gpu); self.background = BackgroundProcessor(gpu: gpu)
        mediaSettings = EnhancementSettings.load()
        super.init()
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "--verify-recording"), i + 1 < args.count {
            qaDestination = URL(fileURLWithPath: args[i+1])
            if let j = args.firstIndex(of: "--duration"), j + 1 < args.count { qaDuration = Double(args[j+1]) ?? 10 }
            else { qaDuration = 10 }
        }
        if let i = args.firstIndex(of: "--qa-log"), i + 1 < args.count { qaLog = URL(fileURLWithPath: args[i+1]) }
        if args.contains("--qa-auto-lighting") { settings.autoLighting = true; mediaSettings.autoLighting = true }
        if let i = args.firstIndex(of: "--qa-background"), i + 1 < args.count, let mode = BackgroundMode(rawValue: args[i+1]) {
            backgroundSettings.mode = mode; mediaBackground = backgroundSettings
        }
        background.configure(mediaBackground)
        qaRepeat = args.contains("--qa-repeat")
        qaSnapshots = args.contains("--qa-snapshots")
        if args.contains("--qa-mic-ugreen") { qaMicrophone = "ugreen" }
        if args.contains("--qa-1080p") { modeID = "1920x1080" }
        else if args.contains("--qa-720p") { modeID = "1280x720" }
        else { modeID = UserDefaults.standard.string(forKey: "modeID") ?? "1280x720" }
    }
    static func cameraDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera], mediaType: .video, position: .unspecified).devices
    }
    static func microphoneDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
    }
    static func supportedModes(_ device: AVCaptureDevice) -> [CaptureMode] {
        [(Int32(1280), Int32(720)), (1920, 1080)].compactMap { w, h in
            let rates = device.formats.filter { let d = CMVideoFormatDescriptionGetDimensions($0.formatDescription); return d.width == w && d.height == h }
                .flatMap { $0.videoSupportedFrameRateRanges }.map { min(30.00003, $0.maxFrameRate) }
            guard let fps = rates.filter({ $0 >= 24 }).max() else { return nil }
            return CaptureMode(width: w, height: h, fps: fps)
        }
    }
    static func frameDuration(in range: AVFrameRateRange, targetFPS: Double) -> CMTime {
        let fps = min(range.maxFrameRate, max(range.minFrameRate, targetFPS))
        // Use the advertised rational value at either endpoint. Rounding 1/30 to
        // nanoseconds can exceed a device's strict maximum and raise an Obj-C exception.
        if fps >= range.maxFrameRate - 0.0001 { return range.minFrameDuration }
        if fps <= range.minFrameRate + 0.0001 { return range.maxFrameDuration }
        return CMTime(seconds: 1/fps, preferredTimescale: 1_000_000_000)
    }
    func start() {
        guard !started else { return }; started = true
        observeDevices()
        AVCaptureDevice.requestAccess(for: .video) { allowed in
            DispatchQueue.main.async {
                guard allowed else { self.status = "Camera access is off. Open System Settings → Privacy & Security → Camera, enable Webcam Studio, then relaunch."; return }
                self.refreshDevices()
                self.configure()
                AVCaptureDevice.requestAccess(for: .audio) { audio in
                    DispatchQueue.main.async {
                        self.audioAllowed = audio
                        self.queue.async { self.permissionsReady = true }
                        self.refreshDevices()
                        self.configure()
                    }
                }
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.watchdog() }
    }
    func refreshDevices() {
        let devices = Self.cameraDevices()
        cameras = devices.map { DeviceChoice(id: $0.uniqueID, name: $0.localizedName) }
        let saved = UserDefaults.standard.string(forKey: "cameraID") ?? ""
        if !devices.contains(where: { $0.uniqueID == cameraID }) {
            cameraID = devices.first(where: { $0.uniqueID == saved })?.uniqueID
                ?? devices.first(where: { $0.localizedName.localizedCaseInsensitiveContains("ugreen") })?.uniqueID
                ?? devices.first?.uniqueID ?? ""
        }
        let mics = Self.microphoneDevices()
        microphones = mics.map { DeviceChoice(id: $0.uniqueID, name: $0.localizedName) }
        if audioAllowed && !mics.contains(where: { $0.uniqueID == microphoneID }) {
            let savedMic = UserDefaults.standard.string(forKey: "microphoneID")
            microphoneID = savedMic == "" ? "" : (mics.first(where: { $0.uniqueID == savedMic })?.uniqueID
                ?? mics.first(where: { $0.localizedName.contains("MacBook") })?.uniqueID ?? mics.first?.uniqueID ?? "")
        }
        if !audioAllowed { microphoneID = "" }
        if audioAllowed, let name = qaMicrophone { microphoneID = mics.first(where: { $0.localizedName.localizedCaseInsensitiveContains(name) })?.uniqueID ?? microphoneID }
        updateModes()
    }
    func updateModes() {
        modes = AVCaptureDevice(uniqueID: cameraID).map(Self.supportedModes) ?? []
        if !modes.contains(where: { $0.id == modeID }) { modeID = modes.first?.id ?? "" }
    }
    func cameraChanged() { updateModes(); configure() }
    func configure() {
        guard !recording && !finalizing else { return }
        let id = cameraID, mic = microphoneID, mode = modes.first { $0.id == modeID }
        configuring = true; running = false; frames.set(nil)
        status = "Connecting camera…"; micLevel = 0
        UserDefaults.standard.set(id, forKey: "cameraID")
        if audioAllowed { UserDefaults.standard.set(mic, forKey: "microphoneID") }
        UserDefaults.standard.set(modeID, forKey: "modeID")
        audioStatus = mic.isEmpty ? (audioAllowed ? "No microphone selected — recordings will be silent." : "Microphone access is off. Enable it in Privacy & Security → Microphone, then relaunch.") : ""
        sessionQueue.async {
            self.session.stopRunning()
            self.queue.sync { self.acceptingFrames = false; self.lastFrame = 0; self.pipeline.resetLighting(); self.background.reset(); self.count = 0; self.lastReport = 0; self.audioConnected = false; self.receivedAudio = false }
            self.session.beginConfiguration()
            self.session.inputs.forEach(self.session.removeInput)
            self.session.outputs.forEach(self.session.removeOutput)
            do {
                guard let device = AVCaptureDevice(uniqueID: id) else { throw StudioError("No camera connected. Connect your USB webcam and click Reconnect.") }
                guard let mode else { throw StudioError("This camera has no supported 720p or 1080p mode at 24–30 fps. Choose another camera.") }
                let input = try AVCaptureDeviceInput(device: device)
                guard self.session.canAddInput(input) else { throw StudioError("Camera unavailable. Close other apps using it, then click Reconnect.") }
                self.session.addInput(input)
                let preset: AVCaptureSession.Preset = mode.height == 1080 ? .hd1920x1080 : .hd1280x720
                if self.session.canSetSessionPreset(preset) { self.session.sessionPreset = preset }
                self.videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: Int(mode.width), kCVPixelBufferHeightKey as String: Int(mode.height)]
                self.videoOutput.alwaysDiscardsLateVideoFrames = true
                self.videoOutput.setSampleBufferDelegate(self, queue: self.queue)
                guard self.session.canAddOutput(self.videoOutput) else { throw StudioError("Could not attach the camera output.") }
                self.session.addOutput(self.videoOutput)
                let matching = device.formats.filter {
                    let d = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
                    return d.width == mode.width && d.height == mode.height && $0.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= mode.fps - 0.01 && $0.minFrameRate <= mode.fps + 0.01 }
                }
                guard let format = matching.first else { throw StudioError("The camera's supported formats changed. Click Reconnect.") }
                try device.lockForConfiguration()
                device.activeFormat = format
                let range = format.videoSupportedFrameRateRanges.first { $0.maxFrameRate >= mode.fps - 0.01 && $0.minFrameRate <= mode.fps + 0.01 }!
                let duration = Self.frameDuration(in: range, targetFPS: mode.fps)
                device.activeVideoMinFrameDuration = duration; device.activeVideoMaxFrameDuration = duration
                device.unlockForConfiguration()
                if let c = self.videoOutput.connection(with: .video), c.isVideoMirroringSupported {
                    c.automaticallyAdjustsVideoMirroring = false; c.isVideoMirrored = false
                }
                if !mic.isEmpty, let microphone = AVCaptureDevice(uniqueID: mic) {
                    do {
                        let audio = try AVCaptureDeviceInput(device: microphone)
                        guard self.session.canAddInput(audio) else { throw StudioError("Selected microphone is unavailable.") }
                        self.session.addInput(audio)
                        self.audioOutput.setSampleBufferDelegate(self, queue: self.queue)
                        guard self.session.canAddOutput(self.audioOutput) else { throw StudioError("Microphone output is unavailable.") }
                        self.session.addOutput(self.audioOutput)
                        self.queue.sync { self.audioConnected = true }
                    } catch { DispatchQueue.main.async { self.audioStatus = "\(error.localizedDescription) Recording is disabled until you choose an available microphone or explicitly select No microphone." } }
                }
                self.session.commitConfiguration()
                self.queue.sync { self.acceptingFrames = true }
                self.session.startRunning()
                let hasAudio = self.queue.sync { self.audioConnected }
                DispatchQueue.main.async { self.configuring = false; self.audioIsConnected = hasAudio; self.status = "Waiting for camera frames…" }
            } catch {
                self.session.commitConfiguration()
                DispatchQueue.main.async { self.configuring = false; self.running = false; self.status = error.localizedDescription }
            }
        }
    }
    func updateSettings() {
        settings.save(); let value = settings
        queue.async { self.mediaSettings = value }
    }
    func updateBackgroundSettings() {
        backgroundSettings.save(); let value = backgroundSettings
        queue.async { self.mediaBackground = value; self.background.configure(value) }
    }
    func chooseBackgroundPhoto() {
        let panel = NSOpenPanel()
        panel.title = "Choose a background photo"
        panel.allowedContentTypes = [.image]
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let sourceURL = panel.url else { return }
            self.sessionQueue.async {
                do {
                    guard let imageSource = CGImageSourceCreateWithURL(sourceURL as CFURL, nil), CGImageSourceGetCount(imageSource) > 0 else { throw StudioError("That file could not be opened as a photo. Choose a PNG, JPEG or HEIC image.") }
                    let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                        .appendingPathComponent("uk.tamim.webcam-studio/Backgrounds", isDirectory: true)
                    try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
                    let destination = support.appendingPathComponent(UUID().uuidString).appendingPathExtension(sourceURL.pathExtension)
                    try FileManager.default.copyItem(at: sourceURL, to: destination)
                    DispatchQueue.main.async {
                        self.backgroundSettings.photoPath = destination.path
                        self.backgroundSettings.photoName = sourceURL.lastPathComponent
                        self.backgroundSettings.mode = .photo
                    }
                } catch { DispatchQueue.main.async { self.errorMessage = error.localizedDescription } }
            }
        }
    }
    func updatePreview() { frames.configure(mode: previewMode, mirror: mirroredPreview) }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        autoreleasepool {
            guard acceptingFrames else { return }
            if output === audioOutput {
                receivedAudio = true
                let level = connection.audioChannels.map { Double($0.averagePowerLevel) }.max() ?? -80
                // Display a useful decibel range; raw amplitude makes normal speech
                // barely visible on a linear progress bar.
                let value = (level + 60) / 60
                if ProcessInfo.processInfo.systemUptime - lastAudioReport > 0.1 {
                    lastAudioReport = ProcessInfo.processInfo.systemUptime
                    DispatchQueue.main.async { self.micLevel = min(1, max(0, value)) }
                }
                recorder?.appendAudio(sampleBuffer)
                return
            }
            guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            let now = ProcessInfo.processInfo.systemUptime
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            lastFrame = now
            let original = CIImage(cvPixelBuffer: buffer)
            let lit = pipeline.process(original, settings: mediaSettings, at: pts.seconds)
            let enhanced = background.apply(to: lit, source: original, at: pts.seconds, settings: mediaBackground)
            let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
            guard let processed = pool.get(width: w, height: h) else { poolDrops += 1; return }
            gpu.context.render(enhanced, to: processed, bounds: original.extent, colorSpace: gpu.colorSpace)
            frames.set(original, enhanced: CIImage(cvPixelBuffer: processed, options: [.colorSpace: gpu.colorSpace]))
            if let recorder {
                recorder.appendVideo(processed, at: pts, duration: CMSampleBufferGetDuration(sampleBuffer))
                if let error = recorder.failure { DispatchQueue.main.async { self.stopRecording(reason: error.localizedDescription) } }
                if now - lastRecordingReport >= 0.25 {
                    lastRecordingReport = now
                    let duration = recorder.elapsed
                    DispatchQueue.main.async { self.elapsed = duration }
                }
                if qaDuration > 0 && recorder.elapsed >= qaDuration {
                    qaDuration = 0
                    DispatchQueue.main.async { self.stopRecording() }
                }
            }
            dimensions = (w, h)
            processingMS += (ProcessInfo.processInfo.systemUptime - now) * 1000
            count += 1
            if now - lastReport >= 1 {
                let fps = lastReport == 0 ? 0 : Double(count) / (now-lastReport)
                let cost = processingMS / Double(count)
                let text = "\(w) × \(h) · \(String(format: "%.1f", fps)) fps"
                let light = "Auto: \(String(format: "%+.2f", pipeline.lighting.exposure)) EV · +\(String(format: "%.2f", pipeline.lighting.shadows)) shadows"
                let effectStatus = background.status
                let details = "Delivered \(text)\nProcessing \(String(format: "%.1f", cost)) ms/frame · late frames \(dropped) · pool drops \(poolDrops)\nBackground: \(mediaBackground.mode.label) · last mask work \(String(format: "%.1f", background.inferenceMS)) ms (separate queue)\nSDR Rec.709 · BGRA → H.264 · unmirrored recording"
                DispatchQueue.main.async { self.status = text; self.running = true; self.lightStatus = light; self.backgroundStatus = effectStatus; self.diagnostics = details + self.recordingDetails }
                if let log = qaLog {
                    let entry: [String: Any] = ["uptime": now, "width": w, "height": h, "fps": fps, "processingMS": cost, "captureDrops": dropped, "poolDrops": poolDrops, "recording": recorder != nil, "recordedSeconds": recorder?.elapsed ?? 0, "writerVideoDrops": recorder?.videoDrops ?? 0, "writerAudioDrops": recorder?.audioDrops ?? 0, "autoEV": pipeline.lighting.exposure, "backgroundMode": mediaBackground.mode.rawValue, "maskWorkMS": background.inferenceMS]
                    if let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) {
                        if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil) }
                        if let handle = try? FileHandle(forWritingTo: log) { _ = try? handle.seekToEnd(); try? handle.write(contentsOf: data + Data([10])); try? handle.close() }
                    }
                }
                if !qaStarted, let url = qaDestination, fps > 15, permissionsReady, audioConnected, receivedAudio {
                    qaStarted = true
                    if qaSnapshots {
                        let folder = url.deletingLastPathComponent()
                        try? gpu.context.writePNGRepresentation(of: original, to: folder.appendingPathComponent("qa-original.png"), format: .RGBA8, colorSpace: gpu.colorSpace)
                        try? gpu.context.writePNGRepresentation(of: CIImage(cvPixelBuffer: processed, options: [.colorSpace: gpu.colorSpace]), to: folder.appendingPathComponent("qa-enhanced.png"), format: .RGBA8, colorSpace: gpu.colorSpace)
                    }
                    DispatchQueue.main.async { self.beginRecording(at: url) }
                }
                count = 0; processingMS = 0; lastReport = now
            }
        }
    }
    private var lastAudioReport = 0.0
    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) { dropped += 1 }
    private func observeDevices() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, let device = note.object as? AVCaptureDevice else { return }
            if device.uniqueID == self.cameraID || device.uniqueID == self.microphoneID {
                self.running = false; self.status = "\(device.localizedName) disconnected. Reconnect the device, then click Reconnect."; self.frames.set(nil)
                self.stopRecording(reason: "\(device.localizedName) disconnected. The recording was stopped.")
                self.sessionQueue.async { self.session.stopRunning() }
            }
        })
        observers.append(center.addObserver(forName: AVCaptureDevice.wasConnectedNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, !self.recording else { return }; self.refreshDevices()
        })
        for name in [AVCaptureSession.runtimeErrorNotification, AVCaptureSession.wasInterruptedNotification] {
            observers.append(center.addObserver(forName: name, object: session, queue: .main) { [weak self] note in
                guard let self else { return }
                let error = note.userInfo?[AVCaptureSessionErrorKey] as? Error
                self.running = false; self.status = error?.localizedDescription ?? "Capture interrupted. Close competing camera apps and click Reconnect."; self.frames.set(nil)
                self.stopRecording(reason: self.status)
            })
        }
    }
    private func watchdog() {
        queue.async {
            if let recorder = self.recorder, let bytes = MovieRecorder.availableBytes(at: recorder.destination), bytes < 50_000_000 {
                DispatchQueue.main.async { self.stopRecording(reason: "Storage is almost full. Recording stopped to finalise your clip.") }
            }
            guard self.acceptingFrames, self.lastFrame > 0, ProcessInfo.processInfo.systemUptime - self.lastFrame > 3 else { return }
            DispatchQueue.main.async { self.running = false; self.status = "No camera frames for 3 seconds. Check the USB cable or close competing camera apps, then Reconnect."; self.frames.set(nil); self.stopRecording(reason: "The camera stopped delivering frames.") }
        }
    }
    func chooseRecording() {
        guard running, !recording, !finalizing, !configuring else { return }
        let panel = NSSavePanel()
        panel.title = "Save camera recording"
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.canCreateDirectories = true
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        panel.nameFieldStringValue = "Presentation_\(formatter.string(from: Date())).mp4"
        if let saved = UserDefaults.standard.string(forKey: "saveDirectory") { panel.directoryURL = URL(fileURLWithPath: saved) }
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            self.beginRecording(at: url)
        }
    }
    func beginRecording(at url: URL) {
        guard running, !recording, !finalizing, !configuring else { return }
        if !microphoneID.isEmpty && !audioIsConnected { errorMessage = "Selected microphone is unavailable. Choose another microphone, or explicitly select No microphone to record a silent clip."; return }
        finalizing = true; savedURL = nil
        queue.async {
            do {
                guard self.acceptingFrames, self.dimensions.width > 0 else { throw StudioError("The camera is not ready.") }
                self.recorder = try MovieRecorder(destination: url, width: self.dimensions.width, height: self.dimensions.height, withAudio: self.audioConnected)
                DispatchQueue.main.async {
                    self.finalizing = false; self.recording = true; self.elapsed = 0
                    UserDefaults.standard.set(url.deletingLastPathComponent().path, forKey: "saveDirectory")
                    if !self.finishWaiters.isEmpty { self.stopRecording() }
                }
            } catch { DispatchQueue.main.async { self.finishRecording(.failure(error), details: "", reason: nil) } }
        }
    }
    func stopRecording(reason: String? = nil, completion: (() -> Void)? = nil) {
        if let completion { finishWaiters.append(completion) }
        guard recording, !finalizing else {
            if !finalizing { let callbacks = finishWaiters; finishWaiters = []; callbacks.forEach { $0() } }
            return
        }
        recording = false; finalizing = true
        queue.async {
            guard let recorder = self.recorder else {
                DispatchQueue.main.async { self.finishRecording(.failure(StudioError("No active recording.")), details: "", reason: reason) }; return
            }
            self.recorder = nil
            recorder.finish { result, details in DispatchQueue.main.async { self.finishRecording(result, details: details, reason: reason) } }
        }
    }
    private func finishRecording(_ result: Result<URL, Error>, details: String, reason: String?) {
        finalizing = false; recordingDetails = "\nLast recording: \(details)"; diagnostics += recordingDetails
        switch result {
        case .success(let url):
            savedURL = url
            if qaRepeat {
                qaRepeat = false
                let next = url.deletingLastPathComponent().appendingPathComponent(url.deletingPathExtension().lastPathComponent + "_take2.mp4")
                queue.async { self.qaDuration = 6 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { if self.finishWaiters.isEmpty { self.beginRecording(at: next) } }
            } else if ProcessInfo.processInfo.arguments.contains("--qa-quit") { NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0) }
            if details.contains("silent") { errorMessage = "The clip saved, but no microphone samples arrived. Check your microphone selection before recording again." }
            else if let reason { errorMessage = "\(reason) Your clip has been finalised and saved." }
        case .failure(let error): errorMessage = "\(error.localizedDescription) Any partial data is preserved in the save folder."
        }
        let callbacks = finishWaiters; finishWaiters = []; callbacks.forEach { $0() }
    }
    func prepareToQuit(completion: @escaping () -> Void) {
        stopRecording {
            self.timer?.invalidate()
            self.sessionQueue.async {
                self.session.stopRunning()
                self.session.beginConfiguration()
                self.session.inputs.forEach(self.session.removeInput)
                self.session.commitConfiguration()
                self.queue.sync { self.acceptingFrames = false; self.frames.set(nil) }
                self.background.waitUntilIdle()
                RunLoop.main.perform(inModes: [.common, .modalPanel]) { completion() }
            }
        }
    }
    func shutdown() {
        timer?.invalidate()
        sessionQueue.async { self.session.stopRunning(); self.queue.sync { self.acceptingFrames = false; self.frames.set(nil) } }
    }
}
struct StudioError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
