import XCTest
import EQCompanionCore
@testable import EQCompanion

/// The share wire format, pinned against the Electron app's own rules — the checksum is computed
/// over `canonicalJson(body)` on both sides, so a serializer that disagreed by one byte would make
/// every cross-app paste read as "damaged".
final class PrefsShareTests: XCTestCase {

    // MARK: - canonical JSON

    func testCanonicalJsonSortsKeysAndDropsWhitespace() {
        let v: JSONValue = ["b": .int(2), "a": .int(1), "c": ["z": .bool(true), "y": .null]]
        XCTAssertEqual(ShareCodec.canonicalJson(v), #"{"a":1,"b":2,"c":{"y":null,"z":true}}"#)
    }

    /// `JSON.stringify` prints an integral double with no fraction, and never escapes a slash.
    func testCanonicalJsonMatchesJsNumberAndStringSpelling() {
        XCTAssertEqual(ShareCodec.canonicalJson(.double(1)), "1")
        XCTAssertEqual(ShareCodec.canonicalJson(.double(0.7)), "0.7")
        XCTAssertEqual(ShareCodec.canonicalJson(.double(-0)), "0")
        XCTAssertEqual(ShareCodec.canonicalJson(.string("a/b")), "\"a/b\"")
        XCTAssertEqual(ShareCodec.canonicalJson(.string("é")), "\"é\"")
        XCTAssertEqual(ShareCodec.canonicalJson(.string("a\nb\t\"c\"")), #""a\nb\t\"c\"""#)
        // A C0 control has no short escape, so it takes the four-hex form - lowercase, as JS.
        XCTAssertEqual(ShareCodec.canonicalJson(.string("\u{01}")), "\"\\u0001\"")
    }

    /// FNV-1a 32-bit over UTF-16 code units, folded byte-wise — the values node produces.
    func testChecksumMatchesTheReferenceDigest() {
        XCTAssertEqual(ShareCodec.checksum(""), "811c9dc5")
        XCTAssertEqual(ShareCodec.checksum("a"), "e40c292c")
        XCTAssertEqual(ShareCodec.checksum("foobar"), "bf9cf968")
    }

    // MARK: - the codec

    func testEncodeDecodeRoundTrip() {
        let body: JSONValue = ["alerts": .array([]), "ui": ["eq.favorites": .string("[\"rune\"]")]]
        let env = ShareCodec.envelope(kind: .settings, body: body, appVersion: "1.14.0")
        let text = ShareCodec.encode(env)
        XCTAssertTrue(text.hasPrefix("EQC1-"))
        XCTAssertTrue(ShareCodec.looksLikeShareString(text))

        guard case .success(let decoded) = ShareCodec.decode(text) else {
            return XCTFail("a string this app just wrote must decode")
        }
        XCTAssertEqual(decoded.kind, .settings)
        XCTAssertEqual(decoded.app, "1.14.0")
        XCTAssertEqual(decoded.body, body)
    }

    /// A paste survives what chat clients do to it — wrapped lines, a code fence, a trailing stop.
    func testDecodeToleratesAMangledPaste() {
        let text = ShareCodec.encode(ShareCodec.envelope(kind: .settings, body: ["alerts": .array([])],
                                                         appVersion: "1.0.0"))
        let mangled = "`` `\n" + text.prefix(20) + "\n" + text.dropFirst(20) + "\n``` "
        guard case .success = ShareCodec.decode(mangled) else {
            return XCTFail("a wrapped, fenced paste is still a share string")
        }
    }

    func testDecodeRefusesTheWaysAStringCanBeWrong() {
        assertError(ShareCodec.decode(""), .empty)
        assertError(ShareCodec.decode("hello there"), .notAShareString)
        assertError(ShareCodec.decode("EQC2-abcdef"), .newerVersion)
        assertError(ShareCodec.decode("EQC1-not-base64-deflate"), .corrupt)
    }

    /// A body that does not match its `sum` is REJECTED rather than partially applied.
    func testAnInflateBombStopsAtTheLimitAndReadsAsTooLong() {
        // 8 MB of one byte deflates to a few kB: a paste that fits the input cap and would inflate
        // far past the JSON cap. The inflate stops just over the limit rather than finishing.
        let bomb = ShareCodec.deflateRaw(Data(repeating: 0x20, count: 8 << 20))
        XCTAssertLessThan(bomb.count, 64 * 1024)
        let out = ShareCodec.inflateRaw(bomb, limit: ShareCodec.Limits.maxJsonChars)
        XCTAssertNotNil(out)
        XCTAssertGreaterThan(out?.count ?? 0, ShareCodec.Limits.maxJsonChars)
        XCTAssertLessThan(out?.count ?? .max, ShareCodec.Limits.maxJsonChars + (2 << 20))
    }

    func testDecodeRefusesABadChecksum() {
        var env = ShareCodec.envelope(kind: .settings, body: ["alerts": .array([])], appVersion: "1.0.0")
        var o = env.object ?? [:]
        o["sum"] = .string("00000000")
        env = .object(o)
        assertError(ShareCodec.decode(ShareCodec.encode(env)), .checksum)
    }

    /// A string from the Electron app, made by `encodeShareString` on the real codec: an alerts
    /// envelope carrying one alert. It must decode here with its checksum intact.
    func testDecodesAnUpstreamSample() {
        let sample = "EQC1-" + upstreamSamplePayload
        guard case .success(let env) = ShareCodec.decode(sample) else {
            return XCTFail("the upstream sample must decode")
        }
        XCTAssertEqual(env.kind, .alerts)
        XCTAssertEqual(env.app, "1.14.0")
        XCTAssertEqual(env.body["alerts"].array?.count, 1)
        XCTAssertEqual(env.body["alerts"][0]["name"].string, "Charm break")
        // Re-encoding the decoded body reproduces the same checksum, which is the whole claim:
        // the two apps agree on what the canonical bytes of a body are.
        XCTAssertEqual(ShareCodec.checksum(ShareCodec.canonicalJson(env.body)), env.sum)
    }

    // MARK: - the bundle and its merge

    func testUiPrefsRideAsTheWireSpellsThem() {
        let d = UserDefaults(suiteName: "PrefsShareTests.ui")!
        d.removePersistentDomain(forName: "PrefsShareTests.ui")
        d.set(["Rune of Al'Kabor", "Sphinx Claw"], forKey: "eq.favorites")
        d.set("compact", forKey: "eq.bossDensity")
        let ui = SettingsBundle.readUiPrefs(d)
        XCTAssertEqual(ui["eq.favorites"], #"["Rune of Al'Kabor","Sphinx Claw"]"#)
        XCTAssertEqual(ui["eq.bossDensity"], "compact")
        // …and back, as the store keeps it.
        SettingsBundle.writeUiPref(SettingsBundle.uiSpecs.first { $0.key == "eq.favorites" }!,
                                   #"["a","b"]"#, d)
        XCTAssertEqual(d.stringArray(forKey: "eq.favorites"), ["a", "b"])
    }

    /// A union adds and never drops: yours first, then theirs, deduped.
    func testUnionKeepsEverythingYouHad() {
        XCTAssertEqual(ShareMerge.unionText(#"["a","b"]"#, #"["b","c"]"#), #"["a","b","c"]"#)
        XCTAssertEqual(ShareMerge.unionText(nil, #"["c"]"#), #"["c"]"#)
    }

    /// An alert you already hold is SKIPPED however its id is spelled, and an id collision that
    /// carries different behaviour is added under a fresh id rather than overwriting yours.
    func testAlertMergeIsAdditive() {
        var mine = AlertDef.fresh()
        mine.id = "aaa"
        mine.name = "Charm break"
        var sameBehaviourOtherId = mine
        sameBehaviourOtherId.id = "bbb"
        var otherBehaviourSameId = mine
        otherBehaviourSameId.name = "Something else"

        let body: JSONValue = ["alerts": .array([sameBehaviourOtherId.toJSON(), otherBehaviourSameId.toJSON()])]
        let ctx = ShareContext(alerts: [mine], globalVolume: 0.7, muted: false, alwaysPlayAll: false,
                               overlayShared: 0.72, overlayIndependent: false, overlays: [:], ui: [:])
        let plan = ShareMerge.planAlerts(body, ctx)
        XCTAssertEqual(plan.count, 2)
        XCTAssertEqual(plan[0].action, .skip)
        XCTAssertEqual(plan[1].action, .rekey)
        XCTAssertNotEqual(plan[1].finalId, "aaa")
    }

    /// Only rows that genuinely differ are offered, and each one is its own opt-in.
    func testScalarPlanOnlyShowsRealDifferences() {
        let body: JSONValue = ["alertPrefs": ["globalVolume": .double(0.7), "muted": .bool(true)],
                               "overlayBgAlpha": ["shared": .double(0.72), "independent": .bool(false)]]
        let ctx = ShareContext(alerts: [], globalVolume: 0.7, muted: false, alwaysPlayAll: false,
                               overlayShared: 0.72, overlayIndependent: false, overlays: [:], ui: [:])
        let rows = ShareMerge.planScalars(body, ctx)
        XCTAssertEqual(rows.map(\.id), ["alertPrefs.muted"])
        XCTAssertEqual(rows[0].current, "Off")
        XCTAssertEqual(rows[0].incoming, "On")
    }

    // MARK: - helpers

    private func assertError(_ r: Result<ShareEnvelope, ShareDecodeError>, _ want: ShareDecodeError,
                             file: StaticString = #filePath, line: UInt = #line) {
        switch r {
        case .success: XCTFail("expected \(want.rawValue)", file: file, line: line)
        case .failure(let got): XCTAssertEqual(got, want, file: file, line: line)
        }
    }

/// A share string produced by the Electron app's own `encodeShareString` — the envelope built by
/// `makeEnvelope('alerts', …)` around one alert, deflate-raw'd and base64url'd by src/main/
/// shareCodec.ts. Committed as bytes rather than rebuilt, so this test fails if either half of
/// this app's codec drifts from the format the other app writes.
let upstreamSamplePayload = "XY-xTsQwEER_BU3tnDYBIuL2KgpEARWIYhOv7qwkdnDsnE5R_h35dGkod_bt7MwKniZolIfy6UBQ4AiNiqq6oJeiaj7LShNpogMRfUGh9eYKvYIHCXGG_l7ReT8Yf3FvM_QjESmI43YQAx1DEgVroNGdOYxFG4R7KDgeBRrHLD7s4nz2l3f30QURt9_OPjmTH07c9a_ZiAd2RbBdP7LDHbgtrJtSLIL8JhvEFP9GqrApxGBPJwnZsLfZGMndkkEhXqecSRZxMbOLH1JOWW4_m9rxe2-FOY0Zbkzd8HMNhSWTfw"
}
