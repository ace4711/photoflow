import Foundation
import Testing
@testable import PhotoFlow

/// ToolLocator replaces hardcoded tool paths (e.g. "/opt/homebrew/bin/exiftool")
/// scattered across PipelineRunner, which broke on setups where Homebrew lives
/// elsewhere (Intel Macs use /usr/local/bin) or a tool simply isn't installed yet.
struct ToolLocatorTests {

    @Test("exiftool hittas i något av de kända sökvägarna om det finns installerat")
    func exiftool_findsKnownPathOrNil() {
        if let path = ToolLocator.exiftool {
            #expect(path.hasSuffix("/exiftool"))
            #expect(FileManager.default.fileExists(atPath: path))
        }
        // Absence is also a valid outcome on a machine without exiftool installed —
        // this test only verifies we never return a bogus/nonexistent path.
    }

    @Test("python3WithOpenCV returnerar en existerande fil eller nil, aldrig ett fantompath")
    func python3WithOpenCV_findsExistingPathOrNil() {
        ToolLocator.resetCacheForTesting()
        if let path = ToolLocator.python3WithOpenCV {
            #expect(path.hasSuffix("/python3"))
            #expect(FileManager.default.fileExists(atPath: path))
        }
    }

    @Test("python3WithOpenCV cachar resultatet mellan anrop")
    func python3WithOpenCV_isCachedBetweenCalls() {
        ToolLocator.resetCacheForTesting()
        let first = ToolLocator.python3WithOpenCV
        let second = ToolLocator.python3WithOpenCV
        #expect(first == second)
    }
}
