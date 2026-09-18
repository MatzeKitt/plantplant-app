import Foundation

/// The part of an export that is not photos.
///
/// The envelope's fields are top-level in this format rather than nested under a
/// key — `writeFlattened` puts them there — so it decodes from the same decoder
/// as the two arrays beside it.
struct ExportDocument: Decodable {
    let envelope: ExportEnvelope
    let rooms: [RoomDTO]
    let plants: [PlantDTO]

    enum CodingKeys: String, CodingKey {
        case rooms, plants
    }

    init(from decoder: Decoder) throws {
        envelope = try ExportEnvelope(from: decoder)

        let values = try decoder.container(keyedBy: CodingKeys.self)
        rooms = try values.decodeIfPresent([RoomDTO].self, forKey: .rooms) ?? []
        plants = try values.decodeIfPresent([PlantDTO].self, forKey: .plants) ?? []
    }
}

/// Reads `plantplant.export` back off disk.
///
/// The mirror image of `JSONStreamWriter`, and for the same reason. Everything
/// but the photo map is a few hundred kilobytes and goes through `JSONDecoder`;
/// the photo map is almost the entire file and is walked one entry at a time.
/// Handing the whole document to `JSONSerialization` would hold the file, the
/// parsed tree *and* every base64 string at once — which is precisely the peak
/// memory the exporter was written to avoid, on the same phone, except now with
/// the app in the foreground where being killed is something the user watches
/// happen.
///
/// It leans on the one ordering guarantee the format makes on purpose: `photos`
/// is the last key of the document. That is what lets every reference be
/// validated before a single image is touched.
struct ExportReader {
    enum ReaderError: LocalizedError {
        case unreadable
        case notAnExport
        case photoMapMissing
        case malformedPhotoMap
        case unsupportedVersion(Int)

        var errorDescription: String? {
            switch self {
            case .unreadable:
                return String(localized: "That file could not be read.")
            case .notAnExport:
                return String(localized: "That doesn't look like a PlantPlant export.")
            case .photoMapMissing:
                return String(localized: "The file is incomplete — it stops before the photos. It was probably cut off while being copied.")
            case .malformedPhotoMap:
                return String(localized: "The photo section of the file is damaged.")
            case .unsupportedVersion(let version):
                return String(localized: "This export was written by a newer version of PlantPlant (format \(version)). Update the app and try again.")
            }
        }
    }

    /// Mapped, not loaded. The 24 MB never becomes 24 MB of resident memory; the
    /// pages the scan touches are faulted in and can be evicted again.
    private let data: Data

    /// Byte offset of the first entry inside the `photos` object — past the
    /// key, the colon and the opening brace.
    private let photosStart: Int

    let document: ExportDocument

    init(url: URL) throws {
        guard let mapped = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            throw ReaderError.unreadable
        }

        data = mapped

        guard let split = Self.photoMapSplit(in: mapped) else {
            // A truncated file is the overwhelmingly likely cause: everything
            // before `photos` is tiny, so a transfer that stops early almost
            // always stops inside the images.
            throw ReaderError.photoMapMissing
        }

        photosStart = split.entriesStart

        // `{ … }` — the head as its own document, with the photo map amputated.
        var head = Data(mapped[mapped.startIndex ..< (mapped.startIndex + split.headEnd)])
        head.append(UInt8(ascii: "}"))

        guard let decoded = try? JSONDecoder().decode(ExportDocument.self, from: head) else {
            throw ReaderError.notAnExport
        }

        guard decoded.envelope.format == ExportFormat.name else {
            throw ReaderError.notAnExport
        }

        guard decoded.envelope.formatVersion <= ExportFormat.version else {
            throw ReaderError.unsupportedVersion(decoded.envelope.formatVersion)
        }

