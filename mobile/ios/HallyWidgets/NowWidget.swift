import SwiftUI
import WidgetKit

/// "Şu an": the family's running timers (screen time, homework/reading, sleep). The app saves the list whenever a
/// timer starts or stops (lib/features/home/now_widget.dart). The clocks tick by themselves; Durdur (iOS 17+)
/// stops the timer through the app in the background. A timer past the server's cap is hidden.
struct NowWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: HallyShared.nowWidgetKind, provider: NowProvider()) { entry in
      NowWidgetView(entry: entry)
    }
    .configurationDisplayName("Hally")
    .description(NowTexts.load().title)
    .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline])
  }
}

struct NowTimer: Hashable {
  let type: String
  let familyId: String
  let childId: String
  let title: String
  let body: String
  let emoji: String
  let since: Date
  let until: Date?
}

struct NowTexts {
  var title = "Şu an"
  var empty = "Çalışan sayaç yok"
  var count = "%d sayaç çalışıyor"
  var stop = "Durdur"

  static func load() -> NowTexts {
    var t = NowTexts()
    if let s = HallyShared.string("now.title") { t.title = s }
    if let s = HallyShared.string("now.empty") { t.empty = s }
    if let s = HallyShared.string("now.count") { t.count = s }
    if let s = HallyShared.string("now.stop") { t.stop = s }
    return t
  }
}

struct NowEntry: TimelineEntry {
  let date: Date
  let timers: [NowTimer]
  let texts: NowTexts
}

struct NowProvider: TimelineProvider {
  static func timers(at date: Date) -> [NowTimer] {
    HallyShared.list("now.items").compactMap { t in
      guard let type = t["type"] as? String, let family = t["familyId"] as? String, let child = t["childId"] as? String,
        let since = HallyShared.date(t["since"])
      else { return nil }
      let until = HallyShared.date(t["until"])
      if let until, until <= date { return nil }
      return NowTimer(
        type: type, familyId: family, childId: child, title: t["title"] as? String ?? "", body: t["body"] as? String ?? "",
        emoji: t["emoji"] as? String ?? "", since: since, until: until)
    }
  }

  func placeholder(in context: Context) -> NowEntry {
    NowEntry(
      date: Date(),
      timers: [NowTimer(type: "screen", familyId: "", childId: "", title: "…", body: "", emoji: "📱", since: Date().addingTimeInterval(-1500), until: nil)],
      texts: NowTexts())
  }

  func getSnapshot(in context: Context, completion: @escaping (NowEntry) -> Void) {
    completion(context.isPreview ? placeholder(in: context) : NowEntry(date: Date(), timers: Self.timers(at: Date()), texts: NowTexts.load()))
  }

  /// Now, and the moment each forgotten timer reaches its cap. The app reloads the widget on every change.
  func getTimeline(in context: Context, completion: @escaping (Timeline<NowEntry>) -> Void) {
    let now = Date()
    let texts = NowTexts.load()
    var moments: Set<Date> = [now]
    for t in Self.timers(at: now) { if let until = t.until { moments.insert(until) } }
    let entries = moments.sorted().map { NowEntry(date: $0, timers: Self.timers(at: $0), texts: texts) }
    completion(Timeline(entries: entries, policy: .never))
  }
}

struct NowWidgetView: View {
  @Environment(\.widgetFamily) var family
  let entry: NowEntry

  var body: some View {
    switch family {
    case .accessoryInline:
      Group {
        if let t = entry.timers.first {
          Text("\(t.emoji) \(t.since, style: .timer)")
        } else {
          Text(entry.texts.empty)
        }
      }
      .modifier(AccessoryBackground())
    case .accessoryRectangular:
      VStack(alignment: .leading, spacing: 1) {
        if let t = entry.timers.first {
          Text("\(t.emoji) \(t.title)").font(.headline).lineLimit(1).widgetAccentable()
          Text(t.since, style: .timer).font(.title3.monospacedDigit())
          if entry.timers.count > 1 { Text(String(format: entry.texts.count, entry.timers.count)).font(.caption2) }
        } else {
          Text(entry.texts.title).font(.headline).widgetAccentable()
          Text(entry.texts.empty).font(.caption).lineLimit(2)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .modifier(AccessoryBackground())
    default:
      VStack(alignment: .leading, spacing: 6) {
        HStack(alignment: .firstTextBaseline) {
          Text(entry.texts.title).font(.headline).foregroundColor(.hallyCherry)
          Spacer(minLength: 4)
          if !entry.timers.isEmpty, family != .systemSmall {
            Text(String(format: entry.texts.count, entry.timers.count)).font(.caption).foregroundColor(.secondary)
          }
        }
        if entry.timers.isEmpty {
          Text(entry.texts.empty).font(.subheadline).foregroundColor(.secondary)
        } else if family == .systemSmall, let t = entry.timers.first {
          Text("\(t.emoji) \(t.title)").font(.subheadline).lineLimit(2)
          Text(t.since, style: .timer).font(.title2.weight(.semibold).monospacedDigit())
          StopButton(timer: t, label: entry.texts.stop)
        } else {
          ForEach(Array(entry.timers.prefix(3)), id: \.self) { t in
            HStack(spacing: 8) {
              Text(t.emoji)
              VStack(alignment: .leading, spacing: 0) {
                Text(t.title).font(.subheadline).lineLimit(1)
                Text(t.since, style: .timer).font(.caption.monospacedDigit()).foregroundColor(.secondary)
              }
              Spacer(minLength: 4)
              StopButton(timer: t, label: entry.texts.stop)
            }
          }
        }
        Spacer(minLength: 0)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .hallyWidgetBackground()
    }
  }
}

/// Durdur: a button from iOS 17 on; before that the widget only shows the clocks.
struct StopButton: View {
  let timer: NowTimer
  let label: String

  var body: some View {
    if #available(iOS 17.0, *) {
      Button(intent: StopTimerIntent(type: timer.type, familyId: timer.familyId, childId: timer.childId)) {
        Text(label).font(.caption.weight(.semibold))
      }
      .tint(.hallyCherry)
    }
  }
}
