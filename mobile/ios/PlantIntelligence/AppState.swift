import SwiftUI

@MainActor
@Observable
final class AppState {
    // Persisted hub address — LAN IP or hostname of the UNO Q.
    var hubAddress: String {
        didSet { UserDefaults.standard.set(hubAddress, forKey: "hubAddress") }
    }

    enum Link: Equatable { case connecting, live, offline }

    var link: Link = .connecting
    var status: StatusResponse?
    var history: [WateringEvent] = []
    var logs: [LogEntry] = []
    var lastError: String?

    // Assistant conversation (client-side transcript).
    var messages: [ChatMessage] = []
    var assistantBusy = false

    private var pollTask: Task<Void, Never>?

    init() {
        hubAddress = UserDefaults.standard.string(forKey: "hubAddress")
            ?? "192.168.68.64:7000"
    }

    var client: HubClient? { HubClient(address: hubAddress) }

    // MARK: - Polling

    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            var slowTick = 0
            while !Task.isCancelled {
                await self?.refreshStatus()
                if slowTick % 6 == 0 { await self?.refreshActivity() }
                slowTick += 1
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    func refreshStatus() async {
        guard let client else { link = .offline; return }
        do {
            status = try await client.status()
            link = .live
        } catch {
            link = .offline
        }
    }

    func refreshActivity() async {
        guard let client else { return }
        history = (try? await client.history()) ?? history
        logs = (try? await client.logs()) ?? logs
    }

    // MARK: - Actions

    func waterNow() async {
        guard let client else { return }
        _ = try? await client.water()
        await refreshStatus()
        await refreshActivity()
    }

    func stopWatering() async {
        guard let client else { return }
        _ = try? await client.stop()
        await refreshStatus()
    }

    // MARK: - Assistant

    func ask(_ question: String) async {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !assistantBusy, let client else { return }
        assistantBusy = true
        messages.append(ChatMessage(role: .user, text: q))
        var replyIndex: Int?
        do {
            for try await chunk in client.chatStream(message: q) {
                if let i = replyIndex {
                    messages[i].text += chunk
                } else {
                    messages.append(ChatMessage(role: .assistant, text: chunk))
                    replyIndex = messages.count - 1
                }
            }
            if replyIndex == nil {
                messages.append(ChatMessage(role: .assistant, text: "No reply from the hub."))
            }
        } catch {
            if replyIndex == nil {
                messages.append(ChatMessage(
                    role: .assistant,
                    text: "Couldn't reach the hub — is the phone on the same Wi-Fi?"))
            } else if let i = replyIndex {
                messages[i].text += "\n[connection lost mid-reply]"
            }
        }
        assistantBusy = false
    }

    func resetConversation() async {
        messages.removeAll()
        try? await client?.chatReset()
    }
}
