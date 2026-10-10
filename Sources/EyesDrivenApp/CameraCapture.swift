import AVFoundation
import CoreMedia
import Foundation

/// A camera device AVFoundation can open.
struct CameraDevice: Equatable, Identifiable {
    /// AVFoundation `uniqueID`; stable across launches.
    let uniqueID: String
    /// Human-readable device name (e.g. "FaceTime HD Camera").
    let name: String

    var id: String { uniqueID }
}

/// Errors thrown while configuring or starting the capture session.
enum CameraCaptureError: LocalizedError {
    case noCameraAvailable
    case cannotAddInput
    case cannotAddOutput

    var errorDescription: String? {
        switch self {
        case .noCameraAvailable:
            return "No camera device is available."
        case .cannotAddInput:
            return "The capture session could not add the camera input."
        case .cannotAddOutput:
            return "The capture session could not add the video output."
        }
    }
}

/// Thin AVFoundation adapter that owns a single `AVCaptureSession` and delivers
/// `CMSampleBuffer`s on a private serial queue. It never writes frames to disk
/// and never touches the network.
final class CameraCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {

    /// Called on a private serial queue for every captured frame.
    var onFrame: ((CMSampleBuffer) -> Void)?

    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "me.eyesdriven2.camera.capture")
    private var configured = false
    private var configuredCameraID: String?

    /// Every video camera currently visible, with the built-in camera listed
    /// first when the discovery session reports it.
    static func availableCameras() -> [CameraDevice] {
        discoverySession().devices.map {
            CameraDevice(uniqueID: $0.uniqueID, name: $0.localizedName)
        }
    }

    private static func discoverySession() -> AVCaptureDevice.DiscoverySession {
        var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
        if #available(macOS 14.0, *) {
            types.append(.external)
            types.append(.continuityCamera)
        }
        return AVCaptureDevice.DiscoverySession(
            deviceTypes: types,
            mediaType: .video,
            position: .unspecified
        )
    }

    /// Starts delivering frames. When `cameraUniqueID` is `nil` the built-in
    /// (default) camera is preferred, then the first available video device.
    /// Reconfigures the session if a different camera is requested.
    func start(cameraUniqueID: String?) throws {
        if session.isRunning { return }

        let device = try Self.device(for: cameraUniqueID)

        // Reconfigure only when needed. `beginConfiguration`/`commitConfiguration`
        // are scoped to this block so `startRunning()` runs outside them —
        // AVCaptureSession raises if started between the two calls.
        if !configured || configuredCameraID != device.uniqueID {
            session.beginConfiguration()
            defer { session.commitConfiguration() }

            for input in session.inputs {
                session.removeInput(input)
            }

            // 640x480 when the device supports it, otherwise the nearest preset.
            session.sessionPreset = session.canSetSessionPreset(.vga640x480) ? .vga640x480 : .medium

            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { throw CameraCaptureError.cannotAddInput }
            session.addInput(input)

            // Drop late frames instead of queueing them up.
            output.alwaysDiscardsLateVideoFrames = true
            output.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            ]
            output.setSampleBufferDelegate(self, queue: queue)

            if !session.outputs.contains(output) {
                guard session.canAddOutput(output) else { throw CameraCaptureError.cannotAddOutput }
                session.addOutput(output)
            }

            configured = true
            configuredCameraID = device.uniqueID
        }

        session.startRunning()
    }

    /// Stops the session. Safe to call multiple times.
    func stop() {
        guard session.isRunning else { return }
        session.stopRunning()
    }

    private static func device(for uniqueID: String?) throws -> AVCaptureDevice {
        if let uniqueID, let device = AVCaptureDevice(uniqueID: uniqueID) {
            return device
        }
        if let device = AVCaptureDevice.default(for: .video) {
            return device
        }
        if let device = discoverySession().devices.first {
            return device
        }
        throw CameraCaptureError.noCameraAvailable
    }

    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        onFrame?(sampleBuffer)
    }
}
