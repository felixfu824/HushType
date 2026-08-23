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

    func testCaptionPositionResetClearsCurrentV3FrameKey() throws {
        let source = try String(
            contentsOf: sourceURL(named: "LiveCaptionManager.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains(
            "removeObject(forKey: \"hushtype.liveCaption.panelFrame.v3\")"
        ))
        XCTAssertFalse(source.contains(
            "removeObject(forKey: \"hushtype.liveCaption.panelFrame\")"
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
