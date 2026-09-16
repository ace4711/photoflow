import Foundation

/// Fas 6: en versionerad, `Codable` ögonblicksbild av EN pipeline-körning
/// ("session"), skriven atomiskt till `photoflow_session.json` i
/// outputmappen och uppdaterad efter varje steg (se
/// `PipelineState.syncManifest`).
///
/// Bakgrund: innan denna fas lämnade en körning efter sig ett dussin löst
/// kopplade filer (`bracket_groups.json`, `cull_decisions.json`, ...) och
/// "hoppa över"-beslut byggde bara på antal (t.ex. "samma antal NEF-filer
/// som sist" — se `PipelineRunner+Brackets.swift`s gamla kommentar). En
/// ändrad inställning (t.ex. `maxTimeGap`) upptäcktes bara om den händelsevis
/// också ändrade filantalet. `SessionManifest.steps[...].inputFingerprint`
/// (se `SessionManifestStore.fingerprint`) löser det: en billig, STABIL
/// (icke-slumpad — INTE Swift's `Hasher`, som har en ny slumpad seed varje
/// processstart och därför aldrig skulle matcha mellan körningar) hash av
/// stegets faktiska indata + relevanta inställningar.
///
/// De gamla lösa filerna tas INTE bort av denna fas — Lightroom-pluginet och
/// användarens egen felsökning förlitar sig på dem (se `agent-rules.md`), och
/// `SessionManifestStore.migrate` bygger upp ett manifest RETROAKTIVT från dem
/// för sessioner som kördes före Fas 6, så gamla sessioner fortsätter fungera
/// utan att behöva köras om.
struct SessionManifest: Codable, Equatable {
    /// Bump om fältformatet ändras på ett sätt som gör en äldre
    /// `photoflow_session.json` otillförlitlig att läsa rakt av — i så fall
    /// bör läsaren falla tillbaka på `SessionManifestStore.migrate` precis
    /// som för en session som helt saknar manifest.
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var sessionID: UUID
    var createdAt: Date
    var updatedAt: Date
    var inputDirectory: String
    var outputDirectory: String
    var photoCount: Int
    var groupCount: Int
    var addresses: [AddressRecord]
    /// Nyckel: `DashboardStep.manifestKey` (stabil sträng, INTE `rawValue`,
    /// som skulle kunna ändras om `DashboardStep`s case-ordning ändras).
    var steps: [String: StepRecord]
    var cullSummary: CullSummary

    struct AddressRecord: Codable, Equatable {
        var address: String
        var eventTitle: String
        var latitude: Double?
        var longitude: Double?
        var manuallyCorrected: Bool
    }

    struct StepRecord: Codable, Equatable {
        var stepID: String
        /// Fritext-spegling av `StepPhase` (`"\(phase)"`) — bara för
        /// visning/felsökning i den råa JSON-filen, ingen kod fattar beslut
        /// baserat på att kunna PARSA tillbaka den här strängen till en
        /// `StepPhase`.
        var phase: String
        var processedCount: Int
        var totalCount: Int
        var duration: TimeInterval?
        var finishedAt: Date?
        /// `nil` för steg som ännu inte satt ett fingerprint (t.ex. innan
        /// Fas 6, eller steg som medvetet inte fingerprint-gates:as än — se
        /// `PipelineRunner+Brackets`/`+AITagging` för de steg som gör det).
        var inputFingerprint: String?
    }

    struct CullSummary: Codable, Equatable {
        var accepted: Int
        var rejected: Int
        var unreviewed: Int
    }
}

extension DashboardStep {
    /// Stabil sträng-nyckel för `SessionManifest.steps`, oberoende av
    /// `rawValue` (som är en positionsberoende `Int` — att lägga till/flytta
    /// ett steg i `DashboardStep` skulle annars tyst byta vilket steg en
    /// gammal manifestpost pekar på).
    var manifestKey: String {
        switch self {
        case .watchSources: return "watchSources"
        case .copyToInput: return "copyToInput"
        case .convertToDNG: return "convertToDNG"
        case .generatePreviews: return "generatePreviews"
        case .findCalendarInfo: return "findCalendarInfo"
        case .aiTagging: return "aiTagging"
        case .createHDR: return "createHDR"
        case .moveToFolders: return "moveToFolders"
        case .writeIPTCTags: return "writeIPTCTags"
        case .manualReview: return "manualReview"
        case .importToLightroom: return "importToLightroom"
        }
    }
}
