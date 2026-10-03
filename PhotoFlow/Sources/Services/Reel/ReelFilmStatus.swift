import Foundation

/// Statusmärket för en film (samma ord som i bildspelsfönstrets huvud).
nonisolated enum ReelFilmBadge: Sendable, Equatable {
    case draft
    case withAgent(revision: Int)
    case approvedWaiting
    case rendered

    /// `status` är serverns (draft, proposed, approved, rendered); `revision` gäller "hos mäklaren".
    init(status: String?, revision: Int) {
        switch status {
        case "proposed": self = .withAgent(revision: revision)
        case "approved": self = .approvedWaiting
        case "rendered": self = .rendered
        default: self = .draft
        }
    }

    var label: String {
        switch self {
        case .draft: return "Utkast"
        case .withAgent(let rev): return "Hos mäklaren (rev \(rev))"
        case .approvedWaiting: return "Godkänd – väntar på rendering"
        case .rendered: return "Renderad"
        }
    }
}

/// En länk till mäklaren, utan token (den finns bara när länken skapas).
nonisolated struct ReelLinkInfo: Sendable, Equatable, Identifiable {
    var linkId: String
    var label: String?
    var createdAt: Date?
    var expiresAt: Date?
    var revokedAt: Date?

    var id: String { linkId }

    func isExpired(now: Date) -> Bool { expiresAt.map { $0 < now } ?? false }

    /// "Länk skickad 3 okt. till Anna, giltig till 2 nov." (med "återkallad" eller "har gått ut" när det gäller).
    func summary(now: Date = Date()) -> String {
        var text = "Länk skickad"
        if let createdAt { text += " \(Self.dateText(createdAt))" }
        text += " till \(label?.isEmpty == false ? label! : "mäklare")"
        if revokedAt != nil { return text + ", återkallad" }
        if let expiresAt {
            text += isExpired(now: now) ? ", gick ut \(Self.dateText(expiresAt))" : ", giltig till \(Self.dateText(expiresAt))"
        }
        return text
    }

    static func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "sv_SE")
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    static func parse(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        return ReelSpec.parseISO8601(text)
    }
}

/// En rendering på servern.
nonisolated struct ReelRemoteRender: Sendable, Equatable, Identifiable {
    var renderId: String
    var revision: Int
    var outputId: String
    var current: Bool
    var width: Int?
    var height: Int?
    var duration: Double?
    /// Signerad URL (kort giltighet), absolut.
    var url: URL?

    var id: String { renderId }
    var formatLabel: String? {
        guard let width, let height else { return nil }
        return ReelLibrary.formatLabel(width: width, height: height)
    }
}

/// Det servern vet om en films objekt, översatt till det UI:t visar.
nonisolated struct ReelRemoteInfo: Sendable, Equatable {
    var badge: ReelFilmBadge
    var status: String
    var currentRevision: Int
    var approvedRevision: Int?
    var renders: [ReelRemoteRender]
    var links: [ReelLinkInfo]
    var fetchedAt: Date

    init(_ detail: ReelServerObjectDetail, baseURL: URL, fetchedAt: Date = Date()) {
        status = detail.status
        currentRevision = detail.currentRevision
        approvedRevision = detail.approvedRevision
        badge = ReelFilmBadge(status: detail.status, revision: detail.currentRevision)
        renders = detail.renders.map { render in
            ReelRemoteRender(
                renderId: render.renderId, revision: render.revision, outputId: render.outputId, current: render.current,
                width: render.width, height: render.height, duration: render.duration,
                url: render.url.flatMap { URL(string: $0, relativeTo: baseURL)?.absoluteURL })
        }
        links = detail.links.map {
            ReelLinkInfo(linkId: $0.linkId, label: $0.label, createdAt: ReelLinkInfo.parse($0.createdAt),
                         expiresAt: ReelLinkInfo.parse($0.expiresAt), revokedAt: ReelLinkInfo.parse($0.revokedAt))
        }
        self.fetchedAt = fetchedAt
    }

    /// Senaste renderingen (helst aktuell revision) med spelbar URL, ev. för ett visst exportformat.
    func playableRender(outputId: String? = nil) -> ReelRemoteRender? {
        renders.filter { $0.url != nil && (outputId == nil || $0.outputId == outputId) }
            .sorted { ($0.current ? 1 : 0, $0.revision) > ($1.current ? 1 : 0, $1.revision) }
            .first
    }
}

/// Länkarna lokalt (ur `reel-remote.json`, utan token) sammanslagna med serverns (som vet om en
/// länk återkallats). Servern vinner; länkar som bara finns lokalt behålls. Nyast först.
nonisolated func mergedLinks(local: [ReelRemoteState.Link], remote: [ReelLinkInfo]?) -> [ReelLinkInfo] {
    var byID: [String: ReelLinkInfo] = [:]
    for link in local {
        byID[link.linkId] = ReelLinkInfo(linkId: link.linkId, label: link.label,
                                         createdAt: ReelLinkInfo.parse(link.createdAt),
                                         expiresAt: ReelLinkInfo.parse(link.expiresAt), revokedAt: nil)
    }
    for link in remote ?? [] { byID[link.linkId] = link }
    return byID.values.sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
}

/// Hämtar och cachar serverstatus per objekt. Cachen gäller kort (så att en omritad lista inte
/// hamrar på servern) och ett serverfel ger `.unreachable`: anroparen visar då lokalt läge.
actor ReelStatusService {

    typealias Fetch = @Sendable (_ objectId: String) async throws -> ReelRemoteInfo

    private let fetch: Fetch
    private let ttl: TimeInterval
    private let now: @Sendable () -> Date
    private var cache: [String: ReelRemoteInfo] = [:]

    init(ttl: TimeInterval = 30, now: @escaping @Sendable () -> Date = { Date() }, fetch: @escaping Fetch) {
        self.ttl = ttl
        self.now = now
        self.fetch = fetch
    }

    /// Standardvarianten mot klienten från Inställningar → Objektfilm.
    static func live(config: ObjektfilmConfig = ObjektfilmConfig()) -> ReelStatusService? {
        guard let client = try? config.client(.photographer) else { return nil }
        return ReelStatusService { objectId in
            ReelRemoteInfo(try await client.object(objectId), baseURL: client.baseURL)
        }
    }

    /// Serverns läge för objektet. `force` hoppar över cachen.
    func lookup(_ objectId: String, force: Bool = false) async -> ReelRemoteLookup {
        if !force, let hit = cache[objectId], now().timeIntervalSince(hit.fetchedAt) < ttl { return .info(hit) }
        do {
            var info = try await fetch(objectId)
            info.fetchedAt = now()
            cache[objectId] = info
            return .info(info)
        } catch ReelServerError.api(let status, _, _) where status == 404 {
            cache[objectId] = nil
            return .gone
        } catch {
            return .unreachable
        }
    }
}

/// Utfallet av en statusfrågan: servern svarade, objektet är borta (gallrat) eller servern nåddes inte.
nonisolated enum ReelRemoteLookup: Sendable, Equatable {
    case info(ReelRemoteInfo)
    case gone
    case unreachable

    var info: ReelRemoteInfo? { if case .info(let info) = self { return info } else { return nil } }
}
