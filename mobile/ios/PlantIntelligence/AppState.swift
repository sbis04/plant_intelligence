import SwiftUI
import UIKit

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

    // Assistant conversation. Threads live on the hub; `messages` mirrors
    // the currently open one. currentThreadId 0 = the hub creates a thread
    // on the first message.
    var messages: [ChatMessage] = []
    var threads: [ChatThread] = []
    var currentThreadId = 0
    var assistantBusy = false
    var assistantOpen = false   // overlay over the Plants tab
    var pendingAttachment: UIImage?
    private var threadsResumed = false

    /// Attach a photo to the next question, pre-shrunk for upload.
    func setAttachment(_ image: UIImage) {
        let maxW: CGFloat = 1280
        guard image.size.width > maxW else { pendingAttachment = image; return }
        let size = CGSize(width: maxW,
                          height: image.size.height * maxW / image.size.width)
        pendingAttachment = UIGraphicsImageRenderer(size: size).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

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

    private var askTask: Task<Void, Never>?

    func ask(_ question: String) async {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !assistantBusy, let client else { return }
        // Run in an owned task so a stop button can cancel mid-stream;
        // dropping the connection makes the hub stop generation too.
        let task = Task { await runAsk(q, client: client) }
        askTask = task
        await task.value
        askTask = nil
    }

    func stopAsking() {
        askTask?.cancel()
    }

    private func runAsk(_ q: String, client: HubClient) async {
        assistantBusy = true
        var attachmentId = ""
        if let image = pendingAttachment,
           let jpeg = image.jpegData(compressionQuality: 0.8) {
            attachmentId = (try? await client.attach(jpeg)) ?? ""
            pendingAttachment = nil
        }
        messages.append(ChatMessage(
            role: .user, text: q,
            attachmentURL: attachmentId.isEmpty ? nil : attachmentURL(attachmentId)))
        var replyIndex: Int?
        do {
            let (tid, chunks) = try await client.chatStream(
                message: q, threadId: currentThreadId,
                attachmentId: attachmentId)
            currentThreadId = tid
            for try await chunk in chunks {
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
            if Task.isCancelled {
                if let i = replyIndex {
                    messages[i].text += " [stopped]"
                } else {
                    messages.append(ChatMessage(role: .assistant, text: "[stopped]"))
                }
            } else if let i = replyIndex {
                messages[i].text += "\n[connection lost mid-reply]"
            } else {
                messages.append(ChatMessage(
                    role: .assistant,
                    text: "Couldn't reach the hub — is the phone on the same Wi-Fi?"))
            }
        }
        assistantBusy = false
        await loadThreads()   // pick up auto-title / recency reorder
    }

    // MARK: - Threads

    func loadThreads() async {
        guard let client else { return }
        threads = (try? await client.chatThreads()) ?? threads
    }

    /// First overlay open of the session: resume the last conversation.
    func resumeThreads() async {
        guard !threadsResumed else { return }
        threadsResumed = true
        await loadThreads()
        if currentThreadId == 0, let latest = threads.first {
            await openThread(latest.id)
        }
    }

    private func attachmentURL(_ token: String) -> URL? {
        client?.baseURL
            .appending(path: "/api/chat/attachment")
            .appending(queryItems: [.init(name: "id", value: token)])
    }

    func openThread(_ id: Int) async {
        guard !assistantBusy else { return }
        currentThreadId = id
        guard let client, id != 0 else { messages = []; return }
        let stored = (try? await client.threadMessages(id: id)) ?? []
        messages = stored.map {
            ChatMessage(role: $0.role == "user" ? .user : .assistant,
                        text: $0.content,
                        attachmentURL: ($0.attachment?.isEmpty == false)
                            ? attachmentURL($0.attachment!) : nil)
        }
    }

    func newThread() {
        guard !assistantBusy else { return }
        currentThreadId = 0
        messages = []
    }

    func deleteCurrentThread() async {
        guard !assistantBusy, currentThreadId != 0, let client else { return }
        _ = try? await client.deleteThread(id: currentThreadId)
        await loadThreads()
        if let latest = threads.first {
            await openThread(latest.id)
        } else {
            newThread()
        }
    }
}
