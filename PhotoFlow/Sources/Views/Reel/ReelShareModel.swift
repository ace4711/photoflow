import Foundation
import Observation

/// Vymodellen för "Skicka till mäklare": skickar filmen till Objektfilm-servern, skapar länkar och
/// hämtar mäklarens ändringar. All logik som inte är ritning ligger här; nätverket går via
/// `ReelServerClient` och sammanslagningen via de rena typerna `ReelUploadPlanner` och `ReelSyncMerger`.
@Observable
final class ReelShareModel {

    enum Phase: Equatable {
        case idle
        case working(String)
        case uploading(done: Int, total: Int)
        case done
        case failed(String)
    }

    /// Statusmärket i redigerarens huvud.
    enum Badge: Equatable {
        case draft
        case withAgent(revision: Int)
        case approvedWaiting
        case rendered

        var label: String {
            switch self {
            case .draft: return "Utkast"
            case .withAgent(let rev): return "Hos mäklaren (rev \(rev))"
            case .approvedWaiting: return "Godkänd – väntar på rendering"
            case .rendered: return "Renderad"
            }
        }
    }

    /// Varför användaren måste välja mellan sitt och serverns: visas som en dialog.
    struct Conflict: Equatable, Identifiable {
        enum Kind: Equatable {
            /// 412 vid skickning: mäklaren har ändrat.
            case remoteChanged
            /// "Hämta ändringar" när lokala ändringar inte är skickade.
            case localUnsent
        }
        var id = UUID()
        var kind: Kind
        var currentRevision: Int
        var spec: ReelSpec

        var title: String {
            switch kind {
            case .remoteChanged: return "Mäklaren har ändrat"
            case .localUnsent: return "Du har ändringar som inte skickats"
            }
        }
        var message: String {
            switch kind {
            case .remoteChanged: return "Mäklaren har ändrat filmen sedan du senast hämtade. Ladda om mäklarens version? Dina egna ändringar ersätts."
            case .localUnsent: return "Mäklaren har en nyare version. Om du hämtar den ersätts dina ändringar som inte är skickade."
            }
        }
    }

    // MARK: Tillstånd

    private(set) var state: ReelRemoteState?
    private(set) var phase: Phase = .idle
    /// Länken som just skapades. Token visas bara en gång, så den hålls bara i minnet.
    private(set) var createdLink: ReelServerCreatedLink?
    /// Mäklarens nyare revision som inte hämtats (lokala ändringar hindrade en automatisk hämtning).
    private(set) var pendingRemoteRevision: Int?
    var conflict: Conflict?
    /// Kort besked efter "Hämta ändringar" ("Inga nya ändringar", "Hämtade rev 4").
    private(set) var notice: String?

    @ObservationIgnored var config = ObjektfilmConfig()
    @ObservationIgnored var indexURL = ReelRemoteIndex.defaultURL
    /// Byts i tester mot en klient med låtsasnätverk.
    @ObservationIgnored var clientOverride: ((ObjektfilmConfig.Role) throws -> ReelServerClient)?
    @ObservationIgnored private var didAutoRefresh = false

    private func makeClient(_ role: ObjektfilmConfig.Role) throws -> ReelServerClient {
        try clientOverride?(role) ?? config.client(role)
    }

    var isBusy: Bool {
        switch phase { case .working, .uploading: return true; default: return false }
    }

    var badge: Badge {
        guard let state else { return .draft }
        switch state.lastKnownStatus {
        case "proposed": return .withAgent(revision: state.lastSyncedRevision)
        case "approved": return .approvedWaiting
        case "rendered": return .rendered
        default: return .draft
        }
    }

    var isLinked: Bool { state != nil }

    // MARK: Läs in

    func load(reelDirectory: URL?) {
        state = reelDirectory.flatMap(ReelRemoteState.load(from:))
        didAutoRefresh = false
        phase = .idle; createdLink = nil; conflict = nil; notice = nil; pendingRemoteRevision = nil
    }

    func resetProgress() {
        if !isBusy { phase = .idle }
        createdLink = nil
    }

    /// Finns lokala ändringar som inte skickats?
    func hasUnsentChanges(_ editor: ReelEditorModel) -> Bool {
        guard let state, let spec = editor.spec, let synced = state.lastSyncedLocalRevision else { return false }
        return spec.revision != synced
    }

