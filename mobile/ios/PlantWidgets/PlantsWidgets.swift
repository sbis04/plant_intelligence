import SwiftUI
import WidgetKit

private struct GardenWidgetEntry: TimelineEntry {
  let date: Date
  let snapshot: GardenSnapshot
}

private struct GardenWidgetProvider: TimelineProvider {
  func placeholder(in context: Context) -> GardenWidgetEntry {
    GardenWidgetEntry(date: Date(), snapshot: .placeholder)
  }

  func getSnapshot(in context: Context, completion: @escaping @Sendable (GardenWidgetEntry) -> Void)
  {
    if context.isPreview {
      completion(placeholder(in: context))
      return
    }
    Task {
      completion(GardenWidgetEntry(date: Date(), snapshot: await GardenSnapshotService.fetch()))
    }
  }

  func getTimeline(
    in context: Context,
    completion: @escaping @Sendable (Timeline<GardenWidgetEntry>) -> Void
  ) {
    Task {
      let entry = GardenWidgetEntry(date: Date(), snapshot: await GardenSnapshotService.fetch())
      let nextUpdate = Calendar.current.date(byAdding: .minute, value: 15, to: Date())!
      completion(Timeline(entries: [entry], policy: .after(nextUpdate)))
    }
  }
}

private struct GardenWidgetView: View {
  @Environment(\.widgetFamily) private var family
  let entry: GardenWidgetEntry

  var body: some View {
    Group {
      switch family {
      case .systemMedium:
        medium
      case .accessoryCircular:
        circular
      case .accessoryRectangular:
        rectangular
      case .accessoryInline:
        inline
      default:
        small
      }
    }
    .containerBackground(for: .widget) {
      LinearGradient(
        colors: [
          Color(red: 0.08, green: 0.17, blue: 0.12),
          Color(red: 0.035, green: 0.06, blue: 0.05),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
    }
  }

  private var snapshot: GardenSnapshot { entry.snapshot }
  private var accent: Color { Color(red: 0.30, green: 0.73, blue: 0.42) }

  private var statusColor: Color {
    if !snapshot.isLive { return .red }
    if snapshot.isWatering { return .cyan }
    if snapshot.waterNow { return .blue }
    return accent
  }

  private var small: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Image(systemName: snapshot.statusSymbol)
          .font(.title2.weight(.semibold))
          .foregroundStyle(statusColor)
        Spacer()
        Circle()
          .fill(snapshot.isLive ? accent : Color.red)
          .frame(width: 7, height: 7)
      }
      Spacer(minLength: 0)
      Text(snapshot.statusTitle)
        .font(.headline)
        .lineLimit(2)
        .minimumScaleFactor(0.82)
        .fixedSize(horizontal: false, vertical: true)
      Text(snapshot.nextWateringShort)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(2)
      if let locationName = snapshot.locationName, snapshot.isLive {
        Label(locationName, systemImage: "location.fill")
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    }
  }

