import Foundation
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics
@testable import PhotoFlow

/// Gemensam testutrustning för Objektfilm: temporära mappar, syntetiska bilder (med riktig JPEG-fil,
/// valfritt med GPS/EXIF) och en låtsasserver bakom `URLProtocol`. Ingen riktig nätverkstrafik.
enum ObjektfilmTestKit {

    static func tempDir(_ name: String = "Objektfilm") throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func sha(_ n: Int) -> String { String(format: "%012x", n) + String(repeating: "0", count: 52) }

    /// Skriver en JPEG med färgfält som beror på `seed` (olika innehåll = olika hash). `gps`: lägg
    /// GPS-position, EXIF-kommentar och IPTC-nyckelord i filen.
    @discardableResult
    static func writeJPEG(to url: URL, width: Int = 320, height: Int = 240, seed: Int = 0, gps: Bool = false) -> URL {
        let space = CGColorSpace(name: CGColorSpace.displayP3)!
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        for y in stride(from: 0, to: height, by: 8) {
            for x in stride(from: 0, to: width, by: 8) {
                ctx.setFillColor(red: CGFloat((x + seed * 37) % 255) / 255, green: CGFloat((y + seed * 71) % 255) / 255,
                                 blue: CGFloat((x + y + seed * 13) % 255) / 255, alpha: 1)
                ctx.fill(CGRect(x: x, y: y, width: 8, height: 8))
            }
        }
        var props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.9, kCGImagePropertyOrientation: 1]
        if gps {
            props[kCGImagePropertyGPSDictionary] = [
                kCGImagePropertyGPSLatitude: 59.3293, kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 18.0686, kCGImagePropertyGPSLongitudeRef: "E"]
            props[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifUserComment: "Hemlig adress"]
            props[kCGImagePropertyIPTCDictionary] = [kCGImagePropertyIPTCKeywords: ["privat"]]
            props[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFMake: "TestCam"]
        }
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, props as CFDictionary)
        CGImageDestinationFinalize(dest)
        return url
    }

    /// Syntetisk analys utan fil (för ren logik).
    static func analysis(_ n: Int, room: String = "Rum", category: String = "Interiör", q: Double = 0.5,
                         width: Int = 6000, height: Int = 4000) -> ReelImageAnalysis {
        ReelImageAnalysis(
            sha256: sha(n), width: width, height: height, qualityScore: q, isUtility: false,
            horizonAngleDegrees: nil, sharpness: nil, featurePrint: nil, saliencyBoxes: [],
            focus: .init(x: 0.5, y: 0.5), salientWidth: 0.4, meanLuminance: 0.45, exifDate: nil,
            room: room, category: category, features: nil, caption: nil)
    }

    /// `count` riktiga JPEG-filer i `dir` med verkliga hashar, som analyserade bilder.
    static func realItems(count: Int, in dir: URL, gps: Bool = false) throws -> [ReelImageAnalyzer.Item] {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let rooms = ["Fasad", "Vardagsrum", "Kök", "Sovrum", "Badrum", "Hall", "Trädgård", "Arbetsrum"]
        return (0..<count).map { n in
            let url = writeJPEG(to: dir.appendingPathComponent("bild-\(n).jpg"), seed: n + 1, gps: gps)
            let sha = ReelImageAnalyzer.sha256Hex(of: url)!
            var a = analysis(0, room: rooms[n % rooms.count], category: n % 8 == 0 || n % 8 == 6 ? "Exteriör" : "Interiör",
                             q: 0.9 - Double(n) * 0.05, width: 320, height: 240)
            a.sha256 = sha
            return .init(url: url, analysis: a)
        }
    }
}

// MARK: - Låtsasserver

/// URLProtocol som svarar via en handler per värdnamn, så att tester kan köras parallellt.
nonisolated final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    struct Reply {
        var status: Int = 200
        var headers: [String: String] = [:]
        var body: Data = Data()
        /// Fel i stället för svar (t.ex. URLError).
        var error: Error?

        static func json(_ object: Any, status: Int = 200, headers: [String: String] = [:]) -> Reply {
            Reply(status: status, headers: headers.merging(["Content-Type": "application/json"]) { a, _ in a },
                  body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
        }
    }
    typealias Handler = @Sendable (URLRequest, Data) -> Reply

    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]
    private static let lock = NSLock()

    static func register(host: String, handler: @escaping Handler) {
        lock.lock(); handlers[host] = handler; lock.unlock()
    }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = self.request
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 65536)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                body.append(buffer, count: n)
            }
            stream.close()
        }
        Self.lock.lock()
        let handler = request.url?.host.flatMap { Self.handlers[$0] }
        Self.lock.unlock()
        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        let reply = handler(request, body)
        if let error = reply.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Förenklad Objektfilm-server i minnet: tillräckligt för klient- och delningsmodelltester.
