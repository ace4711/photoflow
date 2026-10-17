import Foundation

/// "Så valde PhotoFlow" (plan 4.5): ett kort sammandrag av filmens beslut för stilpanelen när
/// ingenting är markerat. Mall, antal bilder, antal låsta val och en rad per klipp med rum, rörelse
/// och övergång. Ren logik, beräknas ur specen och sparas inte.
nonisolated enum ReelChoiceSummary {

    nonisolated struct Row: Equatable, Sendable {
        var index: Int
        var assetID: String
        var room: String
        /// T.ex. "Zoom in", "Panorering →", "Hela bilden", "Egen rörelse".
        var motion: String
        /// Övergången in till klippet, t.ex. "Skjut ← 0,50 s"; nil för första klippet.
        var transition: String?
        /// Klippet har något låst val (längd, rörelse, övergång) eller bilden är låst i filmen.
        var locked: Bool
    }

    nonisolated struct Summary: Equatable, Sendable {
        /// "Villa", "Lägenhet" eller nil när mallen är okänd.
        var template: String?
        var clipCount: Int
        /// Antal val du låst: per klipp längd, rörelse och övergång, plus låsta och uteslutna bilder
        /// och ordningslåset.
        var lockedChoices: Int
        var rows: [Row]
    }

    static func summary(_ spec: ReelSpec) -> Summary {
        let byID = Dictionary(spec.assets.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let pinned = Set(spec.editor?.pinnedAssets ?? [])
        var locked = (spec.editor?.pinnedAssets ?? []).count + (spec.editor?.excludedAssets ?? []).count
            + (spec.editor?.orderLocked == true ? 1 : 0)
        var rows: [Row] = []
        for (i, clip) in spec.timeline.enumerated() {
            let asset = byID[clip.asset]
            let clipLocks = [clip.durationLocked == true, clip.motionPreset != nil, clip.transitionLocked == true]
                .filter { $0 }.count
            locked += clipLocks
            rows.append(.init(
                index: i, assetID: clip.asset,
                room: asset?.analysis?.room ?? asset?.analysis?.category ?? "Okänt rum",
                motion: motionLabel(clip),
                transition: i == 0 ? nil : transitionLabel(ReelTimeline.transition(spec, at: i)),
                locked: clipLocks > 0 || asset.map { pinned.contains($0.sha256) } == true))
        }
        return .init(template: templateLabel(spec.property.kind), clipCount: spec.timeline.count,
                     lockedChoices: locked, rows: rows)
    }

    static func templateLabel(_ kind: String?) -> String? {
        switch kind {
        case "house": return "Villa"
        case "apartment": return "Lägenhet"
        default: return nil
        }
    }

    /// Rörelsen som den faktiskt blev (läses ur nycklarna, inte ur förvalet).
    static func motionLabel(_ clip: ReelSpec.Clip) -> String {
        if clip.motionPreset == ReelMotionPlanner.Preset.custom.rawValue { return "Egen rörelse" }
        if clip.fit == .containBlur { return "Hela bilden" }
        let dz = clip.motion.to.zoom - clip.motion.from.zoom
        if abs(dz) > 1e-6 { return dz > 0 ? "Zoom in" : "Zoom ut" }
        let dx = clip.motion.to.cx - clip.motion.from.cx
        if abs(dx) > 1e-6 { return dx > 0 ? "Panorering →" : "Panorering ←" }
        return "Stilla"
    }

    /// Den effektiva övergången (efter klampning; nil = hårt klipp), t.ex. "Mjuk tona 0,50 s".
    static func transitionLabel(_ t: ReelSpec.Transition?) -> String {
        guard let t, t.type != .cut else { return "Hårt klipp" }
        let seconds = String(format: "%.2f s", t.duration).replacingOccurrences(of: ".", with: ",")
        switch t.type {
        case .crossfade: return "Mjuk tona \(seconds)"
        case .fadeThroughBlack: return "Via svart \(seconds)"
        case .push:
            let arrow: String
            switch t.direction ?? .left {
            case .left: arrow = "←"
            case .right: arrow = "→"
            case .up: arrow = "↑"
            case .down: arrow = "↓"
            }
            return "Skjut \(arrow) \(seconds)"
        case .cut: return "Hårt klipp"
        }
    }
}
