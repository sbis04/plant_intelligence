import AVFoundation
import SwiftUI
import UIKit

/// Live view of the garden via the hub's camera endpoints. Shown only when
/// the hub has a camera configured. The inline card refreshes a snapshot
/// once a minute — plants don't move, and each fetch costs the hub a full
/// RTSP round-trip to the camera. Tapping opens a full-screen viewer fed by
/// the hub's MJPEG live stream. Rendered full-bleed, no card chrome — the
/// photo speaks for itself.
struct CameraCard: View {
    @Environment(AppState.self) private var app
    @State private var image: UIImage?
    @State private var available = false
    @State private var viewerOpen = false
    @State private var autoOpened = false   // dev hook fires at most once

    var body: some View {
        // The poller must live on a view that ALWAYS renders — attaching
        // .task to a conditionally-empty view means it never starts.
        VStack(spacing: 0) {
            if available, let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, -16)   // bleed past the scroll padding
                    .contentShape(.rect)
                    .onTapGesture {
                        Haptics.impact(.light)
                        viewerOpen = true
                    }
            } else {
                Color.clear.frame(height: 1)   // keeps the view (and task) alive
            }
        }
        // id: restarts the loop when the viewer closes, so a snapshot poll
        // isn't left mid-sleep with a stale frame.
        .task(id: viewerOpen) {
            while !Task.isCancelled {
                await refresh()
                if !autoOpened, available,
                   UserDefaults.standard.bool(forKey: "openCamera") {   // dev/testing hook
                    autoOpened = true
                    viewerOpen = true
                }
                try? await Task.sleep(for: .seconds(60))
            }
        }
        .fullScreenCover(isPresented: $viewerOpen) {
            if let image {
                CameraViewer(
                    image: image,
                    // Camera-native H.264 relayed as HLS — full quality and
                    // fps, hardware-decoded by AVPlayer.
                    liveURL: app.client?.baseURL
                        .appending(path: "/api/camera/live.m3u8"),
                    // raw=1: bare JPEG stream — URLSession deadlocks on
                    // multipart/x-mixed-replace (legacy per-part handling).
                    streamURL: app.client?.baseURL
                        .appending(path: "/api/camera/stream")
                        .appending(queryItems: [.init(name: "raw", value: "1")]))
            }
        }
    }

    private func refresh() async {
        guard let client = app.client else { return }
        var req = URLRequest(url: client.baseURL.appending(path: "/api/camera/snapshot"))
        req.timeoutInterval = 15
        req.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse,
              (http.value(forHTTPHeaderField: "Content-Type") ?? "").hasPrefix("image/"),
              let img = UIImage(data: data) else {
            available = false
            return
        }
        image = img
        available = true
    }
}

