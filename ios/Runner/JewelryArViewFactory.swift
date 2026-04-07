import Flutter
import UIKit

/// Factory that creates JewelryArPlatformView instances for Flutter's UiKitView.
class JewelryArViewFactory: NSObject, FlutterPlatformViewFactory {
  private let messenger: FlutterBinaryMessenger

  init(messenger: FlutterBinaryMessenger) {
    self.messenger = messenger
    super.init()
  }

  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    return JewelryArPlatformView(
      frame: frame,
      viewId: viewId,
      args: args as? [String: Any] ?? [:],
      messenger: messenger
    )
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    return FlutterStandardMessageCodec.sharedInstance()
  }
}

/// Thin wrapper that satisfies FlutterPlatformView and owns the real UIView.
class JewelryArPlatformView: NSObject, FlutterPlatformView {
  private let jewelryView: JewelryArView

  init(frame: CGRect, viewId: Int64, args: [String: Any], messenger: FlutterBinaryMessenger) {
    jewelryView = JewelryArView(
      frame: frame,
      viewId: viewId,
      args: args,
      messenger: messenger
    )
    super.init()
  }

  func view() -> UIView {
    return jewelryView
  }
}
