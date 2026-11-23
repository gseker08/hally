import SwiftUI
import WidgetKit

/// "Bugün": the next events and tasks of today. The app saves today's list whenever Today loads
/// (lib/features/home/today_widget.dart). Timed items leave 15 minutes after they start, so the widget stays right
/// while the app is closed; a list from an earlier day is never shown, the widget asks to open the app instead.
struct TodayWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: HallyShared.todayWidgetKind, provider: TodayProvider()) { entry in
      TodayWidgetView(entry: entry)
    }
    .configurationDisplayName("Hally")
    .description(TodayTexts.load().title)
    .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular, .accessoryInline])
  }
}

struct TodayRow: Hashable {
  let time: String
  let title: String
}

struct TodayTexts {
  var title = "Bugün"
  var empty = "Bugün için başka plan yok"
  var stale = "Bugünü görmek için Hally'yi aç"
  var allDay = "Gün boyu"
  var task = "Görev"
  var more = "+%d daha"
  var lang = "tr"

  static func load() -> TodayTexts {
    var t = TodayTexts()
    if let s = HallyShared.string("today.title") { t.title = s }
    if let s = HallyShared.string("today.empty") { t.empty = s }
    if let s = HallyShared.string("today.stale") { t.stale = s }
    if let s = HallyShared.string("today.allDay") { t.allDay = s }
    if let s = HallyShared.string("today.taskMark") { t.task = s }
    if let s = HallyShared.string("today.more") { t.more = s }
    if let s = HallyShared.string("today.lang") { t.lang = s }
    return t
  }
}

struct TodayEntry: TimelineEntry {
  let date: Date
  /// False when the saved list is from an earlier day (or there is none).
  let fresh: Bool
  let rows: [TodayRow]
  let texts: TodayTexts
}

private let grace: TimeInterval = 15 * 60

struct TodayProvider: TimelineProvider {
  func placeholder(in context: Context) -> TodayEntry {
    TodayEntry(date: Date(), fresh: true, rows: [TodayRow(time: "09:00", title: "…"), TodayRow(time: "16:30", title: "…")], texts: TodayTexts())
  }

  func getSnapshot(in context: Context, completion: @escaping (TodayEntry) -> Void) {
    completion(context.isPreview ? placeholder(in: context) : entry(at: Date()))
  }

  /// An entry now, one each time a timed item drops off, and one just after midnight (then the day is stale until
  /// the app saves the new day).
  func getTimeline(in context: Context, completion: @escaping (Timeline<TodayEntry>) -> Void) {
    let now = Date()
    let midnight = Calendar.current.startOfDay(for: now).addingTimeInterval(24 * 3600 + 60)
    var moments: Set<Date> = [now, midnight]
    for item in HallyShared.list("today.items") {
      if let at = HallyShared.date(item["at"]), at + grace > now, at + grace < midnight { moments.insert(at + grace) }
    }
    let entries = moments.sorted().map { entry(at: $0) }
    completion(Timeline(entries: entries, policy: .after(midnight)))
  }

  func entry(at date: Date) -> TodayEntry {
    let texts = TodayTexts.load()
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd"
    let fresh = HallyShared.string("today.day") == f.string(from: date)
    var rows: [TodayRow] = []
    if fresh {
      for item in HallyShared.list("today.items") {
        let title = item["title"] as? String ?? ""
        if let at = HallyShared.date(item["at"]) {
          if at + grace > date { rows.append(TodayRow(time: hallyClock(at), title: title)) }
        } else {
          rows.append(TodayRow(time: (item["kind"] as? String) == "task" ? texts.task : texts.allDay, title: title))
        }
      }
    }
    return TodayEntry(date: date, fresh: fresh, rows: rows, texts: texts)
  }
}

struct TodayWidgetView: View {
  @Environment(\.widgetFamily) var family
  let entry: TodayEntry

  private var limit: Int {
    switch family {
    case .systemSmall: return 2
    case .systemLarge: return 7
    default: return 3
    }
  }

  private var message: String? {
    if !entry.fresh { return entry.texts.stale }
    if entry.rows.isEmpty { return entry.texts.empty }
    if entry.rows.count > limit { return String(format: entry.texts.more, entry.rows.count - limit) }
    return nil
  }

  private var dateLine: String {
    let f = DateFormatter()
    f.locale = Locale(identifier: entry.texts.lang)
    f.setLocalizedDateFormatFromTemplate(family == .systemSmall ? "dMMMEEE" : "dMMMMEEEE")
    return f.string(from: entry.date)
  }

  var body: some View {
    switch family {
    case .accessoryInline:
      Group {
        if let first = entry.rows.first, entry.fresh {
          Text("\(first.time) \(first.title)")
        } else {
          Text(message ?? entry.texts.title)
        }
      }
      .modifier(AccessoryBackground())
    case .accessoryRectangular:
      VStack(alignment: .leading, spacing: 1) {
        Text(entry.texts.title).font(.headline).widgetAccentable()
        if entry.fresh, !entry.rows.isEmpty {
          ForEach(Array(entry.rows.prefix(2)), id: \.self) { row in
            Text("\(row.time) \(row.title)").font(.caption).lineLimit(1)
          }
        } else {
          Text(message ?? "").font(.caption).lineLimit(2)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .modifier(AccessoryBackground())
    default:
      VStack(alignment: .leading, spacing: 6) {
        HStack(alignment: .firstTextBaseline) {
          Text(entry.texts.title).font(.headline).foregroundColor(.hallyCherry)
          Spacer(minLength: 4)
          Text(dateLine).font(.caption).foregroundColor(.secondary).lineLimit(1)
        }
        ForEach(Array(entry.rows.prefix(limit)), id: \.self) { row in
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(row.time).font(.caption.weight(.semibold)).foregroundColor(.hallyCherry).frame(minWidth: 38, alignment: .leading)
            Text(row.title).font(.subheadline).lineLimit(1)
          }
        }
        if let message {
          Text(message).font(.caption).foregroundColor(.secondary).lineLimit(2)
        }
        Spacer(minLength: 0)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .hallyWidgetBackground()
    }
  }
}

/// Lock screen widgets sit on the wallpaper; iOS 17 still wants a declared (empty) background.
struct AccessoryBackground: ViewModifier {
  func body(content: Content) -> some View {
    if #available(iOS 17.0, *) {
      content.containerBackground(for: .widget) { Color.clear }
    } else {
      content
    }
  }
}
