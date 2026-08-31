import Foundation
import os

private let appSupportLog = Logger(
    subsystem: "com.felix.hushtype",
    category: "app-support-migration"
)

/// The single, launch-frozen root for every user-editable Lamitype file.
/// Production must configure this exactly once before constructing consumers.
enum AppSupportPaths {
    private static let lock = NSLock()
    private static var configuredRoot: URL?

    static var rootURL: URL {
        lock.lock()
        defer { lock.unlock() }
        guard let configuredRoot else {
            preconditionFailure("AppSupportPaths read before launch preflight")
        }
        return configuredRoot
    }

    static func configure(root: URL) {
        let normalized = root.standardizedFileURL
        lock.lock()
        defer { lock.unlock() }
        if let configuredRoot {
            precondition(
                configuredRoot == normalized,
                "AppSupportPaths cannot be reconfigured to another root"
            )
            return
        }
        configuredRoot = normalized
    }

    static var dictionaryFileURL: URL {
        rootURL.appendingPathComponent("dictionary.txt")
    }

    static func promptOverrideURL(filename: String) -> URL {
        rootURL.appendingPathComponent(filename)
    }

    static var openAIKeyFileURL: URL {
        rootURL.appendingPathComponent("openai.json")
    }

    static var geminiKeyFileURL: URL {
        rootURL.appendingPathComponent("gemini.json")
    }

    static var liveCaptionTuningFileURL: URL {
        rootURL.appendingPathComponent("live_caption.json")
    }

    #if DEBUG
    static func resetForTesting() {
        lock.lock()
        configuredRoot = nil
        lock.unlock()
    }
    #endif
}

struct AppSupportMigrationError: Error, LocalizedError, Equatable {
    enum Category: String, Equatable {
        case inspect
        case createDirectory
        case move
        case reconcile
        case removeLegacy
        case unusableLegacyLink
        case divergentRoots
        case unsupportedState
    }

    let category: Category
    let detail: String

    var errorDescription: String? {
        "\(category.rawValue): \(detail)"
    }
}

/// Narrow filesystem surface so every migration state and failure can be
/// exercised without process restarts or touching a user's real data.
protocol AppSupportFileManaging {
    func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any]
    func contentsOfDirectory(
        at url: URL,
        includingPropertiesForKeys keys: [URLResourceKey]?,
        options mask: FileManager.DirectoryEnumerationOptions
    ) throws -> [URL]
    func destinationOfSymbolicLink(atPath path: String) throws -> String
    func createDirectory(
        at url: URL,
        withIntermediateDirectories createIntermediates: Bool,
        attributes: [FileAttributeKey: Any]?
    ) throws
    func createSymbolicLink(at url: URL, withDestinationURL destinationURL: URL) throws
    func moveItem(at srcURL: URL, to dstURL: URL) throws
    func copyItem(at srcURL: URL, to dstURL: URL) throws
    func removeItem(at url: URL) throws
    func contentsEqual(atPath path1: String, andPath path2: String) -> Bool
}

extension FileManager: AppSupportFileManaging {}

enum AppSupportMigrator {
    static func productionRoots(in applicationSupport: URL) -> (old: URL, new: URL) {
        (
            applicationSupport.appendingPathComponent("HushType", isDirectory: true),
            applicationSupport.appendingPathComponent("Lamitype", isDirectory: true)
        )
    }

    private enum LinkState {
        case oursLive
        case oursDangling
        case foreignLive
        case foreignUnusable
    }

    private enum SideState {
        case absent
        case realDirectory(empty: Bool)
        case symlink(LinkState)
        case other
    }