        document = decoded
    }

    /// Every photo in the file, one at a time.
    ///
    /// `body` is handed the declared hash and the decoded JPEG, and is expected
    /// to be done with the bytes when it returns — nothing here retains them, so
    /// peak memory stays at one image however many there are. A value that is not
    /// valid base64 arrives as nil rather than being dropped: a photo silently
    /// missing from an import is the one outcome nobody can debug afterwards.
    ///
    /// Verification is the caller's job rather than this reader's, because what
    /// to *do* about a photo whose bytes don't match its hash is an import
    /// policy question (skip it, null its references, warn) and not a parsing one.
    func forEachPhoto(_ body: (String, Data?) throws -> Void) throws {
        var index = photosStart

        while true {
            skipWhitespace(&index)

            guard index < data.count else { throw ReaderError.malformedPhotoMap }

            switch byte(at: index) {
            case UInt8(ascii: "}"):
                return
            case UInt8(ascii: ","):
                index += 1
                continue
            case UInt8(ascii: "\""):
                break
            default:
                throw ReaderError.malformedPhotoMap
            }

            guard let key = readQuoted(&index) else { throw ReaderError.malformedPhotoMap }

            skipWhitespace(&index)

            guard index < data.count, byte(at: index) == UInt8(ascii: ":") else {
                throw ReaderError.malformedPhotoMap
            }

            index += 1
            skipWhitespace(&index)

            guard let base64 = readQuotedRange(&index) else { throw ReaderError.malformedPhotoMap }

            // Decoded straight from the mapped bytes. Going via `String` would
            // cost a second full-size copy of the base64 for no benefit.
            try body(key, Data(base64Encoded: Data(data[base64]), options: []))
        }
    }

    /// The number of entries in the photo map, without decoding any of them.
    ///
    /// The preview screen needs a count and nothing else, and base64-decoding 24
    /// MB of images to produce one integer would turn "show me what's in this
    /// file" into a progress bar.
    func photoCount() throws -> Int {
        var count = 0
        var index = photosStart

        while true {
            skipWhitespace(&index)

            guard index < data.count else { throw ReaderError.malformedPhotoMap }

            switch byte(at: index) {
            case UInt8(ascii: "}"):
                return count
            case UInt8(ascii: ","):
                index += 1
                continue
            case UInt8(ascii: "\""):
                break
            default:
                throw ReaderError.malformedPhotoMap
            }

            guard readQuoted(&index) != nil else { throw ReaderError.malformedPhotoMap }

            skipWhitespace(&index)

            guard index < data.count, byte(at: index) == UInt8(ascii: ":") else {
                throw ReaderError.malformedPhotoMap
            }

            index += 1
            skipWhitespace(&index)

            guard readQuotedRange(&index) != nil else { throw ReaderError.malformedPhotoMap }

            count += 1
        }
    }

    // MARK: - Scanning

    private func byte(at index: Int) -> UInt8 {
        data[data.startIndex + index]
    }

    private func skipWhitespace(_ index: inout Int) {
        while index < data.count {
            switch byte(at: index) {
            case UInt8(ascii: " "), UInt8(ascii: "\n"), UInt8(ascii: "\r"), UInt8(ascii: "\t"):
                index += 1
            default:
                return
            }
        }
    }

    /// Consumes `"…"` starting at `index` and returns the byte range of its
    /// contents.
    ///
    /// No escape handling, deliberately. The only strings this walks are the
    /// photo map's: hex hashes and base64, whose alphabets are
    /// `[0-9a-f]` and `[A-Za-z0-9+/=]`. Neither can contain a quote or a
    /// backslash, so the first closing quote is the real one. Pointing this at
    /// arbitrary JSON text would be wrong, which is why it is private.
    private func readQuotedRange(_ index: inout Int) -> Range<Data.Index>? {
        guard index < data.count, byte(at: index) == UInt8(ascii: "\"") else { return nil }

        let start = index + 1
        var end = start

        while end < data.count, byte(at: end) != UInt8(ascii: "\"") {
            end += 1
        }

        guard end < data.count else { return nil }

        index = end + 1

        return (data.startIndex + start) ..< (data.startIndex + end)
    }

    private func readQuoted(_ index: inout Int) -> String? {
        guard let range = readQuotedRange(&index) else { return nil }

        return String(decoding: data[range], as: UTF8.self)
    }

    /// Where to cut the head off, and where the photo entries begin.
    ///
    /// Not a byte search for `"photos":{`, for two reasons — and *not* the one
    /// that first suggests itself. User text cannot forge the marker: JSON
    /// escapes an embedded quote as `\"`, so an unescaped `"` only ever delimits
    /// a string, and a plant note reading `,"photos":{` lands in the file as
    /// `,\"photos\":{` and matches nothing.
    ///
    /// What does go wrong is subtler. `photos` is already not a unique key in
    /// this format — the envelope's `counts` object has one too — so the name
    /// alone does not identify the map; only its depth does. And searching
    /// backwards to get the last match instead would drag the scan through all
    /// 24 MB of images to find something that sits just past the head.
    ///
    /// So this walks the document: string state, escape state, nesting depth,
    /// and a `photos` key accepted only at depth 1 and only when its value opens
    /// an object. It stops the moment it finds one, and the format puts `photos`
    /// last, so the walk covers the head and never enters the images.
    private static func photoMapSplit(in data: Data) -> (headEnd: Int, entriesStart: Int)? {
        data.withUnsafeBytes { raw -> (headEnd: Int, entriesStart: Int)? in
            let bytes = raw.bindMemory(to: UInt8.self)
            let quote = UInt8(ascii: "\"")
            let backslash = UInt8(ascii: "\\")

            var index = 0
            var depth = 0

            while index < bytes.count {
                let byte = bytes[index]

                if byte == quote {
                    // A string. At depth 1 it may be a key, which is the only
                    // place `photos` can legitimately appear.
                    let start = index + 1
                    var end = start

                    while end < bytes.count {
                        if bytes[end] == backslash {
                            end += 2
                            continue
                        }
                        if bytes[end] == quote { break }
                        end += 1
                    }

                    guard end < bytes.count else { return nil }

                    var after = end + 1
                    while after < bytes.count, bytes[after] == UInt8(ascii: " ") { after += 1 }

                    let isKey = after < bytes.count && bytes[after] == UInt8(ascii: ":")
                    let isPhotos = depth == 1 && isKey && end - start == 6
                        && bytes[start] == UInt8(ascii: "p") && bytes[start + 1] == UInt8(ascii: "h")
                        && bytes[start + 2] == UInt8(ascii: "o") && bytes[start + 3] == UInt8(ascii: "t")
                        && bytes[start + 4] == UInt8(ascii: "o") && bytes[start + 5] == UInt8(ascii: "s")

                    if isPhotos {
                        var value = after + 1
                        while value < bytes.count, bytes[value] == UInt8(ascii: " ") { value += 1 }

                        guard value < bytes.count, bytes[value] == UInt8(ascii: "{") else { return nil }

                        // The head is cut before the key, taking the comma that
                        // separates it from `plants` with it; the entries start
                        // just past the opening brace of the value.
                        let headEnd = index > 0 && bytes[index - 1] == UInt8(ascii: ",") ? index - 1 : index

                        return (headEnd: headEnd, entriesStart: value + 1)
                    }

                    index = after

                    continue
                }

                switch byte {
                case UInt8(ascii: "{"), UInt8(ascii: "["):
                    depth += 1
                case UInt8(ascii: "}"), UInt8(ascii: "]"):
                    depth -= 1
                default:
                    break
                }

                index += 1
            }

            return nil
        }
    }
}
