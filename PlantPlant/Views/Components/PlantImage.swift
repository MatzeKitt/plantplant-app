import UIKit
import ImageIO

/// Decodes plant photos into small, display-ready thumbnails off the main thread.
///
/// Plant photos are stored at full camera resolution. Decoding those with `UIImage(data:)`
/// directly in a SwiftUI `body` blocks the main thread on every render — with several plants
/// that made the overview take seconds to appear. `CGImageSourceCreateThumbnailAtIndex`
/// downsamples during decode (cheap memory + CPU), and results are cached by content + size.
enum PlantImage {
    private static let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 200
        return c
    }()

    /// A thumbnail of `data` no larger than `maxPixel` on its longest edge. Call off the main
    /// actor (e.g. from `Task.detached`); the decode is synchronous.
    static func thumbnail(from data: Data, maxPixel: CGFloat) -> UIImage? {
        let key = "\(data.count)-\(data.hashValue)-\(Int(maxPixel))" as NSString
        if let cached = cache.object(forKey: key) { return cached }

        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let image = UIImage(cgImage: cg)
        cache.setObject(image, forKey: key)
        return image
    }
}
