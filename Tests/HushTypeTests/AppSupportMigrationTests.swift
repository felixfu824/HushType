import Foundation
import XCTest
@testable import HushType

final class AppSupportMigrationTests: XCTestCase {
    private var sandboxes: [URL] = []

    override func tearDown() {
        for sandbox in sandboxes {
            try? FileManager.default.removeItem(at: sandbox)
        }
        sandboxes.removeAll()
        super.tearDown()
    }

    func testR0FreshInstallCreatesNewRootAndLegacyLink() throws {
        let paths = try makePaths()
        XCTAssertEqual(try selected(paths), paths.new.standardizedFileURL)
        XCTAssertTrue(isDirectory(paths.new))
        XCTAssertEqual(try linkDestination(paths.old), paths.new.path)
    }

    func testR0CreationFailureReturnsMigrationErrorWithoutCreatingEitherRoot() throws {
        let paths = try makePaths()
        let manager = FaultInjectingFileManager()
        manager.failDirectoryCreation = true

        let error = try failure(paths, manager: manager)
        XCTAssertEqual(error.category, .createDirectory)
        XCTAssertFalse(itemExists(paths.old))
        XCTAssertFalse(itemExists(paths.new))
    }

    func testR1MovesWholeDirectoryAndCreatesCompatibilityLink() throws {
        let paths = try makePaths()
        try createDirectory(paths.old)
        try write("dictionary", to: paths.old.appendingPathComponent("dictionary.txt"))
        try write("secret", to: paths.old.appendingPathComponent("openai.json"))

        XCTAssertEqual(try selected(paths), paths.new.standardizedFileURL)
        XCTAssertEqual(try read(paths.new.appendingPathComponent("dictionary.txt")), "dictionary")
        XCTAssertEqual(try read(paths.old.appendingPathComponent("openai.json")), "secret")
        XCTAssertEqual(try linkDestination(paths.old), paths.new.path)
    }

    func testMoveSuccessLinkFailureKeepsNewRootAndRetriesNextLaunch() throws {
        let paths = try makePaths()
        try createDirectory(paths.old)
        try write("kept", to: paths.old.appendingPathComponent("dictionary.txt"))
        let manager = FaultInjectingFileManager()
        manager.failSymlinkCreation = true

        XCTAssertEqual(try selected(paths, manager: manager), paths.new.standardizedFileURL)
        XCTAssertFalse(itemExists(paths.old))
        XCTAssertEqual(try read(paths.new.appendingPathComponent("dictionary.txt")), "kept")

        manager.failSymlinkCreation = false
        XCTAssertEqual(try selected(paths, manager: manager), paths.new.standardizedFileURL)
        XCTAssertEqual(try linkDestination(paths.old), paths.new.path)
    }

    func testR3ReconcilesConflictsRecursivelyAndReusesCollisionFreeBackups() throws {
        let paths = try makePaths()
        try createDirectory(paths.old)
        try createDirectory(paths.new)
        try write("same", to: paths.old.appendingPathComponent("same.txt"))
        try write("same", to: paths.new.appendingPathComponent("same.txt"))
        try write("old", to: paths.old.appendingPathComponent("conflict.txt"))
        try write("new", to: paths.new.appendingPathComponent("conflict.txt"))
        try write("occupied", to: paths.new.appendingPathComponent("conflict.txt.legacy-backup"))

        let oldNested = paths.old.appendingPathComponent("nested", isDirectory: true)
        let newNested = paths.new.appendingPathComponent("nested", isDirectory: true)
        try createDirectory(oldNested)
        try createDirectory(newNested)
        try write("old nested", to: oldNested.appendingPathComponent("value.txt"))
        try write("new nested", to: newNested.appendingPathComponent("value.txt"))
        try write("old only", to: oldNested.appendingPathComponent("only-old.txt"))

        XCTAssertEqual(try selected(paths), paths.new.standardizedFileURL)
        XCTAssertEqual(try read(paths.new.appendingPathComponent("conflict.txt")), "new")
        XCTAssertEqual(
            try read(paths.new.appendingPathComponent("conflict.txt.legacy-backup.2")),
            "old"
        )
        XCTAssertEqual(try read(newNested.appendingPathComponent("value.txt")), "new nested")
        XCTAssertEqual(
            try read(newNested.appendingPathComponent("value.txt.legacy-backup")),
            "old nested"
        )
        XCTAssertEqual(try read(newNested.appendingPathComponent("only-old.txt")), "old only")

        // Rerun is a steady-state no-op and does not create another backup.
        XCTAssertEqual(try selected(paths), paths.new.standardizedFileURL)
        XCTAssertFalse(itemExists(paths.new.appendingPathComponent("conflict.txt.legacy-backup.3")))
    }

