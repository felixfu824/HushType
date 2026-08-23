import XCTest
@testable import HushType

final class TextSettingsModelTests: XCTestCase {
    private final class StateBox {
        var polish = false
        var translation = false
        var target: String?
        var warmups = 0
        var releases = 0
        var alerts: [String] = []
        var refreshes = 0
    }

    func testPolishValidationPublishesValidatingThenEnablesAndWarmsUp() async {
        let box = StateBox()
        let model = makeModel(box: box, validation: .ok)
        var validatingStates: [Bool] = []
        model.onMenuRefresh = {
            box.refreshes += 1
            validatingStates.append(model.isValidatingPolish)
        }

        await model.setPolishEnabled(true)

        XCTAssertTrue(box.polish)
        XCTAssertTrue(model.polishEnabled)
        XCTAssertTrue(model.polishAvailable)
        XCTAssertEqual(box.warmups, 1)
        XCTAssertEqual(validatingStates, [true, false])
    }

    func testUnavailablePolishDoesNotEnableAndPresentsReason() async {
        let box = StateBox()
        let model = makeModel(
            box: box,
            validation: .unavailable(reason: "Apple Intelligence is off")
        )

        await model.setPolishEnabled(true)

        XCTAssertFalse(box.polish)
        XCTAssertFalse(model.polishEnabled)
        XCTAssertFalse(model.polishAvailable)
        XCTAssertEqual(box.warmups, 0)
        XCTAssertEqual(box.alerts, ["Apple Intelligence is off"])
    }

    func testDisablingPolishPersistsAndReleasesSession() async {
        let box = StateBox()
        box.polish = true
        let model = makeModel(box: box, validation: .ok)

        await model.setPolishEnabled(false)

        XCTAssertFalse(box.polish)
        XCTAssertFalse(model.polishEnabled)
        XCTAssertEqual(box.releases, 1)
        XCTAssertEqual(box.warmups, 0)
    }

    func testTranslationEnableAndTargetPersistAndRefreshMenu() {
        let box = StateBox()
        let model = makeModel(box: box, validation: .ok)
        model.onMenuRefresh = { box.refreshes += 1 }

        model.setTranslationEnabled(true)
        model.setTranslationTarget("ja")

        XCTAssertTrue(box.translation)
        XCTAssertTrue(model.translationEnabled)
        XCTAssertEqual(box.target, "ja")
        XCTAssertEqual(model.translationTarget, "ja")
        XCTAssertEqual(box.refreshes, 2)
    }

    func testPaneAndStatusBarHandlersUseSharedModelContract() throws {
        let pane = try source(named: "Settings/TextPane.swift")
        let statusBar = try source(named: "StatusBarController.swift")

        XCTAssertTrue(pane.contains("self.model = .shared"))
        XCTAssertTrue(pane.contains("model.requestPolishEnabled"))
        XCTAssertTrue(pane.contains("model.setTranslationEnabled"))
        XCTAssertTrue(pane.contains("model.setTranslationTarget"))
        XCTAssertFalse(pane.contains("AppConfig.shared.textPolishEnabled ="))
        XCTAssertFalse(pane.contains("AppConfig.shared.textTranslationEnabled ="))

        XCTAssertTrue(statusBar.contains("textSettingsModel.togglePolish()"))
        XCTAssertTrue(statusBar.contains("textSettingsModel.toggleTranslation()"))
        XCTAssertTrue(statusBar.contains("textSettingsModel.setTranslationTarget"))
        XCTAssertFalse(statusBar.contains("AppConfig.shared.textPolishEnabled ="))
        XCTAssertFalse(statusBar.contains("AppConfig.shared.textTranslationEnabled ="))
    }

    private func makeModel(
        box: StateBox,
        validation: TextPolisher.ValidationResult
    ) -> TextSettingsModel {
        TextSettingsModel(
            storage: .init(
                readPolishEnabled: { box.polish },
                writePolishEnabled: { box.polish = $0 },
                readTranslationEnabled: { box.translation },
                writeTranslationEnabled: { box.translation = $0 },
                readTranslationTarget: { box.target },
                writeTranslationTarget: { box.target = $0 }
            ),
            initialPolishAvailability: true,
            validatePolish: { validation },
            warmupPolish: { box.warmups += 1 },
            releasePolish: { box.releases += 1 },
            presentUnavailable: { box.alerts.append($0) },
            openInstructions: {}
        )
    }

    private func source(named relativePath: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/HushType")
            .appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
