import Foundation
import XCTest
@testable import HushType

final class CoexistenceGuardTests: XCTestCase {
    func testIgnoresCurrentProcessAndSameBundlePath() {
        let current = URL(fileURLWithPath: "/Applications/Lamitype.app")
        XCTAssertNil(CoexistenceGuard.conflictingBundleURL(
            currentProcessIdentifier: 10,
            currentBundleURL: current,
            candidates: [
                .init(processIdentifier: 10, bundleURL: URL(fileURLWithPath: "/tmp/other.app")),
                .init(processIdentifier: 11, bundleURL: current),
                .init(processIdentifier: 12, bundleURL: nil),
            ]
        ))
    }

    func testFindsSameBundleIdentifierAtDifferentPath() {
        let old = URL(fileURLWithPath: "/Applications/HushType.app")
        XCTAssertEqual(CoexistenceGuard.conflictingBundleURL(
            currentProcessIdentifier: 10,
            currentBundleURL: URL(fileURLWithPath: "/Applications/Lamitype.app"),
            candidates: [
                .init(processIdentifier: 11, bundleURL: old),
            ]
        ), old)
    }

    func testLaunchOrdersCoexistenceGuardBeforeMigrationAndConsumers() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: sourceRoot.appendingPathComponent("Sources/HushType/AppDelegate.swift"),
            encoding: .utf8
        )
        let guardPosition = try XCTUnwrap(source.range(of: "CoexistenceGuard.allowLaunch()"))
        let migrationPosition = try XCTUnwrap(source.range(of: "AppSupportMigrator.migrate("))
        let consumerPosition = try XCTUnwrap(source.range(of: "localEngine = Qwen3TranscriptionEngine()"))
        XCTAssertLessThan(guardPosition.lowerBound, migrationPosition.lowerBound)
        XCTAssertLessThan(migrationPosition.lowerBound, consumerPosition.lowerBound)
    }
}
