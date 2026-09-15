import Foundation

enum PipelineStep: Int, CaseIterable, Identifiable {
    case idle
    case importing
    case convertingDNG
    case analyzingBrackets
    case reviewingBrackets
    case mergingHDR
    case generatingPreviews
    case taggingPhotos
    case sortingFiles
    case writingMetadata
    case culling
    case done

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .idle: return "Redo"
        case .importing: return "Importerar"
        case .convertingDNG: return "NEF → DNG"
        case .analyzingBrackets: return "Analyserar brackets"
        case .reviewingBrackets: return "Granska brackets"
        case .mergingHDR: return "HDR-sammanslagning"
        case .generatingPreviews: return "Skapar previews"
        case .taggingPhotos: return "AI-taggning"
        case .sortingFiles: return "Sorterar filer"
        case .writingMetadata: return "Skriver metadata"
        case .culling: return "Gallring"
        case .done: return "Klart"
        }
    }

    var systemImage: String {
        switch self {
        case .idle: return "circle.dashed"
        case .importing: return "sdcard"
        case .convertingDNG: return "doc.on.doc"
        case .analyzingBrackets: return "chart.bar.xaxis"
        case .reviewingBrackets: return "rectangle.stack"
        case .mergingHDR: return "square.stack.3d.up"
        case .culling: return "checkmark.circle"
        case .generatingPreviews: return "photo.on.rectangle"
        case .taggingPhotos: return "brain"
        case .sortingFiles: return "folder.badge.plus"
        case .writingMetadata: return "mappin.and.ellipse"
        case .done: return "checkmark.seal.fill"
        }
    }

    var isAutomatic: Bool {
        switch self {
        case .reviewingBrackets, .culling, .idle:
            return false
        default:
            return true
        }
    }
}
