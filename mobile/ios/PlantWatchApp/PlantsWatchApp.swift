import Observation
import SwiftUI
import WidgetKit

@main
struct PlantsWatchApp: App {
  @State private var garden = WatchGardenModel()

  var body: some Scene {
    WindowGroup {
      WatchDashboardView()
        .environment(garden)
    }
  }
}

@MainActor
@Observable
private final class WatchGardenModel {
  var snapshot = SharedGardenStore.load() ?? .offline
  var busy = false

  func refresh() async {
    snapshot = await GardenSnapshotService.fetch()
  }

  func water() async {
    await perform { client in try await client.water() }
  }

  func stop() async {
    await perform { client in try await client.stop() }
  }

  private func perform(_ action: (HubClient) async throws -> SimpleResponse) async {
    guard !busy, let client = HubClient(address: SharedGardenStore.hubAddress) else { return }
    busy = true
    _ = try? await action(client)
    snapshot = await GardenSnapshotService.fetch()
    WidgetCenter.shared.reloadAllTimelines()
    busy = false
  }
}

private struct WatchDashboardView: View {
  @Environment(WatchGardenModel.self) private var garden
  @State private var confirmWater = false
  @State private var scrolled = false

  private let accent = Color(red: 0.30, green: 0.73, blue: 0.42)
  private let panel = Color(red: 0.102, green: 0.141, blue: 0.125)
  private let line = Color(red: 0.165, green: 0.220, blue: 0.188)
  private let muted = Color(red: 0.561, green: 0.639, blue: 0.596)

  var body: some View {
    ScrollView {
      VStack(spacing: 9) {
        header
        hero
        metrics
        wateringCard
        action
        if !garden.snapshot.isLive {
          Text("Connect the watch to the same Wi-Fi as the hub.")
            .font(.caption2)
            .foregroundStyle(muted)
            .multilineTextAlignment(.center)
        }
      }
      .padding(.horizontal, 5)
      .padding(.bottom, 8)
    }
    .background {
      LinearGradient(
        stops: [
          .init(color: Color(red: 0.075, green: 0.125, blue: 0.098), location: 0),
          .init(color: Color(red: 0.063, green: 0.086, blue: 0.075), location: 0.45),
          .init(color: Color(red: 0.043, green: 0.059, blue: 0.051), location: 1),
        ],
        startPoint: .top,
        endPoint: .bottom
      )
      .overlay(alignment: .topTrailing) {
        Circle()
          .fill(accent.opacity(0.12))
          .frame(width: 150, height: 150)
          .blur(radius: 50)
          .offset(x: 45, y: -55)
      }
      .ignoresSafeArea()
    }
    .onScrollGeometryChange(for: Bool.self) { geometry in
      geometry.contentOffset.y + geometry.contentInsets.top > 8
    } action: { _, isScrolled in
      withAnimation(.easeInOut(duration: 0.18)) { scrolled = isScrolled }
    }
    .overlay(alignment: .top) {
      Color(red: 0.043, green: 0.059, blue: 0.051)
        .frame(height: 54)
        .mask(
          LinearGradient(
            colors: [.black, .black.opacity(0.82), .clear],
            startPoint: .top,
            endPoint: .bottom
          )
        )
        .ignoresSafeArea(edges: .top)
        .allowsHitTesting(false)
        .opacity(scrolled ? 1 : 0)
    }
    .task {
      while !Task.isCancelled {
        await garden.refresh()
        try? await Task.sleep(for: .seconds(15))
      }
    }
    .alert("Water the garden now?", isPresented: $confirmWater) {
      Button("Start watering") { Task { await garden.water() } }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("The hub still enforces its watering safety limits.")
    }
  }

  private var header: some View {
    HStack(alignment: .firstTextBaseline) {
      Text("Plants")
        .font(.title2.weight(.bold))
      Spacer()
      HStack(spacing: 5) {
        Circle()
          .fill(garden.snapshot.isLive ? accent : Color.red)
          .frame(width: 6, height: 6)
        Text(garden.snapshot.isLive ? "live" : "offline")
          .font(.caption2)
          .foregroundStyle(muted)
      }
    }
    .padding(.horizontal, 3)
    .padding(.top, 2)
  }

