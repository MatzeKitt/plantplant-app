import SwiftUI

/// How much light a plant needs.
enum SunlightLevel: String, Codable, CaseIterable, Identifiable {
    case low, medium, brightIndirect, directSun

    var id: String { rawValue }

    var label: String {
        switch self {
        case .low: return String(localized: "Low light")
        case .medium: return String(localized: "Medium light")
        case .brightIndirect: return String(localized: "Bright, indirect")
        case .directSun: return String(localized: "Direct sun")
        }
    }

    var symbol: String {
        switch self {
        case .low: return "moon.stars"
        case .medium: return "cloud.sun"
        case .brightIndirect: return "sun.max"
        case .directSun: return "sun.max.fill"
        }
    }
}

/// How dry the soil should get before watering again.
enum SoilDryness: String, Codable, CaseIterable, Identifiable {
    case keepMoist, topDry, halfDry, fullyDry

    var id: String { rawValue }

    var label: String {
        switch self {
        case .keepMoist: return String(localized: "Keep moist")
        case .topDry: return String(localized: "Let top of soil dry")
        case .halfDry: return String(localized: "Let half dry out")
        case .fullyDry: return String(localized: "Let fully dry out")
        }
    }

    var symbol: String {
        switch self {
        case .keepMoist: return "humidity.fill"
        case .topDry: return "drop.fill"
        case .halfDry: return "drop.halffull"
        case .fullyDry: return "drop"
        }
    }
}

/// A recurring plant-care activity.
enum CareType: String, Codable, CaseIterable, Identifiable {
    case water, fertilize, mist, repot, photo

    var id: String { rawValue }

    var label: String {
        switch self {
        case .water: return String(localized: "Water")
        case .fertilize: return String(localized: "Fertilize")
        case .mist: return String(localized: "Mist")
        case .repot: return String(localized: "Repot")
        case .photo: return String(localized: "Photo")
        }
    }

    /// Noun naming this care type's interval, used in edit-history diffs. Kept separate from
    /// `label` so German can use the proper compound stem (e.g. "Gieß-Intervall", not
    /// "Gießen-Intervall").
    var intervalLabel: String {
        switch self {
        case .water: return String(localized: "Watering interval")
        case .fertilize: return String(localized: "Fertilizing interval")
        case .mist: return String(localized: "Misting interval")
        case .repot: return String(localized: "Repotting interval")
        case .photo: return String(localized: "Photo interval")
        }
    }

    var symbol: String {
        switch self {
        case .water: return "drop.fill"
        case .fertilize: return "leaf.fill"
        case .mist: return "humidity.fill"
        case .repot: return "arrow.up.bin.fill"
        case .photo: return "camera.fill"
        }
    }

    /// Name of the color set in the asset catalog used to tint this care type.
    var colorName: String {
        switch self {
        case .water: return "CareWater"
        case .fertilize: return "CareFertilize"
        case .mist: return "CareMist"
        case .repot: return "CareRepot"
        case .photo: return "CarePhoto"
        }
    }

    var tint: Color { Color(colorName) }

    /// Sensible default interval in days when a schedule is first enabled.
    var defaultIntervalDays: Int {
        switch self {
        case .water: return 7
        case .fertilize: return 30
        case .mist: return 3
        case .repot: return 365
        case .photo: return 30
        }
    }

    /// The log entry produced when this care task is completed.
    var completionLog: LogType {
        switch self {
        case .water: return .watered
        case .fertilize: return .fertilized
        case .mist: return .misted
        case .repot: return .repotted
        case .photo: return .photoChanged
        }
    }

    /// "Last done" phrasing for the editor's date picker. Kept as full localized phrases
    /// (rather than lowercasing a label at runtime) so proper nouns stay capitalized —
    /// e.g. German "Zuletzt fotografiert", not "Zuletzt foto aktualisiert".
    var lastDoneLabel: String {
        switch self {
        case .water: return String(localized: "Last watered")
        case .fertilize: return String(localized: "Last fertilized")
        case .mist: return String(localized: "Last misted")
        case .repot: return String(localized: "Last repotted")
        case .photo: return String(localized: "Last photographed")
        }
    }
}

/// Every recorded change on a plant.
enum LogType: String, Codable, CaseIterable, Identifiable {
    case watered, fertilized, misted, repotted
    case photoChanged, created, edited, archived, restored, note, snoozed

    var id: String { rawValue }

    var label: String {
        switch self {
        case .watered: return String(localized: "Watered")
        case .fertilized: return String(localized: "Fertilized")
        case .misted: return String(localized: "Misted")
        case .repotted: return String(localized: "Repotted")
        case .photoChanged: return String(localized: "Photo updated")
        case .created: return String(localized: "Added")
        case .edited: return String(localized: "Edited")
        case .archived: return String(localized: "Archived")
        case .restored: return String(localized: "Restored")
        case .note: return String(localized: "Note")
        case .snoozed: return String(localized: "Snoozed")
        }
    }

    var symbol: String {
        switch self {
        case .watered: return "drop.fill"
        case .fertilized: return "leaf.fill"
        case .misted: return "humidity.fill"
        case .repotted: return "arrow.up.bin.fill"
        case .photoChanged: return "camera.fill"
        case .created: return "plus.circle.fill"
        case .edited: return "pencil"
        case .archived: return "archivebox.fill"
        case .restored: return "arrow.uturn.backward.circle.fill"
        case .note: return "text.bubble"
        case .snoozed: return "clock.badge"
        }
    }
}
