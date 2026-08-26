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
    private var latest: CVImageBuffer?

    init(device: AVCaptureDevice, warmup: Int) throws {
        self.warmup = warmup
        super.init()
        session.beginConfiguration()
        // The highest the camera offers: reading a small screen from across a desk needs
        // every pixel it can get.
        if session.canSetSessionPreset(.hd1920x1080) { session.sessionPreset = .hd1920x1080 }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw Failure("camera will not attach") }
        session.addInput(input)
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String:
                                kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = false
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
        latest = buffer
        // Early frames are exposed for whatever the camera saw before it woke up; a
        // dark room and a bright little screen need several before auto-exposure settles.
        if seen >= warmup { done.signal() }
    }

    func shoot(timeout: TimeInterval = 12.0) throws -> CGImage {
        session.startRunning()
        defer { session.stopRunning() }
        if done.wait(timeout: .now() + timeout) == .timedOut, seen == 0 {
            throw Failure("no frames arrived in \(Int(timeout))s")
        }
        guard let buffer = latest else { throw Failure("no frame captured") }
        let ci = CIImage(cvImageBuffer: buffer)
        guard let cg = CIContext().createCGImage(ci, from: ci.extent) else {
            throw Failure("could not convert the frame")
        }
        return cg
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("bench-cam: \(message)\n".utf8))
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

while let arg = args.first {
    args.removeFirst()
    switch arg {
    case "--list":
        for device in cameras() { print(device.localizedName) }
        exit(0)
    case "--device": wanted = args.isEmpty ? nil : args.removeFirst()
    case "--warmup": warmup = Int(args.isEmpty ? "10" : args.removeFirst()) ?? 10
    case "--crop":
        let parts = (args.isEmpty ? "" : args.removeFirst()).split(separator: ",").compactMap { Int($0) }
        if parts.count == 4 { crop = (parts[0], parts[1], parts[2], parts[3]) }
    default: path = arg
    }
}
guard let destination = path else { fail("usage: bench-cam <out.jpg> [--device NAME] [--warmup N] [--crop x,y,w,h]") }

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

do {
    var image = try Shooter(device: device, warmup: warmup).shoot()
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