nonisolated final class FakeObjektfilmServer: @unchecked Sendable {
    let host = "fake-\(UUID().uuidString.prefix(8).lowercased()).test"
    var baseURL: URL { URL(string: "http://\(host)")! }
    let photographerKey = "pf_testkey"

    private let lock = NSLock()
    private(set) var objectId = "00000000-0000-4000-8000-000000000001"
    private(set) var revision = 0
    private(set) var status = "draft"
    private(set) var specJSON: [String: Any]?
    private(set) var variants: [String: Data] = [:]      // "sha/variant" → jpeg
    private(set) var pool: [[String: Any]] = []
    private(set) var links: [[String: Any]] = []
    private(set) var requests: [String] = []
    private(set) var ifMatches: [String] = []
    var failNextWith: MockURLProtocol.Reply?

    init() {
        MockURLProtocol.register(host: host) { [unowned self] req, body in self.handle(req, body) }
    }

    func session() -> URLSession { MockURLProtocol.session() }
    func client() -> ReelServerClient {
        ReelServerClient(baseURL: baseURL, key: photographerKey, session: session(), maxRetries: 0, backoff: { _ in .zero })
    }

    var specRevisionAsKnown: Int { lock.withLock { revision } }

    /// Mäklaren ändrar: ny ordning på klippen (asset-id:n) och en ny revision i läge proposed.
    func agentReorders(_ order: [String]) {
        lock.lock(); defer { lock.unlock() }
        guard var spec = specJSON, var timeline = spec["timeline"] as? [[String: Any]] else { return }
        timeline.sort { (order.firstIndex(of: $0["asset"] as! String) ?? 99) < (order.firstIndex(of: $1["asset"] as! String) ?? 99) }
        spec["timeline"] = timeline
        revision += 1
        spec["revision"] = revision
        spec["updatedAt"] = "2026-10-03T12:00:00.123Z"      // servern skriver millisekunder
        spec["updatedBy"] = ["role": "agent"]
        specJSON = spec
        status = "proposed"
    }

    private func handle(_ req: URLRequest, _ body: Data) -> MockURLProtocol.Reply {
        lock.lock(); defer { lock.unlock() }
        let path = req.url!.path
        let method = req.httpMethod ?? "GET"
        requests.append("\(method) \(path)")
        if let fail = failNextWith { failNextWith = nil; return fail }
        guard req.value(forHTTPHeaderField: "Authorization") == "Bearer \(photographerKey)" else {
            return .json(["error": ["code": "unauthorized", "message": "Ogiltig nyckel."]], status: 401)
        }
        switch (method, path) {
        case ("GET", "/api/v1/me"):
            return .json(["apiVersion": 1, "scope": "photographer", "keyId": "k1", "photographer": ["id": "p1", "name": "Testfotograf"]])
        case ("PUT", _) where path.hasPrefix("/api/v1/objects/by-reel/"):
            return .json(["objectId": objectId, "status": status, "currentRevision": revision])
        case ("POST", "/api/v1/assets/check"):
            let shas = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])?["sha256"] as? [String] ?? []
            return .json(["missing": shas.filter { variants["\($0)/w1600"] == nil || variants["\($0)/w480"] == nil }])
        case ("PUT", _) where path.hasPrefix("/api/v1/assets/"):
            let parts = path.split(separator: "/").map(String.init)   // api v1 assets sha variant
            if Self.hasMetadataSegments(body) {
                return .json(["error": ["code": "gps_in_image", "message": "Bilden innehåller metadata."]], status: 422)
            }
            variants["\(parts[3])/\(parts[4])"] = body
            return .json(["sha256": parts[3], "variant": parts[4], "bytes": body.count])
        case ("PUT", "/api/v1/objects/\(objectId)/pool"):
            pool = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])?["assets"] as? [[String: Any]] ?? []
            return .json(["count": pool.count])
        case ("PUT", "/api/v1/objects/\(objectId)/spec"):
            let ifMatch = req.value(forHTTPHeaderField: "If-Match") ?? ""
            ifMatches.append(ifMatch)
            guard ifMatch == "\"\(revision)\"" else {
                return .json(["error": ["code": "revision_conflict", "message": "Specen har ändrats av någon annan."],
                              "currentRevision": revision, "spec": specJSON.map { $0 as Any } ?? NSNull()], status: 412)
            }
            guard var spec = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
                return .json(["error": ["code": "bad_json", "message": "Trasig JSON."]], status: 400)
            }
            revision += 1
            spec["revision"] = revision
            spec["status"] = status
            specJSON = spec
            return .json(["objectId": objectId, "revision": revision, "status": status, "changed": true, "spec": spec])
        case ("POST", "/api/v1/objects/\(objectId)/links"):
            let n = links.count + 1
            let label = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])?["label"] as? String
            links.append(["linkId": "link-\(n)", "label": label as Any, "createdAt": "2026-10-03T10:00:00.000Z",
                          "expiresAt": "2026-11-02T10:00:00.000Z", "revokedAt": NSNull(), "lastUsedAt": NSNull()])
            status = "proposed"
            return .json(["linkId": "link-\(n)", "url": "http://\(host)/m#TOKEN\(n)", "archiveUrl": "http://\(host)/a#TOKEN\(n)",
                          "expiresAt": "2026-11-02T10:00:00.000Z", "status": "proposed"], status: 201)
        case ("GET", "/api/v1/objects/\(objectId)"):
            return .json(["objectId": objectId, "reelId": specJSON?["id"] ?? "", "address": "Testgatan 1", "status": status,
                          "currentRevision": revision, "approvedRevision": NSNull(),
                          "spec": specJSON.map { $0 as Any } ?? NSNull(), "pool": pool, "links": links, "renders": [], "jobs": []])
        default:
            return .json(["error": ["code": "not_found", "message": "Finns inte."]], status: 404)
        }
    }

    /// Samma kontroll som servern: APP1 (EXIF/XMP), APP13 (IPTC) eller kommentar.
    static func hasMetadataSegments(_ jpeg: Data) -> Bool { ReelWebVariant.hasMetadata(jpeg) }
}
