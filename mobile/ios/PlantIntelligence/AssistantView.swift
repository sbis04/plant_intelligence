import SwiftUI

struct AssistantView: View {
    @Environment(AppState.self) private var app
    @State private var draft = ""
    @FocusState private var inputFocused: Bool

    private let suggestions = [
        "Why aren't you watering?",
        "When is the next watering?",
        "How's the weather looking?",
        "Summarize the last 24 hours",
    ]

    var body: some View {
        NavigationStack {
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
                    .padding(.bottom, 8)
                }
                .defaultScrollAnchor(.bottom)
                .scrollDismissesKeyboard(.immediately)
                .onTapGesture { inputFocused = false }
                .onChange(of: app.messages.count) {
                    if let last = app.messages.last?.id {
                        withAnimation(.snappy) { proxy.scrollTo(last, anchor: .bottom) }
                    }
                }
            }
            .background(GardenBackground())
            .navigationTitle("Assistant")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await app.resetConversation() }
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .disabled(app.messages.isEmpty || app.assistantBusy)
                }
            }
            .safeAreaInset(edge: .bottom) { inputBar }
        }
    }

    // MARK: pieces

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "sparkles")
                .font(.system(size: 40))
                .foregroundStyle(Theme.accent)
            Text("Ask your garden anything")
                .font(.headline)
            Text("The model runs locally on the UNO Q with live access to every sensor, plan and log — no cloud involved.")
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
            Text(msg.text)
                .font(.subheadline)
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

    private var inputBar: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                TextField("Ask the garden…", text: $draft, axis: .vertical)
                    .lineLimit(1...4)
                    .focused($inputFocused)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .glassEffect(.regular, in: .rect(cornerRadius: 22))
                    .onSubmit(send)

                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.body.weight(.semibold))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.glassProminent)
                .tint(Theme.accent)
                .disabled(app.assistantBusy ||
                          draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
    }

    private func send() {
        let text = draft
        draft = ""
        inputFocused = false
        Task { await app.ask(text) }
    }
}

/// Animated "the model is generating" indicator — worth having because
/// on-device generation legitimately takes a minute or two.
struct ThinkingBubble: View {
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
        var text = "thinking on-device… \(elapsed)s"
        if elapsed > 75 { text += " — first answer after a restart takes the longest" }
        return text
    }
}
