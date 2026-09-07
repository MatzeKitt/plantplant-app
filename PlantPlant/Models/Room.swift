import Foundation
import SwiftData

@Model
final class Room {
    var id: UUID = UUID()
    var name: String = ""
    var sortIndex: Int = 0

    @Relationship(inverse: \Plant.room)
    var plants: [Plant]? = []

    init(name: String, sortIndex: Int = 0) {
        self.id = UUID()
        self.name = name
        self.sortIndex = sortIndex
    }

    /// Non-archived plants living in this room.
    var activePlants: [Plant] {
        (plants ?? []).filter { !$0.isArchived }
    }
}
