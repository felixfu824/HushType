import Foundation
import XCTest
@testable import HushType

final class DictionaryReplacerTests: XCTestCase {

    private var temporaryDirectoryURL: URL!
    private var dictionaryURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()

        temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Lamitype-DictionaryReplacerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectoryURL,
            withIntermediateDirectories: true
        )
        dictionaryURL = temporaryDirectoryURL.appendingPathComponent("dictionary.txt")
        DictionaryReplacer.setDictionaryFileURLForTesting(dictionaryURL)
    }

    override func tearDownWithError() throws {
        DictionaryReplacer.setDictionaryFileURLForTesting(nil)
        if let temporaryDirectoryURL {
            try? FileManager.default.removeItem(at: temporaryDirectoryURL)
        }
        try super.tearDownWithError()
    }

    func testSourceMatchingIsCaseInsensitiveAndTargetIsLiteral() throws {
        try writeDictionary("cloud code -> Claude Code\n")

        XCTAssertEqual(
            DictionaryReplacer.apply("CLOUD CODE, Cloud Code, cloud code"),
            "Claude Code, Claude Code, Claude Code"
        )
    }

    func testLongestMatchWinsWhenSourcesOverlap() throws {
        try writeDictionary(
            """
            cloud -> Nimbus
            cloud code -> Claude Code
            """
        )

        XCTAssertEqual(
            DictionaryReplacer.apply("cloud code uses cloud"),
            "Claude Code uses Nimbus"
        )
    }

    func testReplacementTargetsDoNotCascade() throws {
        try writeDictionary(
            """
            A -> B
            B -> C
            """
        )

        XCTAssertEqual(DictionaryReplacer.apply("A B"), "B C")
    }

    func testReloadsAfterFileContentAndModificationDateChange() throws {
        let initialModificationDate = Date(timeIntervalSince1970: 1_700_000_000)
        try writeDictionary("draft -> first\n", modificationDate: initialModificationDate)
        XCTAssertEqual(DictionaryReplacer.apply("draft"), "first")

        try writeDictionary(
            "draft -> revised\n",
            modificationDate: initialModificationDate.addingTimeInterval(5)
        )
        XCTAssertEqual(DictionaryReplacer.apply("draft"), "revised")
    }

    private func writeDictionary(
        _ contents: String,
        modificationDate: Date? = nil
    ) throws {
        try contents.write(to: dictionaryURL, atomically: true, encoding: .utf8)
        if let modificationDate {
            try FileManager.default.setAttributes(
                [.modificationDate: modificationDate],
                ofItemAtPath: dictionaryURL.path
            )
        }
    }
}