    func testR3CopyFailureLeavesOldIntactThenRetryConverges() throws {
        let paths = try makePaths()
        try createDirectory(paths.old)
        try createDirectory(paths.new)
        try write("a", to: paths.old.appendingPathComponent("a.txt"))
        try write("b", to: paths.old.appendingPathComponent("b.txt"))
        let manager = FaultInjectingFileManager()
        manager.failCopyNumber = 2

        let error = try failure(paths, manager: manager)
        XCTAssertEqual(error.category, .reconcile)
        XCTAssertEqual(try read(paths.old.appendingPathComponent("a.txt")), "a")
        XCTAssertEqual(try read(paths.old.appendingPathComponent("b.txt")), "b")
        XCTAssertEqual(try read(paths.new.appendingPathComponent("a.txt")), "a")

        manager.failCopyNumber = nil
        manager.copyCount = 0
        XCTAssertEqual(try selected(paths, manager: manager), paths.new.standardizedFileURL)
        XCTAssertEqual(try read(paths.new.appendingPathComponent("a.txt")), "a")
        XCTAssertEqual(try read(paths.new.appendingPathComponent("b.txt")), "b")
        XCTAssertEqual(try linkDestination(paths.old), paths.new.path)
    }

    func testR2SteadyStateAndInterruptedMoveFallbackCreateOnlyMissingLink() throws {
        let paths = try makePaths()
        try createDirectory(paths.new)
        try write("already moved", to: paths.new.appendingPathComponent("dictionary.txt"))

        XCTAssertEqual(try selected(paths), paths.new.standardizedFileURL)
        XCTAssertEqual(try linkDestination(paths.old), paths.new.path)
        XCTAssertEqual(try read(paths.old.appendingPathComponent("dictionary.txt")), "already moved")

        XCTAssertEqual(try selected(paths), paths.new.standardizedFileURL)
        XCTAssertEqual(try linkDestination(paths.old), paths.new.path)
    }

    func testR4RecreatesOnlyTargetAndNeverDeletesLink() throws {
        let paths = try makePaths()
        try FileManager.default.createSymbolicLink(at: paths.old, withDestinationURL: paths.new)
        let beforeDestination = try linkDestination(paths.old)

        XCTAssertEqual(try selected(paths), paths.new.standardizedFileURL)
        XCTAssertTrue(isDirectory(paths.new))
        XCTAssertEqual(try linkDestination(paths.old), beforeDestination)
    }

    func testR4CreationFailureLeavesDanglingLinkUntouched() throws {
        let paths = try makePaths()
        try FileManager.default.createSymbolicLink(at: paths.old, withDestinationURL: paths.new)
        let manager = FaultInjectingFileManager()
        manager.failDirectoryCreation = true

        XCTAssertEqual(try failure(paths, manager: manager).category, .createDirectory)
        XCTAssertEqual(try linkDestination(paths.old), paths.new.path)
        XCTAssertFalse(itemExists(paths.new))
    }

    func testR5ForeignLiveLinkWinsWhenNewIsAbsentOrEmpty() throws {
        for createEmptyNew in [false, true] {
            let paths = try makePaths()
            let external = paths.parent.appendingPathComponent("External", isDirectory: true)
            try createDirectory(external)
            try write("external", to: external.appendingPathComponent("dictionary.txt"))
            try FileManager.default.createSymbolicLink(at: paths.old, withDestinationURL: external)
            if createEmptyNew {
                try createDirectory(paths.new)
                try write("finder", to: paths.new.appendingPathComponent(".DS_Store"))
            }

            XCTAssertEqual(try selected(paths), paths.old.standardizedFileURL)
            XCTAssertEqual(try linkDestination(paths.old), external.path)
            XCTAssertEqual(try read(external.appendingPathComponent("dictionary.txt")), "external")
        }
    }

    func testR5ForeignDanglingAndPopulatedNewAbortWithoutMutation() throws {
        do {
            let paths = try makePaths()
            let external = paths.parent.appendingPathComponent("Missing", isDirectory: true)
            try FileManager.default.createSymbolicLink(at: paths.old, withDestinationURL: external)
            XCTAssertEqual(try failure(paths).category, .unusableLegacyLink)
            XCTAssertEqual(try linkDestination(paths.old), external.path)
            XCTAssertFalse(itemExists(paths.new))
        }

        do {
            let paths = try makePaths()
            let external = paths.parent.appendingPathComponent("External", isDirectory: true)
            try createDirectory(external)
            try FileManager.default.createSymbolicLink(at: paths.old, withDestinationURL: external)
            try createDirectory(paths.new)
            try write("new", to: paths.new.appendingPathComponent("dictionary.txt"))
            XCTAssertEqual(try failure(paths).category, .divergentRoots)
            XCTAssertEqual(try linkDestination(paths.old), external.path)
            XCTAssertEqual(try read(paths.new.appendingPathComponent("dictionary.txt")), "new")
        }
    }

