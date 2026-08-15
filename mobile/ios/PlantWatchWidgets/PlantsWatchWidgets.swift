import SwiftUI
import WidgetKit

private struct WatchGardenEntry: TimelineEntry {
  let date: Date
  let snapshot: GardenSnapshot
}

private struct WatchGardenProvider: TimelineProvider {
  func placeholder(in context: Context) -> WatchGardenEntry {
    WatchGardenEntry(date: Date(), snapshot: .placeholder)
  }

  func getSnapshot(in context: Context, completion: @escaping @Sendable (WatchGardenEntry) -> Void)
  {
    if context.isPreview {
      completion(placeholder(in: context))
      return
    }
    Task {
      completion(WatchGardenEntry(date: Date(), snapshot: await GardenSnapshotService.fetch()))
    }
  }

  func getTimeline(
    in context: Context,
    completion: @escaping @Sendable (Timeline<WatchGardenEntry>) -> Void
  ) {
    Task {
      let entry = WatchGardenEntry(date: Date(), snapshot: await GardenSnapshotService.fetch())
      let nextUpdate = Calendar.current.date(byAdding: .minute, value: 15, to: Date())!
      completion(Timeline(entries: [entry], policy: .after(nextUpdate)))
    }
  }
}

private struct WatchGardenWidgetView: View {
  @Environment(\.widgetFamily) private var family
  let entry: WatchGardenEntry

  var body: some View {
    switch family {
    case .accessoryCircular:
      circular
    case .accessoryInline:
      inline
    default:
      rectangular
    }
  }

  private var snapshot: GardenSnapshot { entry.snapshot }

  private var circular: some View {
    ZStack {
      AccessoryWidgetBackground()
      if snapshot.isWatering {
        Gauge(value: snapshot.wateringProgress) {
          Image(systemName: "drop.fill")
        } currentValueLabel: {
          Image(systemName: "drop.fill")
        }
        .gaugeStyle(.accessoryCircularCapacity)
      } else {
        Image(systemName: snapshot.statusSymbol)
          .font(.title3.weight(.semibold))
          .widgetAccentable()
      }
    }
  }

  private var rectangular: some View {
    HStack(spacing: 8) {
      Image(systemName: snapshot.statusSymbol)
        .font(.title2)
        .widgetAccentable()
      VStack(alignment: .leading, spacing: 1) {
        Text(snapshot.statusTitle)
          .font(.headline)
          .lineLimit(1)
        Text(snapshot.nextWateringShort)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        if snapshot.isLive {
          Text(snapshot.outsideTemperatureText + " · " + snapshot.rainText)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
    }
  }

  private var inline: some View {
    Label(
      snapshot.statusTitle + " · " + snapshot.nextWateringShort,
      systemImage: snapshot.statusSymbol)
  }
}

private struct WatchGardenStatusWidget: Widget {
  let kind = "WatchGardenStatusWidget"

  var body: some WidgetConfiguration {
    StaticConfiguration(kind: kind, provider: WatchGardenProvider()) { entry in
      WatchGardenWidgetView(entry: entry)
    }
    .configurationDisplayName("Plants Status")
    .description("See the next watering and current garden conditions.")
    .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
  }
}

@main
struct PlantsWatchWidgetBundle: WidgetBundle {
  var body: some Widget {
    WatchGardenStatusWidget()
  }
}
