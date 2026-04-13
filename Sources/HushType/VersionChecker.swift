import Foundation
import os

private let log = Logger(subsystem: "com.felix.hushtype", category: "version-check")

/// User-initiated GitHub release check. Hits the public Releases API only when
/// the user has just clicked through an explicit consent dialog (see
/// `StatusBarController.checkForUpdates`). No automatic checks, no caching, no
/// background polling — every call is a fresh fetch driven by an explicit user
/// action.
///
/// The API endpoint is unauthenticated and returns minimal JSON. We parse only
/// `tag_name` and `html_url` — no Codable boilerplate needed for two fields.
enum VersionChecker {

    enum CheckError: Error, LocalizedError {
        case networkFailure(underlying: Error)
        case invalidResponse(status: Int)
        case malformedJSON
        case missingTagName

        var errorDescription: String? {
            switch self {
            case .networkFailure(let underlying):
                return underlying.localizedDescription
            case .invalidResponse(let status):
                return "GitHub returned HTTP \(status)"
            case .malformedJSON:
                return "Could not parse GitHub response"
            case .missingTagName:
                return "GitHub response missing tag_name"
            }
        }
    }

    struct Result {
        /// The currently running app version (e.g. "0.4.1").
        let currentVersion: String
        /// The latest version on GitHub, with the leading "v" stripped (e.g. "0.5.0").
        let latestVersion: String
        /// True when current >= latest.
        let isUpToDate: Bool
        /// Direct URL to the latest release page on GitHub.
        let releaseURL: URL?
    }

    private static let releasesAPI = URL(string: "https://api.github.com/repos/felixfu824/HushType/releases/latest")!

    /// Fetch the latest GitHub release and compare to the current bundle version.
    /// Throws on network or parsing errors. Caller is responsible for showing
    /// the consent dialog before calling this — `check()` itself does NOT ask
    /// for permission and unconditionally hits the network.
    static func check() async throws -> Result {
        log.info("Fetching latest release from GitHub")

        var request = URLRequest(url: releasesAPI)
        request.timeoutInterval = 10
        // GitHub recommends a User-Agent — without it some endpoints return 403
        request.setValue("HushType-VersionChecker", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            log.warning("Network failure: \(error.localizedDescription, privacy: .public)")
            throw CheckError.networkFailure(underlying: error)
        }

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            log.warning("GitHub returned HTTP \(http.statusCode)")
            throw CheckError.invalidResponse(status: http.statusCode)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CheckError.malformedJSON
        }

        guard let tagName = json["tag_name"] as? String else {
            throw CheckError.missingTagName
        }

        // Strip leading "v" if present (release tags are typically v0.4.1)
        let latestVersion = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName

        let currentVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0.0"

        let releaseURL = (json["html_url"] as? String).flatMap { URL(string: $0) }

        let isUpToDate = compareVersions(currentVersion, latestVersion) >= 0

        log.info("Version check: current=\(currentVersion, privacy: .public), latest=\(latestVersion, privacy: .public), upToDate=\(isUpToDate)")

        return Result(
            currentVersion: currentVersion,
            latestVersion: latestVersion,
            isUpToDate: isUpToDate,
            releaseURL: releaseURL
        )
    }

    // MARK: - Version comparison

    /// Compare two semver-ish version strings numerically.
    /// Returns -1 if a < b, 0 if equal, 1 if a > b.
    /// Pads shorter versions with zeros: "0.4" → "0.4.0".
    /// Non-numeric components compare as 0 (so "0.4.1-beta" → "0.4.1.0").
    static func compareVersions(_ a: String, _ b: String) -> Int {
        let aParts = a.split(separator: ".").map { Int($0.prefix(while: { $0.isNumber })) ?? 0 }
        let bParts = b.split(separator: ".").map { Int($0.prefix(while: { $0.isNumber })) ?? 0 }

        let maxLen = max(aParts.count, bParts.count)
        for i in 0..<maxLen {
            let av = i < aParts.count ? aParts[i] : 0
            let bv = i < bParts.count ? bParts[i] : 0
            if av < bv { return -1 }
            if av > bv { return 1 }
        }
        return 0
    }
}
