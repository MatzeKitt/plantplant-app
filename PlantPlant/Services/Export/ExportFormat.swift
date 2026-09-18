import Foundation

/// The constants and formatters that define `plantplant.export`, in one place.
///
/// The web app has a mirror of this document at `docs/export-format.md`, and a
/// committed fixture both sides code against. Anything changed here has to be
/// changed there in the same breath, which is exactly why it is all in one file
/// rather than scattered across the DTOs.
enum ExportFormat {
    static let name = "plantplant.export"
    static let version = 1
    static let photoEncoding = "base64/jpeg"

    /// The long edge photos are downscaled to on export.
    ///
    /// Not "ship what is on the device", and deliberately so: originals come to
    /// roughly 120 MB after base64, which fails on PHP's upload limit, on
    /// nginx's body limit, and on Safari suspending the tab mid-upload. 2000 px
    /// is *exactly* the largest derivative either app ever renders, so nothing
    /// visible is lost — and the re-encode also flattens EXIF orientation into
    /// the pixels and turns HEIC the library picker handed back into JPEG, which
    /// PHP typically cannot read.
    static let photoLongEdge: CGFloat = 2000

    static let photoQuality: CGFloat = 0.80

    /// ISO 8601 with an explicit offset, never epoch seconds.
    ///
    /// Epoch is an unambiguous instant but throws away the only thing this app's
    /// logic cares about: which local calendar day the instant fell on. Every
    /// date comparison in both apps is a whole-day comparison.
    ///
    /// This is also why the DTOs hold `String` rather than `Date`: there is no
    /// `JSONEncoder.dateEncodingStrategy` that writes a local offset, and the
    /// offset is the load-bearing detail of the whole format.
    static func instant(_ date: Date, in timeZone: TimeZone = .current) -> String {
        date.formatted(
            Date.ISO8601FormatStyle(
                dateSeparator: .dash,
                dateTimeSeparator: .standard,
                timeSeparator: .colon,
                timeZoneSeparator: .colon,
                includingFractionalSeconds: false,
                timeZone: timeZone
            )
        )
    }

    /// The calendar day an instant falls on, as this device sees it.
    ///
    /// Shipped alongside every day-semantic instant because `nextDue` values are
    /// in the *future*, and the importing server deciding "is this due today?"
    /// next month needs the rule, not one historical offset. **If the two ever
    /// disagree, the device wins** — the importer stores this string and does
    /// not recompute it.
    static func localDay(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)

        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// Reads back an instant written by `instant(_:)`.
    ///
    /// `ISO8601DateFormatter` rather than `Date.ISO8601FormatStyle`, because the
    /// format style's parser has to be told the exact shape it is about to see,
    /// and the shape here carries a numeric offset that differs per file —
    /// `+02:00` from this phone, `Z` from a UTC server, `+12:00` from the
    /// Auckland fixture. `.withInternetDateTime` accepts all three, which is the
    /// whole point of shipping the offset rather than an epoch.
    ///
    /// Returns nil rather than throwing: a single unparseable date is a field to
    /// fall back on with a warning, not a reason to reject someone's library.
    static func date(parsing text: String) -> Date? {
        parser.date(from: text)
    }

    /// Shared because constructing one costs more than parsing with it. Date
    /// formatters have been safe to use concurrently since iOS 7, and this one
    /// is only ever touched from inside `DataImporter`'s actor anyway.
    private static let parser: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        return formatter
    }()

    static func generator() -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"

        return "PlantPlant iOS \(version) (build \(build))"
    }
}
