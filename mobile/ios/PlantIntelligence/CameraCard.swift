import SwiftUI
import UIKit

/// Live view of the garden via the hub's camera snapshot endpoint.
/// Shown only when the hub has a camera configured. Ambient refresh is once
/// a minute — plants don't move, and each fetch costs the hub a full RTSP
/// round-trip to the camera. Tapping opens a full-screen viewer that
/// refreshes every few seconds instead. Rendered full-bleed, no card
/// chrome — the photo speaks for itself.
struct CameraCard: View {
    @Environment(AppState.self) private var app
    @State private var image: UIImage?
    @State private var available = false
    @State private var viewerOpen = false

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
        // id: restarts the loop when the viewer opens/closes, so the fast
        // cadence kicks in immediately instead of after a pending 60 s sleep.
        .task(id: viewerOpen) {
            while !Task.isCancelled {
                await refresh()
                if UserDefaults.standard.bool(forKey: "openCamera"),
                   available, !viewerOpen {          // dev/testing hook
                    viewerOpen = true
                }
                // 3 s in the viewer matches the hub's frame cache — polling
                // faster only re-downloads the same cached frame.
                try? await Task.sleep(for: .seconds(viewerOpen ? 3 : 60))
            }
        }
        .fullScreenCover(isPresented: $viewerOpen) {
            if let image {
                CameraViewer(image: image)
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

/// Full-screen camera view. The frame is 16:9, so a rotate button switches
/// the interface to landscape to fill the display; the rest of the app
/// stays portrait-only (see AppDelegate.allowLandscape).
private struct CameraViewer: View {
    let image: UIImage
    @Environment(\.dismiss) private var dismiss
    @State private var landscape = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
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
            if UserDefaults.standard.bool(forKey: "cameraLandscape") {   // dev/testing hook
                try? await Task.sleep(for: .milliseconds(600))   // let the cover settle
                rotate()
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
