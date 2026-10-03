import Foundation

/// Fel från Objektfilm-servern. Texterna är svenska och kan visas rakt av.
nonisolated enum ReelServerError: LocalizedError, Equatable {
    /// Serverns eget felsvar (`error.code` och `error.message`).
    case api(status: Int, code: String, message: String)
    /// 412: någon annan har ändrat specen. `spec` är serverns aktuella (kan saknas).
    case revisionConflict(currentRevision: Int, spec: ReelSpec?)
    /// 409 `superseded`: mäklaren har ändrat efter godkännandet, jobbet ska avbrytas/slängas.
    case superseded(String)
    case network(String)
    case badResponse(String)
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .api(_, _, let message): return message
        case .revisionConflict: return "Mäklaren har ändrat. Hämta den senaste versionen först."
        case .superseded(let message): return message
        case .network(let why): return "Kunde inte nå servern: \(why)"
        case .badResponse(let why): return "Oväntat svar från servern: \(why)"
        case .notConfigured: return "Ange server och nyckel under Inställningar → Objektfilm."
        }
    }

    var isNetwork: Bool { if case .network = self { return true } else { return false } }
}

// MARK: - Svarstyper

nonisolated struct ReelServerMe: Decodable, Sendable, Equatable {
    struct Photographer: Decodable, Sendable, Equatable { var id: String; var name: String }
    var apiVersion: Int
    var scope: String
    var keyId: String
    var photographer: Photographer
}

nonisolated struct ReelServerObjectInfo: Decodable, Sendable, Equatable {
    var objectId: String
    var status: String
    var currentRevision: Int
}

nonisolated struct ReelServerLink: Decodable, Sendable, Equatable {
    var linkId: String
    var label: String?
    var createdAt: String?
    var expiresAt: String?
    var revokedAt: String?
    var lastUsedAt: String?
}

nonisolated struct ReelServerRender: Decodable, Sendable, Equatable {
    var renderId: String
    var revision: Int
    var outputId: String
    var current: Bool
}

nonisolated struct ReelServerObjectDetail: Decodable, Sendable {
    var objectId: String
    var reelId: String
    var address: String
    var status: String
    var currentRevision: Int
    var approvedRevision: Int?
    var spec: ReelSpec?
    var links: [ReelServerLink]
    var renders: [ReelServerRender]
}

nonisolated struct ReelServerSpecResult: Decodable, Sendable {
    var objectId: String
    var revision: Int
    var status: String
    var changed: Bool
    var spec: ReelSpec
}

/// Svaret på `POST /objects/{id}/links`. `url` innehåller token och visas bara en gång.
nonisolated struct ReelServerCreatedLink: Decodable, Sendable, Equatable {
    var linkId: String
    var url: String
    var archiveUrl: String?
    var expiresAt: String
    var status: String?
}

nonisolated struct ReelServerPoolAsset: Codable, Sendable, Equatable {
    var assetId: String
    var sha256: String
    var width: Int
    var height: Int
    var analysis: ReelSpec.Analysis?
}

nonisolated struct ReelRenderJob: Decodable, Sendable {
    var jobId: String
    var objectId: String
    var reelId: String?
    var revision: Int
    var outputId: String
    var spec: ReelSpec
}

/// Det renderworkern behöver av servern. Gör att workerns tillståndsmaskin kan provas med en låtsasklient.
nonisolated protocol ReelRenderQueueAPI: Sendable {
    /// Long-poll; nil = inget jobb (204).
    func claim(wait: Int) async throws -> ReelRenderJob?
    func heartbeat(jobId: String) async throws
    func uploadOutput(jobId: String, file: URL, width: Int, height: Int, duration: Double) async throws
    func fail(jobId: String, message: String) async throws
}

// MARK: - Klienten

