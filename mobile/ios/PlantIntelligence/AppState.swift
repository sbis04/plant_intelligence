import SwiftUI
import UIKit
import WidgetKit

@MainActor
@Observable
final class AppState {
    // Persisted hub address — LAN IP or hostname of the UNO Q.
    var hubAddress: String {
        didSet {
            UserDefaults.standard.set(hubAddress, forKey: "hubAddress")
            SharedGardenStore.hubAddress = hubAddress
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    /// How the app is reaching the garden right now.
    /// `live` is the hub over the LAN; `remote` is the Firestore mirror,
    /// used when the hub cannot be seen. The distinction is shown rather
    /// than hidden — remote data is seconds behind and commands take a
    /// moment to be picked up, and it is better to say so.
    enum Link: Equatable { case connecting, live, remote, offline }

    var link: Link = .connecting

    /// Reachable by either path. Most of the UI only cares about this.
    var isConnected: Bool { link == .live || link == .remote }

    /// How stale the cloud mirror is, when that is the path being used.
    var remoteAgeSeconds: TimeInterval?
    var remoteBusy = false
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
    private var lastWidgetReload = Date.distantPast

    init() {
        let stored = UserDefaults.standard.string(forKey: "hubAddress")
        // The board's mDNS name survives DHCP reassignments; migrate anyone
        // still on the original hard-coded IP default.
        if let stored, stored != "192.168.68.64:7000" {
            hubAddress = stored
        } else {
            hubAddress = "plantintelligence.local:7000"
        }
        SharedGardenStore.hubAddress = hubAddress
        cloud = RemoteAccess.load().map(CloudClient.init(credentials:))
    }

    var client: HubClient? { HubClient(address: hubAddress) }

    /// Resolved at launch from whatever pairing left in the Keychain. Nil
    /// means this device has never been on the home network, so there is
    /// nothing to fall back to.
    @ObservationIgnored private var cloud: CloudClient?

    var isPairedForRemote: Bool { cloud != nil }

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

    /// Try the hub, then the mirror.
    ///
    /// The LAN attempt comes first every time, even while remote, and uses a
    /// short timeout so it costs little when it is going to fail. That is
    /// what makes walking back in the front door switch the app back to the
    /// direct connection within one poll, with nothing to tap.
    func refreshStatus() async {
        if let client {
            do {
                let latestStatus = try await client.status(timeout: link == .live ? 8 : 3)
                status = latestStatus
                link = .live
                remoteAgeSeconds = nil
                lastError = nil
                cacheForWidgets(latestStatus)
                reactToWateringState(latestStatus)
                await pairForRemoteIfNeeded()
                return
            } catch {
                // Fall through to the cloud rather than reporting offline.
            }
        }

        guard let cloud else { link = .offline; return }
        do {
            let latestStatus = try await cloud.status()
            status = latestStatus
            link = .remote
            remoteAgeSeconds = try? await cloud.stateAge()
            lastError = nil
            cacheForWidgets(latestStatus)
            reactToWateringState(latestStatus)
        } catch {
            link = .offline
            lastError = error.localizedDescription
        }
    }

    /// Collect the Firestore credentials from the hub while we can see it.
    /// Runs at most once per launch and only while on the LAN.
    @ObservationIgnored private var pairingAttempted = false

    private func pairForRemoteIfNeeded() async {
        guard cloud == nil, !pairingAttempted, let client else { return }
        pairingAttempted = true
        guard let credentials = try? await client.pairRemoteAccess(),
              credentials.isComplete else { return }
        RemoteAccess.save(credentials)
        cloud = CloudClient(credentials: credentials)
    }

    /// Drop the stored credentials — Settings offers this so a device can be
    /// un-paired without reinstalling.
    func forgetRemoteAccess() {
        RemoteAccess.forget()
        cloud = nil
        pairingAttempted = false
    }

    // MARK: - Notifications & live activity

    private var wasWatering = false

    /// Watch the watering edge and keep the phone's surfaces in step: raise
    /// and retire the live activity, and keep the locally scheduled
    /// notifications aligned with whatever the hub currently plans.
    private func reactToWateringState(_ response: StatusResponse) {
        let watering = response.status.isWatering
        let plan = response.plan

        if watering, !wasWatering {
            // `isWatering` is already true during valve_opening, when the MCU
            // still reports 0 seconds left. `??` only fills in for nil, not
            // for 0, so this used to build a card that had already finished:
            // 0:00 remaining and a full progress bar. Treat any non-positive
            // reading as "not known yet" and fall back to the planned run.
            let reported = response.status.wateringSecondsLeft ?? 0
            let left = reported > 0 ? reported : (plan?.durationS ?? 300)
            // The hub owns the notification; the card is started locally so
            // it appears instantly when the app is the one watching.
            LiveActivityManager.start(
                endsAt: Date().addingTimeInterval(TimeInterval(left)),
                totalSeconds: left,
                trigger: history.first?.trigger ?? "scheduled",
                note: "",
                location: response.location?.name ?? "Garden",
                client: client)
        } else if !watering, LiveActivityManager.hasActive {
            // Covers the ordinary end, and also clears a card orphaned by a
            // crash or a hub-pushed start we never saw finish.
            LiveActivityManager.end()
        }
        wasWatering = watering

        // Clears anything a previous build left queued on this device.
        NotificationManager.shared.cancelPlanned()
    }

    /// Called once at launch and whenever the hub address changes.
    func setUpNotifications() async {
        await NotificationManager.shared.bootstrap()
        LiveActivityManager.registerPushToStart(with: client)
    }

    func registerPushToken(_ token: String) async {
        guard let client else { return }
        _ = try? await client.registerPush(token: token, kind: "alert")
    }

    func refreshActivity() async {
        if link == .remote, let cloud {
            history = (try? await cloud.history()) ?? history
            logs = (try? await cloud.logs()) ?? logs
            return
        }
        guard let client else { return }
        history = (try? await client.history()) ?? history
        logs = (try? await client.logs()) ?? logs
    }

    // MARK: - Actions

    func waterNow() async {
        await command(remote: { try await $0.water() },
                      local: { try await $0.water() })
    }

    func stopWatering() async {
        await command(remote: { try await $0.stop() },
                      local: { try await $0.stop() })
    }

    /// One path for both transports.
    ///
    /// Remotely, the hub is polling rather than listening, so the command
    /// sits in Firestore for a few seconds before anything happens. The
    /// cloud client waits for the hub to write back what it did, and
    /// `remoteBusy` keeps the button honest about that wait instead of
    /// looking like nothing happened.
    private func command(
        remote: @escaping @Sendable (CloudClient) async throws -> String,
        local: @escaping @Sendable (HubClient) async throws -> SimpleResponse
    ) async {
        if link == .remote, let cloud {
            remoteBusy = true
            defer { remoteBusy = false }
            do {
                _ = try await remote(cloud)
                await refreshStatus()
                await refreshActivity()
                WidgetCenter.shared.reloadAllTimelines()
                Haptics.notification(.success)
            } catch {
                lastError = error.localizedDescription
                Haptics.notification(.error)
            }
            return
        }

        guard let client else {
            Haptics.notification(.error)
            return
        }
        do {
            let response = try await local(client)
            guard response.accepted != false, response.error == nil else {
                Haptics.notification(.error)
                return
            }
            await refreshStatus()
            await refreshActivity()
            WidgetCenter.shared.reloadAllTimelines()
            Haptics.notification(.success)
        } catch {
            Haptics.notification(.error)
        }
    }

    private func cacheForWidgets(_ response: StatusResponse) {
        let previous = SharedGardenStore.load()
        let snapshot = GardenSnapshot(response: response)
        SharedGardenStore.save(snapshot)
        let presentationChanged = previous == nil
            || previous?.isLive != snapshot.isLive
            || previous?.isWatering != snapshot.isWatering
            || previous?.waterNow != snapshot.waterNow
            || previous?.planStatus != snapshot.planStatus
            || previous?.nextWateringAt != snapshot.nextWateringAt
        guard presentationChanged
                || Date().timeIntervalSince(lastWidgetReload) >= 15 * 60
        else { return }
        lastWidgetReload = Date()
        WidgetCenter.shared.reloadAllTimelines()
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
                Haptics.notification(.warning)
            } else {
                Haptics.notification(.success)
            }
        } catch {
            if Task.isCancelled {
                if let i = replyIndex {
                    messages[i].text += " [stopped]"
                } else {
                    messages.append(ChatMessage(role: .assistant, text: "[stopped]"))
                }
                Haptics.notification(.warning)
            } else if let i = replyIndex {
                messages[i].text += "\n[connection lost mid-reply]"
                Haptics.notification(.error)
            } else {
                messages.append(ChatMessage(
                    role: .assistant,
                    text: "Couldn't reach the hub — is the phone on the same Wi-Fi?"))
                Haptics.notification(.error)
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

    func deleteThread(_ id: Int) async {
        guard !assistantBusy, id != 0, let client else { return }
        let deletedCurrentThread = id == currentThreadId
        _ = try? await client.deleteThread(id: id)
        await loadThreads()
        if deletedCurrentThread {
            if let latest = threads.first {
                await openThread(latest.id)
            } else {
                newThread()
            }
        }
    }

    func deleteCurrentThread() async {
        await deleteThread(currentThreadId)
    }
}
