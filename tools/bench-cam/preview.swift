// The window half of bench-cam: a live view with a shutter, for setting up the shot.
//
// Headless capture answers "what is on the panel". It cannot answer "is the lamp in the
// right place", because that question is asked by a human moving a lamp and needs an
// answer at the speed of moving it. So: a preview, a button, and — the actual point — a
// clipping meter.
//
// Clipping is the failure that matters here. A screen photographed in a dark room drives
// auto-exposure wide open, every lit pixel pins to 255, and the photograph then reports
// that a colour is white regardless of which colour it is. That looks like "saturated"
// and is really "clipped": the information is gone before the file is written, and no
// amount of editing afterwards brings it back. The meter counts pixels at the ceiling, so
// the lamp can be moved until the number reaches zero, which is the condition under which
// a photograph of a screen means anything at all.

import AVFoundation
import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

final class PreviewController: NSObject, NSApplicationDelegate,
                               AVCaptureVideoDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "bench-cam.preview")
    private let device: AVCaptureDevice
    private let destination: String
    private let crop: (Int, Int, Int, Int)?

    private var window: NSWindow!
    private var readout: NSTextField!
    private var lockBox: NSButton!

    private let frameLock = NSLock()
    private var latest: CVImageBuffer?
    private var saved = 0

    init(device: AVCaptureDevice, destination: String, crop: (Int, Int, Int, Int)?) {
        self.device = device
        self.destination = destination
        self.crop = crop
    }

    // ---- lifecycle ----------------------------------------------------------------

    func applicationDidFinishLaunching(_ note: Notification) {
        session.beginConfiguration()
        // Whatever the sensor will give. A 4K camera downsampled to 1080p and then cropped
        // to a two-inch watch leaves a couple of hundred pixels to judge a colour by; the
        // same crop off the full sensor is four times the evidence.
        for preset in [AVCaptureSession.Preset.hd4K3840x2160, .hd1920x1080, .high]
        where session.canSetSessionPreset(preset) {
            session.sessionPreset = preset
            break
        }
        guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
            fatal("camera will not attach")
        }
        session.addInput(input)
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String:
                                kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()

        buildWindow()
        session.startRunning()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }

    private func fatal(_ message: String) -> Never {
        FileHandle.standardError.write(Data("bench-cam: \(message)\n".utf8))
        exit(1)
    }

    // ---- window -------------------------------------------------------------------

    private func buildWindow() {
        let videoHeight: CGFloat = 480, panelHeight: CGFloat = 96, width: CGFloat = 854
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: videoHeight + panelHeight),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "bench-cam — \(device.localizedName)"
        window.center()

        let content = NSView(frame: window.contentLayoutRect)
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.black.cgColor

        let video = NSView(frame: NSRect(x: 0, y: panelHeight, width: width, height: videoHeight))
        video.wantsLayer = true
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.frame = video.bounds
        layer.videoGravity = .resizeAspect
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        video.layer?.addSublayer(layer)
        video.autoresizingMask = [.width, .height]
        content.addSubview(video)

        readout = NSTextField(labelWithString: "measuring…")
        readout.frame = NSRect(x: 16, y: panelHeight - 32, width: width - 200, height: 20)
        readout.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        readout.textColor = .white
        content.addSubview(readout)

        let shutter = NSButton(title: "Take a shot", target: self, action: #selector(shoot))
        shutter.frame = NSRect(x: width - 170, y: panelHeight - 40, width: 150, height: 32)
        shutter.bezelStyle = .rounded
        shutter.keyEquivalent = " "   // space, because a shutter should be a shutter
        content.addSubview(shutter)

        // macOS gives a UVC camera no manual exposure — no duration, no ISO, no target
        // bias; those are iOS-only. Holding the current exposure is the one control that
        // exists, and it matters because auto-exposure re-meters between shots, so two
        // photographs of two colours are otherwise taken under two different cameras.
        lockBox = NSButton(checkboxWithTitle: "Hold this exposure",
                           target: self, action: #selector(lockChanged))
        lockBox.frame = NSRect(x: 16, y: 12, width: 200, height: 20)
        lockBox.contentTintColor = .white
        content.addSubview(lockBox)

        let hint = NSTextField(labelWithString:
            "Move the light until the meter reads clean, then hold the exposure.")
        hint.frame = NSRect(x: 230, y: 12, width: width - 250, height: 20)
        hint.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        hint.textColor = .darkGray
        content.addSubview(hint)

        window.contentView = content
        window.makeKeyAndOrderFront(nil)
    }

    // ---- exposure -----------------------------------------------------------------

    @objc private func lockChanged() {
        guard (try? device.lockForConfiguration()) != nil else { return }
        defer { device.unlockForConfiguration() }
        let wanted: AVCaptureDevice.ExposureMode = lockBox.state == .on ? .locked
                                                                       : .continuousAutoExposure
        if device.isExposureModeSupported(wanted) { device.exposureMode = wanted }
    }

    // ---- frames -------------------------------------------------------------------

    func captureOutput(_ o: AVCaptureOutput, didOutput sample: CMSampleBuffer,
                       from c: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sample) else { return }
        frameLock.lock(); latest = buffer; frameLock.unlock()

        let clipped = PreviewController.clippedFraction(buffer)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let verdict = clipped > 0.02 ? "CLIPPED — the colour is gone, darken it"
                        : clipped > 0.002 ? "nearly clipping"
                        : "clean"
            let held = self.device.exposureMode == .locked ? "held" : "auto"
            self.readout.stringValue = String(
                format: "%5.2f%% at the ceiling   %@   |  exposure %@  |  %d saved",
                clipped * 100, verdict, held, self.saved)
            self.readout.textColor = clipped > 0.02 ? .systemRed
                                   : clipped > 0.002 ? .systemYellow : .systemGreen
        }
    }

    // Every 64th pixel is plenty: this is looking for a region of blown highlights, not
    // for a stray one, and it runs on every frame.
    private static func clippedFraction(_ buffer: CVImageBuffer) -> Double {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return 0 }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var hot = 0, seen = 0
        for y in Swift.stride(from: 0, to: height, by: 8) {
            let row = bytes + y * stride
            for x in Swift.stride(from: 0, to: width, by: 8) {
                let p = row + x * 4
                if p[0] >= 250 || p[1] >= 250 || p[2] >= 250 { hot += 1 }
                seen += 1
            }
        }
        return seen == 0 ? 0 : Double(hot) / Double(seen)
    }

    // ---- shutter ------------------------------------------------------------------

    @objc private func shoot() {
        frameLock.lock(); let buffer = latest; frameLock.unlock()
        guard let buffer else { return }
        let ci = CIImage(cvImageBuffer: buffer)
        guard var image = CIContext().createCGImage(ci, from: ci.extent) else { return }
        if let (x, y, w, h) = crop,
           let cropped = image.cropping(to: CGRect(x: x, y: y, width: w, height: h)) {
            image = cropped
        }

        // Successive clicks are successive files. Overwriting would make the button
        // useless for the thing it is for — comparing one lighting setup against another.
        let url = URL(fileURLWithPath: destination)
        let stem = url.deletingPathExtension().path
        let ext = url.pathExtension.isEmpty ? "jpg" : url.pathExtension
        let path = saved == 0 ? destination : "\(stem)-\(saved + 1).\(ext)"

        guard let sink = CGImageDestinationCreateWithURL(
            URL(fileURLWithPath: path) as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(
            sink, image, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        guard CGImageDestinationFinalize(sink) else { return }
        saved += 1
        print(path)
        NSSound(named: "Tink")?.play()
    }
}

func runPreview(device: AVCaptureDevice, destination: String, crop: (Int, Int, Int, Int)?) -> Never {
    let app = NSApplication.shared
    // The bundle is LSUIElement so that headless shots do not bounce a dock icon. A
    // window needs the opposite, so the policy is raised only for this mode.
    app.setActivationPolicy(.regular)
    let controller = PreviewController(device: device, destination: destination, crop: crop)
    app.delegate = controller
    app.run()
    exit(0)
}
