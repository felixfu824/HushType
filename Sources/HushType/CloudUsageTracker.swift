import Foundation
import os

private let log = Logger(subsystem: "com.felix.hushtype", category: "cloudUsage")

/// One daily cloud budget shared by dictation and Live Translated Caption.
/// Dollars and audio seconds are persisted per feature/provider bucket so the
/// settings panes can explain the aggregate without splitting the user's cap.
actor CloudUsageTracker {
    enum Feature: String, CaseIterable, Sendable {
        case dictation
        case liveCaption
    }

    enum Provider: String, CaseIterable, Sendable {
        case openai
        case gemini
    }

    enum Rate {
        static let liveTranslatedCaption = 0.034
        static let openAIGPTTranscribe = 0.006
        static let openAIMiniTranscribe = 0.004
        static let geminiFlash = 0.002
        static let geminiFlashLite = 0.001
    }

    static let shared = CloudUsageTracker()

    private struct Usage: Sendable {
        var seconds: Double = 0
        var dollars: Double = 0
    }

    struct Snapshot: Sendable {
        /// Current Live Translated Caption session (kept for its ticker and
        /// auto-stop logic). Dictation never contributes to session fields.
        let sessionSeconds: Double
        let sessionDollars: Double
        /// Aggregate for all features/providers today.
        let dayDollars: Double
        let dayKey: String
        let dictationSeconds: Double
        let dictationDollars: Double
        let translatedCaptionSeconds: Double
        let translatedCaptionDollars: Double
    }

    /// Conservative pre-upload decision for one cloud dictation. The projected
    /// cost uses the same duration/rate math as persisted usage, and the total
    /// aggregates dictation plus Live Translated Caption across providers.
    struct DictationUploadProjection: Equatable, Sendable {
        let currentDollars: Double
        let projectedDollars: Double
        let projectedTotalDollars: Double
        let warningThreshold: Double
        let shouldBlock: Bool
    }

    private var sessionSeconds: Double = 0
    private var sessionDollars: Double = 0
    private var cachedDayKey: String
    private var buckets: [String: Usage] = [:]
    private var dailyCapWarnedToday: Bool

    private init() {
        let today = Self.dayKey(for: Date())
        cachedDayKey = today
        Self.migrateLegacyUsageIfNeeded(dayKey: today)
        buckets = Self.loadBuckets(dayKey: today)
        dailyCapWarnedToday = UserDefaults.standard.bool(
            forKey: Self.capWarnedKey(for: today)
        )
    }

    /// Back-compatible entry point for the existing realtime translation
    /// backend. Its rate is supplied per call rather than being global state.
    @discardableResult
    func recordChunk(seconds: Double) -> Snapshot {
        record(
            seconds: seconds,
            feature: .liveCaption,
            provider: .openai,
            dollarsPerMinute: Rate.liveTranslatedCaption,
            contributesToCaptionSession: true
        )
    }

    /// Record one completed cloud dictation at the selected model's rate.
    @discardableResult
    func recordDictation(
        seconds: Double,
        provider: Provider,
        dollarsPerMinute: Double
    ) -> Snapshot {
        record(
            seconds: seconds,
            feature: .dictation,
            provider: provider,
            dollarsPerMinute: dollarsPerMinute,
            contributesToCaptionSession: false
        )
    }

    func snapshot() -> Snapshot {
        rolloverIfNeeded()
        return makeSnapshot()
    }

    /// Evaluate immediately before constructing/uploading a cloud request.
    /// Equality blocks: the utterance that would first reach or cross the
    /// user's Daily spend warning is kept local and never uploaded.
    func evaluateDictationUpload(
        seconds: Double,
        dollarsPerMinute: Double,
        warningThreshold: Double
    ) -> DictationUploadProjection {
        rolloverIfNeeded()
        let projection = Self.makeDictationUploadProjection(
            currentDollars: totalDollars(),
            seconds: seconds,
            dollarsPerMinute: dollarsPerMinute,
            warningThreshold: warningThreshold,
            warningAlreadyReached: dailyCapWarnedToday
        )
        if projection.shouldBlock && !dailyCapWarnedToday {
            // Reaching the warning latches cloud dictation off for the rest of
            // the day. Changing the threshold does not silently bypass the
            // user's stop; only Reset counter clears this persisted latch.
            dailyCapWarnedToday = true
            UserDefaults.standard.set(true, forKey: Self.capWarnedKey(for: cachedDayKey))
        }
        return projection
    }

    func resetSession() {
        sessionSeconds = 0
        sessionDollars = 0
    }

    func markDailyCapWarned() {
        rolloverIfNeeded()
        dailyCapWarnedToday = true
        UserDefaults.standard.set(true, forKey: Self.capWarnedKey(for: cachedDayKey))
    }

    func shouldFireDailyCapWarning(cap: Double) -> Bool {
        rolloverIfNeeded()
        guard !dailyCapWarnedToday, totalDollars() >= cap else { return false }
        // Claim atomically inside the actor. Existing callers still invoke
        // markDailyCapWarned() after a true result; that idempotent write is
        // retained for API compatibility with LiveCaptionManager.
        dailyCapWarnedToday = true
        UserDefaults.standard.set(true, forKey: Self.capWarnedKey(for: cachedDayKey))
        return true
    }

    /// Reset every feature/provider bucket for today. This intentionally
    /// includes the legacy key so it cannot be migrated back on next launch.
    func resetDailyCounter() {
        rolloverIfNeeded()
        let defaults = UserDefaults.standard
        for feature in Feature.allCases {
            for provider in Provider.allCases {
                defaults.set(0.0, forKey: Self.dollarsKey(
                    feature: feature,
                    provider: provider,
                    dayKey: cachedDayKey
                ))
                defaults.set(0.0, forKey: Self.secondsKey(
                    feature: feature,
                    provider: provider,
                    dayKey: cachedDayKey
                ))
            }
        }
        defaults.set(0.0, forKey: Self.legacyDollarsKey(for: cachedDayKey))
        defaults.set(true, forKey: Self.migrationKey(for: cachedDayKey))
        defaults.set(false, forKey: Self.capWarnedKey(for: cachedDayKey))
        buckets = Self.loadBuckets(dayKey: cachedDayKey)
        dailyCapWarnedToday = false
        log.info("Reset daily cloud usage family for \(self.cachedDayKey, privacy: .public)")
    }

    static func dictationRate(provider: Provider, model: String) -> Double {
        switch (provider, model) {
        case (.openai, "gpt-transcribe"):
            return Rate.openAIGPTTranscribe
        case (.openai, "gpt-4o-mini-transcribe"):
            return Rate.openAIMiniTranscribe
        case (.openai, _):
            return Rate.openAIGPTTranscribe
        case (.gemini, "gemini-3.5-flash-lite"):
            return Rate.geminiFlashLite
        case (.gemini, _):
            return Rate.geminiFlash
        }
    }

    /// Pure policy seam used by unit tests. Invalid/negative usage inputs are
    /// clamped to zero; an invalid threshold fails closed at zero.
    static func makeDictationUploadProjection(
        currentDollars: Double,
        seconds: Double,
        dollarsPerMinute: Double,
        warningThreshold: Double,
        warningAlreadyReached: Bool = false
    ) -> DictationUploadProjection {
        let current = sanitizedNonnegative(currentDollars)
        let safeSeconds = sanitizedNonnegative(seconds)
        let safeRate = sanitizedNonnegative(dollarsPerMinute)
        let threshold = warningThreshold.isFinite
            ? max(0, warningThreshold)
            : 0
        let projected = safeSeconds / 60.0 * safeRate
        let total = current + projected
        return DictationUploadProjection(
            currentDollars: current,
            projectedDollars: projected,
            projectedTotalDollars: total,
            warningThreshold: threshold,
            shouldBlock: warningAlreadyReached || total >= threshold
        )
    }

    // MARK: - Private

    private static func sanitizedNonnegative(_ value: Double) -> Double {
        value.isFinite ? max(0, value) : 0
    }

    private func record(
        seconds: Double,
        feature: Feature,
        provider: Provider,
        dollarsPerMinute: Double,
        contributesToCaptionSession: Bool
    ) -> Snapshot {
        rolloverIfNeeded()
        let safeSeconds = max(0, seconds)
        let dollars = safeSeconds / 60.0 * max(0, dollarsPerMinute)
        let bucketID = Self.bucketID(feature: feature, provider: provider)
        var usage = buckets[bucketID] ?? Usage()
        usage.seconds += safeSeconds
        usage.dollars += dollars
        buckets[bucketID] = usage

        let defaults = UserDefaults.standard
        defaults.set(usage.dollars, forKey: Self.dollarsKey(
            feature: feature,
            provider: provider,
            dayKey: cachedDayKey
        ))
        defaults.set(usage.seconds, forKey: Self.secondsKey(
            feature: feature,
            provider: provider,
            dayKey: cachedDayKey
        ))

        if contributesToCaptionSession {
            sessionSeconds += safeSeconds
            sessionDollars += dollars
        }
        return makeSnapshot()
    }

    private func makeSnapshot() -> Snapshot {
        let dictation = usage(for: .dictation)
        let caption = usage(for: .liveCaption)
        return Snapshot(
            sessionSeconds: sessionSeconds,
            sessionDollars: sessionDollars,
            dayDollars: dictation.dollars + caption.dollars,
            dayKey: cachedDayKey,
            dictationSeconds: dictation.seconds,
            dictationDollars: dictation.dollars,
            translatedCaptionSeconds: caption.seconds,
            translatedCaptionDollars: caption.dollars
        )
    }

    private func usage(for feature: Feature) -> Usage {
        Provider.allCases.reduce(into: Usage()) { total, provider in
            let usage = buckets[Self.bucketID(feature: feature, provider: provider)] ?? Usage()
            total.seconds += usage.seconds
            total.dollars += usage.dollars
        }
    }

    private func totalDollars() -> Double {
        buckets.values.reduce(0) { $0 + $1.dollars }
    }

    private func rolloverIfNeeded() {
        let today = Self.dayKey(for: Date())
        guard today != cachedDayKey else { return }
        log.info("Cloud usage day rollover: \(self.cachedDayKey, privacy: .public) → \(today, privacy: .public)")
        cachedDayKey = today
        Self.migrateLegacyUsageIfNeeded(dayKey: today)
        buckets = Self.loadBuckets(dayKey: today)
        dailyCapWarnedToday = UserDefaults.standard.bool(
            forKey: Self.capWarnedKey(for: today)
        )
    }

    private static func loadBuckets(dayKey: String) -> [String: Usage] {
        let defaults = UserDefaults.standard
        var result: [String: Usage] = [:]
        for feature in Feature.allCases {
            for provider in Provider.allCases {
                result[bucketID(feature: feature, provider: provider)] = Usage(
                    seconds: defaults.double(forKey: secondsKey(
                        feature: feature,
                        provider: provider,
                        dayKey: dayKey
                    )),
                    dollars: defaults.double(forKey: dollarsKey(
                        feature: feature,
                        provider: provider,
                        dayKey: dayKey
                    ))
                )
            }
        }
        return result
    }

    /// The old tracker stored one daily Live Translated Caption total at
    /// `hushtype.cloud.dailyUsage.<day>`. Move it once into the new
    /// liveCaption/openai bucket so an upgrade does not erase today's spend.
    private static func migrateLegacyUsageIfNeeded(dayKey: String) {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: migrationKey(for: dayKey)) else { return }
        let legacyKey = legacyDollarsKey(for: dayKey)
        let legacyDollars = defaults.double(forKey: legacyKey)
        let destination = dollarsKey(
            feature: .liveCaption,
            provider: .openai,
            dayKey: dayKey
        )
        if legacyDollars > 0, defaults.object(forKey: destination) == nil {
            defaults.set(legacyDollars, forKey: destination)
            // The legacy bucket used one fixed $0.034/min rate, so recover
            // its duration exactly enough for the new feature breakdown.
            // Without this, upgraded users would see non-zero caption spend
            // paired with a misleading "(0 min)" label.
            let legacySeconds = legacyDollars / Rate.liveTranslatedCaption * 60.0
            defaults.set(
                legacySeconds,
                forKey: secondsKey(
                    feature: .liveCaption,
                    provider: .openai,
                    dayKey: dayKey
                )
            )
        }
        defaults.set(true, forKey: migrationKey(for: dayKey))
    }

    private static func bucketID(feature: Feature, provider: Provider) -> String {
        "\(feature.rawValue).\(provider.rawValue)"
    }

    private static func dollarsKey(feature: Feature, provider: Provider, dayKey: String) -> String {
        "hushtype.cloud.dailyUsage.\(feature.rawValue).\(provider.rawValue).\(dayKey)"
    }

    private static func secondsKey(feature: Feature, provider: Provider, dayKey: String) -> String {
        "hushtype.cloud.dailyUsage.seconds.\(feature.rawValue).\(provider.rawValue).\(dayKey)"
    }

    private static func legacyDollarsKey(for dayKey: String) -> String {
        "hushtype.cloud.dailyUsage.\(dayKey)"
    }

    private static func migrationKey(for dayKey: String) -> String {
        "hushtype.cloud.dailyUsage.migrated.\(dayKey)"
    }

    private static func capWarnedKey(for dayKey: String) -> String {
        "hushtype.cloud.dailyUsage.capWarned.\(dayKey)"
    }

    private static func dayKey(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

extension CloudUsageTracker {
    static func formatSessionTime(seconds: Double) -> String {
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    static func formatDollars(_ dollars: Double) -> String {
        L10n.format("format.usd_total", "$%1$.2f", arguments: [dollars])
    }

    static func formatDailyBreakdown(_ snapshot: Snapshot) -> String {
        let dictationMinutes = Int(snapshot.dictationSeconds / 60.0)
        let captionMinutes = Int(snapshot.translatedCaptionSeconds / 60.0)
        return L10n.plural(
            "usage.daily_breakdown",
            count: dictationMinutes,
            fallback: "Today's cloud usage: %1$@ total; dictation %2$@ (%3$d min), translated caption %4$@ (%5$d min)",
            arguments: [
                formatDollars(snapshot.dayDollars),
                formatDollars(snapshot.dictationDollars),
                Int32(dictationMinutes),
                formatDollars(snapshot.translatedCaptionDollars),
                Int32(captionMinutes),
            ]
        )
    }
}
