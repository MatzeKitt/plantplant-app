import SwiftUI

/// Full-screen, swipeable viewer for a plant's photo history (newest first). Presented from
/// the detail view's photo header when the plant has one or more photos.
struct PhotoGalleryView: View {
    let photos: [Data]
    @State private var selection: Int
    @Environment(\.dismiss) private var dismiss

    init(photos: [Data], startIndex: Int = 0) {
        self.photos = photos
        _selection = State(initialValue: startIndex)
    }

    var body: some View {
        NavigationStack {
            TabView(selection: $selection) {
                ForEach(Array(photos.enumerated()), id: \.offset) { index, data in
                    GalleryPage(data: data)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: photos.count > 1 ? .automatic : .never))
            .indexViewStyle(.page(backgroundDisplayMode: .interactive))
            .background(Color.black.ignoresSafeArea())
            .navigationTitle(photos.count > 1 ? Text("\(selection + 1) of \(photos.count)") : Text("Photo"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        // Allow rotating to view a photo in its own orientation (e.g. a landscape shot),
        // even if the camera that captured it had pinned the app to portrait.
        .onAppear { AppDelegate.orientationLock = .all }
    }
}

/// A single, aspect-fit gallery page, decoded off the main thread at a larger size than the
/// list thumbnails so full-screen viewing stays sharp.
private struct GalleryPage: View {
    let data: Data
    @State private var image: UIImage?

    var body: some View {
        Color.clear
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    ProgressView()
                        .tint(.white)
                }
            }
            .task(id: data) {
                image = await Task.detached(priority: .userInitiated) {
                    PlantImage.thumbnail(from: data, maxPixel: 2000)
                }.value
            }
    }
}
