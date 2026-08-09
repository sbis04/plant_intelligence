import SwiftUI

struct ActivityView: View {
    @Environment(AppState.self) private var app
    @State private var section: Section = .waterings

    enum Section: String, CaseIterable, Identifiable {
        case waterings = "Waterings"
        case log = "System log"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    HStack {
                        Text("Activity")
                            .font(.largeTitle.weight(.bold))
                        Spacer()
                    }
                    .padding(.top, 8)

                    Picker("Section", selection: $section) {
                        ForEach(Section.allCases) { s in
                            Text(s.rawValue).tag(s)
                        }
                    }
                    .pickerStyle(.segmented)

                    switch section {
                    case .waterings: wateringList
                    case .log: logList
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 80)
            }
            .background(GardenBackground())
            .topEdgeFade()
            .refreshable { await app.refreshActivity() }
            .task { await app.refreshActivity() }
        }
    }

    private var wateringList: some View {
        PanelCard {
            if app.history.isEmpty {
                Text("No waterings recorded yet.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textMuted)
            }
            ForEach(app.history) { event in
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: "drop.fill")
                        .font(.caption)
                        .foregroundStyle(triggerColor(event.trigger))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.startDate?.formatted(
                            date: .abbreviated, time: .shortened) ?? event.waterStartedAt)
                            .font(.subheadline.weight(.medium))
                        if let reason = event.reason, !reason.isEmpty {
                            Text(reason)
                                .font(.caption)
                                .foregroundStyle(Theme.textMuted)
                                .lineLimit(2)
                        }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(event.minutes.map { "\($0) min" } ?? "running")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(event.minutes == nil ? Theme.accent : .primary)
                        Text(event.trigger)
                            .font(.caption2)
                            .foregroundStyle(triggerColor(event.trigger))
                    }
                }
                .padding(.vertical, 4)
                if event != app.history.last {
                    Divider().overlay(Theme.line)
                }
            }
        }
    }

    private var logList: some View {
        PanelCard {
            if app.logs.isEmpty {
                Text("No log entries.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textMuted)
            }
            ForEach(app.logs) { entry in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(entry.date?.formatted(date: .omitted, time: .shortened)
                         ?? "–")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Theme.textMuted)
                        .frame(width: 64, alignment: .leading)
                    Text(entry.message)
                        .font(.caption)
                        .foregroundStyle(entry.isError ? Theme.err : .primary)
                    Spacer()
                    Text(entry.eventType)
                        .font(.caption2)
                        .foregroundStyle(Theme.textMuted)
                }
                .padding(.vertical, 3)
                if entry != app.logs.last {
                    Divider().overlay(Theme.line)
                }
            }
        }
    }

    private func triggerColor(_ trigger: String) -> Color {
        switch trigger {
        case "manual": .blue
        case "failsafe": Theme.warn
        default: Theme.accent
        }
    }
}
