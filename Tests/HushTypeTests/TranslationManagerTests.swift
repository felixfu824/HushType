import XCTest
@testable import HushType

final class TranslationManagerTests: XCTestCase {
    func testExplicitTargetOverridesAutomaticDirection() {
        XCTAssertEqual(
            TranslationManager.resolveTargetIdentifier(
                sourceIdentifier: "en",
                preferredTargetIdentifier: "ja"
            ),
            "ja"
        )
        XCTAssertEqual(
            TranslationManager.resolveTargetIdentifier(
                sourceIdentifier: "zh-Hant",
                preferredTargetIdentifier: "fr"
            ),
            "fr"
        )
    }

    func testAutoTargetPreservesChineseToEnglishDirection() {
        XCTAssertEqual(
            TranslationManager.resolveTargetIdentifier(
                sourceIdentifier: "zh-Hans",
                preferredTargetIdentifier: nil
            ),
            "en"
        )
        XCTAssertEqual(
            TranslationManager.resolveTargetIdentifier(
                sourceIdentifier: "zh-Hant",
                preferredTargetIdentifier: nil
            ),
            "en"
        )
    }

    func testAutoTargetPreservesNonChineseToTraditionalChineseDirection() {
        XCTAssertEqual(
            TranslationManager.resolveTargetIdentifier(
                sourceIdentifier: "en",
                preferredTargetIdentifier: nil
            ),
            "zh-Hant-TW"
        )
        XCTAssertEqual(
            TranslationManager.resolveTargetIdentifier(
                sourceIdentifier: "ja",
                preferredTargetIdentifier: nil
            ),
            "zh-Hant-TW"
        )
    }
}