    func testR6RejectsNewSymlinkNewFileAndCyclicLegacyLink() throws {
        do {
            let paths = try makePaths()
            let target = paths.parent.appendingPathComponent("Elsewhere", isDirectory: true)
            try createDirectory(target)
            try FileManager.default.createSymbolicLink(at: paths.new, withDestinationURL: target)
            XCTAssertEqual(try failure(paths).category, .unsupportedState)
        }
        do {
            let paths = try makePaths()
            try write("not a directory", to: paths.new)
            XCTAssertEqual(try failure(paths).category, .unsupportedState)
        }
        do {
            let paths = try makePaths()
            let other = paths.parent.appendingPathComponent("Loop")
            try FileManager.default.createSymbolicLink(at: paths.old, withDestinationURL: other)
            try FileManager.default.createSymbolicLink(at: other, withDestinationURL: paths.old)
            XCTAssertEqual(try failure(paths).category, .unusableLegacyLink)
        }
    }

    func testForeignSymlinkSourceIsNeverMoved() throws {
        let paths = try makePaths()
        let external = paths.parent.appendingPathComponent("External", isDirectory: true)
        try createDirectory(external)
        try FileManager.default.createSymbolicLink(at: paths.old, withDestinationURL: external)
        let manager = FaultInjectingFileManager()

        XCTAssertEqual(try selected(paths, manager: manager), paths.old.standardizedFileURL)
        XCTAssertEqual(manager.moveCount, 0)
        XCTAssertEqual(try linkDestination(paths.old), external.path)
    }

    private typealias Paths = (parent: URL, old: URL, new: URL)

    private func makePaths() throws -> Paths {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamitype-migration-\(UUID().uuidString)", isDirectory: true)
        try createDirectory(parent)
        sandboxes.append(parent)
        return (
            parent,
            parent.appendingPathComponent("HushType", isDirectory: true),
            parent.appendingPathComponent("Lamitype", isDirectory: true)
        )
    }

    private func selected(
        _ paths: Paths,
        manager: any AppSupportFileManaging = FileManager.default
    ) throws -> URL {
        switch AppSupportMigrator.migrate(
            oldRoot: paths.old,
            newRoot: paths.new,
            fileManager: manager
        ) {
        case .success(let url): return url
        case .failure(let error): throw error
        }
    }

    private func failure(
        _ paths: Paths,
        manager: any AppSupportFileManaging = FileManager.default
    ) throws -> AppSupportMigrationError {
        switch AppSupportMigrator.migrate(
            oldRoot: paths.old,
            newRoot: paths.new,
            fileManager: manager
        ) {
        case .success(let url):
            XCTFail("Expected migration failure, selected \(url.path)")
            throw TestFailure.unexpectedSuccess
        case .failure(let error):
            return error
        }
    }

    private func createDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }

    private func write(_ value: String, to url: URL) throws {
        try value.write(to: url, atomically: true, encoding: .utf8)
    }

    private func read(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private func itemExists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    private func isDirectory(_ url: URL) -> Bool {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.type] as? FileAttributeType) == .typeDirectory
    }

    private func linkDestination(_ url: URL) throws -> String {
        try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
    }

    private enum TestFailure: Error {
        case unexpectedSuccess
    }
}

private final class FaultInjectingFileManager: AppSupportFileManaging {
    let base = FileManager.default
    var failDirectoryCreation = false
    var failSymlinkCreation = false
    var failCopyNumber: Int?
    var copyCount = 0
    var moveCount = 0

    func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
        try base.attributesOfItem(atPath: path)
    }

    func contentsOfDirectory(
        at url: URL,
        includingPropertiesForKeys keys: [URLResourceKey]?,
        options mask: FileManager.DirectoryEnumerationOptions
    ) throws -> [URL] {
        try base.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: keys,
            options: mask
        )
    }

    func destinationOfSymbolicLink(atPath path: String) throws -> String {
        try base.destinationOfSymbolicLink(atPath: path)
    }

    func createDirectory(
        at url: URL,
        withIntermediateDirectories createIntermediates: Bool,
        attributes: [FileAttributeKey: Any]?
    ) throws {
        if failDirectoryCreation { throw InjectedFailure.requested }
        try base.createDirectory(
            at: url,
            withIntermediateDirectories: createIntermediates,
            attributes: attributes
        )
    }

    func createSymbolicLink(at url: URL, withDestinationURL destinationURL: URL) throws {
        if failSymlinkCreation { throw InjectedFailure.requested }
        try base.createSymbolicLink(at: url, withDestinationURL: destinationURL)
    }

    func moveItem(at srcURL: URL, to dstURL: URL) throws {
        moveCount += 1
        try base.moveItem(at: srcURL, to: dstURL)
    }

    func copyItem(at srcURL: URL, to dstURL: URL) throws {
        copyCount += 1
        if copyCount == failCopyNumber { throw InjectedFailure.requested }
        try base.copyItem(at: srcURL, to: dstURL)
    }

    func removeItem(at url: URL) throws {
        try base.removeItem(at: url)
    }

    func contentsEqual(atPath path1: String, andPath path2: String) -> Bool {
        base.contentsEqual(atPath: path1, andPath: path2)
    }

    private enum InjectedFailure: Error {
        case requested
    }
}
