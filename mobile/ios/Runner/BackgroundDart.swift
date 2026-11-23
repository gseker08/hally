import Flutter
import Foundation
import flutter_secure_storage_darwin
import home_widget

/// Runs Hally's Dart code without the UI, for a button pressed outside the app: Durdur on a widget or Live
/// Activity, Verdim on a medication reminder. The entry point is `hallyIosBackgroundMain` in
/// lib/features/notifications/ios_background.dart; it answers with what to tell the user, if anything.
@MainActor
final class BackgroundDart {
  static let shared = BackgroundDart()

  private var engine: FlutterEngine?
  private var channel: FlutterMethodChannel?
  private var ready = false
  private var waiting: [CheckedContinuation<Void, Never>] = []

  /// Sends [url] to Dart and returns its reply: nil, or `["title": .., "body": ..]` for a notice to show.
  func run(_ url: URL) async -> [String: String]? {
    start()
    if !ready {
      await withCheckedContinuation { waiting.append($0) }
    }
    return await withCheckedContinuation { continuation in
      channel?.invokeMethod("run", arguments: url.absoluteString) { reply in
        continuation.resume(returning: reply as? [String: String])
      }
    }
  }

  private func start() {
    guard engine == nil else { return }
    let engine = FlutterEngine(name: "hally_background", project: nil, allowHeadlessExecution: true)
    let channel = FlutterMethodChannel(name: "app.hally/background", binaryMessenger: engine.binaryMessenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "ready" else {
        result(FlutterMethodNotImplemented)
        return
      }
      result(nil)
      Task { @MainActor in self?.markReady() }
    }
    engine.run(withEntrypoint: "hallyIosBackgroundMain", libraryURI: "package:hally/features/notifications/ios_background.dart")
    // Only what the background code needs: the keychain (sign-in) and the widget storage.
    if let registrar = engine.registrar(forPlugin: "FlutterSecureStorageDarwinPlugin") {
      FlutterSecureStorageDarwinPlugin.register(with: registrar)
    }
    if let registrar = engine.registrar(forPlugin: "HomeWidgetPlugin") {
      HomeWidgetPlugin.register(with: registrar)
    }
    self.engine = engine
    self.channel = channel
  }

  private func markReady() {
    ready = true
    let resume = waiting
    waiting.removeAll()
    resume.forEach { $0.resume() }
  }
}
