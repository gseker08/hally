import ActivityKit
import Foundation

/// A running timer (screen time, homework/reading, sleep) as a Live Activity: on the lock screen and in the
/// Dynamic Island. The app starts one for each timer this user started (like the ongoing notification on
/// Android) and ends it when the timer stops on either phone.
@available(iOS 16.1, *)
struct HallyTimerAttributes: ActivityAttributes {
  struct ContentState: Codable, Hashable {
    var title: String
    var body: String
    /// The clock counts up from here.
    var since: Date
  }

  /// `type:childId`, the same key the app uses for its timers.
  var key: String
  var type: String
  var familyId: String
  var childId: String
  var emoji: String
  /// "Durdur" in the app's language.
  var stopLabel: String
}
