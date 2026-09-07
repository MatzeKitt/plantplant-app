import Foundation

/// Writes a JSON document to a file incrementally.
///
/// The whole reason this exists rather than one `JSONEncoder.encode(document)`
/// is the photo map. Encoding a 24 MB export in one go means holding the JSON
/// *and* the object graph *and* every base64 string in memory at once, which on
/// a phone gets the app killed. Here the small parts are encoded normally and
/// the photos are appended one at a time, so peak memory is one image.
///
/// It is deliberately not a general-purpose JSON library. It knows how to open
/// an object, write an encodable value for a key, stream a map of strings, and
/// close — which is exactly the shape of this one format and nothing more.
final class JSONStreamWriter {
    enum WriterError: Error {
        case cannotCreateFile(URL)
    }

    private let handle: FileHandle
    private var needsComma = false

    /// Buffered so that writing a plant is not a syscall per plant. Flushed
    /// whenever it grows past the threshold and again at close.
    private var buffer = Data()
    private let bufferLimit = 256 * 1024

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        // Stable key order makes two exports of unchanged data byte-identical,
        // which is what lets a person diff them to see what actually changed.
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        return encoder
    }()

    init(url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw WriterError.cannotCreateFile(url)
        }

        handle = try FileHandle(forWritingTo: url)
    }

    func beginDocument() {
        append("{")
        needsComma = false
    }

    func endDocument() throws {
        append("}")
        try flush()
        try handle.close()
    }

    /// One `"key": <encoded value>` pair.
    func write<T: Encodable>(_ value: T, forKey key: String) throws {
        separator()
        append("\(quoted(key)):")
        buffer.append(try Self.encoder.encode(value))
        try flushIfLarge()
    }

    /// Splices an encodable object's members in at the current level.
    ///
    /// The envelope's fields are top-level in this format, not nested under a
    /// key, so it is encoded as one object and its outer braces are trimmed.
    /// Safe only because the value is known to encode to a JSON *object* and is
    /// small — the envelope is a few hundred bytes.
    func writeFlattened<T: Encodable>(_ value: T) throws {
        let encoded = try Self.encoder.encode(value)

        guard encoded.count > 2, encoded.first == UInt8(ascii: "{"), encoded.last == UInt8(ascii: "}") else {
            return
        }

        separator()
        buffer.append(encoded.dropFirst().dropLast())
        try flushIfLarge()
    }

    /// Opens `"key": [` — elements follow via `writeElement`, then `endArray`.
    func beginArray(forKey key: String) {
        separator()
        append("\(quoted(key)):[")
        needsComma = false
    }

    func writeElement<T: Encodable>(_ value: T) throws {
        separator()
        buffer.append(try Self.encoder.encode(value))
        try flushIfLarge()
    }

    func endArray() {
        append("]")
        needsComma = true
    }

    /// Opens `"key": {` for a map written key by key.
    func beginObject(forKey key: String) {
        separator()
        append("\(quoted(key)):{")
        needsComma = false
    }

    /// One `"key": "value"` pair inside a streamed object.
    ///
    /// The value is written as a raw quoted string with no escaping, because the
    /// only thing this is used for is base64 — which is `[A-Za-z0-9+/=]` and can
    /// contain nothing that needs escaping. Passing arbitrary text through here
    /// would produce invalid JSON.
    func writeBase64(_ base64: String, forKey key: String) throws {
        separator()
        append("\(quoted(key)):\"\(base64)\"")
        try flushIfLarge()
    }

    func endObject() {
        append("}")
        needsComma = true
    }

    /// Removes a partially written file. Called when the export is cancelled or
    /// fails, so a half-finished document can never be shared by mistake.
    static func discard(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func separator() {
        if needsComma {
            append(",")
        }

        needsComma = true
    }

    private func quoted(_ key: String) -> String {
        // Keys in this format are all fixed identifiers or hex hashes.
        "\"\(key)\""
    }

    private func append(_ text: String) {
        buffer.append(contentsOf: Array(text.utf8))
    }

    private func flushIfLarge() throws {
        if buffer.count >= bufferLimit {
            try flush()
        }
    }

    private func flush() throws {
        guard !buffer.isEmpty else { return }

        try handle.write(contentsOf: buffer)
        buffer.removeAll(keepingCapacity: true)
    }
}