  private var medium: some View {
    HStack(spacing: 16) {
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 8) {
          ZStack {
            Circle().fill(statusColor.opacity(0.16))
            Image(systemName: snapshot.statusSymbol)
              .foregroundStyle(statusColor)
          }
          .frame(width: 38, height: 38)
          Text("Plants")
            .font(.headline)
          Spacer()
        }
        Spacer(minLength: 0)
        Text(snapshot.statusTitle)
          .font(.headline)
          .lineLimit(2)
          .minimumScaleFactor(0.82)
          .fixedSize(horizontal: false, vertical: true)
        Text(snapshot.nextWateringShort)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Divider().overlay(Color.white.opacity(0.08))
      VStack(spacing: 8) {
        metric("Outside", snapshot.outsideTemperatureText, "thermometer.medium")
        metric("Soil", snapshot.soilText, "drop.degreesign")
        metric("Weather", snapshot.rainText, "cloud.rain")
      }
      .frame(width: 112)
    }
  }

  private func metric(_ label: String, _ value: String, _ symbol: String) -> some View {
    HStack(spacing: 7) {
      Image(systemName: symbol)
        .font(.caption)
        .foregroundStyle(accent)
        .frame(width: 16)
      VStack(alignment: .leading, spacing: 0) {
        Text(label.uppercased())
          .font(.system(size: 8, weight: .semibold))
          .foregroundStyle(.secondary)
        Text(value)
          .font(.caption.weight(.semibold))
          .lineLimit(1)
      }
      Spacer(minLength: 0)
    }
  }

  private var circular: some View {
    ZStack {
      AccessoryWidgetBackground()
      if snapshot.isWatering {
        Gauge(value: snapshot.wateringProgress) {
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
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    }
  }

  private var inline: some View {
    Label(
      snapshot.statusTitle + " · " + snapshot.nextWateringShort,
      systemImage: snapshot.statusSymbol)
  }
}

private struct GardenStatusWidget: Widget {
  let kind = "GardenStatusWidget"

  var body: some WidgetConfiguration {
    StaticConfiguration(kind: kind, provider: GardenWidgetProvider()) { entry in
      GardenWidgetView(entry: entry)
    }
    .configurationDisplayName("Plants Status")
    .description("See watering, weather, and sensor status at a glance.")
    .supportedFamilies([
      .systemSmall, .systemMedium,
      .accessoryCircular, .accessoryRectangular, .accessoryInline,
    ])
  }
}

private struct GardenStatsWidgetView: View {
  let entry: GardenWidgetEntry

  private var snapshot: GardenSnapshot { entry.snapshot }
  private let accent = Color(red: 0.30, green: 0.73, blue: 0.42)

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      stat("Outside", snapshot.outsideTemperatureText, "thermometer.medium")
      stat("Soil", snapshot.soilText, "drop.degreesign")
      stat("Next watering", nextWateringText, "calendar.badge.clock")
    }
    .overlay(alignment: .topTrailing) {
      if snapshot.fanOn == true {
        Image(systemName: "fan.fill")
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(accent)
          .accessibilityLabel("Fan running")
      }
    }
    .containerBackground(for: .widget) {
      LinearGradient(
        colors: [
          Color(red: 0.08, green: 0.17, blue: 0.12),
          Color(red: 0.035, green: 0.06, blue: 0.05),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
    }
  }

  private func stat(_ label: String, _ value: String, _ symbol: String) -> some View {
    HStack(spacing: 9) {
      Image(systemName: symbol)
        .font(.subheadline)
        .foregroundStyle(accent)
        .frame(width: 20)
      VStack(alignment: .leading, spacing: 0) {
        Text(label.uppercased())
          .font(.system(size: 9, weight: .semibold))
          .foregroundStyle(.secondary)
        Text(value)
          .font(.subheadline.weight(.semibold))
          .lineLimit(1)
          .minimumScaleFactor(0.7)
      }
      Spacer(minLength: 0)
    }
  }

  private var nextWateringText: String {
    if snapshot.waterNow { return "Due now" }
    guard let next = snapshot.nextWateringAt else { return "Not planned" }
    return next.formatted(.dateTime.day().month(.abbreviated)) + " · "
      + next.formatted(date: .omitted, time: .shortened)
  }
}

private struct GardenStatsWidget: Widget {
  let kind = "GardenStatsWidget"

  var body: some WidgetConfiguration {
    StaticConfiguration(kind: kind, provider: GardenWidgetProvider()) { entry in
      GardenStatsWidgetView(entry: entry)
    }
    .configurationDisplayName("Plants Conditions")
    .description("See temperature, soil, and the next watering at a glance.")
    .supportedFamilies([.systemSmall])
  }
}

@main
struct PlantsWidgetBundle: WidgetBundle {
  var body: some Widget {
    GardenStatusWidget()
    GardenStatsWidget()
  }
}
