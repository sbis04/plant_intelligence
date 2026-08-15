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
          HStack(spacing: 6) {
            activitySymbol(context, size: 24, iconSize: 11)
            Text(context.state.finished ? "Watered" : "Watering")
              .font(.caption.weight(.semibold))
              .lineLimit(1)
          }
          .padding(.leading, 4)
        }
        DynamicIslandExpandedRegion(.trailing) {
          countdown(context)
            .font(.title3.weight(.semibold).monospacedDigit())
            .foregroundStyle(water)
            .padding(.trailing, 6)
        }
        DynamicIslandExpandedRegion(.bottom) {
          VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
              Label(context.attributes.locationName, systemImage: "location.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
              Spacer(minLength: 8)
              Text(statusLabel(context))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(accent)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(accent.opacity(0.14), in: Capsule())
            }
            if !context.state.finished {
              progress(context)
              Text("Ends \(context.state.endsAt, style: .time)")
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
          }
          .padding(.top, 2)
          .padding(.horizontal, 6)
        }
      } compactLeading: {
        activitySymbol(context, size: 24, iconSize: 11)
      } compactTrailing: {
        countdown(context)
          .font(.caption.weight(.semibold).monospacedDigit())
          .foregroundStyle(water)
          .frame(width: 44, alignment: .trailing)
      } minimal: {
        activitySymbol(context, size: 24, iconSize: 11)
      }
      .keylineTint(water)
    }
  }

  // MARK: pieces

  private var accent: Color { Color(red: 0.298, green: 0.725, blue: 0.420) }
  private var water: Color { Color(red: 0.24, green: 0.74, blue: 0.96) }

  private func lockScreen(_ context: ActivityViewContext<WateringAttributes>)
    -> some View
  {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 12) {
        activitySymbol(context, size: 48, iconSize: 20)
        VStack(alignment: .leading, spacing: 3) {
          Text(context.state.finished ? "Watering complete" : "Watering plants")
            .font(.headline)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
          HStack(spacing: 5) {
            Image(systemName: "location.fill")
            Text(context.attributes.locationName)
              .lineLimit(1)
              .minimumScaleFactor(0.72)
          }
          .font(.subheadline)
          .foregroundStyle(.secondary)
        }
        .layoutPriority(1)
        Spacer(minLength: 8)
        VStack(alignment: .trailing, spacing: 1) {
          countdown(context)
            .font(.title2.weight(.semibold).monospacedDigit())
            .foregroundStyle(context.state.finished ? accent : water)
          if !context.state.finished {
            Text("remaining")
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
        }
      }
      if !context.state.finished {
        progress(context)
        HStack {
          Label(statusLabel(context), systemImage: triggerSymbol(context))
          Spacer(minLength: 12)
          Text("Ends \(context.state.endsAt, style: .time)")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 15)
  }

  private func countdown(_ context: ActivityViewContext<WateringAttributes>)
    -> some View
  {
    Group {
      if context.state.finished {
        Text("Done")
      } else {
        // Ticks by itself: no push needed while the water runs.
        Text(
          timerInterval:
            Date()...max(
              context.state.endsAt, Date().addingTimeInterval(1)),
          countsDown: true)
      }
    }
    .lineLimit(1)
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

  private func activitySymbol(
    _ context: ActivityViewContext<WateringAttributes>,
    size: CGFloat,
    iconSize: CGFloat
  ) -> some View {
    ZStack {
      Circle().fill((context.state.finished ? accent : water).opacity(0.16))
      Circle()
        .strokeBorder((context.state.finished ? accent : water).opacity(0.24), lineWidth: 1)
      Image(systemName: context.state.finished ? "checkmark" : "drop.fill")
        .font(.system(size: iconSize, weight: .semibold))
        .foregroundStyle(context.state.finished ? accent : water)
        .symbolEffect(.pulse, isActive: !context.state.finished)
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }

  private func statusLabel(_ context: ActivityViewContext<WateringAttributes>) -> String {
    if context.state.finished { return "Complete" }
    if !context.state.note.isEmpty { return context.state.note }
    let label = context.state.triggerLabel
    return label.isEmpty ? "In progress" : label
  }

  private func triggerSymbol(_ context: ActivityViewContext<WateringAttributes>) -> String {
    switch context.state.trigger {
    case "manual": "hand.tap.fill"
    case "failsafe": "shield.fill"
    default: "calendar.badge.clock"
    }
  }
}
