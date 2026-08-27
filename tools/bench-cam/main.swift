// bench-cam — a camera you can call from a script.
//
// It exists because macOS will not let a command-line tool have a camera. TCC grants
// access to *bundles*, by identifier, after the bundle asks; a bare executable invoked
// from a shell has no identity to grant, so `imagesnap` and friends are refused before
// the request ever reaches the permission list. This is the same program wearing a
// bundle, an Info.plist and an ad-hoc signature, which is all TCC actually wanted.
//
// The point of it is a closed loop: an agent that changes a screen and can then look at
// the screen, rather than describing the change and asking a human what happened.
//
//   bench-cam --list
//   bench-cam shot.jpg [--device "HD Pro Webcam C920"] [--warmup 12] [--crop x,y,w,h]
//   bench-cam shot.jpg --preview        # a window with a shutter, for setting up the shot
//
// There is deliberately no --exposure or --iso. macOS does not offer them: manual
// exposure duration and ISO are iOS-only on AVCaptureDevice, and a UVC webcam here can
// only be told to hold whatever exposure it has already chosen. Which makes the clipping
// meter in the preview the whole game — the fix for a blown-out photograph of a screen is
// to change the light in the room, and the meter is what says when that has worked.

import AVFoundation
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

final class Shooter: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "bench-cam")
    private let done = DispatchSemaphore(value: 0)
    private var seen = 0
    private var warmup: Int
    private let settle: TimeInterval
    // The finished picture, not the buffer it came from.
    //
    // Holding a CVImageBuffer past its delegate callback holds a slot in the capture
    // pool, and with late-frame dropping disabled the pool is the only thing throttling
    // the camera. A short run never noticed; a ten-second settle starved it, and the
    // process died without reaching any of its own error paths — no photograph, no
    // complaint. Rendering once and releasing the buffer keeps exactly what is wanted.
    private var captured: CGImage?
    private let context = CIContext()

    init(device: AVCaptureDevice, warmup: Int, settle: TimeInterval) throws {
        self.warmup = warmup
        self.settle = settle
        super.init()
        session.beginConfiguration()
        // The highest the camera offers: reading a small screen from across a desk needs
        // every pixel it can get.
        // Whatever the sensor will give. A 4K camera downsampled to 1080p and then cropped
        // to a two-inch watch leaves a couple of hundred pixels to judge a colour by; the
        // same crop off the full sensor is four times the evidence.
        for preset in [AVCaptureSession.Preset.hd4K3840x2160, .hd1920x1080, .high]
        where session.canSetSessionPreset(preset) {
            session.sessionPreset = preset
            break
        }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw Failure("camera will not attach") }
        session.addInput(input)
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String:
                                kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { throw Failure("no video output") }
        session.addOutput(output)
        session.commitConfiguration()
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ text: String) { description = text }
    }

    func captureOutput(_ o: AVCaptureOutput, didOutput sample: CMSampleBuffer,
                       from c: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sample) else { return }
        seen += 1
        // Early frames are exposed for whatever the camera saw before it woke up; a
        // dark room and a bright little screen need several before auto-exposure settles.
        guard seen >= warmup, captured == nil else { return }
        let ci = CIImage(cvImageBuffer: buffer)
        captured = context.createCGImage(ci, from: ci.extent)
        done.signal()
    }

    func shoot(timeout: TimeInterval = 12.0) throws -> CGImage {
        session.startRunning()
        defer { session.stopRunning() }

        // Some cameras need wall-clock time, not frames.
        //
        // The OBSBOT sleeps with its head down and a shutter across the lens, and wakes
        // on a motor when a stream opens. It delivers frames the whole time it is waking,
        // so a warm-up counted in frames is satisfied by ninety pictures of the inside of
        // a shutter and the app exits before the lens ever sees the room. Counting frames
        // measures the wrong thing for a camera that has to physically move.
        if settle > 0 {
            Thread.sleep(forTimeInterval: settle)
            queue.sync { seen = 0; captured = nil }
        }

        if done.wait(timeout: .now() + timeout) == .timedOut {
            throw Failure("no usable frame in \(Int(timeout))s (saw \(seen) frames)")
        }
        guard let image = queue.sync(execute: { captured }) else {
            throw Failure("no frame captured")
        }
        return image
    }
}

