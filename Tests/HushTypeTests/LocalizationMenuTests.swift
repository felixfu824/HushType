import XCTest
import AppKit
@testable import HushType

/// Gate C Slice 2 — semantic menu behavior and lifecycle-safety checks.
@MainActor
final class LocalizationMenuTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "hushtype.interfaceLanguage")
        L10n.resetLaunchStateForTests()
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "hushtype.interfaceLanguage")
        L10n.resetLaunchStateForTests()
        super.tearDown()
    }

    func testAppliedNextLaunchOnlyWhenPreferenceDiffersFromLaunchSnapshot() {
        XCTAssertFalse(GeneralSettingsModel.shouldShowAppliedNextLaunch(
            persisted: .system,
            launch: .system
        ))
        XCTAssertFalse(GeneralSettingsModel.shouldShowAppliedNextLaunch(
            persisted: .traditionalChineseTaiwan,
            launch: .traditionalChineseTaiwan
        ))
        XCTAssertTrue(GeneralSettingsModel.shouldShowAppliedNextLaunch(
            persisted: .traditionalChineseTaiwan,
            launch: .english
        ))
        XCTAssertTrue(GeneralSettingsModel.shouldShowAppliedNextLaunch(
            persisted: .english,
            launch: .system
        ))
    }

    func testLanguageSavedAlertHasExactlyOneLocalizedOKButton() {
        AppConfig.shared.interfaceLanguage = .english
        L10n.resetLaunchStateForTests()

        let alert = GeneralSettingsModel.makeLanguageSavedAlert()
        XCTAssertEqual(alert.messageText, "Language Saved")
        XCTAssertEqual(alert.buttons.count, 1)
        XCTAssertEqual(alert.buttons.first?.title, "OK")
        XCTAssertEqual(alert.alertStyle, .informational)
    }

    func testGeneralShortcutReferenceIsExactInEnglishAndTraditionalChinese() {
        let keysAndEnglish = [
            ("settings.general.shortcuts", "Shortcuts:"),
            ("settings.general.shortcuts.hold_option", "Hold Right ⌥"),
            ("settings.general.shortcuts.dictate", "Dictate"),
            ("settings.general.shortcuts.tap_option", "Tap Right ⌥"),
            ("settings.general.shortcuts.translate", "Translate selection"),
            ("settings.general.shortcuts.double_tap_option", "Double-tap Right ⌥"),
            ("settings.general.shortcuts.proofread", "Proofread selection"),
            ("settings.general.shortcuts.caption_key", "Right ⌘ + /"),
            ("settings.general.shortcuts.caption_action", "Toggle Live Caption"),
        ]
        let keysAndChinese = [
            ("settings.general.shortcuts", "快速鍵："),
            ("settings.general.shortcuts.hold_option", "按住右 ⌥"),
            ("settings.general.shortcuts.dictate", "語音輸入"),
            ("settings.general.shortcuts.tap_option", "輕點右 ⌥"),
            ("settings.general.shortcuts.translate", "翻譯選取文字"),
            ("settings.general.shortcuts.double_tap_option", "連按兩下右 ⌥"),
            ("settings.general.shortcuts.proofread", "校對選取文字"),
            ("settings.general.shortcuts.caption_key", "右 ⌘ + /"),
            ("settings.general.shortcuts.caption_action", "切換即時字幕"),
        ]

        AppConfig.shared.interfaceLanguage = .english
        L10n.resetLaunchStateForTests()
        for (key, expected) in keysAndEnglish {
            XCTAssertEqual(L10n.string(key, fallback: "missing"), expected)
        }

        AppConfig.shared.interfaceLanguage = .traditionalChineseTaiwan
        L10n.resetLaunchStateForTests()
        for (key, expected) in keysAndChinese {
            XCTAssertEqual(L10n.string(key, fallback: "missing"), expected)
        }
    }

    func testCaptionRoleIsSemanticAndLocalized() {
        AppConfig.shared.interfaceLanguage = .english
        L10n.resetLaunchStateForTests()
        XCTAssertEqual(CaptionLineRole.source.label, "SOURCE")
        XCTAssertEqual(CaptionLineRole.translated.accessibilityLabel, "Translated")

        AppConfig.shared.interfaceLanguage = .traditionalChineseTaiwan
        L10n.resetLaunchStateForTests()
        XCTAssertEqual(CaptionLineRole.source.label, "原文")
        XCTAssertEqual(CaptionLineRole.translated.label, "翻譯")
        XCTAssertEqual(CaptionLineRole.source.accessibilityLabel, "原文語言")
    }

    func testModelMenuActionIsTyped() {
        let unload: StatusBarController.ModelMenuAction = .unload
        let reload: StatusBarController.ModelMenuAction = .reload
        XCTAssertNotEqual(unload, reload)
    }

    func testLanguageSelectionHandlerHasNoLifecycleAuthorityAndStrictNoOpGuard() throws {
        let body = try sourceSlice(
            from: "@objc private func interfaceLanguageSelected",
            until: "static func makeLanguageSavedAlert",
            in: "Settings/GeneralPane.swift"
        )
        XCTAssertTrue(body.contains("selected != AppConfig.shared.interfaceLanguage"))
        for forbidden in ["restart", "terminate", "NSApp", "AppDelegate", ".cancel", ".stop", "quitClicked"] {
            XCTAssertFalse(body.localizedCaseInsensitiveContains(forbidden), "Forbidden lifecycle call in language handler: \(forbidden)")
        }
    }

    func testNextLaunchRowAlwaysReservesLayoutSpaceAndTracksAccessibility() throws {
        let body = try sourceSlice(
            from: "menu.interface_language.applied_next_launch",
            until: "settings.general.language.note",
            in: "Settings/GeneralPane.swift"
        )
        XCTAssertTrue(body.contains(".opacity(model.appliedNextLaunchVisible ? 1 : 0)"))
        XCTAssertTrue(body.contains(".accessibilityHidden(!model.appliedNextLaunchVisible)"))
        XCTAssertFalse(body.contains("if model.appliedNextLaunchVisible"))
    }

    func testModelActionHandlerDoesNotInspectRenderedTitle() throws {
        let body = try sourceSlice(
            from: "@objc private func unloadOrReloadModel",
            until: "func setModelUnloaded"
        )
        XCTAssertTrue(body.contains("switch modelMenuAction"))
        XCTAssertFalse(body.contains(".title"))
        XCTAssertFalse(body.contains("attributedTitle"))
        XCTAssertFalse(body.contains("contains("))
    }

    func testCaptionBehaviorDoesNotCompareRenderedSourceLabel() throws {
        let source = try String(contentsOf: sourceURL(named: "LiveCaptionView.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("enum CaptionLineRole"))
        XCTAssertFalse(source.contains("roleLabel == \"SOURCE\""))
        XCTAssertFalse(source.contains("role.label =="))
    }

    func testCaptionPositionResetUsesCentralFrameStore() throws {
        let managerSource = try String(
            contentsOf: sourceURL(named: "LiveCaptionManager.swift"),
            encoding: .utf8
        )
        let windowSource = try String(
            contentsOf: sourceURL(named: "LiveCaptionWindow.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(managerSource.contains("LiveCaptionPanelFrameStore.clear()"))
        XCTAssertFalse(managerSource.contains("hushtype.liveCaption.panelFrame"))
        XCTAssertTrue(windowSource.contains(
            "static let frameKey = \"hushtype.liveCaption.panelFrame.v3\""
        ))
    }

    private func sourceSlice(
        from startMarker: String,
        until endMarker: String,
        in file: String = "StatusBarController.swift"
    ) throws -> String {
        let source = try String(contentsOf: sourceURL(named: file), encoding: .utf8)
        guard let start = source.range(of: startMarker)?.lowerBound,
              let end = source.range(of: endMarker, range: start..<source.endIndex)?.lowerBound else {
            XCTFail("Could not locate source slice markers")
            return ""
        }
        return String(source[start..<end])
    }

    private func sourceURL(named name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/HushType")
            .appendingPathComponent(name)
    }
}
