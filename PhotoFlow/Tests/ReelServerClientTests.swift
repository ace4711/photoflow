import Foundation
import Testing
@testable import PhotoFlow

/// Klientens felhantering, 412, If-Match och omförsök mot en låtsas-URLProtocol (ingen riktig trafik).
struct ReelServerClientTests {

    nonisolated final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
        @discardableResult func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
    }

    private func client(host: String = "client-\(UUID().uuidString.prefix(8)).test", retries: Int = 3,
                        handler: @escaping MockURLProtocol.Handler) -> ReelServerClient {
        MockURLProtocol.register(host: host, handler: handler)
        return ReelServerClient(baseURL: URL(string: "http://\(host)")!, key: "pf_abc", session: MockURLProtocol.session(),
                                maxRetries: retries, backoff: { _ in .zero })
    }

    private func sampleSpec() -> ReelSpec {
        let items = [ReelImageAnalyzer.Item(url: URL(fileURLWithPath: "/x/a.jpg"), analysis: ObjektfilmTestKit.analysis(1)),
                     ReelImageAnalyzer.Item(url: URL(fileURLWithPath: "/x/b.jpg"), analysis: ObjektfilmTestKit.analysis(2))]
        var o = ReelComposer.Options()
        o.count = 3
        return ReelComposer.compose(items: items, specDirectory: URL(fileURLWithPath: "/x/FILM"), options: o).spec
    }

    @Test("me(): nyckeln skickas som Bearer och svaret tolkas")
    func me() async throws {
        let c = client { req, _ in
            #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer pf_abc")
            #expect(req.url?.path == "/api/v1/me")
            return .json(["apiVersion": 1, "scope": "render", "keyId": "k", "photographer": ["id": "p", "name": "Fredrik"]])
        }
        let me = try await c.me()
        #expect(me.scope == "render" && me.photographer.name == "Fredrik")
    }

    @Test("Felsvar ger serverns svenska text")
    func errorMessage() async throws {
        let c = client { _, _ in
            .json(["error": ["code": "reel_taken", "message": "Filmen tillhör en annan fotograf."]], status: 409)
        }
        await #expect(throws: ReelServerError.api(status: 409, code: "reel_taken", message: "Filmen tillhör en annan fotograf.")) {
            _ = try await c.upsertObject(reelId: "r", address: "A", sessionID: nil, kind: nil)
        }
        let error = ReelServerError.api(status: 409, code: "reel_taken", message: "Filmen tillhör en annan fotograf.")
        #expect(error.localizedDescription == "Filmen tillhör en annan fotograf.")
    }

    @Test("putSpec skickar If-Match med citattecken och specen som JSON")
    func putSpecIfMatch() async throws {
        let spec = sampleSpec()
        let seen = SeenRequest()
        let c = client { req, body in
            seen.set(req, body)
            return .json(["objectId": "o", "revision": 3, "status": "proposed", "changed": true,
                          "spec": (try? JSONSerialization.jsonObject(with: body)) ?? [:]])
        }
        let result = try await c.putSpec(objectId: "o", spec: spec, ifMatch: 2)
        #expect(seen.request?.value(forHTTPHeaderField: "If-Match") == "\"2\"")
        #expect(seen.request?.httpMethod == "PUT" && seen.request?.url?.path == "/api/v1/objects/o/spec")
        #expect(seen.request?.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(result.revision == 3 && result.changed)
        #expect(result.spec.id == spec.id)
    }

    @Test("412 ger revisionConflict med aktuell revision och spec (serverns datum med millisekunder)")
    func conflict412() async throws {
        let spec = sampleSpec()
        var specObject = try #require(try JSONSerialization.jsonObject(with: try spec.jsonData()) as? [String: Any])
        specObject["revision"] = 5
        specObject["updatedAt"] = "2026-10-03T12:00:00.123Z"
        let reply = MockURLProtocol.Reply.json(["error": ["code": "revision_conflict", "message": "Specen har ändrats."],
                                                "currentRevision": 5, "spec": specObject], status: 412)
        let c = client { _, _ in reply }
        do {
            _ = try await c.putSpec(objectId: "o", spec: spec, ifMatch: 2)
            Issue.record("förväntade 412")
        } catch ReelServerError.revisionConflict(let current, let remote) {
            #expect(current == 5)
            #expect(remote?.revision == 5)
            #expect(remote?.id == spec.id)
        }
    }

    @Test("Nätverksfel provas om med backoff och lyckas till slut")
    func retriesNetworkErrors() async throws {
        let calls = Counter()
        let c = client { _, _ in
            if calls.next() < 3 { return .init(error: URLError(.networkConnectionLost)) }
            return .json(["missing": ["abc"]])
        }
        let missing = try await c.missingAssets(["abc"])
        #expect(missing == ["abc"])
        #expect(calls.value == 3)
    }

    @Test("503 provas om, men 4xx provas inte om; slut på försök ger network")
    func retryPolicy() async throws {
        let calls = Counter()
        let c503 = client { _, _ in
            calls.next()
            return .json(["error": ["code": "web_missing", "message": "Nere."]], status: 503)
        }
        await #expect(throws: ReelServerError.api(status: 503, code: "web_missing", message: "Nere.")) { _ = try await c503.me() }
        #expect(calls.value == 4)   // 1 + 3 omförsök

        let fourXX = Counter()
        let c404 = client { _, _ in
            fourXX.next()
            return .json(["error": ["code": "not_found", "message": "Finns inte."]], status: 404)
        }
        await #expect(throws: ReelServerError.api(status: 404, code: "not_found", message: "Finns inte.")) { _ = try await c404.me() }
        #expect(fourXX.value == 1)

        let down = client(retries: 2) { _, _ in .init(error: URLError(.cannotConnectToHost)) }
        do { _ = try await down.me(); Issue.record("förväntade fel") }
        catch let error as ReelServerError { #expect(error.isNetwork); #expect(error.localizedDescription.hasPrefix("Kunde inte nå servern")) }
    }

    @Test("createLink provas inte om (varje anrop ger en ny länk)")
    func createLinkNotRetried() async throws {
        let calls = Counter()
        let c = client { _, _ in calls.next(); return .init(error: URLError(.networkConnectionLost)) }
        await #expect(throws: ReelServerError.self) { _ = try await c.createLink(objectId: "o", label: "Maja", expiresInDays: 30) }
        #expect(calls.value == 1)
    }

    @Test("Renderkön: claim 204 = nil, 200 = jobb, heartbeat 409 superseded, output med query")
    func renderQueue() async throws {
        let spec = sampleSpec()
        let specData = try spec.jsonData()
        let seen = SeenRequest()
        let step = Counter()
        let c = client { req, body in
            seen.set(req, body)
            switch req.url!.path {
            case "/api/v1/render-jobs/claim":
                return step.next() == 1 ? .init(status: 204)
                    : .json(["jobId": "j1", "objectId": "o1", "reelId": spec.id, "revision": 4, "outputId": "vertical",
                             "spec": (try? JSONSerialization.jsonObject(with: specData)) ?? [:], "leaseUntil": "2026-10-03T12:10:00.000Z"])
            case "/api/v1/render-jobs/j1/heartbeat":
                return .json(["error": ["code": "superseded", "message": "Ersatt."]], status: 409)
            case "/api/v1/render-jobs/j1/output":
                return .json(["renderId": "r1", "status": "rendered"], status: 201)
            default:
                return .json(["status": "queued"])
            }
        }
        #expect(try await c.claim(wait: 25) == nil)
        #expect(seen.request?.url?.query == "wait=25")
        let job = try #require(try await c.claim(wait: 25))
        #expect(job.jobId == "j1" && job.revision == 4 && job.outputId == "vertical" && job.spec.id == spec.id)
        await #expect(throws: ReelServerError.superseded("Ersatt.")) { try await c.heartbeat(jobId: "j1") }

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("klient-\(UUID().uuidString).mp4")
        try Data("mp4data".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        try await c.uploadOutput(jobId: "j1", file: file, width: 1080, height: 1920, duration: 12.3456)
        let req = try #require(seen.request)
        #expect(req.httpMethod == "PUT" && req.value(forHTTPHeaderField: "Content-Type") == "video/mp4")
        #expect(req.url?.query == "width=1080&height=1920&duration=12.346")
        #expect(seen.body == Data("mp4data".utf8))

        try await c.fail(jobId: "j1", message: "trasigt")
        #expect(seen.request?.url?.path == "/api/v1/render-jobs/j1/fail")
        #expect(String(decoding: seen.body, as: UTF8.self).contains("trasigt"))
    }

    nonisolated final class SeenRequest: @unchecked Sendable {
        private let lock = NSLock()
        private var _request: URLRequest?
        private var _body = Data()
        func set(_ r: URLRequest, _ b: Data) { lock.lock(); _request = r; _body = b; lock.unlock() }
        var request: URLRequest? { lock.lock(); defer { lock.unlock() }; return _request }
        var body: Data { lock.lock(); defer { lock.unlock() }; return _body }
    }
}
