import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    guard let registrar = self.registrar(forPlugin: "JewelryArView") else {
      return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }
    let factory = JewelryArViewFactory(messenger: registrar.messenger())
    registrar.register(factory, withId: "jewelry_ar_view")

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
