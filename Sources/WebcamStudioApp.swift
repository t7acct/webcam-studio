import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    let engine = CaptureEngine()
    func applicationDidFinishLaunching(_ notification: Notification) {
        if ProcessInfo.processInfo.arguments.contains("--verify-recording") { engine.start() }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        engine.prepareToQuit { sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { engine.shutdown() }
}

@main struct WebcamStudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        Window("Webcam Studio", id: "studio") {
            StudioView(engine: delegate.engine)
                .onAppear { delegate.engine.start() }
        }.defaultSize(width: 1150, height: 780)
        .defaultLaunchBehavior(.presented)
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}

struct StudioView: View {
    @ObservedObject var engine: CaptureEngine
    @State private var showDiagnostics = false
    var busy: Bool { engine.recording || engine.finalizing || engine.configuring }
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 18) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Webcam Studio").font(.title2.weight(.semibold))
                    Text("Camera, lighting and recording").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Label(engine.running ? "Camera live" : "Camera offline", systemImage: engine.running ? "video.fill" : "video.slash")
                    .font(.callout).foregroundStyle(engine.running ? .green : .secondary)
            }.padding(20)
            Divider()
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Picker("Preview", selection: $engine.previewMode) {
                            ForEach(["Original", "Enhanced", "Compare"], id: \.self) { Text($0) }
                        }.pickerStyle(.segmented).frame(maxWidth: 350)
                            .onChange(of: engine.previewMode) { _, _ in engine.updatePreview() }
                        Spacer()
                        Toggle("Mirror preview", isOn: $engine.mirroredPreview).toggleStyle(.checkbox)
                            .onChange(of: engine.mirroredPreview) { _, _ in engine.updatePreview() }
                    }
                    ZStack {
                        MetalPreview(frames: engine.frames, gpu: engine.gpu)
                        if !engine.running {
                            VStack(spacing: 12) {
                                Image(systemName: engine.configuring ? "video" : "video.slash").font(.largeTitle)
                                Text(engine.status).multilineTextAlignment(.center).frame(maxWidth: 420)
                                if !engine.configuring { Button("Reconnect") { engine.refreshDevices(); engine.configure() }.disabled(busy) }
                            }.padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                        }
                        if engine.previewMode == "Compare" && engine.running {
                            VStack { HStack { Text(engine.mirroredPreview ? "ENHANCED" : "ORIGINAL"); Spacer(); Text(engine.mirroredPreview ? "ORIGINAL" : "ENHANCED") }; Spacer() }
                                .font(.caption.weight(.semibold)).foregroundStyle(.white).padding(14).shadow(radius: 3).allowsHitTesting(false)
                        }
                    }.clipShape(RoundedRectangle(cornerRadius: 10)).frame(minHeight: 300)
                    HStack {
                        Text(engine.status).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        Spacer()
                        Button { showDiagnostics.toggle() } label: { Image(systemName: "info.circle") }.buttonStyle(.borderless).help("Capture diagnostics")
                    }
                    if showDiagnostics { Text(engine.diagnostics).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled) }
                    Text("Recordings use your enhancement and background settings. Original/Compare can show your room; Mirror affects preview only.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        GroupBox("Capture") {
                            VStack(alignment: .leading, spacing: 12) {
                                Picker("Camera", selection: Binding(get: { engine.cameraID }, set: { engine.cameraID = $0; engine.cameraChanged() })) {
                                    if engine.cameras.isEmpty { Text("No camera").tag("") }
                                    ForEach(engine.cameras) { Text($0.name).tag($0.id) }
                                }
                                Picker("Microphone", selection: Binding(get: { engine.microphoneID }, set: { engine.microphoneID = $0; engine.configure() })) {
                                    Text("No microphone").tag("")
                                    ForEach(engine.microphones) { Text($0.name).tag($0.id) }
                                }
                                Picker("Quality", selection: Binding(get: { engine.modeID }, set: { engine.modeID = $0; engine.configure() })) {
                                    ForEach(engine.modes) { Text($0.label).tag($0.id) }
                                }
                                HStack { Spacer(); Button("Reconnect") { engine.refreshDevices(); engine.configure() } }
                            }.padding(8).disabled(busy)
                        }
                        if !engine.audioStatus.isEmpty { Text(engine.audioStatus).font(.caption).foregroundStyle(.orange) }
                        GroupBox("Background") {
                            VStack(alignment: .leading, spacing: 12) {
                                Picker("Effect", selection: $engine.backgroundSettings.mode) {
                                    ForEach(BackgroundMode.allCases) { Text($0.label).tag($0) }
                                }
                                if engine.backgroundSettings.mode == .blur {
                                    setting("Blur amount", value: $engine.backgroundSettings.blurAmount, range: 0.05...1)
                                }
                                if engine.backgroundSettings.mode == .colour || engine.backgroundSettings.mode == .photo {
                                    ColorPicker("Background colour", selection: Binding(get: {
                                        Color(red: engine.backgroundSettings.red, green: engine.backgroundSettings.green, blue: engine.backgroundSettings.blue)
                                    }, set: { colour in
                                        if let rgb = NSColor(colour).usingColorSpace(.sRGB) {
                                            engine.backgroundSettings.red = rgb.redComponent
                                            engine.backgroundSettings.green = rgb.greenComponent
                                            engine.backgroundSettings.blue = rgb.blueComponent
                                        }
                                    }), supportsOpacity: false)
                                }
                                if engine.backgroundSettings.mode == .photo {
                                    Button("Choose Photo…") { engine.chooseBackgroundPhoto() }
                                    if let name = engine.backgroundSettings.photoName { Text(name).font(.caption).lineLimit(1).help(name) }
                                }
                                if engine.backgroundSettings.mode != .off {
                                    Text(engine.backgroundStatus).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                    Text("Hair, hands and held objects may blend into the background. Turn this off when showing objects to the camera.")
                                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                }
                            }.padding(8)
                        }.onChange(of: engine.backgroundSettings) { _, _ in engine.updateBackgroundSettings() }
                        GroupBox {
                            VStack(alignment: .leading, spacing: 14) {
                                Toggle("Enhancement", isOn: $engine.settings.enabled).fontWeight(.medium)
                                Divider()
                                Toggle("Auto Lighting", isOn: $engine.settings.autoLighting)
                                    .disabled(!engine.settings.enabled)
                                Text(engine.settings.autoLighting && engine.settings.enabled ? engine.lightStatus : "Gently adjusts exposure and shadows. Manual sliders remain available.")
                                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                VStack(spacing: 14) {
                                    setting("Exposure", value: $engine.settings.exposure, range: -1.5...1.5, format: "%+.2f EV")
                                    setting("Shadows", value: $engine.settings.shadows, range: 0...0.4)
                                    setting("Protect highlights", value: $engine.settings.highlights, range: 0...0.5)
                                    setting("Warmth", value: $engine.settings.warmth, range: -1500...1500, format: "%+.0f")
                                    setting("Contrast", value: $engine.settings.contrast, range: 0.85...1.2)
                                    setting("Saturation", value: $engine.settings.saturation, range: 0.65...1.3)
                                    setting("Noise reduction", value: $engine.settings.noise, range: 0...0.04, format: "%.3f")
                                    setting("Sharpening", value: $engine.settings.sharpness, range: 0...0.6)
                                }.disabled(!engine.settings.enabled)
                                HStack {
                                    Button("Reset to Neutral") { engine.settings = .neutral }.help("Zero adjustments; Auto Lighting off")
                                    Spacer()
                                    Button("Gentle") { engine.settings = EnhancementSettings() }.help("Restore gentle starting settings")
                                }
                            }.padding(8)
                        }.onChange(of: engine.settings) { _, _ in engine.updateSettings() }
                    }.padding(18)
                }.frame(width: 325)
            }
            Divider()
            HStack(spacing: 14) {
                Image(systemName: "mic.fill").foregroundStyle(.secondary)
                ProgressView(value: engine.micLevel).frame(width: 100).tint(.green).accessibilityLabel("Microphone level")
                Text(engine.microphoneID.isEmpty ? "No audio" : "Microphone").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let url = engine.savedURL {
                    Text("Saved \(url.lastPathComponent)").font(.caption).lineLimit(1).help(url.path)
                    Button("Open Recording") { NSWorkspace.shared.open(url) }
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
                if engine.recording {
                    Circle().fill(.red).frame(width: 9, height: 9).accessibilityLabel("Recording")
                    Text(String(format: "%02d:%02d", Int(engine.elapsed) / 60, Int(engine.elapsed) % 60)).monospacedDigit().font(.title3)
                }
                Button {
                    if engine.recording { engine.stopRecording() } else { engine.chooseRecording() }
                } label: {
                    Label(engine.finalizing ? "Finalising…" : (engine.recording ? "Stop" : (engine.microphoneID.isEmpty ? "Record without audio" : "Record")), systemImage: engine.recording ? "stop.fill" : "record.circle")
                        .frame(minWidth: 100)
                }.buttonStyle(.borderedProminent).tint(engine.recording ? .red : .accentColor)
                    .keyboardShortcut("r", modifiers: [.command])
                    .disabled(engine.finalizing || engine.configuring || (!engine.recording && !engine.running))
            }.padding(18)
        }.frame(minWidth: 1000, minHeight: 680)
        .alert("Webcam Studio", isPresented: Binding(get: { engine.errorMessage != nil }, set: { if !$0 { engine.errorMessage = nil } })) {
            Button("OK") { engine.errorMessage = nil }
        } message: { Text(engine.errorMessage ?? "") }
    }
    private func setting(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, format: String = "%.2f") -> some View {
        VStack(spacing: 4) {
            HStack { Text(title); Spacer(); Text(String(format: format, value.wrappedValue)).monospacedDigit().foregroundStyle(.secondary) }.font(.callout)
            Slider(value: value, in: range).accessibilityLabel(title)
        }
    }
}
