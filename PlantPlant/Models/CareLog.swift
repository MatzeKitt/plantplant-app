import Foundation
import SwiftData

@Model
final class CareLog {
    var id: UUID = UUID()
    var typeRaw: String = LogType.note.rawValue
    var date: Date = Date()
    var note: String = ""

    /// The photo captured with this entry (for `.photoChanged`/`.created` logs), stored so the
    /// journal can show it and the plant can offer a swipeable history of past photos.
    @Attribute(.externalStorage)
    var photoData: Data?

    /// For `.edited` logs that changed the sunlight and/or "water when" level: the old and new
    /// levels (1-based number of filled icons), so the journal can render the change as icons
    /// instead of text. `nil` when this edit didn't touch that setting.
    var sunlightFrom: Int?
    var sunlightTo: Int?
    var soilFrom: Int?
    var soilTo: Int?

    var plant: Plant?

    init(type: LogType, date: Date = Date(), note: String = "", photoData: Data? = nil) {
        self.id = UUID()
        self.typeRaw = type.rawValue
        self.date = date
        self.note = note
        self.photoData = photoData
    }

    var type: LogType {
        get { LogType(rawValue: typeRaw) ?? .note }
        set { typeRaw = newValue.rawValue }
    }
}