/// Full-screen live camera view. Preferred source is the HLS relay of the
/// camera's own H.264 (full 2K, native fps, hardware-decoded); if that
/// fails it falls back to the hub's MJPEG stream, with the last snapshot
/// as the opening frame either way. The frame is 16:9, so a rotate button
/// switches the interface to landscape to fill the display; the rest of
/// the app stays portrait-only (see AppDelegate.allowLandscape).
private struct CameraViewer: View {
    let image: UIImage
    let liveURL: URL?
    let streamURL: URL?
    @Environment(\.dismiss) private var dismiss
    @State private var live: UIImage?
    @State private var landscape = false
    @State private var videoReady = false
    @State private var videoFailed = false
    @State private var streamNote = "starting"
    @State private var zoomScale: CGFloat = 1
    @State private var zoomOffset: CGSize = .zero
    @GestureState private var pinchScale: CGFloat = 1
    @GestureState private var dragOffset: CGSize = .zero

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            GeometryReader { geometry in
                let scale = displayedScale
                let offset = constrainedOffset(
                    CGSize(width: zoomOffset.width + dragOffset.width,
                           height: zoomOffset.height + dragOffset.height),
                    scale: scale,
                    in: geometry.size)

                ZStack {
                    Image(uiImage: live ?? image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if let liveURL, !videoFailed {
                        LiveVideoView(url: liveURL,
                                      onReady: { videoReady = true },
                                      onFail: { videoFailed = true })
                            .opacity(videoReady ? 1 : 0)   // snapshot until frames flow
                            .allowsHitTesting(false)
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .scaleEffect(scale)
                .offset(offset)
                .overlay {
                    // AVPlayer's UIKit view otherwise wins hit testing in
                    // the simulator and the SwiftUI magnifier never starts.
                    Color.clear
                        .contentShape(.rect)
                        .gesture(zoomGesture(in: geometry.size))
                        .onTapGesture(count: 2) { resetZoom() }
                }
            }
            .ignoresSafeArea()
            .clipped()
            if UserDefaults.standard.bool(forKey: "streamDebug") {   // dev/testing hook
                Text(streamNote)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.yellow)
                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                           alignment: .bottomLeading)
                    .padding(16)
            }
            HStack(spacing: 10) {
                Button {
                    rotate()
                } label: {
                    Image(systemName: "rectangle.landscape.rotate")
                        .font(.body.weight(.semibold))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.glass)
                Button {
                    Haptics.impact(.light)
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.glass)
            }
            .padding(16)
        }
        .ignoresSafeArea()
        .statusBarHidden()
        .onAppear {
            // While the viewer is up the whole interface may rotate freely —
            // physically turning the phone lands in the right orientation.
            AppDelegate.allowLandscape = true
            refreshSupportedOrientations()
        }
        .task {
            if UserDefaults.standard.bool(forKey: "cameraLandscape"), !landscape {   // dev/testing hook
                try? await Task.sleep(for: .milliseconds(600))   // let the cover settle
                rotate()
            }
            if liveURL == nil {
                videoFailed = true    // no relay — straight to MJPEG
                return
            }
            // Watchdog: if HLS produces nothing in time, fall back.
            try? await Task.sleep(for: .seconds(10))
            if !videoReady { videoFailed = true }
        }
        .task(id: videoFailed) {
            guard videoFailed, let streamURL else { return }
            streamNote = "hls failed, using mjpeg"
            // Stream until dismissed; brief retries ride out a hub restart
            // or a momentarily saturated camera. On give-up the last
            // snapshot stays on screen.
            for attempt in 1...3 {
                guard !Task.isCancelled else { return }
                do {
                    streamNote = "connecting (try \(attempt))"
                    var count = 0
                    for try await frame in MJPEG.frames(from: streamURL) {
                        live = frame
                        count += 1
                        streamNote = "frames \(count)"
                    }
                    streamNote = "stream ended after \(count)"
                    if count > 0 { return }   // healthy stream closed by server
                } catch {
                    streamNote = "error: \(error.localizedDescription)"
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .onDisappear {
            AppDelegate.allowLandscape = false
            requestOrientation(.portrait)
        }
    }

    private func rotate() {
        Haptics.impact(.medium, intensity: 0.8)
        landscape.toggle()
        AppDelegate.allowLandscape = landscape
        requestOrientation(landscape ? .landscapeRight : .portrait)
    }

    private func refreshSupportedOrientations() {
        // The gate changed, so UIKit must re-query supported orientations.
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.first?
            .keyWindow?.rootViewController?
            .setNeedsUpdateOfSupportedInterfaceOrientations()
    }

    private func requestOrientation(_ mask: UIInterfaceOrientationMask) {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first else { return }
        refreshSupportedOrientations()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
    }

    private var displayedScale: CGFloat {
        min(max(zoomScale * pinchScale, 1), 5)
    }

    private func zoomGesture(in size: CGSize) -> some Gesture {
        MagnifyGesture()
            .updating($pinchScale) { value, state, _ in
                state = value.magnification
            }
            .onEnded { value in
                let newScale = min(max(zoomScale * value.magnification, 1), 5)
                zoomScale = newScale
                zoomOffset = newScale > 1
                    ? constrainedOffset(zoomOffset, scale: newScale, in: size)
                    : .zero
            }
            .simultaneously(with:
                DragGesture(minimumDistance: 1)
                    .updating($dragOffset) { value, state, _ in
                        guard displayedScale > 1 else { return }
                        state = value.translation
                    }
                    .onEnded { value in
                        guard zoomScale > 1 else {
                            zoomOffset = .zero
                            return
                        }
                        let proposed = CGSize(
                            width: zoomOffset.width + value.translation.width,
                            height: zoomOffset.height + value.translation.height)
                        zoomOffset = constrainedOffset(
                            proposed, scale: zoomScale, in: size)
                    }
            )
    }

    private func constrainedOffset(_ proposed: CGSize, scale: CGFloat,
                                   in size: CGSize) -> CGSize {
        guard scale > 1 else { return .zero }
        let maxX = size.width * (scale - 1) / 2
        let maxY = size.height * (scale - 1) / 2
        return CGSize(
            width: min(max(proposed.width, -maxX), maxX),
            height: min(max(proposed.height, -maxY), maxY))
    }

    private func resetZoom() {
        guard zoomScale > 1 else { return }
        Haptics.impact(.soft)
        withAnimation(.snappy) {
            zoomScale = 1
            zoomOffset = .zero
        }
    }
}

/// AVPlayer wrapper for the hub's HLS relay — no controls, just video,
/// hardware-decoded at the camera's native resolution and frame rate.
private struct LiveVideoView: UIViewRepresentable {
    let url: URL
    let onReady: @MainActor @Sendable () -> Void
    let onFail: @MainActor @Sendable () -> Void

    func makeUIView(context: Context) -> PlayerView {
        PlayerView(url: url, onReady: onReady, onFail: onFail)
    }

    func updateUIView(_ uiView: PlayerView, context: Context) {}

    static func dismantleUIView(_ uiView: PlayerView, coordinator: ()) {
        uiView.stop()
    }
}

final class PlayerView: UIView {
    private let player: AVPlayer
    private let playerLayer = AVPlayerLayer()
    private var statusObservation: NSKeyValueObservation?

    init(url: URL,
         onReady: @escaping @MainActor @Sendable () -> Void,
         onFail: @escaping @MainActor @Sendable () -> Void) {
        player = AVPlayer(url: url)
        player.isMuted = true
        super.init(frame: .zero)
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspect
        layer.addSublayer(playerLayer)
        statusObservation = player.currentItem?.observe(\.status) { item, _ in
            let status = item.status
            Task { @MainActor in
                switch status {
                case .readyToPlay: onReady()
                case .failed: onFail()
                default: break
                }
            }
        }
        player.play()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer.frame = bounds
    }

    func stop() {
        statusObservation = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
    }
}

/// Minimal reader for the hub's raw concatenated-JPEG stream. It scans for
/// JPEG start/end markers — the frames are OpenCV-encoded and never contain
/// nested thumbnails, so the markers are unambiguous.
enum MJPEG {
    static func frames(from url: URL) -> AsyncThrowingStream<UIImage, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var req = URLRequest(url: url)
                    req.timeoutInterval = 20
                    let (bytes, response) = try await URLSession.shared.bytes(for: req)
                    guard let http = response as? HTTPURLResponse,
                          http.statusCode == 200,
                          (http.value(forHTTPHeaderField: "Content-Type") ?? "")
                              .hasPrefix("application/octet-stream") else {
                        throw URLError(.badServerResponse)
                    }
                    var buffer = Data()
                    var inFrame = false
                    var previous: UInt8 = 0
                    for try await byte in bytes {
                        if !inFrame {
                            if previous == 0xFF, byte == 0xD8 {   // SOI
                                inFrame = true
                                buffer = Data([0xFF, 0xD8])
                            }
                        } else {
                            buffer.append(byte)
                            if previous == 0xFF, byte == 0xD9 {   // EOI
                                if let img = UIImage(data: buffer) {
                                    continuation.yield(img)
                                }
                                inFrame = false
                                buffer.removeAll(keepingCapacity: true)
                            }
                        }
                        previous = byte
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
