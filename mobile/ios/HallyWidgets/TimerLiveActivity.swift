import ActivityKit
import SwiftUI
import WidgetKit

/// A running timer on the lock screen and in the Dynamic Island, for the timers this user started. The clock counts
/// by itself; Durdur (iOS 17+) stops it through the app in the background.
struct TimerLiveActivity: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: HallyTimerAttributes.self) { context in
      HStack(spacing: 12) {
        Text(context.attributes.emoji).font(.title)
        VStack(alignment: .leading, spacing: 2) {
          Text(context.state.title).font(.headline).lineLimit(1)
          if !context.state.body.isEmpty {
            Text(context.state.body).font(.caption).foregroundColor(.secondary).lineLimit(1)
          }
          Text(context.state.since, style: .timer).font(.title2.weight(.semibold).monospacedDigit())
        }
        Spacer(minLength: 8)
        LiveStopButton(attributes: context.attributes)
      }
      .padding(16)
      .activityBackgroundTint(Color(.systemBackground))
      .activitySystemActionForegroundColor(.hallyCherry)
    } dynamicIsland: { context in
      DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          Text(context.attributes.emoji).font(.title2)
        }
        DynamicIslandExpandedRegion(.center) {
          Text(context.state.title).font(.headline).lineLimit(1)
        }
        DynamicIslandExpandedRegion(.trailing) {
          Text(context.state.since, style: .timer).font(.headline.monospacedDigit()).frame(maxWidth: 72)
        }
        DynamicIslandExpandedRegion(.bottom) {
          LiveStopButton(attributes: context.attributes)
        }
      } compactLeading: {
        Text(context.attributes.emoji)
      } compactTrailing: {
        Text(context.state.since, style: .timer).monospacedDigit().frame(maxWidth: 48)
      } minimal: {
        Text(context.attributes.emoji)
      }
      .keylineTint(.hallyCherry)
    }
  }
}

struct LiveStopButton: View {
  let attributes: HallyTimerAttributes

  var body: some View {
    if #available(iOS 17.0, *) {
      Button(intent: StopTimerIntent(type: attributes.type, familyId: attributes.familyId, childId: attributes.childId)) {
        Text(attributes.stopLabel).font(.subheadline.weight(.semibold))
      }
      .tint(.hallyCherry)
    }
  }
}