  private var hero: some View {
    HStack(spacing: 11) {
      ZStack {
        Circle()
          .fill(accent.opacity(0.16))
          .frame(width: 52, height: 52)
        if garden.snapshot.isWatering {
          Circle()
            .trim(from: 0, to: garden.snapshot.wateringProgress)
            .stroke(.cyan, style: StrokeStyle(lineWidth: 4, lineCap: .round))
            .frame(width: 52, height: 52)
            .rotationEffect(.degrees(-90))
        }
        Image(systemName: garden.snapshot.statusSymbol)
          .font(.title2)
          .foregroundStyle(garden.snapshot.isLive ? accent : .red)
      }
      VStack(alignment: .leading, spacing: 2) {
        Text(garden.snapshot.statusTitle)
          .font(.headline)
          .lineLimit(2)
          .minimumScaleFactor(0.8)
          .fixedSize(horizontal: false, vertical: true)
        Text(heroSubtitle)
          .font(.system(size: 9))
          .foregroundStyle(muted)
          .lineLimit(2)
        if let locationName = garden.snapshot.locationName, garden.snapshot.isLive {
          Label(locationName, systemImage: "location.fill")
            .font(.system(size: 8))
            .foregroundStyle(muted)
            .lineLimit(1)
        }
      }
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity)
    .padding(11)
    .background(panel, in: .rect(cornerRadius: 17))
    .overlay(RoundedRectangle(cornerRadius: 17).strokeBorder(line, lineWidth: 1))
  }

  private var metrics: some View {
    LazyVGrid(
      columns: [GridItem(.flexible(), spacing: 7), GridItem(.flexible())],
      spacing: 7
    ) {
      watchMetric("Soil", garden.snapshot.soilText, nil)
      watchMetric("Outside", garden.snapshot.outsideTemperatureText, outsideDetail)
      watchMetric("Box", boxTemperatureText, nil)
      watchMetric("MCU link", mcuLinkText, "last heartbeat")
    }
  }

  private func watchMetric(_ label: String, _ value: String, _ detail: String?) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(label.uppercased())
        .font(.system(size: 7, weight: .semibold))
        .kerning(0.5)
        .foregroundStyle(muted)
      Text(value)
        .font(value.count > 10 ? .caption.weight(.semibold) : .subheadline.weight(.semibold))
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.5)
        .allowsTightening(true)
      Text(detail ?? "\u{00A0}")
        .font(.system(size: 8))
        .foregroundStyle(muted)
        .lineLimit(1)
        .accessibilityHidden(detail == nil)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(10)
    .background(panel, in: .rect(cornerRadius: 14))
    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(line, lineWidth: 1))
  }

  private var wateringCard: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("NEXT WATERING")
        .font(.system(size: 8, weight: .semibold))
        .kerning(0.7)
        .foregroundStyle(muted)
      Text(nextWateringDateText)
        .font(.subheadline.weight(.semibold))
      if garden.snapshot.rainHold {
        Label("Rain is pausing the schedule", systemImage: "cloud.rain.fill")
          .font(.system(size: 9))
          .foregroundStyle(muted)
      } else if let description = garden.snapshot.weatherDescription,
        garden.snapshot.isLive
      {
        Text(description)
          .font(.system(size: 9))
          .foregroundStyle(muted)
          .lineLimit(2)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(11)
    .background(panel, in: .rect(cornerRadius: 15))
    .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(line, lineWidth: 1))
  }

  @ViewBuilder
  private var action: some View {
    if garden.snapshot.isWatering {
      Button {
        Task { await garden.stop() }
      } label: {
        Label("Stop watering", systemImage: "stop.fill")
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.glassProminent)
      .tint(.red)
      .disabled(garden.busy)
    } else {
      Button {
        confirmWater = true
      } label: {
        Label(
          garden.snapshot.rainHold ? "Water anyway" : "Water now",
          systemImage: "drop.fill"
        )
        .frame(maxWidth: .infinity)
      }
      .buttonStyle(.glassProminent)
      .tint(accent)
      .disabled(!garden.snapshot.isLive || garden.busy)
    }
  }

  private var heroSubtitle: String {
    guard garden.snapshot.isLive else { return "check the hub connection" }
    if garden.snapshot.isWatering { return "stop anytime below" }
    guard let next = garden.snapshot.nextWateringAt else {
      return garden.snapshot.waterNow ? "starting shortly" : "no watering planned yet"
    }
    return "Next watering \(next.formatted(.relative(presentation: .named))) · "
      + next.formatted(date: .omitted, time: .shortened)
  }

  private var nextWateringDateText: String {
    if garden.snapshot.waterNow { return "Due now" }
    guard let next = garden.snapshot.nextWateringAt else { return "–" }
    return next.formatted(date: .abbreviated, time: .shortened)
  }

  private var outsideDetail: String? {
    garden.snapshot.outsideHumidityPct.map { "humidity \(Int($0.rounded()))%" }
  }

  private var boxTemperatureText: String {
    garden.snapshot.boxTemperatureC.map { String(format: "%.1f°C", $0) }
      ?? "Not connected"
  }

  private var mcuLinkText: String {
    garden.snapshot.mcuSeenSecondsAgo.map { String(format: "%.0fs", $0) } ?? "–"
  }
}
