import AppIntents
import Foundation

/// The app sets this at launch: it runs Hally's Dart code in the background for a widget or Live Activity button.
/// Nil inside the widget extension, which never runs these intents itself.
enum HallyIntentBridge {
  static var run: ((URL) async -> Void)?
}

/// Durdur on the "Şu an" widget and on a timer's Live Activity. A LiveActivityIntent runs in the app's process
/// (launched in the background if needed), where the app's sign-in and API code live.
@available(iOS 17.0, *)
struct StopTimerIntent: LiveActivityIntent {
  static var title: LocalizedStringResource = "Stop timer"
  static var isDiscoverable: Bool = false

  @Parameter(title: "Type") var type: String
  @Parameter(title: "Family") var familyId: String
  @Parameter(title: "Child") var childId: String

  init() {}

  init(type: String, familyId: String, childId: String) {
    self.type = type
    self.familyId = familyId
    self.childId = childId
  }

  func perform() async throws -> some IntentResult {
    await HallyIntentBridge.run?(HallyShared.stopTimerURL(type: type, familyId: familyId, childId: childId))
    return .result()
  }
}
