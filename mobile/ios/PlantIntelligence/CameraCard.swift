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
                    .onTapGesture { viewerOpen = true }
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

/// Full-screen live camera view, fed by the hub's MJPEG stream (with the
/// last snapshot as the opening frame). The frame is 16:9, so a rotate
/// button switches the interface to landscape to fill the display; the rest
/// of the app stays portrait-only (see AppDelegate.allowLandscape).
private struct CameraViewer: View {
    let image: UIImage
    let streamURL: URL?
    @Environment(\.dismiss) private var dismiss
    @State private var live: UIImage?
    @State private var landscape = false
    @State private var streamNote = "starting"

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            Image(uiImage: live ?? image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
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
        .statusBarHidden()
        .task {
            if UserDefaults.standard.bool(forKey: "cameraLandscape"), !landscape {   // dev/testing hook
                try? await Task.sleep(for: .milliseconds(600))   // let the cover settle
                rotate()
            }
            guard let streamURL else { streamNote = "no stream url"; return }
            // Stream until dismissed; brief retries ride out a hub restart
            // or a momentarily saturated camera. On give-up the last
            // snapshot stays on screen.
            try? await Task.sleep(for: .milliseconds(100))
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
        landscape.toggle()
        AppDelegate.allowLandscape = landscape
        requestOrientation(landscape ? .landscapeRight : .portrait)
    }

    private func requestOrientation(_ mask: UIInterfaceOrientationMask) {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first else { return }
        // The gate changed, so UIKit must re-query supported orientations
        // before the geometry update can take effect.
        scene.keyWindow?.rootViewController?
            .setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
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
