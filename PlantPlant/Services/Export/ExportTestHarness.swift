#if DEBUG
import Foundation
import SwiftData
import UIKit

/// DEBUG-only scaffolding that makes the export testable without a device.
///
/// The migration is a one-way door: it runs once, against the only copy of data
/// the user cares about, and "I'll check it on my phone" is not a test strategy.
/// These two launch arguments make the whole path scriptable from a simulator —
/// seed, export, then feed the file to the PHP importer and diff the result.
///
///     -seedSampleData -seedSamplePhotos -exportSampleData /path/to/out.json
///
/// None of this ships: the whole file is inside `#if DEBUG`.
@MainActor
enum ExportTestHarness {
    /// Gives the seeded plants photos that look like real camera output.
    ///
    /// Three things here are deliberate, and each exercises something the
    /// exporter or the importer would otherwise never meet in testing:
    ///
    ///  1. **3024×4032** is what an iPhone camera actually produces, so the
    ///     downscale-to-2000 path does real work and the memory ceiling is real.
    ///  2. **The same `Data` is assigned to a plant *and* to one of its logs**,
    ///     which is the duplication that content addressing exists to collapse.
    ///     If dedup breaks, the photo count doubles and the test notices.
    ///  3. **One PNG and one HEIC**, because the library picker can hand back
    ///     either and the export's re-encode is what saves the server from a
    ///     format PHP typically cannot read.
    static func seedPhotos(_ context: ModelContext) {
        let plants = (try? context.fetch(FetchDescriptor<Plant>())) ?? []

        for (index, plant) in plants.enumerated() {
            autoreleasepool {
                let image = synthesise(label: plant.displayName, hue: Double(index) / Double(max(plants.count, 1)))
                let data: Data?

                switch index % 3 {
                case 1: data = image.pngData()
                case 2: data = heic(image) ?? image.jpegData(compressionQuality: 0.9)
                default: data = image.jpegData(compressionQuality: 0.9)
                }

                guard let data else { return }

                plant.photoData = data

                // The same bytes in two places, exactly as a photo reminder
                // leaves them.
                let snapshot = CareLog(type: .photoChanged, date: .now.addingTimeInterval(-3600), photoData: data)
                snapshot.plant = plant
                context.insert(snapshot)

                // And one *older*, different photo, so the plant's history has
                // more than one entry and the two hashes are genuinely distinct.
                if let older = synthesise(label: "\(plant.displayName) (older)", hue: 0.5)
                    .jpegData(compressionQuality: 0.9) {
                    let previous = CareLog(type: .photoChanged, date: .now.addingTimeInterval(-864_000), photoData: older)
                    previous.plant = plant
                    context.insert(previous)
                }
            }
        }

        try? context.save()
    }

    /// Runs the exporter and writes a one-line report to stdout.
    ///
    /// Exits the process afterwards, because the point is a scriptable run and a
    /// simulator app that stays open makes the script wait for a timeout.
    static func runHeadlessExport(to path: String, container: ModelContainer, reminderMinutes: Int) async {
        let exporter = DataExporter(modelContainer: container)
        let url = URL(fileURLWithPath: path)

        do {
            let result = try await exporter.export(to: url, reminderMinutes: reminderMinutes)
            let counts = result.counts
            print("""
            EXPORT-OK path=\(result.url.path) bytes=\(result.byteSize) \
            rooms=\(counts.rooms) plants=\(counts.plants) schedules=\(counts.schedules) \
            seasons=\(counts.wateringSeasons) logs=\(counts.logs) photos=\(counts.photos) \
            skipped=\(counts.photosSkipped)
            """)
        } catch {
            print("EXPORT-FAILED \(error)")
        }

        exit(0)
    }

    // MARK: - Image synthesis

    /// A plausible camera-sized image with the plant's name drawn large, so a
    /// person looking at the imported result can tell which photo is which.
    private static func synthesise(label: String, hue: Double) -> UIImage {
        let size = CGSize(width: 3024, height: 4032)
        let renderer = UIGraphicsImageRenderer(size: size, format: {
            let format = UIGraphicsImageRendererFormat.default()
            format.scale = 1

            return format
        }())

        return renderer.image { context in
            UIColor(hue: hue, saturation: 0.45, brightness: 0.55, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))

            // Some structure, so the JPEG does not compress to nothing and the
            // byte sizes stay in a realistic range.
            UIColor(hue: hue, saturation: 0.7, brightness: 0.85, alpha: 1).setFill()

            for row in 0..<24 {
                for column in 0..<18 {
                    if (row + column).isMultiple(of: 2) {
                        context.fill(CGRect(x: column * 168, y: row * 168, width: 168, height: 168))
                    }
                }
            }

            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: 220),
                .foregroundColor: UIColor.white,
            ]
            let text = label as NSString
            let bounds = text.size(withAttributes: attributes)
            text.draw(
                at: CGPoint(x: (size.width - bounds.width) / 2, y: (size.height - bounds.height) / 2),
                withAttributes: attributes
            )
        }
    }

    /// HEIC, when the simulator's encoder supports it. Nil is a fine answer —
    /// the caller falls back to JPEG and the test still runs.
    private static func heic(_ image: UIImage) -> Data? {
        guard let cgImage = image.cgImage else { return nil }

        let data = NSMutableData()

        guard let destination = CGImageDestinationCreateWithData(data, "public.heic" as CFString, 1, nil) else {
            return nil
        }

        CGImageDestinationAddImage(destination, cgImage, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)

        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
#endif
