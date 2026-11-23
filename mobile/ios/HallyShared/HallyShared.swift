import Foundation

/// Shared by the app and its widget extension: the App Group both read and write, and the keys the Flutter side
/// saves there (lib/features/home/today_widget.dart, now_widget.dart).
enum HallyShared {
  static let appGroup = "group.app.hally"
  static let todayWidgetKind = "TodayWidget"
  static let nowWidgetKind = "NowWidget"

  static var defaults: UserDefaults? { UserDefaults(suiteName: appGroup) }

  static func string(_ key: String) -> String? { defaults?.string(forKey: key) }

  /// A JSON list saved by the app, or an empty list.
  static func list(_ key: String) -> [[String: Any]] {
    guard let text = string(key), let data = text.data(using: .utf8),
      let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    else { return [] }
    return list
  }

  /// Milliseconds since 1970 (as Dart saves them) to a date.
  static func date(_ value: Any?) -> Date? {
    guard let ms = (value as? NSNumber)?.doubleValue else { return nil }
    return Date(timeIntervalSince1970: ms / 1000)
  }

  /// `hally://timer/stop?type=screen&family=..&child=..`: the same link the Android widget's Durdur sends.
  static func stopTimerURL(type: String, familyId: String, childId: String) -> URL {
    var c = URLComponents()
    c.scheme = "hally"
    c.host = "timer"
    c.path = "/stop"
    c.queryItems = [
      URLQueryItem(name: "type", value: type),
      URLQueryItem(name: "family", value: familyId),
      URLQueryItem(name: "child", value: childId),
    ]
    return c.url!
  }
}
