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

    // MethodChannel – odbieranie klatek z Flutter image stream
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
          print("[HandTracking] ❌ processFrame: rzutowanie argumentów nieudane. args=\(String(describing: call.arguments))")
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

    // EventChannel – wysyłanie wyników do Fluttera
    let eventChannel = FlutterEventChannel(
      name: "vision_hand_tracking/events",
      binaryMessenger: binaryMessenger
    )
    eventChannel.setStreamHandler(self)
  }

  // MARK: - Vision processing

  private func processBGRAFrame(pixels: Data, width: Int, height: Int, srcBytesPerRow: Int) {
    // Zbuduj CVPixelBuffer z pojedynczej płaszczyzny BGRA8888
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

    // Uruchom VNDetectHumanHandPoseRequest
    let request = VNDetectHumanHandPoseRequest()
    request.maximumHandCount = 1

    // Kamera tylna w trybie portrait – klatka jest obracana o 90° przez sensor,
    // orientacja .up koryguje to dla Vision.
    let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up, options: [:])
    do {
      try handler.perform([request])
    } catch {
      return
    }

    guard let observation = request.results?.first as? VNHumanHandPoseObservation else {
      print("[HandTracking] 🤚 brak dłoni w kadrze (wyniki Vision: \(String(describing: request.results?.count ?? 0)))")
      return
    }

    // Wszystkie 21 punktów dłoni – Vision zwraca Y od dołu, odwracamy do układu Flutter (0 = góra)
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
      // name.rawValue is VNRecognizedPointKey, which has .rawValue as String
      joints[name.rawValue.rawValue] = [
        "x": Double(pt.location.x),
        "y": Double(1.0 - pt.location.y)
      ]
      // DEBUG – wypisz klucz przy pierwszej klatce
      if self.frameCounter == self.frameSkip {
        print("[HandTracking] klucz: \(name.rawValue.rawValue)")
      }
    }

    guard !joints.isEmpty else {
      print("[HandTracking] ⚠️ żaden punkt nie przeszedł progu confidence")
      return
    }

    let payload: [String: Any] = ["joints": joints]
    print("[HandTracking] ✅ wysyłam \(joints.count) punktów")
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
