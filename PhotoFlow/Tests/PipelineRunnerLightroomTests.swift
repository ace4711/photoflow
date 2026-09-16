import Foundation
import Testing
@testable import PhotoFlow

/// Tests for the Fas 4 Lightroom bridge-path fix: the app previously wrote
/// its HDR trigger file under `NSTemporaryDirectory()` while
/// `PhotoFlowLR.lrplugin`'s Lua side read it from
/// `LrPathUtils.getStandardFilePath("temp")` — two different APIs that
/// happen to resolve to the same place on this machine, but aren't
/// guaranteed to. Both sides now use the same fixed, well-known
/// `~/Library/Application Support/PhotoFlow` folder instead (see
/// `HDRMergeCore.lua`'s `bridgeDir()`, which must match this exactly).
@MainActor
struct PipelineRunnerLightroomTests {

    @Test("lightroomBridgeDirectory pekar på ~/Library/Application Support/PhotoFlow och skapar mappen")
    func lightroomBridgeDirectory_isKnownSharedLocationAndExists() {
        let dir = PipelineRunner.lightroomBridgeDirectory
        let expected = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("PhotoFlow", isDirectory: true)

        #expect(dir.path == expected.path)
        #expect(dir.path.hasSuffix("Library/Application Support/PhotoFlow"))
        #expect(FileManager.default.fileExists(atPath: dir.path))
    }

    @Test("lightroomBridgeDirectory ger samma sökväg vid upprepade anrop")
    func lightroomBridgeDirectory_isStable() {
        #expect(PipelineRunner.lightroomBridgeDirectory.path == PipelineRunner.lightroomBridgeDirectory.path)
    }
}
