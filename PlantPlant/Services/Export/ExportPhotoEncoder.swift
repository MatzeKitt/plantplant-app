import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import UIKit

/// Downscales, re-encodes and hashes one photo for export.
///
/// Content addressing is the point: the same image is normally stored twice on
/// the device — as `plant.photoData` *and* in its newest `photoChanged` log —
/// and keying the export's photo map by the SHA-256 of the exported bytes
/// collapses that to one copy. It also lets the importer verify integrity photo
/// by photo instead of trusting the whole file.
///
/// The hash is taken over the **exported** bytes, not the source, because that
/// is what the importer will hash to check them.
enum ExportPhotoEncoder {
    struct Encoded {
        let sha256: String
        let jpeg: Data
    }

    /// Re-encodes to at most `ExportFormat.photoLongEdge` on the long edge.
    ///
    /// `CGImageSourceCreateThumbnailAtIndex` downsamples *during* decode rather
    /// than decoding full-size and shrinking, so a 3024×4032 camera original
    /// never exists in memory at full resolution. `kCGImageSourceCreateThumbnailWithTransform`
    /// bakes EXIF orientation into the pixels, which is why the importer can
    /// treat the result as already upright.
    ///
    /// Returns nil for bytes no image decoder recognises, so one unreadable
    /// photo is skipped and counted rather than failing the export.
    static func encode(_ data: Data, fullResolution: Bool = false) -> Encoded? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }

        // A ceiling no phone camera reaches, rather than an unbounded value:
        // the point of full resolution is "do not shrink my photos", not "let a
        // pathological input allocate without limit".
        let longEdge = fullResolution ? Self.fullResolutionCeiling : ExportFormat.photoLongEdge

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: longEdge,
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }

        guard let jpeg = UIImage(cgImage: cgImage).jpegData(compressionQuality: ExportFormat.photoQuality) else {
            return nil
        }

        return Encoded(sha256: hex(SHA256.hash(data: jpeg)), jpeg: jpeg)
    }

    /// A cheap identity for source bytes, used only to avoid re-encoding an
    /// image this export has already processed.
    ///
    /// Hashing the source is far cheaper than the decode-downscale-encode round
    /// trip it saves, and the duplicate case is the common one — every plant
    /// whose photo was ever captured through a photo reminder has the same bytes
    /// in two places.
    static func sourceKey(_ data: Data) -> String {
        hex(SHA256.hash(data: data))
    }

    private static let fullResolutionCeiling: CGFloat = 12000

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
