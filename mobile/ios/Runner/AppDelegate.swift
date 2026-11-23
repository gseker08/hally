import Flutter
import UIKit
import UserNotifications
import flutter_local_notifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Notification taps and buttons reach the plugins (and handleMedicationAction below) through this delegate.
    UNUserNotificationCenter.current().delegate = self
    // Durdur on a widget or Live Activity: stop the timer through Dart, then end the activity and redraw widgets.
    HallyIntentBridge.run = { url in
      _ = await BackgroundDart.shared.run(url)
      await LiveActivities.syncWithWidgetData()
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    // Buttons on the app's own notifications (Verdim while the app was open) run Dart in a separate isolate.
    FlutterLocalNotificationsPlugin.setPluginRegistrantCallback { registry in
      GeneratedPluginRegistrant.register(with: registry)
    }
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "HallyLiveActivities") {
      LiveActivities.register(with: registrar.messenger())
    }
  }

  /// "Verdim" on the medication reminder push (category `hally.med`, see PushSender.cs). The push comes from the
  /// server, not from flutter_local_notifications, so the app handles its button itself: Dart records the dose in
  /// the background; if it was not saved, a notice says why.
  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let info = response.notification.request.content.userInfo
    guard response.actionIdentifier == "med.given", let family = info["familyId"] as? String,
      let medication = info["medicationId"] as? String
    else {
      super.userNotificationCenter(center, didReceive: response, withCompletionHandler: completionHandler)
      return
    }
    var c = URLComponents()
    c.scheme = "hally"
    c.host = "med"
    c.path = "/given"
    c.queryItems = [URLQueryItem(name: "family", value: family), URLQueryItem(name: "med", value: medication)]
    let identifier = response.notification.request.identifier
    Task { @MainActor in
      let notice = await BackgroundDart.shared.run(c.url!)
      center.removeDeliveredNotifications(withIdentifiers: [identifier])
      if let notice {
        let content = UNMutableNotificationContent()
        content.title = notice["title"] ?? ""
        content.body = notice["body"] ?? ""
        try? await center.add(UNNotificationRequest(identifier: "med-notice-\(medication)", content: content, trigger: nil))
      }
      completionHandler()
    }
  }
}
