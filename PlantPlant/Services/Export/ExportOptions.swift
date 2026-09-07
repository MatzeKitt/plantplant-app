import Foundation

struct ExportOptions: Sendable {
    /// Ship photos at their stored resolution instead of downscaling to 2000 px.
    ///
    /// Off by default, and the UI warns before turning it on. A real library
    /// comes to roughly 120 MB after base64 at full resolution, which fails on
    /// the server's upload limit and on Safari suspending the tab mid-upload —
    /// and buys nothing visible, because 2000 px is exactly the largest
    /// derivative either app renders.
    var fullResolution = false

    /// Leave the images out entirely.
    ///
    /// Produces a file of a few hundred kilobytes. Useful for a quick top-up
    /// after the photos have already been migrated once, and for support: it can
    /// be read end to end by a person. Photo references are dropped along with
    /// the bytes rather than left dangling.
    var includePhotos = true
}

/// Where an export has got to, for the progress view.
struct ExportProgress: Sendable {
    enum Phase: Sendable {
        case reading
        case photos
        case writing
        case done
    }

    let phase: Phase
    let done: Int
    let total: Int

    var fraction: Double {
        total > 0 ? min(1, Double(done) / Double(total)) : 0
    }
}

struct ExportResult: Sendable {
    let url: URL
    let byteSize: Int
    let counts: ExportSummary

    var readableSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(byteSize), countStyle: .file)
    }
}

/// The same numbers the envelope carries, handed back for the summary screen.
struct ExportSummary: Sendable {
    var rooms = 0
    var plants = 0
    var schedules = 0
    var wateringSeasons = 0
    var logs = 0
    var photos = 0
    var photosSkipped = 0
}
