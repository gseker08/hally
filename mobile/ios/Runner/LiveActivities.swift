import ActivityKit
import Flutter
import Foundation
import WidgetKit

/// `app.hally/live_activities`: the Dart side (IosDeviceNotifications) starts, updates and ends the Live Activity of
/// each running timer this user started, the iPhone counterpart of Android's ongoing timer notification.
enum LiveActivities {
  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "app.hally/live_activities", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      guard #available(iOS 16.2, *) else {
        result(call.method == "keys" ? [String]() : nil)
        return
      }
      let args = call.arguments as? [String: Any] ?? [:]
      Task { @MainActor in
        switch call.method {
        case "show":
          result(await show(args))
        case "end":
          await end(key: args["key"] as? String ?? "")
          result(nil)
        case "endAll":
          await endWhere { _ in true }
          result(nil)
        case "keys":
          result(Activity<HallyTimerAttributes>.activities.map { $0.attributes.key })
        default:
          result(FlutterMethodNotImplemented)
        }
      }
    }
  }

  /// Starts the timer's activity, or updates it when it already runs. False when the user turned Live Activities off.
  @available(iOS 16.2, *)
  @MainActor
  static func show(_ a: [String: Any]) async -> Bool {
    guard let key = a["key"] as? String, let type = a["type"] as? String, let familyId = a["familyId"] as? String,
      let childId = a["childId"] as? String, let since = HallyShared.date(a["since"])
    else { return false }
    let state = HallyTimerAttributes.ContentState(
      title: a["title"] as? String ?? "", body: a["body"] as? String ?? "", since: since)
    // A forgotten timer: after the server's cap iOS shows it as stale until the app ends it.
    let content = ActivityContent(state: state, staleDate: HallyShared.date(a["until"]))
    if let running = Activity<HallyTimerAttributes>.activities.first(where: { $0.attributes.key == key }) {
      await running.update(content)
      return true
    }
    guard ActivityAuthorizationInfo().areActivitiesEnabled else { return false }
    let attributes = HallyTimerAttributes(
      key: key, type: type, familyId: familyId, childId: childId, emoji: a["emoji"] as? String ?? "",
      stopLabel: a["stopLabel"] as? String ?? "Durdur")
    do {
      _ = try Activity.request(attributes: attributes, content: content, pushType: nil)
      return true
    } catch {
      NSLog("Hally: Live Activity not started: \(error)")
      return false
    }
  }

  @available(iOS 16.2, *)
  static func end(key: String) async {
    await endWhere { $0.attributes.key == key }
  }

  @available(iOS 16.2, *)
  static func endWhere(_ match: (Activity<HallyTimerAttributes>) -> Bool) async {
    for activity in Activity<HallyTimerAttributes>.activities where match(activity) {
      await activity.end(nil, dismissalPolicy: .immediate)
    }
  }

  /// After a Durdur in the background: ends the activities whose timer the Dart side removed from the widget list
  /// (stopped now, or already stopped on the other phone), and redraws the widgets.
  static func syncWithWidgetData() async {
    WidgetCenter.shared.reloadAllTimelines()
    guard #available(iOS 16.2, *) else { return }
    let running = Set(
      HallyShared.list("now.items").compactMap { t -> String? in
        guard let type = t["type"] as? String, let child = t["childId"] as? String else { return nil }
        return "\(type):\(child)"
      })
    await endWhere { !running.contains($0.attributes.key) }
  }
}