// Where a failure gets written down.
//
// The bundle is launched through LaunchServices, which is the whole reason the camera
// grant applies — and LaunchServices discards stderr. So every failure in here has been
// invisible: the caller sees no file appear and no reason why, which is how a broken
// --settle looked identical to a camera that would not wake. A note next to the missing
// photograph costs nothing and is the difference between a diagnosis and a guess.
var errorSidecar: String?

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("bench-cam: \(message)\n".utf8))
    if let sidecar = errorSidecar {
        try? "bench-cam: \(message)\n".write(toFile: sidecar, atomically: true, encoding: .utf8)
    }
    exit(1)
}

func cameras() -> [AVCaptureDevice] {
    AVCaptureDevice.DiscoverySession(
        deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
        mediaType: .video, position: .unspecified).devices
}

// ---- arguments --------------------------------------------------------------------
var args = Array(CommandLine.arguments.dropFirst())
var wanted: String?, path: String?, warmup = 10
var crop: (Int, Int, Int, Int)?
var preview = false
var settle: TimeInterval = 0

while let arg = args.first {
    args.removeFirst()
    switch arg {
    case "--list":
        for device in cameras() { print(device.localizedName) }
        exit(0)
    case "--device": wanted = args.isEmpty ? nil : args.removeFirst()
    case "--preview": preview = true
    case "--warmup": warmup = Int(args.isEmpty ? "10" : args.removeFirst()) ?? 10
    case "--settle": settle = Double(args.isEmpty ? "0" : args.removeFirst()) ?? 0
    case "--crop":
        let parts = (args.isEmpty ? "" : args.removeFirst()).split(separator: ",").compactMap { Int($0) }
        if parts.count == 4 { crop = (parts[0], parts[1], parts[2], parts[3]) }
    default: path = arg
    }
}
if let known = path { errorSidecar = known + ".err" }
guard let destination = path else { fail("usage: bench-cam <out.jpg> [--device NAME] [--warmup N] [--crop x,y,w,h] [--settle S] [--preview]") }

// ---- permission -------------------------------------------------------------------
// Asking explicitly, and waiting: the first run is the one that raises the system
// prompt, and the answer decides whether this tool can ever work.
let gate = DispatchSemaphore(value: 0)
var granted = false
AVCaptureDevice.requestAccess(for: .video) { ok in granted = ok; gate.signal() }
if gate.wait(timeout: .now() + 60) == .timedOut { fail("timed out waiting for the camera prompt") }
guard granted else {
    fail("camera access denied — grant it in System Settings, Privacy & Security, Camera")
}

let devices = cameras()
guard !devices.isEmpty else { fail("no cameras found") }
let device = wanted.flatMap { name in devices.first { $0.localizedName.contains(name) } } ?? devices[0]

if preview { runPreview(device: device, destination: destination, crop: crop) }

// A previous run's complaint must not be mistaken for this one's.
if let sidecar = errorSidecar { try? FileManager.default.removeItem(atPath: sidecar) }

do {
    var image = try Shooter(device: device, warmup: warmup, settle: settle).shoot()
    if let (x, y, w, h) = crop, let cropped = image.cropping(
        to: CGRect(x: x, y: y, width: w, height: h)) {
        image = cropped
    }
    let url = URL(fileURLWithPath: destination)
    guard let sink = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
        fail("cannot write \(destination)")
    }
    CGImageDestinationAddImage(sink, image, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
    guard CGImageDestinationFinalize(sink) else { fail("could not encode the image") }
    print("\(destination) \(image.width)x\(image.height) from \(device.localizedName)")
} catch {
    fail("\(error)")
}
