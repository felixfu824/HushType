import Foundation
import XCTest
@testable import HushType

final class LiveCaptionTuningTests: XCTestCase {
    func testPanelSizeSetterCreatesCompleteTemplateWhenFileIsMissing() throws {
        let url = try temporaryTuningURL()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        LiveCaptionTuning.setPanelSize(w: 912.5, h: 244, at: url)

        let written = try jsonObject(at: url)
        let template = try templateObject()
        XCTAssertEqual(Set(written.keys), Set(template.keys))
        XCTAssertEqual((written["panelDefaultWidth"] as? NSNumber)?.doubleValue, 912.5)
        XCTAssertEqual((written["panelDefaultHeight"] as? NSNumber)?.doubleValue, 244)
        XCTAssertEqual(written["audioSource"] as? String, "mic")
        XCTAssertEqual(try commentValueBytes(in: written), try commentValueBytes(in: template))
    }

    func testResetSetterCreatesCompleteTemplateWhenFileIsMissing() throws {
        let url = try temporaryTuningURL()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        LiveCaptionTuning.setResetPanelOnNextStart(true, at: url)

        let written = try jsonObject(at: url)
        let template = try templateObject()
        XCTAssertEqual(Set(written.keys), Set(template.keys))
        XCTAssertEqual(written["resetPanelOnNextStart"] as? Bool, true)
        XCTAssertEqual((written["panelDefaultWidth"] as? NSNumber)?.doubleValue, 1350)
        XCTAssertEqual((written["panelDefaultHeight"] as? NSNumber)?.doubleValue, 160)
        XCTAssertEqual(try commentValueBytes(in: written), try commentValueBytes(in: template))
    }

    func testPanelAndResetMutationsPreserveEveryExistingCommentValueByteIdentically() throws {
        let url = try temporaryTuningURL()
        var seeded = try templateObject()
        let commentKeys = seeded.keys.filter { $0.hasPrefix("_comment_") }.sorted()
        XCTAssertFalse(commentKeys.isEmpty)

        for (index, key) in commentKeys.enumerated() {
            seeded[key] = "comment \(index): quote \" slash \\ line\n繁體中文 🐑"
        }
        let seedData = try JSONSerialization.data(withJSONObject: seeded, options: [.prettyPrinted, .sortedKeys])
        try seedData.write(to: url, options: .atomic)
        let before = try commentValueBytes(in: jsonObject(at: url))

        LiveCaptionTuning.setPanelSize(w: 1111, h: 222, at: url)
        let afterPanelSize = try jsonObject(at: url)
        XCTAssertEqual(try commentValueBytes(in: afterPanelSize), before)
        XCTAssertEqual((afterPanelSize["panelDefaultWidth"] as? NSNumber)?.doubleValue, 1111)
        XCTAssertEqual((afterPanelSize["panelDefaultHeight"] as? NSNumber)?.doubleValue, 222)

        LiveCaptionTuning.setResetPanelOnNextStart(true, at: url)
        let afterReset = try jsonObject(at: url)
        XCTAssertEqual(try commentValueBytes(in: afterReset), before)
        XCTAssertEqual(afterReset["resetPanelOnNextStart"] as? Bool, true)
    }

    private func temporaryTuningURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HushType-LiveCaptionTuningTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory.appendingPathComponent("live_caption.json")
    }

    private func templateObject() throws -> [String: Any] {
        let data = Data(LiveCaptionTuning.templateContent().utf8)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func jsonObject(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func commentValueBytes(in object: [String: Any]) throws -> [String: Data] {
        try Dictionary(uniqueKeysWithValues: object.compactMap { key, value in
            guard key.hasPrefix("_comment_") else { return nil }
            return (key, Data(try XCTUnwrap(value as? String).utf8))
        })
    }
}
