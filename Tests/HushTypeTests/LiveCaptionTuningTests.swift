import Foundation
import AppKit
import XCTest
@testable import HushType

final class LiveCaptionTuningTests: XCTestCase {
    func testLegacyFileMissingNewKeysLoadsAndPreservesExistingValues() throws {
        let url = try temporaryTuningURL()
        let legacy: [String: Any] = [
            "_comment_about": "legacy comment",
            "maxTokens": 777,
            "vadOnset": 0.42,
            "forceSplitSeconds": 18.5,
        ]
        try JSONSerialization.data(
            withJSONObject: legacy,
            options: [.prettyPrinted]
        ).write(to: url, options: .atomic)

        let loaded = LiveCaptionTuning.load(at: url)

        XCTAssertEqual(loaded.maxTokens, 777)
        XCTAssertEqual(loaded.vadOnset, 0.42, accuracy: 0.0001)
        XCTAssertEqual(loaded.forceSplitSeconds, 18.5)
        XCTAssertEqual(loaded.audioSource, "mic")
        XCTAssertEqual(loaded.systemAudioBundleID, "")

        let migrated = try jsonObject(at: url)
        XCTAssertEqual(migrated["maxTokens"] as? Int, 777)
        XCTAssertEqual(migrated["_comment_about"] as? String, "legacy comment")
        XCTAssertEqual(migrated["audioSource"] as? String, "mic")
        XCTAssertEqual(migrated["systemAudioBundleID"] as? String, "")
    }

    func testTemplateOmitsObsoletePanelGeometryKnobs() throws {
        let url = try temporaryTuningURL()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        LiveCaptionTuning.createTemplateIfMissing(at: url)

        let written = try jsonObject(at: url)
        XCTAssertNil(written["panelDefaultWidth"])
        XCTAssertNil(written["panelDefaultHeight"])
        XCTAssertNil(written["resetPanelOnNextStart"])
        XCTAssertNil(written["_comment_panel"])
        XCTAssertNil(written["_comment_resetPanelOnNextStart"])
    }

    func testLegacyPanelGeometryKeysAreIgnoredWithoutDiscardingOtherValues() throws {
        let url = try temporaryTuningURL()
        let legacy: [String: Any] = [
            "panelDefaultWidth": 912.5,
            "panelDefaultHeight": 244,
            "resetPanelOnNextStart": true,
            "maxTokens": 777,
        ]
        try JSONSerialization.data(withJSONObject: legacy).write(to: url)

        let loaded = LiveCaptionTuning.load(at: url)
        XCTAssertEqual(loaded.maxTokens, 777)
        XCTAssertEqual(loaded.audioSource, "mic")
    }

    private func temporaryTuningURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Lamitype-LiveCaptionTuningTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory.appendingPathComponent("live_caption.json")
    }

    private func jsonObject(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

}

final class LiveCaptionPanelFrameStoreTests: XCTestCase {
    func testSavedFrameRoundTripsAndResetClearsAllFrameKeys() throws {
        let suiteName = "Lamitype-LiveCaptionFrameTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        let expected = NSRect(x: 120, y: 90, width: 900, height: 220)

        LiveCaptionPanelFrameStore.save(expected, defaults: defaults)
        defaults.set("legacy", forKey: LiveCaptionPanelFrameStore.legacyFrameKeys[0])

        XCTAssertEqual(LiveCaptionPanelFrameStore.load(defaults: defaults), expected)
        XCTAssertNil(defaults.object(forKey: LiveCaptionPanelFrameStore.legacyFrameKeys[0]))

        LiveCaptionPanelFrameStore.clear(defaults: defaults)
        XCTAssertNil(LiveCaptionPanelFrameStore.load(defaults: defaults))
    }

    func testRestoredFrameIsClampedToSizeLimitsAndFullyOnScreen() throws {
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let oversized = NSRect(x: -200, y: 850, width: 2400, height: 900)

        let normalized = try XCTUnwrap(LiveCaptionPanelFrameStore.normalizedFrame(
            oversized,
            visibleScreens: [screen],
            preferredScreen: screen
        ))

        XCTAssertEqual(normalized.width, 1400)
        XCTAssertEqual(normalized.height, 500)
        XCTAssertGreaterThanOrEqual(normalized.minX, screen.minX + 20)
        XCTAssertLessThanOrEqual(normalized.maxX, screen.maxX - 20)
        XCTAssertGreaterThanOrEqual(normalized.minY, screen.minY + 20)
        XCTAssertLessThanOrEqual(normalized.maxY, screen.maxY - 20)
    }

    func testFrameFromDisconnectedScreenUsesDefaultBottomCenterPlacement() throws {
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let disconnected = NSRect(x: 5000, y: 100, width: 1000, height: 200)

        let normalized = try XCTUnwrap(LiveCaptionPanelFrameStore.normalizedFrame(
            disconnected,
            visibleScreens: [screen],
            preferredScreen: screen
        ))

        XCTAssertEqual(normalized.size, disconnected.size)
        XCTAssertEqual(normalized.midX, screen.midX)
        XCTAssertEqual(normalized.minY, screen.minY + 80)
    }

    func testDefaultFrameShrinksForSmallScreen() throws {
        let smallScreen = NSRect(x: 100, y: 50, width: 800, height: 600)
        let normalized = try XCTUnwrap(LiveCaptionPanelFrameStore.normalizedFrame(
            nil,
            visibleScreens: [smallScreen],
            preferredScreen: smallScreen
        ))

        XCTAssertEqual(normalized.width, 760)
        XCTAssertEqual(normalized.height, 160)
        XCTAssertEqual(normalized.midX, smallScreen.midX)
        XCTAssertEqual(normalized.minY, smallScreen.minY + 80)
    }
}
