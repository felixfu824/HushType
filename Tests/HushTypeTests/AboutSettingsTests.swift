import AppKit
import XCTest
@testable import HushType

@MainActor
final class AboutSettingsTests: XCTestCase {
    override func setUp() {
        super.setUp()
        L10n.resetLaunchStateForTests()
    }

    override func tearDown() {
        L10n.resetLaunchStateForTests()
        super.tearDown()
    }

    func testCoauthorCreditsAreExact() {
        XCTAssertEqual(AboutPane.coauthors, [
            "Claude (Anthropic)",
            "Codex (OpenAI)",
            "Pi (Qwen 3.8 27B)",
        ])
    }

    func testAboutLabelsAreLocalizedInEnglish() {
        withInterfaceLanguage(.english) {
            XCTAssertEqual(L10n.string("settings.tab.about", fallback: "About"), "About")
            XCTAssertEqual(L10n.string("settings.about.author", fallback: "Author:"), "Author:")
            XCTAssertEqual(L10n.string("settings.about.coauthors", fallback: "Co-authors:"), "Co-authors:")
            XCTAssertEqual(L10n.string("settings.about.license", fallback: "License:"), "License:")
            XCTAssertEqual(L10n.string("settings.about.repository", fallback: "Repository:"), "Repository:")
            XCTAssertEqual(
                L10n.format(
                    "settings.about.version_build",
                    "Version %1$@ (Build %2$@)",
                    arguments: ["0.5.10", "28"]
                ),
                "Version 0.5.10 (Build 28)"
            )
        }
    }

    func testAboutLabelsAreLocalizedInTraditionalChinese() {
        withInterfaceLanguage(.traditionalChineseTaiwan) {
            XCTAssertEqual(L10n.string("settings.tab.about", fallback: "About"), "關於")
            XCTAssertEqual(L10n.string("settings.about.author", fallback: "Author:"), "作者：")
            XCTAssertEqual(L10n.string("settings.about.coauthors", fallback: "Co-authors:"), "共同創作者：")
            XCTAssertEqual(L10n.string("settings.about.license", fallback: "License:"), "授權：")
            XCTAssertEqual(L10n.string("settings.about.repository", fallback: "Repository:"), "程式碼儲存庫：")
            XCTAssertEqual(
                L10n.format(
                    "settings.about.version_build",
                    "Version %1$@ (Build %2$@)",
                    arguments: ["0.5.10", "28"]
                ),
                "版本 0.5.10（組建 28）"
            )
        }
    }

    func testUpdateConsentKeepsCancelAsTheDefaultFirstButton() {
        withInterfaceLanguage(.english) {
            let alert = UpdateCheckCoordinator.makeConsentAlert()
            XCTAssertEqual(alert.buttons.map(\.title), ["Cancel", "Check Now"])
        }
    }

    func testAboutIsLastPaneAndMenuDeepLinksToIt() throws {
        let settingsSource = try source(named: "Sources/HushType/Settings/SettingsWindowController.swift")
        let paneMarkers = [
            "GeneralPane.makeSettingsPane",
            "DictationPane.makeSettingsPane",
            "CaptionPane.makeSettingsPane",
            "TextPane.makeSettingsPane",
            "CloudPane.makeSettingsPane",
            "AboutPane.makeSettingsPane",
        ]
        let positions = try paneMarkers.map { marker -> String.Index in
            guard let position = settingsSource.range(of: marker)?.lowerBound else {
                throw TestError.missing(marker)
            }
            return position
        }
        XCTAssertEqual(positions, positions.sorted())

        let statusSource = try source(named: "Sources/HushType/StatusBarController.swift")
        XCTAssertTrue(statusSource.contains(
            "HushTypeSettingsWindowController.shared.presentAndFocus(pane: .about)"
        ))
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

    private func source(named path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private enum TestError: Error {
        case missing(String)
    }
}
