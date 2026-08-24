import AppKit
import XCTest
@testable import HushType

@MainActor
final class CloudSettingsTests: XCTestCase {
    override func setUp() {
        super.setUp()
        L10n.resetLaunchStateForTests()
    }

    override func tearDown() {
        L10n.resetLaunchStateForTests()
        super.tearDown()
    }

    func testResetCounterConfirmationKeepsCancelDefaultAndConfirmSecond() {
        withInterfaceLanguage(.english) {
            let alert = CloudSettingsModel.makeResetCounterAlert()

            XCTAssertEqual(alert.messageText, "Reset today's usage counter?")
            XCTAssertEqual(
                alert.informativeText,
                "This resets only HushType's estimate of today's cloud usage. It does not change usage or charges reported by OpenAI or Gemini. Cloud uploads will be allowed again today."
            )
            XCTAssertEqual(alert.buttons.map(\.title), ["Cancel", "Reset Counter"])
            XCTAssertEqual(alert.buttons[0].keyEquivalent, "\r")
            XCTAssertEqual(alert.buttons[1].keyEquivalent, "")
            XCTAssertTrue(alert.buttons[1].hasDestructiveAction)
        }
    }

    func testResetCounterConfirmationIsLocalizedInTraditionalChinese() {
        withInterfaceLanguage(.traditionalChineseTaiwan) {
            XCTAssertEqual(
                L10n.string("common.button.reset_counter", fallback: "Reset counter"),
                "重設今日用量計數…"
            )

            let alert = CloudSettingsModel.makeResetCounterAlert()
            XCTAssertEqual(alert.messageText, "要重設今日用量計數嗎？")
            XCTAssertEqual(
                alert.informativeText,
                "這只會重設 HushType 對今日雲端用量的估算，不會變更 OpenAI 或 Gemini 顯示的實際用量或費用。重設後，今日將可再次使用雲端上傳。"
            )
            XCTAssertEqual(alert.buttons.map(\.title), ["取消", "重設計數"])
        }
    }

    private func withInterfaceLanguage(
        _ language: InterfaceLanguage,
        assertions: () -> Void
    ) {
        let original = AppConfig.shared.interfaceLanguageRaw
        defer {
            AppConfig.shared.interfaceLanguageRaw = original
            L10n.resetLaunchStateForTests()
        }
        AppConfig.shared.interfaceLanguage = language
        L10n.resetLaunchStateForTests()
        assertions()
    }
}