/// Typad klient mot Objektfilm-servern (`docs/objektfilm-api-v1.md`). En instans hör till en nyckel
/// (fotograf eller render). Nätverksfel och 502/503/504/429 provas om med växande väntetid för
/// anrop som är ofarliga att upprepa; felsvar blir `ReelServerError` med serverns svenska text.
actor ReelServerClient: ReelRenderQueueAPI {

    let baseURL: URL
    private let key: String
    private let session: URLSession
    private let maxRetries: Int
    private let backoff: @Sendable (Int) -> Duration

    /// `backoff(n)` är väntan före omförsök nummer n (1, 2, …).
    init(baseURL: URL, key: String, session: URLSession = .shared, maxRetries: Int = 3,
         backoff: @escaping @Sendable (Int) -> Duration = { .seconds(min(1 << ($0 - 1), 8)) }) {
        self.baseURL = baseURL
        self.key = key
        self.session = session
        self.maxRetries = maxRetries
        self.backoff = backoff
    }

    // MARK: Fotografens API

    func me() async throws -> ReelServerMe {
        try decode(try await request("GET", "/api/v1/me"))
    }

    func upsertObject(reelId: String, address: String, sessionID: String?, kind: String?) async throws -> ReelServerObjectInfo {
        var body: [String: String] = ["address": address]
        if let sessionID, !sessionID.isEmpty { body["sessionID"] = sessionID }
        if let kind { body["kind"] = kind }
        return try decode(try await request("PUT", "/api/v1/objects/by-reel/\(reelId)", json: body))
    }

    /// Vilka av hasharna som saknar webbvarianter på servern.
    func missingAssets(_ sha256: [String]) async throws -> [String] {
        struct Reply: Decodable { var missing: [String] }
        let reply: Reply = try decode(try await request("POST", "/api/v1/assets/check", json: ["sha256": sha256]))
        return reply.missing
    }

    func putVariant(sha256: String, variant: String, jpeg: Data) async throws {
        _ = try await request("PUT", "/api/v1/assets/\(sha256)/\(variant)", body: jpeg, contentType: "image/jpeg")
    }

    func setPool(objectId: String, assets: [ReelServerPoolAsset]) async throws {
        struct Body: Encodable { var assets: [ReelServerPoolAsset] }
        _ = try await request("PUT", "/api/v1/objects/\(objectId)/pool", body: try JSONEncoder().encode(Body(assets: assets)),
                              contentType: "application/json")
    }

    func object(_ objectId: String) async throws -> ReelServerObjectDetail {
        try decode(try await request("GET", "/api/v1/objects/\(objectId)"))
    }

    /// Sparar specen. `ifMatch` är senast synkade revision ("0" första gången). 412 ger `.revisionConflict`.
    func putSpec(objectId: String, spec: ReelSpec, ifMatch: Int) async throws -> ReelServerSpecResult {
        try decode(try await request("PUT", "/api/v1/objects/\(objectId)/spec", body: try spec.jsonData(),
                                     contentType: "application/json", headers: ["If-Match": "\"\(ifMatch)\""]))
    }

    /// Skapar en mäklarlänk. Anropet upprepas inte automatiskt (varje anrop ger en ny länk).
    func createLink(objectId: String, label: String?, expiresInDays: Int) async throws -> ReelServerCreatedLink {
        var body: [String: Any] = ["expiresInDays": expiresInDays]
        if let label, !label.isEmpty { body["label"] = label }
        return try decode(try await request("POST", "/api/v1/objects/\(objectId)/links", json: body, retries: 0))
    }

    func revokeLink(_ linkId: String) async throws {
        _ = try await request("DELETE", "/api/v1/links/\(linkId)")
    }

    func approve(objectId: String, revision: Int) async throws {
        _ = try await request("POST", "/api/v1/objects/\(objectId)/approve", json: ["revision": revision])
    }

    func deleteObject(_ objectId: String) async throws {
        _ = try await request("DELETE", "/api/v1/objects/\(objectId)")
    }

    // MARK: Renderkön

    func claim(wait: Int) async throws -> ReelRenderJob? {
        let (data, status) = try await requestRaw("POST", "/api/v1/render-jobs/claim?wait=\(min(max(wait, 0), 25))",
                                                  retries: 0, timeout: Double(wait) + 20)
        if status == 204 { return nil }
        return try decode(data)
    }

    func heartbeat(jobId: String) async throws {
        _ = try await request("POST", "/api/v1/render-jobs/\(jobId)/heartbeat")
    }

    func uploadOutput(jobId: String, file: URL, width: Int, height: Int, duration: Double) async throws {
        let path = "/api/v1/render-jobs/\(jobId)/output?width=\(width)&height=\(height)&duration=\(String(format: "%.3f", duration))"
        _ = try await request("PUT", path, contentType: "video/mp4", uploadFile: file, timeout: 600)
    }

    func fail(jobId: String, message: String) async throws {
        _ = try await request("POST", "/api/v1/render-jobs/\(jobId)/fail", json: ["message": String(message.prefix(500))])
    }

    // MARK: Transport

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do { return try ReelSpec.makeDecoder().decode(T.self, from: data) }
        catch { throw ReelServerError.badResponse(error.localizedDescription) }
    }

    private func request(_ method: String, _ path: String, json: Any? = nil, body: Data? = nil,
                         contentType: String? = nil, headers: [String: String] = [:], uploadFile: URL? = nil,
                         retries: Int? = nil, timeout: Double = 60) async throws -> Data {
        var payload = body
        var type = contentType
        if let json {
            payload = try JSONSerialization.data(withJSONObject: json)
            type = "application/json"
        }
        return try await requestRaw(method, path, body: payload, contentType: type, headers: headers,
                                    uploadFile: uploadFile, retries: retries, timeout: timeout).data
    }

    private func requestRaw(_ method: String, _ path: String, body: Data? = nil, contentType: String? = nil,
                            headers: [String: String] = [:], uploadFile: URL? = nil,
                            retries: Int? = nil, timeout: Double = 60) async throws -> (data: Data, status: Int) {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            throw ReelServerError.badResponse("ogiltig adress \(path)")
        }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = method
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        if let contentType { req.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }

        let allowed = retries ?? maxRetries
        var attempt = 0
        while true {
            do {
                let (data, response): (Data, URLResponse)
                if let uploadFile {
                    (data, response) = try await session.upload(for: req, fromFile: uploadFile)
                } else {
                    if let body { req.httpBody = body }
                    (data, response) = try await session.data(for: req)
                }
                guard let http = response as? HTTPURLResponse else { throw ReelServerError.badResponse("inget HTTP-svar") }
                if [429, 502, 503, 504].contains(http.statusCode), attempt < allowed {
                    attempt += 1
                    try await Task.sleep(for: retryDelay(http, attempt: attempt))
                    continue
                }
                if (200..<300).contains(http.statusCode) { return (data, http.statusCode) }
                throw Self.error(status: http.statusCode, data: data)
            } catch let error as URLError where error.code != .cancelled {
                guard attempt < allowed else { throw ReelServerError.network(error.localizedDescription) }
                attempt += 1
                try await Task.sleep(for: backoff(attempt))
            }
        }
    }

    private func retryDelay(_ http: HTTPURLResponse, attempt: Int) -> Duration {
        if http.statusCode == 429, let value = http.value(forHTTPHeaderField: "Retry-After"), let secs = Double(value) {
            return .seconds(min(max(secs, 0), 30))
        }
        return backoff(attempt)
    }

    /// Översätter ett felsvar till `ReelServerError`.
    static func error(status: Int, data: Data) -> ReelServerError {
        struct Envelope: Decodable {
            struct Err: Decodable { var code: String?; var message: String? }
            var error: Err?
            var currentRevision: Int?
        }
        struct SpecEnvelope: Decodable { var spec: ReelSpec? }
        let env = try? JSONDecoder().decode(Envelope.self, from: data)
        let code = env?.error?.code ?? "http_\(status)"
        let message = env?.error?.message ?? "Servern svarade med felkod \(status)."
        if status == 412 {
            let spec = (try? ReelSpec.makeDecoder().decode(SpecEnvelope.self, from: data))?.spec
            return .revisionConflict(currentRevision: env?.currentRevision ?? 0, spec: spec)
        }
        if status == 409, code == "superseded" { return .superseded(message) }
        return .api(status: status, code: code, message: message)
    }
}
