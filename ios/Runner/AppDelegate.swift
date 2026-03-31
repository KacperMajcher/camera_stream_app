import Flutter
import UIKit
import Vision

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {

  private var handTrackingEventSink: FlutterEventSink?
  private var frameCounter: Int = 0
  private let frameSkip: Int = 3  // process every 3rd frame

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    guard let binaryMessenger = engineBridge.pluginRegistry.registrar(forPlugin: "HandTracking")?.messenger() else {
      return
    }

    // MethodChannel – receiving frames from Flutter image stream
    let methodChannel = FlutterMethodChannel(
      name: "vision_hand_tracking",
      binaryMessenger: binaryMessenger
    )
    methodChannel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      if call.method == "processFrame" {
        guard let args = call.arguments as? [String: Any],
              let pixels     = args["pixels"]     as? FlutterStandardTypedData,
              let width      = args["width"]      as? Int,
              let height     = args["height"]     as? Int,
              let bytesPerRow = args["bytesPerRow"] as? Int
        else {
          print("[HandTracking] ❌ processFrame: arguments mapping failed. args=\(String(describing: call.arguments))")
          result(nil)
          return
        }

        self.frameCounter += 1
        guard self.frameCounter % self.frameSkip == 0 else {
          result(nil)
          return
        }

        self.processBGRAFrame(
          pixels: pixels.data,
          width: width,
          height: height,
          srcBytesPerRow: bytesPerRow
        )
        result(nil)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }

    // EventChannel – sending results back to Flutter
    let eventChannel = FlutterEventChannel(
      name: "vision_hand_tracking/events",
      binaryMessenger: binaryMessenger
    )
    eventChannel.setStreamHandler(self)
  }

  // MARK: - Vision processing

  private func processBGRAFrame(pixels: Data, width: Int, height: Int, srcBytesPerRow: Int) {
    // Build CVPixelBuffer from BGRA8888 plane
    var pixelBuffer: CVPixelBuffer?
    let attrs: [CFString: Any] = [
      kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
    ]
    CVPixelBufferCreate(
      kCFAllocatorDefault,
      width, height,
      kCVPixelFormatType_32BGRA,
      attrs as CFDictionary,
      &pixelBuffer
    )
    guard let buffer = pixelBuffer else { return }

    CVPixelBufferLockBaseAddress(buffer, [])

    if let dest = CVPixelBufferGetBaseAddress(buffer) {
      let dstBytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
      let bytesPerPixelRow = min(srcBytesPerRow, dstBytesPerRow)
      pixels.withUnsafeBytes { src in
        for row in 0..<height {
          memcpy(
            dest.advanced(by: row * dstBytesPerRow),
            src.baseAddress!.advanced(by: row * srcBytesPerRow),
            bytesPerPixelRow
          )
        }
      }
    }

    CVPixelBufferUnlockBaseAddress(buffer, [])

    // Execute VNDetectHumanHandPoseRequest
    let request = VNDetectHumanHandPoseRequest()
    request.maximumHandCount = 1

    // Rear camera in portrait mode – frame is rotated by 90° by sensor,
    // .up orientation corrects this for Vision.
    let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up, options: [:])
    do {
      try handler.perform([request])
    } catch {
      return
    }

    guard let observation = request.results?.first as? VNHumanHandPoseObservation else {
      return
    }

    // All 21 hand joints – Vision returns Y from bottom, inverted to match Flutter (0 = top)
    let jointNames: [VNHumanHandPoseObservation.JointName] = [
      .wrist,
      .thumbCMC, .thumbMP, .thumbIP, .thumbTip,
      .indexMCP, .indexPIP, .indexDIP, .indexTip,
      .middleMCP, .middlePIP, .middleDIP, .middleTip,
      .ringMCP, .ringPIP, .ringDIP, .ringTip,
      .littleMCP, .littlePIP, .littleDIP, .littleTip
    ]

    var joints: [String: [String: Double]] = [:]
    for name in jointNames {
      guard let pt = try? observation.recognizedPoint(name), pt.confidence > 0.2 else { continue }
      joints[name.rawValue.rawValue] = [
        "x": Double(pt.location.x),
        "y": Double(1.0 - pt.location.y)
      ]
    }

    guard !joints.isEmpty else {
      return
    }

    let payload: [String: Any] = ["joints": joints]
    DispatchQueue.main.async { [weak self] in
      self?.handTrackingEventSink?(payload)
    }
  }
}

// MARK: - FlutterStreamHandler

extension AppDelegate: FlutterStreamHandler {
  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    handTrackingEventSink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    handTrackingEventSink = nil
    return nil
  }
}
