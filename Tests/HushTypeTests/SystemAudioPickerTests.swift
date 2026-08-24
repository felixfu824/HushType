import XCTest
@testable import HushType

final class SystemAudioPickerTests: XCTestCase {
    func testCommonAppsArePresentOnlyAndUseProductPriority() {
        let groups = SystemAudioPickerCatalog.groups(from: [
            .init(bundleID: "us.zoom.xos", name: "Zoom"),
            .init(bundleID: "com.example.notes", name: "Notes"),
            .init(bundleID: "com.google.Chrome", name: "Google Chrome"),
            .init(bundleID: "com.microsoft.edgemac", name: "Microsoft Edge"),
        ])

        XCTAssertEqual(groups.common.map(\.bundleID), [
            "com.microsoft.edgemac",
            "com.google.Chrome",
            "us.zoom.xos",
        ])
        XCTAssertEqual(groups.other.map(\.bundleID), ["com.example.notes"])
    }

    func testMissingCommonAppsDoNotCreatePlaceholders() {
        let groups = SystemAudioPickerCatalog.groups(from: [
            .init(bundleID: "com.google.Chrome", name: "Google Chrome"),
        ])

        XCTAssertEqual(groups.common.map(\.bundleID), ["com.google.Chrome"])
        XCTAssertTrue(groups.other.isEmpty)
    }

    func testNamesAreNormalizedAndWhitespaceOnlyRowsAreRejected() {
        let groups = SystemAudioPickerCatalog.groups(from: [
            .init(bundleID: "com.example.valid", name: "  Example\n  Audio\tApp  "),
            .init(bundleID: "com.example.empty", name: " \n\t "),
            .init(bundleID: " \t ", name: "Invalid Bundle"),
        ])

        XCTAssertEqual(groups.other, [
            .init(bundleID: "com.example.valid", name: "Example Audio App"),
        ])
    }

    func testDuplicateBundleIDChoosesSameConciseNameRegardlessOfInputOrder() {
        let candidates: [SystemAudioPickerCandidate] = [
            .init(bundleID: "com.example.calls", name: "Example Calls Helper"),
            .init(bundleID: "com.example.calls", name: "Example Calls"),
            .init(bundleID: "com.example.calls", name: " example   calls "),
        ]

        let forward = SystemAudioPickerCatalog.groups(from: candidates)
        let reversed = SystemAudioPickerCatalog.groups(from: Array(candidates.reversed()))

        XCTAssertEqual(forward, reversed)
        XCTAssertEqual(forward.other, [
            .init(bundleID: "com.example.calls", name: "Example Calls"),
        ])
    }

    func testOtherAppsSortAlphabeticallyWithDeterministicTieBreakers() {
        let groups = SystemAudioPickerCatalog.groups(from: [
            .init(bundleID: "com.example.zulu", name: "Zulu"),
            .init(bundleID: "com.example.alpha2", name: "alpha"),
            .init(bundleID: "com.example.beta", name: "Beta"),
            .init(bundleID: "com.example.alpha1", name: "Alpha"),
        ])

        XCTAssertEqual(groups.other.map(\.bundleID), [
            "com.example.alpha1",
            "com.example.alpha2",
            "com.example.beta",
            "com.example.zulu",
        ])
    }

    func testBundleIDMatchingRemainsExactAndCaseSensitive() {
        let groups = SystemAudioPickerCatalog.groups(from: [
            .init(bundleID: "com.google.Chrome", name: "Chrome"),
            .init(bundleID: "COM.GOOGLE.CHROME", name: "Chrome Canary"),
        ])

        XCTAssertEqual(groups.common.map(\.bundleID), ["com.google.Chrome"])
        XCTAssertEqual(groups.other.map(\.bundleID), ["COM.GOOGLE.CHROME"])
    }
}
