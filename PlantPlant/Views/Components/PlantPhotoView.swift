import SwiftUI

/// Renders a plant's photo, or a leaf placeholder when there is none.
///
/// The photo is downsampled and decoded off the main thread, then cached, so lists of plants
/// scroll and launch smoothly even when photos are full camera resolution.
struct PlantPhotoView: View {
    let data: Data?
    var cornerRadius: CGFloat = 12
    /// Longest-edge pixel size to decode to; keep it close to the on-screen size.
    var maxPixel: CGFloat = 240

    @State private var image: UIImage?

    var body: some View {
        // `Color.clear` adopts the size proposed by the caller's `.frame`; the image is drawn
        // as an overlay and everything is clipped to that box, so a wide photo can never
        // overflow horizontally.
        Color.clear
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    ZStack {
                        Rectangle().fill(.quaternary)
                        Image(systemName: "leaf.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .task(id: data) {
                guard let data else {
                    image = nil
                    return
                }
                let max = maxPixel
                image = await Task.detached(priority: .userInitiated) {
                    PlantImage.thumbnail(from: data, maxPixel: max)
                }.value
            }
    }
}
