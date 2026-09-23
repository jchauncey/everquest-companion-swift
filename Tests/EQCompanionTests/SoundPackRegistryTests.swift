import XCTest
@testable import EQCompanion
import EQCompanionCore

/// The registry is untrusted: its rows become directory names and URLs. These are the allowlists
/// that stand between a row and the file system, and the conversion that names the files.
final class SoundPackRegistryTests: XCTestCase {
    func testPackIdsAreIdentifiersAndNothingElse() {
        for ok in ["alan-rickman", "pack_1", "a.b-c", "9lives"] { XCTAssertTrue(isSafePackId(ok), ok) }
        for bad in ["", "..", ".hidden", "-lead", "a/b", "a\\b", "émile", "a b", String(repeating: "x", count: 129)] {
            XCTAssertFalse(isSafePackId(bad), bad)
        }
    }

    func testSourceRepoIsOwnerSlashRepo() {
        XCTAssertTrue(isSafeSourceRepo("utensils/openpeon-alan-rickman-soundpack"))
        for bad in ["", "owner", "a/b/c", "../repo", "owner/..", "owner/.", "-owner/repo", "own er/repo", "owner/re po"] {
            XCTAssertFalse(isSafeSourceRepo(bad), bad)
        }
    }

    func testSourceRefRefusesTraversal() {
        XCTAssertTrue(isSafeSourceRef("v1.1.2"))
        for bad in ["", "..", "v1/../main", ".v1", "v1 2", "main/branch"] { XCTAssertFalse(isSafeSourceRef(bad), bad) }
    }

    func testSourcePathIsRelativeWithoutTraversal() {
        for ok in ["", ".", "packs/rickman", "packs/rickman/"] { XCTAssertTrue(isSafeSourcePath(ok), ok) }
        for bad in ["/abs", "../up", "a/../b", "C:/x", "a\\b", "a\0b", "/"] { XCTAssertFalse(isSafeSourcePath(bad), bad) }
    }

    func testConversionLandsEveryFileUnderSoundsByItsBaseName() throws {
        let cesp = try JSONValue.parse(#"""
        {"categories": {
          "task.complete": {"sounds": [{"file": "sounds/done.wav", "label": "Done"}, "sounds/done.wav"]},
          "session.start": {"sounds": ["../../escape/hello.mp3"]}
        }}
        """#)
        let out = convertCesp(cesp)
        XCTAssertEqual(out.map(\.file), ["sounds/hello.mp3", "sounds/done.wav", "sounds/done.wav"])
        XCTAssertEqual(out.map(\.soundId), ["session-start-hello", "task-complete-done", "task-complete-done-2"])
        // The GET path is the manifest's own; the installer refuses the `..` in it before fetching.
        XCTAssertEqual(out.first?.sourceFile, "../../escape/hello.mp3")
        XCTAssertEqual(out[1].label, "Complete · Done")
    }
}
