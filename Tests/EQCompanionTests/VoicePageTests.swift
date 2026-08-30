import XCTest
import AVFoundation
@testable import EQCompanion

/// The Voice page's two pure decisions: the order a picker lists voices in, and the speed slider's
/// map onto what `AVSpeechUtterance` accepts.
final class VoicePageTests: XCTestCase {
    private let entries = [
        VoiceCatalog.Entry(id: "de.anna", name: "Anna", language: "de-DE"),
        VoiceCatalog.Entry(id: "en.samantha", name: "Samantha", language: "en-US"),
        VoiceCatalog.Entry(id: "en.daniel", name: "Daniel", language: "en-GB"),
        VoiceCatalog.Entry(id: "fr.thomas", name: "Thomas", language: "fr-FR")
    ]

    func testTheReadersOwnLanguageComesFirstThenTheRestAlphabetically() {
        let ids = VoiceCatalog.options(entries, preferring: "en_US").map(\.id)
        // en-GB before en-US (region, then name inside the language), then de, then fr.
        XCTAssertEqual(ids, ["en.daniel", "en.samantha", "de.anna", "fr.thomas"])
    }

    func testAnotherLocaleReordersTheGroups() {
        let ids = VoiceCatalog.options(entries, preferring: "fr-FR").map(\.id)
        XCTAssertEqual(ids, ["fr.thomas", "de.anna", "en.daniel", "en.samantha"])
    }

    func testLabelsCarryTheLanguageSoTwoNamesAreTellable() {
        let labels = VoiceCatalog.options(entries, preferring: "en-US").map(\.label)
        XCTAssertEqual(labels.first, "Daniel (en-GB)")
    }

    func testLanguageCodeTakesTheLanguagePartOfEitherSpelling() {
        XCTAssertEqual(VoiceCatalog.languageCode("en-US"), "en")
        XCTAssertEqual(VoiceCatalog.languageCode("en_GB"), "en")
        XCTAssertEqual(VoiceCatalog.languageCode("de"), "de")
    }

    @MainActor
    func testOneTimesSpeedIsThePlatformsOwnDefault() {
        XCTAssertEqual(AlertPlayer.utteranceRate(1.0), AVSpeechUtteranceDefaultSpeechRate, accuracy: 0.0001)
    }

    @MainActor
    func testSpeedStaysInsideWhatTheSynthesizerAccepts() {
        let slow = AlertPlayer.utteranceRate(0.5)
        let fast = AlertPlayer.utteranceRate(2.0)
        XCTAssertLessThan(slow, AVSpeechUtteranceDefaultSpeechRate)
        XCTAssertGreaterThan(fast, AVSpeechUtteranceDefaultSpeechRate)
        for m in [0.1, 0.5, 1.0, 2.0, 9.0] {
            let r = AlertPlayer.utteranceRate(m)
            XCTAssertGreaterThanOrEqual(r, AVSpeechUtteranceMinimumSpeechRate)
            XCTAssertLessThanOrEqual(r, AVSpeechUtteranceMaximumSpeechRate)
        }
    }
}
