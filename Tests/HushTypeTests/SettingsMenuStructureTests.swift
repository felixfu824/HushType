import AppKit
import XCTest
@testable import HushType

@MainActor
final class SettingsMenuStructureTests: XCTestCase {
    func testFinalMenuHasExactStructureAndSingleSettingsEntry() {
        let originalLanguage = AppConfig.shared.interfaceLanguageRaw
        defer {
            AppConfig.shared.interfaceLanguageRaw = originalLanguage
            L10n.resetLaunchStateForTests()
        }
        AppConfig.shared.interfaceLanguage = .english
        L10n.resetLaunchStateForTests()

        let model = makeTextModel()
        let controller = StatusBarController(
            localEngine: Qwen3TranscriptionEngine(),
            textSettingsModel: model
        )
        let items = controller.statusMenuForTesting.items
        let ordinary = items.filter { !$0.isSeparatorItem }

        XCTAssertEqual(ordinary.count, 10)
        XCTAssertEqual(items.filter(\.isSeparatorItem).count, 4)
        XCTAssertEqual(
            items.enumerated().compactMap { $0.element.isSeparatorItem ? $0.offset : nil },
            [1, 6, 8, 11]
        )

        let settingsTitle = L10n.string("menu.settings", fallback: "Settings…")
        let settingsItems = ordinary.filter { $0.title == settingsTitle }
        XCTAssertEqual(settingsItems.count, 1)
        XCTAssertEqual(ordinary.firstIndex(of: settingsItems[0]), 5)
        XCTAssertEqual(items.firstIndex(of: settingsItems[0]), 7)
        XCTAssertEqual(settingsItems[0].keyEquivalent, ",")
        XCTAssertEqual(settingsItems[0].keyEquivalentModifierMask, [.command])

        let preservedSubmenuTitles = [
            L10n.string("menu.live_caption", fallback: "Live Caption"),
            L10n.string("menu.live_translated_caption", fallback: "Live Translated Caption"),
            L10n.string("menu.text_translation", fallback: "Text Translation"),
        ]
        for title in preservedSubmenuTitles {
            XCTAssertNotNil(ordinary.first(where: { $0.title == title })?.submenu)
        }

        let translationParent = ordinary.first {
            $0.title == L10n.string("menu.text_translation", fallback: "Text Translation")
        }!
        let translationMenu = translationParent.submenu!
        let enableItem = translationMenu.items.first {
            $0.title == L10n.string(
                "menu.text_translation.enable",
                fallback: "Enable Text Translation"
            )
        }!
        let targetItem = translationMenu.items.first {
            $0.title == L10n.string("menu.translate_to", fallback: "Translate to")
        }!
        let hintItem = translationMenu.items.last!
        XCTAssertEqual(translationParent.state, .off)
        XCTAssertEqual(enableItem.state, .off)
        XCTAssertTrue(targetItem.isHidden)
        XCTAssertTrue(hintItem.isHidden)

        model.setTranslationEnabled(true)
        model.setTranslationTarget("ja")

        XCTAssertEqual(translationParent.state, .on)
        XCTAssertEqual(enableItem.state, .on)
        XCTAssertFalse(targetItem.isHidden)
        XCTAssertFalse(hintItem.isHidden)
        XCTAssertEqual(
            targetItem.submenu?.items.first(where: {
                ($0.representedObject as? String) == "ja"
            })?.state,
            .on
        )

        XCTAssertFalse(ordinary.contains { $0.title == "Dictation Settings" })
        XCTAssertFalse(ordinary.contains { $0.title == "Interface Language" })
        XCTAssertFalse(ordinary.contains { $0.title == "Edit Polish Instructions" })
    }

    private func makeTextModel() -> TextSettingsModel {
        TextSettingsModel(
            storage: .init(
                readPolishEnabled: { false },
                writePolishEnabled: { _ in },
                readTranslationEnabled: { false },
                writeTranslationEnabled: { _ in },
                readTranslationTarget: { nil },
                writeTranslationTarget: { _ in }
            ),
            initialPolishAvailability: true,
            validatePolish: { .ok },
            warmupPolish: {},
            releasePolish: {},
            presentUnavailable: { _ in },
            openInstructions: {}
        )
    }
}