    static func migrate(
        oldRoot: URL,
        newRoot: URL,
        fileManager: any AppSupportFileManaging = FileManager.default
    ) -> Result<URL, AppSupportMigrationError> {
        let old = oldRoot.standardizedFileURL
        let new = newRoot.standardizedFileURL

        do {
            let oldState = try classify(old, newRoot: new, fileManager: fileManager)
            let newState = try classify(new, newRoot: new, fileManager: fileManager)

            switch (oldState, newState) {
            // R0: first install.
            case (.absent, .absent):
                do {
                    try fileManager.createDirectory(
                        at: new,
                        withIntermediateDirectories: true,
                        attributes: nil
                    )
                } catch {
                    return .failure(.init(
                        category: .createDirectory,
                        detail: "Could not create \(new.path): \(error.localizedDescription)"
                    ))
                }
                ensureLegacyLink(old: old, new: new, fileManager: fileManager)
                return .success(new)

            // R1: same-volume move is the smooth, metadata-preserving path.
            case (.realDirectory, .absent):
                do {
                    try fileManager.moveItem(at: old, to: new)
                } catch {
                    return .failure(.init(
                        category: .move,
                        detail: "Could not move \(old.path) to \(new.path): \(error.localizedDescription)"
                    ))
                }
                // From this point onward the selected root is permanently new.
                ensureLegacyLink(old: old, new: new, fileManager: fileManager)
                return .success(new)

            // R2: steady state and legacy-link retry arm.
            case (.absent, .realDirectory):
                ensureLegacyLink(old: old, new: new, fileManager: fileManager)
                return .success(new)
            case (.symlink(.oursLive), .realDirectory),
                 (.symlink(.oursDangling), .realDirectory):
                return .success(new)

            // R3: both real stores exist; merge additively into Lamitype.
            case (.realDirectory, .realDirectory):
                do {
                    try reconcileDirectory(from: old, into: new, fileManager: fileManager)
                    try fileManager.removeItem(at: old)
                } catch let error as AppSupportMigrationError {
                    return .failure(error)
                } catch {
                    return .failure(.init(
                        category: .removeLegacy,
                        detail: "Data was copied, but \(old.path) could not be removed: \(error.localizedDescription)"
                    ))
                }
                ensureLegacyLink(old: old, new: new, fileManager: fileManager)
                return .success(new)

            // R4: our dangling link remains in place; recreate only its target.
            case (.symlink(.oursDangling), .absent):
                do {
                    try fileManager.createDirectory(
                        at: new,
                        withIntermediateDirectories: true,
                        attributes: nil
                    )
                } catch {
                    return .failure(.init(
                        category: .createDirectory,
                        detail: "Could not recreate \(new.path): \(error.localizedDescription)"
                    ))
                }
                return .success(new)

            // R5: a deliberate external-storage link is authoritative only
            // while it is usable and the Lamitype side has no user data.
            case (.symlink(.foreignLive), .absent),
                 (.symlink(.foreignLive), .realDirectory(empty: true)):
                return .success(old)
            case (.symlink(.foreignUnusable), _):
                return .failure(.init(
                    category: .unusableLegacyLink,
                    detail: "\(old.path) is a foreign symlink whose target is unavailable"
                ))
            case (.symlink(.foreignLive), .realDirectory(empty: false)):
                return .failure(.init(
                    category: .divergentRoots,
                    detail: "Both the external legacy link and \(new.path) contain data"
                ))

            // R6: all ambiguous or unsafe states fail without mutation.
            default:
                return .failure(.init(
                    category: .unsupportedState,
                    detail: "Unsupported filesystem state at \(old.path) and \(new.path)"
                ))
            }
        } catch {
            return .failure(.init(
                category: .inspect,
                detail: "Could not inspect migration paths: \(error.localizedDescription)"
            ))
        }
    }

    private static func classify(
        _ url: URL,
        newRoot: URL,
        fileManager: any AppSupportFileManaging
    ) throws -> SideState {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try fileManager.attributesOfItem(atPath: url.path)
        } catch {
            if isNoSuchFile(error) { return .absent }
            throw error
        }

