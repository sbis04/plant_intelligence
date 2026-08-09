import SwiftUI

/// The assistant lives as an overlay on the Plants tab (opened from the
/// detached sparkles button by the tab bar), blurring the dashboard behind
/// the transcript. The prompt box replaces the watering action bar while
/// it's open — see GardenView.
struct AssistantOverlay: View {
    @Environment(AppState.self) private var app

    private let suggestions = [
        "Why aren't you watering?",
        "When is the next watering?",
        "How's the weather looking?",
        "Summarize the last 24 hours",
    ]

    var body: some View {
        ZStack(alignment: .top) {
            // Blur the dashboard, then re-assert the app's dark botanical
            // gradient so the overlay stays moody whatever is behind it.
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()
            GardenBackground()
                .opacity(0.5)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        if app.messages.isEmpty {
                            emptyState
                        }
                        ForEach(app.messages) { msg in
                            bubble(msg)
                                .id(msg.id)
                        }
                        if app.assistantBusy {
                            ThinkingBubble()
                                .id("thinking")
                        }
                    }
                    .padding(16)
                    .padding(.top, 44)   // room for the control row
                }
                .defaultScrollAnchor(.bottom)
                .scrollDismissesKeyboard(.immediately)
                .onChange(of: app.messages.count) {
                    if let last = app.messages.last?.id {
                        withAnimation(.snappy) { proxy.scrollTo(last, anchor: .bottom) }
                    }
                }
            }

            controls
        }
        .task { await app.resumeThreads() }   // auto-open the last conversation
    }

    // MARK: pieces

    private var controls: some View {
        HStack {
            // Conversation history: switch, resume, or delete threads.
            Menu {
                ForEach(app.threads) { thread in
                    Button {
                        Task { await app.openThread(thread.id) }
                    } label: {
                        if thread.id == app.currentThreadId {
                            Label(thread.displayTitle, systemImage: "checkmark")
                        } else {
                            Text(thread.displayTitle)
                        }
                    }
                }
                if app.currentThreadId != 0 {
                    Divider()
                    Button("Delete conversation", role: .destructive) {
                        Task { await app.deleteCurrentThread() }
                    }
                }
            } label: {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.body.weight(.semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.glass)
            .disabled(app.assistantBusy || app.threads.isEmpty)
            Spacer()
            Button {
                app.newThread()
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.body.weight(.semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.glass)
            .disabled(app.assistantBusy || app.messages.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "sparkles")
                .font(.system(size: 40))
                .foregroundStyle(Theme.accent)
            Text("Ask your garden anything")
                .font(.headline)
            Text("Grounded in live access to every sensor, plan and log. Runs on the UNO Q itself — or via a cloud model when one is configured in Settings.")
                .font(.subheadline)
                .foregroundStyle(Theme.textMuted)
                .multilineTextAlignment(.center)
            VStack(spacing: 8) {
                ForEach(suggestions, id: \.self) { s in
                    Button {
                        Task { await app.ask(s) }
                    } label: {
                        Text(s)
                            .font(.subheadline)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.glass)
                }
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    private func bubble(_ msg: ChatMessage) -> some View {
        HStack {
            if msg.role == .user { Spacer(minLength: 48) }
            VStack(alignment: .leading, spacing: 8) {
                if let url = msg.attachmentURL {
                    // Thumbnail-sized but never cropped: fit inside a small
                    // box at the photo's own aspect ratio, leading-aligned.
                    AsyncImage(url: url) { image in
                        image.resizable().scaledToFit()
                            .clipShape(.rect(cornerRadius: 8))
                    } placeholder: {
                        RoundedRectangle(cornerRadius: 8).fill(Theme.line)
                            .frame(width: 56, height: 42)
                    }
                    .frame(maxWidth: 110, maxHeight: 82, alignment: .leading)
                }
                Text(msg.text)
                    .font(.subheadline)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                msg.role == .user ? Theme.accent : Theme.panel,
                in: .rect(cornerRadius: 16)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(msg.role == .user ? .clear : Theme.line, lineWidth: 1)
            )
            .foregroundStyle(msg.role == .user ? Theme.bgDeep : .primary)
            if msg.role == .assistant { Spacer(minLength: 48) }
        }
    }
}

/// Animated "the model is generating" indicator — worth having because
/// on-device generation legitimately takes a minute or two. Reads the
/// backend from the status poll, which stays live mid-generation.
struct ThinkingBubble: View {
    @Environment(AppState.self) private var app
    @State private var phase = 0
    @State private var elapsed = 0

    var body: some View {
        HStack {
            HStack(spacing: 5) {
                ForEach(0..<3) { i in
                    Circle()
                        .fill(Theme.textMuted)
                        .frame(width: 7, height: 7)
                        .opacity(phase == i ? 1 : 0.3)
                }
                Text(label)
                    .font(.caption)
                    .foregroundStyle(Theme.textMuted)
                    .monospacedDigit()
                    .padding(.leading, 4)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Theme.panel, in: .rect(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.line, lineWidth: 1))
            Spacer(minLength: 48)
        }
        .task {
            var ticks = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(350))
                phase = (phase + 1) % 3
                ticks += 1
                elapsed = ticks * 350 / 1000
            }
        }
    }

    private var label: String {
        let info = app.status?.assistant
        let onDevice = info?.cloudConfigured != true || info?.lastBackend == "local"
        var text = "thinking… \(elapsed)s"
        if onDevice {
            text += " · on-device"
            if elapsed > 75 { text += " — the first answer after a restart takes the longest" }
        }
        return text
    }
}