    // MARK: Skicka

    /// Skickar filmen: registrerar objektet, laddar upp saknade webbvarianter, sätter poolen och specen,
    /// och skapar (om `newLink`) en länk till mäklaren.
    func send(from editor: ReelEditorModel, label: String, days: Int, newLink: Bool = true) async {
        guard !isBusy else { return }
        guard let spec = editor.spec, let dir = editor.reelDirectory else { return }
        createdLink = nil
        conflict = nil
        editor.saveSpec()
        do {
            let client = try makeClient(.photographer)
            phase = .working("Registrerar objektet…")
            let info = try await client.upsertObject(reelId: spec.id, address: editor.address,
                                                     sessionID: editor.sessionID, kind: spec.property.kind)
            var st = state ?? ReelRemoteState(server: client.baseURL.absoluteString, objectId: info.objectId,
                                              reelId: spec.id, lastSyncedRevision: info.currentRevision,
                                              lastKnownStatus: info.status)
            if let source = editor.sourceDirectory {
                st.sourceRelativePath = ReelComposer.relativePath(from: dir, to: source)
            }
            try st.save(to: dir)
            try ReelRemoteIndex.register(objectId: st.objectId, directory: dir, at: indexURL)
            state = st

            let files = ReelFileIndex.index(from: editor.items)
            let analyses = Dictionary(editor.items.map { ($0.analysis.sha256, $0.analysis) }, uniquingKeysWith: { a, _ in a })
            let pool = ReelUploadPlanner.pool(spec: spec, analyses: analyses, files: files)

            phase = .working("Kontrollerar bilder…")
            let missing = try await client.missingAssets(pool.map(\.sha256))
            let plan = ReelUploadPlanner.uploads(missing: missing, files: files)
            guard plan.unresolved.isEmpty else {
                phase = .failed("\(plan.unresolved.count) bild(er) saknas på den här Macen och kan inte laddas upp.")
                return
            }
            for (i, upload) in plan.uploads.enumerated() {
                phase = .uploading(done: i, total: plan.uploads.count)
                guard let variants = await Self.makeVariants(of: upload.url) else {
                    phase = .failed("Kunde inte läsa bilden \(upload.url.lastPathComponent).")
                    return
                }
                for (variant, output) in variants {
                    try await client.putVariant(sha256: upload.sha256, variant: variant.rawValue, jpeg: output.data)
                }
            }
            if !plan.uploads.isEmpty { phase = .uploading(done: plan.uploads.count, total: plan.uploads.count) }

            phase = .working("Skickar filmen…")
            try await client.setPool(objectId: st.objectId, assets: pool.map(\.serverAsset))
            let result: ReelServerSpecResult
            do {
                result = try await client.putSpec(objectId: st.objectId, spec: ReelUploadPlanner.storeSpec(spec),
                                                  ifMatch: st.lastSyncedRevision)
            } catch ReelServerError.revisionConflict(let current, let remote) {
                phase = .idle
                if let remote {
                    conflict = Conflict(kind: .remoteChanged, currentRevision: current, spec: remote)
                } else {
                    phase = .failed(ReelServerError.revisionConflict(currentRevision: current, spec: nil).localizedDescription)
                }
                return
            }
            editor.markSynced(revision: result.revision, status: result.status)
            st.lastSyncedRevision = result.revision
            st.lastSyncedLocalRevision = result.revision
            st.lastKnownStatus = result.status
            pendingRemoteRevision = nil

            if newLink {
                phase = .working("Skapar länk…")
                let link = try await client.createLink(objectId: st.objectId, label: label.isEmpty ? nil : label, expiresInDays: days)
                createdLink = link
                st.links.append(.init(linkId: link.linkId, label: label.isEmpty ? nil : label, createdAt: nil, expiresAt: link.expiresAt))
                if let status = link.status { st.lastKnownStatus = status }
            }
            try st.save(to: dir)
            state = st
            phase = .done
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Båda webbvarianterna för en bild, utanför huvudtråden.
    @concurrent
    private static func makeVariants(of url: URL) async -> [(ReelWebVariant.Variant, ReelWebVariant.Output)]? {
        var result: [(ReelWebVariant.Variant, ReelWebVariant.Output)] = []
        for variant in ReelWebVariant.Variant.allCases {
            guard let output = ReelWebVariant.make(from: url, variant: variant) else { return nil }
            result.append((variant, output))
        }
        return result
    }

    // MARK: Hämta ändringar

    /// Hämtar status och, om mäklaren har en nyare revision, specen. `force` = ersätt även osynkade
    /// lokala ändringar (annars frågar `conflict`). `silent` = inga felmeddelanden (automatisk hämtning).
    func pull(into editor: ReelEditorModel, force: Bool = false, silent: Bool = false) async {
        guard !isBusy, var st = state, let dir = editor.reelDirectory else { return }
        notice = nil
        do {
            let client = try makeClient(.photographer)
            phase = .working("Hämtar ändringar…")
            let detail = try await client.object(st.objectId)
            st.lastKnownStatus = detail.status
            st.approvedRevision = detail.approvedRevision
            st.links = detail.links.filter { $0.revokedAt == nil }.map {
                .init(linkId: $0.linkId, label: $0.label, createdAt: $0.createdAt, expiresAt: $0.expiresAt)
            }
            guard detail.currentRevision > st.lastSyncedRevision, let remote = detail.spec else {
                try? st.save(to: dir)
                state = st
                pendingRemoteRevision = nil
                phase = .idle
                if !silent { notice = "Inga nya ändringar från mäklaren." }
                return
            }
            if hasUnsentChanges(editor), !force {
                try? st.save(to: dir)
                state = st
                pendingRemoteRevision = detail.currentRevision
                phase = .idle
                if !silent { conflict = Conflict(kind: .localUnsent, currentRevision: detail.currentRevision, spec: remote) }
                return
            }
            try adopt(remote, revision: detail.currentRevision, status: detail.status, into: editor, state: &st, dir: dir)
            phase = .idle
            notice = "Hämtade mäklarens ändringar (rev \(detail.currentRevision))."
        } catch {
            phase = silent ? .idle : .failed(error.localizedDescription)
        }
    }

    /// Automatisk hämtning när fönstret öppnats och filmen är laddad (en gång per öppnad mapp).
    func autoRefresh(into editor: ReelEditorModel) async {
        guard !didAutoRefresh, state != nil else { return }
        didAutoRefresh = true
        await pull(into: editor, silent: true)
    }

    /// Användaren svarade "Ladda om" i dialogen: ersätt lokala filmen med serverns spec.
    func resolveConflictByReloading(into editor: ReelEditorModel) {
        guard let conflict, var st = state, let dir = editor.reelDirectory else { return }
        self.conflict = nil
        do {
            try adopt(conflict.spec, revision: conflict.currentRevision, status: st.lastKnownStatus,
                      into: editor, state: &st, dir: dir)
            phase = .idle
            notice = "Hämtade mäklarens ändringar (rev \(conflict.currentRevision))."
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func dismissConflict() { conflict = nil }
    func dismissFailure() { if case .failed = phase { phase = .idle } }

    /// Slår ihop serverns spec med de lokala filerna och lägger in den i redigeraren.
    private func adopt(_ remote: ReelSpec, revision: Int, status: String?, into editor: ReelEditorModel,
                       state st: inout ReelRemoteState, dir: URL) throws {
        let files = ReelFileIndex.index(from: editor.items)
        let analyses = Dictionary(editor.items.map { ($0.analysis.sha256, $0.analysis) }, uniquingKeysWith: { a, _ in a })
        let merged = ReelSyncMerger.merge(remote: remote, local: editor.spec, files: files, specDirectory: dir, analyses: analyses)
        guard merged.isComplete else {
            throw ReelServerError.badResponse("\(merged.missing.count) bild(er) i mäklarens version finns inte på den här Macen.")
        }
        var spec = merged.spec
        spec.revision = revision
        editor.adoptRemoteSpec(spec)
        st.lastSyncedRevision = revision
        st.lastSyncedLocalRevision = revision
        if let status { st.lastKnownStatus = status }
        try st.save(to: dir)
        state = st
        pendingRemoteRevision = nil
    }
}