        guard let type = attributes[.type] as? FileAttributeType else {
            return .other
        }
        switch type {
        case .typeDirectory:
            let entries = try fileManager.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: nil,
                options: []
            )
                .filter { $0.lastPathComponent != ".DS_Store" }
            return .realDirectory(empty: entries.isEmpty)
        case .typeSymbolicLink:
            return .symlink(try classifyLink(
                at: url,
                newRoot: newRoot,
                fileManager: fileManager
            ))
        default:
            return .other
        }
    }

    private static func classifyLink(
        at link: URL,
        newRoot: URL,
        fileManager: any AppSupportFileManaging
    ) throws -> LinkState {
        let directDestination = try normalizedLinkDestination(
            at: link,
            fileManager: fileManager
        )
        if directDestination == newRoot.standardizedFileURL {
            do {
                let attributes = try fileManager.attributesOfItem(atPath: newRoot.path)
                return (attributes[.type] as? FileAttributeType) == .typeDirectory
                    ? .oursLive
                    : .oursDangling
            } catch {
                if isNoSuchFile(error) { return .oursDangling }
                throw error
            }
        }

        var current = link.standardizedFileURL
        var visited: Set<String> = []
        while true {
            guard visited.insert(current.path).inserted else {
                return .foreignUnusable
            }
            let target: URL
            do {
                target = try normalizedLinkDestination(at: current, fileManager: fileManager)
            } catch {
                return .foreignUnusable
            }
            let attributes: [FileAttributeKey: Any]
            do {
                attributes = try fileManager.attributesOfItem(atPath: target.path)
            } catch {
                if isNoSuchFile(error) { return .foreignUnusable }
                return .foreignUnusable
            }
            guard let type = attributes[.type] as? FileAttributeType else {
                return .foreignUnusable
            }
            if type == .typeDirectory { return .foreignLive }
            if type != .typeSymbolicLink { return .foreignUnusable }
            current = target
        }
    }

    private static func normalizedLinkDestination(
        at link: URL,
        fileManager: any AppSupportFileManaging
    ) throws -> URL {
        let raw = try fileManager.destinationOfSymbolicLink(atPath: link.path)
        let destination: URL
        if raw.hasPrefix("/") {
            destination = URL(fileURLWithPath: raw, isDirectory: true)
        } else {
            destination = link.deletingLastPathComponent()
                .appendingPathComponent(raw, isDirectory: true)
        }
        return destination.standardizedFileURL
    }

    private static func ensureLegacyLink(
        old: URL,
        new: URL,
        fileManager: any AppSupportFileManaging
    ) {
        do {
            _ = try fileManager.attributesOfItem(atPath: old.path)
            return
        } catch {
            if isNoSuchFile(error) {
                do {
                    try fileManager.createSymbolicLink(at: old, withDestinationURL: new)
                } catch {
                    appSupportLog.warning(
                        "Legacy-link ensure failed; will retry next launch: \(error.localizedDescription, privacy: .public)"
                    )
                }
                return
            }
            appSupportLog.warning(
                "Legacy-link inspection failed; leaving it untouched: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private static func reconcileDirectory(
        from oldDirectory: URL,
        into newDirectory: URL,
        fileManager: any AppSupportFileManaging
    ) throws {
        let oldItems = try fileManager.contentsOfDirectory(
            at: oldDirectory,
            includingPropertiesForKeys: nil,
            options: []
        )
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        for oldItem in oldItems {
            let newItem = newDirectory.appendingPathComponent(oldItem.lastPathComponent)
            let newAttributes: [FileAttributeKey: Any]?
            do {
                newAttributes = try fileManager.attributesOfItem(atPath: newItem.path)
            } catch {
                if isNoSuchFile(error) {
                    newAttributes = nil
                } else {
                    throw error
                }
            }

            guard let newAttributes else {
                do {
                    try fileManager.copyItem(at: oldItem, to: newItem)
                } catch {
                    throw AppSupportMigrationError(
                        category: .reconcile,
                        detail: "Could not copy \(oldItem.path): \(error.localizedDescription)"
                    )
                }
                continue
            }

            let oldAttributes = try fileManager.attributesOfItem(atPath: oldItem.path)
            let oldType = oldAttributes[.type] as? FileAttributeType
            let newType = newAttributes[.type] as? FileAttributeType

            if oldType == .typeDirectory, newType == .typeDirectory {
                try reconcileDirectory(from: oldItem, into: newItem, fileManager: fileManager)
                continue
            }
            if try itemsAreEquivalent(oldItem, newItem, fileManager: fileManager) {
                continue
            }

            let backup = try collisionFreeBackupURL(
                for: oldItem,
                in: newDirectory,
                fileManager: fileManager
            )
            if backup.reusedEquivalent { continue }
            do {
                try fileManager.copyItem(at: oldItem, to: backup.url)
            } catch {
                throw AppSupportMigrationError(
                    category: .reconcile,
                    detail: "Could not preserve conflict \(oldItem.path): \(error.localizedDescription)"
                )
            }
        }
    }

    private static func collisionFreeBackupURL(
        for oldItem: URL,
        in newDirectory: URL,
        fileManager: any AppSupportFileManaging
    ) throws -> (url: URL, reusedEquivalent: Bool) {
        var index = 1
        while true {
            let suffix = index == 1 ? ".legacy-backup" : ".legacy-backup.\(index)"
            let candidate = newDirectory.appendingPathComponent(oldItem.lastPathComponent + suffix)
            do {
                _ = try fileManager.attributesOfItem(atPath: candidate.path)
                if try itemsAreEquivalent(oldItem, candidate, fileManager: fileManager) {
                    return (candidate, true)
                }
                index += 1
            } catch {
                if isNoSuchFile(error) { return (candidate, false) }
                throw error
            }
        }
    }

    private static func isNoSuchFile(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            // NSFileNoSuchFileError and NSFileReadNoSuchFileError.
            return nsError.code == 4 || nsError.code == 260
        }
        if nsError.domain == NSPOSIXErrorDomain {
            return nsError.code == Int(ENOENT)
        }
        return false
    }

    private static func itemsAreEquivalent(
        _ lhs: URL,
        _ rhs: URL,
        fileManager: any AppSupportFileManaging
    ) throws -> Bool {
        let lhsType = try fileManager.attributesOfItem(atPath: lhs.path)[.type] as? FileAttributeType
        let rhsType = try fileManager.attributesOfItem(atPath: rhs.path)[.type] as? FileAttributeType
        guard lhsType == rhsType else { return false }

        switch lhsType {
        case .typeDirectory:
            let lhsItems = try fileManager.contentsOfDirectory(
                at: lhs,
                includingPropertiesForKeys: nil,
                options: []
            )
            let rhsItems = try fileManager.contentsOfDirectory(
                at: rhs,
                includingPropertiesForKeys: nil,
                options: []
            )
            let lhsNames = Set(lhsItems.map(\.lastPathComponent))
            let rhsNames = Set(rhsItems.map(\.lastPathComponent))
            guard lhsNames == rhsNames else { return false }
            for name in lhsNames {
                guard try itemsAreEquivalent(
                    lhs.appendingPathComponent(name),
                    rhs.appendingPathComponent(name),
                    fileManager: fileManager
                ) else { return false }
            }
            return true
        case .typeSymbolicLink:
            return try fileManager.destinationOfSymbolicLink(atPath: lhs.path)
                == fileManager.destinationOfSymbolicLink(atPath: rhs.path)
        case .typeRegular:
            return fileManager.contentsEqual(atPath: lhs.path, andPath: rhs.path)
        default:
            return false
        }
    }
}
