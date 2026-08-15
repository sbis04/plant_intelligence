import ActivityKit
import SwiftUI
import WidgetKit

/// The watering card: lock screen, Dynamic Island, and the compact glances.
/// The countdown is a `Text(timerInterval:)`, so it runs on its own — the
/// hub only pushes on start and end.
struct WateringLiveActivity: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: WateringAttributes.self) { context in
      lockScreen(context)
        .activityBackgroundTint(Color(red: 0.055, green: 0.098, blue: 0.078))
        .activitySystemActionForegroundColor(accent)
    } dynamicIsland: { context in
      DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          Label {
            Text(context.attributes.locationName)
              .font(.caption)
              .foregroundStyle(.secondary)
          } icon: {
            Image(systemName: "drop.fill").foregroundStyle(accent)
          }
        }
        DynamicIslandExpandedRegion(.trailing) {
          countdown(context)
            .font(.title3.weight(.semibold).monospacedDigit())
            .foregroundStyle(accent)
        }
        DynamicIslandExpandedRegion(.bottom) {
          VStack(alignment: .leading, spacing: 6) {
            progress(context)
            Text(subtitle(context))
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }
      } compactLeading: {
        Image(systemName: "drop.fill").foregroundStyle(accent)
      } compactTrailing: {
        countdown(context)
          .font(.caption.monospacedDigit())
          .foregroundStyle(accent)
          .frame(maxWidth: 44)
      } minimal: {
        Image(systemName: "drop.fill").foregroundStyle(accent)
      }
      .keylineTint(accent)
    }
  }

  // MARK: pieces

  private var accent: Color { Color(red: 0.298, green: 0.725, blue: 0.420) }
  private var water: Color { Color(red: 0.24, green: 0.74, blue: 0.96) }

  private func lockScreen(_ context: ActivityViewContext<WateringAttributes>)
    -> some View
  {
    HStack(spacing: 14) {
      ZStack {
        Circle().fill(water.opacity(0.16)).frame(width: 52, height: 52)
        Image(systemName: context.state.finished ? "checkmark" : "drop.fill")
          .font(.system(size: 22))
          .foregroundStyle(water)
          .symbolEffect(.pulse, isActive: !context.state.finished)
      }
      VStack(alignment: .leading, spacing: 4) {
        Text(context.state.finished ? "Watering finished" : "Watering the garden")
          .font(.headline)
        Text(subtitle(context))
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
        if !context.state.finished {
          progress(context)
        }
      }
      Spacer(minLength: 4)
      if !context.state.finished {
        countdown(context)
          .font(.title2.weight(.semibold).monospacedDigit())
          .foregroundStyle(water)
      }
    }
    .padding(16)
  }

  private func countdown(_ context: ActivityViewContext<WateringAttributes>)
    -> some View
  {
    // Ticks by itself: no push needed while the water runs.
    Text(timerInterval: Date()...max(context.state.endsAt, Date().addingTimeInterval(1)),
         countsDown: true)
      .multilineTextAlignment(.trailing)
  }

  private func progress(_ context: ActivityViewContext<WateringAttributes>)
    -> some View
  {
    let total = max(Double(context.state.totalSeconds), 1)
    let start = context.state.endsAt.addingTimeInterval(-total)
    return ProgressView(timerInterval: start...context.state.endsAt, countsDown: false) {
      EmptyView()
    } currentValueLabel: {
      EmptyView()
    }
    .progressViewStyle(.linear)
    .tint(water)
  }

  private func subtitle(_ context: ActivityViewContext<WateringAttributes>) -> String {
    if context.state.finished { return context.attributes.locationName }
    if !context.state.note.isEmpty { return context.state.note }
    let label = context.state.triggerLabel
    return label.isEmpty ? context.attributes.locationName
      : "\(label) · \(context.attributes.locationName)"
  }
}
