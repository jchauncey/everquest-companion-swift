import XCTest
@testable import EQCompanion

final class MapAnnotationsTests: XCTestCase {
    /// The generated files must round-trip through the app's own parser: same coordinates,
    /// spaces restored in the display label, nothing skipped.
    @MainActor
    func testGeneratedPackParsesBack() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("wiki-annotations-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let r = try MapAnnotations.generate(into: tmp)
        // Regenerating our own pack is allowed; a foreign directory is refused.
        _ = try MapAnnotations.generate(into: tmp)
        let foreign = FileManager.default.temporaryDirectory.appendingPathComponent("foreign-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: foreign) }
        XCTAssertThrowsError(try MapAnnotations.generate(into: foreign))
        XCTAssertNil(MapAnnotations.validName("  "))
        XCTAssertEqual(MapAnnotations.validName(" My Pack "), "My Pack")
        XCTAssertGreaterThan(r.zones, 50, "the wiki states positions in many zones")
        XCTAssertGreaterThan(r.labels, r.zones)
        let files = try FileManager.default.contentsOfDirectory(atPath: tmp.path)
        XCTAssertEqual(files.filter { $0.hasSuffix(".txt") }.count, r.zones)
        guard let f = files.first(where: { $0.hasSuffix("_1.txt") }) else { return XCTFail("no _1 files") }
        let text = try String(contentsOf: tmp.appendingPathComponent(f), encoding: .utf8)
        let parsed = MapFile.parse(text: text, layer: 1)
        XCTAssertEqual(parsed.skipped, 0, "every generated line must parse")
        XCTAssertFalse(parsed.points.isEmpty)
        XCTAssertTrue(parsed.points.allSatisfy { $0.r == 200 && $0.size == 2 })
        XCTAssertTrue(parsed.points.allSatisfy { !$0.display.contains("_") })
        // The default filter keeps the named (capitalized) mobs and drops the lowercase fluff.
        XCTAssertTrue(parsed.points.allSatisfy { $0.display.first?.isUppercase ?? false })
        let all = try MapAnnotations.generate(into: tmp, filter: .init(common: true))
        XCTAssertGreaterThan(all.labels, r.labels, "including common spawns must add labels")
    }
}
