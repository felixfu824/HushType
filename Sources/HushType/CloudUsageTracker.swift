import Foundation
import os

private let log = Logger(subsystem: "com.felix.hushtype", category: "cloudUsage")

/// Tracks audio-second usage for the cloud Live Caption engine and projects it
/// to a cost figure for the in-panel ticker and daily cap.
///
/// Pricing (gpt-realtime-translate, 2026-05-14): **$0.034 / minute of audio**.
/// Counter formula: `seconds_sent / 60 * 0.034`. We count what we send (the
/// backend calls `recordChunk` per outbound `session.input_audio_buffer.append`),
/// not what OpenAI's dashboard bills — slightly conservative (over-counts
/// silence buffers OpenAI may discount), which is the safe direction for a
/// budget cap.
///
/// **Daily rollover (lazy, no daemon):** every `recordChunk` call checks whether
/// today's `yyyy-MM-dd` key still matches the cached `dayKey`. If midnight has
/// passed since the last chunk, the old total has already been persisted under
/// the prior day's key — the in-memory `dayTotalDollars` is just reset to zero
/// for the new day. No background timer required.
///
/// **Settings "Today's usage" read path** uses the same lazy-rollover read in
/// `todayCostDollars()` so a session-less peek after midnight is also correct.
actor CloudUsageTracker {

    /// Per-minute pricing. Tuning constant; if OpenAI publishes a different
    /// rate we patch here.
    static let dollarsPerMinute: Double = 0.034

    /// Singleton — the cost meter is global state (a chip in the panel header,
    /// a daily total in Settings). One tracker shared across sessions.
    static let shared = CloudUsageTracker()

    private var sessionSeconds: Double = 0
    private var cachedDayKey: String
    private var cachedDayTotalDollars: Double

    /// Daily cap notification fires at most once per calendar day. Reset on
    /// rollover.
    private var dailyCapWarnedToday: Bool = false

    /// Snapshot returned by mutating ops so the caller can update the ticker
    /// chip and check cap thresholds without a second hop into the actor.
    struct Snapshot: Sendable {
        let sessionSeconds: Double
        let sessionDollars: Double
        let dayDollars: Double
        let dayKey: String
    }

    private init() {
        let today = Self.dayKey(for: Date())
        self.cachedDayKey = today
        self.cachedDayTotalDollars = UserDefaults.standard.double(forKey: Self.defaultsKey(for: today))
    }

    /// Record an outbound audio chunk's duration. Returns the post-record
    /// snapshot so the caller can drive UI without an extra round-trip.
    @discardableResult
    func recordChunk(seconds: Double) -> Snapshot {
        rolloverIfNeeded()
        sessionSeconds += seconds
        let dollars = seconds / 60.0 * Self.dollarsPerMinute
        cachedDayTotalDollars += dollars
        // Persist the daily total to UserDefaults. UserDefaults is thread-safe
        // for primitive sets and the write coalesces — no fsync required per
        // chunk because the OS flushes opportunistically and on app exit.
        UserDefaults.standard.set(cachedDayTotalDollars, forKey: Self.defaultsKey(for: cachedDayKey))
        return Snapshot(
            sessionSeconds: sessionSeconds,
            sessionDollars: sessionSeconds / 60.0 * Self.dollarsPerMinute,
            dayDollars: cachedDayTotalDollars,
            dayKey: cachedDayKey
        )
    }

    /// Read-only snapshot. Lazy-rolls midnight too so a session-less peek
    /// (e.g. opening Settings after midnight) reflects the fresh day.
    func snapshot() -> Snapshot {
        rolloverIfNeeded()
        return Snapshot(
            sessionSeconds: sessionSeconds,
            sessionDollars: sessionSeconds / 60.0 * Self.dollarsPerMinute,
            dayDollars: cachedDayTotalDollars,
            dayKey: cachedDayKey
        )
    }

    /// Reset session totals for a new cloud session. Daily totals are
    /// untouched.
    func resetSession() {
        sessionSeconds = 0
    }

    /// Mark the daily-cap warning as fired so we don't fire it again before
    /// midnight rollover. Caller checks `shouldFireDailyCapWarning(cap:)`
    /// first.
    func markDailyCapWarned() {
        dailyCapWarnedToday = true
    }

    /// Check whether today's total has crossed the cap AND we haven't fired
    /// the one-time notification yet today.
    func shouldFireDailyCapWarning(cap: Double) -> Bool {
        rolloverIfNeeded()
        return !dailyCapWarnedToday && cachedDayTotalDollars >= cap
    }

    /// Reset today's daily counter to zero — wired to the [Reset counter]
    /// button in Settings.
    func resetDailyCounter() {
        cachedDayTotalDollars = 0
        UserDefaults.standard.set(0.0, forKey: Self.defaultsKey(for: cachedDayKey))
        dailyCapWarnedToday = false
        log.info("Reset daily cloud usage counter for \(self.cachedDayKey, privacy: .public)")
    }

    // MARK: - Private

    private func rolloverIfNeeded() {
        let today = Self.dayKey(for: Date())
        if today != cachedDayKey {
            log.info("Cloud usage day rollover: \(self.cachedDayKey, privacy: .public) → \(today, privacy: .public)")
            cachedDayKey = today
            // Load any pre-existing value for today (e.g. user opened the app
            // earlier today, closed it, reopened tonight) instead of
            // overwriting it with zero.
            cachedDayTotalDollars = UserDefaults.standard.double(forKey: Self.defaultsKey(for: today))
            dailyCapWarnedToday = false
        }
    }

    private static func dayKey(for date: Date) -> String {
        let fmt = DateFormatter()
        fmt.calendar = Calendar(identifier: .gregorian)
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = .current
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: date)
    }

    private static func defaultsKey(for dayKey: String) -> String {
        "hushtype.cloud.dailyUsage.\(dayKey)"
    }
}

extension CloudUsageTracker {
    /// Pretty-print the session timer as `MM:SS` (or `H:MM:SS` past an hour).
    static func formatSessionTime(seconds: Double) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        } else {
            return String(format: "%d:%02d", m, s)
        }
    }

    static func formatDollars(_ dollars: Double) -> String {
        String(format: "$%.2f", dollars)
    }
}
