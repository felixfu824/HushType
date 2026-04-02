# VoxKey iOS — Product Roadmap & Feasibility Report

> **Date:** 2026-04-03
> **Status:** Research complete, not yet started
> **Prerequisite:** VoxKey macOS is working (Qwen3-ASR 0.6B, MLX, Apple Silicon)

---

## Executive Summary

Porting VoxKey to iPhone is **technically feasible but architecturally different** from the macOS version. The core STT engine (Qwen3-ASR via speech-swift) already supports iOS 17+ via CoreML. The hard part is the iOS platform constraint: **keyboard extensions cannot access the microphone**. Every iOS voice input app must use a "bounce to main app" architecture — the keyboard extension opens the main app, the main app records and transcribes, then the user returns to the original app. This is an unsolved UX problem in public iOS APIs.

**Effort estimate:** 3-5x the macOS build. The STT engine ports cleanly; the engineering is in the keyboard extension UX and inter-process communication.

---

## Competitive Landscape

### What exists today

| Project | Type | STT Engine | Chinese? | Stars | Status |
|---------|------|-----------|----------|-------|--------|
| [TypeWhisper iOS](https://github.com/TypeWhisper/typewhisper-ios) | Keyboard extension + main app | WhisperKit + Apple Speech | Yes (99+ langs) | 5 | Beta, GPL-3.0 |
| [WhisperBoard](https://github.com/Saik0s/Whisperboard) | Standalone transcription app | whisper.cpp | Yes | ~1,000 | Semi-maintained |
| [WhisperKit](https://github.com/argmaxinc/WhisperKit) | Library (no app) | Whisper via CoreML | Yes | 5,900 | Active, MIT, Apple-backed |
| [speech-swift](https://github.com/soniqo/speech-swift) | Library + demos | Qwen3-ASR, Parakeet | Yes (52 langs) | 512 | Active |
| [KeyboardKit](https://github.com/KeyboardKit/KeyboardKit) | Keyboard framework | Apple Speech (Pro only) | Yes (75 locales) | 1,800 | Active, paid |
| [FUTO Voice Input](https://voiceinput.futo.org/) | Full voice keyboard | Whisper finetuned | Yes | N/A | **Android only** |

### Key finding

**TypeWhisper iOS is the only open-source project with a working iOS keyboard extension for voice-to-text.** It's very new (5 stars, beta) but validates the architecture. All other projects are either libraries (you build on top) or standalone apps (no keyboard integration).
(Felix: should check TypeLess)
---

## The Fundamental iOS Constraint

### Keyboard extensions cannot access the microphone

This is Apple's intentional security decision, not a bug. The `RequestsOpenAccess` entitlement grants network, contacts, location — but **never** microphone, camera, or HealthKit.

### Mandatory architecture: "Bounce to Main App"

```
User is typing in any app (e.g., Messages, Safari)
    |
    v
[Keyboard Extension]  — tap mic button
    |
    v  (deep link / URL scheme)
[VoxKey Main App]     — records audio, runs Qwen3-ASR, writes result to App Group
    |
    v  (??? return to previous app — UNSOLVED)
[Keyboard Extension]  — reads result from App Group, inserts text
```

### The "return to previous app" problem

After the main app finishes transcription, there is **no public iOS API** to programmatically return the user to the app they came from. Options:

| Approach | Works? | Risk |
|----------|--------|------|
| `_hostBundleID` (private API) | Blocked in iOS 18+ | App Store rejection |
| `UIApplication.suspend()` | Goes to home screen, not previous app | Bad UX |
| User manually switches back | Works but friction | Acceptable for MVP |
| PiP window trick | Some apps use this | Fragile, may break |
| Live Activities / Dynamic Island | Possible for notification | Doesn't switch apps |

**Wispr Flow (commercial)** somehow achieves seamless return for major apps — their method is undisclosed. TypeWhisper iOS uses the manual-return approach.

---

## Memory Constraints

### Keyboard extension limit: ~48-66 MB

Apple doesn't officially document this. The extension is killed instantly (Jetsam) when it exceeds the limit.

| Model | File Size | Runtime RAM | Fits in Extension? |
|-------|-----------|-------------|-------------------|
| Whisper Tiny | 75 MB | ~273 MB | NO |
| Whisper Base | 142 MB | ~388 MB | NO |
| Qwen3-ASR 0.6B (CoreML INT8) | 180 MB | ~400 MB | NO |
| Qwen3-ASR 0.6B (MLX 4-bit) | 675 MB | ~2.2 GB | NO |

**No speech model can run inside a keyboard extension.** All inference must happen in the main app process.

### iPhone device RAM

| Device | RAM | Qwen3-ASR 0.6B CoreML? |
|--------|-----|----------------------|
| iPhone 15 / 15 Plus | 6 GB | Tight but possible |
| iPhone 15 Pro / Pro Max | 8 GB | Yes |
| iPhone 16 / 16 Plus | 8 GB | Yes |
| iPhone 16 Pro / Pro Max | 12 GB | Yes |

MLX on iOS requires the `increased-memory-limit` entitlement and iPhone 15 Pro or later (8 GB+).

---

## Proposed Architecture for VoxKey iOS

### Two-target Xcode project

```
VoxKey-iOS/
├── VoxKey/                          # Main app target
│   ├── VoxKeyApp.swift              # SwiftUI app entry
│   ├── RecordingView.swift          # Full-screen mic recording UI
│   ├── TranscriptionEngine.swift    # Qwen3-ASR via CoreML (reuse from macOS)
│   ├── ChineseConverter.swift       # Pure Swift OpenCC (no CLI on iOS)
│   └── SharedContainer.swift        # App Group read/write
│
├── VoxKeyKeyboard/                  # Keyboard extension target
│   ├── KeyboardViewController.swift # UIInputViewController
│   ├── MicButton.swift              # Mic button in keyboard UI
│   └── SharedContainer.swift        # App Group read (same class)
│
├── Shared/                          # Shared between both targets
│   └── AppGroupConstants.swift      # Group ID, keys
│
└── Resources/
    └── OpenCC dictionaries          # Bundled s2twp tables (~2 MB)
```

### Data flow

1. User taps mic button on VoxKey keyboard
2. Keyboard extension opens main app via URL scheme: `voxkey://record`
3. Main app shows recording UI, captures audio via AVAudioEngine
4. User taps stop (or auto-detect silence via VAD)
5. Main app runs Qwen3-ASR (CoreML path on iOS), applies OpenCC conversion
6. Main app writes result to App Group: `UserDefaults(suiteName: "group.com.felix.voxkey")?.set(text, forKey: "transcription")`
7. Main app posts Darwin notification to signal keyboard extension
8. User switches back to original app (manual for MVP)
9. Keyboard extension reads result, inserts via `textDocumentProxy.insertText()`

---

## Implementation Phases

### Phase 0 — Validate STT on iPhone (1-2 days)

- Build a minimal iOS app (no keyboard extension) that records audio and transcribes with Qwen3-ASR CoreML
- Use speech-swift's iOS CoreML path: `CoreMLASRModel.fromPretrained()`
- Test on physical device (MLX/CoreML don't work on simulator)
- Measure: latency, memory usage, accuracy on mixed EN/ZH
- **Kill criterion:** If CoreML inference is too slow (>5s for 10s clip) or memory exceeds 1.5 GB, reconsider using WhisperKit tiny instead

### Phase 1 — Main App with Recording + Transcription (2-3 days)

- SwiftUI app with recording screen
- Qwen3-ASR CoreML transcription pipeline (reuse TranscriptionEngine protocol from macOS)
- **Pure Swift OpenCC:** Bundle the s2twp dictionary tables (~2 MB JSON) since we can't use `brew install opencc` on iOS. Parse and apply character/phrase mappings directly.
- App Group setup (`group.com.felix.voxkey`)
- URL scheme handler (`voxkey://record`)
- Write transcription result to App Group UserDefaults

### Phase 2 — Keyboard Extension (3-5 days)

- `UIInputViewController` subclass with minimal keyboard UI
- Mic button that opens main app via URL scheme
- Darwin notification listener for transcription completion
- Read result from App Group, insert via `textDocumentProxy.insertText()`
- Handle keyboard lifecycle (viewWillAppear, needsInputModeSwitchKey)
- "Allow Full Access" permission prompt

### Phase 3 — UX Polish (2-3 days)

- Recording UI: waveform visualization, timer, cancel button
- Keyboard UI: match iOS system keyboard aesthetic
- Loading states: "Downloading model..." / "Transcribing..."
- Settings screen: language selection, model choice
- Auto-return UX: investigate Live Activities / Dynamic Island as "tap to return" nudge
- Onboarding: guide user through keyboard setup (Settings → Keyboards → Add)

### Phase 4 — App Store Preparation (if desired)

- App Store review guidelines compliance
- Privacy policy (all processing is on-device)
- Model download UX (675 MB on first launch — cellular warning)
- TestFlight beta

---

## Key Technical Decisions

### 1. STT Engine: Qwen3-ASR CoreML vs WhisperKit

| | Qwen3-ASR 0.6B (CoreML) | WhisperKit Tiny |
|---|---|---|
| File size | ~180 MB | ~75 MB |
| Runtime RAM | ~400 MB | ~273 MB |
| Chinese quality | Excellent (52 langs, trained for code-switching) | Acceptable |
| English quality | Good | Good |
| Mixed EN/ZH | Excellent | Good (not trained specifically for this) |
| Traditional Chinese | Outputs naturally (confirmed on macOS) | Needs OpenCC or initial_prompt |
| iOS support | CoreML path in speech-swift | Native CoreML, Apple-backed |
| Maturity | Newer, fewer iOS deployments | Battle-tested on iOS |

**Recommendation:** Start with Qwen3-ASR CoreML since we already validated it on macOS and it's superior for mixed EN/ZH. Fall back to WhisperKit if iOS performance is unacceptable.

### 2. OpenCC on iOS: Pure Swift dictionary

The macOS version shells out to `/opt/homebrew/bin/opencc`. On iOS, we need a pure Swift implementation:
- Bundle the s2twp phrase dictionary (~2 MB JSON extracted from OpenCC's data files)
- Implement max-match forward segmentation for phrase replacement
- Character-by-character fallback for single-char conversions
- ~200 lines of Swift, no external dependency

Note: Based on macOS testing, Qwen3-ASR may output Traditional Chinese directly for Mandarin audio. If confirmed on iOS, OpenCC becomes optional (keep as fallback).

### 3. Return-to-app UX

For MVP, accept the manual switch. The user flow is:
1. Tap mic in keyboard → bounces to VoxKey app
2. Speak → see transcription
3. Tap "Done" → text is saved to App Group
4. User swipes up / taps notification → returns to original app
5. Keyboard auto-inserts the text

This is the same UX that TypeWhisper and KeyboardKit use. It's not as seamless as Wispr Flow, but it works and is App Store safe.

---

## Risks

| Risk | Impact | Mitigation |
|------|--------|------------|
| Qwen3-ASR CoreML too slow on iPhone | High | Benchmark in Phase 0; fall back to WhisperKit |
| Model too large for download (675 MB) | Medium | WhisperKit Tiny (75 MB) as lightweight option |
| Return-to-app UX friction kills adoption | Medium | Live Activities nudge; user habit formation |
| App Store rejection (keyboard + recording) | Low | TypeWhisper proves this pattern is accepted |
| CoreML model doesn't load on older iPhones | Medium | Require iPhone 15+ (6 GB RAM minimum) |
| Apple adds native mixed-language dictation | Low | Would make this project unnecessary — good outcome |

---

## What We Can Reuse from macOS VoxKey

| Component | Reusable? | Changes needed |
|-----------|-----------|---------------|
| `TranscriptionEngine.swift` (protocol) | Yes, directly | None — same protocol |
| `Qwen3TranscriptionEngine` | Partial | Switch from MLX path to CoreML path |
| `ChineseConverter.swift` | No | Rewrite: CLI → pure Swift dictionary |
| `AudioCaptureService.swift` | Yes, mostly | Add iOS audio session category handling |
| `AppConfig.swift` | Yes, adapt | Same pattern, add App Group UserDefaults |
| `HotkeyManager.swift` | No | Not applicable on iOS |
| `TextInserter.swift` | No | Replace with `textDocumentProxy.insertText()` |
| `InputSourceManager.swift` | No | Not applicable on iOS |
| `StatusBarController.swift` | No | Replace with SwiftUI views |

**~40% of the codebase ports directly.** The STT engine, audio capture, and config layer transfer. The input mechanism (keyboard extension) and output mechanism (text proxy) are entirely new.

---

## References

- [TypeWhisper iOS](https://github.com/TypeWhisper/typewhisper-ios) — only open-source iOS keyboard with voice-to-text
- [WhisperKit](https://github.com/argmaxinc/WhisperKit) — MIT, Apple-backed Whisper on CoreML
- [speech-swift](https://github.com/soniqo/speech-swift) — Qwen3-ASR Swift package (our current engine)
- [KeyboardKit](https://github.com/KeyboardKit/KeyboardKit) — keyboard framework with dictation pattern
- [Apple: Creating a Custom Keyboard](https://developer.apple.com/documentation/uikit/keyboards_and_input/creating_a_custom_keyboard)
- [FUTO Voice Input](https://voiceinput.futo.org/) — gold standard voice keyboard (Android only)
