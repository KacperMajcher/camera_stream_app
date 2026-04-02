import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {

  private var arView: RingARView?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "RingAR") else {
      return
    }

    // Rejestracja natywnego widoku ARKit/SceneKit
    let factory = RingARViewFactory { [weak self] view in
      self?.arView = view
    }
    registrar.register(factory, withId: "ring_ar_view")

    // MethodChannel – sterowanie widocznością szkieletu dłoni z Fluttera
    let channel = FlutterMethodChannel(
      name: "ring_ar_channel",
      binaryMessenger: registrar.messenger()
    )
    channel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "setDebugGlove":
        guard let args = call.arguments as? [String: Any],
              let enabled = args["enabled"] as? Bool else {
          result(FlutterError(code: "INVALID_ARGS",
                              message: "Expected {enabled: Bool}",
                              details: nil))
          return
        }
        self?.arView?.setDebugGlove(enabled: enabled)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
