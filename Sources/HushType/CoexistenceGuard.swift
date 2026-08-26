import AppKit

enum CoexistenceGuard {
    struct RunningInstance: Equatable {
        let processIdentifier: pid_t
        let bundleURL: URL?
    }

    static func conflictingBundleURL(
        currentProcessIdentifier: pid_t,
        currentBundleURL: URL,
        candidates: [RunningInstance]
    ) -> URL? {
        let current = currentBundleURL.standardizedFileURL
        return candidates.lazy
            .filter { $0.processIdentifier != currentProcessIdentifier }
            .compactMap(\.bundleURL)
            .map(\.standardizedFileURL)
            .first { $0 != current }
    }

    @MainActor
    static func allowLaunch() -> Bool {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
            return true
        }
        let candidates = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .map {
                RunningInstance(
                    processIdentifier: $0.processIdentifier,
                    bundleURL: $0.bundleURL
                )
            }
        guard let conflict = conflictingBundleURL(
            currentProcessIdentifier: ProcessInfo.processInfo.processIdentifier,
            currentBundleURL: Bundle.main.bundleURL,
            candidates: candidates
        ) else {
            return true
        }

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Another copy of Lamitype is already running"
        alert.informativeText = """
        Lamitype and HushType cannot run together because they share the same settings and permissions.

        Quit the other copy, delete the old HushType.app from Applications, then launch Lamitype again.

        Other copy: \(conflict.path)
        """
        alert.addButton(withTitle: "Quit")
        alert.runModal()
        return false
    }
}
