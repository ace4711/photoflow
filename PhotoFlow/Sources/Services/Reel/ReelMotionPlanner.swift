import Foundation
import CoreGraphics

/// Väljer fit, rörelse, längd och övergång för varje klipp (plan 4.2–4.4).
/// Ren logik: bara geometri, inga bilder. All klampning görs med
/// `ReelTimeline.cropRect`/`containCrop`, så att nyckelbildernas mittpunkter
/// aldrig behöver korrigeras av renderaren.
nonisolated enum ReelMotionPlanner {

    // MARK: - Konstanter (startvärden ur planen, kalibreras med fotografen)

    static let firstDuration = 3.0
    static let lastDuration = 3.4
    static let panDuration = 2.8
    static let zoomDuration = 2.5
    static let containDuration = 2.6
    static let transitionDuration = 0.5
    static let lastTransitionDuration = 0.6
    /// Filmens standardövergång när ingen annan är vald (`ReelComposer.defaultStyle`).
    static let standardTransition = ReelSpec.Transition(type: .crossfade, direction: nil, duration: transitionDuration)
    /// Övergångens längd är alltid inom detta intervall i redigeraren (och för sista klippets förlängning).
    static let transitionRange = 0.2...1.5

    /// Zoom in/ut för vanliga klipp och för contain-blur.
    static let zoomAmount = 1.12
    static let containZoomAmount = 1.06
    /// Tempotak: andel av bildens bredd per sekund vid panorering, och andel zoom per sekund
    /// (medelvärde över klippet; easeInOut har som mest 1,5 gånger högre toppfart).
    /// Panoreringstaket höjdes från 6 till 10 % efter provkörning (1d): 6 % gav bara ~0,17 av
    /// bilden på ett klipp, för lite för att läsas som en panorering på en interiör.
    static let maxPanPerSecond = 0.10
    /// En panorering ska täcka minst så stor andel av bildbredden (skalad med `closingMotionScale`
    /// i sista klippet), så länge tempotaket och bilden tillåter det.
    static let minPanTravel = 0.25
    /// Minst så stor andel av klippen ska vara zoom/contain (men minst ett klipp från 3 klipp):
    /// interiörer har ofta saliency över nästan hela bredden, och då blev allt panorering.
    static let minZoomShare = 0.4
    static let maxZoomPerSecond = 0.04
    /// Över den här motivbredden (och exteriör) används contain-blur.
    static let wideSubject = 0.85
    /// Montage (R6b): varje halva visas så här länge (sekunder, före tempo). Ett montageklipp är två
    /// halvor efter varandra, alltså 2 × 1,8 = 3,6 s (en vanlig zoom är 2,5 s): varje halva hinner läsas
    /// utan att klippet blir en dödtid, och den interna skjutningen (0,4 s) ligger mellan dem.
    static let montageSegmentDuration = 1.8
    /// Sista klippet rör sig lugnare: så stor andel av vanlig amplitud.
    static let closingMotionScale = 0.6
    /// Kollage (R6c): ingen panorering, bara en svag gemensam zoom 1,00 → 1,04 mot respektive motivs mitt,
    /// och rutorna glider in efter varandra (`collageEntrance`).
    static let collageZoomAmount = 1.04
    static let collageEntrance = ReelSpec.Entrance(type: .slide, stagger: ReelSpec.Entrance.defaultStagger, duration: nil)
    /// Ett kollage är ett vanligt klipps längd (zoom, 2,5 s) plus ingången (stagger 0,3 s + 0,6 s) = 3,4 s,
    /// före tempo. Då hinner den andra rutan ligga stilla lika länge som en vanlig zoom.
    static let collageBaseDuration = zoomDuration + ReelSpec.Entrance.defaultStagger + ReelSpec.Entrance.defaultDuration
    /// Motivet får vara så här mycket (andel av bildbredden) bredare än rutans synliga bredd och ändå
    /// räknas som att det ryms. Interiörers saliency-boxar är ofta 0,8-0,9 av bredden (Chronas väg 7:
    /// median 0,87), så utan marginal skulle en 3:2-bild (synlig bredd 0,75 i 9:8) aldrig få en partner;
    /// 0,15 släpper igenom bilder där högst ungefär en femtedel av motivets bredd beskärs.
    static let collageFocusSlack = 0.15
    /// Stapel (9:16) är till för liggande bilder, sida vid sida (16:9) för stående. Bildförhållande
    /// (bredd/höjd) från vilket en bild räknas som liggande respektive stående i ett kollage.
    static let collageLandscapeMinAspect = 1.15
    static let collagePortraitMaxAspect = 0.87
    /// Ramar med bildförhållande mellan dessa gränser (1:1) får inget automatiskt kollage: rutorna
    /// skulle bli 2:1 (stapel) eller 1:2 (sida), alltså smalare remsor än en 3:2-bild i en kvadrat
    /// (som visar 67 % av bredden). Ett kollage i 1:1 får fotografen göra för hand (R6d).
    static let collageFrameAspectRange = 0.9...1.1

    // MARK: - Indata

    nonisolated struct Image: Sendable, Equatable {
        var assetID: String
        var width: Int
        var height: Int
        var focus: ReelSpec.Point?
        /// Motivets sammanlagda bredd, andel av bildbredden.
        var salientWidth: Double?
        var isExterior: Bool
        /// Bredden på den största saliency-boxen (tätare än `salientWidth`); styr rörelsetypen.
        var focusWidth: Double? = nil
        /// Montage (R6b): källrektanglarna för de två stående halvorna (`ReelSpec.Analysis.panels`); tom
        /// för vanliga bilder.
        var panels: [ReelSpec.UnitRect] = []
        /// Rummet (för förklaringar, t.ex. "Kollage: Kök och Matplats").
        var room: String? = nil

        var aspect: Double { height > 0 ? Double(width) / Double(height) : 1 }
        var size: CGSize { CGSize(width: width, height: height) }
    }

    nonisolated enum Kind: String, Sendable, Equatable {
        case zoom, pan, containBlur
    }

    /// Ramens bildförhållande för en output.
    static func frameAspect(_ output: ReelSpec.Output) -> Double {
        output.height > 0 ? Double(output.width) / Double(output.height) : 9.0 / 16.0
    }

    /// Synlig bredd (andel av bildbredden) i ett cover-utsnitt vid zoom 1.
    static func visibleWidth(imageAspect: Double, frameAspect: Double) -> Double {
        min(1, frameAspect / imageAspect)
    }

    /// Fotografens förval av rörelse per bild.
    nonisolated enum Preset: String, Sendable, CaseIterable, Equatable {
        case auto, zoomIn, zoomOut, panRight, panLeft, contain
        /// Start/slut dragna för hand (`ClipOverride.custom`). Inget menyval: se `selectableCases`.
        case custom

        /// Förvalen som visas i menyn (alla utom `custom`, som bara uppstår av direktmanipulation).
        static var selectableCases: [Preset] { allCases.filter { $0 != .custom } }

        var label: String {
            switch self {
            case .auto: return "Automatisk"
            case .zoomIn: return "Zooma in"
            case .zoomOut: return "Zooma ut"
            case .panRight: return "Panorera →"
            case .panLeft: return "Panorera ←"
            case .contain: return "Hela bilden (contain)"
            case .custom: return "Egen rörelse"
            }
        }
    }

    /// Filmens tempo: faktor på de *automatiska* längderna (låsta längder påverkas inte).
    nonisolated enum Tempo: String, Sendable, CaseIterable, Equatable {
        case calm, normal, fast

        var factor: Double {
            switch self {
            case .calm: return 1.2
            case .normal: return 1.0
            case .fast: return 0.85
            }
        }

        /// Ur `ReelSpec.EditorState.tempo`; okänt eller saknat värde = normal.
        init(editorValue: String?) { self = editorValue.flatMap(Tempo.init(rawValue:)) ?? .normal }
    }

    /// Fotografens egna start/slut för ett klipp (`motionPreset == "custom"`).
    nonisolated struct CustomMotion: Sendable, Equatable {
        var fit: ReelSpec.Fit
        var motion: ReelSpec.Motion
    }

    /// Ett rutklipps utformning (`fit == .panels`, spec v2): behandlas som fotografens låsta val.
    /// Planeraren ritar om varken layout, rutor, rörelse eller ingång (rutornas bilder pekar på asset-id:n
    /// i den spec som skapar låset); bara längd och övergång följer reglerna.
    nonisolated struct PanelsLock: Sendable, Equatable {
        var layout: ReelSpec.PanelLayout
        var panels: [ReelSpec.Panel]
        var gutter: Double?
        var entrance: ReelSpec.Entrance?
    }

    /// Fotografens ändringar för ett klipp. `duration` nil = automatisk längd.
    /// Övergången är låst när `transitionLocked`: `transition` används då som den är, och nil
    /// betyder "filmens `style.defaultTransition`" (skrivs som `transitionIn == nil`).
    /// `custom` används bara när `preset == .custom`; saknas det behandlas klippet som automatiskt.
    nonisolated struct ClipOverride: Sendable, Equatable {
        var preset: Preset = .auto
        var duration: Double?
        var transitionLocked = false
        var transition: ReelSpec.Transition?
        var custom: CustomMotion?
        /// Klippet är ett rutklipp som ska behållas som det är (se `PanelsLock`).
        var panels: PanelsLock?
        var isDefault: Bool {
            preset == .auto && duration == nil && !transitionLocked && custom == nil && panels == nil
        }

        /// `.custom` utan rörelse är ett förval som inte går att utföra: räkna som automatiskt.
        var effectivePreset: Preset { preset == .custom && custom == nil ? .auto : preset }
    }

    // MARK: - Montage (R6b)

    /// Halvans bildförhållande (bredd/höjd i pixlar).
    static func panelAspect(_ rect: ReelSpec.UnitRect, of image: Image) -> Double {
        let h = rect.h * Double(image.height)
        return h > 0 ? rect.w * Double(image.width) / h : 1
    }

    /// De två halvornas sammanlagda bildförhållande: så brett ska ramen vara för att hela montaget ska
    /// fylla den utan att sidorna beskärs. 0 om bilden inte är ett montage med två giltiga halvor.
    static func montageAspect(_ image: Image) -> Double {
        guard image.panels.count == 2, image.panels.allSatisfy({ $0.w > 0 && $0.h > 0 }) else { return 0 }
        return image.panels.map { panelAspect($0, of: image) }.reduce(0, +)
    }

    /// Planeras bilden som ett montage i sekvens (två rutor efter varandra)? Ja när den är ett montage,
    /// ramen är smalare än halvorna tillsammans (9:16, 1:1; i 16:9 visas det som ett vanligt klipp),
    /// klippet inte är ett låst rutklipp och fotografen inte valt ett eget förval (zooma, panorera,
    /// hela bilden, egen rörelse): ett förval gäller hela bilden som förut.
    static func isMontageSequence(_ image: Image, frameAspect: Double, override: ClipOverride?) -> Bool {
        guard override?.panels == nil, (override?.effectivePreset ?? .auto) == .auto else { return false }
        let whole = montageAspect(image)
        return whole > 0 && frameAspect < whole
    }

    /// Rutorna för ett montage i sekvens: första halvan zoomar in, den andra zoomar ut från samma zoom
    /// (så att den interna skjutningen går mellan två lika inzoomade bilder). Varje halva fyller ramen
    /// som cover mot sin egen del; mittpunkten är halvans mitt, klampad inom halvan. `segment` är
    /// varje halvas tid (sekunder) och styr tempotaket för zoomen.
    static func montagePanels(_ image: Image, frameAspect: Double, segment: Double) -> [ReelSpec.Panel] {
        let end = endZoom(amount: zoomAmount, scale: 1, duration: segment)
        return image.panels.enumerated().map { k, source in
            let half = Image(assetID: image.assetID, width: max(Int((source.w * Double(image.width)).rounded()), 1),
                             height: max(Int((source.h * Double(image.height)).rounded()), 1),
                             focus: nil, salientWidth: nil, isExterior: image.isExterior)
            func key(_ zoom: Double) -> ReelSpec.MotionKey {
                let local = clampedCenter(half, frameAspect, .cover, cx: 0.5, cy: 0.5, zoom: zoom)
                return .init(cx: source.x + Double(local.x) * source.w, cy: source.y + Double(local.y) * source.h, zoom: zoom)
            }
            let (z0, z1) = k == 0 ? (1.0, end) : (end, 1.0)
            return .init(asset: image.assetID, source: source, motion: .init(from: key(z0), to: key(z1)))
        }
    }

    // MARK: - Kollage (R6c)

    /// Layouten ett automatiskt kollage får i en ram: stapel i stående format (9:16), sida vid sida i
    /// liggande (16:9), inget i kvadratiskt (`collageFrameAspectRange`).
    static func collageLayout(frameAspect: Double) -> ReelSpec.PanelLayout? {
        if collageFrameAspectRange.contains(frameAspect) { return nil }
        return frameAspect < 1 ? .stack : .side
    }

    /// Bildförhållandet (bredd/höjd) för en ruta i layouten, med förvald gutter (9:8 för stapel i 9:16).
    static func collagePaneAspect(layout: ReelSpec.PanelLayout, frameAspect: Double,
                                  gutter: Double = ReelSpec.Clip.defaultGutter) -> Double {
        let d = ReelTimeline.panelDests(layout: layout, frameAspect: frameAspect, gutter: gutter)[0]
        return d.height > 0 ? Double(d.width) * frameAspect / Double(d.height) : frameAspect
    }

    /// Passar bildens orienteringen i layouten (liggande i stapel, stående i sida vid sida)?
    static func suitsCollage(_ image: Image, layout: ReelSpec.PanelLayout) -> Bool {
        switch layout {
        case .stack: return image.aspect >= collageLandscapeMinAspect
        case .side: return image.aspect <= collagePortraitMaxAspect
        case .sequence: return false
        }
    }

    /// Ryms motivet i rutan? `focusWidth` (annars `salientWidth`, annars 50 %) högst rutans synliga bredd
    /// plus `collageFocusSlack`.
    static func fitsPane(_ image: Image, paneAspect: Double) -> Bool {
        let subject = image.focusWidth ?? image.salientWidth ?? 0.5
        return subject <= visibleWidth(imageAspect: image.aspect, frameAspect: paneAspect) + collageFocusSlack
    }

    /// Skulle bilden i ramen annars bli contain-blur eller en hård beskärning, så att den bör få en
    /// partner? Stapel: en liggande bild vars motiv inte ryms i cover-utsnittet (eller som blir
    /// contain-blur). Sida vid sida: en stående bild i en liggande ram (cover visar bara en bråkdel av
    /// höjden). Ett montage (två bilder redan) behöver aldrig någon.
    static func needsCollage(_ image: Image, frameAspect: Double) -> Bool {
        guard let layout = collageLayout(frameAspect: frameAspect), image.panels.isEmpty,
              suitsCollage(image, layout: layout) else { return false }
        if layout == .side { return true }
        let subject = image.focusWidth ?? image.salientWidth ?? 0.5
        return kind(of: image, frameAspect: frameAspect) == .containBlur
            || subject > visibleWidth(imageAspect: image.aspect, frameAspect: frameAspect)
    }

    /// Kan `anchor` och `partner` planeras som ett kollage i ramen? Båda av rätt orientering, motiven ryms
    /// i rutan, ingen är ett montage, och fotografen har inte låst klippets utformning (förval, egen
    /// rörelse, rutklipp): längd- och övergångslås hindrar inte.
    static func collageActive(anchor: Image, partner: Image, frameAspect: Double, override: ClipOverride?) -> Bool {
        guard let layout = collageLayout(frameAspect: frameAspect),
              override?.panels == nil, (override?.effectivePreset ?? .auto) == .auto,
              anchor.panels.isEmpty, partner.panels.isEmpty, anchor.assetID != partner.assetID,
              suitsCollage(anchor, layout: layout), suitsCollage(partner, layout: layout) else { return false }
        let pane = collagePaneAspect(layout: layout, frameAspect: frameAspect)
        return fitsPane(anchor, paneAspect: pane) && fitsPane(partner, paneAspect: pane)
    }

    /// De kollage i `collages` (nyckel = första rutans bild) som gäller för bilderna i ramen.
    static func activeCollages(_ images: [Image], frameAspect: Double, overrides: [String: ClipOverride],
                               collages: [String: Image]) -> [String: Image] {
        var result: [String: Image] = [:]
        for image in images {
            if let partner = collages[image.assetID],
               collageActive(anchor: image, partner: partner, frameAspect: frameAspect, override: overrides[image.assetID]) {
                result[image.assetID] = partner
            }
        }
        return result
    }

    /// Rutorna för ett kollage: båda zoomar svagt (1,00 → 1,04) mot sitt eget motivs mittpunkt, klampad
    /// i rutans cover-utsnitt. Ingen panorering.
    static func collagePanels(anchor: Image, partner: Image, layout: ReelSpec.PanelLayout, frameAspect: Double,
                              duration: Double) -> [ReelSpec.Panel] {
        let pane = collagePaneAspect(layout: layout, frameAspect: frameAspect)
        let end = endZoom(amount: collageZoomAmount, scale: 1, duration: duration)
        return [anchor, partner].map { image in
            let focus = image.focus ?? .init(x: 0.5, y: 0.5)
            return .init(asset: image.assetID, source: nil,
                         motion: .init(from: key(image, pane, .cover, cx: focus.x, cy: focus.y, zoom: 1),
                                       to: key(image, pane, .cover, cx: focus.x, cy: focus.y, zoom: end)))
        }
    }

    /// Bildförhållandet som "9:8" (närmaste enkla kvot, minst fel under 1 %); annars två decimaler.
    static func ratioText(_ aspect: Double) -> String {
        for q in 1...16 {
            let p = Int((aspect * Double(q)).rounded())
            if p > 0, abs(Double(p) / Double(q) - aspect) < 0.01 * aspect { return "\(p):\(q)" }
        }
        return String(format: "%.2f", aspect).replacingOccurrences(of: ".", with: ",")
    }

    /// "Kök och Matplats" / "Kök (två bilder)" för ett kollage.
    static func collageRoomsText(_ a: Image, _ b: Image) -> String {
        ReelSelector.montageRooms(ReelCandidate(id: "", filename: "", panelRooms: [a.room ?? "", b.room ?? ""])) ?? "okända rum"
    }

    // MARK: - Val av rörelsetyp

    static func kind(of image: Image, frameAspect: Double) -> Kind {
        let w = visibleWidth(imageAspect: image.aspect, frameAspect: frameAspect)
        let s = image.focusWidth ?? image.salientWidth ?? 0.5
        // Ryms motivet, eller är bilden nästan lika bred som ramen (ingenting att panorera): zooma.
        if s <= w || w >= wideSubject { return .zoom }
        if s <= wideSubject { return .pan }
        // En stående bild i ett stående format ska aldrig bli contain-blur: cover ger nästan hela bilden
        // (2:3 i 9:16 visar 84 % av bredden). Chronas väg 7, DSC_9451: w = 0,844 låg just under
        // `wideSubject` (0,85), och den breda fasaden (0,93) blev contain-blur med stora suddiga band.
        if image.aspect < 1, frameAspect < 1 { return .zoom }
        return image.isExterior ? .containBlur : .pan
    }

    // MARK: - Planering

    /// Rörelsetyper per bild: förval från fotografen först, sedan automatiskt val, och till sist
    /// en medveten blandning så att minst `minZoomShare` av klippen är zoom/contain.
    static func kinds(_ images: [Image], frameAspect: Double, overrides: [String: ClipOverride] = [:],
                      collages: [String: Image] = [:]) -> [Kind] {
        kindDecisions(images, frameAspect: frameAspect, overrides: overrides, collages: collages).kinds
    }

    /// Samma val som `kinds`, plus vilka klipp som styrdes av fotografen (`forced`) och vilka som
    /// blev zoom bara genom blandningsregeln (`mixed`). Delas av `kinds` och `motionReasons`, så att
    /// förklaringen alltid följer exakt samma regel som planeringen.
    private static func kindDecisions(_ images: [Image], frameAspect: Double, overrides: [String: ClipOverride],
                                      collages: [String: Image] = [:])
        -> (kinds: [Kind], forced: Set<Int>, mixed: Set<Int>, montage: Set<Int>, collage: Set<Int>) {
        var result = images.map { kind(of: $0, frameAspect: frameAspect) }
        var forced = Set<Int>()
        var montage = Set<Int>()
        var collage = Set<Int>()
        let active = activeCollages(images, frameAspect: frameAspect, overrides: overrides, collages: collages)
        for (i, image) in images.enumerated() {
            if overrides[image.assetID]?.panels != nil { result[i] = .zoom; forced.insert(i); continue }
            // Kollage: två rutor med svag zoom; räknas som zoom men är inte fotografens val.
            if active[image.assetID] != nil { result[i] = .zoom; collage.insert(i); continue }
            // Montage i sekvens: två zoomar efter varandra, räknas som zoom men är inte fotografens val.
            if isMontageSequence(image, frameAspect: frameAspect, override: overrides[image.assetID]) {
                result[i] = .zoom; montage.insert(i); continue
            }
            switch overrides[image.assetID]?.effectivePreset ?? .auto {
            case .auto: break
            case .custom:
                if let c = overrides[image.assetID]?.custom { result[i] = customKind(c) }
                forced.insert(i)
            case .zoomIn, .zoomOut: result[i] = .zoom; forced.insert(i)
            case .panRight, .panLeft: result[i] = .pan; forced.insert(i)
            case .contain: result[i] = .containBlur; forced.insert(i)
            }
        }
        guard images.count >= 3 else { return (result, forced, [], montage, collage) }
        let wanted = max(1, Int(Double(images.count) * minZoomShare))
        var have = result.filter { $0 != .pan }.count
        var mixed = Set<Int>()
        // Smalaste motivet först: det vinner mest på att zoomas.
        let candidates = images.indices
            .filter { result[$0] == .pan && !forced.contains($0) && !montage.contains($0) && !collage.contains($0) }
            .sorted { (images[$0].focusWidth ?? images[$0].salientWidth ?? 1) < (images[$1].focusWidth ?? images[$1].salientWidth ?? 1) }
        for i in candidates where have < wanted {
            result[i] = .zoom
            mixed.insert(i)
            have += 1
        }
        return (result, forced, mixed, montage, collage)
    }

    // MARK: - Varför (rörelse)

    /// Varför ett klipp fick sin rörelsetyp (plan 4.5). Andelar är av bildens bredd: `subject` är
    /// motivbredden som regeln använde (`focusWidth`, annars `salientWidth`; nil = okänd, regeln antar
    /// då 50 %), `frame` är hur stor del av bredden ramen visar vid zoom 1 (`visibleWidth`).
    nonisolated enum MotionReason: Equatable, Sendable {
        /// Förval eller egen rörelse från fotografen.
        case chosenByUser
        /// Motivet ryms i ramen: zoom.
        case subjectFits(subject: Double?, frame: Double)
        /// Bilden är nästan lika smal som ramen (synlig bredd ≥ `wideSubject`): inget att panorera, zoom.
        case narrowImage(frame: Double)
        /// Motivet är bredare än ramen: panorering.
        case subjectWider(subject: Double?, frame: Double)
        /// Bred exteriör (motiv över `wideSubject`): hela bilden med suddig bakgrund.
        case wideExterior(subject: Double?)
        /// Montage (två stående bilder sida vid sida) i en ram som är smalare än halvorna tillsammans:
        /// halvorna visas efter varandra, var och en fyller ramen. `frame` är ramens bildförhållande
        /// (bredd/höjd) och `whole` halvornas sammanlagda.
        case montageSequence(frame: Double, whole: Double)
        /// Montage i en ram som är bred nog för hela montaget: ett vanligt klipp med rörelsetypen `kind`.
        case montageWhole(frame: Double, whole: Double, kind: Kind)
        /// Kollage (R6c): två bilder i `layout`, båda motiven ryms i rutan (bildförhållande `pane`). `rooms`
        /// är bildernas rum ("Kök och Matplats").
        case collage(layout: ReelSpec.PanelLayout, pane: Double, rooms: String)
        /// Hade panorerats, men blev zoom för att minst `minZoomShare` av klippen ska vara zoom.
        case variation(subject: Double?, frame: Double)

        /// Rörelsetypen skälet leder till (nil för fotografens egna val).
        var kind: Kind? {
            switch self {
            case .chosenByUser: return nil
            case .montageSequence, .collage: return .zoom
            case .montageWhole(_, _, let kind): return kind
            case .subjectFits, .narrowImage, .variation: return .zoom
            case .subjectWider: return .pan
            case .wideExterior: return .containBlur
            }
        }

        /// Kort förklaring på svenska, t.ex. "Panorering: motivet (62 % av bredden) är bredare än ramen (37 %)".
        var text: String {
            func pct(_ x: Double) -> String { "\(Int((x * 100).rounded())) %" }
            func ratio(_ x: Double) -> String { String(format: "%.2f", x).replacingOccurrences(of: ".", with: ",") }
            func subjectText(_ s: Double?) -> String { s.map { "motivet (\(pct($0)) av bredden)" } ?? "motivet (okänd bredd, antas 50 %)" }
            switch self {
            case .chosenByUser:
                return "Vald av dig"
            case .subjectFits(let s, let f):
                return "Zoom: \(subjectText(s)) ryms i ramen (\(pct(f)))"
            case .narrowImage(let f):
                return "Zoom: ramen visar nästan hela bildens bredd (\(pct(f))), så det finns inget att panorera"
            case .subjectWider(let s, let f):
                return "Panorering: \(subjectText(s)) är bredare än ramen (\(pct(f)))"
            case .wideExterior(let s):
                return "Hela bilden: bred exteriör, \(subjectText(s))"
            case .montageSequence(let f, let w):
                return "Montage: de två stående bilderna visas efter varandra (zoom på var och en), eftersom ramen (\(ratio(f))) är smalare än hela montaget (\(ratio(w)))"
            case .montageWhole(let f, let w, _):
                return "Montage: ramen (\(ratio(f))) är bred nog för hela montaget (\(ratio(w))), så det visas som en vanlig bild"
            case .collage(let layout, let pane, let rooms):
                let how = layout == .stack ? "staplade" : "sida vid sida"
                return "Kollage: \(rooms), båda ryms i \(ratioText(pane)) (två bilder \(how), svag gemensam zoom, ingen panorering)"
            case .variation(let s, let f):
                return "Zoom för variation (minst \(pct(minZoomShare)) zoom): \(subjectText(s)) är bredare än ramen (\(pct(f))) och hade annars panorerats"
            }
        }
    }

    /// Skälet till varje klipps rörelsetyp, i samma ordning som `images` och med exakt samma regel
    /// som `plan` (`kind(of:)`, fotografens förval och blandningsregeln). Ren funktion: beräknas på
    /// nytt när den behövs och sparas inte i specen.
    static func motionReasons(_ images: [Image], frameAspect: Double,
                              overrides: [String: ClipOverride] = [:],
                              collages: [String: Image] = [:]) -> [MotionReason] {
        let d = kindDecisions(images, frameAspect: frameAspect, overrides: overrides, collages: collages)
        let active = activeCollages(images, frameAspect: frameAspect, overrides: overrides, collages: collages)
        return images.enumerated().map { i, image in
            let frame = visibleWidth(imageAspect: image.aspect, frameAspect: frameAspect)
            let subject = image.focusWidth ?? image.salientWidth
            if d.forced.contains(i) { return .chosenByUser }
            if d.collage.contains(i), let partner = active[image.assetID], let layout = collageLayout(frameAspect: frameAspect) {
                return .collage(layout: layout, pane: collagePaneAspect(layout: layout, frameAspect: frameAspect),
                                rooms: collageRoomsText(image, partner))
            }
            if d.montage.contains(i) { return .montageSequence(frame: frameAspect, whole: montageAspect(image)) }
            if montageAspect(image) > 0 { return .montageWhole(frame: frameAspect, whole: montageAspect(image), kind: d.kinds[i]) }
            if d.mixed.contains(i) { return .variation(subject: subject, frame: frame) }
            switch d.kinds[i] {
            case .containBlur: return .wideExterior(subject: subject)
            case .pan: return .subjectWider(subject: subject, frame: frame)
            case .zoom:
                // Samma ordning som `kind(of:)`: ryms motivet räknas det före den smala bilden.
                return (subject ?? 0.5) <= frame ? .subjectFits(subject: subject, frame: frame) : .narrowImage(frame: frame)
            }
        }
    }

    /// Vilken sorts rörelse en egen rörelse är (styr grundlängd och zoomandelen): contain-blur,
    /// sidledsrörelse utan zoom = panorering, annars zoom.
    static func customKind(_ c: CustomMotion) -> Kind {
        if c.fit == .containBlur { return .containBlur }
        let dx = abs(c.motion.to.cx - c.motion.from.cx), dz = abs(c.motion.to.zoom - c.motion.from.zoom)
        return dx > 0.05 && dz < 0.05 ? .pan : .zoom
    }

    /// Planerar alla klipp. Låsta val (`overrides`) respekteras: förval, längd, övergång och egen
    /// rörelse. Automatiska klipp runt ett låst klipp får sin rytm som vanligt; ett klipp med egen
    /// rörelse räknas som det den faktiskt är i alterneringen (nästa automatiska zoom går åt andra
    /// hållet, nästa automatiska panorering åt andra hållet, och en push efter det följer dess
    /// sidledsriktning). De uttryckliga förvalen (zoomIn m.fl.) alternerar som förut inte.
    /// `tempo` skalar bara automatiska längder. Automatiska övergångar utgår från filmens
    /// standardövergång `defaultTransition` (se `automaticTransition`).
    ///
    /// `collages` är automatiska kollage (R6c): första rutans bild (asset-id) → partnerbilden. De gäller
    /// bara när `collageActive` (formatet motiverar det, motiven ryms, klippet är inte låst); annars
    /// planeras klippet som en vanlig bild och partnern ritas inte (anroparen lägger in den som eget klipp,
    /// se `ReelComposer.rebuild`).
    static func plan(_ images: [Image], frameAspect: Double, overrides: [String: ClipOverride] = [:],
                     tempo: Tempo = .normal, defaultTransition: ReelSpec.Transition = standardTransition,
                     collages: [String: Image] = [:]) -> [ReelSpec.Clip] {
        var clips: [ReelSpec.Clip] = []
        var zoomIn = true            // alterneras mellan zoom-/contain-klipp
        var panRight = true          // alterneras mellan panoreringar
        var previousPanSign = 0.0    // riktningen (+1 höger) som föregående klipp panorerade, 0 = ingen
        let kinds = kinds(images, frameAspect: frameAspect, overrides: overrides, collages: collages)
        let activeCollage = activeCollages(images, frameAspect: frameAspect, overrides: overrides, collages: collages)

        for (i, image) in images.enumerated() {
            let isFirst = i == 0, isLast = i == images.count - 1 && images.count > 1
            let kind = kinds[i]
            var override = overrides[image.assetID] ?? ClipOverride()
            override.preset = override.effectivePreset
            let autoDuration = (isFirst ? firstDuration : (isLast ? lastDuration : baseDuration(kind))) * tempo.factor
            let duration = override.duration ?? autoDuration
            let scale = isLast ? closingMotionScale : 1.0
            let focus = image.focus ?? .init(x: 0.5, y: 0.5)

            var fit = ReelSpec.Fit.cover
            var motion: ReelSpec.Motion
            var unclamped: ReelSpec.Motion?
            var panSign = 0.0

            if let lock = override.panels, let first = lock.panels.first {
                // Rutklipp: fotografens val behålls som det är; längden följer reglerna (en `sequence`
                // får en grundlängd per ruta).
                var transition: ReelSpec.Transition?
                if override.transitionLocked {
                    transition = override.transition
                } else if i > 0 {
                    transition = automaticTransition(previousPanSign: 0, isLast: isLast,
                                                     defaultTransition: defaultTransition).transition
                }
                previousPanSign = 0
                let perPanel = lock.layout == .sequence ? Double(lock.panels.count) : 1
                clips.append(.init(asset: first.asset, duration: override.duration ?? autoDuration * perPanel,
                                   fit: .panels, motion: first.motion, transitionIn: transition,
                                   motionPreset: Preset.custom.rawValue,
                                   durationLocked: override.duration == nil ? nil : true,
                                   transitionLocked: override.transitionLocked ? true : nil,
                                   layout: lock.layout, panels: lock.panels, gutter: lock.gutter, entrance: lock.entrance))
                continue
            }

            if isMontageSequence(image, frameAspect: frameAspect, override: overrides[image.assetID]) {
                // Montage i ett smalt format: två rutor efter varandra, var och en en halva som fyller
                // ramen (`layout: sequence`). Automatiskt (ingen `custom`): planeras om vid varje ombyggnad.
                let duration = override.duration ?? 2 * montageSegmentDuration * tempo.factor
                let panels = montagePanels(image, frameAspect: frameAspect, segment: duration / 2)
                var transition: ReelSpec.Transition?
                if override.transitionLocked {
                    transition = override.transition
                } else if i > 0 {
                    transition = automaticTransition(previousPanSign: previousPanSign, isLast: isLast,
                                                     defaultTransition: defaultTransition).transition
                }
                previousPanSign = 0
                clips.append(.init(asset: image.assetID, duration: duration, fit: .panels, motion: panels[0].motion,
                                   transitionIn: transition, motionPreset: nil,
                                   durationLocked: override.duration == nil ? nil : true,
                                   transitionLocked: override.transitionLocked ? true : nil,
                                   layout: .sequence, panels: panels))
                continue
            }

            if let partner = activeCollage[image.assetID], let layout = collageLayout(frameAspect: frameAspect) {
                // Kollage: två bilder i var sin ruta (stapel i 9:16, sida vid sida i 16:9), svag gemensam
                // zoom och ingång efter varandra. Automatiskt (ingen `custom`): planeras om vid varje
                // ombyggnad, så att det följer formatet.
                let duration = override.duration ?? collageBaseDuration * tempo.factor
                let panels = collagePanels(anchor: image, partner: partner, layout: layout, frameAspect: frameAspect,
                                           duration: duration)
                var transition: ReelSpec.Transition?
                if override.transitionLocked {
                    transition = override.transition
                } else if i > 0 {
                    transition = automaticTransition(previousPanSign: 0, isLast: isLast,
                                                     defaultTransition: defaultTransition).transition
                }
                previousPanSign = 0
                clips.append(.init(asset: image.assetID, duration: duration, fit: .panels, motion: panels[0].motion,
                                   transitionIn: transition, motionPreset: nil,
                                   durationLocked: override.duration == nil ? nil : true,
                                   transitionLocked: override.transitionLocked ? true : nil,
                                   layout: layout, panels: panels, gutter: nil, entrance: collageEntrance))
                continue
            }

            if override.preset == .custom, let custom = override.custom {
                // Egen rörelse: behåll fit och nycklar, klampa mittpunkt (och zoom ≥ 1) mot formatet.
                fit = custom.fit
                motion = clampedCustomMotion(image, frameAspect: frameAspect, custom: custom)
                if motion != custom.motion { unclamped = custom.motion }
                let dx = motion.to.cx - motion.from.cx
                panSign = abs(dx) > 0.02 ? (dx > 0 ? 1 : -1) : 0
                if customKind(custom) == .pan { panRight = dx < 0 }
                else { zoomIn = motion.to.zoom < motion.from.zoom }
            } else {
                switch kind {
                case .zoom, .containBlur:
                    fit = kind == .zoom ? .cover : .containBlur
                    let amount = kind == .zoom ? zoomAmount : containZoomAmount
                    let end = endZoom(amount: amount, scale: scale, duration: duration)
                    let goIn: Bool
                    switch override.preset {
                    case .zoomIn: goIn = true
                    case .zoomOut: goIn = false
                    default: goIn = zoomIn; zoomIn.toggle()
                    }
                    let (z0, z1) = goIn ? (1.0, end) : (end, 1.0)
                    // Litet drift i sidled under zoomen (bara för cover; contain-blur står still).
                    let drift = kind == .zoom ? 0.01 * (panRight ? 1 : -1) : 0
                    let from = key(image, frameAspect, fit, cx: focus.x - drift, cy: focus.y, zoom: z0)
                    let to = key(image, frameAspect, fit, cx: focus.x + drift, cy: focus.y, zoom: z1)
                    motion = .init(from: from, to: to)
                case .pan:
                    let w = visibleWidth(imageAspect: image.aspect, frameAspect: frameAspect)
                    let s = image.salientWidth ?? 1
                    let cap = maxPanPerSecond * duration * scale
                    let travel = min(cap, max(s - w, minPanTravel * scale))
                    let sign: Double
                    switch override.preset {
                    case .panRight: sign = 1
                    case .panLeft: sign = -1
                    default: sign = panRight ? 1 : -1; panRight.toggle()
                    }
                    let (a, b) = panRange(image, frameAspect, centerX: focus.x, travel: travel, sign: sign)
                    let y = clampedCenter(image, frameAspect, fit, cx: focus.x, cy: focus.y, zoom: 1).y
                    motion = .init(from: .init(cx: a, cy: y, zoom: 1), to: .init(cx: b, cy: y, zoom: 1))
                    panSign = b == a ? 0 : (b > a ? 1 : -1)
                }
            }

            var transition: ReelSpec.Transition?
            if override.transitionLocked {
                // Låst övergång behålls som den är (nil = filmens standard); även för klipp 0, så att
                // den följer med om klippet flyttas.
                transition = override.transition
            } else if i > 0 {
                transition = automaticTransition(previousPanSign: previousPanSign, isLast: isLast,
                                                 defaultTransition: defaultTransition).transition
            }
            previousPanSign = panSign
            clips.append(.init(asset: image.assetID, duration: duration, fit: fit, motion: motion, transitionIn: transition,
                               motionPreset: override.preset == .auto ? nil : override.preset.rawValue,
                               durationLocked: override.duration == nil ? nil : true,
                               transitionLocked: override.transitionLocked ? true : nil,
                               customMotion: unclamped))
        }
        return clips
    }

    /// En egen rörelse klampad mot formatet som i `plan`: mittpunkterna inom bilden (oförändrade
    /// bit för bit när de redan ryms) och zoom minst 1.
    static func clampedCustomMotion(_ image: Image, frameAspect: Double, custom: CustomMotion) -> ReelSpec.Motion {
        .init(from: customKey(image, frameAspect, custom.fit, custom.motion.from),
              to: customKey(image, frameAspect, custom.fit, custom.motion.to))
    }

    /// Övergången `t` med typen bytt till `type`, som stilpanelen och övergångsinspektören gör det:
    /// riktning bara för push (behållen, annars vänster). Längden behålls för hårt klipp; för andra
    /// typer klampas den till `transitionRange`, och kommer den från ett hårt klipp eller ligger under
    /// intervallet blir den minst 0,5 s, så att ett hårt klipp med längd 0 inte blir en mjuk tona
    /// som i praktiken är ett hårt klipp.
    static func retyped(_ t: ReelSpec.Transition, to type: ReelSpec.TransitionType) -> ReelSpec.Transition {
        var out = t
        out.type = type
        out.direction = type == .push ? (t.direction ?? .left) : nil
        guard type != .cut else { return out }
        let fallback = transitionDuration
        let wanted = t.type == .cut || t.duration < transitionRange.lowerBound ? max(t.duration, fallback) : t.duration
        out.duration = min(max(wanted, transitionRange.lowerBound), transitionRange.upperBound)
        return out
    }

    // MARK: - Automatiska övergångar

    /// Varför en automatisk övergång blev som den blev (styr texten i inspektören).
    nonisolated enum TransitionReason: Equatable, Sendable {
        /// Standardövergången är något annat än mjuk tona: alla automatiska övergångar följer den.
        case styleDefault
        /// Längre tona in i sista klippet.
        case closing
        /// Skjut åt `direction` eftersom föregående klipp panorerade åt motsatt håll.
        case followsPan(ReelSpec.Direction)
        /// Mjuk tona (standard).
        case standard
    }

    /// Regeln för en automatisk övergång in till ett klipp (inte det första):
    /// - Är standardövergången något annat än `crossfade` (cut, via svart, skjut) används den som
    ///   den är för alla automatiska övergångar. Då gäller varken push efter panorering eller
    ///   längre tona in, eftersom de är varianter av just mjuk tona.
    /// - Annars (crossfade): sista klippet får en längre tona in (standardlängden × 1,2, högst
    ///   1,5 s; 0,5 s ger de gamla 0,6 s), efter ett klipp som panorerade åt höger/vänster blir det
    ///   en push åt motsatt håll med standardlängden, och annars mjuk tona med standardlängden.
    /// Med `standardTransition` (crossfade 0,5 s) ger detta exakt det planeraren alltid gjort.
    static func automaticTransition(previousPanSign: Double, isLast: Bool, defaultTransition d: ReelSpec.Transition)
        -> (transition: ReelSpec.Transition, reason: TransitionReason) {
        guard d.type == .crossfade else { return (d, .styleDefault) }
        if isLast {
            let longer = min(d.duration * (lastTransitionDuration / transitionDuration), transitionRange.upperBound)
            return (.init(type: .crossfade, direction: nil, duration: max(longer, d.duration)), .closing)
        }
        if previousPanSign != 0 {
            // Föregående klipp panorerade åt höger → innehållet rör sig åt vänster → push åt vänster.
            let direction: ReelSpec.Direction = previousPanSign > 0 ? .left : .right
            return (.init(type: .push, direction: direction, duration: d.duration), .followsPan(direction))
        }
        return (.init(type: .crossfade, direction: nil, duration: d.duration), .standard)
    }

    /// Åt vilket håll ett färdigplanerat klipp panorerar (+1 höger, −1 vänster, 0 inget): samma
    /// mått som `plan` använder för nästa övergång. Egen rörelse räknas som panorering vid mer
    /// än 0,02 i sidled; annars bara rörelse utan zoom.
    static func panSign(of clip: ReelSpec.Clip) -> Double {
        if clip.fit == .panels { return 0 }
        let dx = clip.motion.to.cx - clip.motion.from.cx
        if clip.motionPreset == Preset.custom.rawValue { return abs(dx) > 0.02 ? (dx > 0 ? 1 : -1) : 0 }
        guard abs(clip.motion.to.zoom - clip.motion.from.zoom) < 1e-9, clip.fit == .cover, dx != 0 else { return 0 }
        return dx > 0 ? 1 : -1
    }

    /// Kort förklaring på svenska av varför den automatiska övergången in till `clip` (som kommer
    /// efter `previous`) blev som den blev, beräknad med samma regel som planeraren
    /// (`automaticTransition`). Gäller bara automatiska övergångar; för låsta finns inget skäl.
    static func transitionReason(previous: ReelSpec.Clip, isLast: Bool, defaultTransition d: ReelSpec.Transition) -> String {
        let result = automaticTransition(previousPanSign: panSign(of: previous), isLast: isLast, defaultTransition: d)
        switch result.reason {
        case .styleDefault: return "\(label(d)) (filmens standardövergång)"
        case .closing: return "Längre tona in i sista bilden"
        case .followsPan(let direction):
            let moved = previous.motion.to.cx > previous.motion.from.cx ? "åt höger" : "åt vänster"
            return "Skjut \(directionLabel(direction)) eftersom förra klippet panorerade \(moved)"
        case .standard: return "Mjuk tona (standard)"
        }
    }

    private static func directionLabel(_ d: ReelSpec.Direction) -> String {
        switch d {
        case .left: return "åt vänster"
        case .right: return "åt höger"
        case .up: return "uppåt"
        case .down: return "nedåt"
        }
    }

    private static func label(_ t: ReelSpec.Transition) -> String {
        switch t.type {
        case .crossfade: return "Mjuk tona"
        case .cut: return "Hårt klipp"
        case .fadeThroughBlack: return "Via svart"
        case .push: return "Skjut \(directionLabel(t.direction ?? .left))"
        }
    }

    // MARK: - Hjälpfunktioner

    static func baseDuration(_ kind: Kind) -> Double {
        switch kind {
        case .pan: return panDuration
        case .zoom: return zoomDuration
        case .containBlur: return containDuration
        }
    }

    /// Slutzoom efter tempotaket: z ≤ (1 + maxZoomPerSecond)^längd (geometrisk zoom, som i `ReelTimeline`).
    static func endZoom(amount: Double, scale: Double, duration: Double) -> Double {
        let wanted = 1 + (amount - 1) * scale
        return min(wanted, pow(1 + maxZoomPerSecond, duration))
    }

    private static func clampedCenter(_ image: Image, _ frameAspect: Double, _ fit: ReelSpec.Fit,
                                      cx: Double, cy: Double, zoom: Double) -> CGPoint {
        let c = CGPoint(x: cx, y: cy)
        switch fit {
        case .cover, .panels:
            let r = ReelTimeline.cropRect(imageSize: image.size, frameAspect: frameAspect, center: c, zoom: zoom)
            return CGPoint(x: r.midX, y: r.midY)
        case .containBlur:
            let r = ReelTimeline.containCrop(center: c, zoom: zoom)
            return CGPoint(x: r.midX, y: r.midY)
        }
    }

    /// Nyckel för egen rörelse: klampad som `key`, men oförändrad (bit för bit) om den redan ryms,
    /// så att en ombyggnad inte ändrar värden i onödan. Zoom minst 1.
    private static func customKey(_ image: Image, _ frameAspect: Double, _ fit: ReelSpec.Fit,
                                  _ k: ReelSpec.MotionKey) -> ReelSpec.MotionKey {
        let zoom = max(k.zoom, 1)
        let clamped = key(image, frameAspect, fit, cx: k.cx, cy: k.cy, zoom: zoom)
        if abs(clamped.cx - k.cx) < 1e-9, abs(clamped.cy - k.cy) < 1e-9 { return .init(cx: k.cx, cy: k.cy, zoom: zoom) }
        return clamped
    }

    private static func key(_ image: Image, _ frameAspect: Double, _ fit: ReelSpec.Fit,
                            cx: Double, cy: Double, zoom: Double) -> ReelSpec.MotionKey {
        let p = clampedCenter(image, frameAspect, fit, cx: cx, cy: cy, zoom: zoom)
        return .init(cx: Double(p.x), cy: Double(p.y), zoom: zoom)
    }

    /// Start- och slutmittpunkt (x) för en panorering åt `sign`, kring `centerX`, högst `travel` lång,
    /// och helt inom det tillåtna intervallet för cover-utsnittet vid zoom 1.
    private static func panRange(_ image: Image, _ frameAspect: Double, centerX: Double,
                                 travel: Double, sign: Double) -> (Double, Double) {
        let r = ReelTimeline.cropRect(imageSize: image.size, frameAspect: frameAspect,
                                      center: CGPoint(x: 0.5, y: 0.5), zoom: 1)
        let lo = Double(r.width) / 2, hi = 1 - Double(r.width) / 2
        guard hi > lo else { return (0.5, 0.5) }
        let t = min(travel, hi - lo)
        // Mittpunktens läge så att hela sträckan ryms, så nära motivets mitt som möjligt.
        let startMin = lo, startMax = hi - t
        let start = min(max(centerX - t / 2, startMin), startMax)
        let end = start + t
        return sign > 0 ? (start, end) : (end, start)
    }
}
