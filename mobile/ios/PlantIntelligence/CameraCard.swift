import SwiftUI
import UIKit

/// Live view of the garden via the hub's camera snapshot endpoint.
/// Shown only when the hub has a camera configured; refreshes every few
/// seconds, which for plants is as good as live video.
struct CameraCard: View {
    @Environment(AppState.self) private var app
    @State private var image: UIImage?
    @State private var available = false

    var body: some View {
        // The poller must live on a view that ALWAYS renders — attaching
        // .task to a conditionally-empty view means it never starts.
        VStack(spacing: 0) {
            if available, let image {
                PanelCard(title: "Garden camera") {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(maxWidth: .infinity)
                        .clipShape(.rect(cornerRadius: 12))
                }
            } else {
                Color.clear.frame(height: 1)   // keeps the view (and task) alive
            }
        }
        .task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(6))
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
