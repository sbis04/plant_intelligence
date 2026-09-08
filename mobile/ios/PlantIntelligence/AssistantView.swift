import SwiftUI

/// The assistant lives as an overlay on the Plants tab (opened from the
/// detached sparkles button by the tab bar), blurring the dashboard behind
/// the transcript. The prompt box replaces the watering action bar while
/// it's open — see GardenView.
struct AssistantOverlay: View {
    @Environment(AppState.self) private var app
    @State private var historyOpen = false
    @State private var deleteConfirmationPresented = false
    @State private var pendingDeletionID: Int?

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
                            if app.assistantAvailable {
                                emptyState
                            } else {
                                unavailableState
                            }
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

            if historyOpen {
                Color.black.opacity(0.16)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.snappy) { historyOpen = false }
                    }

                historyPanel
                    .padding(.horizontal, 16)
                    .padding(.top, 64)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(1)
            }

            controls
                .zIndex(2)
        }
        .task { await app.resumeThreads() }   // auto-open the last conversation
        .confirmationDialog(
            "Delete conversation?",
            isPresented: $deleteConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Delete Conversation", role: .destructive) {
                guard let id = pendingDeletionID else { return }
                Haptics.notification(.warning)
                Task { await app.deleteThread(id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This conversation and all of its messages will be permanently deleted.")
        }
    }

    // MARK: pieces

    private var controls: some View {
        HStack {
            // Conversation history: switch, resume, or delete threads.
            Button {
                Haptics.impact(.soft)
                withAnimation(.snappy) { historyOpen.toggle() }
            } label: {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.body.weight(.semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.glass)
            .disabled(!app.assistantAvailable || app.assistantBusy || app.threads.isEmpty)
            Spacer()
            Button {
                Haptics.impact(.soft)
                app.newThread()
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.body.weight(.semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.glass)
            .disabled(!app.assistantAvailable || app.assistantBusy || app.messages.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var historyPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text("Conversations")
                    .font(.headline)
                Text("\(app.threads.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textMuted)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Theme.line, in: .capsule)
                Spacer()
                Button {
                    Haptics.impact(.soft)
                    withAnimation(.snappy) { historyOpen = false }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Theme.textMuted)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Divider()
                .overlay(Theme.line)

            ScrollView {
                LazyVStack(spacing: 5) {
                    ForEach(app.threads) { thread in
                        Button {
                            Haptics.selection()
                            withAnimation(.snappy) { historyOpen = false }
                            Task { await app.openThread(thread.id) }
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: thread.id == app.currentThreadId
                                      ? "checkmark.circle.fill" : "message")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(thread.id == app.currentThreadId
                                                     ? Theme.accent : Theme.textMuted)
                                    .frame(width: 22, height: 22)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(thread.displayTitle)
                                        .font(.body.weight(.medium))
                                        .foregroundStyle(.primary)
                                        .multilineTextAlignment(.leading)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    if let snippet = thread.snippet, !snippet.isEmpty {
                                        Text(snippet)
                                            .font(.subheadline)
                                            .foregroundStyle(Theme.textMuted)
                                            .lineLimit(2)
                                            .multilineTextAlignment(.leading)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 11)
                            .background(
                                thread.id == app.currentThreadId
                                    ? Theme.accent.opacity(0.12) : .clear,
                                in: .rect(cornerRadius: 13)
                            )
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive) {
                                requestDeletion(thread.id)
                            } label: {
                                Label("Delete conversation", systemImage: "trash")
                            }
                        }
                    }
                }
                .padding(8)
            }
            .frame(maxHeight: 430)

            if app.currentThreadId != 0 {
                Divider()
                    .overlay(Theme.line)
                Button(role: .destructive) {
                    requestDeletion(app.currentThreadId)
                } label: {
                    Label("Delete current conversation", systemImage: "trash")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.err)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 13)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
        .background(Theme.panel.opacity(0.92), in: .rect(cornerRadius: 24))
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .overlay(
            RoundedRectangle(cornerRadius: 24)
                .strokeBorder(Theme.line, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.32), radius: 24, y: 12)
    }

    private func requestDeletion(_ id: Int) {
        pendingDeletionID = id
        deleteConfirmationPresented = true
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
                        Haptics.impact(.light)
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

    private var unavailableState: some View {
        VStack(spacing: 14) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 38))
                .foregroundStyle(Theme.warn)
            Text("Assistant needs the home network")
                .font(.headline)
            Text("Garden status and watering still work through the cloud. Conversations and camera access connect directly to the hub.")
                .font(.subheadline)
                .foregroundStyle(Theme.textMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.top, 90)
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
                            .clipShape(.rect(cornerRadius: 5))
                    } placeholder: {
                        RoundedRectangle(cornerRadius: 5).fill(Theme.line)
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
