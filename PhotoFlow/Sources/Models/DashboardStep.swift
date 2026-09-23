import Foundation

enum DashboardStep: Int, CaseIterable, Identifiable {
    case watchSources = 0
    case copyToInput
    case convertToDNG
    case generatePreviews
    case findCalendarInfo
    case aiTagging
    case createHDR
    case moveToFolders
    case writeIPTCTags
    case manualReview
    case importToLightroom

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .watchSources: return "Bevaka kallor"
        // "Hämta" i stället för "Kopiera": steget kopierar bara i SD-korts-
        // flödet (rsync i RunnerWrapper.copyFromSDCardAndStart). Väljer man
        // mapp manuellt räknar det bara filerna som redan ligger där.
        // (Enum-caset och manifestKey heter fortfarande copyToInput, så
        // sparade sessioner fortsätter matcha.)
        case .copyToInput: return "Hämta filer"
        case .convertToDNG: return "Konvertera DNG"
        case .generatePreviews: return "Skapa previews"
        case .findCalendarInfo: return "Hitta bokning"
        case .writeIPTCTags: return "Skriv metadata"
        case .aiTagging: return "AI-taggning"
        case .createHDR: return "Skapa HDR"
        case .manualReview: return "Granska"
        case .moveToFolders: return "Sortera filer"
        case .importToLightroom: return "Lightroom"
        }
    }

    var subtitle: String {
        switch self {
        case .watchSources: return "SD-kort & mappar"
        case .copyToInput: return "Till inputkatalog"
        case .convertToDNG: return "NEF → DNG"
        case .generatePreviews: return "JPEG-förhandsvisning"
        case .findCalendarInfo: return "Kalender & adress"
        case .writeIPTCTags: return "GPS & IPTC-taggar"
        case .aiTagging: return "Vision-analys"
        case .createHDR: return "Bracket → HDR"
        case .manualReview: return AppSettings.shared.hdrMergeEnabled ? "Brackets & gallring" : "Gallring"
        case .moveToFolders: return "Adress-kataloger"
        case .importToLightroom: return "Plugin-import"
        }
    }

    var systemImage: String {
        switch self {
        case .watchSources: return "eye"
        case .copyToInput: return "doc.on.doc"
        case .convertToDNG: return "arrow.triangle.2.circlepath"
        case .generatePreviews: return "photo.on.rectangle"
        case .findCalendarInfo: return "calendar"
        case .writeIPTCTags: return "mappin.and.ellipse"
        case .aiTagging: return "brain"
        case .createHDR: return "square.stack.3d.up"
        case .manualReview: return "hand.tap"
        case .moveToFolders: return "folder.badge.plus"
        case .importToLightroom: return "arrow.right.doc.on.clipboard"
        }
    }

    var isAutomatic: Bool {
        switch self {
        case .manualReview: return false
        default: return true
        }
    }

    /// Row in the 2-row grid (0 = top, 1 = bottom)
    var row: Int {
        rawValue < 6 ? 0 : 1
    }
}
