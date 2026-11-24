import SwiftUI
import WidgetKit

/// Hally's widget extension: the "Bugün" and "Şu an" widgets (home screen and lock screen) and the Live Activity of a
/// running timer. They read what the app saved in the App Group; the app redraws them when the data changes.
@main
struct HallyWidgetsBundle: WidgetBundle {
  var body: some Widget {
    TodayWidget()
    NowWidget()
    TimerLiveActivity()
  }
}

extension Color {
  /// Brand cherry. Never used for errors or delays.
  static let hallyCherry = Color(red: 0xAD / 255, green: 0x52 / 255, blue: 0x68 / 255)
}

extension View {
  /// iOS 17 wants the widget background declared; older versions draw it as a plain background.
  @ViewBuilder
  func hallyWidgetBackground() -> some View {
    if #available(iOS 17.0, *) {
      containerBackground(for: .widget) { Color(.systemBackground) }
    } else {
      padding().background(Color(.systemBackground))
    }
  }
}

/// "14:30" in 24-hour time, as on Android.
func hallyClock(_ date: Date) -> String {
  let f = DateFormatter()
  f.locale = Locale(identifier: "en_US_POSIX")
  f.dateFormat = "HH:mm"
  return f.string(from: date)
}
