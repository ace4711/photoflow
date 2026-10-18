import Foundation
import Testing
@testable import PhotoFlow

/// Argumenttolkningen för `photoflow-cli hdr` / `lr-trigger` och manifest-/triggerlogiken
/// (docs/plan-hdr-jamforelse.md, fas 1–2).
struct HDRCompareCLITests {

    @Test("hdr: flera ramar, metod, utfiler och valfria flaggor tolkas")
    func parsesHDRArguments() throws {
        let parsed = try HDRCompareCLI.parseHDR([
            "--frames", "/a/1.NEF", "/a/2.NEF", "/a/3.NEF",
            "--method", "fusion", "--out", "/o/x.tiff",
            "--window-source", "/a/0.NEF", "--hdr-debug", "/o/dbg",
        ])
        #expect(parsed.frames == ["/a/1.NEF", "/a/2.NEF", "/a/3.NEF"])
        #expect(parsed.method == .fusion)
        #expect(parsed.out == "/o/x.tiff")
        #expect(parsed.jpeg == nil)
        #expect(parsed.resolvedJPEG == "/o/x.jpg")
        #expect(parsed.windowSource == "/a/0.NEF")
        #expect(parsed.debugDir == "/o/dbg")
    }

    @Test("hdr: standardmetoden är radiance och --jpeg gäller")
    func hdrDefaults() throws {
        let parsed = try HDRCompareCLI.parseHDR(["--out", "/o/x.tiff", "--jpeg", "/p/y.jpg", "--frames", "a", "b"])
        #expect(parsed.method == .radiance)
        #expect(parsed.resolvedJPEG == "/p/y.jpg")
        #expect(try HDRCompareCLI.parseHDR(["--frames", "a", "b", "--method", "base", "--out", "o.tiff"]).method == .baseFrame)
    }

    @Test("hdr: felaktiga argument avvisas")
    func hdrRejectsBadArguments() {
        #expect(throws: HDRCompareCLI.ParseError.self) { try HDRCompareCLI.parseHDR(["--frames", "a", "b"]) }
        #expect(throws: HDRCompareCLI.ParseError.self) { try HDRCompareCLI.parseHDR(["--frames", "a", "--out", "o"]) }
        #expect(throws: HDRCompareCLI.ParseError.self) { try HDRCompareCLI.parseHDR(["--frames", "--out", "o"]) }
        #expect(throws: HDRCompareCLI.ParseError.self) { try HDRCompareCLI.parseHDR(["--frames", "a", "b", "--out", "o", "--method", "opencv"]) }
        #expect(throws: HDRCompareCLI.ParseError.self) { try HDRCompareCLI.parseHDR(["--frames", "a", "b", "--out"]) }
        #expect(throws: HDRCompareCLI.ParseError.self) { try HDRCompareCLI.parseHDR(["--frames", "a", "b", "--out", "o", "--nope"]) }
    }

    @Test("lr-trigger: flaggor tolkas")
    func parsesLRTrigger() throws {
        let parsed = try HDRCompareCLI.parseLRTrigger(["--manifest", "m.json", "--wait", "--bridge-dir", "/tmp/b", "--timeout", "90"])
        #expect(parsed == .init(manifest: "m.json", wait: true, collect: false, bridgeDir: "/tmp/b", timeoutSeconds: 90))
        #expect(throws: HDRCompareCLI.ParseError.self) { try HDRCompareCLI.parseLRTrigger(["--wait"]) }
        #expect(throws: HDRCompareCLI.ParseError.self) { try HDRCompareCLI.parseLRTrigger(["--manifest", "m", "--timeout", "0"]) }
    }

    @Test("Bryggmappen: flagga före miljövariabel före standard")
    func bridgeDirectoryPrecedence() {
        let env = [HDRCompareCLI.bridgeEnvironmentKey: "/tmp/env"]
        #expect(HDRCompareCLI.bridgeDirectory(override: "/tmp/flag", environment: env).path == "/tmp/flag")
        #expect(HDRCompareCLI.bridgeDirectory(override: nil, environment: env).path == "/tmp/env")
        #expect(HDRCompareCLI.bridgeDirectory(override: nil, environment: [:]).path.hasSuffix("Library/Application Support/PhotoFlow"))
    }

    private let manifest: [String: Any] = [
        "version": 1,
        "groups": [
            ["id": "g-01", "frames": [["file": "nef/g-01/A.NEF", "exposureSeconds": 0.1], ["file": "nef/g-01/B.NEF", "exposureSeconds": 0.2]],
             "variants": ["pf-radiance": "out/g-01/pf-radiance.tiff"]],
            ["id": "g-02", "frames": [["file": "nef/g-02/C.NEF"], ["file": "nef/g-02/D.NEF"]]],
        ] as [[String: Any]],
    ]

    @Test("Triggern: experimentläge, absoluta NEF-sökvägar och exportmapp per grupp")
    func triggerPayload() throws {
        let root = URL(fileURLWithPath: "/bench/hdr-lr")
        let payload = try HDRCompareCLI.triggerPayload(manifest: manifest, root: root)
        #expect(payload["mode"] as? String == "experiment")
        let groups = try #require(payload["groups"] as? [[String: Any]])
        #expect(groups.count == 2)
        #expect(groups[0]["group_id"] as? Int == 1)
        #expect(groups[0]["id"] as? String == "g-01")
        #expect(groups[0]["files"] as? [String] == ["/bench/hdr-lr/nef/g-01/A.NEF", "/bench/hdr-lr/nef/g-01/B.NEF"])
        #expect(groups[1]["export_dir"] as? String == "/bench/hdr-lr/out/g-02")
    }

    @Test("Resultatet förs in i manifestet utan att andra varianter eller fält tappas")
    func mergesStatusIntoManifest() {
        let root = URL(fileURLWithPath: "/bench/hdr-lr")
        var manifest = manifest
        manifest["metricsNote"] = "behålls"
        let status: [String: Any] = [
            "status": "complete", "plugin_version": "1.4",
            "results": [
                ["group_id": 1, "id": "g-01", "status": "ok", "message": "klar",
                 "export": "/bench/hdr-lr/out/g-01/lr-auto.tif", "dng": "/bench/hdr-lr/out/g-01/lr.dng",
                 "develop": ["Exposure2012": 0.35]],
                ["group_id": 2, "id": "g-02", "status": "error", "message": "ingen DNG"],
            ] as [[String: Any]],
        ]
        let ok = HDRCompareCLI.merge(status: status, into: &manifest, root: root)
        #expect(ok == 1)
        #expect(manifest["metricsNote"] as? String == "behålls")
        let groups = manifest["groups"] as? [[String: Any]] ?? []
        let variants = groups[0]["variants"] as? [String: Any]
        #expect(variants?["pf-radiance"] as? String == "out/g-01/pf-radiance.tiff")
        #expect(variants?["lr-auto"] as? String == "out/g-01/lr-auto.tif")
        #expect(variants?["lr-dng"] as? String == "out/g-01/lr.dng")
        #expect((groups[0]["lr"] as? [String: Any])?["develop"] != nil)
        #expect((groups[1]["lr"] as? [String: Any])?["status"] as? String == "error")
        #expect((groups[1]["variants"] as? [String: Any])?["lr-auto"] == nil)
        #expect(manifest["lrRun"] != nil)
    }
}
