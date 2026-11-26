import SwiftUI

struct BackgroundImageLayer: View {
    let style: BackgroundStyle
    let url: URL
    var maxPixels = 2560
    var previewScale: CGFloat = 1
    @Environment(\.displayScale) private var displayScale
    @State private var loaded: (url: URL, image: CGImage)?

    private struct ThumbnailRequest: Hashable {
        let url: URL
        let pixels: Int
    }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let longestEdge = max(size.width, size.height) * displayScale
            let pixels = min(maxPixels, Int(ceil(longestEdge / 512)) * 512)
            ZStack {
                Color.clear
                if let loaded, loaded.url == url {
                    Image(decorative: loaded.image, scale: 1)
                        .resizable()
                        .scaledToFill()
                        .frame(width: size.width, height: size.height)
                        .blur(radius: style.blur * previewScale)
                        .opacity(1 - style.transparency / 100)
                }
            }
            .task(id: ThumbnailRequest(url: url, pixels: pixels)) {
                if loaded?.url != url { loaded = nil }
                guard pixels > 0 else { return }
                if let image = await BackgroundImport.load(at: url, pixels: pixels), !Task.isCancelled {
                    loaded = (url, image)
                }
            }
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
